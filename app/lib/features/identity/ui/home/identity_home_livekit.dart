part of '../identity_home_screen.dart';

// 1. Connect, publish mic (muted), attach room listener.
// 2. Audio route / mute / speaker.
// 3. Disconnect, connection loss, process teardown.

mixin _IdentityHomeLiveKit on _IdentityHomeBase {
  @override
  Future<void> _connectLiveKit(
    OnlineSession session, {
    Room? preparedRoom,
  }) async {
    // 1. Refuse connect without an explicit join.
    if (!_explicitJoinIntent) {
      LogManager.log(
        LogLevel.warn,
        'LiveKitManager',
        'Blocked room.connect without explicit join intent '
            'room=${session.livekitRoomName}',
        userId: session.userId,
        groupId: session.groupId,
      );
      throw StateError('LiveKit connect refused without explicit join intent.');
    }
    // [DEBUG] Go-live latency tracing added Aug 12. Remove before production
    // release. Reset once per connect attempt so the post-connect subscribe
    // and first-audio steps below are only logged for THIS go-live.
    _goLiveConnectResolvedAtMs = null;
    _goLiveFirstSubscribeLogged = false;
    _goLiveFirstAudioLogged = false;
    final step3StartedAt = _goLiveStepStart(
      3,
      'LiveKit room initialization started',
    );

    await _disconnectLiveKit();
    // E1: every live session starts in speaker mode (loud/hands-free).
    const speakerOn = true;

    // Reuse a pre-warmed Room (noise filter + audio route already built)
    // when available; otherwise build one now. Neither path connects here —
    // connect() happens below.
    final Room room;
    if (preparedRoom != null) {
      room = preparedRoom;
    } else {
      // B9: Attach Krisp noise filter via capture options so it applies when
      // the local mic track is created (walkie-talkie and call mode).
      final noiseFilter = LiveKitNoiseFilter();
      room = Room(
        roomOptions: RoomOptions(
          adaptiveStream: false,
          dynacast: false,
          defaultAudioOutputOptions: AudioOutputOptions(speakerOn: speakerOn),
          defaultAudioCaptureOptions: AudioCaptureOptions(
            processor: noiseFilter,
          ),
        ),
      );
    }

    _room = room;
    // 2. Listen, solo-guard, connect, start muted.
    _attachRoomListener(room);
    _listenToHardwareAudioDevices();
    _soloGuard = SoloParticipantGuard(
      userId: session.userId,
      groupId: session.groupId,
      onSoloTimeout: _handleSoloTimeout,
    )..attach(room);

    setState(() {
      _state = 'connecting';
      _message = LiveKitStatus.connecting;
    });
    _goLiveStepEnd(3, 'LiveKit room initialization started', step3StartedAt);

    final step4StartedAt = _goLiveStepStart(4, 'LiveKit room.connect() called');
    LogManager.log(
      LogLevel.info,
      'LiveKitManager',
      'Room connect attempt url=${session.livekitServerUrl} '
          'room=${session.livekitRoomName}',
      userId: session.userId,
      groupId: session.groupId,
    );
    try {
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
    _goLiveConnectResolvedAtMs = DateTime.now().millisecondsSinceEpoch;
    _goLiveStepEnd(
      4,
      'LiveKit room.connect() resolved (connected)',
      step4StartedAt,
    );
    // [DEBUG] Go-live latency tracing added Aug 12. Remove before production
    // release. Steps 6/7 are timed from this same moment (connect resolved)
    // since that's the natural "waiting for the sender" starting point; their
    // END markers are logged from the room event listener below once the
    // corresponding event actually fires for the first time.
    _goLiveStepStart(
      6,
      'Remote participant (sender) detected / subscribed — waiting for autoSubscribe',
    );
    _goLiveStepStart(
      7,
      'Audio track from sender is playing — waiting for first remote speaker',
    );

    try {
      await room.setSpeakerOn(true);
    } catch (_) {
      // Non-fatal. LiveKit can still use the platform default route.
    }
    // E1/E3: explicit connect defaults — speaker, unmuted. Do not inherit
    // native volume=0 as "muted" (STREAM_MUSIC is often 0 in voice mode).
    _callAudio.onSessionConnected();
    unawaited(AudioOutputBridge.setMuted(false, showUi: false));
    unawaited(AudioOutputBridge.applyRemotePlaybackMute(room, false));
    unawaited(_refreshAudioOutputState());
    unawaited(_syncProximityMonitoring());

    final localParticipant = room.localParticipant;
    if (localParticipant == null) {
      throw StateError('LiveKit connected without a local participant.');
    }

    debugPrint(
      '[LiveKit] Connected — '
      'identity=${localParticipant.identity} '
      'canPublish=${localParticipant.permissions.canPublish} '
      'canSubscribe=${localParticipant.permissions.canSubscribe}',
    );

    if (!localParticipant.permissions.canPublish) {
      debugPrint(
        '[LiveKit] WARNING: Local participant cannot publish after connect. '
        'This user will only receive audio. Check token grants.',
      );
    }

    debugPrint('[LiveKit] Noise filter applied to local audio track.');

    // [DEBUG] Go-live latency tracing added Aug 12. Remove before production
    // release.
    final step5StartedAt = _goLiveStepStart(
      5,
      'Local tracks (mic) published — initializing local mic track',
    );
    await localParticipant
        .setMicrophoneEnabled(false)
        .timeout(const Duration(seconds: 8));
    _goLiveStepEnd(
      5,
      'Local tracks (mic) published — local mic track initialized (walkie mode starts muted)',
      step5StartedAt,
    );
  }

  /// Applies the explicit user mode to LiveKit (speaker vs earpiece).
  /// Headphones, when connected, continue to take priority at the OS level.
  Future<void> _applyUserAudioRoute() async {
    final room = _room;
    if (room == null) return;
    if (_callAudio.muted) return;
    try {
      await room.setSpeakerOn(_callAudio.speakerOn);
    } catch (_) {
      // Route changes are best effort on devices without a separate earpiece.
    }
    await _refreshAudioOutputState();
    await _syncProximityMonitoring();
  }

  Future<void> _syncProximityMonitoring() async {
    await AudioOutputBridge.setProximityMonitoring(_callAudio.proximityEnabled);
  }

  Future<void> _toggleAudioOutput() async {
    if (_audioOutputBusy) return;
    _audioOutputBusy = true;
    if (_liveHapticsEnabled) {
      unawaited(HapticFeedback.selectionClick());
    }

    final previousMode = _callAudio.userMode;
    final wasMuted = previousMode == CallAudioUserMode.muted;
    _callAudio.onTap();
    setState(() {});

    try {
      if (wasMuted) {
        // Tap after mute → speaker (E1).
        await AudioOutputBridge.applyRemotePlaybackMute(_room, false);
        await AudioOutputBridge.setMuted(false);
        await _room?.setSpeakerOn(true);
        if (!mounted) return;
        unawaited(_reportMediaVolume());
        _showPresenceSnackbar('Volume unmuted');
      } else {
        await _room?.setSpeakerOn(_callAudio.speakerOn);
      }
    } catch (error, stack) {
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'audio_output_toggle_failed',
        ),
      );
      if (!mounted) return;
      _callAudio.restoreMode(previousMode);
      setState(() {});
      await _applyUserAudioRoute();
    } finally {
      _audioOutputBusy = false;
      unawaited(_refreshAudioOutputState());
      unawaited(_syncProximityMonitoring());
    }
  }

  Future<void> _toggleAudioMute() async {
    await _toggleMicrophone();
  }

  /// Toggles the actual LiveKit microphone by latching or releasing call
  /// mode. Each participant controls only their own mic; peers keep speaking.
  @override
  Future<void> _toggleMicrophone() async {
    await _toggleConnectionMode();
  }

  void _handleAudioOutputState(AudioOutputState next) {
    if (!mounted) return;
    // Device route (especially headset/bluetooth) is observational only —
    // never let native volume-muted flip the explicit user mute state (E3).
    final previousHeadphones = _callAudio.headphonesConnected;
    _callAudio.onDeviceRouteChanged(next.route);
    setState(() {});
    if (previousHeadphones != _callAudio.headphonesConnected) {
      // Reassert speaker/earpiece after unplug; headphones win while plugged.
      if (!_callAudio.headphonesConnected && !_callAudio.muted) {
        unawaited(_applyUserAudioRoute());
      } else {
        unawaited(_syncProximityMonitoring());
      }
    }
  }

  Future<void> _refreshAudioOutputState() async {
    final native = await AudioOutputBridge.getState();
    if (!mounted) return;
    if (native != null) {
      _handleAudioOutputState(native);
      return;
    }
    setState(() {});
  }

  void _listenToHardwareAudioDevices() {
    _hardwareAudioDeviceSubscription?.cancel();
    _hardwareAudioDeviceSubscription = Hardware.instance.onDeviceChange.stream
        .listen((_) {
          unawaited(_refreshAudioOutputState());
        });
  }

  bool get _liveHapticsEnabled {
    return widget.identityRepository.currentSession?.settings.hapticsEnabled ??
        _session.settings.hapticsEnabled;
  }

  String? _participantUserIdFromIdentity(String identity) {
    final parts = identity.split(':');
    if (parts.length < 3) return null;
    return parts[1];
  }

  ConnectionQuality _mergeConnectionQuality(
    ConnectionQuality? existing,
    ConnectionQuality incoming,
  ) {
    if (existing == null) return incoming;

    const order = [
      ConnectionQuality.lost,
      ConnectionQuality.poor,
      ConnectionQuality.unknown,
      ConnectionQuality.good,
      ConnectionQuality.excellent,
    ];

    final existingIndex = order.indexOf(existing);
    final incomingIndex = order.indexOf(incoming);
    return existingIndex <= incomingIndex ? existing : incoming;
  }

  void _syncConnectionQualities(Room room) {
    if (!mounted) return;

    final remotes = <String, ConnectionQuality>{};
    for (final participant in room.remoteParticipants.values) {
      final userId = _participantUserIdFromIdentity(participant.identity);
      if (userId == null) continue;
      remotes[userId] = _mergeConnectionQuality(
        remotes[userId],
        participant.connectionQuality,
      );
    }

    setState(() {
      _localConnectionQuality =
          room.localParticipant?.connectionQuality ?? ConnectionQuality.unknown;
      _remoteConnectionQualityByUserId = remotes;
    });
  }

  void _updateParticipantConnectionQuality(
    Participant participant,
    ConnectionQuality quality,
  ) {
    if (!mounted) return;

    if (participant is LocalParticipant) {
      setState(() => _localConnectionQuality = quality);
      return;
    }

    final userId = _participantUserIdFromIdentity(participant.identity);
    if (userId == null) return;

    setState(() {
      _remoteConnectionQualityByUserId = {
        ..._remoteConnectionQualityByUserId,
        userId: _mergeConnectionQuality(
          _remoteConnectionQualityByUserId[userId],
          quality,
        ),
      };
    });
  }

  void _clearConnectionQualities() {
    _localConnectionQuality = ConnectionQuality.unknown;
    _remoteConnectionQualityByUserId = {};
    if (mounted) setState(() {});
  }

  void _attachRoomListener(Room room) {
    _roomListener =
        attachLiveKitLifecycleLogs(
            room.createListener(),
            userId: _session.userId,
            groupId: _selectedGroup?.groupId ?? _onlineSession?.groupId,
          )
          ..on<RoomConnectedEvent>((_) {
            _syncConnectionQualities(room);
            _setMessage(LiveKitStatus.connected);
            _logLocalParticipantPermissions(room);
          })
          ..on<RoomReconnectingEvent>((_) {
            _setStateAndMessage('reconnecting', LiveKitStatus.reconnecting);
          })
          ..on<RoomReconnectedEvent>((_) {
            _syncConnectionQualities(room);
            _logLocalParticipantPermissions(room);
            // Reconnection can drop the local audio track — restore it based on
            // the current talk/call state so the participant never silently
            // becomes subscriber-only.
            unawaited(_restoreMicrophoneAfterReconnect());
            _setStateAndMessage('live', LiveKitStatus.connected);
          })
          ..on<RoomDisconnectedEvent>((event) {
            unawaited(
              _handleConnectionLoss(
                LiveKitStatus.fromDisconnectReason(event.reason),
              ),
            );
          })
          ..on<ParticipantConnectedEvent>((event) {
            _updateParticipantConnectionQuality(
              event.participant,
              event.participant.connectionQuality,
            );
            final userId = _participantUserIdFromIdentity(
              event.participant.identity,
            );
            if (userId != null && userId != _session.userId) {
              _peerReconnect.peerJoined(userId);
            }
          })
          ..on<ParticipantDisconnectedEvent>((event) {
            final userId = _participantUserIdFromIdentity(
              event.participant.identity,
            );
            if (userId != null && userId != _session.userId) {
              _peerReconnect.peerLeft(userId);
            }
          })
          ..on<ParticipantConnectionQualityUpdatedEvent>((event) {
            _updateParticipantConnectionQuality(
              event.participant,
              event.connectionQuality,
            );
          })
          ..on<TrackSubscribedEvent>((event) {
            // Subscription is an implementation detail — keep UI status clean.
            // [DEBUG] Go-live latency tracing added Aug 12. Remove before
            // production release. Only log the FIRST subscribed remote audio
            // track per go-live, measured from when room.connect() resolved.
            if (!_goLiveFirstSubscribeLogged &&
                event.publication.kind == TrackType.AUDIO) {
              _goLiveFirstSubscribeLogged = true;
              final startedAt = _goLiveConnectResolvedAtMs;
              if (startedAt != null) {
                _goLiveStepEnd(
                  6,
                  'Remote participant (sender) detected / subscribed — '
                  'identity=${event.participant.identity}',
                  startedAt,
                );
              }
            }
            if (_audioMuted && event.publication.kind == TrackType.AUDIO) {
              unawaited(AudioOutputBridge.applyRemotePlaybackMute(_room, true));
            }
          })
          ..on<ActiveSpeakersChangedEvent>((event) {
            final speaking = <String>{};
            for (final speaker in event.speakers) {
              final userId =
                  LiveKitStatus.userIdFromIdentity(speaker.identity) ??
                  _participantUserIdFromIdentity(speaker.identity);
              if (userId != null) speaking.add(userId);
            }
            if (!mounted) return;
            final hasRemoteSpeaker = speaking.any(
              (id) => id != _session.userId,
            );
            // [DEBUG] Go-live latency tracing added Aug 12. Remove before
            // production release. Only log the FIRST remote-speaking moment per
            // go-live, measured from when room.connect() resolved.
            if (!_goLiveFirstAudioLogged && hasRemoteSpeaker) {
              _goLiveFirstAudioLogged = true;
              final startedAt = _goLiveConnectResolvedAtMs;
              if (startedAt != null) {
                _goLiveStepEnd(
                  7,
                  'Audio track from sender is playing — first remote speaker detected',
                  startedAt,
                );
              }
            }
            if (hasRemoteSpeaker || speaking.contains(_session.userId)) {
              _recordVoiceActivity();
            }
            // E1: never reassert speaker/earpiece from active-speaker events —
            // routing changes only on explicit user action (or headphones).
            setState(() {
              _speakingUserIds = speaking;
              final remoteSpeaking = speaking.any(
                (id) => id != _session.userId,
              );
              if (remoteSpeaking && !_isTransmitting) {
                _message = LiveKitStatus.receivingVoice;
              } else if (_message == LiveKitStatus.receivingVoice) {
                _message = LiveKitStatus.live;
              }
            });
            // Reflect the new active speaker in the in-app PiP overlay.
            _updatePipOverlay();
          });
  }

  /// Logs the local participant's publishing/subscribing permissions and
  /// track state so subscriber-only regressions are detectable in logs.
  void _logLocalParticipantPermissions(Room room) {
    final participant = room.localParticipant;
    if (participant == null) {
      debugPrint(
        '[LiveKit] No local participant available for permission check.',
      );
      return;
    }
    debugPrint(
      '[LiveKit] Local participant permissions — '
      'identity=${participant.identity} '
      'canPublish=${participant.permissions.canPublish} '
      'canSubscribe=${participant.permissions.canSubscribe} '
      'canPublishData=${participant.permissions.canPublishData} '
      'isCameraEnabled=${participant.isCameraEnabled} '
      'isMicrophoneEnabled=${participant.isMicrophoneEnabled} '
      'isScreenShareEnabled=${participant.isScreenShareEnabled} '
      'audioTrackPublished=${participant.audioTrackPublications.isNotEmpty} '
      'connectionQuality=${participant.connectionQuality.name}',
    );
    if (!participant.permissions.canPublish) {
      debugPrint(
        '[LiveKit] WARNING: Local participant lacks publish permission — '
        'will be subscriber-only. Check token grants.',
      );
    }
  }

  /// Restores the microphone/track state after a LiveKit SDK reconnection.
  /// Without this, a transient network blip can leave the participant
  /// silently downgraded to subscriber-only.
  Future<void> _restoreMicrophoneAfterReconnect() async {
    final participant = _room?.localParticipant;
    if (participant == null) return;

    // The participant must still have publish capability from the original
    // token; if not, log a warning — they cannot send audio.
    if (!participant.permissions.canPublish) {
      debugPrint(
        '[LiveKit] WARNING: After reconnection, local participant '
        '(${participant.identity}) cannot publish. Token may need to be '
        're-issued. Participant will remain subscriber-only.',
      );
      return;
    }

    // Restore the microphone to match the current session state.
    // Call mode (latched mic) stays on unless the user muted; walkie-talkie
    // stays off until they tap the main button again.
    final shouldBeEnabled =
        (_isCallMode && !_microphoneMutedByUser) || _talkSession != null;
    try {
      await participant
          .setMicrophoneEnabled(shouldBeEnabled)
          .timeout(const Duration(seconds: 8));
      if (mounted) {
        setState(() {});
        _updatePipOverlay();
      }
      debugPrint(
        '[LiveKit] Post-reconnect microphone restored: '
        'enabled=$shouldBeEnabled '
        'mode=${_isCallMode ? "call" : "walkie"} '
        'talking=$_isTransmitting',
      );
    } catch (error) {
      debugPrint(
        '[LiveKit] WARNING: Failed to restore microphone after reconnection: '
        '$error',
      );
    }
  }

  @override
  Future<void> _handleConnectionLoss(String message) async {
    final session = _onlineSession;
    if (session == null || _connectionCleanupInFlight) return;
    _connectionCleanupInFlight = true;

    debugPrint(
      '[LiveKit] Connection loss — reason="$message" '
      'groupId=${session.groupId}',
    );

    final talkSession = _talkSession;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _peerDisconnectGraceTimer?.cancel();
    _peerDisconnectGraceTimer = null;
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
    _callModeTimeoutTimer?.cancel();
    _callModeTimeoutTimer = null;
    _usagePersistTimer?.cancel();
    _usagePersistTimer = null;
    _enteredViaNudge = false;
    _explicitJoinIntent = false;
    _deferredNudgeAction = null;
    _liveSessionActiveOnBackground = false;
    if (mounted) {
      setState(() {
        _onlineSession = null;
        _talkSession = null;
        _speakingUserIds = const {};
        _state = 'away';
        _connectionMode = MemberAvailability.walkieTalkieMode;
        _microphoneMutedByUser = false;
        _message = message;
      });
      _syncPipSessionState();
    }

    try {
      if (talkSession != null) {
        await _talkRepository.stopTalk(talkSession, reason: 'connection_lost');
      }
    } catch (_) {
      // Presence cleanup still has to continue.
    }
    await _disconnectLiveKit();
    try {
      await _onlineRepository
          .goAway(session, reason: 'network_loss')
          .timeout(const Duration(seconds: 3));
      unawaited(ActiveOnlineSessionStore.clear());
      unawaited(
        _onlineRepository.notifyGoneOffline(
          session: session,
          reason: 'network_loss',
        ),
      );
    } catch (_) {
      // Firebase onDisconnect was registered before going live and is the
      // server-side fallback when the device cannot write during an outage.
    } finally {
      _connectionCleanupInFlight = false;
    }
    if (mounted) _showPresenceSnackbar(message);
  }

  /// Fired by [SoloParticipantGuard] after the local user has remained the
  /// sole connected participant for [PresenceConfig.soloParticipantTimeout].
  /// Reports the invalid state as a non-fatal bug (with on-device logs) and
  /// takes the user offline so they never sit alone online indefinitely.
  /// SnackBars are only shown while the app is foregrounded with a Scaffold.
  Future<void> _handleSoloTimeout(SoloSessionContext context) async {
    final session = _onlineSession;
    if (session == null || !mounted) return;

    unawaited(
      CrashlyticsService.recordSoloParticipant(
        userId: _session.userId,
        groupId: session.groupId,
        roomName: context.roomName,
        livekitConnectionState: context.connectionState,
        remoteParticipantCount: context.remoteParticipantCount,
        remoteCountAtConnect: context.remoteCountAtConnect,
        remoteCountAtSoloStart: context.remoteCountAtSoloStart,
        soloDurationSeconds: context.soloDuration.inSeconds,
        entryReason: _enteredViaNudge ? 'nudge_accept' : 'manual_join',
        connectionMode: _connectionMode,
      ),
    );

    await _goAway(reason: 'solo_timeout');
    _showPresenceSnackbar(
      'You were the only one left online, so the room closed automatically.',
    );
  }

  @override
  Future<void> _disconnectLiveKit({bool urgent = false}) async {
    final room = _room;
    _room = null;
    _roomListener?.dispose();
    _roomListener = null;
    _hardwareAudioDeviceSubscription?.cancel();
    _hardwareAudioDeviceSubscription = null;
    _soloGuard?.detach();
    _soloGuard = null;
    _speakingUserIds = const {};
    _clearConnectionQualities();
    _callAudio.onSessionEnded();
    unawaited(AudioOutputBridge.setProximityMonitoring(false));

    if (room != null) {
      debugPrint(
        '[LiveKit] Disconnecting room — '
        'localParticipant=${room.localParticipant?.identity ?? "none"} '
        'remoteParticipants=${room.remoteParticipants.length} '
        'urgent=$urgent',
      );
    }

    if (!urgent) {
      try {
        final localParticipant = room?.localParticipant;
        if (localParticipant != null) {
          await localParticipant.setMicrophoneEnabled(false);
        }
      } catch (_) {
        // Ignore cleanup failures.
      }
    }

    try {
      await room?.disconnect().timeout(
        Duration(milliseconds: urgent ? 800 : 8000),
      );
    } catch (_) {
      // Process teardown cannot wait on a hung websocket.
    }
  }

  Future<void> _teardownLiveSessionForProcessDeath() async {
    if (_processTeardownInFlight) return;
    final session = _onlineSession;
    final room = _room;
    if (session == null && room == null) return;
    _processTeardownInFlight = true;
    _connectionCleanupInFlight = true;
    _explicitJoinIntent = false;
    _liveSessionActiveOnBackground = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _peerDisconnectGraceTimer?.cancel();
    _peerDisconnectGraceTimer = null;
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
    _callModeTimeoutTimer?.cancel();
    _callModeTimeoutTimer = null;
    _usagePersistTimer?.cancel();
    _usagePersistTimer = null;
    _onlineSession = null;
    _talkSession = null;
    if (session != null) {
      LogManager.log(
        LogLevel.warn,
        'PresenceRing',
        'processTeardown goAway sessionSuffix=${session.serviceSessionId.substring(session.serviceSessionId.length - 6)}',
        userId: _session.userId,
        groupId: session.groupId,
      );
    }
    LogManager.log(
      LogLevel.warn,
      'LiveKitManager',
      'Process teardown — disconnecting room and clearing presence',
      userId: _session.userId,
      groupId: session?.groupId ?? _selectedGroup?.groupId,
    );
    try {
      await _disconnectLiveKit(urgent: true);
    } catch (_) {}
    if (session != null) {
      try {
        await _onlineRepository
            .goAway(session, reason: 'process_killed')
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
      unawaited(ActiveOnlineSessionStore.clear());
    }
    _syncPipSessionState();
    if (mounted) {
      setState(() {
        _state = 'away';
        _message = LiveKitStatus.away;
        _speakingUserIds = const {};
      });
    }
  }

  Future<void> _clearAbandonedOnlineSession() async {
    final leftover = await ActiveOnlineSessionStore.read();
    if (leftover == null || _onlineSession != null) return;
    try {
      await _onlineRepository.clearAbandonedSession(leftover);
      LogManager.log(
        LogLevel.warn,
        'LiveKitManager',
        'Cleared abandoned presence from a previous process',
        userId: leftover.userId,
        groupId: leftover.groupId,
      );
    } catch (error) {
      LogManager.log(
        LogLevel.error,
        'LiveKitManager',
        'Failed to clear abandoned presence: $error',
        userId: leftover.userId,
        groupId: leftover.groupId,
      );
    }
    if (_onlineSession != null) return;
    final stored = await ActiveOnlineSessionStore.read();
    if (stored?.serviceSessionId == leftover.serviceSessionId) {
      await ActiveOnlineSessionStore.clear();
    }
  }

  @override
  Future<void> _setMicrophoneEnabled(bool enabled) async {
    final participant = _room?.localParticipant;
    if (participant == null) {
      throw StateError('LiveKit is not connected yet.');
    }

    if (!participant.permissions.canPublish) {
      debugPrint(
        '[LiveKit] WARNING: Attempted setMicrophoneEnabled($enabled) but '
        'local participant cannot publish. Participant is subscriber-only.',
      );
      throw StateError(
        'Cannot publish audio — local participant lacks publish permission.',
      );
    }

    await participant
        .setMicrophoneEnabled(enabled)
        .timeout(const Duration(seconds: 8));

    debugPrint('[LiveKit] Microphone set: enabled=$enabled');
  }
}
