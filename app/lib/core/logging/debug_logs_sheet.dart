import 'package:one_one_app/one_one.dart';

Future<void> showDebugLogsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xff1b1b1b),
    showDragHandle: true,
    builder: (sheetContext) => const _DebugLogsSheet(),
  );
}

class _DebugLogsSheet extends StatefulWidget {
  const _DebugLogsSheet();

  @override
  State<_DebugLogsSheet> createState() => _DebugLogsSheetState();
}

class _DebugLogsSheetState extends State<_DebugLogsSheet> {
  LogFileInfo? _info;
  bool _loading = true;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final info = await LogManager.todayFileInfo();
    if (!mounted) return;
    setState(() {
      _info = info;
      _loading = false;
    });
  }

  Future<void> _share() async {
    final file = _info?.file ?? LogManager.todayFile();
    if (file == null || !file.existsSync()) {
      setState(() => _message = context.l10n.debugLogsNoFile);
      return;
    }
    LogManager.log(LogLevel.info, 'LogManager', 'Share log file requested');
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'text/plain')],
        subject: context.l10n.debugLogsShareSubject,
      ),
    );
  }

  Future<void> _copy() async {
    final text = await LogManager.readTodayText();
    await Clipboard.setData(ClipboardData(text: text));
    LogManager.log(LogLevel.info, 'LogManager', 'Copied log text to clipboard');
    if (!mounted) return;
    setState(() => _message = context.l10n.debugLogsCopied);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final info = _info;
    return BottomSystemSafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Text(
                l10n.settingsDebugLogs,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Text(
                _loading
                    ? l10n.debugLogsReading
                    : info == null
                    ? l10n.debugLogsEmpty
                    : l10n.debugLogsTodayFile(
                        info.sizeLabel,
                        _formatTime(info.lastModified),
                      ),
                style: const TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.ios_share, color: Colors.white70),
              title: Text(
                l10n.debugLogsShareTitle,
                style: const TextStyle(color: Colors.white),
              ),
              subtitle: Text(
                l10n.debugLogsShareSubtitle,
                style: const TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
              onTap: _share,
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined, color: Colors.white70),
              title: Text(
                l10n.debugLogsCopyTitle,
                style: const TextStyle(color: Colors.white),
              ),
              subtitle: Text(
                l10n.debugLogsCopySubtitle,
                style: const TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
              onTap: _copy,
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
                child: Text(
                  _message!,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final local = time.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
