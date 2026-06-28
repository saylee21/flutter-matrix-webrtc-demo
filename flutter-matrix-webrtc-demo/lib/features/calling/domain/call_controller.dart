import 'dart:async';

class CallController extends GetxController {
  final MatrixClient _matrix;
  final WebRTCService _webrtc;

  final Rx<CallState> callState = CallState.idle.obs;
  final RxBool isMuted = false.obs;
  final RxBool isSpeakerOn = false.obs;
  final RxBool isScreenSharing = false.obs;
  final Rx<CallTimer> callTimer = Rx<CallTimer>(CallTimer());

  String? _activeRoomId;
  String? _remoteUserId;
  RTCConfiguration? _rtcConfig;
  StreamSubscription? _candidateSub;
  StreamSubscription? _iceCandidateFromMatrixSub;
  StreamSubscription? _callEventSub;
  StreamSubscription? _remoteTrackSub;
  Timer? _callTimerTick;

  static const String _stunServer = 'stun:stun.l.google.com:19302';

  CallController(this._matrix, this._webrtc) {
    _setupEventListeners();
  }

  RTCConfiguration get _defaultConfig => RTCConfiguration(
    iceServers: [
      RTCIceServer(urls: [_stunServer]),
    ],
    iceTransportPolicy: RTCIceTransportPolicy.all,
    bundlePolicy: RTCBundlePolicy.maxBundle,
    rtcpMuxPolicy: RTCRtcpMuxPolicy.require,
  );

  void _setupEventListeners() {
    _webrtc.onIceCandidate.listen(_onLocalIceCandidate);
    _webrtc.onRemoteStream.listen((stream) {
      if (_activeRoomId != null) {
        // Remote stream is now available for rendering
      }
    });
    _callEventSub = _matrix.onCallEvent.listen(_onCallEvent);
    _iceCandidateFromMatrixSub =
        _matrix.onIceCandidate.listen(_onRemoteIceCandidate);
  }

  void _onLocalIceCandidate(IceCandidateEvent event) {
    if (_remoteUserId == null) return;

    _matrix.sendIceCandidate(
      targetUserId: _remoteUserId!,
      candidate: {
        'call_id': _activeRoomId,
        'candidate': event.candidate.candidate,
        'sdpMid': event.candidate.sdpMid,
        'sdpMLineIndex': event.candidate.sdpMLineIndex,
      },
    );
  }

  void _onRemoteIceCandidate(IceCandidateEvent event) {
    if (_activeRoomId == null) return;

    _webrtc.addIceCandidate(
      roomId: _activeRoomId!,
      sdpMid: event.content['sdpMid'] as String,
      sdpMLineIndex: event.content['sdpMLineIndex'] as int,
      candidate: event.content['candidate'] as String,
    );
  }

  void _onCallEvent(CallEvent event) {
    switch (event.type) {
      case CallEventType.invite:
        _handleIncomingCall(event);
        break;
      case CallEventType.answer:
        _handleCallAnswer(event);
        break;
      case CallEventType.hangup:
        _handleRemoteHangup(event);
        break;
      case CallEventType.reject:
        _handleCallRejected(event);
        break;
    }
  }

  Future<void> initiateCall({
    required String targetUserId,
    required String roomId,
    required bool isVideo,
  }) async {
    callState.value = CallState.outgoing;
    _activeRoomId = roomId;
    _remoteUserId = targetUserId;

    await _webrtc.initLocalStream(video: isVideo, audio: true);

    final pc = await _webrtc.createPeerConnection(
      roomId: roomId,
      config: _defaultConfig,
    );

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    await _matrix.sendToDevice(
      userId: targetUserId,
      type: EventType.callInvite,
      content: {
        'call_id': roomId,
        'offer': offer.sdp,
        'type': isVideo ? 'video' : 'audio',
      },
    );

    Future.delayed(Duration(seconds: 30), () {
      if (callState.value == CallState.outgoing) {
        endCall();
      }
    });
  }

  Future<void> acceptCall({
    required String roomId,
    required String sdpOffer,
    required String fromUserId,
  }) async {
    callState.value = CallState.incoming;
    _activeRoomId = roomId;
    _remoteUserId = fromUserId;

    await _webrtc.initLocalStream(video: true, audio: true);

    final pc = await _webrtc.createPeerConnection(
      roomId: roomId,
      config: _defaultConfig,
    );

    await pc.setRemoteDescription(
      RTCSessionDescription(sdpOffer, 'offer'),
    );

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);

    await _matrix.sendToDevice(
      userId: fromUserId,
      type: EventType.callAnswer,
      content: {
        'call_id': roomId,
        'answer': answer.sdp,
      },
    );

    callState.value = CallState.connected;
    _startCallTimer();
  }

  void _handleIncomingCall(CallEvent event) {
    callState.value = CallState.incoming;
    _activeRoomId = event.content['call_id'] as String;
    _remoteUserId = event.senderId;

    // UI layer observes callState and shows incoming call sheet
  }

  Future<void> _handleCallAnswer(CallEvent event) async {
    final answer = event.content['answer'] as String;
    if (_activeRoomId == null) return;

    final pc = _currentPeer;
    if (pc == null) return;

    await pc.setRemoteDescription(
      RTCSessionDescription(answer, 'answer'),
    );

    callState.value = CallState.connected;
    _startCallTimer();
  }

  void _handleRemoteHangup(CallEvent event) {
    endCall();
  }

  void _handleCallRejected(CallEvent event) {
    callState.value = CallState.idle;
    _cleanup();
  }

  void rejectIncomingCall() {
    if (_remoteUserId != null && _activeRoomId != null) {
      _matrix.sendToDevice(
        userId: _remoteUserId!,
        type: EventType.callReject,
        content: {'call_id': _activeRoomId},
      );
    }
    callState.value = CallState.idle;
    _cleanup();
  }

  PeerConnection? get _currentPeer =>
      _activeRoomId != null ? _webrtc.getPeerConnection(_activeRoomId!) : null;

  Future<void> endCall() async {
    if (_activeRoomId != null) {
      await _webrtc.endCall(_activeRoomId!);

      if (_remoteUserId != null) {
        await _matrix.sendToDevice(
          userId: _remoteUserId!,
          type: EventType.callHangup,
          content: {'call_id': _activeRoomId},
        );
      }
    }

    callState.value = CallState.idle;
    _stopCallTimer();
    _cleanup();
  }

  void _startCallTimer() {
    _callTimerTick?.cancel();
    _callTimerTick = Timer.periodic(Duration(seconds: 1), (_) {
      final current = callTimer.value;
      callTimer.value = CallTimer(
        seconds: current.seconds + 1,
        minutes: current.minutes + (current.seconds + 1 >= 60 ? 1 : 0),
      );
    });
  }

  void _stopCallTimer() {
    _callTimerTick?.cancel();
    callTimer.value = CallTimer();
  }

  void _cleanup() {
    _activeRoomId = null;
    _remoteUserId = null;
  }

  void toggleMute() {
    isMuted.value = !isMuted.value;
    _webrtc.toggleMute(muted: isMuted.value);
  }

  void toggleSpeaker() {
    isSpeakerOn.value = !isSpeakerOn.value;
  }

  Future<void> toggleScreenShare() async {
    if (isScreenSharing.value) {
      await _webrtc.stopScreenShare();
    } else {
      await _webrtc.startScreenShare();
    }
    isScreenSharing.value = !isScreenSharing.value;
  }

  @override
  void onClose() {
    _callTimerTick?.cancel();
    _candidateSub?.cancel();
    _iceCandidateFromMatrixSub?.cancel();
    _callEventSub?.cancel();
    _remoteTrackSub?.cancel();
    _webrtc.dispose();
    super.onClose();
  }
}

enum CallState { idle, outgoing, incoming, connected, reconnecting }

class CallTimer {
  final int seconds;
  final int minutes;

  CallTimer({this.seconds = 0, this.minutes = 0});

  String get formatted =>
      '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}
