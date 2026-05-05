import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/chat/chat_local_db.dart';
import 'package:wrytte/services/chat/firebase_chat_service.dart';
import 'package:wrytte/ui/screens/chats/chat_screen.dart';
import 'package:wrytte/ui/screens/chats/widgets/mini_chat_window.dart';
import 'package:wrytte/ui/screens/chats/widgets/top_bar.dart';
import 'package:wrytte/ui/screens/chats/widgets/conversation_tile.dart';
import 'package:wrytte/ui/screens/firebase_new_chat_screen.dart';
import 'widgets/search_bar.dart' as local_widgets;
import 'widgets/tab_bar_section.dart';
import 'package:wrytte/services/contacts/contact_service.dart';

const double _kSearchBarHeight = 60.0;
const double _kTabBarHeight = 56.0;

class ConversationsScreen extends StatefulWidget {
  final Function(int)? onUnreadCountUpdated;
  final String currentUserId;

  const ConversationsScreen({
    super.key,
    this.onUnreadCountUpdated,
    this.currentUserId = '',
  });

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  bool _isSyncing = false;

  final FirebaseChatService _firebaseChat = FirebaseChatService();
  final ChatLocalDb _localDb = ChatLocalDb.instance;

  List<ChatConversation> _conversations = [];

  bool _isSelectionMode = false;
  final Set<String> _selectedIds = {};

  String _currentUserId = '';
  StreamSubscription<List<ChatConversation>>? _conversationsSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  final ScrollController _scrollController = ScrollController();
  double _searchBarProgress = 0.0;

  // ── Strips lone surrogates (invalid UTF-16) that crash the text renderer ──
  String _sanitize(String s) {
    return String.fromCharCodes(
      s.runes.where((r) => r <= 0xD7FF || r >= 0xE000),
    );
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    Future.microtask(() => _initialize());
  }

  void _onScroll() {
    final offset = _scrollController.offset;
    final progress = (offset / _kSearchBarHeight).clamp(0.0, 1.0);
    if ((progress - _searchBarProgress).abs() > 0.005) {
      setState(() => _searchBarProgress = progress);
    }
  }

  Future<void> _initialize() async {
    _currentUserId = await AuthService.instance.getCurrentUserId() ?? '';

    if (_currentUserId.isEmpty) return;

    // Load cached conversations immediately so UI shows something
    final cached = (await _localDb.loadConversations()).map((c) => c.copyWith(
      otherUserName: c.otherUserName != null ? _sanitize(c.otherUserName!) : null,
      otherUserAvatar: c.otherUserAvatar,
    )).toList();
    if (mounted && cached.isNotEmpty) {
      setState(() => _conversations = cached);
      _notifyUnread(cached);
    }

    // Pre-warm contact cache so FirebaseNewChatScreen opens instantly
    ContactService.preloadContacts(_currentUserId, ContactService());

    // Listen for connectivity changes and retry enrichment when back online
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasConnection = results.any((r) => r != ConnectivityResult.none);
      if (hasConnection) {
        _retryEnrichmentIfNeeded();
      }
    });

    try {
      await _firebaseChat.connect(userId: _currentUserId);

      // Single subscription — merge incoming with existing, never replace
      _conversationsSub =
          _firebaseChat.conversationsStream.listen((incoming){
        //final enriched = await _enrichWithUserInfo(incoming);
        final enriched = incoming;

        if (!mounted) return;

        setState(() {
          // Build a map of the freshly enriched conversations
          final freshById = {for (final c in enriched) c.id: c};

          // Update existing conversations with fresh data, preserving names
          final updated = _conversations.map((existing) {
            final fresh = freshById[existing.id];
            if (fresh == null) return existing;
            return fresh.copyWith(
              otherUserName: fresh.otherUserName ?? existing.otherUserName,
              otherUserAvatar:
                  fresh.otherUserAvatar ?? existing.otherUserAvatar,
            );
          }).toList();

          // Add brand-new conversations not yet in the list
          final existingIds = _conversations.map((c) => c.id).toSet();
          final newOnes =
              enriched.where((c) => !existingIds.contains(c.id)).toList();

          _conversations = [...updated, ...newOnes];
          _isSyncing = false;
        });

        _notifyUnread(_conversations);
        await _localDb.saveConversations(_conversations);
      });
    } catch (e) {
      debugPrint('ConversationsScreen Firebase error: $e');
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  /// Retry enrichment for conversations that still have no name.
  /// Called automatically when connectivity is restored.
  Future<void> _retryEnrichmentIfNeeded() async {
    final needsEnrichment =
        _conversations.where((c) => c.otherUserName == null).toList();
    if (needsEnrichment.isEmpty) return;

    debugPrint('[ENRICH] Retrying for ${needsEnrichment.length} conversations');
    final enriched = await _enrichWithUserInfo(_conversations);
    if (!mounted) return;

    setState(() {
      _conversations = enriched;
    });
    await _localDb.saveConversations(_conversations);
  }

  Future<List<ChatConversation>> _enrichWithUserInfo(
    List<ChatConversation> conversations,
  ) async {
    final unknownIds = conversations
        .where((c) => c.otherUserId.isNotEmpty && c.otherUserName == null)
        .map((c) => c.otherUserId)
        .toSet()
        .toList();

    debugPrint('[ENRICH] unknownIds: $unknownIds');

    if (unknownIds.isEmpty) return conversations;

    final nameMap = <String, String>{};
    final avatarMap = <String, String?>{};

    const chunkSize = 10; // whereIn limit for field queries is 10

    // ── Step 1: doc ID lookup (phone-digit UIDs) ──────────────────────────
    for (int i = 0; i < unknownIds.length; i += chunkSize) {
      final chunk =
          unknownIds.sublist(i, (i + chunkSize).clamp(0, unknownIds.length));
      try {
        final snap = await FirebaseFirestore.instance
            .collection('users')
            .where(FieldPath.documentId, whereIn: chunk)
            .get();

        debugPrint(
            '[ENRICH] /users doc-id query returned ${snap.docs.length} docs for chunk: $chunk');

        for (final doc in snap.docs) {
          final data = doc.data();
          final name = _resolveDisplayName(data);
          final avatar = data['profileImage']?.toString() ??
              data['photoUrl']?.toString() ??
              data['avatarUrl']?.toString();

          nameMap[doc.id] = name;
          avatarMap[doc.id] = (avatar?.isNotEmpty == true) ? avatar : null;

          final matchingConvs =
              conversations.where((c) => c.otherUserId == doc.id).toList();
          if (matchingConvs.isNotEmpty) {
            await _localDb.updateConversationUserInfo(
              conversationId: matchingConvs.first.id,
              name: name,
              avatar: avatarMap[doc.id],
            );
          }
        }
      } catch (e) {
        debugPrint('[ENRICH] ERROR in doc-id lookup: $e');
      }
    }

    // ── Step 2: field lookup for Firebase Auth UIDs ───────────────────────
    final stillMissingAfterStep1 =
        unknownIds.where((id) => !nameMap.containsKey(id)).toList();

    for (int i = 0; i < stillMissingAfterStep1.length; i += chunkSize) {
      final chunk = stillMissingAfterStep1.sublist(
          i, (i + chunkSize).clamp(0, stillMissingAfterStep1.length));
      try {
        final snap = await FirebaseFirestore.instance
            .collection('users')
            .where('uid', whereIn: chunk)
            .get();

        debugPrint(
            '[ENRICH] /users uid-field query returned ${snap.docs.length} docs for chunk: $chunk');

        for (final doc in snap.docs) {
          final data = doc.data();
          final lookupId = data['uid']?.toString() ?? '';
          if (lookupId.isEmpty) continue;

          final name = _resolveDisplayName(data);
          final avatar = data['profileImage']?.toString() ??
              data['photoUrl']?.toString() ??
              data['avatarUrl']?.toString();

          nameMap[lookupId] = name;
          avatarMap[lookupId] = (avatar?.isNotEmpty == true) ? avatar : null;

          final matchingConvs =
              conversations.where((c) => c.otherUserId == lookupId).toList();
          if (matchingConvs.isNotEmpty) {
            await _localDb.updateConversationUserInfo(
              conversationId: matchingConvs.first.id,
              name: name,
              avatar: avatarMap[lookupId],
            );
          }
        }
      } catch (e) {
        debugPrint('[ENRICH] ERROR in uid-field lookup: $e');
      }
    }

    // ── Step 3: contacts sub-collection fallback ──────────────────────────
    final stillMissing =
        unknownIds.where((id) => !nameMap.containsKey(id)).toList();

    if (stillMissing.isNotEmpty && _currentUserId.isNotEmpty) {
      for (int i = 0; i < stillMissing.length; i += chunkSize) {
        final chunk = stillMissing.sublist(
            i, (i + chunkSize).clamp(0, stillMissing.length));
        try {
          final contactSnap = await FirebaseFirestore.instance
              .collection('users')
              .doc(_currentUserId)
              .collection('contacts')
              .where('wrytteUserId', whereIn: chunk)
              .get();

          for (final doc in contactSnap.docs) {
            final data = doc.data();
            final userId = data['wrytteUserId']?.toString() ?? '';
            if (userId.isEmpty) continue;
            final name = _sanitize(data['displayName']?.toString() ?? '');
            if (name.isEmpty) continue;
            final avatar = data['avatarUrl']?.toString();

            nameMap[userId] = name;
            avatarMap[userId] = (avatar?.isNotEmpty == true) ? avatar : null;

            final matchingConvs =
                conversations.where((c) => c.otherUserId == userId).toList();
            if (matchingConvs.isNotEmpty) {
              await _localDb.updateConversationUserInfo(
                conversationId: matchingConvs.first.id,
                name: name,
                avatar: avatarMap[userId],
              );
            }
          }
        } catch (e) {
          debugPrint('[ENRICH] ERROR in contacts lookup: $e');
        }
      }
    }

    return conversations.map((c) {
      if (nameMap.containsKey(c.otherUserId)) {
        return c.copyWith(
          otherUserName: nameMap[c.otherUserId],
          otherUserAvatar: avatarMap[c.otherUserId],
        );
      }
      return c;
    }).toList();
  }

  String _resolveDisplayName(Map<String, dynamic> data) {
    bool looksLikePhone(String v) {
      final s = v.replaceAll(RegExp(r'[\s\-()]'), '');
      return s.startsWith('+') || RegExp(r'^\d{7,}$').hasMatch(s);
    }

    // 1. Prefer a real name (not phone-shaped) — sanitize before returning
    final name = data['name']?.toString() ?? '';
    if (name.isNotEmpty && !looksLikePhone(name)) return _sanitize(name);

    final username = data['username']?.toString() ?? '';
    if (username.isNotEmpty && !looksLikePhone(username)) {
      return _sanitize(username);
    }

    // 2. Fall back to phone (phone digits are always safe UTF-16)
    final phone = data['phone']?.toString() ?? '';
    if (phone.isNotEmpty) return phone;

    // 3. Last resort: truncated UID
    final uid = data['uid']?.toString() ?? '';
    return uid.isNotEmpty ? uid : 'Unknown';
  }

  void _notifyUnread(List<ChatConversation> conversations) {
    final total = conversations.fold(0, (sum, c) => sum + c.unreadCount);
    widget.onUnreadCountUpdated?.call(total);
  }

  void _enterSelectionMode() => setState(() {
        _isSelectionMode = true;
        _selectedIds.clear();
      });

  void _exitSelectionMode() => setState(() {
        _isSelectionMode = false;
        _selectedIds.clear();
      });

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _onPin() => debugPrint('Pin: ${_selectedIds.toList()}');
  void _onMarkAsRead() => debugPrint('MarkAsRead: ${_selectedIds.toList()}');
  void _onMute() => debugPrint('Mute: ${_selectedIds.toList()}');
  void _onArchive() => debugPrint('Archive: ${_selectedIds.toList()}');
  void _onDelete() => debugPrint('Delete: ${_selectedIds.toList()}');

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final local = dt.toLocal();
    final isToday = local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    if (isToday) {
      final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
      final m = local.minute.toString().padLeft(2, '0');
      return '$h:$m ${local.hour >= 12 ? 'PM' : 'AM'}';
    }
    final yesterday = now.subtract(const Duration(days: 1));
    if (local.year == yesterday.year &&
        local.month == yesterday.month &&
        local.day == yesterday.day) return 'Yesterday';
    if (now.difference(local).inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[local.weekday - 1];
    }
    return '${local.day}/${local.month}/${local.year}';
  }

  Widget _buildConversationItem(ChatConversation conversation) {
    final otherId = conversation.otherUserId;
    // Sanitize name before passing to any text widget
    final name = _sanitize(conversation.otherUserName ?? conversation.otherUserId);
    final avatar = conversation.otherUserAvatar;
    final selected = _selectedIds.contains(conversation.id);

    return ConversationTile(
      name: name,
      lastMessage: conversation.lastMessage.isEmpty
          ? 'Say hello! 👋'
          : _sanitize(conversation.lastMessage),
      time: _formatTime(conversation.lastMessageTime),
      avatarUrl: avatar,
      unreadCount: conversation.unreadCount,
      isSelectionMode: _isSelectionMode,
      isSelected: selected,
      onSelectionToggle: () => _toggleSelection(conversation.id),
      onLongPress: () {
        showGeneralDialog(
          context: context,
          barrierDismissible: true,
          barrierLabel: 'Preview',
          barrierColor: Colors.transparent,
          pageBuilder: (_, __, ___) {
            return MiniChatPreview(
              conversationId: conversation.id,
              name: name,
              avatarUrl: avatar,
              currentUserId: _currentUserId,
              receiverId: otherId,
            );
          },
        );
      },
      onTap: () async {
        if (_isSelectionMode) {
          _toggleSelection(conversation.id);
          return;
        }

        await _localDb.markConversationRead(conversation.id);

        if (mounted) {
          setState(() {
            _conversations = _conversations
                .map((c) =>
                    c.id == conversation.id ? c.copyWith(unreadCount: 0) : c)
                .toList();
          });
          _notifyUnread(_conversations);
        }

        if (!mounted) return;

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              conversationId: conversation.id,
              receiverId: otherId,
              currentUserId: _currentUserId,
              title: name,
              avatarUrl: avatar,
            ),
          ),
        );
      },
    );
  }

  Widget _buildChatsTab(double topPadding) {
    if (_conversations.isEmpty) {
      return ListView(
        controller: _scrollController,
        padding: EdgeInsets.only(top: topPadding, bottom: 120),
        physics: const BouncingScrollPhysics(),
        children: [
          const SizedBox(height: 60),
          Center(
            child: Column(
              children: [
                Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 64,
                  color: Colors.white.withOpacity(0.12),
                ),
                const SizedBox(height: 16),
                Text(
                  'No conversations yet',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.35),
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Tap the pencil icon to start a new chat',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.2),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return RefreshIndicator(
      color: const Color(0xFF4DA3FF),
      backgroundColor: Colors.transparent,
      onRefresh: () async {
        final fresh = (await _localDb.loadConversations()).map((c) => c.copyWith(
        otherUserName: c.otherUserName != null ? _sanitize(c.otherUserName!) : null,
        otherUserAvatar: c.otherUserAvatar,
      )).toList();
      if (mounted) setState(() => _conversations = fresh);
        await _retryEnrichmentIfNeeded();
      },
      child: ListView.builder(
        controller: _scrollController,
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.only(top: topPadding, bottom: 120),
        itemCount: _conversations.length,
        itemBuilder: (_, i) => _buildConversationItem(_conversations[i]),
      ),
    );
  }

  @override
  void dispose() {
    _conversationsSub?.cancel();
    _connectivitySub?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double statusBarHeight = MediaQuery.of(context).padding.top;
    final double bottomInset = MediaQuery.of(context).padding.bottom;
    final double headerHeight = statusBarHeight +
        kToolbarHeight +
        _kSearchBarHeight +
        _kTabBarHeight +
        8.0;
    final double searchBarOffset = _kSearchBarHeight * _searchBarProgress;
    final double gradientHeight = headerHeight - searchBarOffset;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      extendBodyBehindAppBar: true,
      floatingActionButton: _isSelectionMode
          ? null
          : Padding(
              padding: EdgeInsets.only(bottom: bottomInset + 80.0),
              child: FloatingActionButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const FirebaseNewChatScreen(),
                    ),
                  );
                },
                backgroundColor: const Color(0xFF4DA3FF),
                child: const Icon(Icons.edit_square, color: Colors.black),
              ),
            ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: DefaultTabController(
        length: 3,
        child: Stack(
          children: [
            // ── Layer 1: tab content ────────────────────────────────────
            Positioned.fill(
              child: TabBarView(
                children: [
                  _buildChatsTab(headerHeight),
                  Center(
                    child: Padding(
                      padding: EdgeInsets.only(top: headerHeight),
                      child: const Text(
                        'Channels coming soon',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  ),
                  Center(
                    child: Padding(
                      padding: EdgeInsets.only(top: headerHeight),
                      child: const Text(
                        'Groups coming soon',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── Layer 2: gradient ───────────────────────────────────────
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: gradientHeight,
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

            // ── Layer 3: sticky header ──────────────────────────────────
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TopBar(
                    isSelectionMode: _isSelectionMode,
                    selectedCount: _selectedIds.length,
                    onEditPressed: _enterSelectionMode,
                    onSelectionClose: _exitSelectionMode,
                    onMarkAsRead: _onMarkAsRead,
                    onPin: _onPin,
                    onMute: _onMute,
                    onArchive: _onArchive,
                    onDelete: _onDelete,
                  ),
                  Transform.translate(
                    offset: Offset(0, -searchBarOffset),
                    child: Opacity(
                      opacity: (1.0 - _searchBarProgress).clamp(0.0, 1.0),
                      child: SizedBox(
                        height: _kSearchBarHeight,
                        child: local_widgets.SearchBar(),
                      ),
                    ),
                  ),
                  Transform.translate(
                    offset: Offset(0, -searchBarOffset),
                    child: const TabBarSection(),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
