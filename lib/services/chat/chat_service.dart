import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart'
    hide MessageStatus;

import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/services/auth/auth_service.dart';

class ChatService {
  ChatService._internal();
  static final ChatService _instance = ChatService._internal();
  factory ChatService() => _instance;

  final AuthService _authService = AuthService.instance;

  final _messageController =
      StreamController<ChatMessage>.broadcast();
  final _errorController =
      StreamController<String>.broadcast();
  final _connectionController =
      StreamController<bool>.broadcast();
  final _conversationsController =
      StreamController<List<ChatConversation>>.broadcast();

  Stream<ChatMessage>            get messageStream       =>
      _messageController.stream;
  Stream<String>                 get errorStream         =>
      _errorController.stream;
  Stream<bool>                   get connectionStream    =>
      _connectionController.stream;
  Stream<List<ChatConversation>> get conversationsStream =>
      _conversationsController.stream;

  String? _currentUserId;
  bool    _initialized = false;
  bool    _isConnected = false;

  String? get currentUserId => _currentUserId;

  final Map<String, ChatConversation>  _conversationsMap = {};
  final Map<String, List<ChatMessage>> _messagesCache    = {};

  Future<void> connect() async {
    if (_initialized) return;

    try {
      final user = await _authService.getCurrentUser();
      _currentUserId = user?.userId ?? OpenIM.iMManager.userID;

      if (_currentUserId == null || _currentUserId!.isEmpty) {
        _errorController.add('User not authenticated');
        return;
      }

      OpenIM.iMManager.messageManager.setAdvancedMsgListener(
        OnAdvancedMsgListener(
          onRecvNewMessage: (Message msg) {
            debugPrint('[ChatService] New message: ${msg.clientMsgID}');
            final chatMsg = _toChat(msg);
            if (chatMsg != null) {
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
            debugPrint('[ChatService] OpenIM sync finished - refreshing');
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

      await fetchConversations();
    } catch (e) {
      debugPrint('[ChatService] connect() error: $e');
      _errorController.add('Connection failed: $e');
      _connectionController.add(false);
    }
  }

  Future<void> sendMessage(ChatMessage message) async {
    if (!_isConnected) throw Exception('ChatService not connected');

    try {
      // Strip non-numeric characters so recvID is valid for OpenIM.
      // OpenIM rejects userIDs with '+' or other non-alphanumeric characters.
      final openImReceiverId = _toOpenImUserId(message.receiverId);

      await _authService.ensureOpenImUserExists(
        userId: openImReceiverId,
        nickname: message.receiverId,
      );

      final openImMsg = await OpenIM.iMManager.messageManager
          .createTextMessage(text: message.content);

      await OpenIM.iMManager.messageManager.sendMessage(
        message: openImMsg,
        userID: openImReceiverId,
        offlinePushInfo: OfflinePushInfo(
          title: 'New message',
          desc: message.content,
          iOSBadgeCount: true,
        ),
      );

      final convId = _deriveConvId(_currentUserId ?? '', openImReceiverId);

      final sent = ChatMessage(
        id: openImMsg.clientMsgID ??
            DateTime.now().millisecondsSinceEpoch.toString(),
        conversationId: convId,
        senderId: _currentUserId ?? '',
        receiverId: openImReceiverId,
        content: message.content,
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
      );

      _cacheMessage(sent);
      _messageController.add(sent);
    } catch (e) {
      //debugPrint('[ChatService] sendMessage error: $e');
      debugPrint('[ChatService] sendMessage error FULL:');
      debugPrint(e.toString());
      _errorController.add('Failed to send: $e');
      rethrow;
    }
  }

  Future<void> sendVoiceMessage({
    required String receiverID,
    required String filePath,
    required int durationSeconds,
    String senderName = 'New voice message',
  }) async {
    if (!_isConnected) throw Exception('ChatService not connected');

    try {
      final openImReceiverId = _toOpenImUserId(receiverID);

      await _authService.ensureOpenImUserExists(
        userId: openImReceiverId,
        nickname: receiverID,
      );

      final openImMsg = await OpenIM.iMManager.messageManager
          .createSoundMessageFromFullPath(
            soundPath: filePath,
            duration: durationSeconds,
          );

      await OpenIM.iMManager.messageManager.sendMessage(
        message: openImMsg,
        userID: openImReceiverId,
        offlinePushInfo: OfflinePushInfo(
          title: senderName,
          desc: 'Voice message',
          iOSBadgeCount: true,
        ),
      );

      final convId = _deriveConvId(_currentUserId ?? '', openImReceiverId);

      final local = ChatMessage(
        id: openImMsg.clientMsgID ??
            DateTime.now().millisecondsSinceEpoch.toString(),
        conversationId: convId,
        senderId: _currentUserId ?? '',
        receiverId: openImReceiverId,
        content: 'Voice message',
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

  Future<List<ChatMessage>> fetchMessageHistory({
    required String conversationID,
    Message? startMsg,
    int count = 40,
  }) async {
    try {
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

      debugPrint('[ChatService] fetchMessageHistory: ${messages.length} '
          'messages for conv $conversationID');
      return messages;
    } catch (e) {
      debugPrint('[ChatService] fetchMessageHistory error: $e');
      return [];
    }
  }

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

  Future<void> markConversationAsRead(String conversationId) async {
    try {
      await OpenIM.iMManager.conversationManager
          .markConversationMessageAsRead(conversationID: conversationId);

      if (_conversationsMap.containsKey(conversationId)) {
        _conversationsMap[conversationId] =
            _conversationsMap[conversationId]!.copyWith(unreadCount: 0);
        _emitConversations();
      }
    } catch (e) {
      debugPrint('[ChatService] markConversationAsRead error: $e');
    }
  }

  List<ChatMessage> getConversationMessages(String conversationId) {
    final msgs =
        List<ChatMessage>.from(_messagesCache[conversationId] ?? []);
    msgs.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return msgs;
  }

  Future<String?> getOpenImConversationId(String otherUserId) async {
    try {
      final info = await OpenIM.iMManager.conversationManager
          .getOneConversation(
            sourceID: _toOpenImUserId(otherUserId),
            sessionType: ConversationType.single,
          );
      return info.conversationID;
    } catch (e) {
      debugPrint('[ChatService] getOpenImConversationId error: $e');
      return null;
    }
  }


  //Before
  /*

  Future<void> disconnect() async {
    if (!_isConnected) return;
    _isConnected = false;
    _initialized = false;
    _connectionController.add(false);
    debugPrint('[ChatService] Disconnected');
  }

  */


  //After
  Future<void> disconnect() async {
  if (!_isConnected) return;
  await reset();
  }

/// Clears all in-memory state so a new user can connect cleanly.
/// Called on logout before OpenIM logout wipes the local SQLite DB.
  Future<void> reset() async {
    _isConnected = false;
    _initialized = false;
    _currentUserId = null;
    _conversationsMap.clear();
    _messagesCache.clear();
    _connectionController.add(false);
    debugPrint('[ChatService] Reset — ready for new user');
  }



  void dispose() {
    disconnect();
    _messageController.close();
    _errorController.close();
    _connectionController.close();
    _conversationsController.close();
  }

  ChatMessage? _toChat(Message msg) {
    final senderId   = msg.sendID ?? '';
    final receiverId = msg.recvID ?? '';
    final msgId      = msg.clientMsgID ?? msg.serverMsgID ?? '';

    if (senderId.isEmpty || msgId.isEmpty) return null;

    final convId = _deriveConvId(senderId, receiverId);

    final timestamp = msg.sendTime != null
        ? DateTime.fromMillisecondsSinceEpoch(msg.sendTime!)
        : DateTime.now();

    if (msg.contentType == 103 && msg.soundElem != null) {
      return ChatMessage(
        id: msgId,
        conversationId: convId,
        senderId: senderId,
        receiverId: receiverId,
        content: 'Voice message',
        timestamp: timestamp,
        status: _mapStatus(msg.status),
        attachmentUrl: msg.soundElem!.sourceUrl,
        attachmentType: 'voice',
        voiceDuration: msg.soundElem!.duration,
      );
    }

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
          lastMsgContent = 'Voice message';
        } else {
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
      _conversationsMap[convId] = _toConversation(conv);
    }
    _emitConversations();
  }

  void _cacheMessage(ChatMessage message) {
    final convId = message.conversationId;

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

  // OpenIM single-chat conversationID format: si_{smaller}_{larger}
  String _deriveConvId(String id1, String id2) {
    final ids = [id1, id2]..sort();
    return 'si_${ids[0]}_${ids[1]}';
  }

  // Strips non-numeric characters from a phone-number-based userID so it
  // is accepted by the OpenIM server, which rejects '+' and other symbols.
  /*
  String _toOpenImUserId(String id) {
    return id.replaceAll(RegExp(r'[^\d]'), '');
  }
  */

  String _toOpenImUserId(String id) {
  return id.trim();
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
