import 'dart:math' as math;

import 'package:one_one_app/one_one.dart';

/// Pre-auth welcome / Google sign-in. Dark sticker field with curve-in
/// choreography; stickers reverse out after a successful sign-in.
class GoogleAuthScreen extends StatefulWidget {
  const GoogleAuthScreen({super.key, this.initializing = false});

  /// When true, shows the splash-colored underlay only — never the signed-out
  /// welcome CTA. Used while Firebase is still initializing so a returning
  /// signed-in session never flashes "Welcome to Duo".
  final bool initializing;

  static const _brandYellow = Color(0xffF8BE03);
  static const _bg = Color(0xff101010);

  @override
  State<GoogleAuthScreen> createState() => _GoogleAuthScreenState();
}

const _kSettle = Cubic(0.16, 1, 0.3, 1);

class _StickerSpec {
  const _StickerSpec({
    required this.asset,
    required this.restX,
    required this.restY,
    required this.size,
    required this.restRotation,
    required this.opacity,
    required this.fromLeft,
    required this.stagger,
    required this.phase,
    this.arc = -0.08,
    this.periodMs = 5400,
  });

  final String asset;
  final double restX;
  final double restY;
  final double size;
  final double restRotation;
  final double opacity;
  final bool fromLeft;
  final double arc;
  final double stagger;
  final double phase;
  final int periodMs;
}

final List<_StickerSpec> _stickers = [
  _StickerSpec(
    asset: 'assets/duo_stickers/message.png',
    restX: 0.22,
    restY: 0.12,
    size: 66,
    restRotation: -0.14,
    opacity: 0.76,
    fromLeft: true,
    stagger: 0,
    phase: 0.2,
    arc: -0.14,
    periodMs: 4800,
  ),
  _StickerSpec(
    asset: 'assets/duo_stickers/mic.png',
    restX: 0.50,
    restY: 0.10,
    size: 60,
    restRotation: 0.08,
    opacity: 0.70,
    fromLeft: false,
    stagger: 0.05,
    phase: 1.1,
    arc: -0.18,
  ),
  _StickerSpec(
    asset: 'assets/duo_stickers/bell.png',
    restX: 0.78,
    restY: 0.12,
    size: 62,
    restRotation: 0.12,
    opacity: 0.70,
    fromLeft: false,
    stagger: 0.08,
    phase: 0.7,
    arc: -0.12,
  ),
  _StickerSpec(
    asset: 'assets/duo_stickers/headset.png',
    restX: 0.22,
    restY: 0.28,
    size: 74,
    restRotation: -0.06,
    opacity: 0.76,
    fromLeft: true,
    stagger: 0.10,
    phase: 2.4,
    arc: 0.07,
  ),
  _StickerSpec(
    asset: 'assets/duo_stickers/boysNgirls.png',
    restX: 0.78,
    restY: 0.26,
    size: 74,
    restRotation: 0.07,
    opacity: 0.76,
    fromLeft: false,
    stagger: 0.12,
    phase: 3.2,
    arc: -0.07,
  ),
  _StickerSpec(
    asset: 'assets/duo_stickers/handshake.png',
    restX: 0.12,
    restY: 0.60,
    size: 66,
    restRotation: 0.10,
    opacity: 0.70,
    fromLeft: true,
    stagger: 0.14,
    phase: 5.0,
    arc: 0.09,
  ),
  _StickerSpec(
    asset: 'assets/duo_stickers/online_orb.png',
    restX: 0.38,
    restY: 0.62,
    size: 58,
    restRotation: -0.05,
    opacity: 0.66,
    fromLeft: true,
    stagger: 0.18,
    phase: 4.1,
    arc: 0.13,
  ),
  _StickerSpec(
    asset: 'assets/duo_stickers/gift.png',
    restX: 0.62,
    restY: 0.64,
    size: 56,
    restRotation: 0.08,
    opacity: 0.64,
    fromLeft: false,
    stagger: 0.16,
    phase: 2.9,
    arc: 0.10,
  ),
  _StickerSpec(
    asset: 'assets/duo_stickers/mic.png',
    restX: 0.88,
    restY: 0.60,
    size: 60,
    restRotation: -0.10,
    opacity: 0.68,
    fromLeft: false,
    stagger: 0.20,
    phase: 3.5,
    arc: 0.06,
  ),
  _StickerSpec(
    asset: 'assets/duo_stickers/message.png',
    restX: 0.25,
    restY: 0.74,
    size: 52,
    restRotation: -0.08,
    opacity: 0.60,
    fromLeft: true,
    stagger: 0.22,
    phase: 1.4,
    arc: 0.16,
  ),
  _StickerSpec(
    asset: 'assets/duo_stickers/bell.png',
    restX: 0.75,
    restY: 0.74,
    size: 50,
    restRotation: 0.11,
    opacity: 0.58,
    fromLeft: false,
    stagger: 0.24,
    phase: 4.6,
    arc: 0.12,
  ),
];

class _GoogleAuthScreenState extends State<GoogleAuthScreen>
    with TickerProviderStateMixin {
  IdentityRepository? _identityRepository;
  bool _isSigningIn = false;
  String? _errorMessage;

  late final AnimationController _enter;
  late final AnimationController _exit;
  late final AnimationController _idle;

  IdentityRepository get _repo => _identityRepository ??= IdentityRepository();

  @override
  void initState() {
    super.initState();
    _idle = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 60),
    );
    _exit = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 780),
    );
    _enter = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1700),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed && !_isSigningIn) {
          _idle.repeat();
        }
      });

    if (!widget.initializing) {
      _enter.forward();
      unawaited(
        AnalyticsService.logScreenView(
          screenName: 'google_auth',
          screenClass: 'GoogleAuthScreen',
        ),
      );
    }
    unawaited(DuoLocalization.start());
  }

  @override
  void dispose() {
    _enter.dispose();
    _exit.dispose();
    _idle.dispose();
    _identityRepository?.dispose();
    super.dispose();
  }

  Future<void> _continueWithGoogle() async {
    if (_isSigningIn) return;
    unawaited(
      AnalyticsService.logButtonClick(
        buttonName: 'continue_with_google',
        screenName: 'google_auth',
      ),
    );
    setState(() {
      _isSigningIn = true;
      _errorMessage = null;
    });

    try {
      await _repo.signInWithGoogle();
      // Success: reverse stickers out. Root auth stream will replace this
      // widget; leave _isSigningIn true so the CTA stays busy.
      if (!mounted) return;
      _idle.stop();
      if (_enter.isAnimating) {
        _enter.stop();
      }
      unawaited(_exit.forward());
    } catch (error, stack) {
      final message = error.toString();
      final cancelled =
          message.contains('canceled') || message.contains('cancelled');
      if (!cancelled) {
        await CrashlyticsService.recordError(
          error,
          stack,
          reason: 'google_sign_in_failed',
        );
      }
      if (!mounted) return;
      setState(() {
        _isSigningIn = false;
        _errorMessage = _friendlyError(context, error);
      });
      if (_enter.status == AnimationStatus.completed && !_idle.isAnimating) {
        _idle.repeat();
      }
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

    final size = MediaQuery.sizeOf(context);

    return WelcomeOnboardingHost(
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: GoogleAuthScreen._bg,
          body: Stack(
            fit: StackFit.expand,
            children: [
              Align(
                alignment: const Alignment(0, -0.36),
                child: Container(
                  width: size.width * 0.95,
                  height: size.width * 0.95,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [Color(0x28F8BE03), Color(0x00F8BE03)],
                    ),
                  ),
                ),
              ),
              AnimatedBuilder(
                animation: Listenable.merge([_enter, _exit, _idle]),
                builder: (context, _) {
                  return Stack(
                    children: [
                      for (final sticker in _stickers)
                        _placedSticker(sticker, size),
                    ],
                  );
                },
              ),
              SafeArea(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(24.w, 12.h, 24.w, 20.h),
                  child: Column(
                    children: [
                      Align(
                        alignment: Alignment.topRight,
                        child: WelcomeLanguageToggle(
                          foreground: Colors.white.withValues(alpha: 0.9),
                        ),
                      ),
                      const Spacer(flex: 3),
                      Image.asset(
                        'assets/logo.png',
                        width: 138.w,
                        fit: BoxFit.contain,
                      ),
                      SizedBox(height: 20.h),
                      Text(
                        context.l10n.welcomeTitle,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 28.sp,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                          height: 1.15,
                        ),
                      ),
                      SizedBox(height: 12.h),
                      Text(
                        context.l10n.welcomeSubtitle,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.62),
                          fontSize: 12.sp,
                          height: 1.45,
                        ),
                      ),
                      const Spacer(flex: 4),
                      if (_errorMessage != null) ...[
                        Text(
                          _errorMessage!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: const Color(0xffff8a80),
                            fontSize: 12.sp,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        SizedBox(height: 14.h),
                      ],
                      _GoogleSignInButton(
                        busy: _isSigningIn,
                        busyLabel: context.l10n.signingIn,
                        label: context.l10n.continueWithGoogle,
                        onTap: _continueWithGoogle,
                      ),
                      SizedBox(height: 16.h),
                      Text(
                        context.l10n.termsFooter,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.38),
                          fontSize: 11.sp,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placedSticker(_StickerSpec spec, Size size) {
    final inT = _kSettle.transform(
      ((_enter.value - spec.stagger) / 0.72).clamp(0.0, 1.0),
    );
    final outT = _kSettle.transform(
      ((_exit.value - spec.stagger * 0.35) / 0.70).clamp(0.0, 1.0),
    );
    final travel = (inT * (1 - outT)).clamp(0.0, 1.0);

    var pos = _curvePoint(spec, size, travel);

    final settled = inT >= 1 && outT == 0;
    if (settled) {
      final idleT = _idle.value * 2 * math.pi;
      final wave = math.sin(idleT * (60000 / spec.periodMs) + spec.phase);
      pos += Offset(0, wave * 3.5);
    }

    final rotation = spec.restRotation * travel;
    final opacity = spec.opacity * travel.clamp(0.0, 1.0);

    if (opacity <= 0.01 && outT > 0) {
      return const SizedBox.shrink();
    }

    return Positioned(
      left: pos.dx - spec.size / 2,
      top: pos.dy - spec.size / 2,
      child: IgnorePointer(
        child: Opacity(
          opacity: opacity,
          child: Transform.rotate(
            angle: rotation,
            child: Image.asset(
              spec.asset,
              width: spec.size,
              height: spec.size,
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    );
  }
}

Offset _curvePoint(_StickerSpec spec, Size size, double t) {
  final rest = Offset(spec.restX * size.width, spec.restY * size.height);
  final offScreenX = spec.fromLeft
      ? -spec.size - 40.0
      : size.width + spec.size + 40.0;
  final start = Offset(offScreenX, rest.dy + spec.arc * size.height * 0.8);
  final controlX = spec.fromLeft ? size.width * 0.72 : size.width * 0.28;
  final control = Offset(controlX, rest.dy - spec.arc * size.height * 1.6);
  final u = 1 - t;
  return Offset(
    u * u * start.dx + 2 * u * t * control.dx + t * t * rest.dx,
    u * u * start.dy + 2 * u * t * control.dy + t * t * rest.dy,
  );
}

class _GoogleSignInButton extends StatefulWidget {
  const _GoogleSignInButton({
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
  State<_GoogleSignInButton> createState() => _GoogleSignInButtonState();
}

class _GoogleSignInButtonState extends State<_GoogleSignInButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _pressed ? 0.97 : 1,
      duration: const Duration(milliseconds: 100),
      child: Material(
        color: widget.busy
            ? GoogleAuthScreen._brandYellow.withValues(alpha: 0.7)
            : GoogleAuthScreen._brandYellow,
        borderRadius: BorderRadius.circular(27.r),
        child: InkWell(
          onTap: widget.busy ? null : widget.onTap,
          onTapDown:
              widget.busy ? null : (_) => setState(() => _pressed = true),
          onTapUp:
              widget.busy ? null : (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          borderRadius: BorderRadius.circular(27.r),
          child: SizedBox(
            width: double.infinity,
            height: 54.h,
            child: Center(
              child: widget.busy
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox.square(
                          dimension: 19.w,
                          child: const CircularProgressIndicator(
                            strokeWidth: 2.3,
                            color: Color(0xff101010),
                          ),
                        ),
                        SizedBox(width: 10.w),
                        Text(
                          widget.busyLabel,
                          style: TextStyle(
                            color: const Color(0xff101010),
                            fontSize: 15.sp,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    )
                  : Text(
                      widget.label,
                      style: TextStyle(
                        color: const Color(0xff101010),
                        fontSize: 15.sp,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
