import 'package:one_one_app/one_one.dart';

/// Opens Gmail compose to Team Duo. Falls back to mailto, then Gmail web,
/// then copies the address if nothing can launch.
class SubscriptionManagementSheet {
  SubscriptionManagementSheet._();

  static Future<void> contactTeamDuo(BuildContext context) async {
    final email = AppConfig.teamDuoContactEmail;
    final opened = await _openGmailCompose(email);
    if (opened || !context.mounted) return;
    try {
      await Clipboard.setData(ClipboardData(text: email));
    } catch (_) {}
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${context.l10n.subEmailCopied}  $email')),
    );
  }

  static Future<bool> _openGmailCompose(String email) async {
    final encoded = Uri.encodeComponent(email);
    final candidates = <Uri>[
      Uri.parse('googlegmail://co?to=$encoded'),
      Uri(scheme: 'mailto', path: email),
      Uri.parse('https://mail.google.com/mail/?view=cm&fs=1&to=$encoded'),
    ];
    for (final uri in candidates) {
      try {
        final launched = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
        if (launched) return true;
      } catch (_) {}
    }
    return false;
  }
}
