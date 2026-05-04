import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:wrytte/services/call_service.dart';
import 'package:wrytte/ui/screens/calls/incoming_call_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CallListenerService
//
// Wires CallService.incomingCallStream → IncomingCallScreen.
// Started in AuthWrapper._onAuthSuccess() immediately after login.
// Stopped in AuthWrapper.dispose().
// ─────────────────────────────────────────────────────────────────────────────

class CallListenerService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final CallService  _callService = CallService.instance;

  StreamSubscription? _incomingCallSubscription;

  // ── Start ──────────────────────────────────────────────────────────────────

  void startListening(BuildContext context) {
    final currentUser = _auth.currentUser;
    if (currentUser == null) return;

    // Tell CallService to open its Firestore listener
    _callService.startListeningForIncomingCalls();

    // Forward incoming call events → full-screen IncomingCallScreen
    _incomingCallSubscription =
        _callService.incomingCallStream.listen((call) {
          _showIncomingCall(context, call);
        });
  }

  // ── Stop ───────────────────────────────────────────────────────────────────

  void stopListening() {
    _incomingCallSubscription?.cancel();
    _incomingCallSubscription = null;
    _callService.stopListeningForIncomingCalls();
  }

  // ── Show full-screen incoming call overlay ─────────────────────────────────

  void _showIncomingCall(BuildContext context, CallData call) {
    // Don't stack multiple call screens
    if (ModalRoute.of(context)?.settings.name == '/incoming_call') return;

    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        settings: const RouteSettings(name: '/incoming_call'),
        builder: (_) => IncomingCallScreen(call: call),
        fullscreenDialog: true,
      ),
    );
  }
}
