import 'dart:async';

class WebRTCService {
  final Map<String, PeerConnection> _peers = {};
  MediaStream? _localStream;
  bool _isScreenSharing = false;

  final StreamController<RemoteTrackEvent> _trackController =
      StreamController<RemoteTrackEvent>.broadcast();
  final StreamController<IceCandidateEvent> _candidateController =
      StreamController<IceCandidateEvent>.broadcast();
  final StreamController<ConnectionStateEvent> _connectionStateController =
      StreamController<ConnectionStateEvent>.broadcast();

  Stream<RemoteTrackEvent> get onRemoteTrack => _trackController.stream;
  Stream<IceCandidateEvent> get onIceCandidate => _candidateController.stream;
  Stream<ConnectionStateEvent> get onConnectionState =>
      _connectionStateController.stream;

  Stream<MediaStream>? _remoteStreamController;
  final StreamController<MediaStream> _remoteStreamControllerImpl =
      StreamController<MediaStream>.broadcast();
  Stream<MediaStream> get onRemoteStream => _remoteStreamControllerImpl.stream;

  Future<MediaStream> initLocalStream({
    required bool video,
    required bool audio,
  }) async {
    final constraints = MediaConstraints(audio: audio, video: video);
    _localStream = await navigator.mediaDevices.getUserMedia(constraints);
    return _localStream!;
  }

  Future<PeerConnection> createPeerConnection({
    required String roomId,
    required RTCConfiguration config,
  }) async {
    final pc = await createPeerConnection(config);
    _peers[roomId] = pc;

    _localStream?.getTracks().forEach((track) {
      pc.addTrack(track, _localStream!);
    });

    pc.onIceCandidate = (candidate) {
      if (candidate == null) return;
      _candidateController.add(IceCandidateEvent(
        roomId: roomId,
        candidate: candidate,
      ));
    };

    pc.onTrack = (event) {
      if (event.track.kind == 'video') {
        _remoteStreamControllerImpl.add(event.streams.first);
      }
      _trackController.add(RemoteTrackEvent(
        roomId: roomId,
        track: event.track,
        stream: event.streams.first,
      ));
    };

    pc.onIceConnectionState = (state) {
      _connectionStateController.add(ConnectionStateEvent(
        roomId: roomId,
        state: state,
      ));
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        _handleReconnection(roomId);
      }
    };

    return pc;
  }

  Future<void> addIceCandidate({
    required String roomId,
    required String sdpMid,
    required int sdpMLineIndex,
    required String candidate,
  }) async {
    final pc = _peers[roomId];
    if (pc == null) return;

    await pc.addCandidate(RTCIceCandidate(
      candidate,
      sdpMid,
      sdpMLineIndex,
    ));
  }

  Future<void> toggleMute({required bool muted}) async {
    _localStream?.getAudioTracks().forEach((track) {
      track.enabled = !muted;
    });
  }

  Future<void> toggleCamera({required bool on}) async {
    _localStream?.getVideoTracks().forEach((track) {
      track.enabled = on;
    });
  }

  Future<void> switchCamera() async {
    final currentTrack = _localStream?.getVideoTracks().first;
    if (currentTrack == null) return;

    await currentTrack.switchCamera();
  }

  Future<void> startScreenShare() async {
    if (_isScreenSharing) return;

    try {
      final screenStream = await navigator.mediaDevices.getDisplayMedia();
      final screenTrack = screenStream.getVideoTracks().first;

      for (final pc in _peers.values) {
        final sender = pc.getSenders().firstWhere(
          (s) => s.track?.kind == 'video',
        );
        await sender.replaceTrack(screenTrack);
      }

      screenTrack.onEnded = () => stopScreenShare();
      _isScreenSharing = true;
    } catch (e) {
      // User cancelled screen share selection
    }
  }

  Future<void> stopScreenShare() async {
    if (!_isScreenSharing) return;

    final cameraTrack = _localStream?.getVideoTracks().first;
    if (cameraTrack == null) return;

    for (final pc in _peers.values) {
      final sender = pc.getSenders().firstWhere(
        (s) => s.track?.kind == 'video',
      );
      await sender.replaceTrack(cameraTrack);
    }

    _isScreenSharing = false;
  }

  Future<void> _handleReconnection(String roomId) async {
    final pc = _peers[roomId];
    if (pc == null) return;

    try {
      await pc.restartIce();
    } catch (e) {
      _connectionStateController.add(ConnectionStateEvent(
        roomId: roomId,
        state: RTCIceConnectionState.RTCIceConnectionStateFailed,
      ));
    }
  }

  PeerConnection? getPeerConnection(String roomId) => _peers[roomId];

  Future<void> endCall(String roomId) async {
    final pc = _peers.remove(roomId);
    await pc?.close();
  }

  void dispose() {
    for (final pc in _peers.values) {
      pc.close();
    }
    _peers.clear();
    _localStream?.dispose();
    _trackController.close();
    _candidateController.close();
    _connectionStateController.close();
    _remoteStreamControllerImpl.close();
  }
}

class RemoteTrackEvent {
  final String roomId;
  final MediaStreamTrack track;
  final MediaStream stream;

  RemoteTrackEvent({
    required this.roomId,
    required this.track,
    required this.stream,
  });
}

class IceCandidateEvent {
  final String roomId;
  final RTCIceCandidate candidate;

  IceCandidateEvent({required this.roomId, required this.candidate});
}

class ConnectionStateEvent {
  final String roomId;
  final RTCIceConnectionState state;

  ConnectionStateEvent({required this.roomId, required this.state});
}
