import 'package:one_one_app/one_one.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.session,
    required this.identityRepository,
    this.manageableGroups = const [],
    this.onManageGroup,
  });

  final IdentitySession session;
  final IdentityRepository identityRepository;

  /// Groups this user created (owner). Empty when none are manageable.
  final List<GroupSummary> manageableGroups;

  /// Opens management for the chosen group. Returns true when the group
  /// membership ended (left/deleted) so Settings can close if needed.
  final Future<bool> Function(GroupSummary group)? onManageGroup;

  /// Opens settings drifting in from the left (settings control side).
  static Future<void> open(
    BuildContext context, {
    required IdentitySession session,
    required IdentityRepository identityRepository,
    List<GroupSummary> manageableGroups = const [],
    Future<bool> Function(GroupSummary group)? onManageGroup,
  }) {
    return Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        opaque: true,
        barrierColor: const Color(0xff101010),
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (context, animation, secondaryAnimation) {
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle.light,
            child: ColoredBox(
              color: const Color(0xff101010),
              child: SettingsScreen(
                session: session,
                identityRepository: identityRepository,
                manageableGroups: manageableGroups,
                onManageGroup: onManageGroup,
              ),
            ),
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              // From the left edge where the settings icon sits — not bottom-up.
              position: Tween<Offset>(
                begin: const Offset(-0.22, 0),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late IdentitySession _session = widget.session;
  late String _accentColorKey = _session.settings.accentColorKey;
  late HapticsIntensity _hapticsIntensity = _session.settings.hapticsIntensity;
  late String _persistedAccentColorKey = _session.settings.accentColorKey;
  bool _saving = false;
  bool _accountActionInProgress = false;
  bool _hasUnsavedAccentPreview = false;
  int _titleTapCount = 0;
  DateTime? _lastTitleTapAt;

  /// While true, never rebuild this route from session listenable updates —
  /// parent rebuilds during the edit-profile sheet's deactivate race
  /// `_dependents.isEmpty` assertions.
  bool _profileEditorOpen = false;
  String? _message;
  DuoAccessSnapshot? _duoAccess;
  String? _appVersion;

  Future<List<AvatarAsset>>? _avatarsFuture;

  @override
  void initState() {
    super.initState();
    unawaited(
      AnalyticsService.logScreenView(
        screenName: 'settings',
        screenClass: 'SettingsScreen',
      ),
    );
    _avatarsFuture = AvatarAssets.loadAll();
    unawaited(HomeVisualVariantController.ensureLoaded());
    unawaited(_loadAppVersion());
    unawaited(_loadDuoAccess());
    final currentSession = widget.identityRepository.currentSession;
    if (currentSession != null && currentSession.userId == _session.userId) {
      _session = currentSession;
      _accentColorKey = currentSession.settings.accentColorKey;
      _hapticsIntensity = currentSession.settings.hapticsIntensity;
      _persistedAccentColorKey = currentSession.settings.accentColorKey;
    }
    try {
      widget.identityRepository.sessionListenable.addListener(
        _onRepositorySessionChanged,
      );
    } catch (_) {
      // The session listenable may be in a partially-disposed state during
      // navigation transitions. The screen still works with the session
      // captured from the constructor above.
    }
  }

  @override
  void dispose() {
    try {
      widget.identityRepository.sessionListenable.removeListener(
        _onRepositorySessionChanged,
      );
    } catch (_) {
      // Best-effort cleanup when the listenable is already torn down.
    }
    if (_hasUnsavedAccentPreview) {
      AccentThemeController.setAccentKey(_persistedAccentColorKey);
    }
    super.dispose();
  }

  void _onRepositorySessionChanged() {
    final session = widget.identityRepository.currentSession;
    if (!mounted || session == null || session.userId != _session.userId) {
      return;
    }
    // Keep data fresh without rebuilding while the edit-profile sheet (or its
    // nested photo picker) owns modal elements under this route.
    if (_profileEditorOpen) {
      _session = session;
      return;
    }
    // Defer: same-frame notify during an awaited save/pop can race Elements
    // that are mid-deactivate (_dependents.isEmpty).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _profileEditorOpen) return;
      final latest = widget.identityRepository.currentSession;
      if (latest == null || latest.userId != _session.userId) return;
      setState(() => _session = latest);
    });
  }

  bool get _hasUnsavedSettings => _accentColorKey != _persistedAccentColorKey;

  void _acceptSession(IdentitySession session) {
    _session = session;
  }

  /// Edit Profile: display name + full avatar/photo section. Saves via a
  /// pinned floating bar so the user never has to scroll to find it.
  Future<void> _openProfileEditor() async {
    _profileEditorOpen = true;
    _EditProfileSheetResult? result;
    try {
      result = await DuoSheet.show<_EditProfileSheetResult>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (sheetContext) {
          return _EditProfileSheet(
            session: _session,
            accentColorKey: _accentColorKey,
            avatarsFuture: _avatarsFuture,
            identityRepository: widget.identityRepository,
          );
        },
      );
    } finally {
      // Stay "open" for one more frame after the route is gone so any
      // deferred session listenable callbacks still skip setState while
      // modal dependents are clearing.
    }

    if (!mounted) {
      _profileEditorOpen = false;
      return;
    }

    // Two end-of-frame waits: (1) modal route dispose, (2) InheritedElement
    // dependent bookkeeping. Avoid `_dependents.isEmpty` races.
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(Duration.zero);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      _profileEditorOpen = false;
      return;
    }

    final latest = widget.identityRepository.currentSession;
    setState(() {
      if (result?.session != null) {
        _acceptSession(result!.session!);
      } else if (latest != null && latest.userId == _session.userId) {
        _acceptSession(latest);
      }
      if (result?.message != null) {
        _message = result!.message;
      }
      _profileEditorOpen = false;
    });
  }

  void _handleSettingsTitleTap() {
    final now = DateTime.now();
    final last = _lastTitleTapAt;
    if (last == null || now.difference(last) > const Duration(seconds: 2)) {
      _titleTapCount = 1;
    } else {
      _titleTapCount += 1;
    }
    _lastTitleTapAt = now;
    if (_titleTapCount >= 7) {
      _titleTapCount = 0;
      unawaited(HomeVisualVariantController.unlockTesting());
      if (mounted) {
        setState(() => _message = context.l10n.settingsTestingUnlocked);
      }
    }
  }

  Future<void> _setAppLanguage(AppLanguage language) async {
    await LocaleController.setLanguage(language);
    try {
      final session = await widget.identityRepository.updateSettings(
        preferredLocale: language.languageCode,
      );
      if (!mounted) return;
      setState(() => _acceptSession(session));
    } catch (error, stack) {
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'settings_language_save_failed',
          feature: 'settings',
          screenName: 'settings',
        ),
      );
    }
  }

  Future<void> _setHapticsIntensity(HapticsIntensity value) async {
    if (_hapticsIntensity == value || _saving) return;
    final previous = _hapticsIntensity;
    setState(() {
      _hapticsIntensity = value;
      _message = null;
    });
    unawaited(_previewHaptics(value));
    try {
      final session = await widget.identityRepository.updateSettings(
        hapticsIntensity: value,
      );
      if (!mounted) return;
      setState(() => _acceptSession(session));
    } catch (error, stack) {
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'settings_haptics_save_failed',
          feature: 'settings',
          screenName: 'settings',
        ),
      );
      if (!mounted) return;
      setState(() {
        _hapticsIntensity = previous;
        _message = error.toString();
      });
    }
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _appVersion = '${info.version}+${info.buildNumber}';
      });
    } catch (_) {
      // Version footer is best-effort.
    }
  }

  Future<void> _previewHaptics(HapticsIntensity value) async {
    await NudgeHaptics.playStart(value);
    if (value == HapticsIntensity.wild) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      NudgeHaptics.stopWild();
    }
  }

  Future<void> _saveAccentColor() async {
    unawaited(
      CrashlyticsService.log(
        'settings_prefs_save_start accent=$_accentColorKey',
      ),
    );
    setState(() {
      _saving = true;
      _message = null;
    });

    try {
      final session = await widget.identityRepository.updateSettings(
        accentColorKey: _accentColorKey,
      );
      unawaited(CrashlyticsService.log('settings_prefs_save_network_ok'));
      _persistedAccentColorKey = session.settings.accentColorKey;
      _hasUnsavedAccentPreview = false;
      // Apply accent after local flags are consistent; no-op if already set.
      AccentThemeController.setAccentKey(session.settings.accentColorKey);
      unawaited(CrashlyticsService.log('settings_prefs_accent_applied'));
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(CrashlyticsService.log('settings_prefs_save_setState'));
        setState(() {
          _acceptSession(session);
          _message = context.l10n.settingsSaved;
          _saving = false;
        });
      });
    } catch (error, stack) {
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'settings_prefs_save_failed',
          feature: 'settings',
          screenName: 'settings',
        ),
      );
      if (!mounted) return;
      setState(() {
        _message = error.toString();
        _saving = false;
      });
    }
  }

  String get _signedInEmail {
    final user = FirebaseAuth.instance.currentUser;
    final directEmail = user?.email?.trim();
    if (directEmail != null && directEmail.isNotEmpty) return directEmail;
    for (final provider in user?.providerData ?? const <UserInfo>[]) {
      final email = provider.email?.trim();
      if (email != null && email.isNotEmpty) return email;
    }
    return context.l10n.settingsGoogleAccount;
  }

  Future<void> _logOut() async {
    final l10n = context.l10n;
    final confirmed = await _confirmAccountAction(
      title: l10n.settingsLogOutTitle,
      message: l10n.settingsLogOutMessage,
      actionLabel: l10n.settingsLogOut,
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _accountActionInProgress = true;
      _message = null;
    });
    try {
      await widget.identityRepository.signOut();
      _goToWelcomeScreen();
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _accountActionInProgress = false);
    }
  }

  Future<void> _deleteAccount() async {
    final l10n = context.l10n;
    final confirmed = await _confirmAccountAction(
      title: l10n.settingsDeleteAccountTitle,
      message: l10n.settingsDeleteAccountMessage,
      actionLabel: l10n.settingsDeleteAccount,
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _accountActionInProgress = true;
      _message = null;
    });
    try {
      await widget.identityRepository.deleteAccount();
      // Use the root navigator — account purge can empty userGroups and race
      // Home into popping this Settings route before delete finishes, so
      // [mounted] may already be false here.
      _goToWelcomeScreen();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = context.l10n.settingsDeleteAccountFailed;
      });
    } finally {
      if (mounted) setState(() => _accountActionInProgress = false);
    }
  }

  void _goToWelcomeScreen() {
    final navigator = appNavigatorKey.currentState;
    if (navigator != null) {
      navigator.pushNamedAndRemoveUntil('/auth', (_) => false);
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/auth', (_) => false);
  }

  Future<bool> _confirmAccountAction({
    required String title,
    required String message,
    required String actionLabel,
    bool destructive = false,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(context.l10n.settingsCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                style: destructive
                    ? FilledButton.styleFrom(
                        backgroundColor: const Color(0xffb3261e),
                        foregroundColor: Colors.white,
                      )
                    : null,
                child: Text(actionLabel),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _openLegalDocument(LegalDocument document) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LegalDocumentScreen(document: document),
      ),
    );
  }

  Future<void> _openGroupManagement() async {
    final groups = widget.manageableGroups;
    final onManage = widget.onManageGroup;
    if (groups.isEmpty || onManage == null) return;

    final selected = await DuoSheet.show<GroupSummary>(
      context: context,
      builder: (sheetContext) {
        return BottomSystemSafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DuoSheetTitle(context.l10n.settingsManageGroup),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: DuoSheetCard(
                    children: [
                      for (var i = 0; i < groups.length; i++) ...[
                        ListTile(
                          onTap: () =>
                              Navigator.of(sheetContext).pop(groups[i]),
                          leading: const Icon(
                            LucideIcons.users,
                            color: Colors.white70,
                            size: 20,
                          ),
                          title: Text(
                            groups[i].name,
                            style: const TextStyle(color: Colors.white),
                          ),
                          trailing: const Icon(
                            LucideIcons.chevronRight,
                            color: Colors.white38,
                            size: 18,
                          ),
                        ),
                        if (i != groups.length - 1)
                          Divider(
                            height: 1,
                            indent: 56,
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (selected == null || !mounted) return;

    final groupEnded = await onManage(selected);
    if (groupEnded && mounted) Navigator.of(context).pop();
  }

  Future<void> _loadDuoAccess() async {
    final snapshot = await FreeTrialAccess.snapshot(userId: _session.userId);
    if (!mounted) return;
    setState(() => _duoAccess = snapshot);
  }

  String _duoProSubtitle(AppLocalizations l10n) {
    final access = _duoAccess;
    if (access == null) return l10n.settingsViewPlans;
    if (access.entitledToPro) return l10n.settingsDuoProActiveSubtitle;
    if (access.trialActive) {
      final days = FreeTrialAccess.remainingWholeDays(access.remaining);
      if (days <= 0) return l10n.settingsTrialLessThanADay;
      if (days == 1) return l10n.settingsTrialOneDayLeft;
      return l10n.settingsTrialDaysLeft(days);
    }
    return l10n.settingsFreePlanSubtitle;
  }

  bool _openingPaywall = false;

  /// Opens the in-app Duo Pro paywall (branded UI + RevenueCat packages).
  Future<void> _showPaywall() async {
    if (_openingPaywall) return;
    setState(() => _openingPaywall = true);
    unawaited(
      AnalyticsService.logButtonClick(
        buttonName: 'duo_pro',
        screenName: 'settings',
      ),
    );
    unawaited(
      AnalyticsService.logFeatureSelected(
        feature: 'paywall',
        screenName: 'settings',
      ),
    );
    try {
      final openFuture = ElevenProPaywallScreen.open(context);
      // Brief settings-side spinner until the Duo Pro route covers us.
      await Future<void>.delayed(const Duration(milliseconds: 160));
      if (mounted) setState(() => _openingPaywall = false);
      final purchased = await openFuture;
      if (!mounted) return;
      await _loadDuoAccess();
      if (purchased) {
        setState(() => _message = context.l10n.settingsWelcomeDuoPro);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _openingPaywall = false;
        _message = context.l10n.settingsPaywallFailed;
      });
      debugPrint('Paywall error: $error');
    }
  }

  /// Opens Gmail compose to Team Duo.
  Future<void> _contactTeamDuo() {
    return SubscriptionManagementSheet.contactTeamDuo(context);
  }

  bool _permissionRequestInFlight = false;

  /// Re-triggers the mic permission prompt, then refreshes the device record
  /// so the settings checklist reflects the grant.
  Future<void> _requestMicPermission() async {
    if (_permissionRequestInFlight) return;
    _permissionRequestInFlight = true;
    try {
      final status = await Permission.microphone.request();
      if (!mounted) return;
      setState(
        () => _message = status.isGranted
            ? context.l10n.settingsMicGranted
            : context.l10n.settingsMicDenied,
      );
      await _refreshPermissions();
    } finally {
      _permissionRequestInFlight = false;
    }
  }

  /// Re-triggers the notification permission prompt, then refreshes the
  /// device record so the settings checklist reflects the grant.
  Future<void> _requestNotificationPermission() async {
    if (_permissionRequestInFlight) return;
    _permissionRequestInFlight = true;
    try {
      final status = await Permission.notification.request();
      if (!mounted) return;
      setState(
        () => _message = status.isGranted
            ? context.l10n.settingsNotificationGranted
            : context.l10n.settingsNotificationDenied,
      );
      await _refreshPermissions();
    } finally {
      _permissionRequestInFlight = false;
    }
  }

  /// Re-triggers the battery optimization request, then refreshes the device
  /// record so the settings checklist reflects the grant.
  Future<void> _requestBatteryOptimization() async {
    if (_permissionRequestInFlight) return;
    _permissionRequestInFlight = true;
    try {
      try {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      } catch (_) {
        // Best effort — the user can enable it from Android Settings.
      }
      if (!mounted) return;
      setState(() => _message = context.l10n.settingsBatteryRequestSent);
      await _refreshPermissions();
    } finally {
      _permissionRequestInFlight = false;
    }
  }

  /// Re-reads the live permission state and publishes the updated session so
  /// the checklist checkboxes reflect what was just granted.
  Future<void> _refreshPermissions() async {
    try {
      await widget.identityRepository.ensureIdentity();
    } catch (_) {
      // Best-effort — the checklist still shows the session we already have.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final accent = accentColorForKey(_accentColorKey);
    final showSaveButton = _hasUnsavedSettings || _saving;

    return Scaffold(
      backgroundColor: const Color(0xff101010),
      extendBodyBehindAppBar: false,
      appBar: AppBar(
        backgroundColor: const Color(0xff101010),
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        // Empty center hit-target keeps the hidden testing unlock (7 taps).
        title: GestureDetector(
          onTap: _handleSettingsTitleTap,
          behavior: HitTestBehavior.opaque,
          child: const SizedBox(width: 120, height: 40),
        ),
        centerTitle: true,
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.25),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: showSaveButton
            ? SafeArea(
                key: const ValueKey('save-settings-floating-button'),
                minimum: const EdgeInsets.symmetric(horizontal: 20),
                child: SizedBox(
                  width: MediaQuery.sizeOf(context).width - 40,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _saveAccentColor,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                      backgroundColor: accent,
                      foregroundColor: Colors.black,
                    ),
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 19,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : const Icon(Icons.check_rounded),
                    label: Text(l10n.settingsSaveColor),
                  ),
                ),
              )
            : const SizedBox.shrink(
                key: ValueKey('save-settings-button-hidden'),
              ),
      ),
      body: ColoredBox(
        color: const Color(0xff101010),
        child: SafeArea(
          top: false,
          child: ListView(
            padding: EdgeInsets.fromLTRB(20, 8, 20, showSaveButton ? 104 : 28),
            children: [
              _ProfileHeader(
                session: _session,
                enabled: !_saving && !_profileEditorOpen,
                onEditProfile: _openProfileEditor,
              ),
              const SizedBox(height: 18),
              _SettingsBlock(
                title: l10n.settingsSectionSubscription,
                child: _SettingsSurface(
                  padding: EdgeInsets.zero,
                  children: [
                    _ElevenProSettingsCard(
                      onTap: _openingPaywall ? null : _showPaywall,
                      subtitle: _duoProSubtitle(l10n),
                      loading: _openingPaywall,
                    ),
                    const _SurfaceDivider(indent: 56),
                    _NavigationRow(
                      icon: LucideIcons.mail,
                      label: l10n.subContactTeam,
                      onTap: _contactTeamDuo,
                    ),
                  ],
                ),
              ),
              if (widget.manageableGroups.isNotEmpty &&
                  widget.onManageGroup != null)
                _SettingsBlock(
                  title: l10n.settingsSectionGroup,
                  child: _SettingsSurface(
                    padding: EdgeInsets.zero,
                    children: [
                      _NavigationRow(
                        icon: LucideIcons.users,
                        label: l10n.settingsManageGroup,
                        onTap: _openGroupManagement,
                      ),
                    ],
                  ),
                ),
              _SettingsBlock(
                title: l10n.settingsSectionPreferences,
                child: _SettingsSurface(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                  children: [
                    _PreferenceHeading(
                      icon: LucideIcons.palette,
                      title: l10n.settingsAccentColorTitle,
                    ),
                    const SizedBox(height: 16),
                    _AccentBlobPicker(
                      selectedKey: _accentColorKey,
                      enabled: !_saving,
                      onSelected: (option) {
                        setState(() {
                          _accentColorKey = option.key;
                          _hasUnsavedAccentPreview =
                              option.key != _persistedAccentColorKey;
                        });
                        AccentThemeController.setAccentKey(option.key);
                      },
                    ),
                    const _SurfaceDivider(height: 32),
                    _PreferenceHeading(
                      icon: LucideIcons.vibrate,
                      title: l10n.settingsHapticsTitle,
                    ),
                    const SizedBox(height: 14),
                    _HapticsTierRow(
                      selected: _hapticsIntensity,
                      accent: accent,
                      enabled: !_saving,
                      onSelected: _setHapticsIntensity,
                    ),
                    const _SurfaceDivider(height: 32),
                    _PreferenceHeading(
                      icon: LucideIcons.image,
                      title: l10n.settingsHomeBackgroundTitle,
                    ),
                    const SizedBox(height: 14),
                    ValueListenableBuilder<HomeVisualVariant>(
                      valueListenable: HomeVisualVariantController.current,
                      builder: (context, variant, _) {
                        return _HomeBackgroundOptionRow(
                          illustrated: variant.isIllustrated,
                          accent: accent,
                          session: _session,
                          enabled: !_saving,
                          onSelected: (illustrated) => unawaited(
                            HomeVisualVariantController.setIllustrated(
                              illustrated,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              SettingsLanguageSection(
                accent: accent,
                onLanguageSelected: _setAppLanguage,
              ),
              ValueListenableBuilder<bool>(
                valueListenable: HomeVisualVariantController.unlocked,
                builder: (context, testingUnlocked, _) {
                  if (!testingUnlocked || !kDebugMode) {
                    return const SizedBox.shrink();
                  }
                  return DebugMarketPanel(accent: accent);
                },
              ),
              _SettingsBlock(
                title: l10n.settingsSectionBackground,
                child: _SettingsSurface(
                  padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
                  children: [
                    _ReliabilityRow(
                      stickerAsset: 'assets/duo_stickers/mic.png',
                      ok: _session.device.micPermissionGranted,
                      label: l10n.settingsMicPermission,
                      detail: _session.device.micPermissionGranted
                          ? l10n.settingsMicReady
                          : l10n.settingsMicRequired,
                      onTap: _requestMicPermission,
                    ),
                    const _SurfaceDivider(indent: 52),
                    _ReliabilityRow(
                      stickerAsset: 'assets/duo_stickers/bell.png',
                      ok: _session.device.notificationPermissionGranted,
                      label: l10n.settingsNotificationPermission,
                      detail: _session.device.notificationPermissionGranted
                          ? l10n.settingsNotificationReady
                          : l10n.settingsNotificationRequired,
                      onTap: _requestNotificationPermission,
                    ),
                    const _SurfaceDivider(indent: 52),
                    _ReliabilityRow(
                      stickerAsset: 'assets/duo_stickers/headset.png',
                      ok: _session.device.batteryOptimizationIgnored,
                      label: l10n.settingsBatteryOptimization,
                      detail: _session.device.batteryOptimizationIgnored
                          ? l10n.settingsBatteryUnrestricted
                          : l10n.settingsBatteryMayInterrupt,
                      onTap: _requestBatteryOptimization,
                    ),
                  ],
                ),
              ),
              _SettingsBlock(
                title: l10n.settingsSectionSupport,
                child: _SettingsSurface(
                  padding: EdgeInsets.zero,
                  children: [
                    _NavigationRow(
                      icon: LucideIcons.messageCircle,
                      label: l10n.settingsSendFeedback,
                      onTap: () => showSendFeedbackSheet(
                        context,
                        userId: _session.userId,
                      ),
                    ),
                    ValueListenableBuilder<bool>(
                      valueListenable: HomeVisualVariantController.unlocked,
                      builder: (context, unlocked, _) {
                        if (!unlocked) return const SizedBox.shrink();
                        return Column(
                          children: [
                            const _SurfaceDivider(indent: 52),
                            _NavigationRow(
                              icon: LucideIcons.bug,
                              label: l10n.settingsDebugLogs,
                              onTap: () => showDebugLogsSheet(context),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: HomeVisualVariantController.unlocked,
                builder: (context, testingUnlocked, _) {
                  if (!testingUnlocked) return const SizedBox.shrink();
                  return _SettingsBlock(
                    title: l10n.settingsTestingSection,
                    child: ValueListenableBuilder<HomeVisualVariant>(
                      valueListenable: HomeVisualVariantController.current,
                      builder: (context, variant, _) {
                        return _SettingsSurface(
                          children: [
                            for (final option in HomeVisualVariant.values) ...[
                              _TestingVariantRow(
                                variant: option,
                                selected: variant == option,
                                accent: accent,
                                onTap: () => unawaited(
                                  HomeVisualVariantController.setVariant(
                                    option,
                                  ),
                                ),
                              ),
                              if (option != HomeVisualVariant.values.last)
                                const _SurfaceDivider(),
                            ],
                          ],
                        );
                      },
                    ),
                  );
                },
              ),
              _SettingsBlock(
                title: l10n.settingsSectionAccount,
                child: _SettingsSurface(
                  padding: EdgeInsets.zero,
                  children: [
                    _NavigationRow(
                      icon: LucideIcons.user,
                      label: _signedInEmail,
                      detail: l10n.settingsSignedInWithGoogle,
                      showChevron: false,
                    ),
                    const _SurfaceDivider(indent: 52),
                    _NavigationRow(
                      icon: LucideIcons.logOut,
                      label: l10n.settingsLogOut,
                      onTap: _accountActionInProgress ? null : _logOut,
                      trailing: _accountActionInProgress
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : null,
                    ),
                    const _SurfaceDivider(indent: 52),
                    _NavigationRow(
                      icon: LucideIcons.trash2,
                      label: l10n.settingsDeleteAccount,
                      onTap: _accountActionInProgress ? null : _deleteAccount,
                      destructive: true,
                    ),
                  ],
                ),
              ),
              _SettingsBlock(
                title: l10n.settingsSectionLegal,
                child: _SettingsSurface(
                  padding: EdgeInsets.zero,
                  children: [
                    _NavigationRow(
                      icon: LucideIcons.scrollText,
                      label: l10n.settingsTerms,
                      onTap: () => _openLegalDocument(LegalDocument.terms),
                    ),
                    const _SurfaceDivider(indent: 52),
                    _NavigationRow(
                      icon: LucideIcons.shield,
                      label: l10n.settingsPrivacy,
                      onTap: () => _openLegalDocument(LegalDocument.privacy),
                    ),
                  ],
                ),
              ),
              if (_message != null) ...[
                Text(
                  _message!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 12),
              ],
              if (_appVersion != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    l10n.settingsAppVersion(_appVersion!),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.38),
                      fontSize: 11,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

InputDecoration _darkInputDecoration(String label) {
  return InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(color: Colors.white60),
    filled: true,
    fillColor: Colors.white.withValues(alpha: 0.06),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: Colors.white24),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: Colors.white70),
    ),
  );
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({
    required this.session,
    required this.enabled,
    required this.onEditProfile,
  });

  final IdentitySession session;
  final bool enabled;
  final VoidCallback onEditProfile;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          width: 128,
          height: 128,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              GestureDetector(
                onTap: enabled ? onEditProfile : null,
                child: _ImageTintedAvatar(session: session, radius: 44),
              ),
              Positioned(
                right: 12,
                bottom: 12,
                child: _EditBadge(
                  enabled: enabled,
                  tooltip: context.l10n.settingsEditProfile,
                  onTap: onEditProfile,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          session.user.displayName,
          maxLines: 1,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// Outline and halo sampled from the avatar/photo itself so the ring always
/// tracks the image, not the app accent.
class _ImageTintedAvatar extends StatelessWidget {
  const _ImageTintedAvatar({required this.session, required this.radius});

  final IdentitySession session;
  final double radius;

  static const _gap = Color(0xff101010);

  /// Push saturation/brightness so the sliver of image used as the ring
  /// reads as a color wash of the face, not a second copy of it.
  static const _ringFilter = ColorFilter.matrix(<double>[
    1.55,
    -0.18,
    -0.12,
    0,
    16,
    -0.14,
    1.55,
    -0.12,
    0,
    16,
    -0.10,
    -0.16,
    1.55,
    0,
    16,
    0,
    0,
    0,
    1,
    0,
  ]);

  Widget _face(double r) {
    return ProfileAvatar(
      profilePhotoUrl: session.user.profilePhotoUrl,
      profilePhotoBase64: session.user.profilePhotoBase64,
      avatarAsset: session.user.avatarAsset,
      radius: r,
      backgroundColor: const Color(0xff2b2b2b),
      fallback: Icon(
        Icons.person_outline,
        color: Colors.white54,
        size: r * 0.9,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const ring = 4.5;
    final outer = radius + ring;
    return SizedBox(
      width: outer * 2,
      height: outer * 2,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Opacity(
              opacity: 0.72,
              child: Transform.scale(scale: 1.06, child: _face(outer)),
            ),
          ),
          ColorFiltered(colorFilter: _ringFilter, child: _face(outer)),
          Container(
            width: (radius + 2) * 2,
            height: (radius + 2) * 2,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: _gap,
            ),
          ),
          _face(radius),
        ],
      ),
    );
  }
}

class _EditBadge extends StatelessWidget {
  const _EditBadge({
    required this.enabled,
    required this.tooltip,
    required this.onTap,
  });

  final bool enabled;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: 32,
            height: 32,
            child: ClipOval(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withValues(alpha: 0.52),
                        Colors.white.withValues(alpha: 0.14),
                      ],
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.62),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        top: 3,
                        left: 5,
                        child: Container(
                          width: 10,
                          height: 5,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(99),
                            color: Colors.white.withValues(alpha: 0.55),
                          ),
                        ),
                      ),
                      const Center(
                        child: Icon(
                          LucideIcons.pencil,
                          size: 13,
                          color: Colors.white,
                        ),
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

class _EditProfileSheetResult {
  const _EditProfileSheetResult({this.session, this.message});

  final IdentitySession? session;
  final String? message;
}

/// Self-contained edit-profile sheet. Owns the [TextEditingController] so
/// dispose is tied to the modal route's element tree — not a parent callback
/// that can fire while the field is still listening.
class _EditProfileSheet extends StatefulWidget {
  const _EditProfileSheet({
    required this.session,
    required this.accentColorKey,
    required this.avatarsFuture,
    required this.identityRepository,
  });

  final IdentitySession session;
  final String accentColorKey;
  final Future<List<AvatarAsset>>? avatarsFuture;
  final IdentityRepository identityRepository;

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  late final TextEditingController _nameController;
  late IdentitySession _session;
  String? _pendingAvatarAsset;
  late _AvatarSectionMode _avatarSectionMode;
  bool _saving = false;
  bool _changingPhoto = false;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _nameController = TextEditingController(text: _session.user.displayName);
    _avatarSectionMode = _session.user.avatarAsset != null
        ? _AvatarSectionMode.avatar
        : _AvatarSectionMode.photo;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<Uint8List?> _pickPhoto({
    required bool recropCurrent,
    required String? currentUrl,
  }) {
    if (recropCurrent) {
      return ProfilePhotoEditor.recropNetworkPhoto(context, currentUrl!);
    }
    return ProfilePhotoEditor.pickAndCrop(context);
  }

  /// Drop focus first so [TextField] detaches cleanly before route pop.
  Future<void> _popSheet(_EditProfileSheetResult result) async {
    FocusManager.instance.primaryFocus?.unfocus();
    // Let the field process unfocus before the element tree starts deactivating.
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  Future<void> _changePhoto() async {
    if (_saving || _changingPhoto) return;
    setState(() => _changingPhoto = true);
    try {
      unawaited(CrashlyticsService.log('settings_edit_profile_photo_start'));
      final bytes = await _pickPhoto(
        recropCurrent: false,
        currentUrl: _session.user.profilePhotoUrl,
      );
      if (bytes == null || !mounted) return;
      final session = await widget.identityRepository.updateProfilePhoto(bytes);
      unawaited(
        CrashlyticsService.log('settings_edit_profile_photo_network_ok'),
      );
      if (!mounted) return;
      setState(() {
        _session = session;
        _pendingAvatarAsset = null;
        _avatarSectionMode = _AvatarSectionMode.photo;
      });
    } catch (error, stack) {
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'settings_edit_profile_photo_failed',
          feature: 'settings',
          screenName: 'settings',
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _changingPhoto = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final displayName = _nameController.text.trim();
    final nameChanged =
        displayName.isNotEmpty && displayName != _session.user.displayName;
    final avatarChanged =
        _pendingAvatarAsset != null &&
        _pendingAvatarAsset != _session.user.avatarAsset;

    if (!nameChanged && !avatarChanged) {
      unawaited(CrashlyticsService.log('settings_edit_profile_pop_no_change'));
      if (!mounted) return;
      await _popSheet(_EditProfileSheetResult(session: _session));
      return;
    }

    unawaited(
      CrashlyticsService.log(
        'settings_edit_profile_save_start '
        'name=$nameChanged avatar=$avatarChanged',
      ),
    );
    setState(() => _saving = true);
    try {
      var session = _session;
      if (nameChanged) {
        session = await widget.identityRepository.updateDisplayName(
          displayName,
        );
        unawaited(
          CrashlyticsService.log('settings_edit_profile_name_network_ok'),
        );
      }
      if (avatarChanged) {
        session = await widget.identityRepository.updatePresetAvatar(
          _pendingAvatarAsset!,
        );
        unawaited(
          CrashlyticsService.log('settings_edit_profile_avatar_network_ok'),
        );
      }
      if (!mounted) return;
      unawaited(CrashlyticsService.log('settings_edit_profile_pop'));
      // Capture results and close before any parent setState can race modal
      // deactivation. Local state is enough for this frame; the parent applies
      // the returned session after the route is fully gone.
      await _popSheet(
        _EditProfileSheetResult(
          session: session,
          message: context.l10n.settingsProfileUpdated,
        ),
      );
    } catch (error, stack) {
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'settings_edit_profile_save_failed',
          feature: 'settings',
          screenName: 'settings',
        ),
      );
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final accent = accentColorForKey(widget.accentColorKey);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final draftAsset = _pendingAvatarAsset ?? _session.user.avatarAsset;
    final nameTrimmed = _nameController.text.trim();
    final nameChanged =
        nameTrimmed.isNotEmpty && nameTrimmed != _session.user.displayName;
    final avatarChanged =
        _pendingAvatarAsset != null &&
        _pendingAvatarAsset != _session.user.avatarAsset;
    final hasChanges = nameChanged || avatarChanged;
    final busy = _saving || _changingPhoto;

    return Padding(
      padding: EdgeInsets.only(
        bottom: keyboardInset + bottomSystemInsetOf(context),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 8, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.settingsEditProfile,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          if (AvatarAssets.isRetiredAvatarPath(
                            draftAsset ?? '',
                          )) ...[
                            const SizedBox(height: 6),
                            Text(
                              l10n.chooseAvatarRefreshSubtitle,
                              style: const TextStyle(color: Colors.white60),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.settingsClose,
                    onPressed: busy
                        ? null
                        : () => unawaited(
                            _popSheet(
                              _EditProfileSheetResult(session: _session),
                            ),
                          ),
                    icon: const Icon(Icons.close_rounded),
                    color: Colors.white70,
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
                children: [
                  TextField(
                    controller: _nameController,
                    autofocus: false,
                    maxLength: AppUserProfile.maxDisplayNameLength,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: busy ? null : (_) => _save(),
                    style: const TextStyle(color: Colors.white),
                    decoration: _darkInputDecoration(
                      l10n.settingsDisplayName,
                    ).copyWith(counterText: ''),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    l10n.settingsAvatarSection,
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _AvatarSection(
                    mode: _avatarSectionMode,
                    onModeChanged: (mode) =>
                        setState(() => _avatarSectionMode = mode),
                    avatarsFuture: widget.avatarsFuture,
                    selectedAsset: draftAsset,
                    accent: accent,
                    avatarSaving: _saving,
                    onAvatarSelected: (asset) {
                      setState(() {
                        _pendingAvatarAsset = asset;
                        _avatarSectionMode = _AvatarSectionMode.avatar;
                      });
                    },
                    showSaveAvatar: false,
                    onSaveAvatar: () {},
                    profilePhotoUrl: _session.user.profilePhotoUrl,
                    profilePhotoBase64: _session.user.profilePhotoBase64,
                    photoSaving: _changingPhoto,
                    onChangePhoto: _changePhoto,
                    enabled: !busy,
                  ),
                ],
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xff161616),
                border: Border(
                  top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 18,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                  child: FilledButton.icon(
                    onPressed: busy ? null : _save,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      backgroundColor: hasChanges
                          ? accent
                          : accent.withValues(alpha: 0.55),
                      foregroundColor: Colors.black,
                    ),
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : Icon(
                            hasChanges
                                ? Icons.check_rounded
                                : Icons.save_outlined,
                          ),
                    label: Text(
                      _saving
                          ? l10n.settingsSaving
                          : hasChanges
                          ? l10n.settingsSaveProfile
                          : l10n.settingsDone,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _AvatarSectionMode { avatar, photo }

/// Lets existing users switch between a bundled preset avatar and a custom
/// photo. Preset choice is a draft until Save; photo applies when uploaded.
class _AvatarSection extends StatelessWidget {
  const _AvatarSection({
    required this.mode,
    required this.onModeChanged,
    required this.avatarsFuture,
    required this.selectedAsset,
    required this.accent,
    required this.avatarSaving,
    required this.onAvatarSelected,
    required this.showSaveAvatar,
    required this.onSaveAvatar,
    required this.profilePhotoUrl,
    required this.profilePhotoBase64,
    required this.photoSaving,
    required this.onChangePhoto,
    required this.enabled,
  });

  final _AvatarSectionMode mode;
  final ValueChanged<_AvatarSectionMode> onModeChanged;
  final Future<List<AvatarAsset>>? avatarsFuture;
  final String? selectedAsset;
  final Color accent;
  final bool avatarSaving;
  final ValueChanged<String> onAvatarSelected;
  final bool showSaveAvatar;
  final VoidCallback onSaveAvatar;
  final String? profilePhotoUrl;
  final String? profilePhotoBase64;
  final bool photoSaving;
  final VoidCallback onChangePhoto;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<_AvatarSectionMode>(
          style: ButtonStyle(
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? Colors.black
                  : Colors.white70,
            ),
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? accent
                  : Colors.transparent,
            ),
          ),
          segments: [
            ButtonSegment(
              value: _AvatarSectionMode.avatar,
              icon: const Icon(Icons.face_retouching_natural_outlined),
              label: Text(context.l10n.settingsAvatar),
            ),
            ButtonSegment(
              value: _AvatarSectionMode.photo,
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(context.l10n.settingsPhoto),
            ),
          ],
          selected: {mode},
          onSelectionChanged: enabled
              ? (selection) => onModeChanged(selection.first)
              : null,
        ),
        const SizedBox(height: 18),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: mode == _AvatarSectionMode.avatar
              ? _AvatarTabContent(
                  key: const ValueKey('avatar-tab'),
                  avatarsFuture: avatarsFuture,
                  selectedAsset: selectedAsset,
                  accent: accent,
                  enabled: enabled,
                  onAvatarSelected: onAvatarSelected,
                  showSave: showSaveAvatar,
                  onSave: onSaveAvatar,
                  saving: avatarSaving,
                )
              : _PhotoTabContent(
                  key: const ValueKey('photo-tab'),
                  profilePhotoUrl: profilePhotoUrl,
                  profilePhotoBase64: profilePhotoBase64,
                  accent: accent,
                  enabled: enabled,
                  saving: photoSaving,
                  onChangePhoto: onChangePhoto,
                ),
        ),
      ],
    );
  }
}

class _AvatarTabContent extends StatelessWidget {
  const _AvatarTabContent({
    super.key,
    required this.avatarsFuture,
    required this.selectedAsset,
    required this.accent,
    required this.enabled,
    required this.onAvatarSelected,
    required this.showSave,
    required this.onSave,
    required this.saving,
  });

  final Future<List<AvatarAsset>>? avatarsFuture;
  final String? selectedAsset;
  final Color accent;
  final bool enabled;
  final ValueChanged<String> onAvatarSelected;
  final bool showSave;
  final VoidCallback onSave;
  final bool saving;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<AvatarAsset>>(
      future: avatarsFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        return Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Nested under Settings' ListView so every avatar is
                // reachable via the outer scroll.
                AvatarPickerGrid(
                  avatars: snapshot.data!,
                  selectedAsset: selectedAsset,
                  enabled: enabled,
                  accent: accent,
                  onAvatarSelected: onAvatarSelected,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                ),
                if (showSave) ...[
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: saving ? null : onSave,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      backgroundColor: accent,
                      foregroundColor: Colors.black,
                    ),
                    icon: saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : const Icon(Icons.check_rounded),
                    label: Text(
                      saving
                          ? context.l10n.settingsSaving
                          : context.l10n.settingsSaveProfile,
                    ),
                  ),
                ],
              ],
            ),
            if (saving)
              const Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(color: Color(0x661b1b1b)),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _PhotoTabContent extends StatelessWidget {
  const _PhotoTabContent({
    super.key,
    required this.profilePhotoUrl,
    required this.profilePhotoBase64,
    required this.accent,
    required this.enabled,
    required this.saving,
    required this.onChangePhoto,
  });

  final String? profilePhotoUrl;
  final String? profilePhotoBase64;
  final Color accent;
  final bool enabled;
  final bool saving;
  final VoidCallback onChangePhoto;

  @override
  Widget build(BuildContext context) {
    final hasPhoto =
        (profilePhotoUrl?.trim().isNotEmpty ?? false) ||
        (profilePhotoBase64?.trim().isNotEmpty ?? false);

    return Row(
      children: [
        ClipOval(
          child: SizedBox(
            width: 64,
            height: 64,
            child: ProfileImage(
              profilePhotoUrl: profilePhotoUrl,
              profilePhotoBase64: profilePhotoBase64,
              backgroundColor: const Color(0xff2b2b2b),
              fallback: const Icon(Icons.person_outline, color: Colors.white54),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                hasPhoto
                    ? context.l10n.settingsYourPhoto
                    : context.l10n.settingsNoPhoto,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: enabled ? onChangePhoto : null,
                style: OutlinedButton.styleFrom(
                  foregroundColor: accent,
                  side: BorderSide(color: accent),
                ),
                icon: saving
                    ? SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: accent,
                        ),
                      )
                    : const Icon(Icons.upload_outlined, size: 18),
                label: Text(
                  hasPhoto
                      ? context.l10n.settingsChangePhoto
                      : context.l10n.settingsUploadPhoto,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsBlock extends StatelessWidget {
  const _SettingsBlock({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [_SectionTitle(title), const SizedBox(height: 8), child],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        color: Colors.white54,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
      ),
    );
  }
}

class _ElevenProSettingsCard extends StatelessWidget {
  const _ElevenProSettingsCard({
    required this.onTap,
    required this.subtitle,
    this.loading = false,
  });

  final VoidCallback? onTap;
  final String subtitle;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          children: [
            Image.asset(
              'assets/duo_stickers/minimalCrown.png',
              width: 36,
              height: 36,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.settingsDuoPro,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (loading)
              const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white54,
                ),
              )
            else
              const Icon(
                LucideIcons.chevronRight,
                color: Colors.white38,
                size: 18,
              ),
          ],
        ),
      ),
    );
  }
}

class _HapticsTierRow extends StatelessWidget {
  const _HapticsTierRow({
    required this.selected,
    required this.accent,
    required this.enabled,
    required this.onSelected,
  });

  final HapticsIntensity selected;
  final Color accent;
  final bool enabled;
  final ValueChanged<HapticsIntensity> onSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final option in HapticsIntensity.values) ...[
          if (option != HapticsIntensity.values.first) const SizedBox(width: 8),
          Expanded(
            child: _HapticsTierChip(
              option: option,
              selected: selected == option,
              accent: accent,
              enabled: enabled,
              onTap: () => onSelected(option),
            ),
          ),
        ],
      ],
    );
  }
}

class _HomeBackgroundOptionRow extends StatelessWidget {
  const _HomeBackgroundOptionRow({
    required this.illustrated,
    required this.accent,
    required this.session,
    required this.enabled,
    required this.onSelected,
  });

  final bool illustrated;
  final Color accent;
  final IdentitySession session;
  final bool enabled;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      children: [
        Expanded(
          child: _HomeBackgroundOptionChip(
            label: l10n.settingsHomeBackgroundDefault,
            illustrated: false,
            selected: !illustrated,
            accent: accent,
            session: session,
            enabled: enabled,
            onTap: () => onSelected(false),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _HomeBackgroundOptionChip(
            label: l10n.settingsHomeBackgroundIllustrated,
            illustrated: true,
            selected: illustrated,
            accent: accent,
            session: session,
            enabled: enabled,
            onTap: () => onSelected(true),
          ),
        ),
      ],
    );
  }
}

class _HomeBackgroundOptionChip extends StatelessWidget {
  const _HomeBackgroundOptionChip({
    required this.label,
    required this.illustrated,
    required this.selected,
    required this.accent,
    required this.session,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool illustrated;
  final bool selected;
  final Color accent;
  final IdentitySession session;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final labelColor = selected ? accent : Colors.white54;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        splashColor: accent.withValues(alpha: 0.12),
        highlightColor: accent.withValues(alpha: 0.06),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              _HomeLookPreview(
                illustrated: illustrated,
                selected: selected,
                accent: accent,
                session: session,
              ),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: labelColor,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 6),
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                height: 2,
                width: selected ? 22 : 0,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeLookPreview extends StatelessWidget {
  const _HomeLookPreview({
    required this.illustrated,
    required this.selected,
    required this.accent,
    required this.session,
  });

  final bool illustrated;
  final bool selected;
  final Color accent;
  final IdentitySession session;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      height: 92,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? accent : Colors.white.withValues(alpha: 0.10),
          width: selected ? 1.6 : 1,
        ),
        boxShadow: selected
            ? [BoxShadow(color: accent.withValues(alpha: 0.28), blurRadius: 12)]
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: illustrated
          ? const _IllustratedHomePreview()
          : _DefaultHomePreview(session: session, accent: accent),
    );
  }
}

/// Mini version of the production collage backdrop (blurred portrait + wash).
class _DefaultHomePreview extends StatelessWidget {
  const _DefaultHomePreview({required this.session, required this.accent});

  final IdentitySession session;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        Opacity(
          opacity: 0.42,
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: ProfileImage(
              profilePhotoUrl: session.user.profilePhotoUrl,
              profilePhotoBase64: session.user.profilePhotoBase64,
              avatarAsset: session.user.avatarAsset,
              backgroundColor: const Color(0xff1a1a1a),
              fallback: const ColoredBox(color: Color(0xff1a1a1a)),
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.28),
                Colors.black.withValues(alpha: 0.55),
                Color.lerp(Colors.black, accent, 0.14)!,
              ],
              stops: const [0, 0.55, 1],
            ),
          ),
        ),
      ],
    );
  }
}

/// Mini version of the illustrated doodle wallpaper used on home.
class _IllustratedHomePreview extends StatelessWidget {
  const _IllustratedHomePreview();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        Image.asset(
          HomeVisualVariantController.illustratedLook.assetPath!,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          filterQuality: FilterQuality.medium,
        ),
        const ColoredBox(color: Color.fromRGBO(0, 0, 0, 0.12)),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.fromRGBO(0, 0, 0, 0.42),
                Color.fromRGBO(0, 0, 0, 0.08),
                Color.fromRGBO(0, 0, 0, 0.50),
              ],
              stops: [0.0, 0.5, 1.0],
            ),
          ),
        ),
      ],
    );
  }
}

class _HapticsTierChip extends StatelessWidget {
  const _HapticsTierChip({
    required this.option,
    required this.selected,
    required this.accent,
    required this.enabled,
    required this.onTap,
  });

  final HapticsIntensity option;
  final bool selected;
  final Color accent;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final labelColor = selected ? accent : Colors.white54;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        splashColor: accent.withValues(alpha: 0.12),
        highlightColor: accent.withValues(alpha: 0.06),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            children: [
              Text(
                option.emoji,
                style: const TextStyle(fontSize: 22, height: 1.1),
              ),
              const SizedBox(height: 4),
              Text(
                option.localizedLabel(context.l10n),
                style: TextStyle(
                  color: labelColor,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 4),
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                height: 2,
                width: selected ? 22 : 0,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TestingVariantRow extends StatelessWidget {
  const _TestingVariantRow({
    required this.variant,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final HomeVisualVariant variant;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off_outlined,
              color: selected ? accent : Colors.white38,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    variant.label,
                    style: const TextStyle(color: Colors.white),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    variant.subtitle,
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSurface extends StatelessWidget {
  const _SettingsSurface({
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(14, 12, 14, 12),
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xff171717),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: padding,
        child: Column(children: children),
      ),
    );
  }
}

class _PreferenceHeading extends StatelessWidget {
  const _PreferenceHeading({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: Colors.white70, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _AccentBlobPicker extends StatelessWidget {
  const _AccentBlobPicker({
    required this.selectedKey,
    required this.enabled,
    required this.onSelected,
  });

  final String selectedKey;
  final bool enabled;
  final ValueChanged<AccentOption> onSelected;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const columns = 6;
        const spacing = 10.0;
        final swatchSize =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: 10,
          children: [
            for (var i = 0; i < accentOptions.length; i++)
              SizedBox(
                width: swatchSize,
                height: swatchSize,
                child: _AccentBlob(
                  option: accentOptions[i],
                  shapeIndex: i,
                  selected: accentOptions[i].key == selectedKey,
                  enabled: enabled,
                  onSelected: () => onSelected(accentOptions[i]),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _AccentBlob extends StatelessWidget {
  const _AccentBlob({
    required this.option,
    required this.shapeIndex,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final AccentOption option;
  final int shapeIndex;
  final bool selected;
  final bool enabled;
  final VoidCallback onSelected;

  BorderRadius get _radius {
    final a = 11.0 + (shapeIndex * 5) % 16;
    final b = 22.0 - (shapeIndex * 3) % 12;
    final c = 13.0 + (shapeIndex * 7) % 14;
    final d = 24.0 - (shapeIndex * 4) % 14;
    return BorderRadius.only(
      topLeft: Radius.circular(a),
      topRight: Radius.circular(b),
      bottomLeft: Radius.circular(c),
      bottomRight: Radius.circular(d),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tilt =
        (shapeIndex.isEven ? -1 : 1) * (0.05 + (shapeIndex % 3) * 0.02);
    return Tooltip(
      message: option.localizedLabel(context.l10n),
      child: Semantics(
        button: true,
        selected: selected,
        label: option.localizedLabel(context.l10n),
        child: InkWell(
          onTap: enabled ? onSelected : null,
          customBorder: RoundedRectangleBorder(borderRadius: _radius),
          child: Center(
            child: AnimatedScale(
              scale: selected ? 1.12 : 1,
              duration: const Duration(milliseconds: 280),
              curve: selected ? Curves.elasticOut : Curves.easeOut,
              child: AnimatedRotation(
                turns: selected ? 0 : tilt / (2 * 3.1416),
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOut,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: option.color,
                    borderRadius: _radius,
                    border: Border.all(
                      color: selected
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.12),
                      width: selected ? 2.5 : 1,
                    ),
                    boxShadow: selected
                        ? [
                            BoxShadow(
                              color: option.color.withValues(alpha: 0.55),
                              blurRadius: 12,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  child: selected
                      ? const Icon(
                          LucideIcons.check,
                          color: Colors.black,
                          size: 16,
                        )
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavigationRow extends StatelessWidget {
  const _NavigationRow({
    required this.icon,
    required this.label,
    this.onTap,
    this.detail,
    this.showChevron = true,
    this.trailing,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final String? detail;
  final bool showChevron;
  final Widget? trailing;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? const Color(0xffff8a80) : Colors.white;
    final iconColor = destructive ? const Color(0xffff8a80) : Colors.white70;
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: iconColor, size: 20),
      title: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: detail == null
          ? null
          : Text(
              detail!,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
      trailing:
          trailing ??
          (showChevron
              ? Icon(
                  LucideIcons.chevronRight,
                  color: destructive
                      ? const Color(0xffff8a80).withValues(alpha: 0.7)
                      : Colors.white38,
                  size: 18,
                )
              : null),
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
    );
  }
}

class _SurfaceDivider extends StatelessWidget {
  const _SurfaceDivider({this.indent = 0, this.height = 1});
  final double indent;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: height,
      indent: indent,
      color: Colors.white.withValues(alpha: 0.09),
    );
  }
}

class _ReliabilityRow extends StatelessWidget {
  const _ReliabilityRow({
    required this.stickerAsset,
    required this.ok,
    required this.label,
    required this.detail,
    this.onTap,
  });

  final String stickerAsset;
  final bool ok;
  final String label;
  final String detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tappable = !ok && onTap != null;
    return InkWell(
      onTap: tappable ? onTap : null,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Opacity(
              opacity: ok ? 1 : 0.58,
              child: Image.asset(stickerAsset, width: 48, height: 48),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (!ok) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              ok ? LucideIcons.check : LucideIcons.chevronRight,
              size: 18,
              color: ok ? const Color(0xff7CFF6B) : Colors.white38,
            ),
          ],
        ),
      ),
    );
  }
}
