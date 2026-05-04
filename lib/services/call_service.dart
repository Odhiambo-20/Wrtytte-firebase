import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

enum CallType { voice, video }

enum CallStatus { ringing, accepted, rejected, ended, missed }

class CallData {
  final String callId;
  final String callerId;
  final String callerName;
  final String callerAvatar;
  final String receiverId;
  final CallType type;
  CallStatus status;

  CallData({
    required this.callId,
    required this.callerId,
    required this.callerName,
    required this.callerAvatar,
    required this.receiverId,
    required this.type,
    required this.status,
  });

  factory CallData.fromMap(String id, Map<String, dynamic> data) {
    return CallData(
      callId:       id,
      callerId:     data['callerId']     ?? '',
      callerName:   data['callerName']   ?? '',
      callerAvatar: data['callerAvatar'] ?? '',
      receiverId:   data['receiverId']   ?? '',
      type:   data['type'] == 'video' ? CallType.video : CallType.voice,
      status: _parseStatus(data['status']),
    );
  }

  static CallStatus _parseStatus(String? s) {
    switch (s) {
      case 'accepted': return CallStatus.accepted;
      case 'rejected': return CallStatus.rejected;
      case 'ended':    return CallStatus.ended;
      case 'missed':   return CallStatus.missed;
      default:         return CallStatus.ringing;
    }
  }

  bool get isVoice => type == CallType.voice;
  bool get isVideo => type == CallType.video;
}

class CallService {
  // ── Singleton ──────────────────────────────────────────────────────────────
  CallService._();
  static final CallService instance = CallService._();

  // ── Firebase ───────────────────────────────────────────────────────────────
  final FirebaseFirestore _db   = FirebaseFirestore.instance;
  final FirebaseAuth      _auth = FirebaseAuth.instance;

  // ── WebRTC ─────────────────────────────────────────────────────────────────
  RTCPeerConnection? _peerConnection;
  MediaStream?       _localStream;
  MediaStream?       _remoteStream;

  // ── State ──────────────────────────────────────────────────────────────────
  String? _currentCallId;
  bool    _isCaller = false;

  StreamSubscription? _callStatusSub;
  StreamSubscription? _candidatesSub;
  StreamSubscription? _incomingCallSub;

  // ── Stream controllers ─────────────────────────────────────────────────────
  final _incomingCallController  = StreamController<CallData>.broadcast();
  final _callStatusController    = StreamController<CallStatus>.broadcast();
  final _remoteStreamController  = StreamController<MediaStream>.broadcast();
  // NEW: fires when local camera/mic stream is ready so the UI can attach it
  final _localStreamController   = StreamController<MediaStream>.broadcast();

  // ── Public streams ─────────────────────────────────────────────────────────
  Stream<CallData>    get incomingCallStream => _incomingCallController.stream;
  Stream<CallStatus>  get callStatusStream   => _callStatusController.stream;
  Stream<MediaStream> get remoteStreamStream => _remoteStreamController.stream;
  Stream<MediaStream> get localStreamStream  => _localStreamController.stream;

  // ── Accessors ──────────────────────────────────────────────────────────────
  MediaStream? get localStream   => _localStream;
  MediaStream? get remoteStream  => _remoteStream;
  String?      get currentCallId => _currentCallId;

  // ── STUN config ───────────────────────────────────────────────────────────
  static const Map<String, dynamic> _iceConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  // ══════════════════════════════════════════════════════════════════════════
  //  INCOMING CALL LISTENER
  // ══════════════════════════════════════════════════════════════════════════

  void startListeningForIncomingCalls() {
    final myId = _auth.currentUser?.uid;
    if (myId == null) return;

    _incomingCallSub?.cancel();
    _incomingCallSub = _db
        .collection('calls')
        .where('receiverId', isEqualTo: myId)
        .where('status',     isEqualTo: 'ringing')
        .snapshots()
        .listen((snapshot) {
          for (final change in snapshot.docChanges) {
            if (change.type == DocumentChangeType.added) {
              final data = change.doc.data() as Map<String, dynamic>?;
              if (data == null) continue;
              _incomingCallController.add(
                CallData.fromMap(change.doc.id, data),
              );
            }
          }
        });
  }

  void stopListeningForIncomingCalls() {
    _incomingCallSub?.cancel();
    _incomingCallSub = null;
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  MAKE CALL  (caller side)
  // ══════════════════════════════════════════════════════════════════════════

  Future<String> makeCall({
    required String   receiverId,
    required CallType type,
    required String   callerName,
    String            callerAvatar = '',
  }) async {
    final myId = _auth.currentUser?.uid;
    if (myId == null) throw Exception('Not authenticated');

    _isCaller = true;

    // 1. Local media — emit on stream so CallScreen can attach to renderer
    await _getLocalStream(type);

    // 2. Peer connection
    await _createPeerConnection();

    // 3. Firestore call doc
    final callRef  = _db.collection('calls').doc();
    _currentCallId = callRef.id;

    await callRef.set({
      'callerId':     myId,
      'callerName':   callerName,
      'callerAvatar': callerAvatar,
      'receiverId':   receiverId,
      'type':         type == CallType.video ? 'video' : 'voice',
      'status':       'ringing',
      'offer':        null,
      'answer':       null,
      'createdAt':    FieldValue.serverTimestamp(),
      'endedAt':      null,
    });

    // 4. ICE candidates → callerCandidates
    _peerConnection!.onIceCandidate = (candidate) {
      callRef.collection('callerCandidates').add(candidate.toMap());
    };

    // 5. Create + set offer
    final offer = await _peerConnection!.createOffer({
      'mandatory': {
        'OfferToReceiveAudio': true,
        'OfferToReceiveVideo': type == CallType.video,
      },
    });
    await _peerConnection!.setLocalDescription(offer);

    // 6. Write offer
    await callRef.update({
      'offer': {'sdp': offer.sdp, 'type': offer.type},
    });

    // 7. Watch for answer / rejection / end
    _callStatusSub = callRef.snapshots().listen((snap) async {
      final data   = snap.data() as Map<String, dynamic>?;
      if (data == null) return;
      final status = data['status'] as String?;

      if (status == 'accepted' && data['answer'] != null) {
        final remote = await _peerConnection?.getRemoteDescription();
        if (remote == null) {
          final a = data['answer'] as Map<String, dynamic>;
          await _peerConnection?.setRemoteDescription(
            RTCSessionDescription(a['sdp'], a['type']),
          );
        }
        _callStatusController.add(CallStatus.accepted);
      } else if (status == 'rejected') {
        _callStatusController.add(CallStatus.rejected);
        await _cleanup();
      } else if (status == 'ended') {
        _callStatusController.add(CallStatus.ended);
        await _cleanup();
      }
    });

    // 8. Watch receiver's ICE candidates
    _listenForRemoteCandidates(callRef, 'receiverCandidates');

    return _currentCallId!;
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  ACCEPT CALL  (receiver side)
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> acceptCall(CallData call) async {
    _isCaller      = false;
    _currentCallId = call.callId;

    final callRef = _db.collection('calls').doc(call.callId);

    // 1. Local media — emit on stream so CallScreen can attach to renderer
    await _getLocalStream(call.type);

    // 2. Peer connection
    await _createPeerConnection();

    // 3. Read offer
    final snap = await callRef.get();
    final data = snap.data() as Map<String, dynamic>?;
    if (data == null) throw Exception('Call document not found');

    final offerMap = data['offer'] as Map<String, dynamic>?;
    if (offerMap == null) throw Exception('Offer missing');

    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(offerMap['sdp'], offerMap['type']),
    );

    // 4. ICE candidates → receiverCandidates
    _peerConnection!.onIceCandidate = (candidate) {
      callRef.collection('receiverCandidates').add(candidate.toMap());
    };

    // 5. Create + set answer
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);

    // 6. Write answer + accept
    await callRef.update({
      'answer': {'sdp': answer.sdp, 'type': answer.type},
      'status': 'accepted',
    });

    // 7. Watch caller's ICE candidates
    _listenForRemoteCandidates(callRef, 'callerCandidates');

    // 8. Watch for call end
    _callStatusSub = callRef.snapshots().listen((snap) {
      final d = snap.data() as Map<String, dynamic>?;
      if (d == null) return;
      if (d['status'] == 'ended') {
        _callStatusController.add(CallStatus.ended);
        _cleanup();
      }
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  REJECT CALL
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> rejectCall(String callId) async {
    await _db.collection('calls').doc(callId).update({
      'status':  'rejected',
      'endedAt': FieldValue.serverTimestamp(),
    });
    await _cleanup();
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  END CALL  (either side)
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> endCall() async {
    if (_currentCallId != null) {
      try {
        await _db.collection('calls').doc(_currentCallId).update({
          'status':  'ended',
          'endedAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        debugPrint('[CallService] endCall error: $e');
      }
    }
    await _cleanup();
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  MEDIA CONTROLS
  // ══════════════════════════════════════════════════════════════════════════

  void setMicrophoneMuted(bool muted) {
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !muted);
  }

  void setCameraEnabled(bool enabled) {
    _localStream?.getVideoTracks().forEach((t) => t.enabled = enabled);
  }

  Future<void> setSpeakerOn(bool on) async {
    await Helper.setSpeakerphoneOn(on);
  }

  Future<void> switchCamera() async {
    final track = _localStream?.getVideoTracks().firstOrNull;
    if (track != null) await Helper.switchCamera(track);
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  PRIVATE
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _getLocalStream(CallType type) async {
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': type == CallType.video
          ? {'facingMode': 'user', 'width': 1280, 'height': 720}
          : false,
    });
    // Emit so CallScreen can attach to the renderer immediately
    _localStreamController.add(_localStream!);
  }

  Future<void> _createPeerConnection() async {
    _peerConnection = await createPeerConnection(_iceConfig);

    _localStream?.getTracks().forEach((track) {
      _peerConnection!.addTrack(track, _localStream!);
    });

    _peerConnection!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
        _remoteStreamController.add(_remoteStream!);
      }
    };

    _peerConnection!.onConnectionState = (state) {
      debugPrint('[CallService] PeerConnection state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _callStatusController.add(CallStatus.ended);
        _cleanup();
      }
    };
  }

  void _listenForRemoteCandidates(
    DocumentReference callRef,
    String collection,
  ) {
    _candidatesSub?.cancel();
    _candidatesSub = callRef
        .collection(collection)
        .snapshots()
        .listen((snap) {
          for (final change in snap.docChanges) {
            if (change.type == DocumentChangeType.added) {
              final d = change.doc.data() as Map<String, dynamic>?;
              if (d == null) continue;
              _peerConnection?.addCandidate(
                RTCIceCandidate(
                  d['candidate'],
                  d['sdpMid'],
                  d['sdpMLineIndex'],
                ),
              );
            }
          }
        });
  }

  Future<void> _cleanup() async {
    _callStatusSub?.cancel();
    _callStatusSub = null;
    _candidatesSub?.cancel();
    _candidatesSub = null;

    await _localStream?.dispose();
    _localStream = null;
    await _remoteStream?.dispose();
    _remoteStream = null;

    await _peerConnection?.close();
    _peerConnection = null;

    _currentCallId = null;
    _isCaller      = false;
  }

  void dispose() {
    stopListeningForIncomingCalls();
    _cleanup();
    _incomingCallController.close();
    _callStatusController.close();
    _remoteStreamController.close();
    _localStreamController.close();
  }
}
