import 'package:cloud_firestore/cloud_firestore.dart';

class AppMetaService {
  AppMetaService._();
  static final AppMetaService instance = AppMetaService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // PING (Health Check)

  Future<bool> ping() async {
    try {
      await _firestore.collection('app_meta').limit(1).get();
      return true;
    } catch (_) {
      return false;
    }
  }

  // VERSION

  Future<Map<String, dynamic>> getVersion() async {
    final doc = await _firestore.collection('app_meta').doc('version').get();
    return doc.data() ?? {'version': '1.0.0'};
  }

  // STATS (Optional)

  Future<Map<String, dynamic>> getStats() async {
    final doc = await _firestore.collection('app_meta').doc('stats').get();
    return doc.data() ?? {};
  }
}
