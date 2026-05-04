// websocket_service.dart
//
// This file has been intentionally emptied.
//
// The manual WebSocket connection that used to live here has been fully replaced by the
// OpenIM SDK, which manages its own WebSocket connection internally including
// reconnection, heartbeat, and multiplexing.
//
// OpenIM WebSocket is booted in two steps:
//   1. initSDK()  — called in main.dart on app start
//   2. login()    — called in auth_service.dart after the user authenticates
//
// This stub class exists only so that any file that still has the line:
//   import 'package:wrytte/services/chat/websocket_service.dart';
// continues to compile without error during the migration.
// Once every import of this file has been removed, this file can be deleted.

class WebSocketService {
  WebSocketService._internal();
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;

  // All methods are no-ops. OpenIM handles everything.
  Future<void> connect({required String token}) async {}
  void send(Map<String, dynamic> data) {}
  Future<void> disconnect() async {}
  void dispose() {}
}
