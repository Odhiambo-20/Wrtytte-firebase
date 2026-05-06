import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:wrytte/models/auth_models/auth_user.dart';

/// Central authentication service.
///
/// Auth model:
///   1. OpenIM chat-server handles phone/OTP login and issues [imToken] + [chatToken].
///   2. Firebase is signed in **anonymously** so that Firestore security rules
///      (`request.auth != null` / `request.auth.uid == userId`) are satisfied.
///      We persist the mapping `firebaseUid → openImUserId` inside the user
///      document so that rules can be tightened to custom-token auth later
///      without any data-migration work.
///   3. All tokens are stored in FlutterSecureStorage (AES-256 on Android,
///      Keychain on iOS).
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  // ── Dependencies ────────────────────────────────────────────────────────────
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _firebaseAuth = FirebaseAuth.instance;

  // ── In-memory OTP store (replace with a real SMS gateway in production) ─────
  final Map<String, String> _pendingPhoneOtps = {};
  final Map<String, String> _pendingEmailOtps = {};

  // ── Storage keys ─────────────────────────────────────────────────────────────
  static const _tokenKey = 'auth_token';
  static const _expiryKey = 'auth_token_expiry';
  static const _userIdKey = 'user_id';
  static const _usernameKey = 'username';
  static const _secretKey = 'secret';
  static const _phoneKey = 'phone';
  static const _openImTokenKey = 'openim_token';
  static const _chatTokenKey = 'chat_token';

  // ── OpenIM configuration ─────────────────────────────────────────────────────
  static const _openImApiBase = 'http://34.63.32.143:10002';
  static const _openImAdminId = 'imAdmin';
  static const _openImSecret = 'openIM123';
  static const _openImPlatformId = 2;

  // ── Timeout constants ─────────────────────────────────────────────────────────
  static const _httpTimeout = Duration(seconds: 15);
  static const _openImLoginTimeout = Duration(seconds: 20);

  // ============================================================================
  // PUBLIC: Firebase Auth (anonymous) — call this BEFORE any Firestore write
  // ============================================================================

  /// Ensures there is a valid Firebase anonymous session.
  ///
  /// This is idempotent — it is safe to call multiple times.  All Firestore
  /// writes must await this method first so that `request.auth` is never null.
  Future<User?> ensureFirebaseAuth() async {
    try {
      if (_firebaseAuth.currentUser != null) return _firebaseAuth.currentUser;
      final credential = await _firebaseAuth.signInAnonymously();
      debugPrint('[AuthService] Firebase anonymous auth established: '
          '${credential.user?.uid}');
      return credential.user;
    } on FirebaseAuthException catch (e) {
      debugPrint('[AuthService] Firebase anonymous sign-in failed: '
          '${e.code} — ${e.message}');
      return null;
    } catch (e) {
      debugPrint('[AuthService] ensureFirebaseAuth unexpected error: $e');
      return null;
    }
  }

  // ============================================================================
  // PUBLIC: OpenIM
  // ============================================================================

  /// Logs the user into the OpenIM SDK.
  ///
  /// If [imToken] is provided (from the chat-server login response), it is used
  /// directly.  Otherwise the admin-token flow is used to register + token the
  /// user (development / first-time setup path).
  Future<void> loginToOpenIM({
    required String userId,
    required String nickname,
    String faceUrl = '',
    String imToken = '',
  }) async {
    try {
      if (imToken.isNotEmpty) {
        await _storage.write(key: _openImTokenKey, value: imToken);
        await OpenIM.iMManager
            .login(userID: userId, token: imToken)
            .timeout(_openImLoginTimeout);
        debugPrint('[OpenIM] Logged in as $userId (chat-server token)');
        return;
      }

      // ── Admin-token fallback ──────────────────────────────────────────────
      final adminToken = await _getOpenImAdminToken();
      if (adminToken == null) {
        debugPrint('[OpenIM] Could not obtain admin token');
        return;
      }

      await _registerOpenImUser(
        adminToken: adminToken,
        userId: userId,
        nickname: nickname,
        faceUrl: faceUrl,
      );

      final userToken = await _getOpenImUserToken(
        adminToken: adminToken,
        userId: userId,
      );
      if (userToken == null) {
        debugPrint('[OpenIM] Could not obtain user token');
        return;
      }

      await _storage.write(key: _openImTokenKey, value: userToken);
      await OpenIM.iMManager
          .login(userID: userId, token: userToken)
          .timeout(_openImLoginTimeout);
      debugPrint('[OpenIM] Logged in as $userId (admin-token flow)');
    } on TimeoutException {
      debugPrint('[OpenIM] loginToOpenIM timed out for $userId');
    } catch (e) {
      debugPrint('[OpenIM] loginToOpenIM error: $e');
    }
  }

  Future<void> logoutFromOpenIM() async {
    try {
      await OpenIM.iMManager.logout();
      await _storage.delete(key: _openImTokenKey);
    } catch (e) {
      debugPrint('[OpenIM] logout error: $e');
    }
  }

  /// Ensures an OpenIM user record exists on the server (idempotent).
  Future<void> ensureOpenImUserExists({
    required String userId,
    String nickname = '',
    String faceUrl = '',
  }) async {
    try {
      final sanitizedId = sanitizeOpenImUserId(userId);
      if (sanitizedId.isEmpty) {
        debugPrint('[OpenIM] ensureOpenImUserExists: sanitized ID is empty '
            'for "$userId"');
        return;
      }

      final adminToken = await _getOpenImAdminToken();
      if (adminToken == null) {
        debugPrint('[OpenIM] ensureOpenImUserExists: could not get admin token');
        return;
      }

      await _registerOpenImUser(
        adminToken: adminToken,
        userId: sanitizedId,
        nickname: nickname.isNotEmpty ? nickname : sanitizedId,
        faceUrl: faceUrl,
      );

      debugPrint('[OpenIM] ensureOpenImUserExists: registered/verified '
          '$sanitizedId (original: $userId)');
    } catch (e) {
      debugPrint('[OpenIM] ensureOpenImUserExists error: $e');
    }
  }

  // ============================================================================
  // PUBLIC: Session persistence
  // ============================================================================

  /// Persists a phone-login session.
  ///
  /// Call this after a successful OpenIM chat-server login so that all
  /// subsequent app launches can restore the session without re-authenticating.
  Future<void> persistPhoneSession({
    required String userId,
    required String username,
    required String phone,
    String imToken = '',
    String chatToken = '',
  }) async {
    // 1. Write tokens to secure storage first (fast, no network).
    await Future.wait([
      _storage.write(key: _tokenKey, value: userId),
      _storage.write(key: _userIdKey, value: userId),
      _storage.write(key: _usernameKey, value: username),
      _storage.write(key: _secretKey, value: userId),
      _storage.write(key: _phoneKey, value: phone),
      _storage.delete(key: _expiryKey),
      if (imToken.isNotEmpty)
        _storage.write(key: _openImTokenKey, value: imToken),
      if (chatToken.isNotEmpty)
        _storage.write(key: _chatTokenKey, value: chatToken),
    ]);

    // 2. Ensure Firebase anonymous auth exists BEFORE writing to Firestore.
    await ensureFirebaseAuth();

    // 3. Write/update the Firestore user document.
    try {
      await _ensureUserDocument(
        uid: userId,
        phone: phone,
        username: username,
      );
    } catch (e) {
      // Non-fatal: the user is logged in via OpenIM; Firestore is supplemental.
      debugPrint('[AuthService] Firestore write error in persistPhoneSession: $e');
    }

    debugPrint('[AuthService] persistPhoneSession complete — userId=$userId');
  }

  // ============================================================================
  // PUBLIC: OTP flows
  // ============================================================================

  Future<void> sendSmsCode(String phone) async {
    final normalizedPhone = _normalizePhone(phone);
    // TODO(production): integrate a real SMS gateway (Twilio, Africa's Talking…)
    _pendingPhoneOtps[normalizedPhone] = '123456';
    debugPrint('[AuthService] OTP ready for $normalizedPhone (dev: use 123456)');
  }

  Future<AuthUser> registerRealPhone({
    required String phone,
    required String code,
    String? username,
    bool login = true,
  }) async {
    final normalizedPhone = _normalizePhone(phone);
    final expected = _pendingPhoneOtps[normalizedPhone];

    if (expected == null) {
      throw Exception(
        'No OTP session found for $normalizedPhone. '
        'Please go back and request the code again.',
      );
    }
    if (code.trim() != expected) {
      throw Exception('Invalid verification code.');
    }

    final userId = _phoneToUserId(normalizedPhone);
    final effectiveUsername = username ?? normalizedPhone;

    // Ensure Firebase auth before Firestore write.
    await ensureFirebaseAuth();
    await _ensureUserDocument(
      uid: userId,
      phone: normalizedPhone,
      username: effectiveUsername,
    );

    final user = AuthUser(
      userId: userId,
      username: effectiveUsername,
      secret: userId,
      token: userId,
      phone: normalizedPhone,
      expiresAt: null,
    );

    if (login) await _persistAuth(user, phone: normalizedPhone);

    _pendingPhoneOtps.remove(normalizedPhone);
    return user;
  }

  Future<AuthUser> authenticatePhone({
    required String phone,
    required String code,
    String? username,
  }) async {
    final savedUser = await getCurrentUser();
    if (savedUser != null &&
        savedUser.secret.isNotEmpty &&
        savedUser.userId.isNotEmpty) {
      return savedUser;
    }
    return registerRealPhone(
      phone: phone,
      code: code,
      username: username,
      login: true,
    );
  }

  Future<void> sendEmailCode(String email) async {
    final normalizedEmail = email.trim().toLowerCase();
    // TODO(production): send a real email OTP.
    _pendingEmailOtps[normalizedEmail] = '123456';
    debugPrint('[AuthService] Email OTP ready for $normalizedEmail '
        '(dev: use 123456)');
  }

  Future<AuthUser> registerVirtualPhone({
    required String email,
    required String code,
    required String phone,
    String? username,
    bool login = true,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    final expected = _pendingEmailOtps[normalizedEmail];

    if (expected == null) {
      throw Exception(
        'No OTP session found for $normalizedEmail. '
        'Please go back and request the code again.',
      );
    }
    if (code.trim() != expected) {
      throw Exception('Invalid verification code.');
    }

    final userId = phone.replaceAll(RegExp(r'[^\d]'), '');
    final effectiveUsername = username ?? normalizedEmail.split('@').first;

    await ensureFirebaseAuth();
    await _ensureUserDocument(
      uid: userId,
      phone: phone,
      username: effectiveUsername,
    );

    final user = AuthUser(
      userId: userId,
      username: effectiveUsername,
      secret: userId,
      token: userId,
      phone: phone,
      expiresAt: null,
    );

    if (login) await _persistAuth(user, phone: phone);

    _pendingEmailOtps.remove(normalizedEmail);
    return user;
  }

  // ============================================================================
  // PUBLIC: Getters
  // ============================================================================

  Future<AuthUser?> getCurrentUser() async {
    final token = await _storage.read(key: _tokenKey);
    if (token == null) return null;

    final expiryString = await _storage.read(key: _expiryKey);
    final userId = await _storage.read(key: _userIdKey) ?? '';
    final username = await _storage.read(key: _usernameKey) ?? '';
    final secret = await _storage.read(key: _secretKey) ?? '';

    return AuthUser(
      userId: userId,
      username: username,
      secret: secret,
      token: token,
      expiresAt:
          expiryString != null ? DateTime.tryParse(expiryString) : null,
    );
  }

  Future<String?> getSavedPhone() async => _storage.read(key: _phoneKey);
  Future<String?> getCurrentUserId() async => _storage.read(key: _userIdKey);
  Future<String?> getToken() async => _storage.read(key: _tokenKey);
  Future<String?> getOpenImToken() async =>
      _storage.read(key: _openImTokenKey);
  Future<String?> getChatToken() async => _storage.read(key: _chatTokenKey);

  Future<bool> isLoggedIn() async {
    final user = await getCurrentUser();
    if (user == null) return false;
    if (user.isExpired) return false;
    return user.isAuthenticated;
  }

  User? get firebaseCurrentUser => _firebaseAuth.currentUser;

  // ============================================================================
  // PUBLIC: Logout
  // ============================================================================

  Future<void> logout() async {
    await logoutFromOpenIM();
    try {
      await _firebaseAuth.signOut();
    } catch (e) {
      debugPrint('[AuthService] Firebase sign-out error: $e');
    }
    await _storage.deleteAll();
  }

  Future<void> signOutFirebase() async {
    try {
      await _firebaseAuth.signOut();
    } catch (e) {
      debugPrint('[AuthService] signOutFirebase error: $e');
    }
  }

  // ============================================================================
  // PUBLIC: Utilities
  // ============================================================================

  /// Strips non-numeric characters so the ID is valid for OpenIM.
  ///
  /// OpenIM rejects user IDs containing `+` or other non-alphanumeric chars.
  /// e.g. `"+254758634762"` → `"254758634762"`
  String sanitizeOpenImUserId(String id) =>
      id.replaceAll(RegExp(r'[^\d]'), '');

  // ============================================================================
  // PRIVATE: OpenIM HTTP helpers
  // ============================================================================

  Future<String?> _getOpenImAdminToken() async {
    try {
      final uri = Uri.parse('$_openImApiBase/auth/get_admin_token');
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'operationID':
                  DateTime.now().millisecondsSinceEpoch.toString(),
            },
            body: jsonEncode(
              {'secret': _openImSecret, 'userID': _openImAdminId},
            ),
          )
          .timeout(_httpTimeout);

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['errCode'] == 0) return body['data']['token'] as String?;
      debugPrint('[OpenIM] _getOpenImAdminToken failed: ${body['errMsg']}');
      return null;
    } catch (e) {
      debugPrint('[OpenIM] _getOpenImAdminToken exception: $e');
      return null;
    }
  }

  Future<void> _registerOpenImUser({
    required String adminToken,
    required String userId,
    required String nickname,
    String faceUrl = '',
  }) async {
    try {
      final uri = Uri.parse('$_openImApiBase/user/user_register');
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'operationID':
                  DateTime.now().millisecondsSinceEpoch.toString(),
              'token': adminToken,
            },
            body: jsonEncode({
              'users': [
                {
                  'userID': userId,
                  'nickname': nickname.isNotEmpty ? nickname : userId,
                  'faceURL': faceUrl,
                }
              ],
            }),
          )
          .timeout(_httpTimeout);

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final errCode = (body['errCode'] as num?)?.toInt() ?? -1;
      // errCode 10001 means "user already exists" — that is fine.
      if (errCode != 0 && errCode != 10001) {
        debugPrint('[OpenIM] _registerOpenImUser failed: '
            'errCode=$errCode errMsg=${body['errMsg']}');
      }
    } catch (e) {
      debugPrint('[OpenIM] _registerOpenImUser exception: $e');
    }
  }

  Future<String?> _getOpenImUserToken({
    required String adminToken,
    required String userId,
  }) async {
    try {
      final uri = Uri.parse('$_openImApiBase/auth/get_user_token');
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'operationID':
                  DateTime.now().millisecondsSinceEpoch.toString(),
              'token': adminToken,
            },
            body: jsonEncode(
              {'userID': userId, 'platformID': _openImPlatformId},
            ),
          )
          .timeout(_httpTimeout);

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['errCode'] == 0) return body['data']['token'] as String?;
      debugPrint('[OpenIM] _getOpenImUserToken failed: ${body['errMsg']}');
      return null;
    } catch (e) {
      debugPrint('[OpenIM] _getOpenImUserToken exception: $e');
      return null;
    }
  }

  // ============================================================================
  // PRIVATE: Firestore helpers
  // ============================================================================

  /// Creates or merges the Firestore user document for [uid].
  ///
  /// IMPORTANT: [ensureFirebaseAuth] MUST be awaited before calling this so
  /// that `request.auth.uid` in the security rules matches [uid].
  ///
  /// Note: Firebase anonymous auth gives us a *Firebase* UID, which is
  /// different from the OpenIM/phone-derived [uid].  Until custom-token auth
  /// is integrated, the Firestore rule `request.auth.uid == userId` will only
  /// work when the Firebase UID happens to equal the document ID — which is
  /// NOT the case with anonymous auth.
  ///
  /// Workaround (applied here): we write a `firebaseUid` field and update the
  /// Firestore rules (or use a Cloud Function) to accept writes where
  /// `request.auth.uid == resource.data.firebaseUid`.
  ///
  /// The IMMEDIATE fix that requires NO rule change is to relax the write rule
  /// to `allow write: if request.auth != null;` while you integrate custom
  /// tokens.  The current rules already allow reads for any authenticated user,
  /// so reads are unaffected.
  Future<void> _ensureUserDocument({
    required String uid,
    String? phone,
    String? username,
  }) async {
    final userRef = _firestore.collection('users').doc(uid);
    final snapshot = await userRef.get();
    final existing = snapshot.data() ?? {};
    final now = FieldValue.serverTimestamp();
    final firebaseUid = _firebaseAuth.currentUser?.uid;

    await userRef.set(
      {
        'uid': uid,
        'updatedAt': now,
        if (!snapshot.exists) 'createdAt': now,
        if (phone != null && phone.isNotEmpty)
          'phone': _normalizePhone(phone),
        if (username != null && username.isNotEmpty) ...{
          'username': username,
          'name': existing['name'] ?? username,
        },
        if (firebaseUid != null) 'firebaseUid': firebaseUid,
        'isOnline': true,
        'lastSeen': now,
      },
      SetOptions(merge: true),
    );
  }

  // ============================================================================
  // PRIVATE: Auth persistence
  // ============================================================================

  Future<void> _persistAuth(AuthUser user, {String? phone}) async {
    await Future.wait([
      _storage.write(key: _tokenKey, value: user.token),
      _storage.write(key: _userIdKey, value: user.userId),
      _storage.write(key: _usernameKey, value: user.username),
      _storage.write(key: _secretKey, value: user.secret),
      if (phone != null && phone.isNotEmpty)
        _storage.write(key: _phoneKey, value: phone),
      _storage.delete(key: _expiryKey),
    ]);
  }

  // ============================================================================
  // PRIVATE: Phone utilities
  // ============================================================================

  String _phoneToUserId(String normalizedPhone) =>
      normalizedPhone.replaceAll(RegExp(r'[^\d]'), '');

  String _normalizePhone(String phone) {
    var cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('00')) cleaned = '+${cleaned.substring(2)}';
    if (!cleaned.startsWith('+')) cleaned = '+$cleaned';
    return cleaned;
  }
}
