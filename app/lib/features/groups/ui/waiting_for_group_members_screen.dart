import 'package:one_one_app/one_one.dart';

class WaitingForGroupMembersScreen extends StatefulWidget {
  const WaitingForGroupMembersScreen({
    super.key,
    required this.group,
    required this.invite,
    required this.session,
    required this.identityRepository,
  });

  final GroupSummary group;
  final GroupInviteResult invite;
  final IdentitySession session;
  final IdentityRepository identityRepository;

  @override
  State<WaitingForGroupMembersScreen> createState() =>
      _WaitingForGroupMembersScreenState();
}

class _WaitingForGroupMembersScreenState
    extends State<WaitingForGroupMembersScreen> {
  StreamSubscription<DatabaseEvent>? _membersSubscription;
  bool _navigatingHome = false;

  @override
  void initState() {
    super.initState();
    AccentThemeController.setAccentKey(widget.session.settings.accentColorKey);
    unawaited(
      PendingGroupInvitesStore.mark(
        widget.session.userId,
        widget.group.groupId,
      ),
    );
    _listenForNewMembers();
  }

  @override
  void dispose() {
    unawaited(_membersSubscription?.cancel());
    super.dispose();
  }

  void _listenForNewMembers() {
    _membersSubscription = AppDatabase.instance()
        .ref('groupMembers/${widget.group.groupId}')
        .onValue
        .listen((event) {
          final count = _activeMemberCount(event.snapshot.value);
          if (count > 1) {
            unawaited(_goHome());
          }
        });
  }

  int _activeMemberCount(Object? value) {
    if (value is! Map<Object?, Object?>) return 0;

    var count = 0;
    for (final entry in value.entries) {
      final raw = entry.value;
      if (raw is! Map<Object?, Object?>) continue;
      if ((raw['memberState']?.toString() ?? 'active') == 'active') {
        count++;
      }
    }
    return count;
  }

  Future<void> _goHome() async {
    if (_navigatingHome || !mounted) return;
    _navigatingHome = true;

    await Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(
        builder: (_) => IdentityHomeScreen(
          initialSession: widget.session,
          identityRepository: widget.identityRepository,
        ),
      ),
      (route) => false,
    );
  }

  Future<void> _shareInvite() async {
    try {
      await InviteLinkBridge().shareInviteLink(widget.invite.inviteUrl);
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: widget.invite.inviteUrl));
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.homeInviteLinkCopied)));
    }
    // After sharing, land on home so the sender sees the Invited chip +
    // grayed chat while waiting for the invitee to accept.
    if (mounted) unawaited(_goHome());
  }

  Future<void> _copyPin() async {
    await Clipboard.setData(ClipboardData(text: widget.invite.inviteCode));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Fallback PIN copied')));
  }

  Route<void> _slideUpJoinRoute() {
    return PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (context, animation, secondaryAnimation) {
        return GroupActionScreen(
          mode: GroupActionMode.joinByPin,
          session: widget.session,
          identityRepository: widget.identityRepository,
        );
      },
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final offset =
            Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            );

        return SlideTransition(position: offset, child: child);
      },
    );
  }

  void _openJoinGroup() {
    Navigator.of(context).push(_slideUpJoinRoute());
  }

  void _openSettings() {
    final ownsGroup = widget.group.ownerUserId == widget.session.userId;
    unawaited(
      SettingsScreen.open(
        context,
        session: widget.session,
        identityRepository: widget.identityRepository,
        manageableGroups: ownsGroup ? [widget.group] : const [],
        onManageGroup: ownsGroup ? _openGroupManagement : null,
      ),
    );
  }

  Future<bool> _openGroupManagement(GroupSummary group) async {
    if (group.ownerUserId != widget.session.userId) return false;
    final members = await GroupRepository().loadGroupMembers(group.groupId);
    if (!mounted) return false;
    final outcome = await Navigator.of(context).push<GroupManagementOutcome>(
      MaterialPageRoute<GroupManagementOutcome>(
        builder: (_) => GroupManagementScreen(
          group: group,
          currentUserId: widget.session.userId,
          initialMembers: members,
          onInvite: _shareInvite,
        ),
      ),
    );
    if (outcome == null || !mounted) return false;
    // Group no longer available — leave the waiting route.
    unawaited(_goHome());
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xff000000),
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 24.w),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '⌛ waiting for someone to join your group',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 28.sp,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                      ),
                    ),
                    SizedBox(height: 28.h),
                    TextButton(
                      onPressed: _openJoinGroup,
                      child: Text(
                        'join a group instead',
                        style: TextStyle(
                          color: const Color.fromRGBO(255, 255, 255, 0.78),
                          fontSize: 15.sp,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                          decorationColor: const Color.fromRGBO(
                            255,
                            255,
                            255,
                            0.78,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: 28.h),
                    GestureDetector(
                      onTap: _shareInvite,
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 22.w,
                          vertical: 14.h,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(28.r),
                          border: Border.all(
                            color: const Color.fromRGBO(255, 255, 255, 0.55),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              context.l10n.homeShareInviteLink,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16.sp,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.4,
                              ),
                            ),
                            SizedBox(width: 12.w),
                            Icon(
                              Icons.ios_share_rounded,
                              color: Colors.white,
                              size: 18.sp,
                            ),
                          ],
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _copyPin,
                      child: Text(
                        context.l10n.homeCopyPin(widget.invite.inviteCode),
                      ),
                    ),
                    TextButton(
                      onPressed: () => unawaited(_goHome()),
                      child: Text(
                        context.l10n.waitingContinueToHome,
                        style: TextStyle(
                          color: const Color.fromRGBO(255, 255, 255, 0.78),
                          fontSize: 15.sp,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                          decorationColor: const Color.fromRGBO(
                            255,
                            255,
                            255,
                            0.78,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: EdgeInsets.only(left: 12.w, top: 12.h),
                child: IconButton(
                  tooltip: 'Settings',
                  onPressed: _openSettings,
                  icon: Icon(Icons.settings_outlined, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
