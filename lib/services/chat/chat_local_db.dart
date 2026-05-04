import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';

/// Local SQLite cache — single source of truth for the UI.
/// Firebase syncs into here; the UI only ever reads from here.
class ChatLocalDb {
  ChatLocalDb._();
  static final ChatLocalDb instance = ChatLocalDb._();

  Database? _db;

  Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  // ── Sanitise strings coming out of SQLite ──────────────────────────────────
  // Strips lone surrogates (U+D800–U+DFFF) that crash Flutter's text renderer.
  // Applied to every user-supplied string field on read so bad data stored in
  // previous sessions can never reach a Text widget.
  static String _sanitize(String s) {
    return String.fromCharCodes(
      s.runes.where((r) => r <= 0xD7FF || r >= 0xE000),
    );
  }

  // ── Open / migrate ─────────────────────────────────────────────────────────

  Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'wrytte_chat.db');

    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages (
            id               TEXT PRIMARY KEY,
            conversationId   TEXT NOT NULL,
            senderId         TEXT NOT NULL,
            receiverId       TEXT NOT NULL,
            content          TEXT NOT NULL,
            timestamp        INTEGER NOT NULL,
            status           TEXT NOT NULL,
            attachmentUrl    TEXT,
            attachmentType   TEXT
          )
        ''');

        await db.execute('''
          CREATE INDEX idx_messages_conv
          ON messages (conversationId, timestamp)
        ''');

        await db.execute('''
          CREATE TABLE conversations (
            id                   TEXT PRIMARY KEY,
            participants         TEXT NOT NULL,
            otherUserId          TEXT NOT NULL,
            lastMessage          TEXT NOT NULL,
            lastMessageSenderId  TEXT NOT NULL,
            lastMessageTime      INTEGER NOT NULL,
            unreadCount          INTEGER NOT NULL DEFAULT 0,
            lastMessageType      TEXT NOT NULL DEFAULT 'text',
            isArchived           INTEGER NOT NULL DEFAULT 0,
            isMuted              INTEGER NOT NULL DEFAULT 0,
            isPinned             INTEGER NOT NULL DEFAULT 0,
            otherUserName        TEXT,
            otherUserAvatar      TEXT
          )
        ''');

        await db.execute('''
          CREATE INDEX idx_conversations_time
          ON conversations (lastMessageTime DESC)
        ''');
      },
    );
  }

  // ── Messages ───────────────────────────────────────────────────────────────

  /// Insert or replace a batch of messages in a single transaction.
  Future<void> saveMessages(List<ChatMessage> messages) async {
    if (messages.isEmpty) return;
    final database = await db;
    final batch = database.batch();

    for (final m in messages) {
      batch.insert('messages', {
        'id': m.id,
        'conversationId': m.conversationId,
        'senderId': m.senderId,
        'receiverId': m.receiverId,
        'content': m.content,
        'timestamp': m.timestamp.millisecondsSinceEpoch,
        'status': m.status.name,
        'attachmentUrl': m.attachmentUrl,
        'attachmentType': m.attachmentType,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    await batch.commit(noResult: true);
  }

  /// Save a single message — used on optimistic send and on receive.
  Future<void> saveMessage(ChatMessage message) => saveMessages([message]);

  /// Load all messages for a conversation, oldest first.
  Future<List<ChatMessage>> loadMessages(String conversationId) async {
    final database = await db;
    final rows = await database.query(
      'messages',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
      orderBy: 'timestamp ASC',
    );
    return rows.map(_rowToMessage).toList();
  }

  ChatMessage _rowToMessage(Map<String, dynamic> row) {
    return ChatMessage(
      id: row['id'] as String,
      conversationId: row['conversationId'] as String,
      senderId: row['senderId'] as String,
      receiverId: row['receiverId'] as String,
      content: _sanitize(row['content'] as String),
      timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
      status: MessageStatus.values.firstWhere(
        (s) => s.name == row['status'],
        orElse: () => MessageStatus.sent,
      ),
      attachmentUrl: row['attachmentUrl'] as String?,
      attachmentType: row['attachmentType'] as String?,
    );
  }

  // ── Conversations ──────────────────────────────────────────────────────────

  /// Upsert a list of conversations — preserves cached name/avatar if already stored.
  Future<void> saveConversations(List<ChatConversation> conversations) async {
    if (conversations.isEmpty) return;
    final database = await db;

    for (final c in conversations) {
      // Read existing row so we don't overwrite a cached name/avatar with null
      final existing = await database.query(
        'conversations',
        where: 'id = ?',
        whereArgs: [c.id],
        limit: 1,
      );

      final existingName =
          existing.isNotEmpty
              ? existing.first['otherUserName'] as String?
              : null;
      final existingAvatar =
          existing.isNotEmpty
              ? existing.first['otherUserAvatar'] as String?
              : null;

      await database.insert('conversations', {
        'id': c.id,
        'participants': c.participants.join(','),
        'otherUserId': c.otherUserId,
        'lastMessage': c.lastMessage,
        'lastMessageSenderId': c.lastMessageSenderId,
        'lastMessageTime': c.lastMessageTime.millisecondsSinceEpoch,
        'unreadCount': c.unreadCount,
        'lastMessageType': c.lastMessageType,
        'isArchived': c.isArchived ? 1 : 0,
        'isMuted': c.isMuted ? 1 : 0,
        'isPinned': c.isPinned ? 1 : 0,
        // Keep existing cached name/avatar — don't overwrite with null
        'otherUserName': c.otherUserName ?? existingName,
        'otherUserAvatar': c.otherUserAvatar ?? existingAvatar,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// Update name + avatar for a conversation after a Firestore /users lookup.
  Future<void> updateConversationUserInfo({
    required String conversationId,
    required String name,
    String? avatar,
  }) async {
    final database = await db;
    await database.update(
      'conversations',
      {'otherUserName': name, 'otherUserAvatar': avatar},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  /// Load all conversations from SQLite, newest first.
  /// Names and last messages are sanitized on read to strip any bad UTF-16
  /// that may have been written by a previous version of the app.
  Future<List<ChatConversation>> loadConversations() async {
    final database = await db;
    final rows = await database.query(
      'conversations',
      orderBy: 'lastMessageTime DESC',
    );
    return rows.map(_rowToConversation).toList();
  }

  ChatConversation _rowToConversation(Map<String, dynamic> row) {
    final participantsRaw = row['participants'] as String? ?? '';
    final participants =
        participantsRaw.isNotEmpty ? participantsRaw.split(',') : <String>[];

    // Sanitize every user-supplied text field to strip lone surrogates
    final rawName = row['otherUserName'] as String?;
    final rawLastMessage = row['lastMessage'] as String;

    return ChatConversation(
      id: row['id'] as String,
      participants: participants,
      otherUserId: row['otherUserId'] as String,
      lastMessage: _sanitize(rawLastMessage),
      lastMessageSenderId: row['lastMessageSenderId'] as String? ?? '',
      lastMessageTime: DateTime.fromMillisecondsSinceEpoch(
        row['lastMessageTime'] as int,
      ),
      unreadCount: row['unreadCount'] as int,
      lastMessageType: row['lastMessageType'] as String? ?? 'text',
      isArchived: (row['isArchived'] as int? ?? 0) == 1,
      isMuted: (row['isMuted'] as int? ?? 0) == 1,
      isPinned: (row['isPinned'] as int? ?? 0) == 1,
      otherUserName: rawName != null ? _sanitize(rawName) : null,
      otherUserAvatar: row['otherUserAvatar'] as String?,
    );
  }

  // ── Mark conversation as read ──────────────────────────────────────────────

  Future<void> markConversationRead(String conversationId) async {
    final database = await db;
    await database.update(
      'conversations',
      {'unreadCount': 0},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  // ── Clear cached user names — call once to flush stale data ───────────────

  Future<void> clearConversationUserNames() async {
    final database = await db;
    await database.update(
      'conversations',
      {'otherUserName': null, 'otherUserAvatar': null},
    );
  }

  // ── Full wipe — call on logout ─────────────────────────────────────────────

  Future<void> clearAll() async {
    final database = await db;
    await database.delete('messages');
    await database.delete('conversations');
  }
}
