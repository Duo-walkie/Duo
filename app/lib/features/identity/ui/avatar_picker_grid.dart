import 'package:one_one_app/one_one.dart';

/// Single scrollable preset-avatar picker.
///
/// Shared by onboarding ([ProfilePictureScreen]) and Settings so both
/// present the same layout. Pack section headers only appear when more
/// than one pack is bundled.
class AvatarPickerGrid extends StatelessWidget {
  const AvatarPickerGrid({
    super.key,
    required this.avatars,
    required this.selectedAsset,
    required this.enabled,
    required this.accent,
    required this.onAvatarSelected,
    this.physics,
    this.shrinkWrap = false,
  });

  final List<AvatarAsset> avatars;
  final String? selectedAsset;
  final bool enabled;
  final Color accent;
  final ValueChanged<String> onAvatarSelected;

  /// Scroll physics for the outer list. Pass [NeverScrollableScrollPhysics]
  /// when embedding this inside another scrollable (e.g. a Settings list).
  final ScrollPhysics? physics;

  /// Whether the list should size itself to its content instead of expanding.
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final sections = <({AvatarPack pack, List<AvatarAsset> items})>[];
    for (final pack in AvatarPack.values) {
      final items = avatars
          .where((avatar) => avatar.pack == pack)
          .toList(growable: false);
      if (items.isNotEmpty) {
        sections.add((pack: pack, items: items));
      }
    }

    if (sections.length == 1) {
      return _AvatarGrid(
        items: sections.first.items,
        packLabel: sections.first.pack.label,
        selectedAsset: selectedAsset,
        enabled: enabled,
        accent: accent,
        onAvatarSelected: onAvatarSelected,
        physics: physics,
        shrinkWrap: shrinkWrap,
      );
    }

    return ListView.builder(
      shrinkWrap: shrinkWrap,
      physics: physics,
      itemCount: sections.length,
      itemBuilder: (context, sectionIndex) {
        final section = sections[sectionIndex];
        return Padding(
          padding: EdgeInsets.only(
            bottom: sectionIndex == sections.length - 1 ? 0 : 20,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                section.pack.label.toUpperCase(),
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 12),
              _AvatarGrid(
                items: section.items,
                packLabel: section.pack.label,
                selectedAsset: selectedAsset,
                enabled: enabled,
                accent: accent,
                onAvatarSelected: onAvatarSelected,
                physics: const NeverScrollableScrollPhysics(),
                shrinkWrap: true,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AvatarGrid extends StatelessWidget {
  const _AvatarGrid({
    required this.items,
    required this.packLabel,
    required this.selectedAsset,
    required this.enabled,
    required this.accent,
    required this.onAvatarSelected,
    required this.physics,
    required this.shrinkWrap,
  });

  final List<AvatarAsset> items;
  final String packLabel;
  final String? selectedAsset;
  final bool enabled;
  final Color accent;
  final ValueChanged<String> onAvatarSelected;
  final ScrollPhysics? physics;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: shrinkWrap,
      physics: physics,
      itemCount: items.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
      ),
      itemBuilder: (context, index) {
        final avatar = items[index];
        final selected = avatar.assetPath == selectedAsset;
        return _AvatarTile(
          assetPath: avatar.assetPath,
          label: '$packLabel ${index + 1}',
          selected: selected,
          accent: accent,
          onTap: enabled ? () => onAvatarSelected(avatar.assetPath) : null,
        );
      },
    );
  }
}

class _AvatarTile extends StatelessWidget {
  const _AvatarTile({
    required this.assetPath,
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final String assetPath;
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkResponse(
        onTap: onTap,
        child: Stack(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? accent : Colors.transparent,
                  width: 3,
                ),
              ),
              child: ClipOval(
                child: Image.asset(assetPath, fit: BoxFit.cover),
              ),
            ),
            if (selected)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.black, width: 1.5),
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    size: 14,
                    color: Colors.black,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
