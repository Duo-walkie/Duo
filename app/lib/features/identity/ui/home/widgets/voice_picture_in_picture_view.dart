part of '../../identity_home_screen.dart';

// 1. Compact OS-PiP surface: avatar, speaking ring, mic badge.

class _VoicePictureInPictureView extends StatelessWidget {
  const _VoicePictureInPictureView({
    super.key,
    required this.member,
    required this.speaking,
    required this.talking,
    required this.accent,
  });

  final GroupMemberSummary member;
  final bool speaking;
  final bool talking;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xff101010),
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final shortestSide = constraints.biggest.shortestSide;
            final avatarRadius = (shortestSide * 0.32).clamp(20.0, 68.0);
            return Semantics(
              label:
                  '${member.displayName}, ${speaking ? 'speaking' : 'listening'}, '
                  '${talking ? 'microphone on' : 'microphone muted'}',
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: speaking ? const Color(0xff7CFF6B) : accent,
                          width: speaking ? 3 : 1,
                        ),
                      ),
                      child: ProfileAvatar(
                        profilePhotoUrl: member.profilePhotoUrl,
                        profilePhotoBase64: member.profilePhotoBase64,
                        avatarAsset: member.avatarAsset,
                        radius: avatarRadius,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: talking
                            ? const Color(0xff28A745)
                            : const Color(0xdd202020),
                      ),
                      child: Icon(
                        talking ? Icons.mic_rounded : Icons.mic_off_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 8,
                    right: 52,
                    bottom: 10,
                    child: Text(
                      member.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        shadows: [Shadow(blurRadius: 6, color: Colors.black)],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
