import 'package:one_one_app/one_one.dart';

class EmojiBurstOverlay extends StatelessWidget {
  const EmojiBurstOverlay({
    super.key,
    required this.bursts,
    required this.onBurstFinished,
  });

  final List<EmojiBurst> bursts;
  final ValueChanged<String> onBurstFinished;

  @override
  Widget build(BuildContext context) {
    if (bursts.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: Stack(
        children: [
          for (final burst in bursts)
            _EmojiBurstEffect(
              key: ValueKey(burst.id),
              burst: burst,
              onCompleted: () => onBurstFinished(burst.id),
            ),
        ],
      ),
    );
  }
}

class _EmojiBurstEffect extends StatefulWidget {
  const _EmojiBurstEffect({
    super.key,
    required this.burst,
    required this.onCompleted,
  });

  final EmojiBurst burst;
  final VoidCallback onCompleted;

  @override
  State<_EmojiBurstEffect> createState() => _EmojiBurstEffectState();
}

class _EmojiBurstEffectState extends State<_EmojiBurstEffect>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<_ParticleSpec> _particles;

  @override
  void initState() {
    super.initState();
    final config = widget.burst.config;
    _controller =
        AnimationController(
          vsync: this,
          duration: Duration(milliseconds: config.totalDurationMs),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) widget.onCompleted();
        });
    _particles = _ParticleSpec.generate(config);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.burst.config;
    final name = widget.burst.senderName.trim().isEmpty
        ? 'friend'
        : widget.burst.senderName.trim().toLowerCase();

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = constraints.maxHeight;
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              // Name stays readable through most of the burst, then fades
              // with the last particles so attribution doesn't linger alone.
              final t = _controller.value;
              final nameOpacity = t < 0.08
                  ? t / 0.08
                  : t > 0.72
                  ? (1 - (t - 0.72) / 0.28).clamp(0.0, 1.0)
                  : 1.0;
              final originY = height * config.originHeightFraction;

              return Stack(
                children: [
                  for (final particle in _particles)
                    particle.build(
                      emoji: widget.burst.emoji,
                      config: config,
                      overallProgress: t,
                      width: width,
                      height: height,
                    ),
                  // Sender label anchored just under the spawn point so you
                  // can tell who fired the burst without crowding the stream.
                  Positioned(
                    left: 0,
                    right: 0,
                    top: originY + 6.h,
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: nameOpacity,
                        child: Text(
                          name,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 11.sp,
                            fontWeight: FontWeight.w600,
                            shadows: const [
                              Shadow(color: Colors.black, blurRadius: 8),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Randomized per-particle timing/placement, generated once per burst so the
/// stream reads as organic rather than mechanically identical copies.
class _ParticleSpec {
  _ParticleSpec({
    required this.startFraction,
    required this.durationFraction,
    required this.xFraction,
    required this.riseFraction,
    required this.size,
    required this.wobbleFrequency,
    required this.wobblePhase,
    required this.wobbleScale,
    required this.rotation,
  });

  final double startFraction;
  final double durationFraction;
  final double xFraction;
  final double riseFraction;
  final double size;
  final double wobbleFrequency;
  final double wobblePhase;
  final double wobbleScale;
  final double rotation;

  static final _random = Random();

  static List<_ParticleSpec> generate(EmojiBurstConfig config) {
    final total = config.totalDurationMs;
    final count = config.particleCount;
    return List.generate(count, (i) {
      final startMs = i * config.staggerMs;
      final durationMs =
          config.minDurationMs +
          _random.nextDouble() * (config.maxDurationMs - config.minDurationMs);
      // Stratified horizontal placement (spread evenly across the target
      // width) plus a little jitter, so particles fan out instead of
      // clumping near the center.
      final slot = count == 1 ? 0.0 : (i / (count - 1)) - 0.5;
      final jitter = (_random.nextDouble() - 0.5) * 0.22;
      return _ParticleSpec(
        startFraction: startMs / total,
        durationFraction: durationMs / total,
        xFraction: (slot + jitter) * config.spreadWidth,
        riseFraction: config.riseHeight * (0.8 + _random.nextDouble() * 0.35),
        size:
            config.minEmojiSize +
            _random.nextDouble() * (config.maxEmojiSize - config.minEmojiSize),
        wobbleFrequency: 1.3 + _random.nextDouble() * 1.7,
        wobblePhase: _random.nextDouble() * 2 * pi,
        wobbleScale: 0.6 + _random.nextDouble() * 0.7,
        rotation: (_random.nextDouble() - 0.5) * 0.5,
      );
    });
  }

  Widget build({
    required String emoji,
    required EmojiBurstConfig config,
    required double overallProgress,
    required double width,
    required double height,
  }) {
    if (overallProgress <= startFraction) return const SizedBox.shrink();
    final localProgress = durationFraction <= 0
        ? 1.0
        : ((overallProgress - startFraction) / durationFraction).clamp(
            0.0,
            1.0,
          );
    if (localProgress >= 1) return const SizedBox.shrink();

    final rise = Curves.easeOutCubic.transform(localProgress);
    final originY = height * config.originHeightFraction;
    final y = originY - height * riseFraction * rise;

    final wobbleDamping = 1 - localProgress * 0.5;
    final wobble =
        sin(localProgress * wobbleFrequency * 2 * pi + wobblePhase) *
        config.wobbleAmplitude *
        wobbleScale *
        wobbleDamping;
    final x = width / 2 + xFraction * width + wobble;

    // Quick fade-in, hold, then fade out over the final third of the flight.
    final opacity = localProgress < 0.12
        ? localProgress / 0.12
        : localProgress > 0.65
        ? (1 - (localProgress - 0.65) / 0.35).clamp(0.0, 1.0)
        : 1.0;

    // Small pop-in overshoot at spawn, then settles to full size.
    final scale = localProgress < 0.22
        ? Curves.easeOutBack.transform(localProgress / 0.22).clamp(0.0, 1.2)
        : 1.0;

    return Positioned(
      left: x - size,
      top: y - size,
      child: IgnorePointer(
        child: Opacity(
          opacity: opacity,
          child: Transform.rotate(
            angle: rotation * rise,
            child: Transform.scale(
              scale: scale,
              child: Text(emoji, style: TextStyle(fontSize: size.sp)),
            ),
          ),
        ),
      ),
    );
  }
}
