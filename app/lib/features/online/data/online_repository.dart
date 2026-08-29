import 'package:one_one_app/one_one.dart';

class OnlineRepository {
  OnlineRepository({ApiClient? apiClient, FirebaseDatabase? database})
    : _apiClient = apiClient ?? ApiClient(),
      _database = database ?? AppDatabase.instance();

  final ApiClient _apiClient;
  final FirebaseDatabase _database;

  Future<OnlineSession> goOnline({
    required IdentitySession identity,
    required GroupSummary group,
    String connectionMode = MemberAvailability.walkieTalkieMode,
    PreparedLiveKitToken? preparedToken,
  }) async {
    // 1. Mic permission
    await _requestOnlinePermissions();

    final now = _nowSeconds();
    final String serviceSessionId;
    final String livekitSessionId;
    final LiveKitTokenResponse token;

    // 2. Reuse a prepared token or mint a new one
    if (preparedToken != null && preparedToken.isUsableAt(now)) {
      serviceSessionId = preparedToken.serviceSessionId;
      livekitSessionId = preparedToken.livekitSessionId;
      token = preparedToken.response;
    } else {
      serviceSessionId = const Uuid().v4();
      livekitSessionId = const Uuid().v4();
      token = await _requestLiveKitToken(
        groupId: group.groupId,
        deviceId: identity.deviceId,
        serviceSessionId: serviceSessionId,
        livekitSessionId: livekitSessionId,
      );
    }

    final session = OnlineSession(
      groupId: group.groupId,
      userId: identity.userId,
      deviceId: identity.deviceId,
      serviceSessionId: serviceSessionId,
      livekitSessionId: livekitSessionId,
      livekitServerUrl: token.serverUrl,
      livekitToken: token.token,
      livekitRoomName: token.roomName,
      participantIdentity: token.participantIdentity,
      startedAt: now,
    );

    await _cancelStaleOnDisconnect(
      groupId: group.groupId,
      userId: identity.userId,
    );
    _logPresenceWrite(
      'goOnline connecting',
      groupId: group.groupId,
      userId: identity.userId,
      serviceSessionId: serviceSessionId,
    );

    // 3. Write connecting presence
    await _database.ref().update({
      'appServiceSessions/$serviceSessionId': {
        'groupId': group.groupId,
        'userId': identity.userId,
        'deviceId': identity.deviceId,
        'serviceState': 'starting',
        'startReason': 'user_online',
        'stopReason': null,
        'startedAt': now,
        'stoppedAt': null,
        'lastHeartbeatAt': now,
      },
      'livekitSessions/$livekitSessionId': {
        'serviceSessionId': serviceSessionId,
        'livekitRoomId': group.groupId,
        'groupId': group.groupId,
        'userId': identity.userId,
        'deviceId': identity.deviceId,
        'participantIdentity': token.participantIdentity,
        'participantName': token.participantName,
        'connectionState': 'connecting',
        'connectedAt': null,
        'disconnectedAt': null,
        'lastStateChangedAt': now,
      },
      'memberAvailability/${group.groupId}/${identity.userId}': {
        'activeDeviceId': identity.deviceId,
        'activeServiceSessionId': serviceSessionId,
        'activeLivekitSessionId': livekitSessionId,
        'desiredState': 'online',
        'effectiveState': 'connecting',
        'serviceState': 'starting',
        'livekitConnectionState': 'connecting',
        'canReceiveLiveAudio': false,
        'connectionMode': connectionMode,
        'lastHeartbeatAt': now,
        'staleAfterAt': now + 30,
        'updatedAt': now,
      },
    });
    // 4. Away if the socket drops
    await _scheduleAwayOnDisconnect(session);

    return session;
  }

  Future<void> markLive(OnlineSession session) async {
    final now = _nowSeconds();
    _logPresenceWrite(
      'markLive',
      groupId: session.groupId,
      userId: session.userId,
      serviceSessionId: session.serviceSessionId,
    );
    await _database.ref().update({
      'appServiceSessions/${session.serviceSessionId}/serviceState': 'running',
      'appServiceSessions/${session.serviceSessionId}/lastHeartbeatAt': now,
      'livekitSessions/${session.livekitSessionId}/connectionState':
          'connected',
      'livekitSessions/${session.livekitSessionId}/connectedAt': now,
      'livekitSessions/${session.livekitSessionId}/lastStateChangedAt': now,
      'memberAvailability/${session.groupId}/${session.userId}/effectiveState':
          'live',
      'memberAvailability/${session.groupId}/${session.userId}/serviceState':
          'running',
      'memberAvailability/${session.groupId}/${session.userId}/livekitConnectionState':
          'connected',
      'memberAvailability/${session.groupId}/${session.userId}/canReceiveLiveAudio':
          true,
      'memberAvailability/${session.groupId}/${session.userId}/lastHeartbeatAt':
          now,
      'memberAvailability/${session.groupId}/${session.userId}/staleAfterAt':
          now + 30,
      'memberAvailability/${session.groupId}/${session.userId}/updatedAt': now,
    });
  }

  Future<void> heartbeat(
    OnlineSession session, {
    bool isTalking = false,
  }) async {
    final now = _nowSeconds();
    await _database.ref().update({
      'appServiceSessions/${session.serviceSessionId}/lastHeartbeatAt': now,
      'memberAvailability/${session.groupId}/${session.userId}/desiredState':
          'online',
      'memberAvailability/${session.groupId}/${session.userId}/effectiveState':
          isTalking ? 'talking' : 'live',
      'memberAvailability/${session.groupId}/${session.userId}/serviceState':
          'running',
      'memberAvailability/${session.groupId}/${session.userId}/livekitConnectionState':
          'connected',
      'memberAvailability/${session.groupId}/${session.userId}/canReceiveLiveAudio':
          true,
      'memberAvailability/${session.groupId}/${session.userId}/lastHeartbeatAt':
          now,
      'memberAvailability/${session.groupId}/${session.userId}/staleAfterAt':
          now + 30,
      'memberAvailability/${session.groupId}/${session.userId}/updatedAt': now,
    });
  }

  Future<void> setConnectionMode(
    OnlineSession session, {
    required String connectionMode,
  }) async {
    await _database.ref().update({
      'memberAvailability/${session.groupId}/${session.userId}/connectionMode':
          connectionMode,
      'memberAvailability/${session.groupId}/${session.userId}/updatedAt':
          _nowSeconds(),
    });
  }

  Future<void> goAway(
    OnlineSession session, {
    String reason = 'user_away',
  }) async {
    final now = _nowSeconds();
    _logPresenceWrite(
      'goAway reason=$reason',
      groupId: session.groupId,
      userId: session.userId,
      serviceSessionId: session.serviceSessionId,
    );
    final availabilityRef = _database.ref(
      'memberAvailability/${session.groupId}/${session.userId}',
    );
    final serviceRef = _database.ref(
      'appServiceSessions/${session.serviceSessionId}',
    );
    final liveKitRef = _database.ref(
      'livekitSessions/${session.livekitSessionId}',
    );
    await Future.wait([
      availabilityRef.onDisconnect().cancel(),
      serviceRef.onDisconnect().cancel(),
      liveKitRef.onDisconnect().cancel(),
    ]);

    await _database.ref().update({
      'appServiceSessions/${session.serviceSessionId}/serviceState': 'stopped',
      'appServiceSessions/${session.serviceSessionId}/stopReason': reason,
      'appServiceSessions/${session.serviceSessionId}/stoppedAt': now,
      'appServiceSessions/${session.serviceSessionId}/lastHeartbeatAt': now,
      'livekitSessions/${session.livekitSessionId}/connectionState':
          'disconnected',
      'livekitSessions/${session.livekitSessionId}/disconnectedAt': now,
      'livekitSessions/${session.livekitSessionId}/lastStateChangedAt': now,
      'memberAvailability/${session.groupId}/${session.userId}': {
        'activeDeviceId': null,
        'activeServiceSessionId': null,
        'activeLivekitSessionId': null,
        'desiredState': 'away',
        'effectiveState': 'away',
        'serviceState': 'stopped',
        'livekitConnectionState': 'disconnected',
        'canReceiveLiveAudio': false,
        'connectionMode': MemberAvailability.walkieTalkieMode,
        'lastHeartbeatAt': now,
        'staleAfterAt': now,
        'updatedAt': now,
      },
    });
  }

  Future<void> clearAbandonedSession(OnlineSession session) async {
    final snapshot = await _database
        .ref('memberAvailability/${session.groupId}/${session.userId}')
        .get();
    final value = snapshot.value;
    if (value is! Map) return;
    final activeId = value['activeServiceSessionId']?.toString();
    if (activeId != session.serviceSessionId) {
      _logPresenceWrite(
        'clearAbandonedSession skipped — active session replaced',
        groupId: session.groupId,
        userId: session.userId,
        serviceSessionId: session.serviceSessionId,
        extra:
            'activeSuffix=${activeId == null || activeId.isEmpty ? "none" : (activeId.length <= 6 ? activeId : activeId.substring(activeId.length - 6))}',
      );
      return;
    }
    _logPresenceWrite(
      'clearAbandonedSession goAway process_killed',
      groupId: session.groupId,
      userId: session.userId,
      serviceSessionId: session.serviceSessionId,
    );
    await goAway(session, reason: 'process_killed');
  }

  Future<void> notifyGoneOffline({
    required OnlineSession session,
    required String reason,
  }) async {
    try {
      await _apiClient.postJson(
        '/v1/groups/${session.groupId}/notifications/gone-offline',
        {'deviceId': session.deviceId, 'reason': reason},
      );
    } catch (_) {
      // Best-effort — RTDB presence is already away; missing the push is
      // non-fatal (foreground snackbars still cover the same cases).
    }
  }

  Future<void> _cancelStaleOnDisconnect({
    required String groupId,
    required String userId,
  }) async {
    final availabilityRef = _database.ref(
      'memberAvailability/$groupId/$userId',
    );
    final cancels = <Future<void>>[availabilityRef.onDisconnect().cancel()];
    try {
      final snapshot = await availabilityRef.get();
      final value = snapshot.value;
      if (value is Map) {
        final serviceId = value['activeServiceSessionId']?.toString();
        final livekitId = value['activeLivekitSessionId']?.toString();
        if (serviceId != null && serviceId.isNotEmpty) {
          cancels.add(
            _database
                .ref('appServiceSessions/$serviceId')
                .onDisconnect()
                .cancel(),
          );
        }
        if (livekitId != null && livekitId.isNotEmpty) {
          cancels.add(
            _database.ref('livekitSessions/$livekitId').onDisconnect().cancel(),
          );
        }
      }
    } catch (_) {
      // Best-effort — availability cancel is the critical one.
    }
    await Future.wait(cancels);
  }

  void _logPresenceWrite(
    String action, {
    required String groupId,
    required String userId,
    required String serviceSessionId,
    String? extra,
  }) {
    final suffix = serviceSessionId.length <= 6
        ? serviceSessionId
        : serviceSessionId.substring(serviceSessionId.length - 6);
    LogManager.log(
      LogLevel.info,
      'PresenceRing',
      '$action userId=$userId groupId=$groupId sessionSuffix=$suffix'
          '${extra == null ? '' : ' $extra'}',
      userId: userId,
      groupId: groupId,
    );
  }

  Future<void> _scheduleAwayOnDisconnect(OnlineSession session) async {
    final now = _nowSeconds();
    final availabilityRef = _database.ref(
      'memberAvailability/${session.groupId}/${session.userId}',
    );
    final serviceRef = _database.ref(
      'appServiceSessions/${session.serviceSessionId}',
    );
    final liveKitRef = _database.ref(
      'livekitSessions/${session.livekitSessionId}',
    );
    await Future.wait([
      serviceRef.onDisconnect().update({
        'serviceState': 'stopped',
        'stopReason': 'network_loss',
        'stoppedAt': now,
        'lastHeartbeatAt': now,
      }),
      liveKitRef.onDisconnect().update({
        'connectionState': 'disconnected',
        'disconnectedAt': now,
        'lastStateChangedAt': now,
      }),
      availabilityRef.onDisconnect().set({
        'activeDeviceId': null,
        'activeServiceSessionId': null,
        'activeLivekitSessionId': null,
        'desiredState': MemberAvailability.away.desiredState,
        'effectiveState': MemberAvailability.away.effectiveState,
        'serviceState': 'stopped',
        'livekitConnectionState': 'disconnected',
        'canReceiveLiveAudio': false,
        'connectionMode': MemberAvailability.walkieTalkieMode,
        'lastHeartbeatAt': 0,
        'staleAfterAt': 0,
        'updatedAt': now,
      }),
    ]);
  }

  Future<LiveKitTokenResponse> _requestLiveKitToken({
    required String groupId,
    required String deviceId,
    required String serviceSessionId,
    required String livekitSessionId,
  }) async {
    final response = await _apiClient.postJson('/v1/livekit/token', {
      'groupId': groupId,
      'deviceId': deviceId,
      'serviceSessionId': serviceSessionId,
      'livekitSessionId': livekitSessionId,
    });
    return LiveKitTokenResponse.fromJson(response);
  }

  Future<PreparedLiveKitToken> prepareToken({
    required String groupId,
    required String deviceId,
  }) async {
    final serviceSessionId = const Uuid().v4();
    final livekitSessionId = const Uuid().v4();
    final token = await _requestLiveKitToken(
      groupId: groupId,
      deviceId: deviceId,
      serviceSessionId: serviceSessionId,
      livekitSessionId: livekitSessionId,
    );
    return PreparedLiveKitToken(
      response: token,
      serviceSessionId: serviceSessionId,
      livekitSessionId: livekitSessionId,
    );
  }

  Future<void> _requestOnlinePermissions() async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      throw StateError(
        'Microphone permission is required before going online.',
      );
    }
  }

  int _nowSeconds() {
    return DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }
}
