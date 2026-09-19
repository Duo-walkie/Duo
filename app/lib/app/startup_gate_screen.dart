import 'package:one_one_app/one_one.dart';

class StartupGateScreen extends StatefulWidget {
  const StartupGateScreen({super.key});

  @override
  State<StartupGateScreen> createState() => _StartupGateScreenState();
}

class _StartupGateScreenState extends State<StartupGateScreen>
    with WidgetsBindingObserver {
  final IdentityRepository _identityRepository = IdentityRepository();
  final GroupRepository _groupRepository = GroupRepository();
  final InviteLinkBridge _inviteLinkBridge = InviteLinkBridge();

  bool _isLoggingIn = false;
  bool _joiningInvite = false;
  /// Shared so concurrent callers (startup present + linkSignals) await the
  /// same join instead of one returning null and flashing NoGroups.
  Completer<String?>? _inviteJoinCompleter;
  Widget? _nextScreen;
  StreamSubscription<void>? _inviteLinkSubscription;
  IdentitySession? _readySession;
  String? _startupError;
  /// `true` = success snackbar; otherwise an error string.
  Object? _pendingInviteFeedback;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _inviteLinkSubscription = InviteLinkBridge.linkSignals.listen((_) {
      unawaited(_handleIncomingInviteLink());
    });
    // Start identity/session resolution the instant this screen mounts —
    // there's no UX benefit to an artificial delay here, and every
    // millisecond saved shows up as faster time-to-home-screen.
    unawaited(_continueAfterLogin());
  }

  @override
  void dispose() {
    _inviteLinkSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _identityRepository.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_handleIncomingInviteLink());
    }
  }

  Future<void> _continueAfterLogin() async {
    if (_isLoggingIn) return;
    final stopwatch = Stopwatch()..start();

    setState(() {
      _isLoggingIn = true;
      _startupError = null;
    });

    try {
      final session = await _identityRepository.ensureIdentity();
      logStartupMilestone('local identity ready', stopwatch);
      if (!mounted) return;
      _readySession = session;
      unawaited(
        MarketController.syncWithAccount(
          backendMarketIso: session.user.market,
          persistIfAbsent: _identityRepository.persistMarketIfAbsent,
        ),
      );
      unawaited(
        LocaleController.syncWithAccount(session.settings.preferredLocale),
      );

      // Prefer the on-device setup flag so post-Google-sign-in does not sit
      // on the art-only underlay waiting for an RTDB round-trip. Remote
      // confirmation still runs for reinstalls (local miss, RTDB hit).
      final localSetupDone = await _hasCompletedSetup(session.userId);
      logStartupMilestone('local setup state resolved', stopwatch);
      if (!mounted) return;

      // Always pre-fetch groups in parallel regardless of setup state.
      final groupsPrefetch = _groupRepository.loadGroupsForUser(session.userId);

      // Start the free-trial clock as soon as identity is ready so the
      // 7-day window covers onboarding as well as home use. Do not await
      // for new users — that only delayed the permission screen and made
      // the post-Google-sign-in underlay linger.
      final trialStart = FreeTrialAccess.ensureStarted(session.userId);

      if (!localSetupDone) {
        unawaited(trialStart);
        _presentNewUserPermissionSetup(session);

        // Reinstall / cleared prefs: RTDB may still say setup is done.
        final isReturningUser = await _identityRepository.hasCompletedSetup();
        logStartupMilestone('setup state resolved', stopwatch);
        if (!mounted) return;
        if (isReturningUser && _nextScreen is SetupPermissionScreen) {
          await trialStart;
          if (!await _requiredPermissionsGranted()) {
            if (!mounted) return;
            // Keep permissions, but complete as a returning user afterward.
            setState(() {
              _nextScreen = SetupPermissionScreen(
                onComplete: () => _finishReturningSetup(session),
              );
            });
            return;
          }
          await _finishReturningSetup(session);
        }
        return;
      }

      await trialStart;
      logStartupMilestone('setup state resolved', stopwatch);
      // On every launch, verify critical permissions are still granted.
      // Users can revoke them between sessions via system settings.
      if (!await _requiredPermissionsGranted()) {
        if (!mounted) return;
        setState(() {
          _nextScreen = SetupPermissionScreen(
            onComplete: () => _finishReturningSetup(session),
          );
        });
        return;
      }
      await _markSetupComplete(session.userId);
      if (!mounted) return;
      if (_needsAvatarRefresh(session)) {
        _presentAvatarRefresh(session, groupsPrefetch: groupsPrefetch);
        return;
      }
      await _presentHomeOrTrialGate(
        session,
        groupsPrefetch: groupsPrefetch,
        stopwatch: stopwatch,
      );
    } catch (error, stack) {
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'startup_gate_failed',
        ),
      );
      if (!mounted) return;

      setState(() {
        _isLoggingIn = false;
        _startupError = error.toString();
      });
    }
  }

  /// Returns true when all permissions that the app needs to function are
  /// granted.  Microphone is mandatory; notification and battery-optimisation
  /// are strongly recommended but won't block launch — the red dot on the
  /// home screen will still flag them.
  Future<bool> _requiredPermissionsGranted() async {
    // Microphone is non-negotiable for voice sessions.
    return await Permission.microphone.isGranted;
  }

  void _presentNewUserPermissionSetup(IdentitySession session) {
    setState(() {
      _nextScreen = SetupPermissionScreen(
        onComplete: () async {
          if (!mounted) return;
          setState(() {
            _nextScreen = ProfilePictureScreen(
              session: session,
              identityRepository: _identityRepository,
              onComplete: (updatedSession) async {
                if (!mounted) return;
                setState(() {
                  _nextScreen = DisplayNameScreen(
                    session: updatedSession,
                    identityRepository: _identityRepository,
                    onComplete: () async {
                      final readySession = await _identityRepository
                          .ensureIdentity();
                      _readySession = readySession;
                      await _identityRepository.markSetupComplete();
                      await _markSetupComplete(readySession.userId);
                      if (!mounted) return;
                      await _presentHomeOrTrialGate(readySession);
                    },
                  );
                });
              },
            );
          });
        },
      );
    });
  }

  Future<void> _finishReturningSetup(IdentitySession session) async {
    await _markSetupComplete(session.userId);
    final readySession = await _identityRepository.ensureIdentity();
    _readySession = readySession;
    if (!mounted) return;
    if (_needsAvatarRefresh(readySession)) {
      _presentAvatarRefresh(readySession);
      return;
    }
    await _presentHomeOrTrialGate(readySession);
  }

  bool _needsAvatarRefresh(IdentitySession session) {
    return AvatarAssets.needsRefresh(
      avatarAsset: session.user.avatarAsset,
      profilePhotoUrl: session.user.profilePhotoUrl,
      profilePhotoBase64: session.user.profilePhotoBase64,
    );
  }

  void _presentAvatarRefresh(
    IdentitySession session, {
    Future<List<GroupSummary>>? groupsPrefetch,
  }) {
    setState(() {
      _nextScreen = ProfilePictureScreen(
        session: session,
        identityRepository: _identityRepository,
        refreshRetiredAvatar: true,
        onComplete: (updatedSession) async {
          _readySession = updatedSession;
          if (!mounted) return;
          await _presentHomeOrTrialGate(
            updatedSession,
            groupsPrefetch: groupsPrefetch,
          );
        },
      );
    });
  }

  /// Home, nudges and chat are free forever — the free trial only gates
  /// live voice, which is checked inline at the moment of connecting
  /// (`_goOnline` in `identity_home_presence.dart`) so it can show
  /// tailored receiver/sender copy plus the Duo Pro paywall right there.
  ///
  /// This method no longer blocks entry to home after the trial ends; it
  /// is kept (rather than inlined) so call sites and naming stay stable if
  /// a future startup-level check is reintroduced.
  Future<void> _presentHomeOrTrialGate(
    IdentitySession session, {
    Future<List<GroupSummary>>? groupsPrefetch,
    Stopwatch? stopwatch,
    String? preferredGroupId,
  }) async {
    await _presentHomeScreen(
      session,
      groupsPrefetch: groupsPrefetch,
      stopwatch: stopwatch,
      preferredGroupId: preferredGroupId,
    );
  }

  /// Keeps a Duo logo loader up while invite join + home prefetch finish, then
  /// transitions once the first home frame can render.
  Future<void> _presentHomeScreen(
    IdentitySession session, {
    Future<List<GroupSummary>>? groupsPrefetch,
    Stopwatch? stopwatch,
    String? preferredGroupId,
  }) async {
    final phase = stopwatch ?? (Stopwatch()..start());

    // Peek before kicking off a groups prefetch so a pending invite does not
    // race an empty membership index and flash the binoculars empty state.
    final pendingInviteCode = preferredGroupId == null
        ? await _inviteLinkBridge.peekPendingInviteCode()
        : null;
    final joiningFromInvite =
        preferredGroupId != null || pendingInviteCode != null;
    if (joiningFromInvite && mounted) {
      setState(() => _joiningInvite = true);
      await _awaitOverlayPaint();
    }

    late String? invitedGroupId;
    late List<GroupSummary> groups;
    try {
      if (preferredGroupId != null) {
        invitedGroupId = preferredGroupId;
        groups = await (groupsPrefetch ??
            _groupRepository.loadGroupsForUser(session.userId));
        groups = await _ensureJoinedGroupPresent(
          session.userId,
          invitedGroupId,
          groups,
        );
      } else if (pendingInviteCode != null) {
        // Join first, then load groups — one membership-aware fetch.
        invitedGroupId = await _joinPendingInvite();
        groups = await _groupRepository.loadGroupsForUser(session.userId);
        if (invitedGroupId != null) {
          groups = await _ensureJoinedGroupPresent(
            session.userId,
            invitedGroupId,
            groups,
          );
        }
      } else {
        groupsPrefetch ??= _groupRepository.loadGroupsForUser(session.userId);
        invitedGroupId = null;
        groups = await groupsPrefetch;
      }

      // Invite/nudge deep links always win. Otherwise, restore whichever group
      // the user was last active in before the app was killed; if that group
      // no longer exists, IdentityHomeBootstrap.resolveSelectedGroup silently
      // falls back to the first group.
      final preferredForBootstrap =
          invitedGroupId ?? await LastActiveGroupStore.read(session.userId);

      IdentityHomeBootstrap bootstrap;
      try {
        bootstrap = await IdentityHomeBootstrap.fromGroups(
          groupRepository: _groupRepository,
          groups: groups,
          preferredGroupId: preferredForBootstrap,
        );
      } catch (error) {
        bootstrap = IdentityHomeBootstrap.failure(error);
      }

      logStartupMilestone('home prefetch complete', phase);
      if (!mounted) return;

      // Never drop a just-joined invite user onto binoculars NoGroups while the
      // membership index is still catching up — keep the logo loader briefly.
      if (!bootstrap.hasGroups &&
          bootstrap.loadError == null &&
          invitedGroupId != null) {
        for (var attempt = 0; attempt < 3 && groups.isEmpty; attempt++) {
          await Future<void>.delayed(
            Duration(milliseconds: 200 * (attempt + 1)),
          );
          groups = await _groupRepository.loadGroupsForUser(session.userId);
        }
        try {
          bootstrap = await IdentityHomeBootstrap.fromGroups(
            groupRepository: _groupRepository,
            groups: groups,
            preferredGroupId: preferredForBootstrap,
          );
        } catch (error) {
          bootstrap = IdentityHomeBootstrap.failure(error);
        }
        if (!mounted) return;
      }

      if (!bootstrap.hasGroups && bootstrap.loadError == null) {
        setState(() {
          _joiningInvite = false;
          _nextScreen = NoGroupsScreen(
            session: session,
            identityRepository: _identityRepository,
          );
        });
      } else {
        setState(() {
          _joiningInvite = false;
          _nextScreen = IdentityHomeScreen(
            initialSession: session,
            identityRepository: _identityRepository,
            initialGroupId: preferredForBootstrap,
            initialBootstrap: bootstrap,
          );
        });
      }
      logStartupMilestone('Home route selected', phase);
      _showPendingInviteFeedback();
    } finally {
      // If we bailed early (unmounted / error before setState), drop the loader.
      if (mounted && _joiningInvite) {
        setState(() => _joiningInvite = false);
      }
    }
  }

  /// Reloads groups when the just-joined id is missing from a stale prefetch.
  Future<List<GroupSummary>> _ensureJoinedGroupPresent(
    String userId,
    String groupId,
    List<GroupSummary> groups,
  ) async {
    if (groups.any((group) => group.groupId == groupId)) return groups;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return _groupRepository.loadGroupsForUser(userId);
  }

  Future<bool> _hasCompletedSetup(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_setupCompleteKey(userId)) ?? false;
  }

  Future<void> _markSetupComplete(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_setupCompleteKey(userId), true);
  }

  String _setupCompleteKey(String userId) => 'one_one_setup_complete_$userId';

  Future<void> _handleIncomingInviteLink() async {
    final session = _readySession;
    if (session == null || _nextScreen is IdentityHomeScreen) return;
    // Startup present already owns join + navigation for this invite.
    if (_joiningInvite) {
      await _inviteJoinCompleter?.future;
      return;
    }
    if (!await _hasCompletedSetup(session.userId)) return;
    if (!mounted) return;
    // Paint the logo overlay on whatever is already showing (usually
    // binoculars) before the join network call starts.
    setState(() => _joiningInvite = true);
    await _awaitOverlayPaint();
    if (!mounted) return;
    final groupId = await _joinPendingInvite();
    if (!mounted) return;
    if (groupId != null) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      if (!mounted) return;
      await _presentHomeOrTrialGate(
        session,
        groupsPrefetch: _groupRepository.loadGroupsForUser(session.userId),
        preferredGroupId: groupId,
      );
    } else if (mounted) {
      setState(() => _joiningInvite = false);
    }
    _showPendingInviteFeedback();
  }

  /// Lets Flutter build + paint the overlay before we block on network I/O.
  Future<void> _awaitOverlayPaint() async {
    await SchedulerBinding.instance.endOfFrame;
    // One extra frame so the first overlay image decode is on screen.
    await SchedulerBinding.instance.endOfFrame;
  }

  Future<String?> _joinPendingInvite() async {
    final inFlight = _inviteJoinCompleter;
    if (inFlight != null) return inFlight.future;

    final inviteCode = await _inviteLinkBridge.peekPendingInviteCode();
    if (inviteCode == null) return null;

    final completer = Completer<String?>();
    _inviteJoinCompleter = completer;
    try {
      final groupId = await _groupRepository.joinInvite(inviteCode);
      await _inviteLinkBridge.clearPendingInviteCode(inviteCode);
      debugPrint(
        '[OneOneInvite] Joined pending invite groupSuffix='
        '${groupId.length <= 6 ? groupId : groupId.substring(groupId.length - 6)}',
      );
      _pendingInviteFeedback = true;
      completer.complete(groupId);
      return groupId;
    } catch (error, stack) {
      debugPrint(
        '[OneOneInvite] Pending invite failed ${error.runtimeType}: $error',
      );
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'pending_invite_join_failed',
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
      _pendingInviteFeedback = error is ApiException
          ? error.message
          : 'Couldn’t open this invite. Check your connection and try again.';
      completer.complete(null);
      return null;
    } finally {
      _inviteJoinCompleter = null;
    }
  }

  void _showPendingInviteFeedback() {
    final feedback = _pendingInviteFeedback;
    _pendingInviteFeedback = null;
    if (feedback == null) return;

    // Wait one frame so NoGroups / Home Scaffold is mounted under this gate.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (feedback == true) {
        showInviteJoinedSnackBar(context);
        return;
      }
      final message = feedback is String ? feedback.trim() : '';
      if (message.isEmpty) return;
      showInviteJoinErrorSnackBar(context, message);
    });
  }

  void _markNativeSplashReady() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      NativeSplashBridge.markReady();
    });
  }

  @override
  Widget build(BuildContext context) {
    final nextScreen = _nextScreen;

    // Overlay MUST win over `_nextScreen`. New users already have binoculars
    // (or an onboarding screen) assigned there; returning that first made
    // `_joiningInvite` a no-op, so the Duo loader never appeared.
    if (_joiningInvite) {
      _markNativeSplashReady();
      // Keep binoculars behind the loader. `_nextScreen` is often still the
      // last onboarding page, which would hide the logo against the wrong UI.
      final Widget behind;
      if (nextScreen is NoGroupsScreen || nextScreen is IdentityHomeScreen) {
        behind = nextScreen!;
      } else if (_readySession != null) {
        behind = NoGroupsScreen(
          session: _readySession!,
          identityRepository: _identityRepository,
        );
      } else {
        behind = nextScreen ?? const Scaffold(backgroundColor: Colors.black);
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          behind,
          const Positioned.fill(child: InviteJoinOverlay()),
        ],
      );
    }

    if (nextScreen != null) {
      // A real destination (permissions/onboarding/home/no-groups) is ready
      // — the native splash can come down now that there's real content
      // behind it, not another loader.
      _markNativeSplashReady();
      return nextScreen;
    }

    if (_startupError != null) {
      // Terminal error state with a retry action — also real, interactive
      // content, so drop the native splash here too.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        NativeSplashBridge.markReady();
      });
      return Scaffold(
        backgroundColor: BrandSplashScreen.backgroundColor,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 28.w),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    context.l10n.startupSetupFailed,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: const Color(0xff7a2f2f),
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 14.h),
                  OutlinedButton(
                    onPressed: _isLoggingIn ? null : _continueAfterLogin,
                    child: Text(context.l10n.startupTryAgain),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // Cold start: native splash still covers this, so brand yellow is fine.
    // Post Google sign-in: splash is already gone — paint the full mic-step
    // chrome (art + CTA) so the handoff into SetupPermissionScreen does not
    // flash brand yellow or pop the mic button in late.
    if (NativeSplashBridge.isReady) {
      return SetupPermissionScreen.firstStepUnderlay(context);
    }
    return const BrandSplashScreen();
  }
}
