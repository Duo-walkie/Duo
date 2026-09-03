part of '../../identity_home_screen.dart';

// 1. Right-edge nudge hit target while mixed/live.

class _EdgeQuickActions extends StatelessWidget {
  const _EdgeQuickActions({required this.showNudge, required this.onNudge});

  final bool showNudge;
  final VoidCallback? onNudge;

  /// Shared column width so the nudge glyph stays on the right-edge axis.
  static double get _columnWidth => 48.w;

  @override
  Widget build(BuildContext context) {
    if (!showNudge) return const SizedBox.shrink();
    return SizedBox(
      width: _columnWidth,
      child: Semantics(
        button: true,
        label: context.l10n.homeNudgeTheGroup,
        child: Tooltip(
          message: context.l10n.homeSendNudge,
          child: _EdgeActionHit(
            onTap: onNudge,
            enabled: onNudge != null,
            hitSize: _columnWidth,
            child: Text('👋', style: TextStyle(fontSize: 28.sp)),
          ),
        ),
      ),
    );
  }
}

/// Comfortable hit target around a bare glyph.
class _EdgeActionHit extends StatelessWidget {
  const _EdgeActionHit({
    required this.onTap,
    required this.enabled,
    required this.child,
    this.hitSize,
  });

  final VoidCallback? onTap;
  final bool enabled;
  final double? hitSize;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = hitSize ?? 48.w;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Opacity(opacity: enabled ? 1 : 0.4, child: child),
        ),
      ),
    );
  }
}
