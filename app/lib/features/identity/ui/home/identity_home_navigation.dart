part of '../identity_home_screen.dart';

// 1. Create/join group routes and invite share sheet.
// 2. Settings, nudge sheet, setup-warning sheet.

mixin _IdentityHomeNavigation on _IdentityHomeBase {
  // C4 decision: creating or joining a group while live keeps the existing
  // session active. The new group is created/joined independently; the user
  // can switch to it from the carousel on the home screen, which goes away
  // from the current group and joins the new one. The in-app PiP overlay
  // (visible on the GroupActionScreen) lets the user return directly to the
  // home/live screen without losing context.
  void _openCreateGroup() {
    unawaited(
      AnalyticsService.logButtonClick(
        buttonName: 'create_group',
        screenName: 'home',
      ),
    );
    unawaited(
      AnalyticsService.logFeatureSelected(
        feature: 'create_group',
        screenName: 'home',
      ),
    );
    _openGroupAction(GroupActionMode.createGroup);
  }

  void _openJoinGroup() {
    unawaited(
      AnalyticsService.logButtonClick(
        buttonName: 'join_group',
        screenName: 'home',
      ),
    );
    unawaited(
      AnalyticsService.logFeatureSelected(
        feature: 'join_group',
        screenName: 'home',
      ),
    );
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
    unawaited(
      AnalyticsService.logButtonClick(
        buttonName: 'invite',
        screenName: 'home',
      ),
    );
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
                  context.l10n.homeInviteFriends,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18.sp,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 8.h),
                Text(
                  context.l10n.homeInviteFriendsSubtitle,
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
                          SnackBar(content: Text(context.l10n.homeInviteLinkCopied)),
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
                                context.l10n.homeShareInviteLink,
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
                      SnackBar(content: Text(context.l10n.homeFallbackPinCopied)),
                    );
                  },
                  icon: Icon(Icons.copy_rounded, size: 17.sp),
                  label: Text(context.l10n.homeCopyPin(invite.inviteCode)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
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

  @override
  void _setMessage(String message) {
    if (!mounted) return;
    setState(() => _message = message);
  }

  @override
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
    unawaited(
      AnalyticsService.logButtonClick(
        buttonName: 'settings',
        screenName: 'home',
      ),
    );
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

  @override
  void _openNudges() {
    if (_incomingPromptNudge != null) return;
    final group = _selectedGroup;
    if (group == null) return;
    unawaited(
      AnalyticsService.logButtonClick(
        buttonName: 'nudge',
        screenName: 'home',
      ),
    );
    unawaited(
      AnalyticsService.logFeatureSelected(
        feature: 'nudge',
        screenName: 'home',
      ),
    );
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
        isLiveMicrophoneInUse: () => _isOnline && _isTransmitting,
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
              Text(context.l10n.homeSetup, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              if (warnings.isEmpty)
                _SetupLine(
                  ok: true,
                  text: context.l10n.homeSetupReady,
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
        _SetupWarning(text: context.l10n.homeSetupNeedGroup, accent: accent),
      );
    }
    if (!_session.device.micPermissionGranted && _onlineSession == null) {
      warnings.add(
        _SetupWarning(
          text: context.l10n.homeSetupNeedMic,
          accent: accent,
          onTap: () => _requestMicPermissionFromSetup(),
        ),
      );
    }
    if (!_session.device.notificationPermissionGranted) {
      warnings.add(
        _SetupWarning(
          text: context.l10n.homeSetupNeedNotifications,
          accent: accent,
          onTap: () => _requestNotificationPermissionFromSetup(),
        ),
      );
    }
    if (_session.device.fcmToken == null) {
      warnings.add(
        _SetupWarning(
          text: context.l10n.homeSetupNeedPush,
          accent: accent,
          onTap: null, // Needs app restart — informational only.
        ),
      );
    }
    if (!_session.device.batteryOptimizationIgnored) {
      warnings.add(
        _SetupWarning(
          text: context.l10n.homeSetupNeedBattery,
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
      setState(() => _message = context.l10n.settingsMicGranted);
    } else {
      setState(() => _message = context.l10n.settingsMicDenied);
    }
  }

  Future<void> _requestNotificationPermissionFromSetup() async {
    final status = await Permission.notification.request();
    if (!mounted) return;
    if (status.isGranted) {
      setState(() => _message = context.l10n.settingsNotificationGranted);
    } else {
      setState(() => _message = context.l10n.settingsNotificationDenied);
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
          context.l10n.settingsBatteryRequestSent,
    );
  }
}
