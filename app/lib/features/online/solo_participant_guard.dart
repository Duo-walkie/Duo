import 'package:livekit_client/livekit_client.dart' as livekit;

import 'package:one_one_app/one_one.dart';

class SoloSessionContext {
  const SoloSessionContext({
    required this.roomName,
    required this.connectionState,
    required this.remoteParticipantCount,
    required this.remoteCountAtConnect,
    required this.remoteCountAtSoloStart,
    required this.soloDuration,
    required this.remoteIdentities,
  });

  final String roomName;
  final String connectionState;
  final int remoteParticipantCount;

  /// How many remote participants were present when the room first connected.
  /// `0` here (with a later timeout) is the classic "accepted the nudge but the
  /// sender never connected" failure mode.
  final int remoteCountAtConnect;

  /// How many remote participants were present when the solo countdown began.
  final int remoteCountAtSoloStart;

  final Duration soloDuration;
  final List<String> remoteIdentities;
}

class SoloParticipantGuard {
  SoloParticipantGuard({
    required this.userId,
    this.groupId,
    this.onSoloStateChanged,
    this.onSoloTimeout,
  });

  final String userId;
  final String? groupId;

  /// Called whenever the sole-connected-participant state changes.
  final void Function(bool solo)? onSoloStateChanged;

  /// Called after [PresenceConfig.soloParticipantTimeout] elapses while the
  /// local user is still the only connected participant. The guard resets its
  /// own state *before* invoking this; the callback is expected to log the bug
  /// and disconnect the room.
  final Future<void> Function(SoloSessionContext context)? onSoloTimeout;

  Room? _room;
  EventsListener<RoomEvent>? _listener;
  Timer? _soloTimer;
  bool _solo = false;
  int? _remoteCountAtConnect;
  int _remoteCountAtSoloStart = 0;
  DateTime? _soloStartedAt;

  bool get isSolo => _solo;

  /// Attaches to [room]. Safe to call before or after [Room.connect] — the
  /// countdown only starts once LiveKit reports the room as connected.
  void attach(Room room) {
    detach();
    _room = room;
    _listener = room.createListener()
      ..on<RoomConnectedEvent>((_) {
        // Record how many participants were present at first connect. This is
        // the key diagnostic for "accepted nudge but sender never connected".
        _remoteCountAtConnect ??= room.remoteParticipants.length;
        _evaluate();
      })
      ..on<RoomReconnectedEvent>((_) => _evaluate())
      ..on<ParticipantConnectedEvent>((_) => _evaluate())
      ..on<ParticipantDisconnectedEvent>((_) => _evaluate())
      ..on<RoomDisconnectedEvent>((_) => _reset());
    // If the room is somehow already connected when attached (warm room
    // reuse), evaluate immediately.
    _evaluate();
  }

  /// Stops listening and cancels any active countdown.
  void detach() {
    _soloTimer?.cancel();
    _soloTimer = null;
    _listener?.dispose();
    _listener = null;
    _room = null;
    _solo = false;
    _remoteCountAtConnect = null;
    _remoteCountAtSoloStart = 0;
    _soloStartedAt = null;
  }

  void dispose() => detach();

  /// Restarts the solo countdown from zero. Called by the screen when a
  /// connection-mode change (mic-off / call ↔ walkie-talkie) lands so the
  /// countdown re-bases off the latest LiveKit state. No-op unless currently
  /// solo.
  void refreshCountdown() {
    if (!_solo || _room == null) return;
    _restartTimer();
    LogManager.log(
      LogLevel.info,
      'SoloParticipantGuard',
      'Solo countdown refreshed by connection-mode/mic change',
      userId: userId,
      groupId: groupId,
    );
  }

  void _evaluate() {
    final room = _room;
    if (room == null) return;

    final connected = room.connectionState == livekit.ConnectionState.connected;
    final remoteCount = room.remoteParticipants.length;

    if (!connected || remoteCount > 0) {
      _reset();
      return;
    }

    // Connected with zero remote participants → sole participant.
    _enterSolo();
  }

  void _enterSolo() {
    if (_solo) return; // Preserve the original deadline.
    _solo = true;
    _remoteCountAtSoloStart = _room?.remoteParticipants.length ?? 0;
    _soloStartedAt = DateTime.now();
    _startTimer();
    LogManager.log(
      LogLevel.warn,
      'SoloParticipantGuard',
      'Sole connected participant detected (room=${_room?.name}) — starting '
          '${PresenceConfig.soloParticipantTimeout.inSeconds}s disconnection '
          'countdown (remoteCountAtConnect=${_remoteCountAtConnect ?? 'n/a'})',
      userId: userId,
      groupId: groupId,
    );
    onSoloStateChanged?.call(true);
  }

  void _reset() {
    _soloTimer?.cancel();
    _soloTimer = null;
    final wasSolo = _solo;
    _solo = false;
    _remoteCountAtSoloStart = 0;
    _soloStartedAt = null;
    if (wasSolo) onSoloStateChanged?.call(false);
  }

  void _startTimer() {
    _soloTimer?.cancel();
    _soloTimer = Timer(
      PresenceConfig.soloParticipantTimeout,
      _onSoloTimerFired,
    );
  }

  void _restartTimer() {
    _soloStartedAt = DateTime.now();
    _startTimer();
  }

  Future<void> _onSoloTimerFired() async {
    final room = _room;
    if (room == null || !_solo) return;

    // Re-check at fire time: a participant may have joined after the last
    // event, or the room may no longer be connected.
    if (room.connectionState != livekit.ConnectionState.connected) {
      _reset();
      return;
    }
    if (room.remoteParticipants.isNotEmpty) {
      _evaluate();
      return;
    }

    final context = SoloSessionContext(
      roomName: room.name ?? '',
      connectionState: room.connectionState.toString(),
      remoteParticipantCount: room.remoteParticipants.length,
      remoteCountAtConnect: _remoteCountAtConnect ?? 0,
      remoteCountAtSoloStart: _remoteCountAtSoloStart,
      soloDuration: _soloStartedAt == null
          ? PresenceConfig.soloParticipantTimeout
          : DateTime.now().difference(_soloStartedAt!),
      remoteIdentities: room.remoteParticipants.values
          .map((participant) => participant.identity)
          .toList(growable: false),
    );

    // Reset before invoking the async callback so a re-entry (or reconnect)
    // starts from a clean state; the callback performs the actual disconnect.
    _reset();

    LogManager.log(
      LogLevel.error,
      'SoloParticipantGuard',
      'Solo-participant timeout fired — invalid single-user room state '
          '(room=${context.roomName} remoteCount=${context.remoteParticipantCount} '
          'remoteCountAtConnect=${context.remoteCountAtConnect} '
          'soloDuration=${context.soloDuration.inSeconds}s)',
      userId: userId,
      groupId: groupId,
    );

    final callback = onSoloTimeout;
    if (callback == null) return;
    try {
      await callback(context);
    } catch (error) {
      LogManager.log(
        LogLevel.error,
        'SoloParticipantGuard',
        'onSoloTimeout callback failed: $error',
        userId: userId,
        groupId: groupId,
      );
    }
  }
}
