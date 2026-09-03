import 'package:one_one_app/one_one.dart';

Future<void>? _inFlight;

/// Shows a blocking post-crash report dialog on the home screen when
/// Crashlytics reports the previous run crashed, or a prior send is still pending.
Future<void> showPostCrashReportDialogIfNeeded(
  BuildContext context, {
  String? userId,
  String? groupId,
  DeviceLogReport? report,
}) {
  return _inFlight ??= _show(
    context,
    userId: userId,
    groupId: groupId,
    report: report ?? DeviceLogReport(),
  ).whenComplete(() => _inFlight = null);
}

Future<void> _show(
  BuildContext context, {
  String? userId,
  String? groupId,
  required DeviceLogReport report,
}) async {
  final crashed = await CrashlyticsService.didCrashOnPreviousExecution();
  if (crashed) {
    await CrashReportPending.markPending();
  }
  final pending = crashed || await CrashReportPending.isPending();
  if (!pending || !context.mounted) return;

  DeviceLogReport.uiBlocking = true;
  LogManager.log(
    LogLevel.warn,
    'DeviceLogReport',
    'Showing post-crash report dialog crashed=$crashed',
    userId: userId,
    groupId: groupId,
  );
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (dialogContext) {
        return _PostCrashReportDialog(
          userId: userId,
          groupId: groupId,
          report: report,
        );
      },
    );
  } finally {
    DeviceLogReport.uiBlocking = false;
  }
}

class _PostCrashReportDialog extends StatefulWidget {
  const _PostCrashReportDialog({
    required this.userId,
    required this.groupId,
    required this.report,
  });

  final String? userId;
  final String? groupId;
  final DeviceLogReport report;

  @override
  State<_PostCrashReportDialog> createState() => _PostCrashReportDialogState();
}

class _PostCrashReportDialogState extends State<_PostCrashReportDialog> {
  bool _sending = false;
  String? _error;

  Future<void> _send() async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.report.upload(
        kind: DeviceLogReportKind.crash,
        userId: widget.userId,
        groupId: widget.groupId,
      );
      await CrashReportPending.clear();
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
    } catch (error) {
      LogManager.log(
        LogLevel.error,
        'DeviceLogReport',
        'Crash report upload failed: $error',
        userId: widget.userId,
        groupId: widget.groupId,
      );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = context.l10n.crashSendFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: const Color(0xff1b1b1b),
        title: Text(context.l10n.crashTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(context.l10n.crashBody),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Color(0xffff8a80), fontSize: 13),
              ),
            ],
          ],
        ),
        actions: [
          FilledButton(
            onPressed: _sending ? null : _send,
            child: _sending
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    _error == null
                        ? context.l10n.crashSendReport
                        : context.l10n.crashTryAgain,
                  ),
          ),
        ],
      ),
    );
  }
}
