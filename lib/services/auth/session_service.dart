import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SessionService {
  SessionService._();
  static final SessionService instance = SessionService._();

  static const _storage = FlutterSecureStorage();

  static const _tokenKey = 'auth_token';
  static const _userIdKey = 'user_id';

  // SAVE SESSION

  Future<void> saveSession({
    required String token,
    String? userId,
    required String secret,
    required String username,
  }) async {
    await _storage.write(key: _tokenKey, value: token);

    if (userId != null) {
      await _storage.write(key: _userIdKey, value: userId);
    }
  }

  // READ SESSION

  Future<String?> getToken() async {
    return await _storage.read(key: _tokenKey);
  }

  Future<String?> getUserId() async {
    return await _storage.read(key: _userIdKey);
  }

  Future<bool> isLoggedIn() async {
    final token = await getToken();
    return token != null && token.isNotEmpty;
  }

  // CLEAR SESSION (LOGOUT)

  Future<void> logout() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _userIdKey);
  }

  Future<void> clearAll() async {
    await _storage.deleteAll();
  }
}
