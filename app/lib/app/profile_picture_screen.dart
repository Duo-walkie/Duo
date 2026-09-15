import 'package:one_one_app/one_one.dart';

class ProfilePictureScreen extends StatefulWidget {
  const ProfilePictureScreen({
    super.key,
    required this.session,
    required this.identityRepository,
    required this.onComplete,
    this.refreshRetiredAvatar = false,
  });

  final IdentitySession session;
  final IdentityRepository identityRepository;
  final Future<void> Function(IdentitySession session) onComplete;

  /// Returning users whose stored avatar was retired. Same picker, different
  /// copy — they must pick a current avatar before continuing.
  final bool refreshRetiredAvatar;

  @override
  State<ProfilePictureScreen> createState() => _ProfilePictureScreenState();
}

class _ProfilePictureScreenState extends State<ProfilePictureScreen> {
  static const _accent = Color(0xffF8BE03);

  Future<List<AvatarAsset>>? _avatarsFuture;
  String? _selected;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _avatarsFuture = AvatarAssets.loadAll();
  }

  Future<void> _continue() async {
    final avatar = _selected;
    if (avatar == null || _saving) return;
    setState(() => _saving = true);
    try {
      await widget.onComplete(
        await widget.identityRepository.updatePresetAvatar(avatar),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(24.w, 36.h, 24.w, 24.h),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.refreshRetiredAvatar
                    ? context.l10n.chooseAvatarRefreshTitle
                    : context.l10n.chooseAvatarTitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 27.sp,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 8.h),
              Text(
                widget.refreshRetiredAvatar
                    ? context.l10n.chooseAvatarRefreshSubtitle
                    : context.l10n.chooseAvatarSubtitle,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 13.sp),
              ),
              SizedBox(height: 24.h),
              Expanded(
                child: FutureBuilder<List<AvatarAsset>>(
                  future: _avatarsFuture,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(
                        child: CircularProgressIndicator(color: _accent),
                      );
                    }
                    final avatars = snapshot.data!;
                    return AvatarPickerGrid(
                      avatars: avatars,
                      selectedAsset: _selected,
                      enabled: !_saving,
                      accent: _accent,
                      onAvatarSelected: (asset) =>
                          setState(() => _selected = asset),
                    );
                  },
                ),
              ),
              SizedBox(height: 10.h),
              Transform.rotate(
                angle: -0.04,
                child: Text(
                  context.l10n.chooseAvatarComingSoon,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _accent,
                    fontSize: 14.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.4,
                    height: 1.15,
                    fontStyle: FontStyle.italic,
                    shadows: [
                      Shadow(
                        color: _accent.withValues(alpha: 0.45),
                        blurRadius: 14,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 14.h),
              FilledButton(
                onPressed: _selected == null || _saving ? null : _continue,
                style: FilledButton.styleFrom(
                  minimumSize: Size.fromHeight(54.h),
                  backgroundColor: _accent,
                  foregroundColor: Colors.black,
                ),
                child: _saving
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Text('Continue'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
