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

  RealNumberRegisterResult({
    required this.username,
    required this.userId,
    required this.secret,
  });
}

// =============================================================================
//  RealNumberService
//
//  Handles phone-based registration and login for ALL countries worldwide.
//
//  Flow:
//    1. sendSmsCode()       — calls /account/code/send (usedFor=1) to init
//                             a verification session on the server.
//                             REQUIRED even with super-code 666666.
//    2. registerRealPhone() —
//         a. Parse fullPhone into areaCode + localNumber (longest-match).
//         b. Call /account/code/send (usedFor=1) to init session.
//         c. POST /account/register  (new user)
//            → on failure (20004 = already registered):
//              call /account/code/send (usedFor=2) then POST /account/login
//         d. Persist session tokens via AuthService.
//         e. Log into OpenIM SDK via AuthService (fire-and-forget).
//         f. Return result so OtpVerificationPage can navigate forward.
// =============================================================================
class RealNumberService {
  RealNumberService();

  static const _chatBase = 'http://34.63.32.143:10008';

  // ---------------------------------------------------------------------------
  //  STEP 1 — "Send OTP"
  //  Calls /account/code/send to initialize a verification session.
  //  The server requires this before it will accept 666666 on register/login.
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
  // ---------------------------------------------------------------------------
  Future<RealNumberRegisterResult> registerRealPhone({
    required String fullPhone,
    required String code,     // ignored — server uses super-code 666666
    String nickname = '',
    bool login = true,
  }) async {
    debugPrint('[RealNumberService] registerRealPhone → "$fullPhone"');

    // ── 1. Parse dial code ───────────────────────────────────────────────────
    //
    // _splitFullPhone tries prefixes of length 1–4 and keeps the LONGEST
    // matching dial code so the most-specific country always wins.
    // e.g. "1876…" → Jamaica +1876, not USA +1

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
    //
    // /account/code/send MUST be called before /account/register.
    // Without it the server returns errCode 1001 (ArgsError) even with
    // the super-code 666666 configured in chat.yaml.
    await _sendVerificationSession(
      areaCode:    areaCode,
      phoneNumber: phoneNumber,
      usedFor:     1,
    );

    // ── 3. Register (new user) — fall back to login (returning user) ─────────
    //
    // Try register first. If errCode 20004 (AccountAlreadyRegister), re-init
    // session with usedFor=2 and attempt login instead.

    OpenIMRegisterResult result;

    try {
      result = await OpenIMChatService.instance.registerWithPhone(
        areaCode:    areaCode,
        phoneNumber: phoneNumber,
        nickname:    displayName,
      );
      debugPrint('[RealNumberService] Registered new user: ${result.userID}');
    } on OpenIMChatException catch (e) {
      debugPrint(
        '[RealNumberService] Register failed [${e.code}] "$e" '
        '— retrying as login',
      );

      // Re-init session for login (usedFor=2) — required by the server
      await _sendVerificationSession(
        areaCode:    areaCode,
        phoneNumber: phoneNumber,
        usedFor:     2,
      );

      // Login uses FLAT fields (no "user" wrapper) — confirmed via curl
      result = await OpenIMChatService.instance.loginWithPhone(
        areaCode:    areaCode,
        phoneNumber: phoneNumber,
      );
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

      // Fire-and-forget — do NOT await. SDK connects in the background.
      // Navigation happens immediately after this method returns.
      AuthService.instance.loginToOpenIM(
        userId:   result.userID,
        nickname: displayName,
        imToken:  result.imToken,
      ).catchError((e) {
        debugPrint('[RealNumberService] Background OpenIM login error: $e');
      });
    }

    return RealNumberRegisterResult(
      username: displayName,
      userId:   result.userID,
      secret:   result.userID,
    );
  }

  // ---------------------------------------------------------------------------
  //  _sendVerificationSession
  //
  //  POST /account/code/send
  //  Initializes a verification session on the OpenIM chat server.
  //  Must be called before /account/register or /account/login.
  //  Errors are logged but never rethrown — auth flow always continues.
  //
  //  usedFor: 1 = register, 2 = login / reset password
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
  //
  //  Strips non-digits from fullPhone then tries every prefix of length 1–4
  //  against the countries list. The LONGEST match wins so that e.g.
  //  Caribbean numbers (+1876) are not swallowed by the generic +1 (USA).
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
