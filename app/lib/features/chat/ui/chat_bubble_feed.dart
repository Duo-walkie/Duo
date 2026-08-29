import 'package:one_one_app/one_one.dart';

/// Renders sent chat bubbles in the group screen's cleared center area. Own
/// messages align right, others' align left; every bubble shows the
/// sender's name and self-removes once [expiresAt] elapses via its own
/// independent timer (see [_ChatBubbleTile]). The host caps how many past
/// bubbles stay in the list (rolling window).
class ChatBubbleFeed extends StatelessWidget {
  const ChatBubbleFeed({
    super.key,
    required this.messages,
    required this.currentUserId,
    required this.accent,
    required this.onExpire,
    this.displayNameForUserId,
    this.opacity = 1,
  });

  final List<GroupChatMessage> messages;
  final String currentUserId;
  final Color accent;
  final ValueChanged<String> onExpire;
  final String Function(String userId, String fallback)? displayNameForUserId;

  /// Host-driven fade (e.g. clearing offline history when anyone goes live).
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final visible = messages
        .where((message) => !message.isExpired)
        .toList(growable: false);
    if (visible.isEmpty) return const SizedBox.shrink();

    // Stretch so each row is full-width; without that, MainAxisAlignment
    // start/end has no room to pin bubbles left (theirs) vs right (ours).
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      opacity: opacity.clamp(0.0, 1.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final message in visible)
            _ChatBubbleTile(
              key: ValueKey(message.messageId),
              message: message,
              isOwn: message.senderUserId == currentUserId,
              senderLabel: _senderLabel(message),
              accent: accent,
              onExpire: () => onExpire(message.messageId),
            ),
        ],
      ),
    );
  }

  String _senderLabel(GroupChatMessage message) {
    if (message.senderUserId == currentUserId) return 'You';
    final resolved = displayNameForUserId?.call(
      message.senderUserId,
      message.senderDisplayName,
    );
    return resolved ?? message.senderDisplayName;
  }
}

class _ChatBubbleTile extends StatefulWidget {
  const _ChatBubbleTile({
    super.key,
    required this.message,
    required this.isOwn,
    required this.senderLabel,
    required this.accent,
    required this.onExpire,
  });

  final GroupChatMessage message;
  final bool isOwn;
  final String senderLabel;
  final Color accent;
  final VoidCallback onExpire;

  @override
  State<_ChatBubbleTile> createState() => _ChatBubbleTileState();
}

class _ChatBubbleTileState extends State<_ChatBubbleTile> {
  Timer? _expiryTimer;
  Timer? _fadeTimer;

  @override
  void initState() {
    super.initState();
    _armTimers();
  }

  @override
  void didUpdateWidget(covariant _ChatBubbleTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.expiresAt != widget.message.expiresAt ||
        oldWidget.message.createdAt != widget.message.createdAt) {
      _armTimers();
    }
  }

  void _armTimers() {
    _expiryTimer?.cancel();
    _fadeTimer?.cancel();
    final seconds = widget.message.secondsUntilExpiry;
    if (seconds <= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onExpire();
      });
      return;
    }
    _expiryTimer = Timer(Duration(seconds: seconds), () {
      if (mounted) widget.onExpire();
    });
    final untilFade = widget.message.secondsUntilFadeStarts;
    if (untilFade > 0) {
      _fadeTimer = Timer(Duration(seconds: untilFade), _startFadeTicker);
    } else if (widget.message.opacityAt() < 1) {
      _startFadeTicker();
    }
  }

  void _startFadeTicker() {
    _fadeTimer?.cancel();
    _fadeTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    _fadeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final isOwn = widget.isOwn;
    final fade = message.opacityAt();
    final radius = BorderRadius.only(
      topLeft: Radius.circular(18.r),
      topRight: Radius.circular(18.r),
      bottomLeft: Radius.circular(isOwn ? 18.r : 5.r),
      bottomRight: Radius.circular(isOwn ? 5.r : 18.r),
    );

    return Opacity(
      opacity: fade,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 2.h),
        child: Row(
          mainAxisAlignment: isOwn
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 240.w),
              child: Column(
                crossAxisAlignment: isOwn
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12.w),
                    child: Text(
                      widget.senderLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 10.sp,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  SizedBox(height: 2.h),
                  // Frosted chip — soft gradient + blur instead of a flat fill.
                  ClipRRect(
                    borderRadius: radius,
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: radius,
                          border: Border.all(
                            color: isOwn
                                ? widget.accent.withValues(alpha: 0.45)
                                : Colors.white.withValues(alpha: 0.14),
                            width: 1,
                          ),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: isOwn
                                ? [
                                    widget.accent.withValues(alpha: 0.38),
                                    widget.accent.withValues(alpha: 0.14),
                                    Colors.white.withValues(alpha: 0.04),
                                  ]
                                : [
                                    Colors.white.withValues(alpha: 0.14),
                                    Colors.white.withValues(alpha: 0.05),
                                    Colors.black.withValues(alpha: 0.18),
                                  ],
                            stops: const [0.0, 0.55, 1.0],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.28),
                              blurRadius: 16,
                              offset: Offset(0, 6.h),
                            ),
                            if (isOwn)
                              BoxShadow(
                                color: widget.accent.withValues(alpha: 0.18),
                                blurRadius: 20,
                                offset: Offset(0, 2.h),
                              ),
                          ],
                        ),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 14.w,
                            vertical: 7.h,
                          ),
                          child: Text(
                            message.text,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.94),
                              fontSize: 13.sp,
                              fontWeight: FontWeight.w500,
                              height: 1.25,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
