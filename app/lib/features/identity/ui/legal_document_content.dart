import 'package:one_one_app/l10n/l10n.dart';

class LegalSection {
  const LegalSection(this.heading, this.body);

  final String heading;
  final String body;
}

List<LegalSection> termsSectionsFor(AppLocalizations l10n) => [
  LegalSection(l10n.legalTerms1Title, l10n.legalTerms1Body),
  LegalSection(l10n.legalTerms2Title, l10n.legalTerms2Body),
  LegalSection(l10n.legalTerms3Title, l10n.legalTerms3Body),
  LegalSection(l10n.legalTerms4Title, l10n.legalTerms4Body),
  LegalSection(l10n.legalTerms5Title, l10n.legalTerms5Body),
  LegalSection(l10n.legalTerms6Title, l10n.legalTerms6Body),
  LegalSection(l10n.legalTerms7Title, l10n.legalTerms7Body),
  LegalSection(l10n.legalTerms8Title, l10n.legalTerms8Body),
  LegalSection(l10n.legalTerms9Title, l10n.legalTerms9Body),
];

List<LegalSection> privacySectionsFor(AppLocalizations l10n) => [
  LegalSection(l10n.legalPrivacy1Title, l10n.legalPrivacy1Body),
  LegalSection(l10n.legalPrivacy2Title, l10n.legalPrivacy2Body),
  LegalSection(l10n.legalPrivacy3Title, l10n.legalPrivacy3Body),
  LegalSection(l10n.legalPrivacy4Title, l10n.legalPrivacy4Body),
  LegalSection(l10n.legalPrivacy5Title, l10n.legalPrivacy5Body),
  LegalSection(l10n.legalPrivacy6Title, l10n.legalPrivacy6Body),
  LegalSection(l10n.legalPrivacy7Title, l10n.legalPrivacy7Body),
  LegalSection(l10n.legalPrivacy8Title, l10n.legalPrivacy8Body),
  LegalSection(l10n.legalPrivacy9Title, l10n.legalPrivacy9Body),
  LegalSection(l10n.legalPrivacy10Title, l10n.legalPrivacy10Body),
  LegalSection(l10n.legalPrivacy11Title, l10n.legalPrivacy11Body),
];

List<String> chatPresetsFor(AppLocalizations l10n) => [
  l10n.chatPresetJoin15Min,
  l10n.chatPresetWhereEveryone,
  l10n.chatPresetOnMyWay,
  l10n.chatPresetGiveMe5Min,
];
