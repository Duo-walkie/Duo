part of '../../identity_home_screen.dart';

// 1. Group name + friend chips (live ring, nudge reply).
// 2. Talking pulse and add-friend chip.

class _FriendsStrip extends StatelessWidget {
  const _FriendsStrip({
    required this.groupName,
    required this.friends,
    required this.availability,
    required this.speakingUserIds,
    required this.connectionQualityByUserId,
    required this.nudgeRepliesByUserId,
    required this.onInvite,
  });

  final String? groupName;
  final List<GroupMemberSummary> friends;
  final Map<String, MemberAvailability> availability;
  final Set<String> speakingUserIds;
  final Map<String, ConnectionQuality> connectionQualityByUserId;
  final Map<String, NudgeRecipientReply> nudgeRepliesByUserId;
  final VoidCallback? onInvite;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (groupName != null)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 20.w),
            child: Text(
              groupName!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: 14.sp,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ),
        SizedBox(height: 6.h),
        SizedBox(
          height: 92.h,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: 16.w),
            children: [
              for (final friend in friends) ...[
                _FriendChip(
                  key: ValueKey(friend.userId),
                  name: friend.displayName,
                  profilePhotoUrl: friend.profilePhotoUrl,
                  profilePhotoBase64: friend.profilePhotoBase64,
                  avatarAsset: friend.avatarAsset,
                  availability:
                      availability[friend.userId] ?? MemberAvailability.away,
                  isSpeaking:
                      speakingUserIds.contains(friend.userId) ||
                      (availability[friend.userId]?.isTalking ?? false),
                  connectionQuality:
                      connectionQualityByUserId[friend.userId] ??
                      ConnectionQuality.unknown,
                  nudgeReply: nudgeRepliesByUserId[friend.userId],
                ),
                SizedBox(width: 12.w),
              ],
              _AddFriendChip(onTap: onInvite),
            ],
          ),
        ),
      ],
    );
  }
}

class _FriendChip extends StatelessWidget {
  const _FriendChip({
    super.key,
    required this.name,
    required this.profilePhotoUrl,
    required this.profilePhotoBase64,
    required this.avatarAsset,
    required this.availability,
    required this.isSpeaking,
    required this.connectionQuality,
    this.nudgeReply,
  });

  final String name;
  final String? profilePhotoUrl;
  final String? profilePhotoBase64;
  final String? avatarAsset;
  final MemberAvailability availability;
  final bool isSpeaking;
  final ConnectionQuality connectionQuality;
  final NudgeRecipientReply? nudgeReply;

  @override
  Widget build(BuildContext context) {
    final live = availability.isLive;
    final degradedNetwork =
        connectionQuality == ConnectionQuality.poor ||
        connectionQuality == ConnectionQuality.lost;
    final shortName = name.trim().split(RegExp(r'\s+')).first;
    final initial = profileDisplayInitial(name);
    final ringColor = isSpeaking
        ? const Color(0xff7CFF6B)
        : live
        ? const Color(0xff7CFF6B)
        : Colors.white24;

    return Column(
      children: [
        Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            if (isSpeaking)
              const _TalkingPulseRing(color: Color(0xff7CFF6B), size: 60),
            Container(
              width: 52.w,
              height: 52.w,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xff2a2a2a),
                border: Border.all(
                  color: ringColor,
                  width: isSpeaking ? 2.5 : 2,
                ),
              ),
              child: ClipOval(
                child: ProfileAvatar(
                  profilePhotoUrl: profilePhotoUrl,
                  profilePhotoBase64: profilePhotoBase64,
                  avatarAsset: avatarAsset,
                  radius: 26.w,
                  backgroundColor: const Color(0xff2a2a2a),
                  fallback: Text(
                    initial,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18.sp,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: -4,
              bottom: -2,
              // Prefer decline/snooze reply badge over the live/away glyph
              // while a recent nudge response is still active.
              child: nudgeReply != null
                  ? _NudgeReplyBadge(reply: nudgeReply!)
                  : live
                  ? Text('🟢', style: TextStyle(fontSize: 14.sp))
                  : Container(
                      width: 20.w,
                      height: 20.w,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xff2a2a2a),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black45,
                            blurRadius: 3,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.dark_mode_rounded,
                        color: Colors.white70,
                        size: 13.sp,
                      ),
                    ),
            ),
          ],
        ),
        SizedBox(height: 4.h),
        SizedBox(
          width: 72.w,
          child: Text(
            isSpeaking ? '🗣️ talking' : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isSpeaking ? const Color(0xff7CFF6B) : Colors.white70,
              fontSize: 10.sp,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (degradedNetwork && !isSpeaking) ...[
          SizedBox(height: 2.h),
          SizedBox(
            width: 72.w,
            child: Text(
              "${shortName.isEmpty ? 'Their' : shortName}'s network is low",
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: const Color(0xffffb347),
                fontSize: 8.sp,
                fontWeight: FontWeight.w600,
                height: 1.1,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _NudgeReplyBadge extends StatelessWidget {
  const _NudgeReplyBadge({required this.reply});

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
    return Container(
      width: 22.w,
      height: 22.w,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // Match the away moon badge grey (Color(0xff2a2a2a)).
        color: const Color(0xff2a2a2a),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.28),
          width: 1,
        ),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 3, offset: Offset(0, 1)),
        ],
      ),
      child: Icon(icon, color: color, size: 13.sp),
    );
  }
}

class _TalkingPulseRing extends StatefulWidget {
  const _TalkingPulseRing({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  State<_TalkingPulseRing> createState() => _TalkingPulseRingState();
}

class _TalkingPulseRingState extends State<_TalkingPulseRing>
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
        final t = _controller.value;
        final scale = 1 + (0.18 * t);
        final opacity = (1 - t).clamp(0.0, 1.0);
        return Transform.scale(
          scale: scale,
          child: Container(
            width: widget.size.w,
            height: widget.size.w,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: widget.color.withValues(alpha: 0.55 * opacity),
                width: 2,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AddFriendChip extends StatelessWidget {
  const _AddFriendChip({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: Column(
          children: [
            Container(
              width: 52.w,
              height: 52.w,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white54, width: 1.5),
              ),
              child: Icon(Icons.add, color: Colors.white, size: 24.sp),
            ),
            SizedBox(height: 4.h),
            Text(
              'invite',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 10.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
