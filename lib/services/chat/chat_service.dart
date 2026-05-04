import 'dart:async';

import 'package:flutter/foundation.dart';

// ── Hide OpenIM's MessageStatus so it never clashes with our own enum ─────────
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart'
    hide MessageStatus;
// ─────────────────────────────────────────────────────────────────────────────

import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/services/auth/auth_service.dart';

class ChatService {
  // ── Singleton ──────────────────────────────────────────────────────────────
  ChatService._internal();
  static final ChatService _instance = ChatService._internal();
  factory ChatService() => _instance;

  final AuthService _authService = AuthService.instance;

  // ── Stream controllers ─────────────────────────────────────────────────────
  final StreamController<ChatMessage> _messageController =
      StreamController<ChatMessage>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();
  final StreamController<List<ChatConversation>> _conversationsController =
      StreamController<List<ChatConversation>>.broadcast();

  // ── Public streams ─────────────────────────────────────────────────────────
  Stream<ChatMessage>            get messageStream       => _messageController.stream;
  Stream<String>                 get errorStream         => _errorController.stream;
  Stream<bool>                   get connectionStream    => _connectionController.stream;
  Stream<List<ChatConversation>> get conversationsStream => _conversationsController.stream;

  // ── State ──────────────────────────────────────────────────────────────────
  String? _currentUserId;
  bool _initialized = false;
  bool _isConnected = false;

  // ── In-memory cache ────────────────────────────────────────────────────────
  final Map<String, ChatConversation>  _conversationsMap = {};
  final Map<String, List<ChatMessage>> _messagesCache    = {};


  // ══════════════════════════════════════════════════════════════════════════
  //  CONNECT
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> connect() async {
    if (_initialized) return;

    try {
      final user = await _authService.getCurrentUser();
      _currentUserId = user?.userId ?? OpenIM.iMManager.userID;

      if (_currentUserId == null || _currentUserId!.isEmpty) {
        _errorController.add("User not authenticated");
        return;
      }

      // ── Register OpenIM message listener ───────────────────────────────────
      //
      // SDK 3.8.3 OnAdvancedMsgListener constructor parameters (verified):
      //   onRecvNewMessage          → (Message msg)
      //   onNewRecvMessageRevoked   → (RevokedInfo info)
      //   onMsgDeleted              → (Message msg)
      //   onRecvC2CReadReceipt      → (List<ReadReceiptInfo> list)
      //   onRecvOfflineNewMessage   → (Message msg)
      //   onRecvOnlineOnlyMessage   → (Message msg)
      OpenIM.iMManager.messageManager.setAdvancedMsgListener(
        OnAdvancedMsgListener(
          onRecvNewMessage: (Message msg) {
            final chatMsg = _openImMessageToChatMessage(msg);
            if (chatMsg != null) {
              _messageController.add(chatMsg);
              _updateConversationCache(chatMsg);
            }
          },
          onNewRecvMessageRevoked: (RevokedInfo info) {
            final revokedId = info.clientMsgID ?? '';
            for (final msgs in _messagesCache.values) {
              msgs.removeWhere((m) => m.id == revokedId);
            }
            _emitConversations();
          },
          onMsgDeleted: (Message msg) {
            final deletedId = msg.clientMsgID ?? '';
            for (final msgs in _messagesCache.values) {
              msgs.removeWhere((m) => m.id == deletedId);
            }
            _emitConversations();
          },
          onRecvC2CReadReceipt: (List<ReadReceiptInfo> list) {
            for (final receipt in list) {
              for (final msgs in _messagesCache.values) {
                for (var i = 0; i < msgs.length; i++) {
                  if (receipt.msgIDList?.contains(msgs[i].id) == true) {
                    msgs[i] = msgs[i].copyWith(status: MessageStatus.read);
                  }
                }
              }
            }
            _emitConversations();
          },
        ),
      );

      // ── Register conversation listener ─────────────────────────────────────
      await OpenIM.iMManager.conversationManager.setConversationListener(
        OnConversationListener(
          onConversationChanged: (List<ConversationInfo> list) {
            _mergeConversations(list);
          },
          onNewConversation: (List<ConversationInfo> list) {
            _mergeConversations(list);
          },
          onSyncServerStart: (bool? reinstalled) {
            debugPrint('[ChatService] OpenIM sync started');
          },
          onSyncServerFinish: (bool? reinstalled) {
            debugPrint('[ChatService] OpenIM sync finished');
            fetchConversations();
          },
          onSyncServerFailed: (bool? reinstalled) {
            debugPrint('[ChatService] OpenIM sync failed');
          },
          onTotalUnreadMessageCountChanged: (int count) {
            debugPrint('[ChatService] Unread count: $count');
          },
        ),
      );

      _isConnected = true;
      _initialized = true;
      _connectionController.add(true);
      debugPrint('[ChatService] Connected via OpenIM');

      await fetchConversations();
    } catch (e) {
      debugPrint('[ChatService] connect() error: $e');
      _errorController.add("Connection failed: $e");
      _connectionController.add(false);
    }
  }


  // ══════════════════════════════════════════════════════════════════════════
  //  SEND TEXT MESSAGE
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> sendMessage(ChatMessage message) async {
    if (!_isConnected) throw Exception("ChatService not connected");

    try {
      final openImMsg = await OpenIM.iMManager.messageManager
          .createTextMessage(text: message.content);

      await OpenIM.iMManager.messageManager.sendMessage(
        message: openImMsg,
        userID: message.receiverId,
        offlinePushInfo: OfflinePushInfo(
          title: 'New message',
          desc: message.content,
          iOSBadgeCount: true,
        ),
      );

      _updateConversationCache(message);
      _messageController.add(message);
    } catch (e) {
      debugPrint('[ChatService] sendMessage error: $e');
      _errorController.add("Failed to send message: $e");
      rethrow;
    }
  }


  // ══════════════════════════════════════════════════════════════════════════
  //  SEND VOICE NOTE  ← NEW
  //
  //  Flow (mirrors WhatsApp voice notes):
  //    1. UI records audio via flutter_sound → gets a local file path + duration
  //    2. UI calls ChatService.sendVoiceMessage(receiverID, filePath, duration)
  //    3. OpenIM creates a sound message from the file path
  //    4. OpenIM uploads the file to its server and sends the message
  //    5. Receiver's onRecvNewMessage fires; _openImMessageToChatMessage()
  //       reads soundElem and returns a ChatMessage with attachmentType='voice'
  //
  //  Parameters:
  //    receiverID      — OpenIM userID of the other person
  //    filePath        — absolute path from flutter_sound (e.g. .aac file)
  //    durationSeconds — length of the recording in whole seconds
  //    senderName      — shown in the offline push notification
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> sendVoiceMessage({
    required String receiverID,
    required String filePath,
    required int durationSeconds,
    String senderName = 'New voice message',
  }) async {
    if (!_isConnected) throw Exception("ChatService not connected");

    try {
      // createSoundMessageFromFullPath uploads the file to the OpenIM file
      // server and returns a Message object with soundElem populated.
      final openImMsg = await OpenIM.iMManager.messageManager
          .createSoundMessageFromFullPath(
            soundPath: filePath,
            duration: durationSeconds,
          );

      await OpenIM.iMManager.messageManager.sendMessage(
        message: openImMsg,
        userID: receiverID,
        offlinePushInfo: OfflinePushInfo(
          title: senderName,
          desc: '🎤 Voice message',
          iOSBadgeCount: true,
        ),
      );

      // Build our local ChatMessage so the sender sees it in the list
      // immediately (optimistic update), same pattern as sendMessage().
      final localMsg = ChatMessage(
        id: openImMsg.clientMsgID ??
            DateTime.now().millisecondsSinceEpoch.toString(),
        conversationId: _deriveConvId(_currentUserId ?? '', receiverID),
        senderId: _currentUserId ?? '',
        receiverId: receiverID,
        content: '🎤 Voice message',        // fallback text for conversation preview
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
        attachmentUrl: openImMsg.soundElem?.sourceUrl,
        attachmentType: 'voice',
        voiceDuration: durationSeconds,
      );

      _updateConversationCache(localMsg);
      _messageController.add(localMsg);

      debugPrint('[ChatService] Voice note sent (${durationSeconds}s)');
    } catch (e) {
      debugPrint('[ChatService] sendVoiceMessage error: $e');
      _errorController.add("Failed to send voice message: $e");
      rethrow;
    }
  }


  // ══════════════════════════════════════════════════════════════════════════
  //  FETCH MESSAGE HISTORY
  //
  //  SDK 3.8.3: method is getAdvancedHistoryMessageList
  //  Returns AdvancedMessage whose .messageList is List<Message>?
  //  Takes conversationID (not userID)
  // ══════════════════════════════════════════════════════════════════════════

  Future<List<ChatMessage>> fetchMessageHistory({
    required String conversationID,
    Message? startMsg,
    int count = 20,
  }) async {
    try {
      final AdvancedMessage result = await OpenIM
          .iMManager.messageManager
          .getAdvancedHistoryMessageList(
            conversationID: conversationID,
            startMsg: startMsg,
            count: count,
          );

      final List<ChatMessage> chatMessages = [];
      for (final msg in result.messageList ?? <Message>[]) {
        final chatMsg = _openImMessageToChatMessage(msg);
        if (chatMsg != null) {
          chatMessages.add(chatMsg);
          _updateConversationCache(chatMsg);
        }
      }

      debugPrint('[ChatService] Fetched ${chatMessages.length} messages');
      return chatMessages;
    } catch (e) {
      debugPrint('[ChatService] fetchMessageHistory error: $e');
      return [];
    }
  }

  // Legacy alias so existing callers don't break
  Future<void> fetchMessages() async => fetchConversations();


  // ══════════════════════════════════════════════════════════════════════════
  //  FETCH CONVERSATION LIST
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> fetchConversations({int offset = 0, int count = 50}) async {
    try {
      final List<ConversationInfo> convs = await OpenIM
          .iMManager.conversationManager
          .getConversationListSplit(offset: offset, count: count);

      _mergeConversations(convs);
    } catch (e) {
      debugPrint('[ChatService] fetchConversations error: $e');
    }
  }


  // ══════════════════════════════════════════════════════════════════════════
  //  GET CACHED CONVERSATION MESSAGES
  // ══════════════════════════════════════════════════════════════════════════

  List<ChatMessage> getConversationMessages(String conversationId) {
    final messages = List<ChatMessage>.from(
        _messagesCache[conversationId] ?? []);
    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return messages;
  }


  // ══════════════════════════════════════════════════════════════════════════
  //  MARK AS READ
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> markConversationAsRead(String conversationId) async {
    try {
      await OpenIM.iMManager.conversationManager
          .markConversationMessageAsRead(conversationID: conversationId);
    } catch (e) {
      debugPrint('[ChatService] markConversationAsRead error: $e');
    }
  }


  // ══════════════════════════════════════════════════════════════════════════
  //  DISCONNECT / DISPOSE
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> disconnect() async => _handleDisconnect();

  void _handleDisconnect() {
    if (!_isConnected) return;
    _isConnected = false;
    _initialized = false;
    _connectionController.add(false);
    debugPrint('[ChatService] Disconnected');
  }

  void dispose() {
    disconnect();
    _messageController.close();
    _errorController.close();
    _connectionController.close();
    _conversationsController.close();
  }


  // ══════════════════════════════════════════════════════════════════════════
  //  PRIVATE HELPERS
  // ══════════════════════════════════════════════════════════════════════════

  // ── Convert an OpenIM Message → our ChatMessage ───────────────────────────
  //
  // Handles both text messages (contentType == 101) and
  // voice/sound messages  (contentType == 103).
  //
  // OpenIM content type constants (verified from SDK source):
  //   101 → text
  //   103 → sound / voice note
  //   102 → picture
  //   104 → video
  // ─────────────────────────────────────────────────────────────────────────
  ChatMessage? _openImMessageToChatMessage(Message msg) {
    final senderId = msg.sendID ?? '';
    final receiverId = msg.recvID ?? '';
    final msgId = msg.clientMsgID ?? msg.serverMsgID ?? '';

    if (senderId.isEmpty || msgId.isEmpty) return null;

    final convId = _deriveConvId(senderId, receiverId);

    final timestamp = msg.sendTime != null
        ? DateTime.fromMillisecondsSinceEpoch(msg.sendTime!)
        : DateTime.now();

    // ── Voice note (soundElem) ─────────────────────────────────────────────
    // OpenIM contentType 103 = sound message
    if (msg.contentType == 103 && msg.soundElem != null) {
      return ChatMessage(
        id: msgId,
        conversationId: convId,
        senderId: senderId,
        receiverId: receiverId,
        content: '🎤 Voice message',          // preview text
        timestamp: timestamp,
        status: _mapMsgStatus(msg.status),
        attachmentUrl: msg.soundElem!.sourceUrl,   // CDN URL after upload
        attachmentType: 'voice',
        voiceDuration: msg.soundElem!.duration,    // seconds
      );
    }

    // ── Plain text message (textElem) ──────────────────────────────────────
    final content = msg.textElem?.content ?? '';
    return ChatMessage(
      id: msgId,
      conversationId: convId,
      senderId: senderId,
      receiverId: receiverId,
      content: content,
      timestamp: timestamp,
      status: _mapMsgStatus(msg.status),
    );
  }

  // Stable sorted conversationId — matches select_contact_screen.dart
  String _deriveConvId(String id1, String id2) {
    final ids = [id1, id2]..sort();
    return '${ids[0]}-${ids[1]}';
  }

  MessageStatus _mapMsgStatus(int? status) {
    switch (status) {
      case 1:  return MessageStatus.sending;
      case 2:  return MessageStatus.sent;
      case 3:  return MessageStatus.failed;
      default: return MessageStatus.sent;
    }
  }

  void _mergeConversations(List<ConversationInfo> openImConvs) {
    for (final conv in openImConvs) {
      final convId  = conv.conversationID ?? '';
      final otherId = conv.userID ?? '';
      if (convId.isEmpty) continue;

      final lastTime = conv.latestMsgSendTime != null
          ? DateTime.fromMillisecondsSinceEpoch(conv.latestMsgSendTime!)
          : DateTime.now();

      final lastMsg = ChatMessage(
        id: '${convId}_last',
        conversationId: convId,
        senderId: otherId,
        receiverId: _currentUserId ?? '',
        content: conv.showName ?? '',
        timestamp: lastTime,
        status: MessageStatus.sent,
      );

      if (_conversationsMap.containsKey(convId)) {
        _conversationsMap[convId] = _conversationsMap[convId]!
            .updateWithMessage(lastMsg, _currentUserId ?? '');
      } else {
        _conversationsMap[convId] =
            ChatConversation.fromMessage(lastMsg, _currentUserId ?? '');
      }
    }
    _emitConversations();
  }

  void _updateConversationCache(ChatMessage message) {
    final convId        = message.conversationId;
    final currentUserId = _currentUserId ?? '';

    if (_conversationsMap.containsKey(convId)) {
      _conversationsMap[convId] =
          _conversationsMap[convId]!.updateWithMessage(message, currentUserId);
    } else {
      _conversationsMap[convId] =
          ChatConversation.fromMessage(message, currentUserId);
    }

    _messagesCache.putIfAbsent(convId, () => []);
    if (!_messagesCache[convId]!.any((m) => m.id == message.id)) {
      _messagesCache[convId]!.add(message);
    }

    _emitConversations();
  }

  void _emitConversations() {
    final sorted = _conversationsMap.values.toList()
      ..sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
    _conversationsController.add(sorted);
  }
}
