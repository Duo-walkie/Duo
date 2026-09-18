import 'package:one_one_app/one_one.dart';

// 1. Prompt row data
// 2. Accept/Decline dialogue
class IncomingNudgePromptItem {
  const IncomingNudgePromptItem({
    required this.nudge,
    required this.groupName,
    required this.remainingOtherCount,
  });

  final ActiveNudge nudge;
  final String groupName;

  /// How many *other groups* still have an active nudge after this one.
  final int remainingOtherCount;

  String? get remainingHint {
    if (remainingOtherCount <= 0) return null;
    if (remainingOtherCount == 1) return '1 more nudge in another group';
    return '$remainingOtherCount more nudges in other groups';
  }

  String get typeLabel => switch (nudge.kind) {
    NudgeKind.ring => 'Ring',
    NudgeKind.voice => 'Voice',
    NudgeKind.push => 'Push',
    null => 'Nudge',
  };

  IconData get typeIcon => switch (nudge.kind) {
    NudgeKind.ring => Icons.notifications_active_rounded,
    NudgeKind.voice => Icons.mic_rounded,
    NudgeKind.push => Icons.campaign_rounded,
    null => Icons.waving_hand_rounded,
  };

  String receivedLabel({DateTime? now}) {
    final elapsed = (now ?? DateTime.now()).difference(nudge.sentAt);
    if (elapsed.isNegative || elapsed.inSeconds < 45) return 'Just now';
    if (elapsed.inMinutes < 60) {
      final minutes = elapsed.inMinutes.clamp(1, 59);
      return minutes == 1 ? '1 min ago' : '$minutes min ago';
    }
    final hours = elapsed.inHours;
    return hours == 1 ? '1 hr ago' : '$hours hr ago';
  }
}

/// Modal Accept/Decline dialogue shown on top of the relevant group.
class IncomingNudgeDialogue extends StatelessWidget {
  const IncomingNudgeDialogue({
    super.key,
    required this.item,
    required this.accent,
    required this.onAccept,
    required this.onDecline,
    this.busy = false,
    this.liveVoiceLocked = false,
  });

  final IncomingNudgePromptItem item;
  final Color accent;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final bool busy;
  final bool liveVoiceLocked;

  @override
  Widget build(BuildContext context) {
    final hint = item.remainingHint;
    final sender = item.nudge.senderName?.trim();
    final received = item.receivedLabel();
    final metaParts = <String>[
      if (sender != null && sender.isNotEmpty) 'From $sender',
      'Received $received',
    ];

    return Material(
      color: Colors.black.withValues(alpha: 0.58),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 28.w),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 360.w),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xff161616),
                  borderRadius: BorderRadius.circular(24.r),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.12),
                      blurRadius: 28,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(22.w, 22.h, 22.w, 18.h),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 56.w,
                          height: 56.w,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.16),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: accent.withValues(alpha: 0.35),
                            ),
                          ),
                          child: Icon(
                            item.typeIcon,
                            color: accent,
                            size: 26.sp,
                          ),
                        ),
                      ),
                      SizedBox(height: 16.h),
                      Center(
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 10.w,
                            vertical: 5.h,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.08),
                            ),
                          ),
                          child: Text(
                            '${item.typeLabel} nudge',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12.sp,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: 14.h),
                      Text(
                        item.groupName,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22.sp,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                      SizedBox(height: 8.h),
                      Text(
                        metaParts.join(' · '),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 13.sp,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                        ),
                      ),
                      SizedBox(height: 10.h),
                      Text(
                        liveVoiceLocked
                            ? 'Live voice requires Duo Pro'
                            : 'Join this group live?',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 14.sp,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (hint != null) ...[
                        SizedBox(height: 12.h),
                        Text(
                          hint,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: accent.withValues(alpha: 0.9),
                            fontSize: 12.sp,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      SizedBox(height: 22.h),
                      Row(
                        children: [
                          Expanded(
                            child: _PromptButton(
                              label: 'Decline',
                              enabled: !busy,
                              onTap: onDecline,
                              background: Colors.white.withValues(alpha: 0.08),
                              foreground: Colors.white70,
                            ),
                          ),
                          SizedBox(width: 10.w),
                          Expanded(
                            child: _PromptButton(
                              label: 'Accept',
                              enabled: !busy,
                              onTap: onAccept,
                              background: accent,
                              foreground: Colors.black,
                              busy: busy,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PromptButton extends StatelessWidget {
  const _PromptButton({
    required this.label,
    required this.enabled,
    required this.onTap,
    required this.background,
    required this.foreground,
    this.busy = false,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final Color background;
  final Color foreground;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: enabled ? onTap : null,
      style: FilledButton.styleFrom(
        backgroundColor: background,
        foregroundColor: foreground,
        disabledBackgroundColor: background.withValues(alpha: 0.5),
        padding: EdgeInsets.symmetric(vertical: 14.h),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16.r),
        ),
      ),
      child: busy
          ? SizedBox(
              width: 18.sp,
              height: 18.sp,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: foreground,
              ),
            )
          : Text(
              label,
              style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700),
            ),
    );
  }
}
