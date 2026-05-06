import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wrytte/models/user_models/user_profile_service.dart';
import 'package:wrytte/services/auth/auth_service.dart';

class UserProfileService {
  UserProfileService._();
  static final UserProfileService instance = UserProfileService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static const _collection = 'users';
  static const _prefKey = 'cached_user_profile'; // ← SharedPreferences key

  UserProfile? _cachedProfile;
  String? _cachedUid;

  // ─────────────────────────────────────────────────────────────
  // PERSIST / LOAD  (survives app restarts)
  // ─────────────────────────────────────────────────────────────

  Future<void> _persistProfile(UserProfile profile) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, jsonEncode(profile.toMap()..['uid'] = profile.uid));
    } catch (_) {}
  }

  Future<UserProfile?> _loadPersistedProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw == null) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final uid = map['uid'] as String? ?? '';
      if (uid.isEmpty) return null;
      return UserProfile.fromMap(uid, map);
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearPersistedProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefKey);
    } catch (_) {}
  }

  // ─────────────────────────────────────────────────────────────
  // WARM UP
  // ─────────────────────────────────────────────────────────────

  Future<void> warmUp() async {
    // ① Load persisted profile instantly — zero network latency
    if (_cachedProfile == null) {
      final persisted = await _loadPersistedProfile();
      if (persisted != null) {
        _cachedProfile = persisted;
        _cachedUid = persisted.uid;
      }
    }

    // ② Then fetch fresh from Firestore in background
    final uid = await AuthService.instance.getCurrentUserId();
    if (uid == null || uid.isEmpty) return;
    _cachedUid = uid;
    await getProfileByUid(uid);
  }

  // ─────────────────────────────────────────────────────────────
  // FETCH
  // ─────────────────────────────────────────────────────────────

  Future<UserProfile?> getCurrentUserProfile({
    bool forceRefresh = false,
  }) async {
    if (_cachedProfile != null && !forceRefresh) return _cachedProfile;

    final uid = _cachedUid ?? await AuthService.instance.getCurrentUserId();
    if (uid == null || uid.isEmpty) return null;
    _cachedUid = uid;

    return getProfileByUid(uid);
  }

  Future<UserProfile?> getProfileByUid(String uid) async {
    try {
      final doc = await _firestore.collection(_collection).doc(uid).get();
      if (!doc.exists || doc.data() == null) return null;

      final profile = UserProfile.fromMap(uid, doc.data()!);

      final currentUid =
          _cachedUid ?? await AuthService.instance.getCurrentUserId();
      if (currentUid == uid) {
        _cachedProfile = profile;
        _cachedUid = uid;
        await _persistProfile(profile); // ← save to disk
      }

      return profile;
    } catch (e) {
      return null;
    }
  }

  Future<UserProfile?> getProfileByPhone(String phone) async {
    try {
      final query = await _firestore
          .collection(_collection)
          .where('phone', isEqualTo: phone)
          .limit(1)
          .get();

      if (query.docs.isEmpty) return null;

      final doc = query.docs.first;
      return UserProfile.fromMap(doc.id, doc.data());
    } catch (e) {
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // STREAM
  // ─────────────────────────────────────────────────────────────

  Stream<UserProfile?> getCurrentUserProfileStream() async* {
    // Emit persisted profile instantly if in-memory cache is empty
    if (_cachedProfile == null) {
      final persisted = await _loadPersistedProfile();
      if (persisted != null) {
        _cachedProfile = persisted;
        _cachedUid = persisted.uid;
      }
    }

    if (_cachedProfile != null) yield _cachedProfile;

    final uid = _cachedUid ?? await AuthService.instance.getCurrentUserId();
    if (uid == null || uid.isEmpty) {
      yield null;
      return;
    }
    _cachedUid = uid;

    yield* _firestore
        .collection(_collection)
        .doc(uid)
        .snapshots()
        .map((doc) {
      if (!doc.exists || doc.data() == null) return null;
      final profile = UserProfile.fromMap(doc.id, doc.data()!);
      _cachedProfile = profile;
      _persistProfile(profile); // ← keep disk cache fresh
      return profile;
    });
  }

  // ─────────────────────────────────────────────────────────────
  // CACHE HELPERS
  // ─────────────────────────────────────────────────────────────

  UserProfile? get cachedProfile => _cachedProfile;

  void clearCache() {
    _cachedProfile = null;
    _cachedUid = null;
    _clearPersistedProfile(); // ← wipe disk too on logout
  }
}
