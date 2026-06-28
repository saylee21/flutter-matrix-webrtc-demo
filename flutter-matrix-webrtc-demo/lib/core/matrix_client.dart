import 'dart:async';

class MatrixClient {
  late Client _client;
  final Store _store;
  final RxBool isSyncing = false.obs;
  final Rx<SyncStatus> syncStatus = SyncStatus.disconnected.obs;

  final StreamController<CallEvent> _callEventController =
      StreamController<CallEvent>.broadcast();
  final StreamController<IceCandidateEvent> _candidateController =
      StreamController<IceCandidateEvent>.broadcast();

  Stream<CallEvent> get onCallEvent => _callEventController.stream;
  Stream<IceCandidateEvent> get onIceCandidate => _candidateController.stream;

  MatrixClient(this._store);

  Future<bool> tryRestoreSession() async {
    try {
      _client = Client(
        'io.app.communicator',
        store: _store,
        databaseBuilder: (_, __) async => _store,
      );

      if (await _client.database?.isLoggedIn() == true) {
        await _client.startSync();
        syncStatus.value = SyncStatus.connected;
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  Future<void> login({
    required String homeserver,
    required String userId,
    required String password,
  }) async {
    _client = Client(
      'io.app.communicator',
      store: _store,
      databaseBuilder: (_, __) async => _store,
    );

    await _client.login(
      LoginType.mLoginPassword,
      userId,
      password,
      initialDeviceDisplayName: 'Communicator',
    );

    _client.onSync.stream.listen(_handleSyncUpdate);
    _client.onEvent.stream.listen(_handleToDeviceEvent);

    await _client.setSyncFilter(SyncFilter(
      room: RoomFilter(
        timeline: TimelineFilter(limit: 50),
        includeLeave: false,
      ),
    ));

    await _client.startSync(200);
    syncStatus.value = SyncStatus.connected;
  }

  void _handleSyncUpdate(SyncUpdate update) {
    isSyncing.value = update.status == SyncStatus.syncing;
    syncStatus.value = update.status;
  }

  void _handleToDeviceEvent(Event event) {
    switch (event.type) {
      case EventType.callInvite:
        _callEventController.add(CallEvent(
          type: CallEventType.invite,
          senderId: event.senderId,
          content: event.content,
        ));
        break;

      case EventType.callAnswer:
        _callEventController.add(CallEvent(
          type: CallEventType.answer,
          senderId: event.senderId,
          content: event.content,
        ));
        break;

      case EventType.callHangup:
        _callEventController.add(CallEvent(
          type: CallEventType.hangup,
          senderId: event.senderId,
          content: event.content,
        ));
        break;

      case EventType.callCandidate:
        _candidateController.add(IceCandidateEvent(
          senderId: event.senderId,
          content: event.content,
        ));
        break;

      case EventType.callReject:
        _callEventController.add(CallEvent(
          type: CallEventType.reject,
          senderId: event.senderId,
          content: event.content,
        ));
        break;
    }
  }

  Stream<Room> roomStream() => _client.onRoom.stream;

  Future<void> sendMessage({
    required String roomId,
    required String text,
  }) async {
    final room = _client.getRoomById(roomId);
    if (room == null) return;
    await room.sendTextEvent(text);
  }

  Future<void> sendToDevice({
    required String userId,
    required String type,
    required Map<String, dynamic> content,
  }) async {
    await _client.sendToDevice(type, {
      userId: {'*': content},
    });
  }

  Future<void> sendIceCandidate({
    required String targetUserId,
    required Map<String, dynamic> candidate,
  }) async {
    await _client.sendToDevice(EventType.callCandidate, {
      targetUserId: {'*': candidate},
    });
  }

  Future<void> dispose() async {
    await _client.stopSync();
    _client.dispose();
    _callEventController.close();
    _candidateController.close();
  }
}

enum SyncStatus { disconnected, syncing, connected }

enum CallEventType { invite, answer, hangup, reject }

class CallEvent {
  final CallEventType type;
  final String senderId;
  final Map<String, dynamic> content;

  CallEvent({
    required this.type,
    required this.senderId,
    required this.content,
  });
}

class IceCandidateEvent {
  final String senderId;
  final Map<String, dynamic> content;

  IceCandidateEvent({required this.senderId, required this.content});
}
