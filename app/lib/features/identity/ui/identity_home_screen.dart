import 'package:one_one_app/one_one.dart';

// [DEBUG] Go-live latency tracing helpers added Aug 12. Remove before
// production release. Logs a numbered start/end pair for each major step of
// the receiver's go-live flow (nudge accept -> LiveKit connected) so the
// ~3-4s/~6-7s latency can be attributed to a specific step from device logs.
int _goLiveStepStart(int step, String description) {
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  debugPrint('[GO-LIVE STEP $step START] $description — timestamp: $timestamp');
  return timestamp;
}

void _goLiveStepEnd(int step, String description, int startedAtMs) {
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final elapsed = timestamp - startedAtMs;
  debugPrint(
    '[GO-LIVE STEP $step END] $description — timestamp: $timestamp | elapsed: ${elapsed}ms',
  );
}

class IdentityHomeScreen extends StatefulWidget {
  const IdentityHomeScreen({
    super.key,
    required this.initialSession,
    required this.identityRepository,
    this.initialGroupId,
    this.initialBootstrap,
  });

  final IdentitySession initialSession;
  final IdentityRepository identityRepository;
  final String? initialGroupId;
  final IdentityHomeBootstrap? initialBootstrap;

  @override
  State<IdentityHomeScreen> createState() => _IdentityHomeScreenState();
}

class _IdentityHomeScreenState extends State<IdentityHomeScreen>
    with WidgetsBindingObserver, RouteAware {
  final GroupRepository _groupRepository = GroupRepository();
  final OnlineRepository _onlineRepository = OnlineRepository();
  final TalkRepository _talkRepository = TalkRepository();
  final AndroidVoiceNudgeBridge _nudgeActionBridge = AndroidVoiceNudgeBridge();
  final NudgeRepository _nudgeRepository = NudgeRepository();
  final ChatMessageRepository _chatMessageRepository = ChatMessageRepository();
  final InviteLinkBridge _inviteLinkBridge = InviteLinkBridge();
  final VoicePipBridge _voicePipBridge = VoicePipBridge();

  late IdentitySession _session;
  List<GroupSummary> _groups = const [];
  List<GroupMemberSummary> _members = const [];
  Map<String, List<GroupMemberSummary>> _membersByGroupId = {};
  Map<String, MemberAvailability> _availability = {};
  Set<String> _speakingUserIds = {};
  List<GroupChatMessage> _chatMessages = const [];
  StreamSubscription<DatabaseEvent>? _chatMessagesSubscription;
  StreamSubscription<Map<String, dynamic>>? _emojiBurstSubscription;

  /// App is assumed foreground at startup; lifecycle callbacks keep it current.
  AppLifecycleState _appLifecycle = AppLifecycleState.resumed;
  GroupSummary? _selectedGroup;
  StreamSubscription<DatabaseEvent>? _availabilitySubscription;
  Timer? _availabilityExpiryTimer;
  bool _hasAvailabilitySnapshot = false;
  StreamSubscription<DatabaseEvent>? _membersSubscription;
  StreamSubscription<DatabaseEvent>? _userGroupsSubscription;
  final List<StreamSubscription<DatabaseEvent>> _memberProfileSubscriptions =
      [];
  Set<String>? _pendingUserGroupIds;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  StreamSubscription<void>? _nudgeActionSubscription;
  StreamSubscription<String>? _nudgeReceivedSubscription;
  StreamSubscription<ActiveNudge>? _incomingNudgeSubscription;
  StreamSubscription<IncomingNudgeStatusUpdate>?
  _incomingNudgeStatusSubscription;
  StreamSubscription<NudgeRecipientResponse>? _nudgeResponseSubscription;
  StreamSubscription<void>? _registrationRenewalSubscription;
  StreamSubscription<void>? _inviteLinkSubscription;
  StreamSubscription<VoicePipAction>? _voicePipActionSubscription;

  OnlineSession? _onlineSession;
  TalkSession? _talkSession;
  Room? _room;
  EventsListener<RoomEvent>? _roomListener;
  SoloParticipantGuard? _soloGuard;
  Timer? _heartbeatTimer;
  List<EmojiBurst> _emojiBursts = const [];

  // True when the current online session was entered by accepting (or
  // connecting to) a nudge. Used to explain *why* a single-user-in-room bug
  // occurred when the solo-participant timeout later fires.
  bool _enteredViaNudge = false;

  // Set only when the user taps Join or accepts/connects a nudge. Room
  // connect is refused without this, so a later foreground cannot resurrect
  // a session the user already left.
  bool _explicitJoinIntent = false;

  // True when a LiveKit session was active at the last backgrounding.
  // Resume may keep that session; it must not start a new one.
  bool _liveSessionActiveOnBackground = false;

  final Set<String> _processedNudgeEventIds = {};

  // Automatic-offline-on-disconnect (with grace period) bookkeeping. See
  // _evaluatePeerPresenceForAutoOffline for the state machine.
  bool _peerWasLiveWithMe = false;
  Timer? _peerDisconnectGraceTimer;

  // Inactivity timeout: if nobody speaks for the configured duration while
  // the room is active, the session auto-closes to prevent runaway costs.
  DateTime? _lastVoiceActivityAt;
  Timer? _inactivityTimer;

  // Daily usage tracker: prevents runaway sessions (e.g. phone left on in a
  // crowd). Accumulates online seconds and caps at 180 min / user / day.
  int _todayOnlineSeconds = 0;
  String? _todayUsageDateKey;
  Timer? _usagePersistTimer; // Flushes accumulated seconds to RTDB every 30 s.

  int _carouselIndex = 0;

  // [DEBUG] Go-live latency tracing added Aug 12. Remove before production
  // release. Tracks the timestamp LiveKit last finished connecting, and
  // whether the first post-connect subscribe/audio events have already been
  // logged, so those steps are only logged once per go-live (not on every
  // later speaker change).
  int? _goLiveConnectResolvedAtMs;
  bool _goLiveFirstSubscribeLogged = false;
  bool _goLiveFirstAudioLogged = false;

  bool _loadingGroups = true;
  bool _busy = false;
  /// Sync lock so concurrent auto-connect paths (FCM accept + native pending
  /// action) cannot both run [goOnline] and flash live→connecting→live.
  bool _goOnlineInFlight = false;
  bool _audioOutputBusy = false;
  bool _audioMuteBusy = false;
  bool _microphoneMutedByUser = false;
  final CallAudioRouteController _callAudio = CallAudioRouteController();
  AudioOutputRoute get _audioRoute => _callAudio.displayRoute;
  bool get _audioMuted => _callAudio.muted;
  StreamSubscription<AudioOutputState>? _audioOutputSubscription;
  StreamSubscription<List<MediaDevice>>? _hardwareAudioDeviceSubscription;
  bool _talkBusy = false;
  bool _talkPressed = false;
  // Per-user connection style for the *local* user's own connection — never
  // a group-wide mode. Defaults to walkie-talkie; see _toggleConnectionMode
  // and the startInCallMode logic in _goOnline for how it changes.
  String _connectionMode = MemberAvailability.walkieTalkieMode;
  bool _connectionModeBusy = false;
  // Caps continuous call mode at PresenceConfig.callModeTimeout; cancelled
  // whenever the local user leaves call mode (manual toggle, go-away, etc.).
  Timer? _callModeTimeoutTimer;
  String _state = 'away';
  String? _message;
  ConnectionQuality _localConnectionQuality = ConnectionQuality.unknown;
  Map<String, ConnectionQuality> _remoteConnectionQualityByUserId = {};
  List<ConnectivityResult> _connectivity = const [];
  bool _registrationRefreshInFlight = false;
  DateTime? _lastRegistrationRefreshAt;
  NudgeNotificationAction? _deferredNudgeAction;
  bool _nudgeActionInFlight = false;
  final ActiveNudgeInbox _nudgeInbox = ActiveNudgeInbox.instance;
  final ActiveNudgeSync _nudgeSync = ActiveNudgeSync();
  ActiveNudge? _incomingPromptNudge;
  String? _promptRestoreGroupId;
  bool _incomingPromptBusy = false;
  bool _incomingHydrateInFlight = false;
  Timer? _incomingExpiryTimer;
  bool _inviteJoinInFlight = false;
  bool _connectionCleanupInFlight = false;
  String? _lastPeerLossUserId;
  DateTime? _lastPeerLossAt;
  bool _processTeardownInFlight = false;
  StreamSubscription<void>? _processTeardownSubscription;
  late final PeerReconnectCoordinator _peerReconnect;
  bool _inPictureInPicture = false;
  /// True when another route (settings, group action, etc.) covers home.
  bool _routeCovered = false;
  String? _preferredGroupId;

  @override
  void initState() {
    super.initState();
    _peerReconnect = PeerReconnectCoordinator(
      onLostConnection: _showPeerLostConnection,
      onBackLive: _showPeerBackLive,
    );
    WidgetsBinding.instance.addObserver(this);
    _session =
        widget.identityRepository.currentSession ?? widget.initialSession;
    unawaited(HomeVisualVariantController.ensureLoaded());
    _preferredGroupId = widget.initialGroupId;
    widget.identityRepository.sessionListenable.addListener(
      _onIdentitySessionChanged,
    );
    // Defer: this screen is first inserted during StartupGateScreen.build,
    // and notifying the root accent ValueListenableBuilder in the same frame
    // fatals with setState-during-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AccentThemeController.setAccentKey(_session.settings.accentColorKey);
      unawaited(
        showPostCrashReportDialogIfNeeded(
          context,
          userId: _session.userId,
          groupId: _selectedGroup?.groupId,
        ),
      );
    });
    unawaited(
      AnalyticsService.logScreenView(
        screenName: 'identity_home',
        screenClass: 'IdentityHomeScreen',
      ),
    );
    _nudgeActionSubscription = AndroidVoiceNudgeBridge.actionSignals.listen((
      _,
    ) {
      unawaited(_takePendingNudgeAction());
    });
    _nudgeReceivedSubscription = AndroidVoiceNudgeBridge.receivedSignals.listen(
      (groupId) {
        LogManager.log(
          LogLevel.info,
          'NudgeService',
          'FCM trigger received on Dart bridge groupId=$groupId',
          userId: _session.userId,
          groupId: groupId,
        );
        unawaited(_onNudgeReceived(groupId));
      },
    );
    _incomingNudgeSubscription = AndroidVoiceNudgeBridge.incomingSignals.listen(
      (nudge) {
        _nudgeInbox.upsert(nudge);
        if (_appLifecycle == AppLifecycleState.resumed &&
            !_incomingPromptBusy &&
            !DeviceLogReport.uiBlocking) {
          unawaited(_presentIncomingNudgePrompt());
        }
      },
    );
    _incomingNudgeStatusSubscription = AndroidVoiceNudgeBridge
        .incomingStatusSignals
        .listen((update) {
          unawaited(
            _nudgeInbox.mark(
              nudgeId: update.nudgeId,
              status: update.status,
              snoozedUntil: update.snoozedUntil,
            ),
          );
          unawaited(_presentIncomingNudgePrompt());
        });
    _nudgeResponseSubscription = AndroidVoiceNudgeBridge.recipientResponses
        .listen(_onSenderNudgeResponse);
    _registrationRenewalSubscription = AndroidVoiceNudgeBridge
        .registrationSignals
        .listen((_) {
          unawaited(_refreshDeviceRegistration(force: true));
        });
    _inviteLinkSubscription = InviteLinkBridge.linkSignals.listen((_) {
      unawaited(_takePendingInviteLink());
    });
    _voicePipBridge.isInPictureInPicture.addListener(_onPipModeChanged);
    _voicePipActionSubscription = _voicePipBridge.actions.listen(
      (action) => unawaited(_handlePipAction(action)),
    );
    _processTeardownSubscription = _voicePipBridge.processTeardown.listen((_) {
      unawaited(_teardownLiveSessionForProcessDeath());
    });
    _audioOutputSubscription = AudioOutputBridge.changes.listen(
      _handleAudioOutputState,
    );
    unawaited(_refreshAudioOutputState());
    unawaited(_clearAbandonedOnlineSession());
    unawaited(_startConnectivityMonitoring());
    final bootstrap = widget.initialBootstrap;
    if (bootstrap != null) {
      _applyBootstrap(bootstrap);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        logStartupMilestone('Home visible');
        logStartupMilestone('Home data interactive');
        unawaited(_takePendingNudgeAction());
        unawaited(_takePendingInviteLink());
        unawaited(_clearOpenedChatPiles());
      });
    } else {
      unawaited(_loadGroups());
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => logStartupMilestone('Home visible'),
      );
    }
  }

  void _applyBootstrap(IdentityHomeBootstrap bootstrap) {
    _groups = bootstrap.groups;
    _selectedGroup = bootstrap.selectedGroup;
    LogManager.setIdentity(
      userId: _session.userId,
      groupId: bootstrap.selectedGroup?.groupId,
    );
    _members = bootstrap.members;
    // Copy — IdentityHomeBootstrap may hold `const {}`, and later member
    // loads write this map during foreground reconnects.
    _membersByGroupId = Map<String, List<GroupMemberSummary>>.of(
      bootstrap.membersByGroupId,
    );
    _carouselIndex = bootstrap.carouselIndex;
    _loadingGroups = false;
    _message = bootstrap.loadError;
    _syncDuoWidget();

    _userGroupsSubscription = _groupRepository
        .userGroupsRef(_session.userId)
        .onValue
        .listen((event) => unawaited(_handleUserGroupsChanged(event)));

    final selected = _selectedGroup;
    if (selected != null) {
      unawaited(AppTelemetry.setActiveGroup(selected.groupId));
      _listenToMembers(selected.groupId);
      _listenToAvailability(selected.groupId);
      _listenToChatMessages(selected.groupId);
      _listenToEmojiBursts(selected.groupId);
      _listenToMemberProfiles(_members);
    }
    unawaited(_reportMediaVolume());
  }

  @override
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      appRouteObserver.subscribe(this, route);
    }
  }

  // ── RouteAware callbacks ─────────────────────────────────────────────────

  @override
  void didPush() => _showPipOverlayIfLive();

  @override
  void didPopNext() {
    _routeCovered = false;
    _showPipOverlayIfLive();
  }

  /// Another route was pushed on top of home — show PiP if currently live.
  @override
  void didPushNext() {
    _routeCovered = true;
    _showPipOverlayIfLive();
  }

  // ── In-app PiP overlay helpers ───────────────────────────────────────────

  /// Keep the floating live-session control available when live but not already
  /// on the active group's home screen (PiP is for returning from other routes).
  void _showPipOverlayIfLive() {
    if (!_isOnline) return;
    if (_isViewingActiveGroup && !_routeCovered) {
      _hidePipOverlay();
      return;
    }
    LiveSessionOverlayController.instance.setSession(
      LiveSessionOverlayData(
        member: _localLiveMember,
        groupName: _activeLiveGroupName,
        microphoneMuted: !_microphoneEnabled,
        onToggleMicrophone: _toggleMicrophone,
        accentColor: accentColorForKey(_session.settings.accentColorKey),
      ),
    );
  }

  /// Refresh the PiP data (speaker / mute state) while the overlay is live.
  void _updatePipOverlay() {
    if (LiveSessionOverlayController.instance.state.value == null) return;
    LiveSessionOverlayController.instance.updateSession(
      LiveSessionOverlayData(
        member: _localLiveMember,
        groupName: _activeLiveGroupName,
        microphoneMuted: !_microphoneEnabled,
        onToggleMicrophone: _toggleMicrophone,
        accentColor: accentColorForKey(_session.settings.accentColorKey),
      ),
    );
  }

  /// Clear the in-app PiP only when the LiveKit session ends.
  void _hidePipOverlay() {
    LiveSessionOverlayController.instance.clearSession();
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    LiveSessionOverlayController.instance.clearSession();
    WidgetsBinding.instance.removeObserver(this);
    widget.identityRepository.sessionListenable.removeListener(
      _onIdentitySessionChanged,
    );
    _availabilitySubscription?.cancel();
    _availabilityExpiryTimer?.cancel();
    _membersSubscription?.cancel();
    _chatMessagesSubscription?.cancel();
    _emojiBurstSubscription?.cancel();
    _userGroupsSubscription?.cancel();
    for (final sub in _memberProfileSubscriptions) {
      unawaited(sub.cancel());
    }
    _memberProfileSubscriptions.clear();
    _connectivitySubscription?.cancel();
    _nudgeActionSubscription?.cancel();
    _nudgeReceivedSubscription?.cancel();
    _incomingNudgeSubscription?.cancel();
    _incomingNudgeStatusSubscription?.cancel();
    _nudgeResponseSubscription?.cancel();
    _registrationRenewalSubscription?.cancel();
    _inviteLinkSubscription?.cancel();
    _voicePipActionSubscription?.cancel();
    _processTeardownSubscription?.cancel();
    _audioOutputSubscription?.cancel();
    _hardwareAudioDeviceSubscription?.cancel();
    unawaited(AudioOutputBridge.setProximityMonitoring(false));
    _peerReconnect.clear();
    _voicePipBridge.isInPictureInPicture.removeListener(_onPipModeChanged);
    unawaited(_voicePipBridge.setSessionState(active: false, isTalking: false));
    unawaited(_voicePipBridge.dispose());
    _heartbeatTimer?.cancel();
    _peerDisconnectGraceTimer?.cancel();
    _inactivityTimer?.cancel();
    _callModeTimeoutTimer?.cancel();
    _usagePersistTimer?.cancel();
    _incomingExpiryTimer?.cancel();
    // Persist final usage before disposal.
    if (_todayOnlineSeconds > 0 && _onlineSession != null) {
      unawaited(_persistDailyUsage(_onlineSession!.groupId));
    }
    final activeTalk = _talkSession;
    if (activeTalk != null) {
      unawaited(_talkRepository.stopTalk(activeTalk, reason: 'screen_closed'));
    }
    unawaited(_disconnectLiveKit());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycle = state;
    if (state == AppLifecycleState.detached) {
      unawaited(_teardownLiveSessionForProcessDeath());
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _liveSessionActiveOnBackground = _isOnline && _room != null;
      return;
    }
    if (state == AppLifecycleState.resumed) {
      try {
        unawaited(_refreshDeviceRegistration());
        unawaited(_reportMediaVolume());
        // Notification Accept/Connect taps are queued natively and consumed
        // here. Opening the app by itself must not start a LiveKit session —
        // `_goOnline` still requires `_explicitJoinIntent`.
        unawaited(_takePendingNudgeAction());
        unawaited(_takePendingInviteLink());
        // The user is now actively looking at the app, so any pile that
        // accumulated while backgrounded should be cleared.
        unawaited(_clearOpenedChatPiles());
        if (!_liveSessionActiveOnBackground && !_explicitJoinIntent) {
          LogManager.log(
            LogLevel.info,
            'LiveKitManager',
            'Foreground with no active session and no join intent — '
                'skipping room connect',
            userId: _session.userId,
            groupId: _selectedGroup?.groupId,
          );
        }
      } catch (error) {
        // Resume work must never fatal the root zone (unmodifiable map
        // writes from plugins / inbox prune have historically thrown here).
        LogManager.log(
          LogLevel.error,
          'AppLifecycle',
          'Foreground resume handler failed: $error',
          userId: _session.userId,
        );
      }
    }
  }

  void _onPipModeChanged() {
    if (!mounted) return;
    setState(() {
      _inPictureInPicture = _voicePipBridge.isInPictureInPicture.value;
    });
  }

  /// One-shot STREAM_MUSIC self-report for every group this user is in.
  /// Android cannot expose another device's volume; this is the receiver
  /// half of the sender's post-send warning.
  Future<void> _reportMediaVolume() {
    return MediaVolumeStore.instance.reportForGroups(
      userId: _session.userId,
      groupIds: _groups.map((group) => group.groupId),
    );
  }

  Future<void> _handlePipAction(VoicePipAction action) async {
    if (_onlineSession == null) return;
    switch (action) {
      case VoicePipAction.toggleMicrophone:
        // Call mode's mic is always on by design — the PiP quick-action is
        // only meaningful for the walkie-talkie push-to-talk lock.
        if (_isCallMode) return;
        if (_talkSession == null) {
          await _startTalking();
        } else {
          await _stopTalking(reason: 'pip_toggle');
        }
        return;
    }
  }

  void _syncPipSessionState() {
    final session = _onlineSession;
    LogManager.log(
      LogLevel.info,
      'PresenceRing',
      'syncPipSessionState active=${session != null} '
          'sessionSuffix=${session == null ? "none" : session.serviceSessionId.substring(session.serviceSessionId.length - 6)} '
          'state=$_state',
      userId: _session.userId,
      groupId: session?.groupId ?? _selectedGroup?.groupId,
    );
    unawaited(
      _voicePipBridge.setSessionState(
        active: _onlineSession != null,
        isTalking: _talkSession != null || _isCallMode,
        session: _onlineSession,
      ),
    );
    // Keep the in-app floating PiP in sync with the same state changes that
    // drive the OS-level PiP — going away clears it, going live updates it.
    if (_onlineSession == null) {
      _hidePipOverlay();
    } else {
      _showPipOverlayIfLive();
    }
  }

  Future<void> _refreshDeviceRegistration({bool force = false}) async {
    final lastRefresh = _lastRegistrationRefreshAt;
    if (_registrationRefreshInFlight ||
        (!force &&
            lastRefresh != null &&
            DateTime.now().difference(lastRefresh) <
                const Duration(seconds: 30))) {
      return;
    }
    _registrationRefreshInFlight = true;
    try {
      await widget.identityRepository.ensureIdentity();
      _lastRegistrationRefreshAt = DateTime.now();
    } catch (error, stack) {
      debugPrint(
        '[OneOneFCM][DART-E5] Resume-time device registration refresh failed: $error',
      );
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'device_registration_refresh_failed',
        ),
      );
    } finally {
      _registrationRefreshInFlight = false;
    }
  }

  void _onIdentitySessionChanged() {
    final next = widget.identityRepository.currentSession;
    if (!mounted || next == null || next.userId != _session.userId) return;
    // Defer two frames so Settings / edit-profile modal pop + deactivate can
    // settle first. Same-frame setState under a deactivating modal races the
    // framework as `_dependents.isEmpty`.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final latest = widget.identityRepository.currentSession;
        if (latest == null || latest.userId != _session.userId) return;
        setState(() => _session = latest);
        AccentThemeController.setAccentKey(latest.settings.accentColorKey);
      });
    });
  }

  Future<void> _startConnectivityMonitoring() async {
    final connectivity = Connectivity();
    try {
      final current = await connectivity.checkConnectivity();
      _handleConnectivityChanged(current);
    } catch (_) {
      // LiveKit connection quality remains the primary signal.
    }
    _connectivitySubscription = connectivity.onConnectivityChanged.listen((
      results,
    ) {
      _handleConnectivityChanged(results);
    });
  }

  void _handleConnectivityChanged(List<ConnectivityResult> results) {
    if (!mounted) return;
    setState(() => _connectivity = results);
    if (results.contains(ConnectivityResult.none) && _isOnline) {
      unawaited(
        _handleConnectionLoss('You were marked Away due to network loss.'),
      );
    }
  }

  Future<void> _loadGroups() async {
    final stopwatch = Stopwatch()..start();
    setState(() => _loadingGroups = true);
    try {
      final groups = await _groupRepository.loadGroupsForUser(_session.userId);
      logStartupMilestone('groups loaded', stopwatch);
      if (!mounted) return;
      _userGroupsSubscription ??= _groupRepository
          .userGroupsRef(_session.userId)
          .onValue
          .listen((event) => unawaited(_handleUserGroupsChanged(event)));

      if (groups.isEmpty && (ModalRoute.of(context)?.isCurrent ?? true)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(_replaceWithNoGroups());
        });
        return;
      }

      final selected = IdentityHomeBootstrap.resolveSelectedGroup(
        groups,
        preferredGroupId: _preferredGroupId,
        currentGroup: _selectedGroup,
      );
      final selectedMembers = selected == null
          ? const <GroupMemberSummary>[]
          : await _groupRepository.loadGroupMembers(selected.groupId);
      final membersByGroupId = selected == null
          ? <String, List<GroupMemberSummary>>{}
          : <String, List<GroupMemberSummary>>{
              selected.groupId: selectedMembers,
            };
      logStartupMilestone('selected group members loaded', stopwatch);

      if (!mounted) return;
      setState(() {
        _groups = groups;
        _selectedGroup = selected;
        _membersByGroupId = membersByGroupId;
        _members = selected == null
            ? const []
            : membersByGroupId[selected.groupId] ?? const [];
        if (selected == null) {
          _availability = {};
          _chatMessages = const [];
        }
      });
      _syncDuoWidget();
      LogManager.setIdentity(groupId: selected?.groupId ?? '');
      if (selected != null) {
        unawaited(AppTelemetry.setActiveGroup(selected.groupId));
        unawaited(
          _precacheGroupMemberPhotos(
            membersByGroupId[selected.groupId] ?? const [],
          ),
        );
        _listenToMemberProfiles(membersByGroupId[selected.groupId] ?? const []);
      } else {
        unawaited(AppTelemetry.setActiveGroup(null));
      }
      _syncCarouselToSelectedGroup();

      if (selected != null) {
        _listenToMembers(selected.groupId);
        _listenToAvailability(selected.groupId);
        _listenToChatMessages(selected.groupId);
        _listenToEmojiBursts(selected.groupId);
      }
      unawaited(_reportMediaVolume());
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = LiveKitStatus.sanitizeError(error));
    } finally {
      if (mounted && _loadingGroups) {
        setState(() => _loadingGroups = false);
        logStartupMilestone('Home data interactive', stopwatch);
        unawaited(_takePendingNudgeAction());
        unawaited(_takePendingInviteLink());
        unawaited(_clearOpenedChatPiles());
        final pendingGroupIds = _pendingUserGroupIds;
        _pendingUserGroupIds = null;
        if (pendingGroupIds != null) {
          unawaited(_handleIndexedGroupsChanged(pendingGroupIds));
        }
      }
    }
  }

  Future<void> _handleUserGroupsChanged(DatabaseEvent event) async {
    if (!mounted) return;
    final value = event.snapshot.value;
    final indexedGroupIds = value is Map<Object?, Object?>
        ? value.keys.map((key) => key.toString()).toSet()
        : <String>{};
    if (_loadingGroups) {
      _pendingUserGroupIds = indexedGroupIds;
      return;
    }
    await _handleIndexedGroupsChanged(indexedGroupIds);
  }

  Future<void> _handleIndexedGroupsChanged(Set<String> indexedGroupIds) async {
    if (!mounted) return;
    final loadedGroupIds = _groups.map((group) => group.groupId).toSet();
    if (indexedGroupIds.length == loadedGroupIds.length &&
        indexedGroupIds.containsAll(loadedGroupIds)) {
      return;
    }

    final activeGroupId = _onlineSession?.groupId;
    if (activeGroupId != null && !indexedGroupIds.contains(activeGroupId)) {
      await _endRevokedVoiceSession(activeGroupId);
    }
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    if (!mounted) return;
    await _loadGroups();
    if (mounted && indexedGroupIds.isNotEmpty) {
      setState(() => _message = 'Your group membership changed.');
    }
  }

  Future<void> _endRevokedVoiceSession(String groupId) async {
    if (_onlineSession?.groupId != groupId) return;
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
    await _disconnectLiveKit();
    if (!mounted) return;
    setState(() {
      _onlineSession = null;
      _talkSession = null;
      _talkPressed = false;
      _speakingUserIds = const {};
      _state = 'away';
      _connectionMode = MemberAvailability.walkieTalkieMode;
    });
    _explicitJoinIntent = false;
    _deferredNudgeAction = null;
    _liveSessionActiveOnBackground = false;
    _syncPipSessionState();
  }

  Future<void> _takePendingInviteLink() async {
    if (_inviteJoinInFlight || _loadingGroups) return;
    final inviteCode = await _inviteLinkBridge.peekPendingInviteCode();
    if (inviteCode == null || !mounted) return;
    _inviteJoinInFlight = true;
    try {
      final groupId = await _groupRepository.joinInvite(inviteCode);
      await _inviteLinkBridge.clearPendingInviteCode(inviteCode);
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
      if (!mounted) return;
      _preferredGroupId = groupId;
      debugPrint(
        '[OneOneInvite] Joined link while Home was active groupSuffix='
        '${groupId.length <= 6 ? groupId : groupId.substring(groupId.length - 6)}',
      );
      await _loadGroups();
      if (mounted) {
        setState(() => _message = 'Group joined from invite link.');
      }
    } catch (error, stack) {
      debugPrint(
        '[OneOneInvite] Active invite failed ${error.runtimeType}: $error',
      );
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'invite_join_failed',
        ),
      );
      if (error is ApiException &&
          const {
            'invite_not_found',
            'invite_unavailable',
            'group_full',
            'group_not_active',
          }.contains(error.code)) {
        await _inviteLinkBridge.clearPendingInviteCode(inviteCode);
      }
      if (mounted) {
        setState(() {
          _message = error is ApiException
              ? error.message
              : 'Couldn’t open this invite. Check your connection.';
        });
      }
    } finally {
      _inviteJoinInFlight = false;
    }
  }

  Future<void> _takePendingNudgeAction() async {
    if (_nudgeActionInFlight) return;
    NudgeNotificationAction? action;
    // [DEBUG] Go-live latency tracing added Aug 12. Remove before production
    // release.
    final step1StartedAt = _goLiveStepStart(
      1,
      'Nudge accepted by receiver (user action) — taking pending action from native bridge',
    );
    try {
      action =
          _deferredNudgeAction ??
          await _nudgeActionBridge.takePendingNudgeAction();
      if (!mounted) return;
      if (action == null) {
        unawaited(_hydrateIncomingNudges());
        return;
      }
      if (_loadingGroups) {
        _deferredNudgeAction = action;
        return;
      }
      _goLiveStepEnd(
        1,
        'Nudge accepted by receiver (user action) — action=${action.action} '
        'eventId=${action.eventId} groupId=${action.groupId}',
        step1StartedAt,
      );
      _deferredNudgeAction = null;
      if (action.isOpenOnly) {
        _nudgeInbox.upsert(
          ActiveNudge(
            nudgeId: action.eventId,
            groupId: action.groupId,
            senderId: action.senderUserId ?? '',
            sentAt: DateTime.now(),
          ),
        );
        await _hydrateIncomingNudges(
          preferGroupId: action.groupId,
          preferNudgeId: action.eventId,
        );
        return;
      }
      _nudgeActionInFlight = true;
      await _processNudgeAction(action);
    } catch (error) {
      // Banner taps only open the Accept/Decline prompt — never auto-join.
      // Don't surface the Accept-path error if hydrate/present failed.
      if (action != null && action.isOpenOnly) {
        if (mounted) {
          await _presentIncomingNudgePrompt(
            preferGroupId: action.groupId,
            preferNudgeId: action.eventId,
          );
        }
        return;
      }
      // Only defer while home data is still loading. Re-queuing after a
      // later failure would auto-connect on every subsequent foreground.
      if (action != null && _loadingGroups) {
        _deferredNudgeAction = action;
      }
      if (mounted) {
        setState(() => _message = 'Couldn’t process the nudge action.');
      }
    } finally {
      _nudgeActionInFlight = false;
    }
  }

  /// Fired when this device receives a nudge (FCM arrived / playback starting),
  /// before the user has tapped accept. Prefetches + warms the LiveKit
  /// connection so the accept -> connected path skips the token round-trip and
  /// the WebRTC/DNS/TLS warm-up.
  Future<void> _onNudgeReceived(String groupId) async {
    final group = _groups
        .where((candidate) => candidate.groupId == groupId)
        .firstOrNull;
    if (group == null) return;
    await _prefetchLiveKit(group: group);
  }

  /// Prefetches a LiveKit token and warms the local [Room]/DNS/TLS without
  /// connecting. Best-effort: any failure here is ignored because the real
  /// go-online path still performs a synchronous fallback.
  Future<void> _prefetchLiveKit({required GroupSummary group}) async {
    // Warm rooms always default to speaker; session connect reasserts this (E1).
    await LiveKitConnectionWarmer.instance.prefetch(
      repository: _onlineRepository,
      identity: _session,
      group: group,
      speakerOn: true,
    );
  }

  Future<void> _processNudgeAction(NudgeNotificationAction action) async {
    if (_processedNudgeEventIds.contains(action.eventId)) {
      LogManager.log(
        LogLevel.info,
        'LiveKitManager',
        'Ignoring already-processed nudge action=${action.action} '
            'eventId=${action.eventId}',
        userId: _session.userId,
        groupId: action.groupId,
      );
      return;
    }
    // Mark before awaiting goOnline so a parallel FCM/native path with the
    // same eventId cannot start a second connect mid-handshake.
    _processedNudgeEventIds.add(action.eventId);
    // [DEBUG] Go-live latency tracing added Aug 12. Remove before production
    // release.
    final step2StartedAt = _goLiveStepStart(
      2,
      'FCM/notification payload parsed — resolving target group locally',
    );
    final index = _groups.indexWhere(
      (group) => group.groupId == action.groupId,
    );
    if (index < 0) {
      setState(() => _message = 'That nudge group is no longer available.');
      return;
    }
    _goLiveStepEnd(
      2,
      'FCM/notification payload parsed — resolved groupId=${action.groupId} at carouselIndex=$index',
      step2StartedAt,
    );

    await _onGroupCarouselChanged(index);
    if (!mounted) return;
    _explicitJoinIntent = true;
    if (!_isViewingActiveGroup) {
      if (_isOnline) {
        await _switchVoiceGroup();
      } else {
        await _goOnline(userIntent: true);
      }
    }
    if (!mounted) return;
    if (!_isOnline) {
      _processedNudgeEventIds.remove(action.eventId);
      _explicitJoinIntent = false;
      throw StateError('Could not enter the nudge group.');
    }
    // Entered (or is entering) via nudge — remember so a later
    // single-user-in-room bug report can explain how it occurred.
    _enteredViaNudge = true;
    // The receiver accepted the nudge (or this device accepted one) — the
    // last sent nudge is no longer the active pending state.
    NudgeStatusMemory.instance.clear(action.groupId);
    if (mounted) setState(() {});
    if (action.action == 'connect' &&
        _appLifecycle != AppLifecycleState.resumed) {
      // Sender auto-connected while the app stayed in the background — the
      // shade notification is the only confirmation they get.
      final group = _groups
          .where((candidate) => candidate.groupId == action.groupId)
          .firstOrNull;
      unawaited(
        AndroidVoiceNudgeBridge.shared.showYouAreOnlineNotification(
          groupId: action.groupId,
          groupName: group?.name,
        ),
      );
    }
    if (action.action != 'accept') return;
    await _nudgeInbox.mark(
      nudgeId: action.eventId,
      status: ActiveNudgeStatus.accepted,
    );
    unawaited(_nudgeActionBridge.dismissIncomingNudge(action.eventId));
    // Don't block the in-app dialogue on the HTTP respond — the receiver is
    // already live. A hung /respond left Accept spinning forever.
    unawaited(_notifyNudgeAccepted(action));
    debugPrint(
      '[OneOneFCM][DART-07] Accepted nudge and entered group '
      'eventSuffix=${action.eventId.length <= 6 ? action.eventId : action.eventId.substring(action.eventId.length - 6)}',
    );
    _promptRestoreGroupId = null;
    _incomingExpiryTimer?.cancel();
    if (mounted) {
      setState(() {
        _incomingPromptNudge = null;
        _incomingPromptBusy = false;
        _message = 'Nudge accepted — you’re now online together.';
      });
    }
    unawaited(
      _acceptSiblingNudges(action.groupId, exceptNudgeId: action.eventId),
    );
  }

  Future<void> _notifyNudgeAccepted(NudgeNotificationAction action) async {
    try {
      await _nudgeRepository.respond(
        groupId: action.groupId,
        eventId: action.eventId,
        action: 'accept',
      );
    } catch (error) {
      LogManager.log(
        LogLevel.warn,
        'NudgeService',
        'Accept respond failed after join: $error',
        userId: _session.userId,
        groupId: action.groupId,
      );
    }
  }

  /// Sender-side: decline/snooze (and accept) replies update profile signifiers
  /// even when the nudge sheet is closed.
  void _onSenderNudgeResponse(NudgeRecipientResponse response) {
    if (response.isAccept) {
      NudgeStatusMemory.instance.clear(response.groupId);
      if (mounted && _selectedGroup?.groupId == response.groupId) {
        setState(() {});
      }
      unawaited(_connectSenderAfterNudgeAccept(response));
      return;
    }

    final updated = NudgeStatusMemory.instance.applyRecipientResponse(
      eventId: response.eventId,
      groupId: response.groupId,
      responderUserId: response.responderUserId ?? '',
      responderName: response.responderName ?? 'Friend',
      action: response.action,
    );
    if (!updated) return;
    if (!mounted) return;
    if (_selectedGroup?.groupId == response.groupId) {
      setState(() {});
    }
  }

  /// Brings the sender online when a receiver accepts, including while the
  /// app is backgrounded (native bridge queues connect + may launch the app).
  Future<void> _connectSenderAfterNudgeAccept(
    NudgeRecipientResponse response,
  ) async {
    if (_nudgeActionInFlight || _goOnlineInFlight || _isOnline) return;
    if (_processedNudgeEventIds.contains(response.eventId)) return;
    final action = NudgeNotificationAction(
      action: 'connect',
      eventId: response.eventId,
      groupId: response.groupId,
    );
    if (_loadingGroups) {
      _deferredNudgeAction = action;
      return;
    }
    try {
      _nudgeActionInFlight = true;
      await _processNudgeAction(action);
    } catch (error) {
      LogManager.log(
        LogLevel.warn,
        'NudgeService',
        'Sender auto-connect after accept failed: $error',
        userId: _session.userId,
        groupId: response.groupId,
      );
    } finally {
      _nudgeActionInFlight = false;
    }
  }

  Map<String, NudgeRecipientReply> _nudgeRepliesForGroup(String? groupId) {
    if (groupId == null || groupId.isEmpty) return const {};
    final entry = NudgeStatusMemory.instance.forGroup(groupId);
    if (entry == null) return const {};
    return {
      for (final signifier in entry.signifiers)
        if (signifier.reply != null) signifier.userId: signifier.reply!,
    };
  }

  /// After the receiver is already live, accept any other still-pending
  /// senders in the same group so both LiveKit tokens connect.
  Future<void> _acceptSiblingNudges(
    String groupId, {
    required String exceptNudgeId,
  }) async {
    await _hydrateIncomingNudges(present: false);
    final extras = _nudgeInbox
        .activeInGroup(groupId)
        .where((nudge) => nudge.nudgeId != exceptNudgeId)
        .toList(growable: false);
    for (final extra in extras) {
      _processedNudgeEventIds.add(extra.nudgeId);
      unawaited(
        _nudgeRepository.respond(
          groupId: extra.groupId,
          eventId: extra.nudgeId,
          action: 'accept',
        ),
      );
      unawaited(_nudgeActionBridge.dismissIncomingNudge(extra.nudgeId));
    }
    await _nudgeInbox.markAllInGroup(
      groupId: groupId,
      status: ActiveNudgeStatus.accepted,
    );
    if (mounted) {
      await _presentIncomingNudgePrompt(ignoreInFlight: true);
    }
  }

  Future<void> _hydrateIncomingNudges({
    String? preferGroupId,
    String? preferNudgeId,
    bool present = true,
  }) async {
    if (_loadingGroups || !mounted) return;
    if (_incomingHydrateInFlight) {
      for (var i = 0; i < 50 && _incomingHydrateInFlight; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        if (!mounted) return;
      }
      if (present) {
        await _presentIncomingNudgePrompt(
          preferGroupId: preferGroupId,
          preferNudgeId: preferNudgeId,
        );
      }
      return;
    }
    _incomingHydrateInFlight = true;
    try {
      try {
        await _nudgeInbox.bindUser(_session.userId);
      } catch (error) {
        LogManager.log(
          LogLevel.warn,
          'NudgeService',
          'Incoming nudge inbox bind failed: $error',
          userId: _session.userId,
        );
      }
      try {
        final native = await _nudgeActionBridge.listIncomingNudges();
        for (final nudge in native) {
          if (nudge.senderId == _session.userId) continue;
          _nudgeInbox.upsert(nudge);
          if (nudge.status != ActiveNudgeStatus.pending) {
            await _nudgeInbox.mark(
              nudgeId: nudge.nudgeId,
              status: nudge.status,
              snoozedUntil: nudge.snoozedUntil,
            );
          }
        }
      } catch (error) {
        LogManager.log(
          LogLevel.warn,
          'NudgeService',
          'Native incoming nudge cache failed: $error',
          userId: _session.userId,
        );
      }
      try {
        final remote = await _nudgeSync.loadForGroups(
          groupIds: _groups.map((group) => group.groupId),
          currentUserId: _session.userId,
        );
        _nudgeInbox.upsertAll(remote);
      } catch (error) {
        LogManager.log(
          LogLevel.warn,
          'NudgeService',
          'Remote incoming nudge sync failed: $error',
          userId: _session.userId,
        );
      }
    } finally {
      _incomingHydrateInFlight = false;
    }
    if (present && mounted) {
      await _presentIncomingNudgePrompt(
        preferGroupId: preferGroupId,
        preferNudgeId: preferNudgeId,
      );
    }
  }

  Future<void> _presentIncomingNudgePrompt({
    String? preferGroupId,
    String? preferNudgeId,
    bool ignoreInFlight = false,
  }) async {
    if (!mounted ||
        _inPictureInPicture ||
        _loadingGroups ||
        DeviceLogReport.uiBlocking) {
      return;
    }
    if (!ignoreInFlight && (_nudgeActionInFlight || _incomingPromptBusy)) {
      return;
    }
    final queue = _nudgeInbox
        .presentationQueue(
          preferGroupId: preferGroupId ?? _incomingPromptNudge?.groupId,
          preferNudgeId: preferNudgeId,
        )
        .where(
          (nudge) => _groups.any((group) => group.groupId == nudge.groupId),
        )
        .toList();
    if (queue.isEmpty) {
      await _dismissIncomingPrompt(restoreGroup: _incomingPromptNudge != null);
      return;
    }
    final next = queue.first;
    // Always show accept/decline — never auto-accept from a prior accept in
    // this group (ring/nudge position must stay an explicit choice).
    _promptRestoreGroupId ??= _selectedGroup?.groupId;
    await _focusGroupForIncomingNudge(next);
    if (!mounted) return;
    setState(() => _incomingPromptNudge = next);
    _scheduleIncomingExpiryWatch();
  }

  Future<void> _focusGroupForIncomingNudge(ActiveNudge nudge) async {
    final index = _groups.indexWhere((group) => group.groupId == nudge.groupId);
    if (index < 0) return;
    unawaited(_prefetchLiveKit(group: _groups[index]));
    await _onGroupCarouselChanged(index);
  }

  Future<void> _dismissIncomingPrompt({required bool restoreGroup}) async {
    _incomingExpiryTimer?.cancel();
    final restoreId = _promptRestoreGroupId;
    _promptRestoreGroupId = null;
    if (!mounted) return;
    setState(() {
      _incomingPromptNudge = null;
      _incomingPromptBusy = false;
    });
    if (!restoreGroup || restoreId == null) return;
    final index = _groups.indexWhere((group) => group.groupId == restoreId);
    if (index >= 0) await _onGroupCarouselChanged(index);
  }

  void _scheduleIncomingExpiryWatch() {
    _incomingExpiryTimer?.cancel();
    _incomingExpiryTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted || _incomingPromptNudge == null) {
        _incomingExpiryTimer?.cancel();
        return;
      }
      unawaited(_presentIncomingNudgePrompt());
    });
  }

  Future<void> _acceptIncomingNudge(ActiveNudge nudge) async {
    if (_incomingPromptBusy) return;
    setState(() {
      _incomingPromptBusy = true;
      _incomingPromptNudge = null;
    });
    _incomingExpiryTimer?.cancel();
    try {
      await _processNudgeAction(
        NudgeNotificationAction(
          action: 'accept',
          eventId: nudge.nudgeId,
          groupId: nudge.groupId,
          senderUserId: nudge.senderId,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _incomingPromptBusy = false;
        _incomingPromptNudge = nudge;
        _message = 'Couldn’t join this group. Check your connection.';
      });
      _scheduleIncomingExpiryWatch();
      return;
    } finally {
      if (mounted && _incomingPromptBusy) {
        setState(() => _incomingPromptBusy = false);
      }
    }
    if (mounted) {
      await _presentIncomingNudgePrompt();
    }
  }

  Future<void> _declineIncomingNudge(ActiveNudge nudge) async {
    if (_incomingPromptBusy) return;
    setState(() => _incomingPromptBusy = true);
    final pending = _nudgeInbox.activeInGroup(nudge.groupId);
    for (final event in pending) {
      _processedNudgeEventIds.add(event.nudgeId);
      unawaited(
        _nudgeRepository.respond(
          groupId: event.groupId,
          eventId: event.nudgeId,
          action: 'decline',
        ),
      );
      unawaited(_nudgeActionBridge.dismissIncomingNudge(event.nudgeId));
    }
    await _nudgeInbox.markAllInGroup(
      groupId: nudge.groupId,
      status: ActiveNudgeStatus.declined,
    );
    if (!mounted) return;
    setState(() => _incomingPromptBusy = false);
    await _presentIncomingNudgePrompt();
  }

  Future<void> _replaceWithNoGroups() async {
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => NoGroupsScreen(
          session: _session,
          identityRepository: widget.identityRepository,
        ),
      ),
    );
  }

  Future<void> _loadMembers(String groupId) async {
    final members = await _groupRepository.loadGroupMembers(groupId);
    if (!mounted || _selectedGroup?.groupId != groupId) return;
    setState(() {
      _members = members;
      _membersByGroupId = {..._membersByGroupId, groupId: members};
    });
    _listenToMemberProfiles(members);
  }

  /// Profile photos are loaded with members via RTDB. This just clears any
  /// leftover per-user profile subscriptions from earlier builds.
  void _listenToMemberProfiles(List<GroupMemberSummary> members) {
    for (final sub in _memberProfileSubscriptions) {
      unawaited(sub.cancel());
    }
    _memberProfileSubscriptions.clear();
  }

  Future<void> _precacheGroupMemberPhotos(
    Iterable<GroupMemberSummary> members,
  ) async {
    final urls = members
        .map((member) => member.profilePhotoUrl?.trim())
        .whereType<String>()
        .where((url) => url.isNotEmpty)
        .toSet();

    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final pixelSize = (MediaQuery.sizeOf(context).shortestSide * dpr)
        .round()
        .clamp(
          CloudinaryDelivery.minFetchEdge,
          CloudinaryDelivery.maxStoredEdge,
        );
    await Future.wait(
      urls.map((url) async {
        try {
          await precacheImage(
            CachedNetworkImageProvider(
              CloudinaryDelivery.urlFor(url, pixelSize: pixelSize),
            ),
            context,
            onError: (error, stackTrace) {},
          );
        } catch (_) {
          // A broken member photo falls back to initials in ProfileImage.
        }
      }),
    );
  }

  void _listenToMembers(String groupId) {
    unawaited(_membersSubscription?.cancel());
    _membersSubscription = AppDatabase.instance()
        .ref('groupMembers/$groupId')
        .onValue
        .listen((event) {
          if (groupMembershipMatchesSnapshot(
            members: _members,
            snapshotValue: event.snapshot.value,
          )) {
            return;
          }
          unawaited(_loadMembers(groupId));
        });
  }

  void _listenToAvailability(String groupId) {
    unawaited(_availabilitySubscription?.cancel());
    _hasAvailabilitySnapshot = false;
    _availabilitySubscription = AppDatabase.instance()
        .ref('memberAvailability/$groupId')
        .onValue
        .listen((event) {
          final value = event.snapshot.value;
          final next = <String, MemberAvailability>{};

          if (value is Map<Object?, Object?>) {
            for (final entry in value.entries) {
              final raw = entry.value;
              if (raw is Map<Object?, Object?>) {
                next[entry.key.toString()] = MemberAvailability.fromJson(raw);
              }
            }
          }

          if (!mounted || _selectedGroup?.groupId != groupId) return;
          _logFriendRingTransitions(groupId: groupId, next: next, raw: value);
          if (_hasAvailabilitySnapshot) {
            final lostPeerIds = _availability.entries
                .where(
                  (entry) =>
                      entry.key != _session.userId &&
                      entry.value.isLive &&
                      !(next[entry.key]?.isLive ?? false),
                )
                .map((entry) => entry.key)
                .toList(growable: false);
            final rejoinedPeerIds = next.entries
                .where(
                  (entry) =>
                      entry.key != _session.userId &&
                      entry.value.isLive &&
                      !(_availability[entry.key]?.isLive ?? false),
                )
                .map((entry) => entry.key)
                .toList(growable: false);
            for (final userId in lostPeerIds) {
              _peerReconnect.peerLeft(userId);
            }
            for (final userId in rejoinedPeerIds) {
              _peerReconnect.peerJoined(userId);
            }
          }
          setState(() => _availability = next);
          _hasAvailabilitySnapshot = true;
          _scheduleAvailabilityExpiryRefresh();
          if (_onlineSession?.groupId == groupId) {
            _evaluatePeerPresenceForAutoOffline(next);
          }
        });
  }

  /// Logs green-ring (isLive) transitions for friends on the home strip.
  void _logFriendRingTransitions({
    required String groupId,
    required Map<String, MemberAvailability> next,
    required Object? raw,
  }) {
    final rawByUserId = <String, Map<Object?, Object?>>{};
    if (raw is Map<Object?, Object?>) {
      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is Map<Object?, Object?>) {
          rawByUserId[entry.key.toString()] = value;
        }
      }
    }

    for (final friend in _friends) {
      final userId = friend.userId;
      final prevLive =
          (_availability[userId] ?? MemberAvailability.away).isLive;
      final nextAvail = next[userId] ?? MemberAvailability.away;
      final nextLive = nextAvail.isLive;
      if (!_hasAvailabilitySnapshot || prevLive == nextLive) continue;

      final rawEntry = rawByUserId[userId];
      final activeSessionId = rawEntry?['activeServiceSessionId']?.toString();
      final sessionSuffix = activeSessionId == null || activeSessionId.isEmpty
          ? 'none'
          : activeSessionId.length <= 6
          ? activeSessionId
          : activeSessionId.substring(activeSessionId.length - 6);

      LogManager.log(
        LogLevel.info,
        'PresenceRing',
        'UI ring ${prevLive ? "live" : "grey"} -> ${nextLive ? "live" : "grey"} '
            'peer=${friend.displayName} userId=$userId '
            'effective=${nextAvail.effectiveState} desired=${nextAvail.desiredState} '
            'canAudio=${nextAvail.canReceiveLiveAudio} sessionSuffix=$sessionSuffix '
            'localOnline=$_isOnline localState=$_state',
        userId: _session.userId,
        groupId: groupId,
      );
    }
  }

  /// Live-syncs the last [ChatMessageRepository.visibleLimit] chat bubbles
  /// for a group. Uses push-key order (`limitToLast` without `orderByChild`)
  /// so the query doesn't depend on a deployed secondary index, then sorts
  /// by `createdAt` client-side. Caps client-side again so even a partial
  /// snapshot never shows more than the rolling window.
  void _listenToChatMessages(String groupId) {
    unawaited(_chatMessagesSubscription?.cancel());
    unawaited(_clearChatPile(groupId));
    _chatMessagesSubscription = _chatMessageRepository
        .groupMessagesRef(groupId)
        .limitToLast(ChatMessageRepository.visibleLimit)
        .onValue
        .listen(
          (event) {
            if (!mounted || _selectedGroup?.groupId != groupId) return;
            final value = event.snapshot.value;
            final messages = <GroupChatMessage>[];
            // Accept any Map shape Firebase returns (String/Object keys).
            if (value is Map) {
              for (final entry in value.entries) {
                final parsed = GroupChatMessage.tryParse(
                  entry.key.toString(),
                  entry.value,
                );
                if (parsed == null || parsed.isExpired) continue;
                messages.add(parsed);
              }
            }
            // Deterministic order: createdAt, then messageId (not arrival order).
            messages.sort((a, b) {
              final byTime = a.createdAt.compareTo(b.createdAt);
              return byTime != 0
                  ? byTime
                  : a.messageId.compareTo(b.messageId);
            });
            final window = messages.length > ChatMessageRepository.visibleLimit
                ? messages.sublist(
                    messages.length - ChatMessageRepository.visibleLimit,
                  )
                : messages;
            setState(() => _chatMessages = window);
            unawaited(_clearChatPile(groupId));
          },
          onError: (Object error, StackTrace stackTrace) {
            // Don't leave the feed stuck empty after a transient deny/blip —
            // log and keep the last good list; next group reselect resubscribes.
            CrashlyticsService.recordError(
              error,
              stackTrace,
              reason: 'chat_messages_listen_failed groupId=$groupId',
            );
          },
        );
  }

  // ── B8: Emoji burst listener ──
  /// Listens for emoji bursts from remote participants and triggers the
  /// local burst animation.
  void _listenToEmojiBursts(String groupId) {
    unawaited(_emojiBurstSubscription?.cancel());
    _emojiBurstSubscription = _chatMessageRepository
        .watchEmojiBursts(groupId)
        .listen(
          (data) {
            if (!mounted || _selectedGroup?.groupId != groupId) return;
            final senderUserId = data['senderUserId']?.toString();
            if (senderUserId == null || senderUserId == _session.userId) {
              return;
            }
            final emoji = data['emoji']?.toString().trim() ?? '';
            if (emoji.isEmpty) return;
            final senderName =
                data['senderDisplayName']?.toString().trim() ?? 'friend';
            final burstId = data['burstId']?.toString();
            if (burstId == null) return;

            final id = 'remote-$burstId';
            if (!mounted) return;
            setState(() {
              _emojiBursts = [
                ..._emojiBursts.where((item) => item.id != id),
                EmojiBurst(id: id, emoji: emoji, senderName: senderName),
              ];
              if (_emojiBursts.length > 2) {
                _emojiBursts = _emojiBursts.sublist(_emojiBursts.length - 2);
              }
            });
          },
          onError: (Object error, StackTrace stackTrace) {
            unawaited(
              CrashlyticsService.recordError(
                error,
                stackTrace,
                reason: 'emoji_burst_listener_failed groupId=$groupId',
                feature: 'chat',
              ),
            );
            // Stream dies after a deny/disconnect — resubscribe if still here.
            if (!mounted || _selectedGroup?.groupId != groupId) return;
            Future<void>.delayed(const Duration(seconds: 2), () {
              if (!mounted || _selectedGroup?.groupId != groupId) return;
              _listenToEmojiBursts(groupId);
            });
          },
        );
  }

  Future<void> _clearOpenedChatPiles() async {
    final tappedGroupId = await _nudgeActionBridge.takePendingChatPileOpen();
    if (tappedGroupId != null && tappedGroupId.isNotEmpty) {
      unawaited(_clearChatPile(tappedGroupId, force: true));
    }
    final selected = _selectedGroup;
    if (selected != null && selected.groupId != tappedGroupId) {
      unawaited(_clearChatPile(selected.groupId));
    }
  }

  Future<void> _clearChatPile(String groupId, {bool force = false}) async {
    // Only the foreground app clears the pile. The RTDB listener keeps
    // firing in the background, and clearing there would cancel the pile
    // notification and reset the server unread count right after the FCM
    // service posts it — breaking the WhatsApp-style collapse.
    // Tapping the notification is an explicit read, so [force] skips the
    // lifecycle gate and zeros the count immediately.
    if (!force && _appLifecycle != AppLifecycleState.resumed) return;
    unawaited(
      _chatMessageRepository.clearUnreadPile(
        groupId: groupId,
        userId: _session.userId,
      ),
    );
    await _nudgeActionBridge.clearChatPile(groupId);
  }

  void _dismissExpiredChatMessage(String messageId) {
    if (!mounted) return;
    setState(() {
      _chatMessages = _chatMessages
          .where((message) => message.messageId != messageId)
          .toList(growable: false);
    });
  }

  String _chatDisplayNameForUser(String userId, String fallback) {
    if (userId == _session.userId) {
      return _session.user.displayName;
    }
    for (final member in _members) {
      if (member.userId == userId) {
        return member.displayName;
      }
    }
    return fallback;
  }

  Future<void> _sendChatMessage(String text) async {
    final group = _selectedGroup;
    if (group == null) return;
    if (_session.settings.hapticsEnabled) {
      unawaited(HapticFeedback.selectionClick());
    }
    try {
      await _chatMessageRepository.sendMessage(
        groupId: group.groupId,
        senderUserId: _session.userId,
        senderDisplayName: _session.user.displayName,
        text: text,
      );
    } catch (error) {
      if (!mounted) rethrow;
      setState(() => _message = 'Couldn’t send message. Try again.');
      rethrow;
    }
  }

  void _triggerEmojiBurst(String emoji) {
    final trimmed = emoji.trim();
    if (trimmed.isEmpty || !mounted) return;
    if (_session.settings.hapticsEnabled) {
      unawaited(HapticFeedback.selectionClick());
    }
    final id =
        '${_session.userId}-${DateTime.now().microsecondsSinceEpoch}-$trimmed';
    setState(() {
      _emojiBursts = [
        ..._emojiBursts.where((item) => item.id != id),
        EmojiBurst(
          id: id,
          emoji: trimmed,
          senderName: _session.user.displayName,
        ),
      ];
      // Cap concurrent streams so rapid taps don't flood the overlay.
      if (_emojiBursts.length > 2) {
        _emojiBursts = _emojiBursts.sublist(_emojiBursts.length - 2);
      }
    });

    // B8: Send emoji burst to remote participants via RTDB.
    final group = _selectedGroup;
    if (group != null && _isOnline) {
      unawaited(
        _chatMessageRepository.sendEmojiBurst(
          groupId: group.groupId,
          senderUserId: _session.userId,
          senderDisplayName: _session.user.displayName,
          emoji: trimmed,
        ),
      );
    }
  }

  void _onEmojiBurstFinished(String id) {
    if (!mounted) return;
    setState(() {
      _emojiBursts = _emojiBursts
          .where((burst) => burst.id != id)
          .toList(growable: false);
    });
  }

  void _showPeerLostConnection(String userId) {
    final now = DateTime.now();
    if (_lastPeerLossUserId == userId &&
        _lastPeerLossAt != null &&
        now.difference(_lastPeerLossAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastPeerLossUserId = userId;
    _lastPeerLossAt = now;
    final name = _membersByGroupId.values
        .expand((members) => members)
        .where((member) => member.userId == userId)
        .map((member) => member.displayName.trim())
        .firstOrNull;
    _showPresenceSnackbar(
      '${name == null || name.isEmpty ? 'A participant' : name} lost connection.',
    );
  }

  void _showPeerBackLive(String userId) {
    final name = _membersByGroupId.values
        .expand((members) => members)
        .where((member) => member.userId == userId)
        .map((member) => member.displayName.trim())
        .firstOrNull;
    _showPresenceSnackbar(
      '${name == null || name.isEmpty ? 'A participant' : name} is back live.',
    );
  }

  /// Implements "automatic offline handling with a grace period": while
  /// this device is online, watch for the group dropping to exactly one
  /// online member. If nobody else is in (or rejoining) the room for
  /// [PresenceConfig.disconnectGracePeriod], this device is taken offline.
  ///
  /// The countdown only runs while we remain alone uninterrupted. Any other
  /// member rejoining — including still-connecting — cancels/resets it; a
  /// later drop back to one member starts a fresh minute.
  void _evaluatePeerPresenceForAutoOffline(
    Map<String, MemberAvailability> availability,
  ) {
    if (!_isOnline) {
      _peerWasLiveWithMe = false;
      _peerDisconnectGraceTimer?.cancel();
      _peerDisconnectGraceTimer = null;
      return;
    }

    final anyPeerInSession = _anyOtherMemberInVoiceSession(availability);

    if (anyPeerInSession) {
      _peerWasLiveWithMe = true;
      if (_peerDisconnectGraceTimer != null) {
        _peerDisconnectGraceTimer?.cancel();
        _peerDisconnectGraceTimer = null;
        if (mounted) setState(() => _message = 'Your friend reconnected.');
      }
      return;
    }

    // Never had a peer live with us yet (e.g. we just connected and theirs
    // hasn't propagated) — nothing to react to.
    if (!_peerWasLiveWithMe) return;
    if (_peerDisconnectGraceTimer != null) return;

    _peerDisconnectGraceTimer = Timer(PresenceConfig.disconnectGracePeriod, () {
      _peerDisconnectGraceTimer = null;
      if (!mounted || !_isOnline) return;
      // Re-check at fire time: a rejoin may have landed after the last
      // evaluation (or while this callback was already queued).
      if (_anyOtherMemberInVoiceSession(_availability)) return;
      unawaited(_goAway(reason: 'peer_left'));
      _showPresenceSnackbar(
        'The other participant has gone offline. You are now offline.',
      );
    });
  }

  bool _anyOtherMemberInVoiceSession(
    Map<String, MemberAvailability> availability,
  ) {
    return availability.entries.any(
      (entry) => entry.key != _session.userId && entry.value.isInVoiceSession,
    );
  }

  /// Marks the last time voice activity was detected (local or remote) and
  /// reschedules the inactivity timeout check. Called from talk start/stop
  /// and remote-speaker callbacks so the room stays open as long as anyone
  /// is actually talking.
  void _recordVoiceActivity() {
    if (!_isOnline) return;
    _lastVoiceActivityAt = DateTime.now();
    _scheduleInactivityCheck();
  }

  /// Starts or resets a timer that auto-closes the room if nobody speaks for
  /// [PresenceConfig.inactivityTimeout]. Prevents runaway sessions when a
  /// phone is left unattended with an open mic.
  void _scheduleInactivityCheck() {
    _inactivityTimer?.cancel();
    if (!_isOnline) return;
    _inactivityTimer = Timer(PresenceConfig.inactivityTimeout, () {
      if (!mounted || !_isOnline) return;
      final lastActivity = _lastVoiceActivityAt;
      if (lastActivity != null &&
          DateTime.now().difference(lastActivity) <
              PresenceConfig.inactivityTimeout) {
        // Activity happened since we scheduled — reschedule instead.
        _scheduleInactivityCheck();
        return;
      }
      unawaited(_goAway(reason: 'inactivity'));
      _showPresenceSnackbar(
        'Room closed due to inactivity. Send a nudge to go online again.',
      );
    });
  }

  /// Returns today's UTC date key (e.g. "2026-07-23") used to partition
  /// daily usage records in RTDB.
  String get _todayDateKey {
    final now = DateTime.now().toUtc();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  /// Loads the accumulated online seconds for this user in the selected
  /// group for today from RTDB. Called once when going online.
  Future<int> _loadDailyUsage(String groupId) async {
    try {
      final snapshot = await AppDatabase.instance()
          .ref('dailyUsage/$groupId/${_session.userId}/$_todayDateKey')
          .get();
      if (snapshot.exists && snapshot.value is Map<Object?, Object?>) {
        final data = snapshot.value! as Map<Object?, Object?>;
        return (data['onlineSeconds'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {
      // Non-fatal — if we can't read usage, assume 0.
    }
    return 0;
  }

  /// Persists the accumulated online seconds to RTDB for today.
  Future<void> _persistDailyUsage(String groupId) async {
    try {
      await AppDatabase.instance()
          .ref('dailyUsage/$groupId/${_session.userId}/$_todayDateKey')
          .update({
            'onlineSeconds': _todayOnlineSeconds,
            'updatedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          });
    } catch (_) {
      // Best-effort — usage tracking is not critical for the session itself.
    }
  }

  /// Starts a periodic timer that increments the daily usage counter and
  /// persists it to RTDB every 30 seconds while the user is online.
  void _startUsageTracking() {
    _usagePersistTimer?.cancel();
    // Persist immediately when going online.
    final groupId = _onlineSession?.groupId;
    if (groupId != null) {
      unawaited(_persistDailyUsage(groupId));
    }
    _usagePersistTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_isOnline) {
        _usagePersistTimer?.cancel();
        _usagePersistTimer = null;
        return;
      }
      _todayOnlineSeconds += 30;
      final groupId = _onlineSession?.groupId;
      if (groupId != null) {
        unawaited(_persistDailyUsage(groupId));
      }
      // If cap is exceeded mid-session, force offline.
      if (_todayOnlineSeconds >= PresenceConfig.dailyUsageCap.inSeconds) {
        unawaited(_goAway(reason: 'daily_usage_cap'));
        _showPresenceSnackbar(
          'Daily usage limit reached (${PresenceConfig.dailyUsageCap.inMinutes} min). '
          'You can go online again tomorrow.',
        );
      }
    });
  }

  /// Themed Snackbar for presence transitions the user didn't directly
  /// trigger (auto-offline, blocked "go online alone" attempts) — kept
  /// visually consistent with the app's dark glass surfaces rather than
  /// the default Material Snackbar look.
  void _showPresenceSnackbar(String message) {
    _presentSnackbar((messenger) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: const Color(0xff1e1e1e),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14.r),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
            margin: EdgeInsets.fromLTRB(16.w, 0, 16.w, 16.h),
            duration: const Duration(seconds: 4),
            content: Row(
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  color: Colors.white70,
                  size: 18.sp,
                ),
                SizedBox(width: 10.w),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(color: Colors.white, fontSize: 13.sp),
                  ),
                ),
              ],
            ),
          ),
        );
    }, debugLabel: 'presence snackbar message=$message');
  }

  /// True when a SnackBar can actually be presented: the widget is mounted,
  /// the app is foregrounded, and a ScaffoldMessenger is in the tree.
  /// Backgrounded Flutter views unregister Scaffolds, so showSnackBar
  /// asserts `_scaffolds.isNotEmpty` even while `mounted` is still true.
  bool get _canPresentSnackbar {
    if (!mounted) return false;
    if (_appLifecycle != AppLifecycleState.resumed) return false;
    if (_inPictureInPicture) return false;
    return ScaffoldMessenger.maybeOf(context) != null;
  }

  void _presentSnackbar(
    void Function(ScaffoldMessengerState messenger) present, {
    required String debugLabel,
  }) {
    if (!_canPresentSnackbar) return;
    try {
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      present(messenger);
    } catch (error) {
      debugPrint('[OneOneUI] Could not show $debugLabel: $error');
    }
  }

  void _scheduleAvailabilityExpiryRefresh() {
    _availabilityExpiryTimer?.cancel();
    final now =
        DateTime.now().millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond;
    final futureExpiries = _availability.values
        .map((item) => item.staleAfterAt)
        .whereType<int>()
        .where((expiry) => expiry > now);
    if (futureExpiries.isEmpty) {
      // Everyone already stale (or no heartbeats) — still re-evaluate so a
      // lone-member grace timer can start without waiting for another RTDB
      // write.
      if (_onlineSession != null) {
        _evaluatePeerPresenceForAutoOffline(_availability);
      }
      return;
    }

    final nextExpiry = futureExpiries.reduce((a, b) => a < b ? a : b);
    _availabilityExpiryTimer = Timer(
      Duration(seconds: nextExpiry - now + 1),
      () {
        if (!mounted) return;
        setState(() {});
        if (_onlineSession != null) {
          _evaluatePeerPresenceForAutoOffline(_availability);
        }
        _scheduleAvailabilityExpiryRefresh();
      },
    );
  }

  /// Android-only: pushes the current group roster + last-active group to
  /// the native home-screen widget cache so it can render offline without
  /// waking Flutter. Best-effort — failures are logged, never surfaced.
  void _syncDuoWidget() {
    if (!Platform.isAndroid) return;
    unawaited(
      DuoHomeWidgetSync.publish(
        userId: _session.userId,
        apiBaseUrl: AppConfig.apiBaseUrl,
        accentKey: AccentThemeController.accentKey.value,
        lastActiveGroupId: _selectedGroup?.groupId,
        groups: _groups.map((group) {
          final members = _membersByGroupId[group.groupId] ?? const [];
          return DuoWidgetGroupSnapshot(
            groupId: group.groupId,
            name: group.name,
            members: members
                .map(
                  (member) => DuoWidgetMemberSnapshot(
                    userId: member.userId,
                    displayName: member.displayName,
                    photoUrl: member.profilePhotoUrl,
                    online: _availability[member.userId]?.isLive ?? false,
                  ),
                )
                .toList(),
          );
        }).toList(),
      ),
    );
  }

  Future<void> _selectGroup(String groupId) async {
    final group = _groups.firstWhere((item) => item.groupId == groupId);
    final cachedMembers = _membersByGroupId[groupId];
    setState(() {
      _selectedGroup = group;
      _members = cachedMembers ?? const [];
      _availability = {};
      _chatMessages = const [];
    });
    _peerReconnect.clear();
    // Keep native DeviceLog.groupId in sync so FCM can suppress chat piles
    // only for the group currently on screen (not every foreground chat).
    LogManager.setIdentity(groupId: group.groupId);
    unawaited(LastActiveGroupStore.write(_session.userId, group.groupId));
    unawaited(AppTelemetry.setActiveGroup(group.groupId));
    _syncDuoWidget();
    if (cachedMembers == null) {
      await _loadMembers(group.groupId);
    }
    _listenToMembers(group.groupId);
    _listenToAvailability(group.groupId);
    _listenToChatMessages(group.groupId);
    _listenToEmojiBursts(group.groupId);
    _showPipOverlayIfLive();
  }

  Future<void> _onGroupCarouselChanged(int index) async {
    if (index < 0 || index >= _groups.length) return;
    final group = _groups[index];
    setState(() => _carouselIndex = index);

    if (group.groupId == _selectedGroup?.groupId) return;

    await _selectGroup(group.groupId);
  }

  void _syncCarouselToSelectedGroup() {
    final selected = _selectedGroup;
    if (selected == null || _groups.isEmpty) return;
    final index = _groups.indexWhere(
      (group) => group.groupId == selected.groupId,
    );
    if (index < 0) return;

    _carouselIndex = index;
  }

  // C4 decision: creating or joining a group while live keeps the existing
  // session active. The new group is created/joined independently; the user
  // can switch to it from the carousel on the home screen, which goes away
  // from the current group and joins the new one. The in-app PiP overlay
  // (visible on the GroupActionScreen) lets the user return directly to the
  // home/live screen without losing context.
  void _openCreateGroup() {
    _openGroupAction(GroupActionMode.createGroup);
  }

  void _openJoinGroup() {
    _openGroupAction(GroupActionMode.joinByPin);
  }

  void _openGroupAction(GroupActionMode mode) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (context, animation, secondaryAnimation) {
          return GroupActionScreen(
            mode: mode,
            session: _session,
            identityRepository: widget.identityRepository,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final offset =
              Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              );
          return SlideTransition(position: offset, child: child);
        },
      ),
    );
  }

  Future<void> _createInvite() async {
    final group = _selectedGroup;
    if (group == null) return;
    await _createInviteForGroup(group);
  }

  Future<void> _createInviteForGroup(GroupSummary group) async {
    await _runBusy(() async {
      final invite = await _groupRepository.createInvite(group.groupId);
      if (!mounted) return;
      setState(() => _message = 'Invite created');
      await _showShareInviteSheet(invite);
    });
  }

  Future<void> _showShareInviteSheet(GroupInviteResult invite) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff141414),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24.r)),
      ),
      builder: (context) {
        return BottomSystemSafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(24.w, 20.h, 24.w, 24.h),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Invite friends',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18.sp,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 8.h),
                Text(
                  'Share this link. Your friend will open Duo and join this group automatically.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 14.sp),
                ),
                SizedBox(height: 20.h),
                Material(
                  color: const Color(0xff1f1f1f),
                  borderRadius: BorderRadius.circular(18.r),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18.r),
                    onTap: () async {
                      try {
                        await InviteLinkBridge().shareInviteLink(
                          invite.inviteUrl,
                        );
                      } catch (_) {
                        await Clipboard.setData(
                          ClipboardData(text: invite.inviteUrl),
                        );
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Invite link copied')),
                        );
                      }
                    },
                    child: Container(
                      width: double.infinity,
                      padding: EdgeInsets.symmetric(
                        horizontal: 20.w,
                        vertical: 18.h,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18.r),
                        border: Border.all(
                          color: const Color.fromRGBO(255, 255, 255, 0.12),
                        ),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.ios_share_rounded,
                                color: Colors.white,
                                size: 22.sp,
                              ),
                              SizedBox(width: 10.w),
                              Text(
                                'Share invite link',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16.sp,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 8.h),
                          Text(
                            invite.inviteUrl,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11.sp,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SizedBox(height: 14.h),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: invite.inviteCode),
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Fallback PIN copied')),
                    );
                  },
                  icon: Icon(Icons.copy_rounded, size: 17.sp),
                  label: Text('Copy PIN ${invite.inviteCode}'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _togglePresence() {
    if (_busy) return;
    if (!_serviceReady) {
      setState(() => _message = 'Invite a friend to enable voice service.');
      return;
    }
    if (_isViewingActiveGroup) {
      _showPresenceSnackbar(
        'You\'re going offline. Tap again when someone is live to rejoin without a nudge.',
      );
      unawaited(_goAway());
      return;
    }
    // Already live in another group — nudge this one instead of auto-switching.
    // Switching voice rooms only happens after an explicit accept/connect.
    if (_isOnline) {
      _openNudges();
      return;
    }
    // If someone else is already online in this group, let the user join
    // directly — no nudge required since the room is already active.
    if (_anyPeerOnline) {
      unawaited(_goOnline(userIntent: true));
      return;
    }
    // Nobody is online yet — the room doesn't exist. Prompt the user to
    // send a nudge so at least two people go online together.
    _showPresenceSnackbar(
      'Send a nudge to go online together — or tap when someone else is already live.',
    );
  }

  /// True when at least one other group member is actively online.
  bool get _anyPeerOnline {
    return _availability.entries.any(
      (entry) => entry.key != _session.userId && entry.value.isLive,
    );
  }

  Future<void> _goOnline({bool userIntent = false}) async {
    if (!userIntent && !_explicitJoinIntent) {
      LogManager.log(
        LogLevel.warn,
        'LiveKitManager',
        'Blocked room connect without explicit join intent',
        userId: _session.userId,
        groupId: _selectedGroup?.groupId,
      );
      return;
    }
    // Must be sync (not just `_busy` from a later setState) — accept FCM and
    // native pending-connect can both enter here within the same event loop
    // turn and otherwise each write a new session (live → connecting → live).
    if (_goOnlineInFlight || _busy) {
      LogManager.log(
        LogLevel.info,
        'PresenceRing',
        'goOnline skipped — already in flight '
            '(inFlight=$_goOnlineInFlight busy=$_busy isOnline=$_isOnline)',
        userId: _session.userId,
        groupId: _selectedGroup?.groupId,
      );
      return;
    }
    _explicitJoinIntent = true;
    // Going online resets the nudge-origin marker; the nudge path re-asserts
    // it after a successful connect so manual joins are never mislabeled.
    _enteredViaNudge = false;
    final group = _selectedGroup;
    if (group == null) {
      _explicitJoinIntent = false;
      setState(() => _message = 'Create or join a group first.');
      return;
    }
    if (_isOnline) {
      if (!_isViewingActiveGroup) await _switchVoiceGroup();
      return;
    }
    if (!_serviceReady) {
      _explicitJoinIntent = false;
      setState(() => _message = 'Invite a friend to enable voice service.');
      return;
    }

    _goOnlineInFlight = true;
    setState(() {
      _busy = true;
      _state = 'connecting';
      _message = null;
    });

    // Check daily usage cap before allowing the session to start.
    final dateKey = _todayDateKey;
    if (_todayUsageDateKey != dateKey) {
      _todayUsageDateKey = dateKey;
      _todayOnlineSeconds = 0;
    }
    final loadedSeconds = await _loadDailyUsage(group.groupId);
    if (loadedSeconds > _todayOnlineSeconds) {
      _todayOnlineSeconds = loadedSeconds;
    }
    if (_todayOnlineSeconds >= PresenceConfig.dailyUsageCap.inSeconds) {
      _explicitJoinIntent = false;
      _goOnlineInFlight = false;
      if (!mounted) return;
      unawaited(
        AnalyticsService.logDailyUsageCapReached(groupId: group.groupId),
      );
      setState(() {
        _busy = false;
        _state = 'away';
        _message =
            'Daily usage limit reached (${PresenceConfig.dailyUsageCap.inMinutes} min). '
            'You can go online again tomorrow.';
      });
      return;
    }

    // If peers are already connected to each other in call mode, join
    // directly into call mode with them rather than defaulting to
    // walkie-talkie — this is only ever the starting point, though: the
    // user can still tap the call-mode button to switch back at any time.
    final startInCallMode = _availability.entries.any(
      (entry) =>
          entry.key != _session.userId &&
          entry.value.isLive &&
          entry.value.isCallMode,
    );
    final startingConnectionMode = startInCallMode
        ? MemberAvailability.callMode
        : MemberAvailability.walkieTalkieMode;

    OnlineSession? createdSession;
    // E1: live sessions always warm/connect on speaker regardless of settings.
    const speakerOn = true;
    final preparedToken = LiveKitConnectionWarmer.instance.takeToken(
      group.groupId,
    );
    final preparedRoom = LiveKitConnectionWarmer.instance.takeWarmRoom(
      speakerOn: speakerOn,
    );
    try {
      createdSession = await _onlineRepository.goOnline(
        identity: _session,
        group: group,
        connectionMode: startingConnectionMode,
        preparedToken: preparedToken,
      );
      unawaited(ActiveOnlineSessionStore.save(createdSession));
      await _connectLiveKit(createdSession, preparedRoom: preparedRoom);
      if (startInCallMode) {
        await _setMicrophoneEnabled(true);
      }
      await _onlineRepository.markLive(createdSession);
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        final activeSession = _onlineSession;
        if (activeSession != null) {
          unawaited(
            _onlineRepository.heartbeat(
              activeSession,
              isTalking: _talkSession != null,
            ),
          );
        }
      });

      if (!mounted) return;
      setState(() {
        _onlineSession = createdSession;
        _connectionMode = startingConnectionMode;
        _microphoneMutedByUser = false;
        _state = 'live';
        _message = LiveKitStatus.live;
      });
      _syncDuoWidget();
      // Ensure remote emoji bursts reattach after going live (bootstrap may
      // have left a dead stream after a prior permission blip).
      _listenToEmojiBursts(group.groupId);
      _syncPipSessionState();
      unawaited(TalkFeedback.joined());
      if (startInCallMode) {
        _scheduleCallModeTimeout();
      } else {
        _cancelCallModeTimeout();
      }
      _scheduleInactivityCheck();
      _startUsageTracking();
      unawaited(
        AnalyticsService.logGoOnline(
          groupId: group.groupId,
          connectionMode: startingConnectionMode,
          joinedCallMode: startInCallMode,
        ),
      );
      unawaited(
        CrashlyticsService.log(
          'go_online group=${group.groupId} mode=$startingConnectionMode',
        ),
      );
    } catch (error, stack) {
      unawaited(
        CrashlyticsService.recordNudgeFailure(
          error: error,
          stack: stack,
          failureReason: NudgeFailureReason.livekitSessionFailed,
          receiverId: _session.userId,
          groupId: group.groupId,
          livekitRoomState: _room?.connectionState.toString(),
          extras: {
            'feature': 'presence',
            'connection_mode': startingConnectionMode,
          },
        ),
      );
      // If a warm room was taken but connect never claimed it (e.g. the
      // permission check threw before connect), release it now.
      if (preparedRoom != null && _room != preparedRoom) {
        unawaited(preparedRoom.dispose());
      }
      await _disconnectLiveKit();
      _explicitJoinIntent = false;
      if (createdSession != null) {
        try {
          await _onlineRepository.goAway(createdSession);
        } catch (_) {
          // Best-effort cleanup after a failed connect.
        }
        unawaited(ActiveOnlineSessionStore.clear());
      }
      if (!mounted) return;
      setState(() {
        _state = 'away';
        _message = LiveKitStatus.sanitizeError(error);
      });
    } finally {
      _goOnlineInFlight = false;
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _switchVoiceGroup() async {
    final previousSession = _onlineSession;
    final nextGroup = _selectedGroup;
    if (previousSession == null || nextGroup == null) return;
    if (previousSession.groupId == nextGroup.groupId) return;

    final previousName = _groups
        .where((group) => group.groupId == previousSession.groupId)
        .map((group) => group.name)
        .firstOrNull;
    await _goAway();
    if (!mounted || _onlineSession != null) return;
    await _goOnline(userIntent: true);
    if (!mounted || _onlineSession?.groupId != nextGroup.groupId) return;
    _showPresenceSnackbar(
      'You joined ${nextGroup.name}. '
      'Connection with ${previousName ?? 'the previous group'} has ended.',
    );
  }

  Future<void> _goAway({String reason = 'user_away'}) async {
    _explicitJoinIntent = false;
    _deferredNudgeAction = null;
    _liveSessionActiveOnBackground = false;
    final session = _onlineSession;
    if (session == null) {
      setState(() => _state = 'away');
      _syncPipSessionState();
      return;
    }

    setState(() => _state = 'connecting');
    await _runBusy(() async {
      final activeTalk = _talkSession;
      if (activeTalk != null) {
        await _talkRepository.stopTalk(activeTalk, reason: 'going_away');
      }
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      _peerDisconnectGraceTimer?.cancel();
      _peerDisconnectGraceTimer = null;
      _inactivityTimer?.cancel();
      _inactivityTimer = null;
      _lastVoiceActivityAt = null;
      _callModeTimeoutTimer?.cancel();
      _callModeTimeoutTimer = null;
      _usagePersistTimer?.cancel();
      _usagePersistTimer = null;
      // Persist final usage when going away.
      final groupId = session.groupId;
      if (_todayOnlineSeconds > 0) {
        unawaited(_persistDailyUsage(groupId));
      }
      _peerWasLiveWithMe = false;
      _enteredViaNudge = false;
      await _disconnectLiveKit();
      await _onlineRepository.goAway(session, reason: reason);
      unawaited(ActiveOnlineSessionStore.clear());
      unawaited(
        AnalyticsService.logGoAway(groupId: session.groupId, reason: reason),
      );
      unawaited(CrashlyticsService.log('go_away reason=$reason'));
      if (_shouldNotifyGoneOffline(reason)) {
        unawaited(
          _onlineRepository.notifyGoneOffline(session: session, reason: reason),
        );
      }
      if (!mounted) return;
      setState(() {
        _onlineSession = null;
        _talkSession = null;
        _speakingUserIds = const {};
        _state = 'away';
        _connectionMode = MemberAvailability.walkieTalkieMode;
        _message = LiveKitStatus.away;
      });
      _syncDuoWidget();
      _syncPipSessionState();
    });
  }

  /// True for leaves the user did not explicitly request — peer left after a
  /// nudge/elsewhere leave, inactivity, or daily cap. Manual toggle and group
  /// switches stay silent.
  bool _shouldNotifyGoneOffline(String reason) {
    return reason == 'peer_left' ||
        reason == 'inactivity' ||
        reason == 'daily_usage_cap' ||
        reason == 'network_loss';
  }

  Future<void> _startTalking() async {
    final session = _onlineSession;
    if (session == null ||
        !_isViewingActiveGroup ||
        _talkSession != null ||
        _talkBusy) {
      return;
    }

    _talkPressed = true;
    setState(() {
      _talkBusy = true;
      _message = null;
    });

    TalkSession? startedTalk;
    try {
      startedTalk = await _talkRepository.startTalk(session);
      if (!_talkPressed) {
        await _talkRepository.stopTalk(startedTalk, reason: 'released_early');
        await _setMicrophoneEnabled(false);
        if (!mounted) return;
        setState(() {
          _talkSession = null;
          _state = 'live';
        });
        return;
      }

      await _setMicrophoneEnabled(true);
      unawaited(
        TalkFeedback.talkStarted(
          hapticsEnabled: _session.settings.hapticsEnabled,
        ),
      );
      if (!mounted) return;

      if (!_talkPressed) {
        await _setMicrophoneEnabled(false);
        await _talkRepository.stopTalk(startedTalk, reason: 'released_early');
        setState(() {
          _talkSession = null;
          _state = 'live';
        });
        return;
      }

      setState(() {
        _talkSession = startedTalk;
        _state = 'talking';
        _message = LiveKitStatus.talking;
      });
      _syncPipSessionState();
      _recordVoiceActivity();
      unawaited(AnalyticsService.logTalkStart(groupId: session.groupId));
    } catch (error, stack) {
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'talk_start_mic_failed',
          feature: 'talk',
        ),
      );
      if (startedTalk != null) {
        await _talkRepository.stopTalk(startedTalk, reason: 'mic_failed');
      }
      if (!mounted) return;
      setState(() {
        _talkSession = null;
        _state = _onlineSession == null ? 'away' : 'live';
        _message = LiveKitStatus.sanitizeError(error);
      });
      _syncPipSessionState();
    } finally {
      if (mounted) {
        setState(() => _talkBusy = false);
      }
    }
  }

  Future<void> _stopTalking({String reason = 'released'}) async {
    _talkPressed = false;
    final talkSession = _talkSession;
    if (talkSession == null) return;

    setState(() {
      _talkSession = null;
      _state = 'live';
      _message = LiveKitStatus.live;
    });
    _syncPipSessionState();

    _recordVoiceActivity();

    Object? stopError;
    try {
      await _setMicrophoneEnabled(false);
      if (mounted) _updatePipOverlay();
    } catch (error) {
      stopError = error;
    }

    try {
      unawaited(
        TalkFeedback.talkStopped(
          hapticsEnabled: _session.settings.hapticsEnabled,
        ),
      );
      await _talkRepository.stopTalk(talkSession, reason: reason);
      unawaited(
        AnalyticsService.logTalkStop(
          groupId: talkSession.groupId,
          reason: reason,
        ),
      );
    } catch (error) {
      stopError ??= error;
    }

    if (stopError != null) {
      if (!mounted) return;
      setState(() => _message = 'Couldn’t stop talking. Try again.');
    }
  }

  /// Toggles the local user's own connection between walkie-talkie
  /// (push-to-talk) and call (always-on mic). Purely per-user: it never
  /// touches anyone else's connection or availability.
  Future<void> _toggleConnectionMode() async {
    final session = _onlineSession;
    if (session == null ||
        _connectionModeBusy ||
        !_isViewingActiveGroup ||
        _busy) {
      return;
    }

    final switchingToCallMode = !_isCallMode;
    final nextMode = switchingToCallMode
        ? MemberAvailability.callMode
        : MemberAvailability.walkieTalkieMode;

    setState(() => _connectionModeBusy = true);
    try {
      // Switching modes mid-press shouldn't leave a dangling talk lock.
      final activeTalk = _talkSession;
      if (activeTalk != null) {
        await _stopTalking(reason: 'connection_mode_changed');
      }

      await _setMicrophoneEnabled(switchingToCallMode);
      await _onlineRepository.setConnectionMode(
        session,
        connectionMode: nextMode,
      );

      if (!mounted) return;
      setState(() {
        _connectionMode = nextMode;
        _microphoneMutedByUser = false;
      });
      if (switchingToCallMode) {
        _scheduleCallModeTimeout();
      } else {
        _cancelCallModeTimeout();
      }
      _syncPipSessionState();
      // A mode change (call ↔ walkie-talkie) is a LiveKit state signal; give
      // the solo-participant countdown a fresh start off the latest state.
      _soloGuard?.refreshCountdown();
      unawaited(
        AnalyticsService.logConnectionModeChanged(
          groupId: session.groupId,
          mode: nextMode,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = 'Couldn\u2019t switch connection mode.');
    } finally {
      if (mounted) setState(() => _connectionModeBusy = false);
    }
  }

  /// Starts (or restarts) the continuous call-mode cap. Fires
  /// [_exitCallModeDueToTimeout] after [PresenceConfig.callModeTimeout].
  void _scheduleCallModeTimeout() {
    _callModeTimeoutTimer?.cancel();
    unawaited(VoiceOverlayBridge.warmup());
    _callModeTimeoutTimer = Timer(PresenceConfig.callModeTimeout, () {
      _callModeTimeoutTimer = null;
      unawaited(_exitCallModeDueToTimeout());
    });
  }

  void _cancelCallModeTimeout() {
    _callModeTimeoutTimer?.cancel();
    _callModeTimeoutTimer = null;
  }

  /// Auto-switches the local user back to walkie-talkie after the continuous
  /// call-mode cap. Keeps them connected to the group — only their mode and
  /// mic change. Other participants are not notified.
  Future<void> _exitCallModeDueToTimeout() async {
    final session = _onlineSession;
    if (session == null || !_isCallMode || _connectionModeBusy) return;

    setState(() => _connectionModeBusy = true);
    try {
      // Concurrent with the mic/mode cutover so the switch is not delayed
      // by TTS. Native side no-ops when media volume is muted.
      unawaited(VoiceOverlayBridge.announceCallModeTimeout());
      await _setMicrophoneEnabled(false);
      await _onlineRepository.setConnectionMode(
        session,
        connectionMode: MemberAvailability.walkieTalkieMode,
      );
      if (!mounted) return;
      setState(() => _connectionMode = MemberAvailability.walkieTalkieMode);
      _cancelCallModeTimeout();
      _syncPipSessionState();
      // Auto-exiting call mode flips the mic off (a LiveKit state signal).
      // Re-base the solo-participant countdown for any remaining participant.
      _soloGuard?.refreshCountdown();
      _showCallModeTimeoutSnackbar();
    } catch (_) {
      // Best-effort; leave local state as-is if the write fails so the user
      // can still toggle manually.
      if (!mounted) return;
      setState(() => _message = 'Couldn\u2019t leave call mode automatically.');
    } finally {
      if (mounted) setState(() => _connectionModeBusy = false);
    }
  }

  void _showCallModeTimeoutSnackbar() {
    _presentSnackbar((messenger) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: const Color(0xff1e1e1e),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14.r),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
            margin: EdgeInsets.fromLTRB(16.w, 0, 16.w, 16.h),
            duration: const Duration(seconds: 8),
            content: Row(
              children: [
                Icon(
                  Icons.timer_off_outlined,
                  color: Colors.white70,
                  size: 18.sp,
                ),
                SizedBox(width: 10.w),
                Expanded(
                  child: Text(
                    'Switched back to walkie-talkie after '
                    '${PresenceConfig.callModeTimeout.inMinutes} min in call mode.',
                    style: TextStyle(color: Colors.white, fontSize: 13.sp),
                  ),
                ),
              ],
            ),
            action: SnackBarAction(
              label: 'Call mode',
              textColor: const Color(0xfffff1a8),
              onPressed: () {
                if (!_isCallMode) unawaited(_toggleConnectionMode());
              },
            ),
          ),
        );
    }, debugLabel: 'call-mode timeout snackbar');
  }

  Future<void> _connectLiveKit(
    OnlineSession session, {
    Room? preparedRoom,
  }) async {
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

  /// Toggles the actual LiveKit microphone. Walkie mode reuses the existing
  /// talk lock; call mode mutes/unmutes the published microphone track.
  Future<void> _toggleMicrophone() async {
    if (_audioMuteBusy) return;
    if (!_isCallMode) {
      if (_talkSession != null || _microphoneEnabled) {
        await _stopTalking(reason: 'microphone_toggle');
      } else {
        await _startTalking();
      }
      return;
    }

    _audioMuteBusy = true;
    final enable = !_microphoneEnabled;
    try {
      await _setMicrophoneEnabled(enable);
      if (!mounted) return;
      _microphoneMutedByUser = !enable;
      setState(() {});
      _updatePipOverlay();
      _showPresenceSnackbar(enable ? 'Microphone on' : 'Microphone muted');
    } catch (error, stack) {
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'microphone_toggle_failed',
        ),
      );
      if (!mounted) return;
      setState(() {});
      _showPresenceSnackbar(LiveKitStatus.sanitizeError(error));
    } finally {
      _audioMuteBusy = false;
    }
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

  Future<void> _handleRemoteSpeakerStarted() async {
    await TalkFeedback.remoteSpeakerStarted(
      hapticsEnabled: _liveHapticsEnabled,
    );
    // Do NOT reassert audio route here — routing is user-driven only (E1).
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
            final previousRemoteSpeakers = _speakingUserIds.where(
              (id) => id != _session.userId,
            );
            final speaking = <String>{};
            for (final speaker in event.speakers) {
              final userId =
                  LiveKitStatus.userIdFromIdentity(speaker.identity) ??
                  _participantUserIdFromIdentity(speaker.identity);
              if (userId != null) speaking.add(userId);
            }
            if (!mounted) return;
            final newlySpeakingRemote = speaking
                .where((id) => id != _session.userId)
                .any((id) => !previousRemoteSpeakers.contains(id));
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
            if (newlySpeakingRemote && _talkSession != null) {
              unawaited(_handleRemoteSpeakerStarted());
            }
            // E1: never reassert speaker/earpiece from active-speaker events —
            // routing changes only on explicit user action (or headphones).
            setState(() {
              _speakingUserIds = speaking;
              final remoteSpeaking = speaking.any(
                (id) => id != _session.userId,
              );
              if (remoteSpeaking && _talkSession == null) {
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
    // In call mode the mic should be on; in walkie-talkie, it stays off
    // until the user presses talk.
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
        'talking=${_talkSession != null}',
      );
    } catch (error) {
      debugPrint(
        '[LiveKit] WARNING: Failed to restore microphone after reconnection: '
        '$error',
      );
    }
  }

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
        _talkPressed = false;
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

  Future<void> _runBusy(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = LiveKitStatus.sanitizeError(error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
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

  List<GroupSummary> get _ownedGroups => _groups
      .where((group) => group.ownerUserId == _session.userId)
      .toList(growable: false);

  Future<bool> _openGroupManagement(GroupSummary group) async {
    // Only group creators can manage; ignore anything that slipped past UI.
    if (group.ownerUserId != _session.userId) return false;

    final initialMembers = group.groupId == _selectedGroup?.groupId
        ? _members
        : await _groupRepository.loadGroupMembers(group.groupId);
    if (!mounted) return false;

    final outcome = await Navigator.of(context).push<GroupManagementOutcome>(
      MaterialPageRoute<GroupManagementOutcome>(
        builder: (_) => GroupManagementScreen(
          group: group,
          currentUserId: _session.userId,
          initialMembers: initialMembers,
          onInvite: () => _createInviteForGroup(group),
        ),
      ),
    );
    if (outcome == null || !mounted) return false;

    await _endRevokedVoiceSession(group.groupId);
    if (!mounted) return true;
    await _loadGroups();
    if (mounted) {
      setState(() {
        _message = outcome == GroupManagementOutcome.groupDeleted
            ? '${group.name} was deleted.'
            : 'You left ${group.name}.';
      });
    }
    return true;
  }

  void _openSettings() {
    final ownedGroups = _ownedGroups;
    unawaited(
      SettingsScreen.open(
        context,
        session: _session,
        identityRepository: widget.identityRepository,
        manageableGroups: ownedGroups,
        onManageGroup: ownedGroups.isEmpty ? null : _openGroupManagement,
      ),
    );
  }

  void _openNudges() {
    if (_incomingPromptNudge != null) return;
    final group = _selectedGroup;
    if (group == null) return;
    if (_session.settings.hapticsEnabled) {
      unawaited(HapticFeedback.selectionClick());
    }
    // Sender-side warm: prefetch this device's LiveKit token now so that if
    // the nudge is accepted and both sides go online, joining is instant.
    unawaited(_prefetchLiveKit(group: group));
    final onlineUserIds = <String>{
      for (final entry in _availability.entries)
        if (entry.value.isLive || entry.value.isInVoiceSession) entry.key,
      if (_isOnline) _session.userId,
    };
    unawaited(
      showNudgeBottomSheet(
        context,
        group: group,
        currentUserId: _session.userId,
        members: _displayMembers,
        accent: accentColorForKey(_session.settings.accentColorKey),
        onlineUserIds: onlineUserIds,
        // LiveKit holds the hardware mic while unmuted / PTT — voice nudge
        // recording cannot share it. Caller must mute first.
        isLiveMicrophoneInUse: () =>
            _isOnline && (_microphoneEnabled || _talkSession != null),
      ),
    );
  }

  void _openSetupWarnings() {
    final warnings = _setupWarnings();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return BottomSystemSafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              Text('Setup', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              if (warnings.isEmpty)
                const _SetupLine(
                  ok: true,
                  text: 'Ready for foreground and closed-app voice',
                )
              else
                for (final warning in warnings)
                  _TappableSetupLine(
                    ok: false,
                    text: warning.text,
                    accent: warning.accent,
                    onTap: warning.onTap,
                  ),
            ],
          ),
        );
      },
    );
  }

  List<_SetupWarning> _setupWarnings() {
    final warnings = <_SetupWarning>[];
    final accent = accentColorForKey(_session.settings.accentColorKey);
    if (_groups.isEmpty) {
      warnings.add(
        _SetupWarning(text: 'Create or join a group.', accent: accent),
      );
    }
    if (!_session.device.micPermissionGranted && _onlineSession == null) {
      warnings.add(
        _SetupWarning(
          text: 'Microphone permission has not been confirmed.',
          accent: accent,
          onTap: () => _requestMicPermissionFromSetup(),
        ),
      );
    }
    if (!_session.device.notificationPermissionGranted) {
      warnings.add(
        _SetupWarning(
          text: 'Notification permission is required for closed-app nudges.',
          accent: accent,
          onTap: () => _requestNotificationPermissionFromSetup(),
        ),
      );
    }
    if (_session.device.fcmToken == null) {
      warnings.add(
        _SetupWarning(
          text: 'Push registration is not ready. Reopen the app while online.',
          accent: accent,
          onTap: null, // Needs app restart — informational only.
        ),
      );
    }
    if (!_session.device.batteryOptimizationIgnored) {
      warnings.add(
        _SetupWarning(
          text: 'Battery optimization may interrupt background mode.',
          accent: accent,
          onTap: () => _requestBatteryOptimizationFromSetup(),
        ),
      );
    }
    return warnings;
  }

  Future<void> _requestMicPermissionFromSetup() async {
    final status = await Permission.microphone.request();
    if (!mounted) return;
    if (status.isGranted) {
      setState(() => _message = 'Microphone permission granted.');
    } else {
      setState(() => _message = 'Microphone permission was denied.');
    }
  }

  Future<void> _requestNotificationPermissionFromSetup() async {
    final status = await Permission.notification.request();
    if (!mounted) return;
    if (status.isGranted) {
      setState(() => _message = 'Notification permission granted.');
    } else {
      setState(() => _message = 'Notification permission was denied.');
    }
  }

  Future<void> _requestBatteryOptimizationFromSetup() async {
    try {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    } catch (_) {
      // Best effort — the user can set this from Android Settings.
    }
    if (!mounted) return;
    setState(
      () => _message =
          'Battery optimization request sent. Check your device settings.',
    );
  }

  bool get _isOnline => _onlineSession != null;

  bool get _microphoneEnabled =>
      _room?.localParticipant?.isMicrophoneEnabled() ?? false;

  /// LiveKit join, reconnect, or leave is in flight — the main button must
  /// show a loader instead of an empty middle state between online/offline.
  bool get _isSessionConnecting =>
      _nudgeActionInFlight ||
      _state == 'connecting' ||
      _state == 'reconnecting';

  bool get _isViewingActiveGroup =>
      _onlineSession?.groupId == _selectedGroup?.groupId;
  bool get _isCallMode => _connectionMode == MemberAvailability.callMode;

  bool get _serviceReady =>
      groupHasServicePeer(members: _members, currentUserId: _session.userId);

  List<GroupMemberSummary> get _friends {
    return _members
        .where((member) => member.userId != _session.userId)
        .toList(growable: false);
  }

  List<GroupMemberSummary> get _displayMembers {
    return _displayMembersFrom(_members);
  }

  GroupMemberSummary get _pictureInPictureMember {
    final activeUserId = _speakingUserIds.firstOrNull ?? _session.userId;
    final activeMembers = _displayMembersFrom(
      _membersByGroupId[_onlineSession?.groupId] ?? const [],
    );
    for (final member in activeMembers) {
      if (member.userId == activeUserId) return member;
    }
    return GroupMemberSummary(
      userId: _session.userId,
      displayName: _session.user.displayName,
      role: 'member',
      memberState: 'active',
      profilePhotoUrl: _session.user.profilePhotoUrl,
      profilePhotoBase64: _session.user.profilePhotoBase64,
      avatarAsset: _session.user.avatarAsset,
    );
  }

  GroupMemberSummary get _localLiveMember => GroupMemberSummary(
    userId: _session.userId,
    displayName: _session.user.displayName,
    role: 'member',
    memberState: 'active',
    profilePhotoUrl: _session.user.profilePhotoUrl,
    profilePhotoBase64: _session.user.profilePhotoBase64,
    avatarAsset: _session.user.avatarAsset,
  );

  String get _activeLiveGroupName =>
      _groups
          .where((group) => group.groupId == _onlineSession?.groupId)
          .firstOrNull
          ?.name ??
      'Live conversation';

  List<GroupMemberSummary> _displayMembersFrom(
    List<GroupMemberSummary> members,
  ) {
    return members
        .map((member) {
          if (member.userId != _session.userId) return member;
          return GroupMemberSummary(
            userId: member.userId,
            displayName: _session.user.displayName,
            role: member.role,
            memberState: member.memberState,
            profilePhotoUrl: _session.user.profilePhotoUrl,
            profilePhotoBase64: _session.user.profilePhotoBase64,
            avatarAsset: _session.user.avatarAsset,
          );
        })
        .toList(growable: false);
  }

  ConnectionQuality get _effectiveLocalConnectionQuality {
    if (_connectivity.contains(ConnectivityResult.none)) {
      return ConnectionQuality.lost;
    }
    if (_localConnectionQuality != ConnectionQuality.unknown) {
      return _localConnectionQuality;
    }
    return _connectivity.isEmpty
        ? ConnectionQuality.unknown
        : ConnectionQuality.good;
  }

  List<_CarouselItem> get _carouselItems {
    final selfIsLive = _isOnline && (_state == 'live' || _state == 'talking');
    final selfAvailability = _isOnline
        ? MemberAvailability(
            desiredState: 'online',
            effectiveState: _state,
            canReceiveLiveAudio: selfIsLive,
          )
        : MemberAvailability.away;

    return [
      for (final group in _groups)
        _CarouselItem.group(
          group: group,
          displayName: _session.user.displayName,
          profilePhotoUrl: _session.user.profilePhotoUrl,
          profilePhotoBase64: _session.user.profilePhotoBase64,
          avatarAsset: _session.user.avatarAsset,
          availability: group.groupId == _onlineSession?.groupId
              ? selfAvailability
              : MemberAvailability.away,
          members: _displayMembersFrom(
            _membersByGroupId[group.groupId] ?? const [],
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final accent = accentColorForKey(_session.settings.accentColorKey);
    // Android reports PiP exit before the window has finished expanding.
    // Keep the compact constraint-safe view during those intermediate frames.
    if (_inPictureInPicture || MediaQuery.sizeOf(context).height < 480) {
      final member = _pictureInPictureMember;
      return _VoicePictureInPictureView(
        key: ValueKey(member.userId),
        member: member,
        speaking:
            _speakingUserIds.contains(member.userId) ||
            (_talkSession != null && member.userId == _session.userId),
        talking: _talkSession != null,
        accent: accent,
      );
    }
    final warnings = _setupWarnings();
    final items = _carouselItems;
    final focusedGroup = _selectedGroup;
    final activeGroup = _groups
        .where((group) => group.groupId == _onlineSession?.groupId)
        .firstOrNull;
    final viewingActiveGroup = _isViewingActiveGroup;
    // Local session is the source of truth — remote availability can lag after goAway.
    final live = _isOnline && (_state == 'live' || _state == 'talking');
    final inviteAction = _busy || focusedGroup == null
        ? null
        : () => unawaited(_createInvite());

    // Tri-state for the focused group's control cluster: whether nobody, some,
    // or everybody (self included) is currently online. Drives whether the
    // main button becomes a nudge trigger, whether the nudge bell shows, and
    // whether the call-mode controls render at all.
    final friends = _friends;
    final anyFriendOnline = friends.any(
      (friend) =>
          (_availability[friend.userId] ?? MemberAvailability.away).isLive,
    );
    final allFriendsOnline =
        friends.isNotEmpty &&
        friends.every(
          (friend) =>
              (_availability[friend.userId] ?? MemberAvailability.away).isLive,
        );
    final groupAllOffline = !live && !anyFriendOnline;
    final groupAllOnline = live && allFriendsOnline;
    final groupMixed = !groupAllOffline && !groupAllOnline;
    final anyMemberOnline = live || anyFriendOnline;
    final showGoLive = !_isOnline && anyFriendOnline;
    final liveAvailability = <String, MemberAvailability>{
      for (final friend in friends)
        friend.userId: (_availability[friend.userId] ?? MemberAvailability.away)
                .isLive
            ? MemberAvailability(
                desiredState: 'online',
                effectiveState: _speakingUserIds.contains(friend.userId)
                    ? 'talking'
                    : 'live',
                canReceiveLiveAudio: true,
                connectionMode:
                    _availability[friend.userId]?.connectionMode ??
                    MemberAvailability.walkieTalkieMode,
              )
            : (_availability[friend.userId] ?? MemberAvailability.away),
    };
    // Live nav-bar / home-indicator inset (gesture pill vs 3-button). Uses
    // viewPadding as a fallback because modal routes and Android
    // edge-to-edge often report padding.bottom as 0. Captured here, before
    // the inner SafeArea, so the pinned messages bar / main button row
    // can sit above the system nav without touching the top inset.
    final bottomSystemInset = bottomSystemInsetOf(context);

    // When the chat keyboard is open, temporarily collapse and fade the
    // status-hint notifier and the join/create carousel row so the message
    // feed has more space above the keyboard. The group name + participants
    // strip stays visible.
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 100;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _HomeBackdrop(
            members: _displayMembers,
            fallbackPhotoUrl: _session.user.profilePhotoUrl,
            fallbackPhotoBase64: _session.user.profilePhotoBase64,
            fallbackAvatarAsset: _session.user.avatarAsset,
            accent: accent,
          ),
          // `bottom: false` here because bottom clearance for the pinned
          // controls at the end of the column is now applied explicitly
          // (see `bottomSystemInset` below) so 3-button-nav devices get
          // real extra space instead of a single fixed gap that assumes a
          // gesture-nav-sized inset.
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                _TopChrome(
                  onSettings: _openSettings,
                  onSetup: _openSetupWarnings,
                  hasSetupWarnings: warnings.isNotEmpty,
                  busy: _busy,
                  online: live,
                  enabled: _serviceReady,
                  onTogglePresence: _togglePresence,
                  showAudioOutput: _isOnline,
                  speakerOn: _callAudio.speakerOn,
                  audioRoute: _audioRoute,
                  audioMuted: _audioMuted,
                  onToggleAudioOutput: _toggleAudioOutput,
                  onToggleAudioMute: _toggleAudioMute,
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(height: 8.h),
                    _FriendsStrip(
                      groupName: focusedGroup?.name,
                      friends: _friends,
                      availability: liveAvailability,
                      speakingUserIds: _speakingUserIds,
                      connectionQualityByUserId:
                          _remoteConnectionQualityByUserId,
                      nudgeRepliesByUserId: _nudgeRepliesForGroup(
                        focusedGroup?.groupId,
                      ),
                      onInvite: inviteAction,
                    ),
                  ],
                ),
                if (_isOnline &&
                    (_effectiveLocalConnectionQuality ==
                            ConnectionQuality.poor ||
                        _effectiveLocalConnectionQuality ==
                            ConnectionQuality.lost)) ...[
                  SizedBox(height: 8.h),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24.w),
                    child: Text(
                      'Your network connection is a bit low.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: const Color(0xffffb347),
                        fontSize: 12.sp,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                if (_message != null &&
                    !(_isOnline && viewingActiveGroup)) ...[
                  SizedBox(height: 10.h),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24.w),
                    child: Text(
                      UserFacingCopy.sanitize(_message!),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white70, fontSize: 12.sp),
                    ),
                  ),
                ],
                // Middle band: ephemeral bubbles sit here (own=right,
                // others=left). Empty Expanded keeps layout stable so
                // the feed doesn't jump the carousel when it appears.
                // Bottom-align the feed; scroll when the rolling window
                // exceeds available height instead of clipping the top pill.
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16.w, 0, 16.w, 14.h),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return SingleChildScrollView(
                          reverse: true,
                          physics: const ClampingScrollPhysics(),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: constraints.maxHeight,
                            ),
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: ChatBubbleFeed(
                                messages: _chatMessages,
                                currentUserId: _session.userId,
                                displayNameForUserId: _chatDisplayNameForUser,
                                accent: accent,
                                onExpire: _dismissExpiredChatMessage,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                // Status hint: collapsed when keyboard is open so the
                // message feed gets more space above the keyboard.
                if (!(_isOnline &&
                    viewingActiveGroup &&
                    !_isSessionConnecting))
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 180),
                    opacity: keyboardOpen ? 0.0 : 1.0,
                    child: AnimatedAlign(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      heightFactor: keyboardOpen ? 0.0 : 1.0,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(24.w, 0, 24.w, 6.h),
                        child: Text(
                          _isSessionConnecting
                              ? (_state == 'reconnecting'
                                    ? LiveKitStatus.reconnecting
                                    : LiveKitStatus.connecting)
                              : viewingActiveGroup
                              ? (_isCallMode
                                    ? (_microphoneEnabled
                                          ? 'In a call — mic on'
                                          : 'In a call — mic muted')
                                    : 'Tap to Talk')
                              : _isOnline
                              ? 'connected to ${activeGroup?.name ?? 'another group'} • tap to nudge this group'
                              : showGoLive
                              ? 'Someone is live — tap Join? to join'
                              : !_serviceReady
                              ? 'invite a friend to enable voice service'
                              : 'send a nudge to go online together',
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: const Color.fromRGBO(255, 255, 255, 0.55),
                            fontSize: 13.sp,
                            fontWeight: FontWeight.w500,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ),
                  ),
                // Keep nudge secondary on the right while peers are live.
                // With nobody live it remains inside the main button.
                if ((live && (groupMixed || anyMemberOnline)) || showGoLive)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      // Flush to the right edge of the safe area.
                      padding: EdgeInsets.only(right: 0, bottom: 6.h),
                      child: _EdgeQuickActions(
                        showNudge: groupMixed || showGoLive,
                        onNudge: _busy ? null : _openNudges,
                        showModeToggle: live && anyMemberOnline,
                        modeToggleEnabled:
                            viewingActiveGroup && !_connectionModeBusy,
                        callModeActive: _isCallMode,
                        onToggleMode: _toggleConnectionMode,
                      ),
                    ),
                  ),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: keyboardOpen ? 0.0 : 1.0,
                  child: AnimatedAlign(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    heightFactor: keyboardOpen ? 0.0 : 1.0,
                    child: IgnorePointer(
                      ignoring: keyboardOpen,
                      child: SizedBox(
                        height: 160.h,
                        child: _ExperienceCarousel(
                          items: items,
                          index: _carouselIndex,
                          connectedGroupId: _onlineSession?.groupId,
                          connecting: _isSessionConnecting,
                          talkEnabled:
                              viewingActiveGroup &&
                              !_busy &&
                              !_isCallMode &&
                              !_isSessionConnecting,
                          talkActive:
                              _talkSession != null ||
                              (_isCallMode &&
                                  _speakingUserIds.contains(_session.userId)),
                          talkBusy: _talkBusy,
                          callMode: _isCallMode,
                          accent: accent,
                          nudgeGroupId:
                              (groupAllOffline ||
                                  (_isOnline && !viewingActiveGroup))
                              ? focusedGroup?.groupId
                              : null,
                          goLiveGroupId: showGoLive
                              ? focusedGroup?.groupId
                              : null,
                          onNudge: _busy ? null : _openNudges,
                          onSelected: (index) {
                            unawaited(_onGroupCarouselChanged(index));
                          },
                          onTalkStart: _startTalking,
                          onTalkStop: () => _stopTalking(),
                          onJoinVoiceGroup: _togglePresence,
                          onCreateGroup: _openCreateGroup,
                          onJoinGroup: _openJoinGroup,
                        ),
                      ),
                    ),
                  ),
                ),
                if (focusedGroup != null) ...[
                  SizedBox(height: 8.h),
                  ChatBubbleBar(
                    key: const ValueKey('home-chat-bubble-bar'),
                    accent: accent,
                    anyMemberOnline: anyMemberOnline,
                    onSend: _sendChatMessage,
                    onEmojiSelected: _triggerEmojiBurst,
                  ),
                ],
                // Live system inset + a short base gap so the main
                // button row sits near the bottom without crowding
                // the nav area.
                SizedBox(height: 8.h + bottomSystemInset),
              ],
            ),
          ),
          if (_emojiBursts.isNotEmpty)
            EmojiBurstOverlay(
              bursts: _emojiBursts,
              onBurstFinished: _onEmojiBurstFinished,
            ),
          if (_incomingPromptNudge != null)
            IncomingNudgeDialogue(
              item: IncomingNudgePromptItem(
                nudge: _incomingPromptNudge!,
                groupName:
                    _groups
                        .where(
                          (group) =>
                              group.groupId == _incomingPromptNudge!.groupId,
                        )
                        .firstOrNull
                        ?.name ??
                    'Group',
                remainingOtherCount:
                    (_nudgeInbox
                                .presentationQueue()
                                .where(
                                  (nudge) => _groups.any(
                                    (group) => group.groupId == nudge.groupId,
                                  ),
                                )
                                .length -
                            1)
                        .clamp(0, 99),
              ),
              accent: accent,
              busy: _incomingPromptBusy,
              onAccept: () =>
                  unawaited(_acceptIncomingNudge(_incomingPromptNudge!)),
              onDecline: () =>
                  unawaited(_declineIncomingNudge(_incomingPromptNudge!)),
            ),
        ],
      ),
    );
  }
}

class _VoicePictureInPictureView extends StatelessWidget {
  const _VoicePictureInPictureView({
    super.key,
    required this.member,
    required this.speaking,
    required this.talking,
    required this.accent,
  });

  final GroupMemberSummary member;
  final bool speaking;
  final bool talking;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xff101010),
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final shortestSide = constraints.biggest.shortestSide;
            final avatarRadius = (shortestSide * 0.32).clamp(20.0, 68.0);
            return Semantics(
              label:
                  '${member.displayName}, ${speaking ? 'speaking' : 'listening'}, '
                  '${talking ? 'microphone on' : 'microphone muted'}',
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: speaking ? const Color(0xff7CFF6B) : accent,
                          width: speaking ? 3 : 1,
                        ),
                      ),
                      child: ProfileAvatar(
                        profilePhotoUrl: member.profilePhotoUrl,
                        profilePhotoBase64: member.profilePhotoBase64,
                        avatarAsset: member.avatarAsset,
                        radius: avatarRadius,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: talking
                            ? const Color(0xff28A745)
                            : const Color(0xdd202020),
                      ),
                      child: Icon(
                        talking ? Icons.mic_rounded : Icons.mic_off_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 8,
                    right: 52,
                    bottom: 10,
                    child: Text(
                      member.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        shadows: [Shadow(blurRadius: 6, color: Colors.black)],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _HomeBackdrop extends StatelessWidget {
  const _HomeBackdrop({
    required this.members,
    required this.fallbackPhotoUrl,
    required this.fallbackPhotoBase64,
    required this.fallbackAvatarAsset,
    required this.accent,
  });

  final List<GroupMemberSummary> members;
  final String? fallbackPhotoUrl;
  final String? fallbackPhotoBase64;
  final String? fallbackAvatarAsset;
  final Color accent;

  bool _memberHasPhoto(GroupMemberSummary member) {
    return (member.profilePhotoUrl?.trim().isNotEmpty ?? false) ||
        (member.profilePhotoBase64?.trim().isNotEmpty ?? false) ||
        (member.avatarAsset?.trim().isNotEmpty ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final hasMemberPhotos = members.any(_memberHasPhoto);
    final hasFallbackPhoto =
        (fallbackPhotoUrl?.trim().isNotEmpty ?? false) ||
        (fallbackPhotoBase64?.trim().isNotEmpty ?? false) ||
        (fallbackAvatarAsset?.trim().isNotEmpty ?? false);
    final showCollage = members.isNotEmpty ? true : hasFallbackPhoto;

    return ValueListenableBuilder<HomeVisualVariant>(
      valueListenable: HomeVisualVariantController.current,
      builder: (context, variant, _) {
        final baseOpacity = hasMemberPhotos || hasFallbackPhoto
            ? variant.backdropOpacity
            : 0.2;
        final overlay = (1.15 - variant.backdropOpacity).clamp(0.42, 0.92);

        return Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Colors.black),
            if (showCollage)
              Opacity(
                opacity: baseOpacity,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(
                    sigmaX: variant.blurSigma,
                    sigmaY: variant.blurSigma,
                  ),
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: 400,
                      height: 800,
                      child: _BackdropMemberCollage(
                        members: members,
                        fallbackPhotoUrl: fallbackPhotoUrl,
                        fallbackPhotoBase64: fallbackPhotoBase64,
                        fallbackAvatarAsset: fallbackAvatarAsset,
                      ),
                    ),
                  ),
                ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: overlay * 0.34),
                    Colors.black.withValues(alpha: overlay * 0.62),
                    Colors.black.withValues(alpha: overlay),
                    Color.lerp(Colors.black, accent, 0.14)!,
                  ],
                  stops: const [0, 0.35, 0.72, 1],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Full-bleed member photo grid for the blurred home backdrop.
class _BackdropMemberCollage extends StatelessWidget {
  const _BackdropMemberCollage({
    required this.members,
    required this.fallbackPhotoUrl,
    required this.fallbackPhotoBase64,
    required this.fallbackAvatarAsset,
  });

  static const int _maxTiles = 9;

  final List<GroupMemberSummary> members;
  final String? fallbackPhotoUrl;
  final String? fallbackPhotoBase64;
  final String? fallbackAvatarAsset;

  int _columnsFor(int count) {
    if (count <= 1) return 1;
    if (count <= 4) return 2;
    return 3;
  }

  Widget _tile(GroupMemberSummary member) {
    final initial = profileDisplayInitial(member.displayName);
    return ProfileImage(
      // Keyed by user ID so switching groups/members never reuses another
      // user's ProfileImage state (and its sticky-photo cache) by position.
      key: ValueKey(member.userId),
      profilePhotoUrl: member.profilePhotoUrl,
      profilePhotoBase64: member.profilePhotoBase64,
      avatarAsset: member.avatarAsset,
      backgroundColor: const Color(0xff1a1a1a),
      fallback: Text(
        initial,
        style: const TextStyle(
          color: Colors.white54,
          fontSize: 48,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) {
      return ProfileImage(
        profilePhotoUrl: fallbackPhotoUrl,
        profilePhotoBase64: fallbackPhotoBase64,
        avatarAsset: fallbackAvatarAsset,
        backgroundColor: const Color(0xff1a1a1a),
        fallback: const Icon(
          Icons.person_outline,
          color: Colors.white38,
          size: 120,
        ),
      );
    }

    final tiles = members.take(_maxTiles).toList(growable: false);
    final columns = _columnsFor(tiles.length);
    final rows = (tiles.length / columns).ceil();

    return Column(
      children: List.generate(rows, (row) {
        return Expanded(
          child: Row(
            children: List.generate(columns, (column) {
              final index = row * columns + column;
              if (index >= tiles.length) {
                return const Expanded(
                  child: ColoredBox(color: Color(0xff141414)),
                );
              }
              return Expanded(child: _tile(tiles[index]));
            }),
          ),
        );
      }),
    );
  }
}

class _TopChrome extends StatelessWidget {
  const _TopChrome({
    required this.onSettings,
    required this.onSetup,
    required this.hasSetupWarnings,
    required this.busy,
    required this.online,
    required this.enabled,
    required this.onTogglePresence,
    required this.showAudioOutput,
    required this.speakerOn,
    required this.audioRoute,
    required this.audioMuted,
    required this.onToggleAudioOutput,
    required this.onToggleAudioMute,
  });

  final VoidCallback onSettings;
  final VoidCallback onSetup;
  final bool hasSetupWarnings;
  final bool busy;
  final bool online;
  final bool enabled;
  final VoidCallback onTogglePresence;
  final bool showAudioOutput;
  final bool speakerOn;
  final AudioOutputRoute audioRoute;
  final bool audioMuted;
  final VoidCallback onToggleAudioOutput;
  final VoidCallback onToggleAudioMute;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(12.w, 4.h, 12.w, 0),
      child: SizedBox(
        height: 52.h,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Center(
              child: Image.asset(
                'assets/logo.png',
                height: 44.h,
                fit: BoxFit.contain,
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      _GlassIconButton(
                        tooltip: hasSetupWarnings
                            ? 'Settings / Setup'
                            : 'Settings',
                        icon: Icons.settings_outlined,
                        onPressed: onSettings,
                        onLongPress: onSetup,
                      ),
                      if (hasSetupWarnings)
                        Positioned(
                          top: -2,
                          right: -2,
                          child: GestureDetector(
                            onTap: onSetup,
                            child: Container(
                              width: 14.w,
                              height: 14.w,
                              decoration: const BoxDecoration(
                                color: Color(0xffff5a5f),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (showAudioOutput) ...[
                    SizedBox(width: 6.w),
                    _AudioOutputSwitchIcon(
                      speakerOn: speakerOn,
                      route: audioRoute,
                      muted: audioMuted,
                      onToggle: onToggleAudioOutput,
                      onMute: onToggleAudioMute,
                    ),
                  ],
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              // No text label under the toggle by design - its state (and a
              // description for accessibility) is conveyed by the switch
              // itself plus its Tooltip/Semantics.
              child: _StatusToggle(
                busy: busy,
                online: online,
                enabled: enabled,
                onToggle: onTogglePresence,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusToggle extends StatelessWidget {
  const _StatusToggle({
    required this.busy,
    required this.online,
    required this.enabled,
    required this.onToggle,
  });

  final bool busy;
  final bool online;
  final bool enabled;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: busy || !enabled ? 0.55 : 1,
      child: Tooltip(
        message: !enabled
            ? 'Available after another member joins'
            : online
            ? 'Tap to go away'
            : 'Go online when someone is already live, or send a nudge to go together',
        child: SizedBox(
          width: 66.w,
          height: 40,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: busy || !enabled ? null : onToggle,
              borderRadius: BorderRadius.circular(20),
              child: Center(
                child: Container(
                  width: double.infinity,
                  height: 24.h,
                  padding: EdgeInsets.all(2.w),
                  decoration: BoxDecoration(
                    color: const Color.fromRGBO(255, 255, 255, 0.12),
                    borderRadius: BorderRadius.circular(14.r),
                    border: Border.all(
                      color: const Color.fromRGBO(255, 255, 255, 0.22),
                    ),
                  ),
                  child: Stack(
                    children: [
                      AnimatedAlign(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        alignment: online
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          width: 30.w,
                          height: double.infinity,
                          decoration: BoxDecoration(
                            color: online
                                ? const Color(0xff7CFF6B)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(11.r),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Center(
                              // Matches the profile-picture away moon badge
                              // (Icons.dark_mode_rounded @ ~13.sp).
                              child: Icon(
                                Icons.dark_mode_rounded,
                                color: online
                                    ? Colors.white54
                                    : const Color(0xff2a2a2a),
                                size: 13.sp,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Center(
                              child: busy
                                  ? Text('…', style: TextStyle(fontSize: 10.sp))
                                  : online
                                  ? Text(
                                      '🟢',
                                      style: TextStyle(fontSize: 10.sp),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({
    required this.tooltip,
    this.icon,
    this.child,
    required this.onPressed,
    this.onLongPress,
  });

  final String tooltip;
  final IconData? icon;
  final Widget? child;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(22.r),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: onPressed == null
                ? const Color.fromRGBO(255, 255, 255, 0.06)
                : const Color.fromRGBO(0, 0, 0, 0.35),
            border: Border.all(
              color: const Color.fromRGBO(255, 255, 255, 0.18),
            ),
          ),
          child:
              child ??
              Icon(
                icon,
                color: onPressed == null ? Colors.white38 : Colors.white,
                size: 22.sp,
              ),
        ),
      ),
    );
  }
}

class _FriendsStrip extends StatelessWidget {
  const _FriendsStrip({
    required this.groupName,
    required this.friends,
    required this.availability,
    required this.speakingUserIds,
    required this.connectionQualityByUserId,
    required this.nudgeRepliesByUserId,
    required this.onInvite,
  });

  final String? groupName;
  final List<GroupMemberSummary> friends;
  final Map<String, MemberAvailability> availability;
  final Set<String> speakingUserIds;
  final Map<String, ConnectionQuality> connectionQualityByUserId;
  final Map<String, NudgeRecipientReply> nudgeRepliesByUserId;
  final VoidCallback? onInvite;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (groupName != null)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 20.w),
            child: Text(
              groupName!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: 14.sp,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ),
        SizedBox(height: 10.h),
        SizedBox(
          height: 104.h,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: 16.w),
            children: [
              for (final friend in friends) ...[
                _FriendChip(
                  key: ValueKey(friend.userId),
                  name: friend.displayName,
                  profilePhotoUrl: friend.profilePhotoUrl,
                  profilePhotoBase64: friend.profilePhotoBase64,
                  avatarAsset: friend.avatarAsset,
                  availability:
                      availability[friend.userId] ?? MemberAvailability.away,
                  isSpeaking:
                      speakingUserIds.contains(friend.userId) ||
                      (availability[friend.userId]?.isTalking ?? false),
                  connectionQuality:
                      connectionQualityByUserId[friend.userId] ??
                      ConnectionQuality.unknown,
                  nudgeReply: nudgeRepliesByUserId[friend.userId],
                ),
                SizedBox(width: 12.w),
              ],
              _AddFriendChip(onTap: onInvite),
            ],
          ),
        ),
      ],
    );
  }
}

class _FriendChip extends StatelessWidget {
  const _FriendChip({
    super.key,
    required this.name,
    required this.profilePhotoUrl,
    required this.profilePhotoBase64,
    required this.avatarAsset,
    required this.availability,
    required this.isSpeaking,
    required this.connectionQuality,
    this.nudgeReply,
  });

  final String name;
  final String? profilePhotoUrl;
  final String? profilePhotoBase64;
  final String? avatarAsset;
  final MemberAvailability availability;
  final bool isSpeaking;
  final ConnectionQuality connectionQuality;
  final NudgeRecipientReply? nudgeReply;

  @override
  Widget build(BuildContext context) {
    final live = availability.isLive;
    final degradedNetwork =
        connectionQuality == ConnectionQuality.poor ||
        connectionQuality == ConnectionQuality.lost;
    final shortName = name.trim().split(RegExp(r'\s+')).first;
    final initial = profileDisplayInitial(name);
    final ringColor = isSpeaking
        ? const Color(0xff7CFF6B)
        : live
        ? const Color(0xff7CFF6B)
        : Colors.white24;

    return Column(
      children: [
        Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            if (isSpeaking)
              const _TalkingPulseRing(color: Color(0xff7CFF6B), size: 60),
            Container(
              width: 52.w,
              height: 52.w,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xff2a2a2a),
                border: Border.all(
                  color: ringColor,
                  width: isSpeaking ? 2.5 : 2,
                ),
              ),
              child: ClipOval(
                child: ProfileAvatar(
                  profilePhotoUrl: profilePhotoUrl,
                  profilePhotoBase64: profilePhotoBase64,
                  avatarAsset: avatarAsset,
                  radius: 26.w,
                  backgroundColor: const Color(0xff2a2a2a),
                  fallback: Text(
                    initial,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18.sp,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: -4,
              bottom: -2,
              // Prefer decline/snooze reply badge over the live/away glyph
              // while a recent nudge response is still active.
              child: nudgeReply != null
                  ? _NudgeReplyBadge(reply: nudgeReply!)
                  : live
                  ? Text('🟢', style: TextStyle(fontSize: 14.sp))
                  : Container(
                      width: 20.w,
                      height: 20.w,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xff2a2a2a),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black45,
                            blurRadius: 3,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.dark_mode_rounded,
                        color: Colors.white70,
                        size: 13.sp,
                      ),
                    ),
            ),
          ],
        ),
        SizedBox(height: 4.h),
        SizedBox(
          width: 72.w,
          child: Text(
            isSpeaking ? '🗣️ talking' : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isSpeaking ? const Color(0xff7CFF6B) : Colors.white70,
              fontSize: 10.sp,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (degradedNetwork && !isSpeaking) ...[
          SizedBox(height: 2.h),
          SizedBox(
            width: 72.w,
            child: Text(
              "${shortName.isEmpty ? 'Their' : shortName}'s network is low",
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: const Color(0xffffb347),
                fontSize: 8.sp,
                fontWeight: FontWeight.w600,
                height: 1.1,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _NudgeReplyBadge extends StatelessWidget {
  const _NudgeReplyBadge({required this.reply});

  final NudgeRecipientReply reply;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (reply) {
      NudgeRecipientReply.declined => (Icons.dark_mode_rounded, Colors.white70),
      NudgeRecipientReply.snoozed => (
        LucideIcons.timer,
        const Color(0xffe0a83c),
      ),
    };
    return Container(
      width: 22.w,
      height: 22.w,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // Match the away moon badge grey (Color(0xff2a2a2a)).
        color: const Color(0xff2a2a2a),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.28),
          width: 1,
        ),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 3, offset: Offset(0, 1)),
        ],
      ),
      child: Icon(icon, color: color, size: 13.sp),
    );
  }
}

class _TalkingPulseRing extends StatefulWidget {
  const _TalkingPulseRing({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  State<_TalkingPulseRing> createState() => _TalkingPulseRingState();
}

class _TalkingPulseRingState extends State<_TalkingPulseRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        final scale = 1 + (0.18 * t);
        final opacity = (1 - t).clamp(0.0, 1.0);
        return Transform.scale(
          scale: scale,
          child: Container(
            width: widget.size.w,
            height: widget.size.w,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: widget.color.withValues(alpha: 0.55 * opacity),
                width: 2,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AudioOutputSwitchIcon extends StatefulWidget {
  const _AudioOutputSwitchIcon({
    required this.speakerOn,
    required this.route,
    required this.muted,
    required this.onToggle,
    required this.onMute,
  });

  final bool speakerOn;
  final AudioOutputRoute route;
  final bool muted;
  final VoidCallback onToggle;
  final VoidCallback onMute;

  @override
  State<_AudioOutputSwitchIcon> createState() => _AudioOutputSwitchIconState();
}

class _AudioOutputSwitchIconState extends State<_AudioOutputSwitchIcon> {
  @override
  Widget build(BuildContext context) {
    final kind = resolveAudioOutputGlyph(
      route: widget.route,
      muted: widget.muted,
    );
    return _GlassIconButton(
      tooltip: audioOutputTooltip(
        kind: kind,
        speakerPreferenceOn: widget.speakerOn,
      ),
      onPressed: widget.onToggle,
      onLongPress: widget.onMute,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: LucideAudioGlyph(
          key: ValueKey(kind),
          kind: kind,
          color: Colors.white,
          size: 22.sp,
        ),
      ),
    );
  }
}

class _AddFriendChip extends StatelessWidget {
  const _AddFriendChip({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: Column(
          children: [
            Container(
              width: 52.w,
              height: 52.w,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white54, width: 1.5),
              ),
              child: Icon(Icons.add, color: Colors.white, size: 24.sp),
            ),
            SizedBox(height: 4.h),
            Text(
              'invite',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 10.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Vertical edge actions on the right of the main button row: 👋 nudge on
/// top (when the group is mixed), and the alternate connection-mode icon
/// below (shown whenever someone is online). No circular chrome — just the
/// glyph — with a subtle shake to telegraph "tap me".
///
/// Mode icon semantics: in walkie-talkie mode the edge shows a call icon
/// (tap → call mode); in call mode it shows the walkie asset (tap → walkie).
class _EdgeQuickActions extends StatelessWidget {
  const _EdgeQuickActions({
    required this.showNudge,
    required this.onNudge,
    required this.showModeToggle,
    required this.modeToggleEnabled,
    required this.callModeActive,
    required this.onToggleMode,
  });

  final bool showNudge;
  final VoidCallback? onNudge;
  final bool showModeToggle;
  final bool modeToggleEnabled;
  final bool callModeActive;
  final VoidCallback onToggleMode;

  /// Shared column width so 👋 and the mode glyph share one right-edge axis.
  static double get _columnWidth => 48.w;

  @override
  Widget build(BuildContext context) {
    if (!showNudge && !showModeToggle) return const SizedBox.shrink();
    return SizedBox(
      width: _columnWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (showNudge)
            Semantics(
              button: true,
              label: 'Nudge the group',
              child: Tooltip(
                message: 'Send a nudge',
                child: _EdgeActionHit(
                  onTap: onNudge,
                  enabled: onNudge != null,
                  shake: false,
                  hitSize: _columnWidth,
                  child: Text('👋', style: TextStyle(fontSize: 28.sp)),
                ),
              ),
            ),
          if (showNudge && showModeToggle) SizedBox(height: 10.h),
          if (showModeToggle)
            Semantics(
              button: true,
              label: callModeActive
                  ? 'Switch to walkie-talkie mode'
                  : 'Switch to call mode',
              child: Tooltip(
                message: callModeActive
                    ? 'Switch to walkie-talkie'
                    : 'Switch to call mode',
                child: _EdgeActionHit(
                  onTap: modeToggleEnabled ? onToggleMode : null,
                  enabled: modeToggleEnabled,
                  shake: modeToggleEnabled,
                  hitSize: _columnWidth,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 240),
                    transitionBuilder: (child, animation) => ScaleTransition(
                      scale: animation,
                      child: FadeTransition(opacity: animation, child: child),
                    ),
                    child: callModeActive
                        ? _WalkieEdgeIcon(
                            key: const ValueKey('edge-walkie'),
                            size: _columnWidth * 0.78,
                          )
                        : Icon(
                            Icons.call_rounded,
                            key: const ValueKey('edge-call'),
                            color: Colors.white,
                            size: 26.sp,
                          ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Walkie PNG has large transparent padding, so a plain `Image.asset` +
/// `BoxFit.contain` leaves the device art looking tiny and inset from the
/// edge. Zoom to the painted body and center it in [size] for the edge stack.
class _WalkieEdgeIcon extends StatelessWidget {
  const _WalkieEdgeIcon({super.key, required this.size});

  final double size;

  // Source is 2079×1135 with content roughly at x 743–1337 / y 88–1047.
  // Scale is tuned so the body reads clearly without dominating the edge.
  static const double _contentZoom = 2.35;

  @override
  Widget build(BuildContext context) {
    // Inset from the hit slot so scale-up doesn't clip top/bottom.
    final paintSize = size * 0.82;
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: SizedBox(
          width: paintSize,
          height: paintSize,
          child: ClipRect(
            child: Transform.scale(
              scale: _contentZoom,
              alignment: Alignment.center,
              child: Image.asset(
                'assets/walkie.png',
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Comfortable hit target around a bare glyph. Optional soft shake while
/// [enabled] so mode-toggle reads as tappable (nudge keeps still).
class _EdgeActionHit extends StatelessWidget {
  const _EdgeActionHit({
    required this.onTap,
    required this.enabled,
    required this.child,
    this.shake = false,
    this.hitSize,
  });

  final VoidCallback? onTap;
  final bool enabled;
  final bool shake;
  final double? hitSize;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = hitSize ?? 48.w;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Opacity(
            opacity: enabled ? 1 : 0.4,
            child: shake && enabled
                ? _SoftShake(active: true, child: child)
                : child,
          ),
        ),
      ),
    );
  }
}

/// Subtle left/right wobble that loops while [active] is true — used on the
/// edge nudge and mode-toggle glyphs to signal they can be tapped.
class _SoftShake extends StatefulWidget {
  const _SoftShake({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<_SoftShake> createState() => _SoftShakeState();
}

class _SoftShakeState extends State<_SoftShake>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _SoftShake oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // Two soft half-wobbles per loop, then a rest — feels playful without
        // reading as an alert.
        final t = _controller.value;
        final wave = t < 0.45
            ? sin(t / 0.45 * pi * 2) * (1 - t / 0.45)
            : 0.0;
        return Transform.rotate(
          angle: wave * 0.12,
          child: Transform.translate(
            offset: Offset(wave * 2.2, 0),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

class _ExperienceCarousel extends StatefulWidget {
  const _ExperienceCarousel({
    required this.items,
    required this.index,
    required this.connectedGroupId,
    required this.connecting,
    required this.talkEnabled,
    required this.talkActive,
    required this.talkBusy,
    required this.callMode,
    required this.accent,
    required this.nudgeGroupId,
    required this.goLiveGroupId,
    required this.onNudge,
    required this.onSelected,
    required this.onTalkStart,
    required this.onTalkStop,
    required this.onJoinVoiceGroup,
    required this.onCreateGroup,
    required this.onJoinGroup,
  });

  final List<_CarouselItem> items;
  final int index;
  final String? connectedGroupId;

  /// True while LiveKit is joining, reconnecting, or leaving.
  final bool connecting;
  final bool talkEnabled;
  final bool talkActive;
  final bool talkBusy;

  /// Local conversation mode: true = always-on call, false = walkie-talkie
  /// (push-to-talk). Drives which glyph the main connected circle shows.
  final bool callMode;
  final Color accent;

  /// Group id of the focused card when the whole group (self included) is
  /// offline — tapping the main circle opens the nudge composer. Null when
  /// the focused card should join instead (peers already live, or switching
  /// from another connected group).
  final String? nudgeGroupId;

  /// Focused room with an active LiveKit peer while this user is offline.
  final String? goLiveGroupId;
  final VoidCallback? onNudge;
  final ValueChanged<int> onSelected;
  final Future<void> Function() onTalkStart;
  final Future<void> Function() onTalkStop;
  final VoidCallback onJoinVoiceGroup;
  final VoidCallback onCreateGroup;
  final VoidCallback onJoinGroup;

  @override
  State<_ExperienceCarousel> createState() => _ExperienceCarouselState();
}

class _ExperienceCarouselState extends State<_ExperienceCarousel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _settleController = AnimationController(
    vsync: this,
  );
  late double _position = widget.index.toDouble();
  Animation<double>? _settleAnimation;
  double _itemSpacing = 64;
  int? _selectionAfterSettle;

  @override
  void initState() {
    super.initState();
    _settleController.addListener(_onSettleTick);
    _settleController.addStatusListener(_onSettleStatus);
  }

  @override
  void didUpdateWidget(covariant _ExperienceCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.items.isEmpty) {
      _settleController.stop();
      _position = 0;
      return;
    }

    final lastIndex = widget.items.length - 1;
    _position = _position.clamp(0, lastIndex).toDouble();
    if (widget.index != oldWidget.index &&
        widget.index != _position.round() &&
        !_settleController.isAnimating) {
      _animateTo(widget.index, notifySelection: false);
    }
  }

  @override
  void dispose() {
    _settleController
      ..removeListener(_onSettleTick)
      ..removeStatusListener(_onSettleStatus)
      ..dispose();
    super.dispose();
  }

  void _onSettleTick() {
    final animation = _settleAnimation;
    if (animation == null || !mounted) return;
    setState(() => _position = animation.value);
  }

  void _onSettleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    final selection = _selectionAfterSettle;
    _selectionAfterSettle = null;
    if (selection == null || selection == widget.index) return;
    unawaited(HapticFeedback.selectionClick());
    widget.onSelected(selection);
  }

  void _animateTo(int target, {required bool notifySelection}) {
    if (widget.items.isEmpty) return;
    final resolvedTarget = target.clamp(0, widget.items.length - 1);
    final distance = (_position - resolvedTarget).abs();

    _settleController.stop();
    _selectionAfterSettle = notifySelection ? resolvedTarget : null;
    _settleController.duration = Duration(
      milliseconds: (220 + distance * 45).clamp(220, 420).round(),
    );
    _settleAnimation =
        Tween<double>(begin: _position, end: resolvedTarget.toDouble()).animate(
          CurvedAnimation(
            parent: _settleController,
            curve: Curves.easeOutCubic,
          ),
        );
    _settleController.forward(from: 0);
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    _selectionAfterSettle = null;
    _settleController.stop();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (widget.items.length < 2) return;
    final next = _position - details.delta.dx / _itemSpacing;
    setState(() {
      _position = next.clamp(0, widget.items.length - 1).toDouble();
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (widget.items.isEmpty) return;
    final projected = _position - details.velocity.pixelsPerSecond.dx / 1000;
    _animateTo(projected.round(), notifySelection: true);
  }

  void _onHorizontalDragCancel() {
    if (widget.items.isEmpty) return;
    _animateTo(_position.round(), notifySelection: true);
  }

  Widget _buildGroupCircle(int itemIndex, double spacing) {
    final item = widget.items[itemIndex];
    final delta = itemIndex - _position;
    final distance = delta.abs();
    final visualFocus = _position.round().clamp(0, widget.items.length - 1);
    final visuallySelected = itemIndex == visualFocus;
    final actuallySelected = itemIndex == widget.index;
    final scale = (1 / (1 + distance * 0.46)).clamp(0.4, 1.0);
    final opacity = (1 - distance * 0.18).clamp(0.28, 1.0);
    final rotationY = (delta * -0.26).clamp(-0.62, 0.62);

    final connectedToThisGroup = item.group.groupId == widget.connectedGroupId;
    final focused = actuallySelected && distance < 0.45;
    final goLiveMode = focused && item.group.groupId == widget.goLiveGroupId;
    Widget circle = _MainAvatarCircle(
      item: item,
      selected: visuallySelected,
      connected: connectedToThisGroup,
      connecting: widget.connecting && focused,
      talkEnabled: widget.talkEnabled && focused,
      joinEnabled:
          focused &&
          !widget.connecting &&
          !connectedToThisGroup &&
          // Direct join only when offline. While live elsewhere, the main
          // button is nudge-only (no auto-switch into this group).
          widget.connectedGroupId == null &&
          widget.nudgeGroupId == null,
      talkActive: widget.talkActive && actuallySelected,
      talkBusy: widget.talkBusy,
      callMode: widget.callMode,
      accent: widget.accent,
      // Offline/default icon whenever this focused card is not in a live
      // session and not mid-connect — never leave the circle with no glyph.
      nudgeMode:
          focused &&
          !widget.connecting &&
          !connectedToThisGroup &&
          item.group.groupId == widget.nudgeGroupId,
      goLiveMode: goLiveMode,
      onNudge: widget.onNudge,
      onTalkStart: widget.onTalkStart,
      onTalkStop: widget.onTalkStop,
      onJoin: widget.onJoinVoiceGroup,
    );

    if (!actuallySelected) {
      circle = Semantics(
        button: true,
        label: 'Select ${item.group.name} group',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _animateTo(itemIndex, notifySelection: true),
          child: circle,
        ),
      );
    }

    return Positioned.fill(
      child: Center(
        child: Transform.translate(
          offset: Offset(delta * spacing, distance * 7.h),
          child: Opacity(
            opacity: opacity,
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.0014)
                ..rotateY(rotationY),
              child: Transform.scale(
                scale: scale,
                child:
                    focused &&
                        connectedToThisGroup &&
                        !widget.callMode &&
                        !widget.connecting
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.talkActive
                                ? 'Tap to Stop Talking'
                                : 'Tap to Talk',
                            maxLines: 1,
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12.sp,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(height: 4.h),
                          circle,
                        ],
                      )
                    : circle,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return Row(
        children: [
          SizedBox(width: 16.w),
          _DashedAddCircle(
            onTap: widget.onJoinGroup,
            compact: true,
            label: '+ join\ngroup',
          ),
          const Spacer(),
          _DashedAddCircle(
            onTap: widget.onCreateGroup,
            compact: true,
            label: '+ create\nnew group',
          ),
          SizedBox(width: 16.w),
        ],
      );
    }

    return Row(
      children: [
        SizedBox(width: 12.w),
        _DashedAddCircle(
          onTap: widget.onJoinGroup,
          compact: true,
          label: '+ join\ngroup',
        ),
        SizedBox(width: 8.w),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final spacing = (constraints.maxWidth * 0.34).clamp(52.w, 70.w);
              _itemSpacing = spacing;
              final paintOrder =
                  List<int>.generate(
                    widget.items.length,
                    (itemIndex) => itemIndex,
                  )..sort((a, b) {
                    final aDistance = (a - _position).abs();
                    final bDistance = (b - _position).abs();
                    return bDistance.compareTo(aDistance);
                  });

              return ClipRect(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ShaderMask(
                        blendMode: BlendMode.dstIn,
                        shaderCallback: (bounds) => const LinearGradient(
                          colors: [
                            Colors.transparent,
                            Color(0x40FFFFFF),
                            Colors.white,
                            Colors.white,
                            Color(0x40FFFFFF),
                            Colors.transparent,
                          ],
                          stops: [0, 0.08, 0.22, 0.78, 0.92, 1],
                        ).createShader(bounds),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragStart: _onHorizontalDragStart,
                          onHorizontalDragUpdate: _onHorizontalDragUpdate,
                          onHorizontalDragEnd: _onHorizontalDragEnd,
                          onHorizontalDragCancel: _onHorizontalDragCancel,
                          child: Stack(
                            clipBehavior: Clip.hardEdge,
                            children: [
                              for (final itemIndex in paintOrder)
                                _buildGroupCircle(itemIndex, spacing),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: 52.w,
                      child: const _CarouselEdgeVeil(leftEdge: true),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      width: 52.w,
                      child: const _CarouselEdgeVeil(leftEdge: false),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        SizedBox(width: 8.w),
        _DashedAddCircle(
          onTap: widget.onCreateGroup,
          compact: true,
          label: '+ create\nnew group',
        ),
        SizedBox(width: 12.w),
      ],
    );
  }
}

class _CarouselEdgeVeil extends StatelessWidget {
  const _CarouselEdgeVeil({required this.leftEdge});

  final bool leftEdge;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => LinearGradient(
          begin: leftEdge ? Alignment.centerLeft : Alignment.centerRight,
          end: leftEdge ? Alignment.centerRight : Alignment.centerLeft,
          colors: const [Colors.white, Color(0x99FFFFFF), Colors.transparent],
          stops: const [0, 0.35, 1],
        ).createShader(bounds),
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: const ColoredBox(color: Colors.transparent),
          ),
        ),
      ),
    );
  }
}

class _MainAvatarCircle extends StatelessWidget {
  const _MainAvatarCircle({
    required this.item,
    required this.selected,
    required this.connected,
    required this.connecting,
    required this.talkEnabled,
    required this.joinEnabled,
    required this.talkActive,
    required this.talkBusy,
    required this.callMode,
    required this.accent,
    required this.nudgeMode,
    required this.goLiveMode,
    required this.onNudge,
    required this.onTalkStart,
    required this.onTalkStop,
    required this.onJoin,
  });

  final _CarouselItem item;
  final bool selected;
  final bool connected;
  final bool connecting;
  final bool talkEnabled;
  final bool joinEnabled;
  final bool talkActive;
  final bool talkBusy;

  /// True when the local user is in always-on call mode; false = walkie
  /// (push-to-talk). Controls which overlay glyph renders while connected.
  final bool callMode;
  final Color accent;

  /// True when this focused card should open the nudge sheet (👋) instead of
  /// join/talk — whole group offline, or live elsewhere viewing this group.
  final bool nudgeMode;

  /// True when an offline user can directly join an active LiveKit room.
  final bool goLiveMode;
  final VoidCallback? onNudge;
  final Future<void> Function() onTalkStart;
  final Future<void> Function() onTalkStop;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final size = 110.w;
    // Yellow ring only while the local user is actively transmitting.
    final borderColor = connecting
        ? Colors.white54
        : connected
        ? (talkActive ? const Color(0xffffd54f) : const Color(0xff28A745))
        : nudgeMode
        ? Colors.white38
        : Colors.white;

    Widget circle = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: borderColor,
          width: connected || connecting ? 4 : (selected ? 2.5 : 2),
        ),
      ),
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedOpacity(
              duration: const Duration(milliseconds: 220),
              opacity: (nudgeMode || goLiveMode || connecting) ? 0.38 : 1,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: goLiveMode ? 2.4 : 0,
                  sigmaY: goLiveMode ? 2.4 : 0,
                ),
                child: _MemberPhotoCollage(
                  members: item.members,
                  fallbackPhotoUrl: item.profilePhotoUrl,
                  fallbackPhotoBase64: item.profilePhotoBase64,
                  fallbackAvatarAsset: item.avatarAsset,
                  tileSize: size,
                ),
              ),
            ),
            if (goLiveMode && !connecting) ...[
              const ColoredBox(color: Color(0x40000000)),
              Center(
                child: Text(
                  'Join?',
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 19.sp,
                    fontWeight: FontWeight.w800,
                    shadows: const [Shadow(color: Colors.black, blurRadius: 8)],
                  ),
                ),
              ),
            ],
            // Bottom fade lifts live glyphs without fully masking profiles.
            if (connected && !connecting)
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x00000000),
                      Color(0x66000000),
                      Color(0x99000000),
                    ],
                    stops: [0.3, 0.68, 1],
                  ),
                ),
              ),
            // Nudge wave stays inside the clipped circle (offline state).
            if (nudgeMode && !connecting)
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.only(bottom: size * 0.1),
                  child: Text('👋', style: TextStyle(fontSize: size * 0.22)),
                ),
              ),
          ],
        ),
      ),
    );

    final plateSize = size * 0.96;
    final glyphSize = size * 0.88;
    if (connecting || connected) {
      // ~2–3 logical px shrink while PTT is held for a pressed feel.
      final transmitInset = talkActive && !callMode && !connecting
          ? 2.5.w
          : 0.0;
      circle = SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            // Compact radial ripples sit outside the solid border so
            // transmitting reads clearly without enlarging the button hit area.
            if (talkActive && !connecting)
              Positioned.fill(
                child: IgnorePointer(
                  child: _TransmitRadialVisualizer(
                    color: const Color(0xffffd54f),
                    diameter: size,
                  ),
                ),
              ),
            circle,
            Positioned(
              left: 0,
              right: 0,
              bottom: size * 0.02,
              child: Center(
                child: Container(
                  width: plateSize,
                  height: plateSize,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.35),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 10,
                        spreadRadius: 0,
                      ),
                    ],
                  ),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 240),
                    transitionBuilder: (child, animation) => ScaleTransition(
                      scale: animation,
                      child: FadeTransition(opacity: animation, child: child),
                    ),
                    child: connecting
                        ? _MainButtonDotsLoader(
                            key: const ValueKey('main-connecting'),
                            size: glyphSize * 0.52,
                          )
                        : callMode
                        ? Icon(
                            Icons.call_rounded,
                            key: const ValueKey('main-call'),
                            color: talkActive
                                ? const Color(0xffffd54f)
                                : Colors.white,
                            size: glyphSize * 0.42,
                          )
                        : AnimatedScale(
                            key: const ValueKey('main-walkie'),
                            scale: talkActive
                                ? (glyphSize - transmitInset * 2) / glyphSize
                                : 1,
                            duration: const Duration(milliseconds: 90),
                            curve: Curves.easeOut,
                            child: Image.asset(
                              'assets/walkie.png',
                              width: glyphSize,
                              height: glyphSize,
                              fit: BoxFit.contain,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (!connecting && (talkEnabled || joinEnabled || nudgeMode)) {
      circle = Semantics(
        button: true,
        label: goLiveMode
            ? 'Join the conversation in ${item.group.name}'
            : joinEnabled
            ? 'Join ${item.group.name}'
            : nudgeMode
            ? 'Nudge ${item.group.name}'
            : talkActive
            ? 'Stop talking'
            : 'Tap to Talk',
        child: GestureDetector(
          onTap: talkBusy
              ? null
              : () {
                  if (joinEnabled) {
                    onJoin();
                    return;
                  }
                  if (nudgeMode) {
                    onNudge?.call();
                    return;
                  }
                  if (talkActive) {
                    unawaited(onTalkStop());
                  } else {
                    unawaited(onTalkStart());
                  }
                },
          child: circle,
        ),
      );
    }

    final content = AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: talkBusy ? 0.65 : 1,
      child: circle,
    );

    if (!nudgeMode || connecting) return content;

    // Rising "Z"s sit outside ClipOval so they can keep travelling past the
    // button's ring and fade out in open space (instead of being clipped or
    // orbiting the edge). Same up-and-right drift as the previous design.
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          content,
          Positioned(
            right: size * 0.08,
            top: size * 0.06,
            child: IgnorePointer(child: _SleepZAnimation(size: size * 0.3)),
          ),
        ],
      ),
    );
  }
}

/// Three-dot pulse used on the main circle while LiveKit is connecting.
class _MainButtonDotsLoader extends StatefulWidget {
  const _MainButtonDotsLoader({super.key, required this.size});

  final double size;

  @override
  State<_MainButtonDotsLoader> createState() => _MainButtonDotsLoaderState();
}

class _MainButtonDotsLoaderState extends State<_MainButtonDotsLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = widget.size * 0.28;
    return SizedBox(
      width: widget.size,
      height: widget.size * 0.45,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) SizedBox(width: widget.size * 0.1),
                _dot(i, dot),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _dot(int index, double diameter) {
    final t = ((_controller.value + (1 - index * 0.22)) % 1.0);
    final bounce = sin(t * pi);
    final scale = 0.55 + 0.45 * bounce;
    final opacity = 0.35 + 0.65 * bounce;
    return Transform.translate(
      offset: Offset(0, -widget.size * 0.12 * bounce),
      child: Transform.scale(
        scale: scale,
        child: Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: opacity),
          ),
        ),
      ),
    );
  }
}

/// Compact expanding rings around the talk button while transmitting.
/// Timer-driven (no LiveKit visualizer dependency) for a light CPU cost.
class _TransmitRadialVisualizer extends StatefulWidget {
  const _TransmitRadialVisualizer({
    required this.color,
    required this.diameter,
  });

  final Color color;
  final double diameter;

  @override
  State<_TransmitRadialVisualizer> createState() =>
      _TransmitRadialVisualizerState();
}

class _TransmitRadialVisualizerState extends State<_TransmitRadialVisualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return CustomPaint(
          painter: _TransmitRipplePainter(
            progress: _controller.value,
            color: widget.color,
          ),
          size: Size.square(widget.diameter),
        );
      },
    );
  }
}

class _TransmitRipplePainter extends CustomPainter {
  _TransmitRipplePainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = size.shortestSide / 2;
    // Three staggered ripples, short travel beyond the solid outline.
    for (var i = 0; i < 3; i++) {
      final t = (progress + i / 3) % 1.0;
      final radius = baseRadius + 2 + t * 10;
      final opacity = (1 - t) * 0.45;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 * (1 - t * 0.5)
        ..color = color.withValues(alpha: opacity);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TransmitRipplePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

/// Looping "Z"s drifting up-and-right and fading for the fully-offline nudge
/// state. Hosted outside the button ClipOval so glyphs clear the ring before
/// dissolving.
class _SleepZAnimation extends StatefulWidget {
  const _SleepZAnimation({required this.size});

  final double size;

  @override
  State<_SleepZAnimation> createState() => _SleepZAnimationState();
}

class _SleepZAnimationState extends State<_SleepZAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Stack(
            clipBehavior: Clip.none,
            children: [for (var i = 0; i < 3; i++) _buildZ(i)],
          );
        },
      ),
    );
  }

  Widget _buildZ(int i) {
    // Three staggered "Z"s rise up-and-right. Travel is long enough that they
    // clearly pass the button outline; the fade starts later so most of the
    // dissolve happens once they're outside the ring.
    final t = ((_controller.value + i * 0.33) % 1.0);
    final opacity = t < 0.12
        ? Curves.easeOut.transform(t / 0.12)
        : t > 0.55
        ? Curves.easeIn.transform((1 - t) / 0.45).clamp(0.0, 1.0)
        : 1.0;
    final scale =
        0.88 + 0.22 * Curves.easeOut.transform((t * 1.4).clamp(0.0, 1.0));
    return Positioned(
      // Extra outward travel vs the older in-circle version so glyphs leave
      // the ring before fully fading.
      right: -t * widget.size * 0.85,
      top: widget.size * 0.55 - t * widget.size * 1.45,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: scale,
          child: Text(
            'Z',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.92),
              fontSize: widget.size * (0.42 + i * 0.1),
              fontWeight: FontWeight.w800,
              height: 1,
              letterSpacing: -0.5,
              shadows: const [
                Shadow(
                  color: Colors.black54,
                  blurRadius: 6,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tiles every group member inside the connect circle. Falls back to a single
/// self-avatar when member data isn't loaded yet.
class _MemberPhotoCollage extends StatelessWidget {
  const _MemberPhotoCollage({
    required this.members,
    required this.fallbackPhotoUrl,
    required this.fallbackPhotoBase64,
    required this.fallbackAvatarAsset,
    required this.tileSize,
  });

  final List<GroupMemberSummary> members;
  final String? fallbackPhotoUrl;
  final String? fallbackPhotoBase64;
  final String? fallbackAvatarAsset;
  final double tileSize;

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) {
      return ProfileImage(
        profilePhotoUrl: fallbackPhotoUrl,
        profilePhotoBase64: fallbackPhotoBase64,
        avatarAsset: fallbackAvatarAsset,
        backgroundColor: const Color(0xff2a2a2a),
        fadeInDuration: Duration.zero,
        fallback: Icon(
          Icons.person_outline,
          color: Colors.white70,
          size: tileSize * 0.4,
        ),
      );
    }

    final columns = sqrt(members.length).ceil();
    final rows = (members.length / columns).ceil();

    Widget tile(GroupMemberSummary member) {
      final initial = profileDisplayInitial(member.displayName);
      return ProfileImage(
        // Keyed by user ID so switching groups never reuses another user's
        // ProfileImage state (and its sticky-photo cache) by position.
        key: ValueKey(member.userId),
        profilePhotoUrl: member.profilePhotoUrl,
        profilePhotoBase64: member.profilePhotoBase64,
        avatarAsset: member.avatarAsset,
        backgroundColor: const Color(0xff2a2a2a),
        fadeInDuration: Duration.zero,
        fallback: Text(
          initial,
          style: TextStyle(
            color: Colors.white,
            fontSize: tileSize * 0.16 / columns,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    return GridView.builder(
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: members.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        childAspectRatio: rows / columns,
        crossAxisSpacing: 1.5,
        mainAxisSpacing: 1.5,
      ),
      itemBuilder: (context, index) => tile(members[index]),
    );
  }
}

class _DashedAddCircle extends StatelessWidget {
  const _DashedAddCircle({
    required this.onTap,
    required this.compact,
    required this.label,
  });

  final VoidCallback? onTap;
  final bool compact;
  final String label;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 72.w : 110.w;
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: CustomPaint(
          painter: _DashedCirclePainter(
            color: const Color.fromRGBO(255, 255, 255, 0.7),
          ),
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(10.w),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: compact ? 9.sp : 12.sp,
                    fontWeight: FontWeight.w600,
                    height: 1.15,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedCirclePainter extends CustomPainter {
  const _DashedCirclePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;

    final radius = size.shortestSide / 2;
    const dashCount = 28;
    const dashSweep = 0.12;
    const gapSweep = (6.28318530718 / dashCount) - dashSweep;
    var start = 0.0;

    for (var i = 0; i < dashCount; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: size.center(Offset.zero), radius: radius),
        start,
        dashSweep,
        false,
        paint,
      );
      start += dashSweep + gapSweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedCirclePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _CarouselItem {
  const _CarouselItem({
    required this.group,
    required this.displayName,
    required this.availability,
    this.profilePhotoUrl,
    this.profilePhotoBase64,
    this.avatarAsset,
    this.members = const [],
  });

  factory _CarouselItem.group({
    required GroupSummary group,
    required String displayName,
    required String? profilePhotoUrl,
    required String? profilePhotoBase64,
    required String? avatarAsset,
    required MemberAvailability availability,
    List<GroupMemberSummary> members = const [],
  }) {
    return _CarouselItem(
      group: group,
      displayName: displayName,
      profilePhotoUrl: profilePhotoUrl,
      profilePhotoBase64: profilePhotoBase64,
      avatarAsset: avatarAsset,
      availability: availability,
      members: members,
    );
  }

  final GroupSummary group;
  final String displayName;
  final MemberAvailability availability;
  final String? profilePhotoUrl;
  final String? profilePhotoBase64;
  final String? avatarAsset;

  /// Group members loaded for this group (only populated for the
  /// currently-selected/focused group). Used to render a photo collage on
  /// the connect circle so it's obvious at a glance who you're joining.
  final List<GroupMemberSummary> members;
}

class _SetupLine extends StatelessWidget {
  const _SetupLine({required this.ok, required this.text});

  final bool ok;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.error_outline,
            color: ok ? colors.primary : colors.error,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

/// A setup warning with an optional tap action (e.g. request the missing
/// permission directly from the setup modal).
class _SetupWarning {
  const _SetupWarning({required this.text, required this.accent, this.onTap});

  final String text;
  final Color accent;
  final VoidCallback? onTap;
}

/// Like [_SetupLine] but tappable — tapping an unresolved warning navigates
/// to the specific permission request instead of just listing it.
class _TappableSetupLine extends StatelessWidget {
  const _TappableSetupLine({
    required this.ok,
    required this.text,
    required this.onTap,
    required this.accent,
  });

  final bool ok;
  final String text;
  final VoidCallback? onTap;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tappable = onTap != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.symmetric(
            vertical: 4.h,
            horizontal: tappable ? 6.w : 0,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                ok ? Icons.check_circle : Icons.error_outline,
                color: ok ? colors.primary : colors.error,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    color: tappable ? accent : null,
                    decoration: tappable ? TextDecoration.underline : null,
                  ),
                ),
              ),
              if (tappable)
                Icon(
                  Icons.arrow_forward_rounded,
                  size: 16,
                  color: colors.onSurface.withValues(alpha: 0.3),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
