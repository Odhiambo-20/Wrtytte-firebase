import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class OpenIMChatService {
  OpenIMChatService._();
  static final OpenIMChatService instance = OpenIMChatService._();

  static const _chatBase = 'http://34.63.32.143:10008';

  // ===========================================================================
  //  REGISTER — POST /account/register
  //  Called for brand-new users. Uses super-code "666666" (no SMS needed).
  //  Requires /account/code/send to be called first (done by RealNumberService).
  // ===========================================================================
  Future<OpenIMRegisterResult> registerWithPhone({
    required String areaCode,    // e.g. "+254"
    required String phoneNumber, // e.g. "742135625"
    required String nickname,
    int platform = 2,
  }) async {
    final uri = Uri.parse('$_chatBase/account/register');

    final requestBody = {
      'verifyCode': '666666',
      'platform': platform,
      'autoLogin': true,
      'user': {
        'nickname': nickname,
        'faceURL': '',
        'areaCode': areaCode,
        'phoneNumber': phoneNumber,
      },
    };

    debugPrint('[OpenIMChat] POST /account/register → $requestBody');

    final response = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'operationID': _opId(),
          },
          body: jsonEncode(requestBody),
        )
        .timeout(const Duration(seconds: 15));

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    debugPrint('[OpenIMChat] /account/register response: $body');

    final errCode = (body['errCode'] as num?)?.toInt() ?? -1;
    if (errCode != 0) {
      throw OpenIMChatException(
        code: errCode,
        message: body['errMsg'] as String? ?? 'Registration failed',
      );
    }

    final data = (body['data'] as Map<String, dynamic>?) ?? {};
    return OpenIMRegisterResult(
      userID:    data['userID']    as String? ?? '',
      imToken:   data['imToken']   as String? ?? '',
      chatToken: data['chatToken'] as String? ?? '',
    );
  }

  // ===========================================================================
  //  LOGIN — POST /account/login
  //  Called for returning users. Uses super-code "666666".
  //
  //  IMPORTANT: The login endpoint expects areaCode and phoneNumber as FLAT
  //  top-level fields — NOT nested inside a "user" object like /account/register.
  //  Confirmed via curl: flat fields → errCode 0 ✅, nested → errCode 1001 ✗.
  //
  //  Also requires /account/code/send (usedFor=2) to be called first.
  //  This is handled by RealNumberService before calling this method.
  // ===========================================================================
  Future<OpenIMRegisterResult> loginWithPhone({
    required String areaCode,    // e.g. "+254"
    required String phoneNumber, // e.g. "742135625"
    int platform = 2,
  }) async {
    final uri = Uri.parse('$_chatBase/account/login');

    // FLAT fields — do NOT nest inside "user": {} for this endpoint
    final requestBody = {
      'verifyCode':  '666666',
      'platform':    platform,
      'areaCode':    areaCode,
      'phoneNumber': phoneNumber,
    };

    debugPrint('[OpenIMChat] POST /account/login → $requestBody');

    final response = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'operationID': _opId(),
          },
          body: jsonEncode(requestBody),
        )
        .timeout(const Duration(seconds: 15));

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    debugPrint('[OpenIMChat] /account/login response: $body');

    final errCode = (body['errCode'] as num?)?.toInt() ?? -1;
    if (errCode != 0) {
      throw OpenIMChatException(
        code: errCode,
        message: body['errMsg'] as String? ?? 'Login failed',
      );
    }

    final data = (body['data'] as Map<String, dynamic>?) ?? {};
    return OpenIMRegisterResult(
      userID:    data['userID']    as String? ?? '',
      imToken:   data['imToken']   as String? ?? '',
      chatToken: data['chatToken'] as String? ?? '',
    );
  }

  String _opId() => DateTime.now().millisecondsSinceEpoch.toString();
}

// =============================================================================
//  Result model
// =============================================================================
class OpenIMRegisterResult {
  final String userID;
  final String imToken;
  final String chatToken;

  const OpenIMRegisterResult({
    required this.userID,
    required this.imToken,
    required this.chatToken,
  });
}

// =============================================================================
//  Exception model
// =============================================================================
class OpenIMChatException implements Exception {
  final int    code;
  final String message;

  const OpenIMChatException({required this.code, required this.message});

  /// True when the server says this phone is already registered (errCode 20004).
  bool get isAlreadyExists => code == 20004;

  @override
  String toString() => 'OpenIMChatException($code): $message';
}
