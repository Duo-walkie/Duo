import 'package:one_one_app/one_one.dart';

/// Pre-redesign light welcome / Google sign-in UI.
///
/// Kept for reference and Settings comparison only. The live pre-auth
/// welcome is [GoogleAuthScreen].
@Deprecated('Use GoogleAuthScreen — the dark sticker welcome is now live.')
class DeprecatedGoogleAuthScreen extends StatefulWidget {
  @Deprecated('Use GoogleAuthScreen — the dark sticker welcome is now live.')
  const DeprecatedGoogleAuthScreen({super.key, this.initializing = false});

  final bool initializing;

  @override
  State<DeprecatedGoogleAuthScreen> createState() =>
      _DeprecatedGoogleAuthScreenState();
}

class _DeprecatedGoogleAuthScreenState
    extends State<DeprecatedGoogleAuthScreen> {
  IdentityRepository? _identityRepository;
  bool _isSigningIn = false;
  String? _errorMessage;

  IdentityRepository get _repo => _identityRepository ??= IdentityRepository();

  @override
  void initState() {
    super.initState();
    if (!widget.initializing) {
      unawaited(
        AnalyticsService.logScreenView(
          screenName: 'google_auth_legacy',
          screenClass: 'DeprecatedGoogleAuthScreen',
        ),
      );
    }
    unawaited(DuoLocalization.start());
  }

  @override
  void dispose() {
    _identityRepository?.dispose();
    super.dispose();
  }

  Future<void> _continueWithGoogle() async {
    if (_isSigningIn) return;
    unawaited(
      AnalyticsService.logButtonClick(
        buttonName: 'continue_with_google',
        screenName: 'google_auth_legacy',
      ),
    );
    setState(() {
      _isSigningIn = true;
      _errorMessage = null;
    });

    try {
      await _repo.signInWithGoogle();
    } catch (error, stack) {
      final message = error.toString();
      final cancelled =
          message.contains('canceled') || message.contains('cancelled');
      if (!cancelled) {
        await CrashlyticsService.recordError(
          error,
          stack,
          reason: 'google_sign_in_failed_legacy',
        );
      }
      if (!mounted) return;
      setState(() {
        _isSigningIn = false;
        _errorMessage = _friendlyError(context, error);
      });
    }
  }

  String _friendlyError(BuildContext context, Object error) {
    final message = error.toString();
    if (message.contains('canceled') || message.contains('cancelled')) {
      return context.l10n.googleSignInCancelled;
    }
    return context.l10n.googleSignInFailed;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.initializing) {
      return const BrandSplashScreen();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      NativeSplashBridge.markReady();
    });

    return WelcomeOnboardingHost(
      child: Scaffold(
        backgroundColor: BrandSplashScreen.backgroundColor,
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(28.w, 28.h, 28.w, 24.h),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: const WelcomeLanguageToggle(),
                ),
                const Spacer(flex: 2),
                Image.asset(
                  'assets/logo.png',
                  width: 172.w,
                  fit: BoxFit.contain,
                ),
                SizedBox(height: 36.h),
                Text(
                  context.l10n.welcomeTitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: const Color(0xff252a2e),
                    fontSize: 26.sp,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 10.h),
                Text(
                  context.l10n.welcomeSubtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: const Color.fromRGBO(37, 42, 46, 0.72),
                    fontSize: 14.sp,
                    height: 1.45,
                  ),
                ),
                const Spacer(flex: 3),
                if (_errorMessage != null) ...[
                  Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: const Color(0xff7a2f2f),
                      fontSize: 12.sp,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  SizedBox(height: 14.h),
                ],
                _LegacyGoogleSignInButton(
                  busy: _isSigningIn,
                  busyLabel: context.l10n.signingIn,
                  label: context.l10n.continueWithGoogle,
                  onTap: _continueWithGoogle,
                ),
                SizedBox(height: 22.h),
                Text(
                  context.l10n.termsFooter,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: const Color.fromRGBO(56, 64, 71, 0.72),
                    fontSize: 11.sp,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LegacyGoogleSignInButton extends StatefulWidget {
  const _LegacyGoogleSignInButton({
    required this.busy,
    required this.onTap,
    required this.label,
    this.busyLabel = 'Signing in…',
  });
  final bool busy;
  final VoidCallback onTap;
  final String label;
  final String busyLabel;
  @override
  State<_LegacyGoogleSignInButton> createState() =>
      _LegacyGoogleSignInButtonState();
}

class _LegacyGoogleSignInButtonState extends State<_LegacyGoogleSignInButton> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) => AnimatedScale(
    scale: _pressed ? .96 : 1,
    duration: const Duration(milliseconds: 100),
    child: Material(
      color: widget.busy ? Colors.white70 : Colors.white,
      borderRadius: BorderRadius.circular(27.r),
      child: InkWell(
        onTap: widget.busy ? null : widget.onTap,
        onTapDown: widget.busy ? null : (_) => setState(() => _pressed = true),
        onTapUp: widget.busy ? null : (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        borderRadius: BorderRadius.circular(27.r),
        child: SizedBox(
          width: double.infinity,
          height: 54.h,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              widget.busy
                  ? SizedBox.square(
                      dimension: 19.w,
                      child: const CircularProgressIndicator(
                        strokeWidth: 2.3,
                        color: Color(0xff384047),
                      ),
                    )
                  : Text(
                      'G',
                      style: TextStyle(
                        fontSize: 19.sp,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
              SizedBox(width: 10.w),
              Text(
                widget.busy ? widget.busyLabel : widget.label,
                style: TextStyle(
                  color: const Color(0xff384047),
                  fontSize: 15.sp,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
