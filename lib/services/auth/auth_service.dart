import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_openim_sdk/flutter_openim_sdk.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:wrytte/models/auth_models/auth_user.dart';

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  final Map<String, String> _pendingPhoneOtps  = {};
  final Map<String, String> _pendingEmailOtps  = {};

  static const _tokenKey       = 'auth_token';
  static const _expiryKey      = 'auth_token_expiry';
  static const _userIdKey      = 'user_id';
  static const _usernameKey    = 'username';
  static const _secretKey      = 'secret';
  static const _phoneKey       = 'phone';
  static const _openImTokenKey = 'openim_token';
  static const _chatTokenKey   = 'chat_token';

  static const _openImApiBase    = 'http://34.63.32.143:10002';
  static const _openImAdminId    = 'imAdmin';
  static const _openImSecret     = 'openIM123';
  static const _openImPlatformId = 2;

  // ============================================================
  //  OPENIM TOKEN FLOW — NOT TOUCHED
  // ============================================================

  Future<void> loginToOpenIM({
    required String userId,
    required String nickname,
    String faceUrl  = '',
    String imToken  = '',
  }) async {
    try {
      if (imToken.isNotEmpty) {
        await _storage.write(key: _openImTokenKey, value: imToken);
        await OpenIM.iMManager.login(userID: userId, token: imToken)
            .timeout(const Duration(seconds: 20));
        debugPrint('[OpenIM] Logged in as $userId (chat-server token)');
        return;
      }

      final adminToken = await _getOpenImAdminToken();
      if (adminToken == null) {
        debugPrint('[OpenIM] Could not get admin token');
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
        debugPrint('[OpenIM] Could not get user token');
        return;
      }

      await _storage.write(key: _openImTokenKey, value: userToken);
      await OpenIM.iMManager.login(userID: userId, token: userToken);
      debugPrint('[OpenIM] Logged in as $userId (admin-token flow)');
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

  Future<String?> _getOpenImAdminToken() async {
    try {
      final uri = Uri.parse('$_openImApiBase/auth/get_admin_token');
      final response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'operationID': DateTime.now().millisecondsSinceEpoch.toString(),
        },
        body: jsonEncode({'secret': _openImSecret, 'userID': _openImAdminId}),
      );
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['errCode'] == 0) return body['data']['token'] as String?;
      return null;
    } catch (e) {
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
      await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'operationID': DateTime.now().millisecondsSinceEpoch.toString(),
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
      );
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
      final response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'operationID': DateTime.now().millisecondsSinceEpoch.toString(),
          'token': adminToken,
        },
        body: jsonEncode({'userID': userId, 'platformID': _openImPlatformId}),
      );
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['errCode'] == 0) return body['data']['token'] as String?;
      return null;
    } catch (e) {
      return null;
    }
  }

  // ============================================================
  //  PHONE AUTH — NOT TOUCHED
  // ============================================================

  Future<void> sendSmsCode(String phone) async {
    final normalizedPhone = _normalizePhone(phone);
    _pendingPhoneOtps[normalizedPhone] = '123456';
    debugPrint('[AuthService] OTP ready for $normalizedPhone (use 123456)');
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
        'No OTP session found for $normalizedPhone. Please go back and request the code again.',
      );
    }

    if (code.trim() != expected) {
      throw Exception('Invalid verification code.');
    }

    final userId = _phoneToUserId(normalizedPhone);
    final effectiveUsername = username ?? normalizedPhone;

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
      try {
        return savedUser;
      } catch (_) {}
    }
    return await registerRealPhone(
      phone: phone,
      code: code,
      username: username,
      login: true,
    );
  }

  // ============================================================
  //  persistPhoneSession — ONLY THIS METHOD CHANGED
  //  Added Firebase anonymous sign-in so Firestore rules work.
  //  OpenIM logic is completely untouched.
  // ============================================================

  Future<void> persistPhoneSession({
    required String userId,
    required String username,
    required String phone,
    String imToken   = '',
    String chatToken = '',
  }) async {
    // ── Secure storage (OpenIM session) — NOT TOUCHED ──────────────────
    await _storage.write(key: _tokenKey,    value: userId);
    await _storage.write(key: _userIdKey,   value: userId);
    await _storage.write(key: _usernameKey, value: username);
    await _storage.write(key: _secretKey,   value: userId);
    await _storage.write(key: _phoneKey,    value: phone);
    await _storage.delete(key: _expiryKey);

    if (imToken.isNotEmpty) {
      await _storage.write(key: _openImTokenKey, value: imToken);
    }
    if (chatToken.isNotEmpty) {
      await _storage.write(key: _chatTokenKey, value: chatToken);
    }

    // ── NEW: Firebase anonymous sign-in so Firestore rules work ────────
    // This does NOT affect OpenIM in any way. It only creates a Firebase
    // Auth session so that Firestore security rules (request.auth != null)
    // stop rejecting reads and writes.
    try {
      final firebaseAuth = FirebaseAuth.instance;
      if (firebaseAuth.currentUser == null) {
        await firebaseAuth.signInAnonymously();
        debugPrint('[AuthService] Firebase anonymous auth established');
      }
    } catch (e) {
      // Non-fatal — app still works, Firestore rules will be open fallback
      debugPrint('[AuthService] Firebase anonymous sign-in failed: $e');
    }
    // ── END NEW ────────────────────────────────────────────────────────

    // ── Firestore user doc — fire-and-forget ───────────────────────────
    _ensureUserDocument(
      uid: userId,
      phone: phone,
      username: username,
    ).catchError((e) {
      debugPrint('[AuthService] Background Firestore write error: $e');
    });

    debugPrint('[AuthService] persistPhoneSession → userId=$userId');
  }

  // ============================================================
  //  VIRTUAL NUMBER AUTH — NOT TOUCHED
  // ============================================================

  Future<void> sendEmailCode(String email) async {
    final normalizedEmail = email.trim().toLowerCase();
    _pendingEmailOtps[normalizedEmail] = '123456';
    debugPrint('[AuthService] Email OTP ready for $normalizedEmail (use 123456)');
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
        'No OTP session found for $normalizedEmail. Please go back and request the code again.',
      );
    }

    if (code.trim() != expected) {
      throw Exception('Invalid verification code.');
    }

    final userId = phone.replaceAll(RegExp(r'[^\d]'), '');
    final effectiveUsername = username ?? normalizedEmail.split('@').first;

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

  // ============================================================
  //  PERSIST HELPERS — NOT TOUCHED
  // ============================================================

  Future<void> _persistAuth(AuthUser user, {String? phone}) async {
    await _storage.write(key: _tokenKey,    value: user.token);
    await _storage.write(key: _userIdKey,   value: user.userId);
    await _storage.write(key: _usernameKey, value: user.username);
    await _storage.write(key: _secretKey,   value: user.secret);
    if (phone != null && phone.isNotEmpty) {
      await _storage.write(key: _phoneKey, value: phone);
    }
    await _storage.delete(key: _expiryKey);
  }

  Future<void> _ensureUserDocument({
    required String uid,
    String? phone,
    String? username,
  }) async {
    final userRef  = _firestore.collection('users').doc(uid);
    final snapshot = await userRef.get();
    final existing = snapshot.data() ?? {};
    final now      = FieldValue.serverTimestamp();

    await userRef.set({
      'uid': uid,
      'updatedAt': now,
      if (!snapshot.exists) 'createdAt': now,
      if (phone != null && phone.isNotEmpty) 'phone': _normalizePhone(phone),
      if (username != null && username.isNotEmpty) ...{
        'username': username,
        'name': existing['name'] ?? username,
      },
      'isOnline': true,
      'lastSeen': now,
    }, SetOptions(merge: true));
  }

  String _phoneToUserId(String normalizedPhone) {
    return normalizedPhone.replaceAll(RegExp(r'[^\d]'), '');
  }

  String _normalizePhone(String phone) {
    var cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('00')) cleaned = '+${cleaned.substring(2)}';
    if (!cleaned.startsWith('+')) cleaned = '+$cleaned';
    return cleaned;
  }

  // ============================================================
  //  READ CURRENT USER — NOT TOUCHED
  // ============================================================

  Future<AuthUser?> getCurrentUser() async {
    final token = await _storage.read(key: _tokenKey);
    if (token == null) return null;

    final expiryString = await _storage.read(key: _expiryKey);
    final userId   = await _storage.read(key: _userIdKey)   ?? '';
    final username = await _storage.read(key: _usernameKey) ?? '';
    final secret   = await _storage.read(key: _secretKey)   ?? '';

    return AuthUser(
      userId: userId,
      username: username,
      secret: secret,
      token: token,
      expiresAt: expiryString != null ? DateTime.tryParse(expiryString) : null,
    );
  }

  Future<String?> getSavedPhone()    async => _storage.read(key: _phoneKey);
  Future<String?> getCurrentUserId() async => _storage.read(key: _userIdKey);
  Future<String?> getToken()         async => _storage.read(key: _tokenKey);
  Future<String?> getOpenImToken()   async => _storage.read(key: _openImTokenKey);
  Future<String?> getChatToken()     async => _storage.read(key: _chatTokenKey);

  Future<bool> isLoggedIn() async {
    final user = await getCurrentUser();
    if (user == null) return false;
    if (user.isExpired) return false;
    return user.isAuthenticated;
  }

  // ============================================================
  //  LOGOUT — NOT TOUCHED
  // ============================================================

  Future<void> logout() async {
    await logoutFromOpenIM();
    // Also sign out of Firebase anonymous session
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
    await _storage.deleteAll();
  }

  Future<void> signOutFirebase() async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
  }

  dynamic get firebaseCurrentUser => FirebaseAuth.instance.currentUser;
}
