import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:wrytte/models/chat_models/chat_message.dart';
import 'package:wrytte/models/chat_models/chat_conversation.dart';
import 'package:wrytte/services/auth/auth_service.dart';

class FirebaseChatService {
  // ── Singleton ──────────────────────────────────────────────────────────────

  FirebaseChatService._internal();
  static final FirebaseChatService _instance = FirebaseChatService._internal();
  factory FirebaseChatService() => _instance;

  // ── Firebase references ────────────────────────────────────────────────────

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  // ── State ──────────────────────────────────────────────────────────────────

  String? _currentUserId;
  bool _initialized = false;

  final Map<String, StreamSubscription> _messageListeners = {};

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

  Stream<ChatMessage> get messageStream => _messageController.stream;
  Stream<String> get errorStream => _errorController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;
  Stream<List<ChatConversation>> get conversationsStream =>
      _conversationsController.stream;

  // ── Helpers ────────────────────────────────────────────────────────────────

  String get currentUserId => _currentUserId ?? '';

  static String buildConversationId(String uid1, String uid2) {
    final parts = [uid1, uid2]..sort();
    return '${parts[0]}-${parts[1]}';
  }

  static String buildParticipantsKey(String uid1, String uid2) {
    final parts = [uid1, uid2]..sort();
    return '${parts[0]}_${parts[1]}';
  }

  // ── Connect ────────────────────────────────────────────────────────────────

  /// [userId] can be passed directly from the caller (ConversationsScreen
  /// already resolved it from AuthService). If omitted, we resolve it here.
  Future<void> connect({String? userId}) async {
    if (_initialized) return;

    try {
      // Prefer the caller-supplied userId, fall back to AuthService
      _currentUserId = (userId != null && userId.isNotEmpty)
          ? userId
          : await AuthService.instance.getCurrentUserId();

      if (_currentUserId == null || _currentUserId!.isEmpty) {
        _errorController.add('User not authenticated');
        _connectionController.add(false);
        return;
      }

      _initialized = true;
      _connectionController.add(true);
      _listenToConversations();

      debugPrint('FirebaseChatService connected as $_currentUserId');
    } catch (e) {
      debugPrint('FirebaseChatService connect error: $e');
      _errorController.add('Connection failed: $e');
      _connectionController.add(false);
    }
  }

  // ── Conversations listener ─────────────────────────────────────────────────

  StreamSubscription? _conversationsSub;

  void _listenToConversations() {
    _conversationsSub?.cancel();

    _conversationsSub = _db
        .collection('chats')
        .where('participants', arrayContains: _currentUserId)
        .orderBy('lastMessageTime', descending: true)
        .snapshots()
        .listen(
          (snapshot) {
            final conversations = snapshot.docs
                .map((doc) => _conversationFromDoc(doc))
                .where((c) => c != null)
                .cast<ChatConversation>()
                .toList();

            _conversationsController.add(conversations);
          },
          onError: (e) {
            debugPrint('Conversations listener error: $e');
            _errorController.add('Conversations error: $e');
          },
        );
  }

  ChatConversation? _conversationFromDoc(DocumentSnapshot doc) {
    try {
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null) return null;

      final participants = List<String>.from(data['participants'] ?? []);
      final otherId = participants.firstWhere(
        (p) => p != _currentUserId,
        orElse: () => '',
      );

      if (otherId.isEmpty) return null;

      final lastMessageTime =
          (data['lastMessageTime'] as Timestamp?)?.toDate() ?? DateTime.now();

      final unreadMap = Map<String, dynamic>.from(data['unreadCount'] ?? {});
      final unreadCount = (unreadMap[_currentUserId] as int?) ?? 0;

      return ChatConversation(
        id: doc.id,
        otherUserId: otherId,
        lastMessage: data['lastMessage']?.toString() ?? '',
        lastMessageTime: lastMessageTime,
        lastMessageSenderId: data['lastMessageSender']?.toString() ?? '',
        unreadCount: unreadCount,
        participants: [],
      );
    } catch (e) {
      debugPrint('Error parsing conversation doc: $e');
      return null;
    }
  }

  // ── Messages stream for a single conversation ──────────────────────────────

  Stream<List<ChatMessage>> getMessagesStream(String conversationId) {
    return _db
        .collection('chats')
        .doc(conversationId)
        .collection('messages')
        .orderBy('ts', descending: false)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((doc) => _messageFromDoc(doc, conversationId))
              .where((m) => m != null)
              .cast<ChatMessage>()
              .toList(),
        );
  }

  ChatMessage? _messageFromDoc(DocumentSnapshot doc, String conversationId) {
    try {
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null) return null;

      final ts = data['ts'];
      DateTime timestamp;
      if (ts is Timestamp) {
        timestamp = ts.toDate();
      } else if (ts is String) {
        timestamp = DateTime.tryParse(ts) ?? DateTime.now();
      } else {
        timestamp = DateTime.now();
      }

      return ChatMessage(
        id: doc.id,
        conversationId: conversationId,
        senderId: data['from']?.toString() ?? '',
        receiverId: data['to']?.toString() ?? '',
        content: data['msg']?.toString() ?? '',
        timestamp: timestamp,
        status: MessageStatus.sent,
        attachmentUrl: data['attachmentUrl']?.toString(),
        attachmentType: data['attachmentType']?.toString(),
        voiceDuration: data['voiceDuration'] != null
            ? int.tryParse(data['voiceDuration'].toString())
            : null,
      );
    } catch (e) {
      debugPrint('Error parsing message doc: $e');
      return null;
    }
  }

  // ── Send text message ──────────────────────────────────────────────────────

  Future<void> sendMessage(ChatMessage message) async {
    if (_currentUserId == null) {
      throw Exception('FirebaseChatService not connected');
    }

    final conversationId = message.conversationId;
    final convRef = _db.collection('chats').doc(conversationId);
    final messagesRef = convRef.collection('messages');

    final now = FieldValue.serverTimestamp();
    final clientNow = DateTime.now();

    final batch = _db.batch();

    final msgRef = messagesRef.doc(message.id);
    batch.set(msgRef, {
      'from': message.senderId,
      'to': message.receiverId,
      'msg': message.content,
      'ts': Timestamp.fromDate(clientNow),
      'msgType': 'text',
      if (message.attachmentUrl != null) 'attachmentUrl': message.attachmentUrl,
      if (message.attachmentType != null)
        'attachmentType': message.attachmentType,
      'seenBy': [message.senderId],
    });

    batch.set(convRef, {
      'participants': [message.senderId, message.receiverId]..sort(),
      'participantsKey': buildParticipantsKey(
        message.senderId,
        message.receiverId,
      ),
      'lastMessage': message.content,
      'lastMessageSender': message.senderId,
      'lastMessageTime': now,
      'lastMessageType': 'text',
      'isArchived': false,
      'isMuted': false,
      'isPinned': false,
      'mutedUntil': null,
      'unreadCount.${message.receiverId}': FieldValue.increment(1),
      'createdAt': now,
    }, SetOptions(merge: true));

    try {
      await batch.commit();
      debugPrint('Message sent: ${message.id}');
    } catch (e) {
      debugPrint('sendMessage error: $e');
      _errorController.add('Send failed: $e');
      rethrow;
    }
  }

  // ── Send voice note ────────────────────────────────────────────────────────

  Future<ChatMessage> sendVoiceMessage({
    required String receiverId,
    required String filePath,
    required int durationSeconds,
    required String conversationId,
  }) async {
    if (_currentUserId == null) {
      throw Exception('FirebaseChatService not connected');
    }

    final myId = _currentUserId!;
    final messageId = DateTime.now().millisecondsSinceEpoch.toString();
    final file = File(filePath);

    if (!await file.exists()) {
      throw Exception('Voice file not found: $filePath');
    }

    final storageRef = _storage
        .ref()
        .child('voice_notes')
        .child(conversationId)
        .child('$messageId.aac');

    debugPrint('[FirebaseChatService] Uploading voice note…');

    String downloadUrl;
    try {
      final uploadTask = await storageRef.putFile(
        file,
        SettableMetadata(contentType: 'audio/aac'),
      );
      downloadUrl = await uploadTask.ref.getDownloadURL();
      debugPrint('[FirebaseChatService] Voice note uploaded: $downloadUrl');
    } catch (e) {
      debugPrint('[FirebaseChatService] Upload error: $e');
      _errorController.add('Voice upload failed: $e');
      rethrow;
    }

    final message = ChatMessage(
      id: messageId,
      conversationId: conversationId,
      senderId: myId,
      receiverId: receiverId,
      content: '',
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
      attachmentUrl: downloadUrl,
      attachmentType: 'voice',
      voiceDuration: durationSeconds,
    );

    final convRef = _db.collection('chats').doc(conversationId);
    final msgRef = convRef.collection('messages').doc(messageId);
    final now = FieldValue.serverTimestamp();
    final clientNow = Timestamp.fromDate(message.timestamp);

    final batch = _db.batch();

    batch.set(msgRef, {
      'from': myId,
      'to': receiverId,
      'msg': '',
      'ts': clientNow,
      'msgType': 'voice',
      'attachmentUrl': downloadUrl,
      'attachmentType': 'voice',
      'voiceDuration': durationSeconds,
      'seenBy': [myId],
    });

    batch.set(convRef, {
      'participants': [myId, receiverId]..sort(),
      'participantsKey': buildParticipantsKey(myId, receiverId),
      'lastMessage': '🎤 Voice message',
      'lastMessageSender': myId,
      'lastMessageTime': now,
      'lastMessageType': 'voice',
      'isArchived': false,
      'isMuted': false,
      'isPinned': false,
      'mutedUntil': null,
      'unreadCount.$receiverId': FieldValue.increment(1),
      'createdAt': now,
    }, SetOptions(merge: true));

    try {
      await batch.commit();
      debugPrint('[FirebaseChatService] Voice note message written: $messageId');
    } catch (e) {
      debugPrint('[FirebaseChatService] Firestore write error: $e');
      _errorController.add('Voice send failed: $e');
      rethrow;
    }

    try {
      await file.delete();
    } catch (_) {}

    return message.copyWith(status: MessageStatus.sent);
  }

  // ── Ensure conversation exists ─────────────────────────────────────────────

  Future<String> ensureConversation(String otherUserId) async {
    final myId = _currentUserId!;
    final convId = buildConversationId(myId, otherUserId);
    final convRef = _db.collection('chats').doc(convId);

    final snap = await convRef.get();
    if (!snap.exists) {
      await convRef.set({
        'participants': [myId, otherUserId]..sort(),
        'participantsKey': buildParticipantsKey(myId, otherUserId),
        'lastMessage': '',
        'lastMessageSender': '',
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageType': 'text',
        'unreadCount': {myId: 0, otherUserId: 0},
        'isArchived': false,
        'isMuted': false,
        'isPinned': false,
        'mutedUntil': null,
        'lastSeen': {},
        'createdAt': FieldValue.serverTimestamp(),
        'deletedAt': null,
        'deletedBy': [],
      });
    }

    return convId;
  }

  // ── Mark as read ───────────────────────────────────────────────────────────

  Future<void> markConversationAsRead(String conversationId) async {
    final myId = _currentUserId;
    if (myId == null) return;

    try {
      await _db.collection('chats').doc(conversationId).set({
        'unreadCount.$myId': 0,
        'lastSeen.$myId': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('markAsRead error: $e');
    }
  }

  // ── Fetch conversations (one-shot) ─────────────────────────────────────────

  Future<List<ChatConversation>> fetchConversations() async {
    try {
      final snap = await _db
          .collection('chats')
          .where('participants', arrayContains: _currentUserId)
          .orderBy('lastMessageTime', descending: true)
          .get();

      return snap.docs
          .map((doc) => _conversationFromDoc(doc))
          .where((c) => c != null)
          .cast<ChatConversation>()
          .toList();
    } catch (e) {
      debugPrint('fetchConversations error: $e');
      return [];
    }
  }

  // ── Disconnect / dispose ───────────────────────────────────────────────────

  Future<void> disconnect() async {
    _conversationsSub?.cancel();
    for (final sub in _messageListeners.values) {
      await sub.cancel();
    }
    _messageListeners.clear();
    _initialized = false;
    _currentUserId = null;
    _connectionController.add(false);
  }

  void dispose() {
    disconnect();
    _messageController.close();
    _errorController.close();
    _connectionController.close();
    _conversationsController.close();
  }
}
