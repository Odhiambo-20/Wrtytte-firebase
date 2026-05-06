import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/services/auth/openim_chat_service.dart';
import 'package:wrytte/utils/countries.dart';

// =============================================================================
//  Result model
// =============================================================================
class RealNumberRegisterResult {
  final String username;
  final String userId;
  final String secret;

  /// True  → brand-new account (must set profile name)
  /// False → existing account   (go straight to HomeScreen)
  final bool isNewUser;

  RealNumberRegisterResult({
    required this.username,
    required this.userId,
    required this.secret,
    required this.isNewUser,
  });
}

// =============================================================================
//  RealNumberService
// =============================================================================
class RealNumberService {
  RealNumberService();

  static const _chatBase = 'http://34.63.32.143:10008';

  // ---------------------------------------------------------------------------
  //  STEP 1 — "Send OTP"
  // ---------------------------------------------------------------------------
  Future<void> sendSmsCode(String fullPhone) async {
    debugPrint('[RealNumberService] sendSmsCode → $fullPhone');

    final split = _splitFullPhone(fullPhone);
    final String areaCode;
    final String phoneNumber;

    if (split == null) {
      areaCode    = '+0';
      phoneNumber = fullPhone.replaceAll(RegExp(r'[^\d]'), '');
    } else {
      areaCode    = '+${split.areaCode}';
      phoneNumber = split.localNumber;
    }

    await _sendVerificationSession(
      areaCode:    areaCode,
      phoneNumber: phoneNumber,
      usedFor:     1,
    );
  }

  // ---------------------------------------------------------------------------
  //  STEP 2 — Register or login
  //
  //  Returns [RealNumberRegisterResult] with [isNewUser] = true  for first-time
  //  signups, and [isNewUser] = false for returning users.
  // ---------------------------------------------------------------------------
  Future<RealNumberRegisterResult> registerRealPhone({
    required String fullPhone,
    required String code,
    String nickname = '',
    bool login = true,
  }) async {
    debugPrint('[RealNumberService] registerRealPhone → "$fullPhone"');

    // ── 1. Parse dial code ───────────────────────────────────────────────────
    final split = _splitFullPhone(fullPhone);

    final String areaCode;
    final String phoneNumber;

    if (split == null) {
      debugPrint(
        '[RealNumberService] No dial-code match for "$fullPhone"; '
        'using raw digits with area code +0',
      );
      areaCode    = '+0';
      phoneNumber = fullPhone.replaceAll(RegExp(r'[^\d]'), '');
    } else {
      areaCode    = '+${split.areaCode}';
      phoneNumber = split.localNumber;
      debugPrint(
        '[RealNumberService] Split → areaCode=$areaCode  '
        'phoneNumber=$phoneNumber',
      );
    }

    final displayName = nickname.isNotEmpty ? nickname : fullPhone;

    // ── 2. Init verification session for register (usedFor=1) ────────────────
    await _sendVerificationSession(
      areaCode:    areaCode,
      phoneNumber: phoneNumber,
      usedFor:     1,
    );

    // ── 3. Register (new user) — fall back to login (returning user) ─────────
    OpenIMRegisterResult result;
    bool isNewUser;

    try {
      result = await OpenIMChatService.instance.registerWithPhone(
        areaCode:    areaCode,
        phoneNumber: phoneNumber,
        nickname:    displayName,
      );
      isNewUser = true; // ← brand-new account
      debugPrint('[RealNumberService] Registered new user: ${result.userID}');
    } on OpenIMChatException catch (e) {
      debugPrint(
        '[RealNumberService] Register failed [${e.code}] "$e" '
        '— retrying as login',
      );

      await _sendVerificationSession(
        areaCode:    areaCode,
        phoneNumber: phoneNumber,
        usedFor:     2,
      );

      result = await OpenIMChatService.instance.loginWithPhone(
        areaCode:    areaCode,
        phoneNumber: phoneNumber,
      );
      isNewUser = false; // ← returning user
      debugPrint('[RealNumberService] Logged in existing user: ${result.userID}');
    }

    // ── 4. Persist session & connect OpenIM SDK ───────────────────────────────
    if (login) {
      await AuthService.instance.persistPhoneSession(
        userId:    result.userID,
        username:  displayName,
        phone:     '$areaCode$phoneNumber',
        imToken:   result.imToken,
        chatToken: result.chatToken,
      );

      AuthService.instance.loginToOpenIM(
        userId:   result.userID,
        nickname: displayName,
        imToken:  result.imToken,
      ).catchError((e) {
        debugPrint('[RealNumberService] Background OpenIM login error: $e');
      });
    }

    return RealNumberRegisterResult(
      username:  displayName,
      userId:    result.userID,
      secret:    result.userID,
      isNewUser: isNewUser, // ← passed through to OtpVerificationPage
    );
  }

  // ---------------------------------------------------------------------------
  //  _sendVerificationSession
  // ---------------------------------------------------------------------------
  Future<void> _sendVerificationSession({
    required String areaCode,
    required String phoneNumber,
    int usedFor = 1,
  }) async {
    try {
      final uri = Uri.parse('$_chatBase/account/code/send');
      final body = {
        'areaCode':    areaCode,
        'phoneNumber': phoneNumber,
        'usedFor':     usedFor,
      };

      debugPrint('[RealNumberService] POST /account/code/send → $body');

      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'operationID':
                  DateTime.now().millisecondsSinceEpoch.toString(),
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      debugPrint(
        '[RealNumberService] /account/code/send response: $decoded',
      );
    } catch (e) {
      debugPrint('[RealNumberService] /account/code/send error (ignoring): $e');
    }
  }

  // ---------------------------------------------------------------------------
  //  _splitFullPhone
  // ---------------------------------------------------------------------------
  _PhoneParts? _splitFullPhone(String fullPhone) {
    final digits = fullPhone.replaceAll(RegExp(r'[^\d]'), '');

    _PhoneParts? bestMatch;

    for (int len = 1; len <= 4; len++) {
      if (digits.length <= len) break;

      final candidate = digits.substring(0, len);

      final country = countries.firstWhere(
        (c) => c.dialCode == candidate,
        orElse: () => const Country(
          name: '', isoCode: '', dialCode: '__none__', flag: '',
        ),
      );

      if (country.dialCode != '__none__') {
        bestMatch = _PhoneParts(
          areaCode:    candidate,
          localNumber: digits.substring(len),
        );
      }
    }

    return bestMatch;
  }
}

// =============================================================================
//  Internal helper
// =============================================================================
class _PhoneParts {
  final String areaCode;
  final String localNumber;
  const _PhoneParts({required this.areaCode, required this.localNumber});
}
