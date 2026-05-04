import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:wrytte/components/user_avatar.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/models/user_models/user_profile_service.dart';
import 'package:wrytte/services/call_service.dart';
import 'package:wrytte/services/chat/chat_local_db.dart';
import 'package:wrytte/services/chat/firebase_chat_service.dart';
import 'package:wrytte/services/user/user_profile_service.dart';
import 'package:wrytte/state/chat/chat_state.dart';
import 'package:wrytte/ui/screens/calls/call_screen.dart';
import 'package:wrytte/ui/screens/calls/calls_screen.dart';
import 'package:wrytte/ui/screens/chats/widgets/message_bubble.dart';
import 'package:wrytte/ui/screens/chats/widgets/message_input.dart';
import 'package:wrytte/ui/screens/profile_screen.dart';

class ChatScreen extends StatefulWidget {
  final String conversationId;
  final String receiverId;
  final String currentUserId;
  final String title;
  final ChatState? chatState;
  final String? avatarUrl;

  const ChatScreen({
    super.key,
    required this.conversationId,
    required this.receiverId,
    required this.currentUserId,
    required this.title,
    this.chatState,
    this.avatarUrl,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  late final FirebaseChatService _firebaseChat;
  StreamSubscription<List<ChatMessage>>? _messagesSub;
  final List<ChatMessage> _firebaseMessages = [];
  final ChatLocalDb _localDb = ChatLocalDb.instance;

  final CallService _callService = CallService.instance;

  UserProfile? _receiverProfile;

  bool get _isFirebaseMode =>
      widget.chatState == null && widget.currentUserId.isNotEmpty;

  bool _isSending = false;

  static const double _kHeaderPillHeight = 48.0;
  static const double _kInputPillHeight  = 40.0;

  @override
  void initState() {
    super.initState();
    if (_isFirebaseMode) {
      _initFirebase();
    } else if (widget.chatState != null) {
      _initLegacyChat();
    }
    _loadReceiverProfile();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  Future<void> _loadReceiverProfile() async {
    final profile = await UserProfileService.instance.getProfileByUid(
      widget.receiverId,
    );
    if (mounted) setState(() => _receiverProfile = profile);
  }

  Future<void> _initFirebase() async {
    _firebaseChat = FirebaseChatService();
    await _firebaseChat.connect();
    await _firebaseChat.ensureConversation(widget.receiverId);
    await _firebaseChat.markConversationAsRead(widget.conversationId);
    await _localDb.markConversationRead(widget.conversationId);

    final cached = await _localDb.loadMessages(widget.conversationId);
    if (mounted && cached.isNotEmpty) {
      setState(() {
        _firebaseMessages
          ..clear()
          ..addAll(cached);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }

    _messagesSub = _firebaseChat
        .getMessagesStream(widget.conversationId)
        .listen((messages) async {
          await _localDb.saveMessages(messages);
          if (!mounted) return;
          setState(() {
            _firebaseMessages
              ..clear()
              ..addAll(messages);
          });
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scrollToBottom(),
          );
        });
  }

  Future<void> _initLegacyChat() async {
    await widget.chatState!.initialize();
    await widget.chatState!.loadConversation(widget.conversationId);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  // ── Send text ──────────────────────────────────────────────────────────────

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;

    _controller.clear();

    if (_isFirebaseMode) {
      setState(() => _isSending = true);
      try {
        final message = ChatMessage(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          conversationId: widget.conversationId,
          senderId: widget.currentUserId,
          receiverId: widget.receiverId,
          content: text,
          timestamp: DateTime.now(),
          status: MessageStatus.sending,
        );
        await _localDb.saveMessage(message);
        if (mounted) {
          setState(() => _firebaseMessages.add(message));
          Future.delayed(const Duration(milliseconds: 80), _scrollToBottom);
        }
        await _firebaseChat.sendMessage(message);
      } catch (e) {
        debugPrint('Send error: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to send: $e'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      } finally {
        if (mounted) setState(() => _isSending = false);
      }
      return;
    }

    // Legacy path
    final message = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      conversationId: widget.conversationId,
      senderId: widget.currentUserId,
      receiverId: widget.receiverId,
      content: text,
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
    );
    widget.chatState!.sendMessage(message);
    Future.delayed(const Duration(milliseconds: 80), _scrollToBottom);
  }

  // ── Send voice note ────────────────────────────────────────────────────────

  Future<void> _sendVoiceNote(String filePath, int durationSeconds) async {
    if (!_isFirebaseMode) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Voice notes are only supported in the new chat mode',
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }

    final placeholderId = 'voice_${DateTime.now().millisecondsSinceEpoch}';
    final placeholder = ChatMessage(
      id: placeholderId,
      conversationId: widget.conversationId,
      senderId: widget.currentUserId,
      receiverId: widget.receiverId,
      content: '',
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
      attachmentType: 'voice',
      voiceDuration: durationSeconds,
    );

    if (mounted) {
      setState(() => _firebaseMessages.add(placeholder));
      Future.delayed(const Duration(milliseconds: 80), _scrollToBottom);
    }

    try {
      final sent = await _firebaseChat.sendVoiceMessage(
        receiverId: widget.receiverId,
        filePath: filePath,
        durationSeconds: durationSeconds,
        conversationId: widget.conversationId,
      );

      if (mounted) {
        setState(() {
          final idx =
              _firebaseMessages.indexWhere((m) => m.id == placeholderId);
          if (idx != -1) _firebaseMessages[idx] = sent;
        });
      }
      await _localDb.saveMessage(sent);
    } catch (e) {
      debugPrint('Voice send error: $e');
      if (mounted) {
        setState(() {
          _firebaseMessages.removeWhere((m) => m.id == placeholderId);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send voice note: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  // ── Start a call ───────────────────────────────────────────────────────────

  Future<void> _startCall(CallType type) async {
    final displayName = _receiverProfile?.displayName ?? widget.title;
    //final myName = FirebaseAuth.instance.currentUser?.displayName ??
        //widget.currentUserId;
    //final myAvatar = FirebaseAuth.instance.currentUser?.photoURL ?? '';

    final myName = widget.currentUserId; // or load from UserProfileService
    final myAvatar = '';

    try {
      await _callService.makeCall(
        receiverId:    widget.receiverId,
        type:          type,
        callerName:    myName,
        callerAvatar:  myAvatar,
      );

      if (!mounted) return;

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CallScreen(
            remoteUserId:     widget.receiverId,
            remoteUserName:   displayName,
            remoteUserAvatar: _receiverProfile?.hasProfileImage == true
                ? _receiverProfile!.profileImage
                : widget.avatarUrl,
            type:     type,
            isCaller: true,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Start call error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not start call: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _messagesSub?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final double statusBarHeight = MediaQuery.of(context).padding.top;
    final double appBarHeight    = statusBarHeight + kToolbarHeight;

    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      extendBodyBehindAppBar: true,
      extendBody: true,
      body: Stack(
        children: [
          // ── Layer 1: message list + input ────────────────────────────
          Column(
            children: [
              SizedBox(height: appBarHeight),
              Expanded(child: _buildMessageList()),
              MessageInputField(
                controller: _controller,
                focusNode: _focusNode,
                isSending: _isSending,
                onSend: _send,
                inputPillHeight: _kInputPillHeight,
                onVoiceMessage: _sendVoiceNote,
              ),
            ],
          ),

          // ── Layer 2: top gradient scrim ───────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: appBarHeight + 20,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.6, 1.0],
                    colors: [
                      const Color(0xFF08090B).withOpacity(0.95),
                      const Color(0xFF08090B).withOpacity(0.75),
                      const Color(0xFF08090B).withOpacity(0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── Layer 3: app bar ──────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildAppBar(statusBarHeight),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    if (_isFirebaseMode) return _buildFirebaseMessages();
    return _buildLegacyMessages();
  }

  // ── App bar ────────────────────────────────────────────────────────────────

  Widget _buildAppBar(double statusBarHeight) {
    final String displayName =
        _receiverProfile?.displayName ?? widget.title;

    return Padding(
      padding: EdgeInsets.only(top: statusBarHeight),
      child: SizedBox(
        height: kToolbarHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // ── Back pill ────────────────────────────────────────────
              _glassPill(
                width: _kHeaderPillHeight,
                height: _kHeaderPillHeight,
                child: const Icon(
                  Icons.arrow_back_ios_new,
                  color: Colors.white,
                  size: 16,
                ),
                onTap: () => Navigator.pop(context),
              ),

              const SizedBox(width: 8),

              // ── Name + avatar pill ────────────────────────────────────
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            ProfileScreen(uid: widget.receiverId),
                      ),
                    );
                  },
                  child: SizedBox(
                    height: _kHeaderPillHeight,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(24),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(
                                sigmaX: 24,
                                sigmaY: 24,
                              ),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFF23262C,
                                  ).withOpacity(0.30),
                                  borderRadius: BorderRadius.circular(24),
                                  border: Border.all(
                                    color: const Color(0xFF23262C),
                                    width: 1.0,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 2,
                          top: -2,
                          bottom: -2,
                          child: AspectRatio(
                            aspectRatio: 1,
                            child: UserAvatar(
                              size: _kHeaderPillHeight + 12,
                              imageUrl:
                                  _receiverProfile?.hasProfileImage == true
                                      ? _receiverProfile!.profileImage
                                      : widget.avatarUrl,
                              name: displayName,
                            ),
                          ),
                        ),
                        Positioned(
                          left: _kHeaderPillHeight + 14,
                          top: 0,
                          bottom: 0,
                          right: 12,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                displayName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                'Online',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.5),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 8),

              // ── Video call pill ───────────────────────────────────────
              _glassPill(
                width: _kHeaderPillHeight,
                height: _kHeaderPillHeight,
                child: const Icon(
                  Icons.videocam_outlined,
                  color: Colors.white,
                  size: 20,
                ),
                onTap: () => _startCall(CallType.video),
              ),

              const SizedBox(width: 8),

              // ── Voice call pill ───────────────────────────────────────
              _glassPill(
                width: _kHeaderPillHeight,
                height: _kHeaderPillHeight,
                child: const Icon(
                  Icons.call_outlined,
                  color: Colors.white,
                  size: 20,
                ),
                onTap: () => _startCall(CallType.voice),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Firebase messages ──────────────────────────────────────────────────────

  Widget _buildFirebaseMessages() {
    if (_firebaseMessages.isEmpty) {
      return Center(
        child: Text(
          'No messages yet.\nSay hello! 👋',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withOpacity(0.3),
            fontSize: 15,
            height: 1.6,
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      physics: const BouncingScrollPhysics(),
      itemCount: _firebaseMessages.length,
      itemBuilder: (context, index) {
        final msg    = _firebaseMessages[index];
        final isMine = msg.senderId == widget.currentUserId;
        final prev   = index > 0 ? _firebaseMessages[index - 1] : null;
        final showTail = prev == null ||
            (prev.senderId == widget.currentUserId) != isMine;
        return Column(
          children: [
            if (index == 0) _buildDateDivider('Today'),
            MessageBubble(
              content:      msg.content,
              time:         _formatTime(msg.timestamp),
              isMine:       isMine,
              showTail:     showTail,
              status:       isMine ? msg.status : null,
              isVoiceNote:  msg.isVoiceNote,
              voiceDuration: msg.voiceDuration,
              audioUrl:     msg.attachmentUrl,
            ),
          ],
        );
      },
    );
  }

  // ── Legacy messages ────────────────────────────────────────────────────────

  Widget _buildLegacyMessages() {
    return StreamBuilder<List<ChatMessage>>(
      stream: widget.chatState!.messagesStream,
      builder: (context, snapshot) {
        final messages = (snapshot.data ?? [])
            .where((m) => m.conversationId == widget.conversationId)
            .toList();
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _scrollToBottom(),
        );
        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.only(top: 12, bottom: 8),
          physics: const BouncingScrollPhysics(),
          itemCount: messages.length,
          itemBuilder: (context, index) {
            final msg    = messages[index];
            final isMine = msg.senderId == widget.currentUserId;
            final prev   = index > 0 ? messages[index - 1] : null;
            final showTail = prev == null ||
                (prev.senderId == widget.currentUserId) != isMine;
            return Column(
              children: [
                if (index == 0) _buildDateDivider('Today'),
                MessageBubble(
                  content:  msg.content,
                  time:     _formatTime(msg.timestamp),
                  isMine:   isMine,
                  showTail: showTail,
                  status:   isMine ? msg.status : null,
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _formatTime(DateTime dt) {
    final h      = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m      = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $period';
  }

  // ── Date divider ───────────────────────────────────────────────────────────

  Widget _buildDateDivider(String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Divider(
              color: Colors.white.withOpacity(0.08),
              height: 1,
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF23262C).withOpacity(0.60),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Divider(
              color: Colors.white.withOpacity(0.08),
              height: 1,
            ),
          ),
        ],
      ),
    );
  }

  // ── Shared glass pill ──────────────────────────────────────────────────────

  Widget _glassPill({
    required double width,
    required double height,
    required Widget child,
    VoidCallback? onTap,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: const Color(0xFF23262C).withOpacity(0.30),
              borderRadius: BorderRadius.circular(height / 2),
              border: Border.all(
                color: const Color(0xFF23262C),
                width: 1.0,
              ),
            ),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}
