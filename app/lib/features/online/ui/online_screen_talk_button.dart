part of 'online_screen.dart';

class _TalkButton extends StatelessWidget {
  const _TalkButton({
    required this.enabled,
    required this.active,
    required this.busy,
    required this.onStart,
    required this.onStop,
  });

  final bool enabled;
  final bool active;
  final bool busy;
  final Future<void> Function() onStart;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final backgroundColor = active
        ? colors.error
        : enabled
        ? colors.primary
        : colors.surfaceContainerHighest;
    final foregroundColor = active || enabled
        ? colors.onPrimary
        : colors.onSurfaceVariant;

    return GestureDetector(
      onTapDown: enabled && !busy ? (_) => onStart() : null,
      onTapUp: enabled ? (_) => onStop() : null,
      onTapCancel: enabled ? () => onStop() : null,
      child: Container(
        height: 136,
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              active ? Icons.mic : Icons.mic_none,
              color: foregroundColor,
              size: 42,
            ),
            const SizedBox(height: 8),
            Text(
              busy
                  ? 'WAIT'
                  : active
                  ? 'TALKING'
                  : 'HOLD TO TALK',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: foregroundColor,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
