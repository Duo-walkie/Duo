import 'package:one_one_app/one_one.dart';

// 3. Draggable PiP — must be a direct Stack child

class LiveSessionFloatingPip extends StatefulWidget {
  const LiveSessionFloatingPip({super.key, required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<LiveSessionFloatingPip> createState() => _LiveSessionFloatingPipState();
}

class _LiveSessionFloatingPipState extends State<LiveSessionFloatingPip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  LiveSessionOverlayData? _data;
  Offset _position = Offset.zero;
  bool _positioned = false;

  @override
  void initState() {
    super.initState();
    _data = LiveSessionOverlayController.instance.state.value;
    LiveSessionOverlayController.instance.state.addListener(_onSessionChanged);
  }

  void _onSessionChanged() {
    if (!mounted) return;
    setState(() {
      _data = LiveSessionOverlayController.instance.state.value;
    });
  }

  @override
  void dispose() {
    LiveSessionOverlayController.instance.state.removeListener(
      _onSessionChanged,
    );
    _pulseController.dispose();
    super.dispose();
  }

  void _returnToHome() {
    widget.navigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  void _onDragUpdate(DragUpdateDetails details, Size screenSize) {
    const w = 204.0;
    const h = 56.0;
    const margin = 12.0;
    setState(() {
      _position = Offset(
        (_position.dx + details.delta.dx).clamp(
          margin,
          screenSize.width - w - margin,
        ),
        (_position.dy + details.delta.dy).clamp(
          margin,
          screenSize.height - h - margin,
        ),
      );
    });
  }

  Offset _defaultPosition(Size screenSize) {
    return Offset(
      screenSize.width - 204.0 - 16,
      screenSize.height - 56.0 - 120,
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) return const SizedBox.shrink();

    final screenSize = MediaQuery.sizeOf(context);
    if (!_positioned) {
      _position = _defaultPosition(screenSize);
      _positioned = true;
    }

    return Positioned(
      left: _position.dx,
      top: _position.dy,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => _onDragUpdate(d, screenSize),
        onTap: _returnToHome,
        child: _PipContainer(data: data, pulseController: _pulseController),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// PiP visual container
// ---------------------------------------------------------------------------

class _PipContainer extends StatelessWidget {
  const _PipContainer({required this.data, required this.pulseController});

  final LiveSessionOverlayData data;
  final AnimationController pulseController;

  @override
  Widget build(BuildContext context) {
    final accent = data.accentColor;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 204,
        height: 56,
        decoration: BoxDecoration(
          color: const Color(0xf2141414),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: const Color(0xff7CFF6B).withValues(alpha: 0.35),
            width: 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xff7CFF6B).withValues(alpha: 0.08),
              blurRadius: 16,
              spreadRadius: 0,
            ),
            const BoxShadow(
              color: Color(0xaa000000),
              blurRadius: 18,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              // Avatar with pulsing live badge
              SizedBox(
                width: 40,
                height: 40,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: accent.withValues(alpha: 0.65),
                          width: 1.5,
                        ),
                      ),
                      child: ClipOval(
                        child: ProfileAvatar(
                          profilePhotoUrl: data.member.profilePhotoUrl,
                          profilePhotoBase64: data.member.profilePhotoBase64,
                          avatarAsset: data.member.avatarAsset,
                          radius: 20,
                          backgroundColor: const Color(0xff2a2a2a),
                          fallback: Text(
                            profileDisplayInitial(data.member.displayName),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Live indicator badge
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: AnimatedBuilder(
                        animation: pulseController,
                        builder: (context, _) {
                          return Container(
                            width: 11,
                            height: 11,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xff7CFF6B),
                              border: Border.all(
                                color: const Color(0xff141414),
                                width: 1.5,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xff7CFF6B).withValues(
                                    alpha: 0.25 + 0.6 * pulseController.value,
                                  ),
                                  blurRadius: 5,
                                  spreadRadius: 0,
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 9),
              // Name + Live label
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.groupName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.15,
                        letterSpacing: 0.1,
                      ),
                    ),
                    const SizedBox(height: 1),
                    const Text(
                      'Live',
                      style: TextStyle(
                        color: Color(0xff7CFF6B),
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.4,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Actual LiveKit microphone toggle.
              GestureDetector(
                onTap: data.onToggleMicrophone,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: data.microphoneMuted
                        ? const Color(0xffff5a5f).withValues(alpha: 0.2)
                        : Colors.white.withValues(alpha: 0.09),
                    border: Border.all(
                      color: data.microphoneMuted
                          ? const Color(0xffff5a5f).withValues(alpha: 0.65)
                          : Colors.white.withValues(alpha: 0.18),
                      width: 1.0,
                    ),
                  ),
                  child: Icon(
                    data.microphoneMuted
                        ? Icons.mic_off_rounded
                        : Icons.mic_rounded,
                    color: data.microphoneMuted
                        ? const Color(0xffff5a5f)
                        : Colors.white60,
                    size: 16,
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
