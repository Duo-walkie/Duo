import 'package:one_one_app/one_one.dart';

/// Manage Subscription sheet — in-app contact only.
///
/// Store cancel/upgrade lives on the Duo Pro paywall. This sheet is the
/// Team Duo inbox path from Settings.
class SubscriptionManagementSheet extends StatelessWidget {
  const SubscriptionManagementSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff1b1b1b),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => const SubscriptionManagementSheet(),
    );
  }

  static Future<void> contactTeamDuo(BuildContext context) {
    return _promptContactTeamDuo(context);
  }

  Future<void> _contactTeamDuo(BuildContext context) {
    return _promptContactTeamDuo(context);
  }

  @override
  Widget build(BuildContext context) {
    return BottomSystemSafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Image.asset(
                  'assets/logo.png',
                  width: 36,
                  height: 36,
                  fit: BoxFit.contain,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    context.l10n.subManageTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _SheetAction(
              icon: Icons.mail_outline_rounded,
              label: context.l10n.subContactTeam,
              subtitle: context.l10n.subContactTeamSubtitle,
              onTap: () => _contactTeamDuo(context),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _promptContactTeamDuo(BuildContext context) async {
  final email = AppConfig.teamDuoContactEmail;

  try {
    await Clipboard.setData(ClipboardData(text: email));
  } catch (_) {
    // Clipboard can fail on some platforms; still show the dialog.
  }

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        backgroundColor: const Color(0xff1b1b1b),
        title: Text(
          context.l10n.subContactTeam,
          style: const TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.subContactBody,
              style: const TextStyle(color: Colors.white70, height: 1.4),
            ),
            const SizedBox(height: 14),
            SelectableText(
              email,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.subEmailCopied,
              style: const TextStyle(color: Colors.white54, fontSize: 12.5),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(context.l10n.subClose),
          ),
        ],
      );
    },
  );
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xff242424),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: Colors.white70),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.white38),
            ],
          ),
        ),
      ),
    );
  }
}
