import 'package:one_one_app/one_one.dart';

Future<void> showSendFeedbackSheet(
  BuildContext context, {
  String? userId,
  String? groupId,
  DeviceLogReport? report,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xff1b1b1b),
    showDragHandle: true,
    builder: (sheetContext) => _SendFeedbackSheet(
      userId: userId,
      groupId: groupId,
      report: report ?? DeviceLogReport(),
    ),
  );
}

class _SendFeedbackSheet extends StatefulWidget {
  const _SendFeedbackSheet({
    required this.userId,
    required this.groupId,
    required this.report,
  });

  final String? userId;
  final String? groupId;
  final DeviceLogReport report;

  @override
  State<_SendFeedbackSheet> createState() => _SendFeedbackSheetState();
}

class _SendFeedbackSheetState extends State<_SendFeedbackSheet> {
  final _controller = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final description = _controller.text.trim();
    try {
      await widget.report.upload(
        kind: DeviceLogReportKind.feedback,
        userId: widget.userId,
        groupId: widget.groupId,
        description: description.isEmpty ? null : description,
      );
      LogManager.log(
        LogLevel.info,
        'DeviceLogReport',
        'Feedback report sent',
        userId: widget.userId,
        groupId: widget.groupId,
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      final thanks = context.l10n.feedbackThanks;
      Navigator.pop(context);
      messenger?.showSnackBar(SnackBar(content: Text(thanks)));
    } catch (error) {
      LogManager.log(
        LogLevel.error,
        'DeviceLogReport',
        'Feedback upload failed: $error',
        userId: widget.userId,
        groupId: widget.groupId,
      );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = context.l10n.feedbackSendFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return BottomSystemSafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(18, 4, 18, 16 + bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.settingsSendFeedback,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.feedbackSubtitle,
              style: const TextStyle(color: Colors.white54, fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _controller,
              enabled: !_sending,
              maxLines: 5,
              maxLength: 2000,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: l10n.feedbackHint,
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xff101010),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.white24),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.white24),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 4),
              Text(
                _error!,
                style: const TextStyle(color: Color(0xffff8a80), fontSize: 13),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _sending ? null : _submit,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: _sending
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.crashSendReport),
            ),
          ],
        ),
      ),
    );
  }
}
