import 'package:one_one_app/one_one.dart';

/// Heartbeat "beep" pulse on the Duo mark.
///
/// Animation shape: quick scale punch, settle, pause, repeat.
class DuoLogoLoading extends StatefulWidget {
  const DuoLogoLoading({super.key, this.logoHeight});

  final double? logoHeight;

  @override
  State<DuoLogoLoading> createState() => _DuoLogoLoadingState();
}

class _DuoLogoLoadingState extends State<DuoLogoLoading>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 1.0,
        end: 1.18,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 14,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 1.18,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeIn)),
      weight: 20,
    ),
    TweenSequenceItem(tween: ConstantTween<double>(1.0), weight: 66),
  ]).animate(_controller);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logoHeight = widget.logoHeight ?? 72.0;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.scale(scale: _scale.value, child: child);
      },
      child: Image.asset(
        'assets/logo.png',
        height: logoHeight,
        fit: BoxFit.contain,
      ),
    );
  }
}

/// Full-screen dimmer with a pulsing Duo mark. Must be given tight
/// constraints ([Positioned.fill] or [SizedBox.expand]) so it covers
/// the screen behind it.
class InviteJoinOverlay extends StatelessWidget {
  const InviteJoinOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return const AbsorbPointer(
      child: ColoredBox(
        // ~35% black — binoculars stay clearly visible underneath.
        color: Color(0x59000000),
        child: Center(child: DuoLogoLoading()),
      ),
    );
  }
}
