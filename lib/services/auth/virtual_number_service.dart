import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:wrytte/models/auth_models/auth_user.dart';
import 'package:wrytte/services/auth/auth_service.dart';

class VirtualNumberService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  VirtualNumberService();

  /// 1️ Get an available Wrytte ID number from Firebase.
  Future<String> getAvailableVpn() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      final candidate = _generateVirtualNumber();
      final ref = _firestore.collection('reserved_wrytte_ids').doc(candidate);

      final reserved = await _firestore.runTransaction<bool>((transaction) async {
        final doc = await transaction.get(ref);
        if (doc.exists) return false;

        transaction.set(ref, {
          'value': candidate,
          'reservedAt': FieldValue.serverTimestamp(),
          'claimed': false,
        });

        return true;
      });

      if (reserved) return candidate;
    }

    throw Exception('Failed to allocate Wrytte ID number');
  }

  /// 2️ Send/store email verification code through the Firebase auth service.
  Future<void> sendEmailCode(String email) async {
    await AuthService.instance.sendEmailCode(email);
  }

  /// 3️ Verify email + activate Wrytte ID in Firebase.
  Future<AuthUser> registerVpn({
    required String email,
    required String code,
    required String phone,
  }) async {
    final user = await AuthService.instance.registerVirtualPhone(
      email: email,
      code: code,
      phone: phone,
      username: email.split('@').first,
      login: true,
    );

    await _firestore.collection('reserved_wrytte_ids').doc(phone).set({
      'claimed': true,
      'claimedBy': user.userId,
      'claimedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    return user;
  }

  String _generateVirtualNumber() {
    final random = Random.secure();
    final first = 10 + random.nextInt(90);
    final second = 100 + random.nextInt(900);
    final third = 100 + random.nextInt(900);
    final fourth = 100 + random.nextInt(900);
    return '$first$second$third$fourth';
  }
}
