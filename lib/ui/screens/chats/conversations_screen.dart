import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/chat/chat_service.dart';
import 'package:wrytte/services/contacts/contact_service.dart';
import 'package:wrytte/ui/screens/chats/chat_screen.dart';
import 'package:wrytte/ui/screens/chats/widgets/conversation_tile.dart';
import 'package:wrytte/ui/screens/chats/widgets/mini_chat_window.dart';
import 'package:wrytte/ui/screens/chats/widgets/top_bar.dart';
import 'package:wrytte/ui/screens/firebase_new_chat_screen.dart';
import 'widgets/search_bar.dart' as local_widgets;
import 'widgets/tab_bar_section.dart';

// =============================================================================
//  ConversationsScreen
//
//  Reads conversation list from OpenIM SDK's local SQLite cache via ChatService.
//  No Firebase reads for conversations — only for user display names/avatars
//  (enrichment step, runs once per unknown user).
//
//  Data flow:
//    1. ChatService.connect() → OpenIM SDK loads conversations from its SQLite
//    2. _conversationsStream emits the list → UI updates instantly
//    3. Enrichment: unknown display names are resolved from Firestore /users
//       and stored in memory for the session.
//    4. OpenIM real-time listener keeps the list live via ChatService.
// =============================================================================

const double _kSearchBarHeight = 60.0;
const double _kTabBarHeight    = 56.0;

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
  final ChatService _chat = ChatService();

  List<ChatConversation> _conversations = [];

  String _currentUserId = '';
  bool   _isSelectionMode = false;
  final Set<String> _selectedIds = {};

  StreamSubscription<List<ChatConversation>>? _convSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  final ScrollController _scrollCtrl   = ScrollController();
  double _searchBarProgress = 0.0;

  // Display name/avatar cache resolved from Firestore (session-only)
  final Map<String, String>  _nameCache   = {};
  final Map<String, String?> _avatarCache = {};

  // ===========================================================================
  //  LIFECYCLE
  // ===========================================================================

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    Future.microtask(_initialize);
  }

  @override
  void dispose() {
    _convSub?.cancel();
    _connectivitySub?.cancel();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    final progress =
        (_scrollCtrl.offset / _kSearchBarHeight).clamp(0.0, 1.0);
    if ((progress - _searchBarProgress).abs() > 0.005) {
      setState(() => _searchBarProgress = progress);
    }
  }

  // ===========================================================================
  //  INITIALIZE
  // ===========================================================================

  Future<void> _initialize() async {
    _currentUserId = widget.currentUserId.isNotEmpty
        ? widget.currentUserId
        : await AuthService.instance.getCurrentUserId() ?? '';

    if (_currentUserId.isEmpty) return;

    // Pre-warm contact cache for FirebaseNewChatScreen
    ContactService.preloadContacts(_currentUserId, ContactService());

    // Connect ChatService (idempotent — safe to call multiple times)
    await _chat.connect();

    // Subscribe to the OpenIM conversation stream from ChatService
    _convSub = _chat.conversationsStream.listen((incoming) async {
      // Enrich any conversations that are missing display names
      final enriched = await _enrichNames(incoming);
      if (!mounted) return;
      setState(() {
        _conversations = enriched;
      });
      _notifyUnread(_conversations);
    });

    // Retry name enrichment when connectivity is restored
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNet = results.any((r) => r != ConnectivityResult.none);
      if (hasNet) _retryEnrichment();
    });
  }

  // ===========================================================================
  //  ENRICHMENT
  //  Resolves display names from Firestore /users for conversations where
  //  OpenIM only has a userID (no nickname set yet).
  //  Results are cached in _nameCache so Firestore is only hit once per user.
  // ===========================================================================

  Future<List<ChatConversation>> _enrichNames(
    List<ChatConversation> convs,
  ) async {
    // IDs we haven't resolved yet
    final unknownIds = convs
        .where((c) =>
            c.otherUserId.isNotEmpty &&
            c.otherUserName == null &&
            !_nameCache.containsKey(c.otherUserId))
        .map((c) => c.otherUserId)
        .toSet()
        .toList();

    if (unknownIds.isEmpty) {
      // Apply cached names to any convs still missing them
      return _applyCache(convs);
    }

    const chunk = 10;
    for (int i = 0; i < unknownIds.length; i += chunk) {
      final slice = unknownIds.sublist(
          i, (i + chunk).clamp(0, unknownIds.length));

      try {
        // Doc-ID lookup (phone-digit UIDs used by OpenIM)
        final snap = await FirebaseFirestore.instance
            .collection('users')
            .where(FieldPath.documentId, whereIn: slice)
            .get();

        for (final doc in snap.docs) {
          final data   = doc.data();
          final name   = _resolveName(data);
          final avatar = data['profileImage']?.toString() ??
              data['photoUrl']?.toString();
          _nameCache[doc.id]   = name;
          _avatarCache[doc.id] = avatar?.isNotEmpty == true ? avatar : null;
        }
      } catch (e) {
        debugPrint('[ConversationsScreen] enrichment error: $e');
      }
    }

    return _applyCache(convs);
  }

  List<ChatConversation> _applyCache(List<ChatConversation> convs) {
    return convs.map((c) {
      if (_nameCache.containsKey(c.otherUserId)) {
        return c.copyWith(
          otherUserName:   _nameCache[c.otherUserId],
          otherUserAvatar: _avatarCache[c.otherUserId],
        );
      }
      return c;
    }).toList();
  }

  String _resolveName(Map<String, dynamic> data) {
    bool isPhone(String v) {
      final s = v.replaceAll(RegExp(r'[\s\-()]'), '');
      return s.startsWith('+') || RegExp(r'^\d{7,}$').hasMatch(s);
    }

    final name = data['name']?.toString() ?? '';
    if (name.isNotEmpty && !isPhone(name)) return name;

    final username = data['username']?.toString() ?? '';
    if (username.isNotEmpty && !isPhone(username)) return username;

    final phone = data['phone']?.toString() ?? '';
    if (phone.isNotEmpty) return phone;

    return data['uid']?.toString() ?? 'Unknown';
  }

  Future<void> _retryEnrichment() async {
    final needsEnrich =
        _conversations.where((c) => c.otherUserName == null).toList();
    if (needsEnrich.isEmpty) return;

    final enriched = await _enrichNames(_conversations);
    if (mounted) setState(() => _conversations = enriched);
  }

  // ===========================================================================
  //  HELPERS
  // ===========================================================================

  void _notifyUnread(List<ChatConversation> convs) {
    final total = convs.fold(0, (sum, c) => sum + c.unreadCount);
    widget.onUnreadCountUpdated?.call(total);
  }

  String _sanitize(String s) => String.fromCharCodes(
      s.runes.where((r) => r <= 0xD7FF || r >= 0xE000));

  void _enterSelection() =>
      setState(() { _isSelectionMode = true; _selectedIds.clear(); });
  void _exitSelection() =>
      setState(() { _isSelectionMode = false; _selectedIds.clear(); });
  void _toggleSelection(String id) => setState(() {
    if (_selectedIds.contains(id)) _selectedIds.remove(id);
    else _selectedIds.add(id);
  });

  void _onPin()        => debugPrint('Pin: ${_selectedIds.toList()}');
  void _onMarkAsRead() => debugPrint('MarkAsRead: ${_selectedIds.toList()}');
  void _onMute()       => debugPrint('Mute: ${_selectedIds.toList()}');
  void _onArchive()    => debugPrint('Archive: ${_selectedIds.toList()}');
  void _onDelete()     => debugPrint('Delete: ${_selectedIds.toList()}');

  String _formatTime(DateTime dt) {
    final now  = DateTime.now();
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

  // ===========================================================================
  //  CONVERSATION TILE
  // ===========================================================================

  Widget _buildTile(ChatConversation conv) {
    final name     = _sanitize(conv.otherUserName ?? conv.otherUserId);
    final avatar   = conv.otherUserAvatar;
    final selected = _selectedIds.contains(conv.id);

    return ConversationTile(
      name: name,
      lastMessage: conv.lastMessage.isEmpty
          ? 'Say hello! 👋'
          : _sanitize(conv.lastMessage),
      time: _formatTime(conv.lastMessageTime),
      avatarUrl: avatar,
      unreadCount: conv.unreadCount,
      isSelectionMode: _isSelectionMode,
      isSelected: selected,
      onSelectionToggle: () => _toggleSelection(conv.id),
      onLongPress: () {
        showGeneralDialog(
          context: context,
          barrierDismissible: true,
          barrierLabel: 'Preview',
          barrierColor: Colors.transparent,
          pageBuilder: (_, __, ___) => MiniChatPreview(
            conversationId: conv.id,
            name: name,
            avatarUrl: avatar,
            currentUserId: _currentUserId,
            receiverId: conv.otherUserId,
          ),
        );
      },
      onTap: () async {
        if (_isSelectionMode) {
          _toggleSelection(conv.id);
          return;
        }

        // Mark as read via OpenIM (updates local SQLite + server)
        await _chat.markConversationAsRead(conv.id);

        if (mounted) {
          setState(() {
            _conversations = _conversations
                .map((c) => c.id == conv.id
                    ? c.copyWith(unreadCount: 0)
                    : c)
                .toList();
          });
          _notifyUnread(_conversations);
        }

        if (!mounted) return;

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              conversationId: conv.id,
              receiverId:     conv.otherUserId,
              currentUserId:  _currentUserId,
              title:          name,
              avatarUrl:      avatar,
            ),
          ),
        );
      },
    );
  }

  // ===========================================================================
  //  BUILD
  // ===========================================================================

  Widget _buildChatsTab(double topPadding) {
    if (_conversations.isEmpty) {
      return ListView(
        controller: _scrollCtrl,
        padding: EdgeInsets.only(top: topPadding, bottom: 120),
        physics: const BouncingScrollPhysics(),
        children: [
          const SizedBox(height: 60),
          Center(
            child: Column(
              children: [
                Icon(Icons.chat_bubble_outline_rounded,
                    size: 64, color: Colors.white.withOpacity(0.12)),
                const SizedBox(height: 16),
                Text('No conversations yet',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.35),
                        fontSize: 16,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 8),
                Text('Tap the pencil icon to start a new chat',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.2), fontSize: 13)),
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
        // Re-fetch from OpenIM local SQLite + server sync
        await _chat.fetchConversations();
        await _retryEnrichment();
      },
      child: ListView.builder(
        controller: _scrollCtrl,
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.only(top: topPadding, bottom: 120),
        itemCount: _conversations.length,
        itemBuilder: (_, i) => _buildTile(_conversations[i]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double statusBarH  = MediaQuery.of(context).padding.top;
    final double bottomInset = MediaQuery.of(context).padding.bottom;
    final double headerH = statusBarH +
        kToolbarHeight +
        _kSearchBarHeight +
        _kTabBarHeight +
        8.0;

    final double searchBarOffset = _kSearchBarHeight * _searchBarProgress;
    final double gradientH = headerH - searchBarOffset;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      extendBodyBehindAppBar: true,
      floatingActionButton: _isSelectionMode
          ? null
          : Padding(
              padding: EdgeInsets.only(bottom: bottomInset + 80.0),
              child: FloatingActionButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const FirebaseNewChatScreen()),
                ),
                backgroundColor: const Color(0xFF4DA3FF),
                child: const Icon(Icons.edit_square, color: Colors.black),
              ),
            ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: DefaultTabController(
        length: 3,
        child: Stack(
          children: [
            // ── Tab content ──────────────────────────────────────────────
            Positioned.fill(
              child: TabBarView(
                children: [
                  _buildChatsTab(headerH),
                  Center(
                    child: Padding(
                      padding: EdgeInsets.only(top: headerH),
                      child: const Text('Channels coming soon',
                          style: TextStyle(color: Colors.grey)),
                    ),
                  ),
                  Center(
                    child: Padding(
                      padding: EdgeInsets.only(top: headerH),
                      child: const Text('Groups coming soon',
                          style: TextStyle(color: Colors.grey)),
                    ),
                  ),
                ],
              ),
            ),

            // ── Gradient ─────────────────────────────────────────────────
            Positioned(
              top: 0, left: 0, right: 0,
              height: gradientH,
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

            // ── Sticky header ─────────────────────────────────────────────
            Positioned(
              top: 0, left: 0, right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TopBar(
                    isSelectionMode: _isSelectionMode,
                    selectedCount: _selectedIds.length,
                    onEditPressed: _enterSelection,
                    onSelectionClose: _exitSelection,
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
