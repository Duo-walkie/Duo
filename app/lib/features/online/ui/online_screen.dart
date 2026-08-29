import 'package:one_one_app/one_one.dart';

part 'online_screen_talk_button.dart';

class OnlineScreen extends StatefulWidget {
  const OnlineScreen({
    super.key,
    required this.identity,
    required this.group,
    this.onlineRepository,
    this.talkRepository,
  });

  final IdentitySession identity;
  final GroupSummary group;
  final OnlineRepository? onlineRepository;
  final TalkRepository? talkRepository;

  @override
  State<OnlineScreen> createState() => _OnlineScreenState();
}

class _OnlineScreenState extends State<OnlineScreen> {
  late final OnlineRepository _onlineRepository =
      widget.onlineRepository ?? OnlineRepository();
  late final TalkRepository _talkRepository =
      widget.talkRepository ?? TalkRepository();
  OnlineSession? _session;
  TalkSession? _talkSession;
  Room? _room;
  EventsListener<RoomEvent>? _roomListener;
  Timer? _heartbeatTimer;
  Timer? _inactivityTimer;
  Timer? _usagePersistTimer;
  DateTime? _lastVoiceActivityAt;
  int _todayOnlineSeconds = 0;
  String? _todayUsageDateKey;
  String _state = 'away';
  String? _message;
  bool _busy = false;
  bool _talkBusy = false;

  // Reconnect state — exponential backoff up to 2 retries.
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 2;
  static const Duration _reconnectBaseDelay = Duration(seconds: 1);
  Timer? _reconnectTimer;

  String get _todayDateKey {
    final now = DateTime.now().toUtc();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    _inactivityTimer?.cancel();
    _usagePersistTimer?.cancel();
    _reconnectTimer?.cancel();
    if (_todayOnlineSeconds > 0 && _session != null) {
      unawaited(_persistDailyUsage());
    }
    final activeTalk = _talkSession;
    if (activeTalk != null) {
      unawaited(_talkRepository.stopTalk(activeTalk, reason: 'screen_closed'));
    }
    unawaited(_disconnectLiveKit());
    super.dispose();
  }

  Future<void> _goOnline() async {
    // 1. Mark connecting
    setState(() {
      _busy = true;
      _state = 'connecting';
      _message = null;
    });

    // 2. Enforce daily usage cap
    final dateKey = _todayDateKey;
    if (_todayUsageDateKey != dateKey) {
      _todayUsageDateKey = dateKey;
      _todayOnlineSeconds = 0;
    }
    final loadedSeconds = await _loadDailyUsage();
    if (loadedSeconds > _todayOnlineSeconds) {
      _todayOnlineSeconds = loadedSeconds;
    }
    if (_todayOnlineSeconds >= PresenceConfig.dailyUsageCap.inSeconds) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _state = 'away';
        _message =
            'Daily usage limit reached (${PresenceConfig.dailyUsageCap.inMinutes} min). '
            'You can go online again tomorrow.';
      });
      return;
    }

    OnlineSession? createdSession;
    final speakerOn = true;
    // 3. Reuse a warmed token/room when one is already prepared
    final preparedToken = LiveKitConnectionWarmer.instance.takeToken(
      widget.group.groupId,
    );
    final preparedRoom = LiveKitConnectionWarmer.instance.takeWarmRoom(
      speakerOn: speakerOn,
    );
    try {
      // 4. Create presence, connect LiveKit, mark live
      createdSession = await _onlineRepository.goOnline(
        identity: widget.identity,
        group: widget.group,
        preparedToken: preparedToken,
      );
      await _connectLiveKit(createdSession, preparedRoom: preparedRoom);
      await _onlineRepository.markLive(createdSession);
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        final activeSession = _session;
        if (activeSession != null) {
          unawaited(_onlineRepository.heartbeat(activeSession));
        }
      });

      setState(() {
        _session = createdSession;
        _state = 'live';
        _message = LiveKitStatus.live;
      });
      // 5. Heartbeat + inactivity + daily usage
      _scheduleInactivityCheck();
      _startUsageTracking();
    } catch (error, stack) {
      unawaited(
        CrashlyticsService.recordNudgeFailure(
          error: error,
          stack: stack,
          failureReason: NudgeFailureReason.livekitSessionFailed,
          receiverId: widget.identity.userId,
          groupId: widget.group.groupId,
          livekitRoomState: _room?.connectionState.toString(),
        ),
      );
      // If a warm room was taken but connect never claimed it, release it.
      if (preparedRoom != null && _room != preparedRoom) {
        unawaited(preparedRoom.dispose());
      }
      await _disconnectLiveKit();
      if (createdSession != null) {
        try {
          await _onlineRepository.goAway(createdSession);
        } catch (_) {
          // Best-effort cleanup after a failed connect.
        }
      }
      if (!mounted) return;
      setState(() {
        _state = 'away';
        _message = LiveKitStatus.sanitizeError(error);
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _goAway() async {
    final session = _session;
    if (session == null) {
      setState(() => _state = 'away');
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      // 1. Stop talk if holding the lock
      final activeTalk = _talkSession;
      if (activeTalk != null) {
        await _talkRepository.stopTalk(activeTalk, reason: 'going_away');
      }
      // 2. Stop heartbeat / inactivity / usage
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      _inactivityTimer?.cancel();
      _inactivityTimer = null;
      _lastVoiceActivityAt = null;
      _usagePersistTimer?.cancel();
      _usagePersistTimer = null;
      if (_todayOnlineSeconds > 0) {
        unawaited(_persistDailyUsage());
      }
      // 3. Disconnect LiveKit and write away
      await _disconnectLiveKit();
      await _onlineRepository.goAway(session);
      setState(() {
        _session = null;
        _talkSession = null;
        _state = 'away';
        _message = LiveKitStatus.away;
      });
    } catch (error) {
      setState(() => _message = LiveKitStatus.sanitizeError(error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _startTalking() async {
    final session = _session;
    if (session == null || _talkSession != null || _talkBusy) return;

    setState(() {
      _talkBusy = true;
      _message = null;
    });

    TalkSession? startedTalk;
    try {
      // 1. Take the talk lock
      startedTalk = await _talkRepository.startTalk(session);
      // 2. Open the local mic
      await _setMicrophoneEnabled(true);
      if (!mounted) return;
      setState(() {
        _talkSession = startedTalk;
        _state = 'talking';
        _message = LiveKitStatus.talking;
      });
      _recordVoiceActivity();
    } catch (error) {
      if (startedTalk != null) {
        await _talkRepository.stopTalk(startedTalk, reason: 'mic_failed');
      }
      if (!mounted) return;
      setState(() {
        _talkSession = null;
        _state = _session == null ? 'away' : 'live';
        _message = LiveKitStatus.sanitizeError(error);
      });
    } finally {
      if (mounted) {
        setState(() => _talkBusy = false);
      }
    }
  }

  Future<void> _stopTalking({String reason = 'released'}) async {
    final talkSession = _talkSession;
    if (talkSession == null) return;

    setState(() {
      _talkSession = null;
      _state = 'live';
    });
    _recordVoiceActivity();

    try {
      await _setMicrophoneEnabled(false);
      await _talkRepository.stopTalk(talkSession, reason: reason);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = 'Couldn’t stop talking. Try again.';
      });
    }
  }

  Future<void> _connectLiveKit(
    OnlineSession session, {
    Room? preparedRoom,
  }) async {
    // 1. Drop any previous room
    await _disconnectLiveKit();

    final room =
        preparedRoom ??
        Room(
          roomOptions: const RoomOptions(
            adaptiveStream: false,
            dynacast: false,
            defaultAudioOutputOptions: AudioOutputOptions(speakerOn: true),
          ),
        );

    _room = room;
    _attachRoomListener(room);

    setState(() {
      _state = 'connecting';
      _message = LiveKitStatus.connecting;
    });

    LogManager.log(
      LogLevel.info,
      'LiveKitManager',
      'Room connect attempt url=${session.livekitServerUrl} '
          'room=${session.livekitRoomName}',
      userId: session.userId,
      groupId: session.groupId,
    );

    try {
      // 2. Connect (20s cap)
      await room
          .connect(
            session.livekitServerUrl,
            session.livekitToken,
            connectOptions: const ConnectOptions(autoSubscribe: true),
          )
          .timeout(const Duration(seconds: 20));
    } catch (error, stack) {
      unawaited(
        CrashlyticsService.recordNudgeFailure(
          error: error,
          stack: stack,
          failureReason: NudgeFailureReason.livekitSessionFailed,
          receiverId: session.userId,
          groupId: session.groupId,
          livekitRoomState: room.connectionState.toString(),
          extras: {'checkpoint': 'room.connect'},
        ),
      );
      rethrow;
    }

    try {
      await room.setSpeakerOn(true);
    } catch (_) {
      // Non-fatal. LiveKit can still use the platform default audio route.
    }

    final localParticipant = room.localParticipant;
    if (localParticipant == null) {
      throw StateError('LiveKit connected without a local participant.');
    }

    // 3. Join muted — talk button opens the mic
    await localParticipant
        .setMicrophoneEnabled(false)
        .timeout(const Duration(seconds: 8));
  }

  void _attachRoomListener(Room room) {
    _roomListener =
        attachLiveKitLifecycleLogs(
            room.createListener(),
            userId: widget.identity.userId,
            groupId: widget.group.groupId,
          )
          ..on<RoomConnectedEvent>((_) {
            _reconnectAttempts = 0;
            _reconnectTimer?.cancel();
            _reconnectTimer = null;
            _setMessage(LiveKitStatus.connected);
          })
          ..on<RoomReconnectingEvent>((_) {
            _setStateAndMessage('reconnecting', LiveKitStatus.reconnecting);
          })
          ..on<RoomReconnectedEvent>((_) {
            _reconnectAttempts = 0;
            _reconnectTimer?.cancel();
            _reconnectTimer = null;
            _setStateAndMessage('live', LiveKitStatus.connected);
          })
          ..on<RoomDisconnectedEvent>((event) {
            _setStateAndMessage(
              'disconnected',
              LiveKitStatus.fromDisconnectReason(event.reason),
            );
            // Attempt automatic reconnect with exponential backoff.
            // Only reconnect if the user is still in a live session (not
            // deliberately going away) and we haven't exhausted retries.
            if (_session != null && _state != 'away') {
              _scheduleReconnect();
            }
          })
          ..on<ParticipantConnectedEvent>((_) {})
          ..on<TrackSubscribedEvent>((_) {})
          ..on<ActiveSpeakersChangedEvent>((event) {
            final remoteSpeakers = event.speakers.where(
              (speaker) => speaker.identity != room.localParticipant?.identity,
            );
            if (event.speakers.isNotEmpty) {
              _recordVoiceActivity();
            }
            if (remoteSpeakers.isNotEmpty) {
              _setMessage(LiveKitStatus.receivingVoice);
            }
          });
  }

  /// Exponential backoff reconnect: 1s → 2s delay, max 2 retries.
  /// After exhausting retries the error is surfaced to the user.
  void _scheduleReconnect() {
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      _setStateAndMessage('away', LiveKitStatus.connectionError);
      unawaited(_goAway());
      return;
    }

    _reconnectTimer?.cancel();
    final delay = _reconnectBaseDelay * pow(2, _reconnectAttempts);
    _reconnectTimer = Timer(delay, () {
      if (!mounted || _session == null || _state == 'away') return;
      _attemptReconnect();
    });
  }

  Future<void> _attemptReconnect() async {
    final session = _session;
    if (session == null || !mounted) return;

    _reconnectAttempts++;
    setState(() {
      _state = 'reconnecting';
      _message = LiveKitStatus.reconnecting;
    });

    try {
      await _connectLiveKit(session);
      await _onlineRepository.markLive(session);
      if (!mounted) return;
      setState(() {
        _state = 'live';
        _message = LiveKitStatus.live;
      });
      _reconnectAttempts = 0;
    } catch (error) {
      if (!mounted) return;
      _scheduleReconnect();
    }
  }

  Future<void> _disconnectLiveKit() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;

    final room = _room;
    _room = null;
    _roomListener?.dispose();
    _roomListener = null;

    try {
      final localParticipant = room?.localParticipant;
      if (localParticipant != null) {
        await localParticipant.setMicrophoneEnabled(false);
      }
    } catch (_) {
      // Ignore cleanup failures.
    }

    await room?.disconnect();
  }

  Future<void> _setMicrophoneEnabled(bool enabled) async {
    final participant = _room?.localParticipant;
    if (participant == null) {
      throw StateError('LiveKit is not connected yet.');
    }

    await participant
        .setMicrophoneEnabled(enabled)
        .timeout(const Duration(seconds: 8));
  }

  void _setMessage(String message) {
    if (!mounted) return;
    setState(() => _message = message);
  }

  void _setStateAndMessage(String state, String message) {
    if (!mounted) return;
    setState(() {
      _state = state;
      _message = message;
    });
  }

  void _recordVoiceActivity() {
    if (_session == null) return;
    _lastVoiceActivityAt = DateTime.now();
    _scheduleInactivityCheck();
  }

  void _scheduleInactivityCheck() {
    _inactivityTimer?.cancel();
    if (_session == null) return;
    _inactivityTimer = Timer(PresenceConfig.inactivityTimeout, () {
      if (!mounted || _session == null) return;
      final lastActivity = _lastVoiceActivityAt;
      if (lastActivity != null &&
          DateTime.now().difference(lastActivity) <
              PresenceConfig.inactivityTimeout) {
        _scheduleInactivityCheck();
        return;
      }
      setState(() => _message = 'Room closed due to inactivity.');
      unawaited(_goAway());
    });
  }

  Future<int> _loadDailyUsage() async {
    final session = _session;
    if (session == null) return 0;
    try {
      final snapshot = await AppDatabase.instance()
          .ref('dailyUsage/${session.groupId}/${session.userId}/$_todayDateKey')
          .get();
      if (snapshot.exists && snapshot.value is Map<Object?, Object?>) {
        final data = snapshot.value! as Map<Object?, Object?>;
        return (data['onlineSeconds'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {}
    return 0;
  }

  Future<void> _persistDailyUsage() async {
    final session = _session;
    if (session == null) return;
    try {
      await AppDatabase.instance()
          .ref('dailyUsage/${session.groupId}/${session.userId}/$_todayDateKey')
          .update({
            'onlineSeconds': _todayOnlineSeconds,
            'updatedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          });
    } catch (_) {}
  }

  void _startUsageTracking() {
    final session = _session;
    if (session == null) return;
    _usagePersistTimer?.cancel();
    unawaited(_persistDailyUsage());
    _usagePersistTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_session == null) {
        _usagePersistTimer?.cancel();
        _usagePersistTimer = null;
        return;
      }
      _todayOnlineSeconds += 30;
      unawaited(_persistDailyUsage());
      if (_todayOnlineSeconds >= PresenceConfig.dailyUsageCap.inSeconds) {
        if (mounted) {
          setState(() => _message = 'Daily usage limit reached.');
        }
        unawaited(_goAway());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.group.name),
        backgroundColor: colors.inversePrimary,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _state.toUpperCase(),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Text('Group: ${widget.group.groupId}'),
              const SizedBox(height: 24),
              _TalkButton(
                enabled: _session != null && !_busy,
                active: _talkSession != null,
                busy: _talkBusy,
                onStart: _startTalking,
                onStop: () => _stopTalking(),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _busy || _session != null ? null : _goOnline,
                icon: const Icon(Icons.radio_button_checked),
                label: const Text('Go online'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy || _session == null ? null : _goAway,
                icon: const Icon(Icons.radio_button_unchecked),
                label: const Text('Go away'),
              ),
              if (_message != null) ...[
                const SizedBox(height: 24),
                Text(_message!),
              ],
              const Spacer(),
              Text(
                'Hold-to-talk is available after you are live.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
