import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart'
    hide MessageStatus;

import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/services/auth/auth_service.dart';

// =============================================================================
//  ChatService
//
//  Single source of truth for all messaging in Wrytte.
//  All reads and writes go through the OpenIM SDK which manages its own
//  SQLite cache (local_chat_logs, local_conversations tables).
//
//  Firebase is NOT used here. FirebaseChatService can remain for legacy data
//  migration but is no longer called for any live messaging.
//
//  Public API:
//    connect()                    — register listeners, load initial data
//    sendMessage(msg)             — send a text message via OpenIM
//    sendVoiceMessage(...)        — send a voice note via OpenIM
//    fetchMessageHistory(...)     — load older messages (paginated)
//    fetchConversations()         — refresh conversation list from OpenIM cache
//    markConversationAsRead(id)   — mark all messages in conv as read
//    getConversationMessages(id)  — synchronous in-memory cache read
//    disconnect()                 — clean up listeners
// =============================================================================

class ChatService {
  // ── Singleton ──────────────────────────────────────────────────────────────
  ChatService._internal();
  static final ChatService _instance = ChatService._internal();
  factory ChatService() => _instance;

  final AuthService _authService = AuthService.instance;

  // ── Stream controllers ─────────────────────────────────────────────────────
  final _messageController =
      StreamController<ChatMessage>.broadcast();
  final _errorController =
      StreamController<String>.broadcast();
  final _connectionController =
      StreamController<bool>.broadcast();
  final _conversationsController =
      StreamController<List<ChatConversation>>.broadcast();

  // ── Public streams ─────────────────────────────────────────────────────────
  Stream<ChatMessage>            get messageStream       => _messageController.stream;
  Stream<String>                 get errorStream         => _errorController.stream;
  Stream<bool>                   get connectionStream    => _connectionController.stream;
  Stream<List<ChatConversation>> get conversationsStream => _conversationsController.stream;

  // ── State ──────────────────────────────────────────────────────────────────
  String? _currentUserId;
  bool    _initialized = false;
  bool    _isConnected = false;

  String? get currentUserId => _currentUserId;

  // ── In-memory cache (mirrors OpenIM's SQLite for fast sync reads) ──────────
  final Map<String, ChatConversation>  _conversationsMap = {};
  final Map<String, List<ChatMessage>> _messagesCache    = {};

  // ===========================================================================
  //  CONNECT
  //  Registers OpenIM listeners and loads the initial conversation list from
  //  OpenIM's local SQLite cache (instant — no network needed).
  // ===========================================================================
  Future<void> connect() async {
    if (_initialized) return;

    try {
      final user = await _authService.getCurrentUser();
      _currentUserId = user?.userId ?? OpenIM.iMManager.userID;

      if (_currentUserId == null || _currentUserId!.isEmpty) {
        _errorController.add('User not authenticated');
        return;
      }

      // ── 1. Message listener ──────────────────────────────────────────────
      OpenIM.iMManager.messageManager.setAdvancedMsgListener(
        OnAdvancedMsgListener(
          onRecvNewMessage: (Message msg) {
            debugPrint('[ChatService] New message: ${msg.clientMsgID}');
            final chatMsg = _toChat(msg);
            if (chatMsg != null) {
              // OpenIM already persisted this to its SQLite — just update UI
              _cacheMessage(chatMsg);
              _messageController.add(chatMsg);
            }
          },
          onNewRecvMessageRevoked: (RevokedInfo info) {
            final id = info.clientMsgID ?? '';
            for (final msgs in _messagesCache.values) {
              msgs.removeWhere((m) => m.id == id);
            }
            _emitConversations();
          },
          onMsgDeleted: (Message msg) {
            final id = msg.clientMsgID ?? '';
            for (final msgs in _messagesCache.values) {
              msgs.removeWhere((m) => m.id == id);
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

      // ── 2. Conversation listener ─────────────────────────────────────────
      await OpenIM.iMManager.conversationManager.setConversationListener(
        OnConversationListener(
          onConversationChanged: (List<ConversationInfo> list) {
            debugPrint('[ChatService] Conversations changed: ${list.length}');
            _mergeOpenImConversations(list);
          },
          onNewConversation: (List<ConversationInfo> list) {
            debugPrint('[ChatService] New conversations: ${list.length}');
            _mergeOpenImConversations(list);
          },
          onSyncServerStart: (_) =>
              debugPrint('[ChatService] OpenIM sync started'),
          onSyncServerFinish: (_) {
            debugPrint('[ChatService] OpenIM sync finished — refreshing');
            fetchConversations();
          },
          onSyncServerFailed: (_) =>
              debugPrint('[ChatService] OpenIM sync failed'),
          onTotalUnreadMessageCountChanged: (int count) =>
              debugPrint('[ChatService] Total unread: $count'),
        ),
      );

      _isConnected = true;
      _initialized = true;
      _connectionController.add(true);
      debugPrint('[ChatService] Connected (OpenIM SDK)');

      // ── 3. Load conversations from OpenIM's local SQLite immediately ──────
      await fetchConversations();
    } catch (e) {
      debugPrint('[ChatService] connect() error: $e');
      _errorController.add('Connection failed: $e');
      _connectionController.add(false);
    }
  }

  // ===========================================================================
  //  SEND TEXT MESSAGE
  //  OpenIM persists to local SQLite and syncs to server automatically.
  // ===========================================================================
  Future<void> sendMessage(ChatMessage message) async {
    if (!_isConnected) throw Exception('ChatService not connected');

    try {
      // createTextMessage builds an OpenIM Message object
      final openImMsg = await OpenIM.iMManager.messageManager
          .createTextMessage(text: message.content);

      // sendMessage delivers via WebSocket and persists to local SQLite
      await OpenIM.iMManager.messageManager.sendMessage(
        message: openImMsg,
        userID: message.receiverId,
        offlinePushInfo: OfflinePushInfo(
          title: 'New message',
          desc: message.content,
          iOSBadgeCount: true,
        ),
      );

      // Build a local ChatMessage from the sent OpenIM message for optimistic UI
      final sent = ChatMessage(
        id: openImMsg.clientMsgID ??
            DateTime.now().millisecondsSinceEpoch.toString(),
        conversationId: message.conversationId,
        senderId: _currentUserId ?? '',
        receiverId: message.receiverId,
        content: message.content,
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
      );

      _cacheMessage(sent);
      _messageController.add(sent);
    } catch (e) {
      debugPrint('[ChatService] sendMessage error: $e');
      _errorController.add('Failed to send: $e');
      rethrow;
    }
  }

  // ===========================================================================
  //  SEND VOICE NOTE
  //  OpenIM uploads the file to its CDN, persists metadata to local SQLite,
  //  and delivers via WebSocket.
  // ===========================================================================
  Future<void> sendVoiceMessage({
    required String receiverID,
    required String filePath,
    required int durationSeconds,
    String senderName = 'New voice message',
  }) async {
    if (!_isConnected) throw Exception('ChatService not connected');

    try {
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

      final convId = _deriveConvId(_currentUserId ?? '', receiverID);
      final local = ChatMessage(
        id: openImMsg.clientMsgID ??
            DateTime.now().millisecondsSinceEpoch.toString(),
        conversationId: convId,
        senderId: _currentUserId ?? '',
        receiverId: receiverID,
        content: '🎤 Voice message',
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
        attachmentUrl: openImMsg.soundElem?.sourceUrl,
        attachmentType: 'voice',
        voiceDuration: durationSeconds,
      );

      _cacheMessage(local);
      _messageController.add(local);
      debugPrint('[ChatService] Voice note sent (${durationSeconds}s)');
    } catch (e) {
      debugPrint('[ChatService] sendVoiceMessage error: $e');
      _errorController.add('Failed to send voice message: $e');
      rethrow;
    }
  }

  // ===========================================================================
  //  FETCH MESSAGE HISTORY
  //
  //  Reads from OpenIM's local SQLite cache first (fast, offline-capable).
  //  OpenIM automatically syncs missing messages from server in background.
  //
  //  Parameters:
  //    conversationID — OpenIM conversation ID (not our derived one)
  //    startMsg       — last known message for pagination (null = load latest)
  //    count          — number of messages to load per page
  // ===========================================================================
  Future<List<ChatMessage>> fetchMessageHistory({
    required String conversationID,
    Message? startMsg,
    int count = 40,
  }) async {
    try {
      // getAdvancedHistoryMessageList reads from OpenIM's local SQLite.
      // No network call unless messages are missing from cache.
      final AdvancedMessage result = await OpenIM
          .iMManager.messageManager
          .getAdvancedHistoryMessageList(
            conversationID: conversationID,
            startMsg: startMsg,
            count: count,
          );

      final List<ChatMessage> messages = [];
      for (final msg in result.messageList ?? <Message>[]) {
        final chatMsg = _toChat(msg);
        if (chatMsg != null) {
          messages.add(chatMsg);
          _cacheMessage(chatMsg);
        }
      }

      debugPrint(
          '[ChatService] fetchMessageHistory: ${messages.length} messages '
          'for conv $conversationID');
      return messages;
    } catch (e) {
      debugPrint('[ChatService] fetchMessageHistory error: $e');
      return [];
    }
  }

  // ===========================================================================
  //  FETCH CONVERSATIONS
  //
  //  Reads from OpenIM's local SQLite (getConversationListSplit).
  //  This is the same table OpenIM syncs server-side conversations into.
  //  Result is instant on subsequent calls — no network needed.
  // ===========================================================================
  Future<void> fetchConversations({int offset = 0, int count = 100}) async {
    try {
      final List<ConversationInfo> convs = await OpenIM
          .iMManager.conversationManager
          .getConversationListSplit(offset: offset, count: count);

      debugPrint('[ChatService] Loaded ${convs.length} conversations from '
          'OpenIM local cache');
      _mergeOpenImConversations(convs);
    } catch (e) {
      debugPrint('[ChatService] fetchConversations error: $e');
    }
  }

  // ===========================================================================
  //  MARK AS READ
  //  Tells OpenIM to mark all messages in the conversation as read.
  //  OpenIM updates its local SQLite and syncs the read receipt to server.
  // ===========================================================================
  Future<void> markConversationAsRead(String conversationId) async {
    try {
      await OpenIM.iMManager.conversationManager
          .markConversationMessageAsRead(conversationID: conversationId);

      // Update our in-memory cache too
      if (_conversationsMap.containsKey(conversationId)) {
        _conversationsMap[conversationId] =
            _conversationsMap[conversationId]!.copyWith(unreadCount: 0);
        _emitConversations();
      }
    } catch (e) {
      debugPrint('[ChatService] markConversationAsRead error: $e');
    }
  }

  // ===========================================================================
  //  GET CACHED MESSAGES (synchronous)
  //  Returns the in-memory copy — use after fetchMessageHistory() has been called.
  // ===========================================================================
  List<ChatMessage> getConversationMessages(String conversationId) {
    final msgs = List<ChatMessage>.from(_messagesCache[conversationId] ?? []);
    msgs.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return msgs;
  }

  // ===========================================================================
  //  GET OPENIM CONVERSATION ID
  //
  //  OpenIM uses its own conversationID format (e.g. "si_uid1_uid2_0").
  //  Use this to get the real OpenIM conversationID before calling
  //  fetchMessageHistory().
  // ===========================================================================
  Future<String?> getOpenImConversationId(String otherUserId) async {
    try {
      final info = await OpenIM.iMManager.conversationManager
          .getOneConversation(
            sourceID: otherUserId,
            sessionType: ConversationType.single,
          );
      return info.conversationID;
    } catch (e) {
      debugPrint('[ChatService] getOpenImConversationId error: $e');
      return null;
    }
  }

  // ===========================================================================
  //  DISCONNECT
  // ===========================================================================
  Future<void> disconnect() async {
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

  // ===========================================================================
  //  PRIVATE HELPERS
  // ===========================================================================

  // ── Convert OpenIM Message → ChatMessage ────────────────────────────────────
  // FIX: msg.conversationID does not exist on the OpenIM Message type.
  // Always derive the conversation ID from sendID + recvID instead.
  ChatMessage? _toChat(Message msg) {
    final senderId   = msg.sendID ?? '';
    final receiverId = msg.recvID ?? '';
    final msgId      = msg.clientMsgID ?? msg.serverMsgID ?? '';

    if (senderId.isEmpty || msgId.isEmpty) return null;

    // Derive a stable conversationID from the two participant IDs.
    // (msg.conversationID is not a field on the OpenIM Message type.)
    final convId = _deriveConvId(senderId, receiverId);

    final timestamp = msg.sendTime != null
        ? DateTime.fromMillisecondsSinceEpoch(msg.sendTime!)
        : DateTime.now();

    // Voice note (contentType 103)
    if (msg.contentType == 103 && msg.soundElem != null) {
      return ChatMessage(
        id: msgId,
        conversationId: convId,
        senderId: senderId,
        receiverId: receiverId,
        content: '🎤 Voice message',
        timestamp: timestamp,
        status: _mapStatus(msg.status),
        attachmentUrl: msg.soundElem!.sourceUrl,
        attachmentType: 'voice',
        voiceDuration: msg.soundElem!.duration,
      );
    }

    // Text message (contentType 101)
    return ChatMessage(
      id: msgId,
      conversationId: convId,
      senderId: senderId,
      receiverId: receiverId,
      content: msg.textElem?.content ?? '',
      timestamp: timestamp,
      status: _mapStatus(msg.status),
    );
  }

  // ── Convert OpenIM ConversationInfo → ChatConversation ──────────────────────
  // FIX: conv.latestMsg is typed as Message? (not String?) in the SDK.
  // Access it as a typed object via .textElem?.content and .contentType.
  ChatConversation _toConversation(ConversationInfo conv) {
    final convId  = conv.conversationID ?? '';
    final otherId = conv.userID ?? '';

    final lastTime = conv.latestMsgSendTime != null
        ? DateTime.fromMillisecondsSinceEpoch(conv.latestMsgSendTime!)
        : DateTime.now();

    String lastMsgContent = conv.showName ?? '';
    try {
      final latestMsg = conv.latestMsg;
      if (latestMsg != null) {
        if (latestMsg.contentType == 103) {
          // Voice note
          lastMsgContent = '🎤 Voice message';
        } else {
          // Text or any other type — prefer textElem content, fall back to showName
          final text = latestMsg.textElem?.content;
          if (text != null && text.isNotEmpty) {
            lastMsgContent = text;
          }
        }
      }
    } catch (_) {}

    return ChatConversation(
      id: convId,
      participants: [_currentUserId ?? '', otherId],
      otherUserId: otherId,
      lastMessage: lastMsgContent,
      lastMessageSenderId: '',
      lastMessageTime: lastTime,
      unreadCount: conv.unreadCount ?? 0,
      otherUserName: conv.showName,
      otherUserAvatar: conv.faceURL,
    );
  }

  void _mergeOpenImConversations(List<ConversationInfo> convs) {
    for (final conv in convs) {
      final convId = conv.conversationID ?? '';
      if (convId.isEmpty) continue;

      final chatConv = _toConversation(conv);
      _conversationsMap[convId] = chatConv;
    }
    _emitConversations();
  }

  void _cacheMessage(ChatMessage message) {
    final convId = message.conversationId;

    // Update conversation preview
    if (_conversationsMap.containsKey(convId)) {
      _conversationsMap[convId] =
          _conversationsMap[convId]!.updateWithMessage(
            message,
            _currentUserId ?? '',
          );
    } else {
      _conversationsMap[convId] =
          ChatConversation.fromMessage(message, _currentUserId ?? '');
    }

    // Store in message cache (dedup by id)
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

  // Stable sorted conversationID derived from two participant IDs.
  // Used as a fallback since OpenIM Message objects don't carry conversationID.
  String _deriveConvId(String id1, String id2) {
    final ids = [id1, id2]..sort();
    return '${ids[0]}-${ids[1]}';
  }

  MessageStatus _mapStatus(int? status) {
    switch (status) {
      case 1:  return MessageStatus.sending;
      case 2:  return MessageStatus.sent;
      case 3:  return MessageStatus.failed;
      default: return MessageStatus.sent;
    }
  }
}
