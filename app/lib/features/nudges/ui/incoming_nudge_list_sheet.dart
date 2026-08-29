import 'package:one_one_app/one_one.dart';

// Alternate home-open UI: list of active nudges. Dialogue is the default.

Future<void> showIncomingNudgeListSheet(
  BuildContext context, {
  required List<IncomingNudgePromptItem> items,
  required Color accent,
  required Future<void> Function(IncomingNudgePromptItem item) onAccept,
  required Future<void> Function(IncomingNudgePromptItem item) onDecline,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) {
      return IncomingNudgeListSheet(
        items: items,
        accent: accent,
        onAccept: onAccept,
        onDecline: onDecline,
      );
    },
  );
}

class IncomingNudgeListSheet extends StatelessWidget {
  const IncomingNudgeListSheet({
    super.key,
    required this.items,
    required this.accent,
    required this.onAccept,
    required this.onDecline,
  });

  final List<IncomingNudgePromptItem> items;
  final Color accent;
  final Future<void> Function(IncomingNudgePromptItem item) onAccept;
  final Future<void> Function(IncomingNudgePromptItem item) onDecline;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xff141414),
      borderRadius: BorderRadius.vertical(top: Radius.circular(28.r)),
      clipBehavior: Clip.antiAlias,
      child: BottomSystemSafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20.w, 12.h, 20.w, 20.h),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 38.w,
                  height: 4.h,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              SizedBox(height: 16.h),
              Text(
                'Active nudges',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18.sp,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 12.h),
              for (final item in items) ...[
                _IncomingNudgeListRow(
                  item: item,
                  accent: accent,
                  onAccept: () => onAccept(item),
                  onDecline: () => onDecline(item),
                ),
                SizedBox(height: 8.h),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _IncomingNudgeListRow extends StatelessWidget {
  const _IncomingNudgeListRow({
    required this.item,
    required this.accent,
    required this.onAccept,
    required this.onDecline,
  });

  final IncomingNudgePromptItem item;
  final Color accent;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(14.w, 12.h, 10.w, 12.h),
      decoration: BoxDecoration(
        color: const Color(0xff1e1e1e),
        borderRadius: BorderRadius.circular(16.r),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              item.groupName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: 15.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: onDecline,
            child: Text(
              'Decline',
              style: TextStyle(color: Colors.white54, fontSize: 13.sp),
            ),
          ),
          FilledButton(
            onPressed: onAccept,
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.black,
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }
}
