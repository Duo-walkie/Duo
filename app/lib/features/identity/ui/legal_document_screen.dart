import 'package:one_one_app/one_one.dart';

import 'legal_document_content.dart';

enum LegalDocument { terms, privacy }

class LegalDocumentScreen extends StatelessWidget {
  const LegalDocumentScreen({super.key, required this.document});

  final LegalDocument document;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final content = document == LegalDocument.terms
        ? termsSectionsFor(l10n)
        : privacySectionsFor(l10n);
    final title = document == LegalDocument.terms
        ? l10n.settingsTerms
        : l10n.settingsPrivacy;

    return Scaffold(
      backgroundColor: const Color(0xff101010),
      appBar: AppBar(
        title: Text(title),
        centerTitle: true,
        backgroundColor: const Color(0xff101010),
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 8, 22, 36),
          children: [
            Text(
              l10n.legalLastUpdated,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.42),
                fontSize: 12,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 22),
            for (final section in content) ...[
              Text(
                section.heading,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                section.body,
                style: const TextStyle(
                  color: Colors.white70,
                  height: 1.55,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 22),
            ],
          ],
        ),
      ),
    );
  }
}
