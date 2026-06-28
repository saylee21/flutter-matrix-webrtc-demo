# Flutter Matrix + WebRTC Communication Suite

A production-grade reference architecture for building real-time messaging and calling applications using the Matrix Protocol and WebRTC in Flutter.

This is not a working app — it's a documented architecture showcase demonstrating how to wire Matrix SDK, WebRTC, push notifications (Sygnal + FCM), screen sharing, and group calling into a single Flutter codebase using clean architecture with GetX.

---

## Why This Matters

Most Flutter developers build CRUD apps. This repo documents patterns for:

- Real-time state synchronisation via Matrix event streams
- Peer-to-peer media pipelines with WebRTC
- Push notification delivery through Matrix's Sygnal proxy
- Background execution and call state management
- Cross-platform screen sharing

---

## Architecture

```
lib/
├── core/
│   ├── matrix_client.dart          ─ Matrix SDK initialisation and session management
│   ├── webrtc_service.dart         ─ WebRTC peer connection lifecycle
│   ├── push/
│   │   ├── sygnal_service.dart     ─ Sygnal push gateway integration
│   │   └── fcm_service.dart        ─ Firebase Cloud Messaging bridge
│   ├── network/
│   │   └── connectivity_service.dart
│   └── utils/
│       ├── permission_handler.dart
│       └── audio_route_manager.dart
│
├── features/
│   ├── auth/
│   │   ├── data/
│   │   │   └── matrix_auth_repository.dart
│   │   ├── domain/
│   │   │   └── auth_controller.dart
│   │   └── presentation/
│   │       └── login_page.dart
│   │
│   ├── chat/
│   │   ├── data/
│   │   │   └── room_repository.dart     ─ Room sync, timeline, state events
│   │   ├── domain/
│   │   │   └── chat_controller.dart
│   │   └── presentation/
│   │       ├── room_list_page.dart
│   │       └── chat_view.dart
│   │
│   └── calling/
│       ├── data/
│       │   └── call_repository.dart
│       ├── domain/
│       │   ├── call_controller.dart     ─ Offer/answer, ICE, hold, mute
│       │   └── call_state.dart
│       └── presentation/
│           ├── incoming_call_sheet.dart
│           ├── active_call_screen.dart
│           └── screen_share_widget.dart
│
└── config/
    └── app_config.dart
```

### Key Architecture Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Protocol | Matrix over Firebase | Decentralised, self-hostable, end-to-end encryption by default |
| Media | WebRTC (no Agora/Twilio) | Direct peer-to-peer, no per-minute costs, full control |
| State | GetX over Bloc/Riverpod | Minimal boilerplate, built-in dependency injection, team velocity |
| Push | Sygnal + FCM | FCM alone cannot deliver Matrix room events; Sygnal bridges the gap |
| Local storage | Isar | Fast, reactive, supports complex queries for room history |

---

## Hard Problems Solved

### 1. Sygnal Push Gateway Setup

Matrix does not use FCM natively. When the app is backgrounded, the Matrix homeserver cannot deliver events directly. Sygnal acts as a push gateway:

- Homeserver sends push notification to Sygnal
- Sygnal formats and forwards to FCM/APNS
- Device wakes, connects to Matrix, and syncs

The challenge is configuring Sygnal to preserve Matrix's encryption model while routing through platform push services. The key is mapping FCM tokens to Matrix device IDs so push notifications carry enough context to decrypt upon receipt.

### 2. RPScreenRecorder Conflict with WebRTC

On iOS, `RPScreenRecorder` (used for screen broadcast) conflicts with WebRTC's audio/video capture pipeline. Both compete for the same media subsystem.

Resolution path:
- Detect when `RPBroadcastActivityViewController` is presented
- Pause local video track before broadcast starts
- Restart camera track after broadcast ends
- Use a separate audio session category broadcast vs call

### 3. FCM Delivery on Background State

FCM delivery reliability drops significantly when the app transitions between foreground, background, and killed states — especially on Chinese OEM devices (Xiaomi, Oppo, OnePlus).

Solution:
- Implement `onBackgroundMessage` handler that establishes a lightweight Matrix sync connection
- Store last known event ID in SharedPreferences
- On app resume, fast-forward sync from stored event ID
- Show local notification only for missed calls (not every message)

### 4. WebRTC Reconnection Logic

Network handoffs (WiFi → mobile data) kill WebRTC peer connections. ICE restart alone is not always sufficient.

Strategy:
- Monitor connectivity via `connectivity_plus`
- On network change: emit ICE restart, do not terminate the call
- If no media received for 8 seconds, tear down and notify the remote peer via Matrix to-device message
- Re-establish via a new offer from the peer with the better connection

---

## Code Snippets

### Matrix Client Initialisation with Sync Filter

```dart
class MatrixClient {
  late Client _client;
  final Store _store;

  final StreamController<CallEvent> _callEventController =
      StreamController<CallEvent>.broadcast();
  final StreamController<IceCandidateEvent> _candidateController =
      StreamController<IceCandidateEvent>.broadcast();

  Stream<CallEvent> get onCallEvent => _callEventController.stream;
  Stream<IceCandidateEvent> get onIceCandidate => _candidateController.stream;

  MatrixClient(this._store);

  Future<bool> tryRestoreSession() async {
    _client = Client('io.app.communicator', store: _store);
    if (await _client.database?.isLoggedIn() == true) {
      await _client.startSync();
      return true;
    }
    return false;
  }

  Future<void> login({required String homeserver, required String userId, required String password}) async {
    _client = Client('io.app.communicator', store: _store);
    await _client.login(LoginType.mLoginPassword, userId, password);
    _client.onSync.stream.listen(_handleSyncUpdate);
    _client.onEvent.stream.listen(_handleToDeviceEvent);
    await _client.setSyncFilter(SyncFilter(
      room: RoomFilter(timeline: TimelineFilter(limit: 50), includeLeave: false),
    ));
    await _client.startSync(200);
  }

  void _handleToDeviceEvent(Event event) {
    switch (event.type) {
      case EventType.callInvite:
        _callEventController.add(CallEvent(CallEventType.invite, event.senderId, event.content));
        break;
      case EventType.callAnswer:
        _callEventController.add(CallEvent(CallEventType.answer, event.senderId, event.content));
        break;
      case EventType.callHangup:
        _callEventController.add(CallEvent(CallEventType.hangup, event.senderId, event.content));
        break;
      case EventType.callCandidate:
        _candidateController.add(IceCandidateEvent(event.senderId, event.content));
        break;
    }
  }
}
```

### WebRTC Peer Connection with Stream-Based Events

```dart
class WebRTCService {
  final Map<String, PeerConnection> _peers = {};

  final StreamController<IceCandidateEvent> _candidateController =
      StreamController<IceCandidateEvent>.broadcast();
  final StreamController<MediaStream> _remoteStreamController =
      StreamController<MediaStream>.broadcast();

  Stream<IceCandidateEvent> get onIceCandidate => _candidateController.stream;
  Stream<MediaStream> get onRemoteStream => _remoteStreamController.stream;

  Future<PeerConnection> createPeerConnection({
    required String roomId,
    required RTCConfiguration config,
  }) async {
    final pc = await createPeerConnection(config);
    _peers[roomId] = pc;

    _localStream?.getTracks().forEach((track) => pc.addTrack(track, _localStream!));

    pc.onIceCandidate = (candidate) {
      if (candidate == null) return;
      _candidateController.add(IceCandidateEvent(roomId: roomId, candidate: candidate));
    };

    pc.onTrack = (event) {
      _remoteStreamController.add(event.streams.first);
    };

    return pc;
  }

  Future<void> addIceCandidate({
    required String roomId, required String sdpMid,
    required int sdpMLineIndex, required String candidate,
  }) async {
    final pc = _peers[roomId];
    if (pc == null) return;
    await pc.addCandidate(RTCIceCandidate(candidate, sdpMid, sdpMLineIndex));
  }
}
```

### Call Offer/Answer with Full ICE Routing

```dart
Future<void> initiateCall({required String targetUserId, required String roomId}) async {
  await _webrtc.initLocalStream(video: true, audio: true);
  final pc = await _webrtc.createPeerConnection(roomId: roomId, config: _defaultConfig);
  final offer = await pc.createOffer();
  await pc.setLocalDescription(offer);
  await _matrix.sendToDevice(userId: targetUserId, type: EventType.callInvite, content: {
    'call_id': roomId, 'offer': offer.sdp, 'type': 'video',
  });
}

Future<void> acceptCall({required String roomId, required String sdpOffer, required String fromUserId}) async {
  await _webrtc.initLocalStream(video: true, audio: true);
  final pc = await _webrtc.createPeerConnection(roomId: roomId, config: _defaultConfig);
  await pc.setRemoteDescription(RTCSessionDescription(sdpOffer, 'offer'));
  final answer = await pc.createAnswer();
  await pc.setLocalDescription(answer);
  await _matrix.sendToDevice(userId: fromUserId, type: EventType.callAnswer, content: {
    'call_id': roomId, 'answer': answer.sdp,
  });
}
```

---

## End-to-End Encryption

Matrix provides end-to-end encryption at the protocol level using Olm/Megolm double-ratchet, the same algorithm behind Signal. The SDK handles key exchange, session management, and room-level encryption automatically once enabled.

What we handled explicitly:

- **Device key verification** — cross-signing trust establishment on first login, with a QR code fallback for verification between devices
- **Key backup** — encrypted room key backups stored on the homeserver, recoverable via a recovery key or passphrase
- **Unverified device handling** — inbound messages from unverified devices are flagged in the UI rather than blocked, allowing users to manually verify
- **Encrypted push notifications** — Sygnal is configured to strip message content from push payloads, delivering only the event ID and room metadata. The app decrypts content locally upon opening the notification

E2EE was non-negotiable for this project given the communication context. Matrix's built-in encryption eliminated the need for a separate layer while maintaining compatibility with web and desktop clients in the same rooms.

---

---

## Directory Reference

- `lib/core/` — Matrix client, WebRTC service, push notification service
- `lib/features/calling/` — Call lifecycle controller, event routing
- `lib/features/chat/` — Room subscription, message sending, timeline
- `architecture/` — System diagrams, Mermaid sequence charts
- `pubspec.yaml` — Dependency versions

---


## Getting Started (Demo Mode)

This repo documents architecture, not a runnable app. To explore the structure:

```bash
git clone https://github.com/saylee21/flutter-matrix-webrtc-demo
cd flutter-matrix-webrtc-demo
```

Open in your editor and browse `lib/` and `architecture/` for the detailed breakdowns.

---

## Related Repositories

- [flutter-offline-first-architecture](https://github.com/saylee21/flutter-offline-first-architecture) — Offline-first patterns using Isar and background sync

---

## About

Built by [Saylee Bharsakle](https://saylee21.github.io). 3 years shipping Flutter apps in production across hospitality, agritech, insurance, and fintech.
