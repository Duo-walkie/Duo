part of 'nudge_screen.dart';

// Sheet widgets: pulse, actions, badges, recipient chip, status.

// ── Sending animation ──────────────────────────────────────────────────────

class _SendingVoicePulse extends StatefulWidget {
  const _SendingVoicePulse({required this.accent});
  final Color accent;

  @override
  State<_SendingVoicePulse> createState() => _SendingVoicePulseState();
}

class _SendingVoicePulseState extends State<_SendingVoicePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
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
        final t = _controller.value;
        return Stack(
          alignment: Alignment.center,
          fit: StackFit.expand,
          children: [
            _ripple((t + 0.0) % 1.0),
            _ripple((t + 0.5) % 1.0),
            Transform.translate(
              offset: Offset(0, -3.r * sin(t * 2 * pi)),
              child: Icon(Icons.send_rounded, size: 32.sp, color: Colors.white),
            ),
          ],
        );
      },
    );
  }

  Widget _ripple(double progress) {
    final scale = 0.5 + progress * 0.85;
    final opacity = (1 - progress) * 0.5;
    return Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: Transform.scale(
        scale: scale,
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1.4),
          ),
        ),
      ),
    );
  }
}

// ── Shared divider ─────────────────────────────────────────────────────────

class _SheetDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Divider(
      color: Colors.white.withValues(alpha: 0.06),
      height: 1,
      indent: 20.w,
      endIndent: 20.w,
    );
  }
}

class _RingActionButton extends StatefulWidget {
  const _RingActionButton({
    required this.enabled,
    required this.onRingCount,
    this.cooldownLabel,
  });

  final bool enabled;
  final ValueChanged<int> onRingCount;
  final String? cooldownLabel;

  @override
  State<_RingActionButton> createState() => _RingActionButtonState();
}

class _RingActionButtonState extends State<_RingActionButton> {
  Timer? _dispatchTimer;
  int _tapCount = 0;

  void _queueRing() {
    if (!widget.enabled || _tapCount >= 3) return;
    setState(() => _tapCount++);
    _dispatchTimer?.cancel();
    _dispatchTimer = Timer(const Duration(milliseconds: 350), () {
      final count = _tapCount;
      if (!mounted || count == 0) return;
      setState(() => _tapCount = 0);
      widget.onRingCount(count);
    });
  }

  @override
  void dispose() {
    _dispatchTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: 'Ring their phone',
      child: GestureDetector(
        onTap: widget.enabled ? _queueRing : null,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: 72.w, minHeight: 48.h),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.all(8.r),
                child: Icon(
                  LucideIcons.bellRing,
                  color: widget.enabled ? Colors.white70 : Colors.white24,
                  size: 28.sp,
                ),
              ),
              SizedBox(height: 4.h),
              Text(
                widget.cooldownLabel ??
                    (_tapCount > 1 ? 'Ring ×$_tapCount' : 'Ring'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: widget.enabled ? Colors.white54 : Colors.white24,
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PushActionButton extends StatelessWidget {
  const _PushActionButton({
    required this.enabled,
    required this.onTap,
    this.cooldownLabel,
  });

  final bool enabled;
  final VoidCallback onTap;
  final String? cooldownLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      label: 'Send a notification',
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: 72.w, minHeight: 48.h),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.all(8.r),
                child: Icon(
                  LucideIcons.send,
                  color: enabled ? Colors.white70 : Colors.white24,
                  size: 28.sp,
                ),
              ),
              SizedBox(height: 4.h),
              Text(
                cooldownLabel ?? 'Notify',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: enabled ? Colors.white54 : Colors.white24,
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VolumeBadgeIcon extends StatelessWidget {
  const _VolumeBadgeIcon({required this.band});

  final MediaVolumeBand band;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (band) {
      MediaVolumeBand.muted => (LucideIcons.volumeX, const Color(0xffff4040)),
      MediaVolumeBand.veryLow => (LucideIcons.volume, const Color(0xffff4040)),
      MediaVolumeBand.low => (LucideIcons.volume1, const Color(0xffe0a83c)),
      MediaVolumeBand.ok => (LucideIcons.volume2, const Color(0xff4caf50)),
    };
    return _AvatarCornerBadge(icon: icon, color: color);
  }
}

class _ResponseBadgeIcon extends StatelessWidget {
  const _ResponseBadgeIcon({required this.reply});

  final NudgeRecipientReply reply;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (reply) {
      NudgeRecipientReply.declined => (Icons.dark_mode_rounded, Colors.white70),
      NudgeRecipientReply.snoozed => (
        LucideIcons.timer,
        const Color(0xffe0a83c),
      ),
    };
    return _AvatarCornerBadge(icon: icon, color: color);
  }
}

class _AvatarCornerBadge extends StatelessWidget {
  const _AvatarCornerBadge({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26.r,
      height: 26.r,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xff1c1c1c),
      ),
      child: Center(
        child: Icon(icon, size: 15.sp, color: color),
      ),
    );
  }
}

// ── Recipient chip ─────────────────────────────────────────────────────────

class _PendingRecipient {
  const _PendingRecipient({required this.userId, required this.displayName});

  final String userId;
  final String displayName;
}

class _NudgeRecipient extends StatelessWidget {
  const _NudgeRecipient({
    required this.label,
    required this.selected,
    required this.accent,
    required this.avatar,
    required this.onTap,
    this.enabled = true,
    this.dimmed = false,
    this.subtitle,
    this.deliveryBadge,
  });

  final String label;
  final bool selected;
  final Color accent;
  final Widget avatar;
  final VoidCallback? onTap;
  final bool enabled;
  final bool dimmed;
  final String? subtitle;

  /// Small icon widget shown at the bottom-right corner of the avatar circle.
  /// Used for Lucide volume badges. Skull state is embedded in [avatar] itself.
  final Widget? deliveryBadge;

  @override
  Widget build(BuildContext context) {
    final tap = enabled ? onTap : null;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: subtitle != null ? '$label, $subtitle' : 'Send to $label',
      child: InkWell(
        onTap: tap,
        borderRadius: BorderRadius.circular(18.r),
        child: SizedBox(
          width: 68.w,
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: EdgeInsets.all(2.r),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xff1e1e1e),
                      border: Border.all(
                        color: selected ? accent : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: ClipOval(
                      child: SizedBox(width: 46.r, height: 46.r, child: avatar),
                    ),
                  ),
                  if (deliveryBadge != null)
                    Positioned(right: -6, bottom: -6, child: deliveryBadge!),
                ],
              ),
              SizedBox(height: 5.h),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: dimmed
                      ? Colors.white30
                      : selected
                      ? Colors.white
                      : Colors.white54,
                  fontSize: 10.sp,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white24,
                    fontSize: 8.sp,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NudgeStatus extends StatelessWidget {
  const _NudgeStatus({
    required this.message,
    required this.isError,
    this.isWarning = false,
    this.isPending = false,
  });

  final String message;
  final bool isError;
  final bool isWarning;
  final bool isPending;

  @override
  Widget build(BuildContext context) {
    final color = isPending
        ? const Color(0xffe0a83c)
        : isError
        ? const Color(0xffff6b6f)
        : isWarning
        ? const Color(0xffe0a83c)
        : const Color(0xff9bdc28);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isPending)
            Padding(
              padding: EdgeInsets.only(top: 1.h),
              child: SizedBox(
                width: 15.sp,
                height: 15.sp,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              ),
            )
          else
            Icon(
              isError
                  ? Icons.error_outline_rounded
                  : isWarning
                  ? Icons.warning_amber_rounded
                  : Icons.check_circle_outline,
              color: color,
              size: 17.sp,
            ),
          SizedBox(width: 8.w),
          Expanded(
            child: Text(
              message,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white70,
                fontSize: 11.sp,
                fontWeight: FontWeight.w500,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
