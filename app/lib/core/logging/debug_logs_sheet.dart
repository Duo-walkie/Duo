import 'package:one_one_app/one_one.dart';

Future<void> showDebugLogsSheet(BuildContext context) {
  return DuoSheet.show<void>(
    context: context,
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
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DuoSheetTitle(
              l10n.settingsDebugLogs,
              subtitle: _loading
                  ? l10n.debugLogsReading
                  : info == null
                  ? l10n.debugLogsEmpty
                  : l10n.debugLogsTodayFile(
                      info.sizeLabel,
                      _formatTime(info.lastModified),
                    ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: DuoSheetCard(
                children: [
                  ListTile(
                    leading: const Icon(
                      LucideIcons.share,
                      color: Colors.white70,
                      size: 20,
                    ),
                    title: Text(
                      l10n.debugLogsShareTitle,
                      style: const TextStyle(color: Colors.white),
                    ),
                    trailing: const Icon(
                      LucideIcons.chevronRight,
                      color: Colors.white38,
                      size: 18,
                    ),
                    onTap: _share,
                  ),
                  Divider(
                    height: 1,
                    indent: 56,
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                  ListTile(
                    leading: const Icon(
                      LucideIcons.copy,
                      color: Colors.white70,
                      size: 20,
                    ),
                    title: Text(
                      l10n.debugLogsCopyTitle,
                      style: const TextStyle(color: Colors.white),
                    ),
                    trailing: const Icon(
                      LucideIcons.chevronRight,
                      color: Colors.white38,
                      size: 18,
                    ),
                    onTap: _copy,
                  ),
                ],
              ),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Text(
                  _message!,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
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
