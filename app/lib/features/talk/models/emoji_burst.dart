class EmojiBurstConfig {
  const EmojiBurstConfig({
    this.particleCount = 12,
    this.spreadWidth = 0.7,
    this.riseHeight = 0.6,
    this.originHeightFraction = 0.78,
    this.minDurationMs = 900,
    this.maxDurationMs = 1500,
    this.staggerMs = 45,
    this.minEmojiSize = 22,
    this.maxEmojiSize = 38,
    this.wobbleAmplitude = 16,
  }) : assert(particleCount > 0),
       assert(spreadWidth >= 0 && spreadWidth <= 1),
       assert(riseHeight > 0 && riseHeight <= 1),
       assert(minDurationMs > 0 && minDurationMs <= maxDurationMs),
       assert(staggerMs >= 0),
       assert(minEmojiSize > 0 && minEmojiSize <= maxEmojiSize);

  static const standard = EmojiBurstConfig();

  static const singleEmoji = EmojiBurstConfig(
    particleCount: 1,
    spreadWidth: 0,
    staggerMs: 0,
  );

  /// How many emoji glyphs animate per burst.
  final int particleCount;

  /// Horizontal spread as a fraction of the overlay width the particles can
  /// land across (0 = all particles rise straight up from the origin).
  final double spreadWidth;

  /// How far up the particles travel, as a fraction of the overlay height.
  final double riseHeight;

  /// Where the stream originates, as a fraction of overlay height from the
  /// top (e.g. 0.78 starts low, near where the reaction control lives).
  final double originHeightFraction;

  /// Per-particle rise+fade duration range; each particle picks a random
  /// value in this range so the burst doesn't look mechanically uniform.
  final int minDurationMs;
  final int maxDurationMs;

  /// Delay between each successive particle's start, in milliseconds.
  /// Larger values read as a "stream", smaller values read as a "pop".
  final int staggerMs;

  /// Per-particle glyph size range (logical pixels, pre-ScreenUtil scaling).
  final double minEmojiSize;
  final double maxEmojiSize;

  /// Amplitude (logical pixels) of the side-to-side wobble as each particle
  /// rises, giving the stream some organic motion instead of dead-straight
  /// lines.
  final double wobbleAmplitude;

  /// Total wall-clock time the burst needs on screen, including stagger.
  int get totalDurationMs => maxDurationMs + staggerMs * (particleCount - 1);

  EmojiBurstConfig copyWith({
    int? particleCount,
    double? spreadWidth,
    double? riseHeight,
    double? originHeightFraction,
    int? minDurationMs,
    int? maxDurationMs,
    int? staggerMs,
    double? minEmojiSize,
    double? maxEmojiSize,
    double? wobbleAmplitude,
  }) {
    return EmojiBurstConfig(
      particleCount: particleCount ?? this.particleCount,
      spreadWidth: spreadWidth ?? this.spreadWidth,
      riseHeight: riseHeight ?? this.riseHeight,
      originHeightFraction: originHeightFraction ?? this.originHeightFraction,
      minDurationMs: minDurationMs ?? this.minDurationMs,
      maxDurationMs: maxDurationMs ?? this.maxDurationMs,
      staggerMs: staggerMs ?? this.staggerMs,
      minEmojiSize: minEmojiSize ?? this.minEmojiSize,
      maxEmojiSize: maxEmojiSize ?? this.maxEmojiSize,
      wobbleAmplitude: wobbleAmplitude ?? this.wobbleAmplitude,
    );
  }
}

/// A single "send" event that should render as a burst of [emoji] glyphs.
class EmojiBurst {
  const EmojiBurst({
    required this.id,
    required this.emoji,
    required this.senderName,
    this.config = EmojiBurstConfig.standard,
  });

  final String id;
  final String emoji;
  final String senderName;
  final EmojiBurstConfig config;
}
