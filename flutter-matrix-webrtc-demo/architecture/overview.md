# Architecture Overview

## System Diagram

```mermaid
flowchart TB
    subgraph App["Flutter App"]
        direction TB
        MC[Matrix Client] --> GC[GetX Controllers]
        WS[WebRTC Service] --> GC
        PS[Push Service] --> GC
        GC --> UI[UI Layer]
    end

    subgraph Infrastructure
        HS[Matrix Homeserver\nSynapse]
        TS[TURN/STUN Server]
        SG[Sygnal Push Gateway]
        FCM[FCM / APNS]
    end

    subgraph Peers
        OC[Other Clients\nWeb / iOS / Android]
    end

    App --> HS
    App --> TS
    App --> SG
    SG --> FCM
    HS --> OC
```

## Data Flow — Outgoing Call

```mermaid
sequenceDiagram
    participant A as User A
    participant CC as CallController
    participant MC as MatrixClient
    participant WS as WebRTCService
    participant HS as Homeserver
    participant B as User B

    A->>CC: Tap "Call User B"
    CC->>WS: initLocalStream(video, audio)
    WS->>CC: localStream ready
    CC->>WS: createPeerConnection
    CC->>WS: createOffer
    WS->>CC: offer SDP
    CC->>MC: sendToDevice(callInvite)
    MC->>HS: Matrix to-device event
    HS->>B: Deliver call invite

    Note over B: User B receives incoming call

    B->>HS: callAnswer
    HS->>MC: to-device event (callAnswer)
    MC->>CC: onCallEvent(answer)
    CC->>WS: getPeerConnection
    CC->>WS: setRemoteDescription(answer)

    Note over A,B: ICE candidate exchange via Matrix to-device

    CC->>WS: addIceCandidate
    WS->>WS: onIceConnectionState → connected
    CC->>CC: callState = connected
```

## Data Flow — Incoming Call

```mermaid
sequenceDiagram
    participant B as User B
    participant CC as CallController
    participant MC as MatrixClient
    participant WS as WebRTCService
    participant HS as Homeserver
    participant A as User A

    MC->>CC: onCallEvent(invite)
    CC->>CC: callState = incoming

    B->>CC: Accept call
    CC->>WS: initLocalStream(video, audio)
    CC->>WS: createPeerConnection
    CC->>WS: setRemoteDescription(offer)
    CC->>WS: createAnswer
    WS->>CC: answer SDP
    CC->>MC: sendToDevice(callAnswer)
    MC->>HS: Matrix to-device event
    HS->>A: Deliver answer

    Note over A,B: ICE candidate exchange

    CC->>WS: addIceCandidate
    WS->>WS: onIceConnectionState → connected
    CC->>CC: callState = connected
```

## Layers

**Presentation Layer**
GetX controllers manage UI state. Pages observe Rx streams and rebuild accordingly. No business logic in widgets. The UI subscribes to `callState` and renders the appropriate screen (idle, outgoing, incoming, connected).

**Domain Layer**
CallController orchestrates the call lifecycle. It subscribes to Matrix to-device events, initiates WebRTC peer connections, and routes ICE candidates bidirectionally. Business rules are enforced here — cannot initiate a call if already connected, cannot accept if already in a call.

**Data Layer**
MatrixClient wraps the Matrix SDK with session persistence via the store interface. WebRTCService wraps peer connection lifecycle with stream-based event emission. Both are injected into controllers via GetX service locator.

## Event Routing Architecture

```
Matrix to-device events
        │
        ▼
MatrixClient._handleToDeviceEvent()
        │
        ├── callInvite  ──→ CallController._handleIncomingCall()
        ├── callAnswer  ──→ CallController._handleCallAnswer()
        ├── callHangup  ──→ CallController._handleRemoteHangup()
        ├── callReject  ──→ CallController._handleCallRejected()
        └── callCandidate ─→ CallController._onRemoteIceCandidate()
                                       │
                                       ▼
                              WebRTCService.addIceCandidate()
                                       │
                                       ▼
                              PeerConnection.addCandidate()
```

## Tech Stack

| Component | Technology | Purpose |
|-----------|------------|---------|
| Framework | Flutter 3.x | Cross-platform UI |
| State Management | GetX | Reactive controllers, DI, minimises boilerplate |
| Messaging Protocol | Matrix (matrix-dart-sdk) | End-to-end encrypted messaging, room management, presence |
| Media Pipeline | WebRTC (flutter_webrtc) | Peer-to-peer audio/video calling, screen sharing |
| Push Notifications | Sygnal + FCM | Matrix-compatible push delivery bridge |
| Local Storage | Isar | Session persistence, room history cache |
| Network Monitoring | connectivity_plus | Detect network transitions for reconnection |
