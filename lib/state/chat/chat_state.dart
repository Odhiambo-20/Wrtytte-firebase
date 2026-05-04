import 'dart:async';

import 'package:flutter/widgets.dart' show UniqueKey;
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart' hide MessageStatus;

import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';

class ChatState {
  String? _activeConversationId;

  final List<ChatMessage> _messages = [];
  final List<ChatConversation> _conversations = [];

  final StreamController<List<ChatMessage>> _messagesController =
      StreamController<List<ChatMessage>>.broadcast();
  final StreamController<List<ChatConversation>> _conversationsController =
      StreamController<List<ChatConversation>>.broadcast();
  final StreamController<bool> _loadingController =
      StreamController<bool>.broadcast();
  final StreamController<String?> _errorController =
      StreamController<String?>.broadcast();

  Stream<List<ChatMessage>> get messagesStream => _messagesController.stream;
  Stream<List<ChatConversation>> get conversationsStream =>
      _conversationsController.stream;
  Stream<bool> get loadingStream => _loadingController.stream;
  Stream<String?> get errorStream => _errorController.stream;

  Future<void> initialize() async {
    _loadingController.add(true);
    try {
      OpenIM.iMManager.messageManager.setAdvancedMsgListener(
        OnAdvancedMsgListener(
          onRecvNewMessage: (Message msg) {
            final incoming = _openImMsgToChatMessage(msg);
            if (incoming == null) return;
            final msgConvId = _msgConversationId(msg);
            if (msgConvId == _activeConversationId) {
              if (!_messages.any((m) => m.id == incoming.id)) {
                _messages.add(incoming);
                _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
                _messagesController.add(List.unmodifiable(_messages));
              }
            }
            _loadConversationList();
          },
          onNewRecvMessageRevoked: (RevokedInfo info) {
            _messages.removeWhere((m) => m.id == info.clientMsgID);
            _messagesController.add(List.unmodifiable(_messages));
          },
          onRecvC2CReadReceipt: (List<ReadReceiptInfo> list) {
            for (final receipt in list) {
              for (final msgId in (receipt.msgIDList ?? [])) {
                final idx = _messages.indexWhere((m) => m.id == msgId);
                if (idx != -1) {
                  _messages[idx] = _messages[idx].copyWith(
                    status: MessageStatus.read,
                  );
                }
              }
            }
            _messagesController.add(List.unmodifiable(_messages));
          },
        ),
      );

      await _loadConversationList();
      _loadingController.add(false);
    } catch (e) {
      _loadingController.add(false);
      _handleError('Failed to initialize chat: $e');
    }
  }

  Future<void> loadConversation(String conversationId) async {
    _activeConversationId = conversationId;
    _messages.clear();

    try {
      final AdvancedMessage result = await OpenIM.iMManager.messageManager
          .getAdvancedHistoryMessageList(
            conversationID: conversationId,
            count: 40,
          );

      for (final msg in result.messageList ?? []) {
        final cm = _openImMsgToChatMessage(msg);
        if (cm != null) _messages.add(cm);
      }

      _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      _messagesController.add(List.unmodifiable(_messages));
    } catch (e) {
      _handleError('Failed to load conversation: $e');
    }
  }

  Future<void> sendMessage(ChatMessage message) async {
    if (message.conversationId == _activeConversationId) {
      if (!_messages.any((m) => m.id == message.id)) {
        _messages.add(message);
        _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        _messagesController.add(List.unmodifiable(_messages));
      }
    }

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
          iOSPushSound: 'default',
        ),
      );

      final idx = _messages.indexWhere((m) => m.id == message.id);
      if (idx != -1) {
        _messages[idx] = _messages[idx].copyWith(status: MessageStatus.sent);
        _messagesController.add(List.unmodifiable(_messages));
      }
      _loadConversationList();
    } catch (e) {
      final idx = _messages.indexWhere((m) => m.id == message.id);
      if (idx != -1) {
        _messages[idx] = _messages[idx].copyWith(status: MessageStatus.failed);
        _messagesController.add(List.unmodifiable(_messages));
      }
      _handleError('Failed to send message: $e');
    }
  }

  void clearMessages() {
    _messages.clear();
    _messagesController.add([]);
  }

  Future<void> disconnect() async {}

  void dispose() {
    _messagesController.close();
    _conversationsController.close();
    _loadingController.close();
    _errorController.close();
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  /// Derive a conversation ID from a Message.
  /// For 1-to-1 chats sessionType==1, groupID is null; use recvID+sendID combo.
  String _msgConversationId(Message msg) {
    if (msg.groupID != null && msg.groupID!.isNotEmpty) return msg.groupID!;
    // For single chats OpenIM uses a derived conversationID not stored on Message.
    // Fall back to activeConversationId when the message belongs to active conv.
    return _activeConversationId ?? '';
  }

  Future<void> _loadConversationList() async {
    try {
      final List<ConversationInfo> openImConvs = await OpenIM
          .iMManager
          .conversationManager
          .getAllConversationList();

      _conversations
        ..clear()
        ..addAll(openImConvs.map(_openImConvToChatConversation).whereType<ChatConversation>());

      _conversationsController.add(List.unmodifiable(_conversations));
    } catch (e) {
      // ignore: avoid_print
      print('[ChatState] Failed to load conversations: $e');
    }
  }

  ChatMessage? _openImMsgToChatMessage(Message msg) {
    final textContent = msg.textElem?.content ?? '';
    if (textContent.isEmpty) return null;

    return ChatMessage(
      id: msg.clientMsgID ?? msg.serverMsgID ?? UniqueKey().toString(),
      conversationId: _msgConversationId(msg),
      senderId: msg.sendID ?? '',
      receiverId: msg.recvID ?? '',
      content: textContent,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (msg.sendTime ?? 0) * 1000,
      ),
      status: _openImStatusToLocal(msg.status),
    );
  }

  ChatConversation? _openImConvToChatConversation(ConversationInfo conv) {
    final convId = conv.conversationID ?? '';
    final otherId = conv.userID ?? conv.groupID ?? '';
    if (convId.isEmpty || otherId.isEmpty) return null;

    ChatMessage? lastMsg;
    try {
      if (conv.latestMsg != null) {
        lastMsg = _openImMsgToChatMessage(
          Message.fromJson(conv.latestMsg as Map<String, dynamic>),
        );
      }
    } catch (_) {}

    return ChatConversation(
      id: convId,
      participants: [otherId],
      otherUserId: otherId,
      lastMessage: lastMsg?.content ?? '',
      lastMessageSenderId: lastMsg?.senderId ?? '',
      lastMessageTime: lastMsg?.timestamp ?? DateTime.now(),
      unreadCount: conv.unreadCount ?? 0,
    );
  }

  MessageStatus _openImStatusToLocal(int? status) {
    switch (status) {
      case 1: return MessageStatus.sending;
      case 2: return MessageStatus.sent;
      case 3: return MessageStatus.failed;
      default: return MessageStatus.sent;
    }
  }

  void _handleError(String error) {
    _errorController.add(error);
  }
}
