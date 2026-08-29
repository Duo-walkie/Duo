part of '../../identity_home_screen.dart';

// 1. Setup warning rows (tappable permission fixes).

class _SetupLine extends StatelessWidget {
  const _SetupLine({required this.ok, required this.text});

  final bool ok;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.error_outline,
            color: ok ? colors.primary : colors.error,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

/// A setup warning with an optional tap action (e.g. request the missing
/// permission directly from the setup modal).
class _SetupWarning {
  const _SetupWarning({required this.text, required this.accent, this.onTap});

  final String text;
  final Color accent;
  final VoidCallback? onTap;
}

/// Like [_SetupLine] but tappable — tapping an unresolved warning navigates
/// to the specific permission request instead of just listing it.
class _TappableSetupLine extends StatelessWidget {
  const _TappableSetupLine({
    required this.ok,
    required this.text,
    required this.onTap,
    required this.accent,
  });

  final bool ok;
  final String text;
  final VoidCallback? onTap;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tappable = onTap != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.symmetric(
            vertical: 4.h,
            horizontal: tappable ? 6.w : 0,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                ok ? Icons.check_circle : Icons.error_outline,
                color: ok ? colors.primary : colors.error,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    color: tappable ? accent : null,
                    decoration: tappable ? TextDecoration.underline : null,
                  ),
                ),
              ),
              if (tappable)
                Icon(
                  Icons.arrow_forward_rounded,
                  size: 16,
                  color: colors.onSurface.withValues(alpha: 0.3),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
