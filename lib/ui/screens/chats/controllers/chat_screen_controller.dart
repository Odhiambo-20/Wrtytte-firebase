import 'package:flutter_openim_sdk/flutter_openim_sdk.dart' hide MessageStatus;

import 'package:wrytte/models/auth_models/auth_user.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/state/chat/chat_state.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ChatScreenController — OpenIM-powered controller for the chat screen
//
// Changes vs previous version:
//   • Added: sendVoiceMessage() — bridges the UI recorder to ChatService
//   • Added: ChatService instance (needed to call sendVoiceMessage on the service)
//   • Kept:  ALL other public properties and method signatures — UI untouched.
// ─────────────────────────────────────────────────────────────────────────────

class ChatScreenController {
  final String conversationId;
  final AuthUser currentUser;
  final String receiverId;

  // ChatState owns OpenIM message listener + history loading
  late final ChatState _chatState;

  // ChatService owns OpenIM message sending (text + voice)
  final ChatService _chatService = ChatService();

  ChatScreenController({
    required this.conversationId,
    required this.currentUser,
    required this.receiverId,
  }) {
    _chatState = ChatState();
  }

  // ── Public streams (same signatures as before — UI untouched) ─────────────
  Stream<List<ChatMessage>> get messagesStream => _chatState.messagesStream;
  Stream<bool> get loadingStream => _chatState.loadingStream;
  Stream<String?> get errorStream => _chatState.errorStream;

  // ─────────────────────────────────────────────────────────────────────────
  // INITIALIZE
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> initialize() async {
    await _chatState.initialize();
    final String openImConversationId = await _resolveConversationId();
    await _chatState.loadConversation(openImConversationId);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SEND TEXT MESSAGE
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> sendMessage(String content) async {
    if (content.trim().isEmpty) return;

    final openImConversationId = await _resolveConversationId();

    final message = ChatMessage(
      id: '${currentUser.userId}_${DateTime.now().millisecondsSinceEpoch}',
      conversationId: openImConversationId,
      senderId: currentUser.userId,
      receiverId: receiverId,
      content: content.trim(),
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
    );

    await _chatState.sendMessage(message);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SEND VOICE NOTE  ← NEW
  //
  // Called by the UI after flutter_sound finishes recording.
  //
  // Parameters:
  //   filePath        — absolute local path to the .aac / .m4a file
  //                     (comes directly from flutter_sound's recorder)
  //   durationSeconds — length of the recording in whole seconds
  //
  // The method delegates to ChatService.sendVoiceMessage() which handles
  // the OpenIM upload + delivery. No UI changes required anywhere.
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> sendVoiceMessage({
    required String filePath,
    required int durationSeconds,
  }) async {
    await _chatService.sendVoiceMessage(
      receiverID: receiverId,
      filePath: filePath,
      durationSeconds: durationSeconds,
      senderName: currentUser.username.isNotEmpty
          ? currentUser.username
          : 'New voice message',
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // IS MINE — used by message_bubble.dart for bubble alignment
  // ─────────────────────────────────────────────────────────────────────────
  bool isMine(ChatMessage message) {
    return message.senderId == currentUser.userId;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DISPOSE
  // ─────────────────────────────────────────────────────────────────────────
  void dispose() {
    _chatState.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PRIVATE HELPERS
  // ─────────────────────────────────────────────────────────────────────────

  String? _cachedConversationId;

  Future<String> _resolveConversationId() async {
    if (_cachedConversationId != null) return _cachedConversationId!;

    try {
      final ConversationInfo conv = await OpenIM
          .iMManager
          .conversationManager
          .getOneConversation(
            sourceID: receiverId,
            sessionType: ConversationType.single,
          );
      _cachedConversationId = conv.conversationID ?? conversationId;
    } catch (_) {
      _cachedConversationId = conversationId;
    }

    return _cachedConversationId!;
  }
}
