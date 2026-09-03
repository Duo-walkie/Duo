part of '../../identity_home_screen.dart';

// 1. Center avatar / join / talk control.
// 2. Loader, transmit ripples, sleep-Z, member collage.

class _MainAvatarCircle extends StatelessWidget {
  const _MainAvatarCircle({
    required this.item,
    required this.selected,
    required this.connected,
    required this.connecting,
    required this.talkEnabled,
    required this.joinEnabled,
    required this.talkActive,
    required this.talkBusy,
    required this.accent,
    required this.nudgeMode,
    required this.goLiveMode,
    required this.onNudge,
    required this.onTalkStart,
    required this.onTalkStop,
    required this.onJoin,
  });

  final _CarouselItem item;
  final bool selected;
  final bool connected;
  final bool connecting;
  final bool talkEnabled;
  final bool joinEnabled;
  final bool talkActive;
  final bool talkBusy;
  final Color accent;

  /// True when this focused card should open the nudge sheet (👋) instead of
  /// join/talk — whole group offline, or live elsewhere viewing this group.
  final bool nudgeMode;

  /// True when an offline user can directly join an active LiveKit room.
  final bool goLiveMode;
  final VoidCallback? onNudge;
  final Future<void> Function() onTalkStart;
  final Future<void> Function() onTalkStop;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final size = 110.w;
    // Yellow ring only while the local user is actively transmitting.
    final borderColor = connecting
        ? Colors.white54
        : connected
        ? (talkActive ? const Color(0xffffd54f) : const Color(0xff28A745))
        : nudgeMode
        ? Colors.white38
        : Colors.white;

    Widget circle = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: borderColor,
          width: connected || connecting ? 4 : (selected ? 2.5 : 2),
        ),
      ),
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedOpacity(
              duration: const Duration(milliseconds: 220),
              opacity: (nudgeMode || goLiveMode || connecting) ? 0.38 : 1,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: goLiveMode ? 2.4 : 0,
                  sigmaY: goLiveMode ? 2.4 : 0,
                ),
                child: _MemberPhotoCollage(
                  members: item.members,
                  fallbackPhotoUrl: item.profilePhotoUrl,
                  fallbackPhotoBase64: item.profilePhotoBase64,
                  fallbackAvatarAsset: item.avatarAsset,
                  tileSize: size,
                ),
              ),
            ),
            if (goLiveMode && !connecting) ...[
              const ColoredBox(color: Color(0x40000000)),
              Center(
                child: Text(
                  context.l10n.homeJoinQuestion,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 19.sp,
                    fontWeight: FontWeight.w800,
                    shadows: const [Shadow(color: Colors.black, blurRadius: 8)],
                  ),
                ),
              ),
            ],
            // Bottom fade lifts live glyphs without fully masking profiles.
            if (connected && !connecting)
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x00000000),
                      Color(0x66000000),
                      Color(0x99000000),
                    ],
                    stops: [0.3, 0.68, 1],
                  ),
                ),
              ),
            // Nudge wave stays inside the clipped circle (offline state).
            if (nudgeMode && !connecting)
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.only(bottom: size * 0.1),
                  child: Text('👋', style: TextStyle(fontSize: size * 0.22)),
                ),
              ),
          ],
        ),
      ),
    );

    final plateSize = size * 0.96;
    final glyphSize = size * 0.88;
    if (connecting || connected) {
      // ~2–3 logical px shrink while transmitting for a pressed feel.
      final transmitInset = talkActive && !connecting ? 2.5.w : 0.0;
      circle = SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            // Compact radial ripples sit outside the solid border so
            // transmitting reads clearly without enlarging the button hit area.
            if (talkActive && !connecting)
              Positioned.fill(
                child: IgnorePointer(
                  child: _TransmitRadialVisualizer(
                    color: const Color(0xffffd54f),
                    diameter: size,
                  ),
                ),
              ),
            circle,
            Positioned(
              left: 0,
              right: 0,
              bottom: size * 0.02,
              child: Center(
                child: Container(
                  width: plateSize,
                  height: plateSize,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.35),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 10,
                        spreadRadius: 0,
                      ),
                    ],
                  ),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 240),
                    transitionBuilder: (child, animation) => ScaleTransition(
                      scale: animation,
                      child: FadeTransition(opacity: animation, child: child),
                    ),
                    child: connecting
                        ? _MainButtonDotsLoader(
                            key: const ValueKey('main-connecting'),
                            size: glyphSize * 0.52,
                          )
                        : AnimatedScale(
                            key: const ValueKey('main-walkie'),
                            scale: talkActive
                                ? (glyphSize - transmitInset * 2) / glyphSize
                                : 1,
                            duration: const Duration(milliseconds: 90),
                            curve: Curves.easeOut,
                            child: Image.asset(
                              'assets/walkie.png',
                              width: glyphSize,
                              height: glyphSize,
                              fit: BoxFit.contain,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (!connecting && (talkEnabled || joinEnabled || nudgeMode)) {
      circle = Semantics(
        button: true,
        label: goLiveMode
            ? 'Join the conversation in ${item.group.name}'
            : joinEnabled
            ? 'Join ${item.group.name}'
            : nudgeMode
            ? 'Nudge ${item.group.name}'
            : talkActive
            ? 'Stop talking'
            : context.l10n.homeTapToTalk,
        child: GestureDetector(
          onTap: talkBusy
              ? null
              : () {
                  if (joinEnabled) {
                    onJoin();
                    return;
                  }
                  if (nudgeMode) {
                    onNudge?.call();
                    return;
                  }
                  if (talkActive) {
                    unawaited(onTalkStop());
                  } else {
                    unawaited(onTalkStart());
                  }
                },
          child: circle,
        ),
      );
    }

    final content = AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: talkBusy ? 0.65 : 1,
      child: circle,
    );

    if (!nudgeMode || connecting) return content;

    // Rising "Z"s sit outside ClipOval so they can keep travelling past the
    // button's ring and fade out in open space (instead of being clipped or
    // orbiting the edge). Same up-and-right drift as the previous design.
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          content,
          Positioned(
            right: size * 0.08,
            top: size * 0.06,
            child: IgnorePointer(child: _SleepZAnimation(size: size * 0.3)),
          ),
        ],
      ),
    );
  }
}

/// Three-dot pulse used on the main circle while LiveKit is connecting.
class _MainButtonDotsLoader extends StatefulWidget {
  const _MainButtonDotsLoader({super.key, required this.size});

  final double size;

  @override
  State<_MainButtonDotsLoader> createState() => _MainButtonDotsLoaderState();
}

class _MainButtonDotsLoaderState extends State<_MainButtonDotsLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = widget.size * 0.28;
    return SizedBox(
      width: widget.size,
      height: widget.size * 0.45,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) SizedBox(width: widget.size * 0.1),
                _dot(i, dot),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _dot(int index, double diameter) {
    final t = ((_controller.value + (1 - index * 0.22)) % 1.0);
    final bounce = sin(t * pi);
    final scale = 0.55 + 0.45 * bounce;
    final opacity = 0.35 + 0.65 * bounce;
    return Transform.translate(
      offset: Offset(0, -widget.size * 0.12 * bounce),
      child: Transform.scale(
        scale: scale,
        child: Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: opacity),
          ),
        ),
      ),
    );
  }
}

/// Compact expanding rings around the talk button while transmitting.
/// Timer-driven (no LiveKit visualizer dependency) for a light CPU cost.
class _TransmitRadialVisualizer extends StatefulWidget {
  const _TransmitRadialVisualizer({
    required this.color,
    required this.diameter,
  });

  final Color color;
  final double diameter;

  @override
  State<_TransmitRadialVisualizer> createState() =>
      _TransmitRadialVisualizerState();
}

class _TransmitRadialVisualizerState extends State<_TransmitRadialVisualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return CustomPaint(
          painter: _TransmitRipplePainter(
            progress: _controller.value,
            color: widget.color,
          ),
          size: Size.square(widget.diameter),
        );
      },
    );
  }
}

class _TransmitRipplePainter extends CustomPainter {
  _TransmitRipplePainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = size.shortestSide / 2;
    // Three staggered ripples, short travel beyond the solid outline.
    for (var i = 0; i < 3; i++) {
      final t = (progress + i / 3) % 1.0;
      final radius = baseRadius + 2 + t * 10;
      final opacity = (1 - t) * 0.45;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 * (1 - t * 0.5)
        ..color = color.withValues(alpha: opacity);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TransmitRipplePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

/// Looping "Z"s drifting up-and-right and fading for the fully-offline nudge
/// state. Hosted outside the button ClipOval so glyphs clear the ring before
/// dissolving.
class _SleepZAnimation extends StatefulWidget {
  const _SleepZAnimation({required this.size});

  final double size;

  @override
  State<_SleepZAnimation> createState() => _SleepZAnimationState();
}

class _SleepZAnimationState extends State<_SleepZAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Stack(
            clipBehavior: Clip.none,
            children: [for (var i = 0; i < 3; i++) _buildZ(i)],
          );
        },
      ),
    );
  }

  Widget _buildZ(int i) {
    // Three staggered "Z"s rise up-and-right. Travel is long enough that they
    // clearly pass the button outline; the fade starts later so most of the
    // dissolve happens once they're outside the ring.
    final t = ((_controller.value + i * 0.33) % 1.0);
    final opacity = t < 0.12
        ? Curves.easeOut.transform(t / 0.12)
        : t > 0.55
        ? Curves.easeIn.transform((1 - t) / 0.45).clamp(0.0, 1.0)
        : 1.0;
    final scale =
        0.88 + 0.22 * Curves.easeOut.transform((t * 1.4).clamp(0.0, 1.0));
    return Positioned(
      // Extra outward travel vs the older in-circle version so glyphs leave
      // the ring before fully fading.
      right: -t * widget.size * 0.85,
      top: widget.size * 0.55 - t * widget.size * 1.45,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: scale,
          child: Text(
            'Z',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.92),
              fontSize: widget.size * (0.42 + i * 0.1),
              fontWeight: FontWeight.w800,
              height: 1,
              letterSpacing: -0.5,
              shadows: const [
                Shadow(
                  color: Colors.black54,
                  blurRadius: 6,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tiles every group member inside the connect circle. Falls back to a single
/// self-avatar when member data isn't loaded yet.
class _MemberPhotoCollage extends StatelessWidget {
  const _MemberPhotoCollage({
    required this.members,
    required this.fallbackPhotoUrl,
    required this.fallbackPhotoBase64,
    required this.fallbackAvatarAsset,
    required this.tileSize,
  });

  final List<GroupMemberSummary> members;
  final String? fallbackPhotoUrl;
  final String? fallbackPhotoBase64;
  final String? fallbackAvatarAsset;
  final double tileSize;

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) {
      return ProfileImage(
        profilePhotoUrl: fallbackPhotoUrl,
        profilePhotoBase64: fallbackPhotoBase64,
        avatarAsset: fallbackAvatarAsset,
        backgroundColor: const Color(0xff2a2a2a),
        fadeInDuration: Duration.zero,
        fallback: Icon(
          Icons.person_outline,
          color: Colors.white70,
          size: tileSize * 0.4,
        ),
      );
    }

    final columns = sqrt(members.length).ceil();
    final rows = (members.length / columns).ceil();

    Widget tile(GroupMemberSummary member) {
      final initial = profileDisplayInitial(member.displayName);
      return ProfileImage(
        // Keyed by user ID so switching groups never reuses another user's
        // ProfileImage state (and its sticky-photo cache) by position.
        key: ValueKey(member.userId),
        profilePhotoUrl: member.profilePhotoUrl,
        profilePhotoBase64: member.profilePhotoBase64,
        avatarAsset: member.avatarAsset,
        backgroundColor: const Color(0xff2a2a2a),
        fadeInDuration: Duration.zero,
        fallback: Text(
          initial,
          style: TextStyle(
            color: Colors.white,
            fontSize: tileSize * 0.16 / columns,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    return GridView.builder(
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: members.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        childAspectRatio: rows / columns,
        crossAxisSpacing: 1.5,
        mainAxisSpacing: 1.5,
      ),
      itemBuilder: (context, index) => tile(members[index]),
    );
  }
}
