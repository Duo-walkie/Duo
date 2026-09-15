import 'package:one_one_app/one_one.dart';

class NoGroupsScreen extends StatefulWidget {
  const NoGroupsScreen({
    super.key,
    required this.session,
    required this.identityRepository,
  });

  final IdentitySession session;
  final IdentityRepository identityRepository;

  @override
  State<NoGroupsScreen> createState() => _NoGroupsScreenState();
}

class _NoGroupsScreenState extends State<NoGroupsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        showPostCrashReportDialogIfNeeded(
          context,
          userId: widget.session.userId,
        ),
      );
    });
  }

  Route<void> _slideUpRoute(GroupActionMode mode) {
    return PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (context, animation, secondaryAnimation) {
        return GroupActionScreen(
          mode: mode,
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

  void _openJoinGroup(BuildContext context) {
    Navigator.of(context).push(_slideUpRoute(GroupActionMode.joinByPin));
  }

  void _openInviteContactsSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => InviteContactsSheet(
        session: widget.session,
        identityRepository: widget.identityRepository,
        onGroupCreated: () {
          // Navigate to home — group was just created inside the sheet.
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute<void>(
              builder: (_) => IdentityHomeScreen(
                initialSession: widget.session,
                identityRepository: widget.identityRepository,
              ),
            ),
            (route) => false,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xff000000),
        foregroundColor: Colors.white,
        leading: IconButton(
          tooltip: context.l10n.homeSettings,
          onPressed: () {
            unawaited(
              SettingsScreen.open(
                context,
                session: widget.session,
                identityRepository: widget.identityRepository,
              ),
            );
          },
          icon: const Icon(Icons.settings_outlined),
        ),
      ),
      backgroundColor: const Color(0xff000000),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 24.w),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        'assets/duo_stickers/waiting-binoculars.png',
                        width: 168.w,
                        fit: BoxFit.contain,
                      ),
                      SizedBox(height: 22.h),
                      Text(
                        context.l10n.noGroupsTitle,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineLarge
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                      ),
                      SizedBox(height: 10.h),
                      Text(
                        context.l10n.noGroupsSubtitle,
                        textAlign: TextAlign.center,
                        style: Theme.of(
                          context,
                        ).textTheme.bodyLarge?.copyWith(color: Colors.white),
                      ),
                      SizedBox(height: 28.h),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () => _openInviteContactsSheet(context),
                          icon: const Icon(Icons.people_alt_rounded),
                          label: Text(context.l10n.noGroupsInviteClosedOnes),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xffF8BE03),
                            foregroundColor: Colors.black,
                            padding: EdgeInsets.symmetric(vertical: 16.h),
                            textStyle: TextStyle(
                              fontSize: 16.sp,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Column(
                children: [
                  Text(
                    context.l10n.noGroupsHavePin,
                    textAlign: TextAlign.center,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyLarge?.copyWith(color: Colors.white),
                  ),
                  SizedBox(height: 18.h),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => _openJoinGroup(context),
                      icon: const Icon(Icons.login),
                      label: Text(context.l10n.noGroupsJoinPin),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 18.h),
            ],
          ),
        ),
      ),
    );
  }
}
