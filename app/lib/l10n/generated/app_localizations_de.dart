// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get welcomeTitle => 'Willkommen bei Duo';

  @override
  String get welcomeSubtitle =>
      'Melde dich an oder erstelle ein Konto, bevor du dein Profil einrichtest.';

  @override
  String get continueWithGoogle => 'Mit Google fortfahren';

  @override
  String get signingIn => 'Anmeldung…';

  @override
  String get termsFooter =>
      'Mit dem Fortfahren stimmst du unseren Bedingungen und Richtlinien zu.';

  @override
  String get googleSignInCancelled =>
      'Die Google-Anmeldung wurde abgebrochen. Bitte versuche es erneut.';

  @override
  String get googleSignInFailed =>
      'Die Google-Anmeldung konnte nicht abgeschlossen werden. Prüfe deine Internetverbindung und versuche es erneut.';

  @override
  String get languageMenuTooltip => 'Sprache';

  @override
  String get chooseAvatarTitle => 'wähle einen avatar';

  @override
  String get chooseAvatarSubtitle =>
      'Ein eigenes Foto kannst du später in den Einstellungen hinzufügen.';

  @override
  String get displayNameHint => 'dein name';

  @override
  String get displayNameSubtitle => 'so sehen dich deine freunde';

  @override
  String get permissionMicTitle => 'mikrofon';

  @override
  String get permissionMicSubtitle =>
      'damit dich deine freunde hören,\nwenn du sprichst...';

  @override
  String get permissionNotificationsTitle => 'benachrichtigungen';

  @override
  String get permissionNotificationsSubtitle =>
      'erfahren, wenn deine freunde\nmit dir sprechen';

  @override
  String get permissionBackgroundTitle => 'hintergrundaktivität';

  @override
  String get permissionBackgroundSubtitle =>
      'nudges empfangen, wenn duo\nnicht geöffnet ist';

  @override
  String get permissionFootnote => '*wir brauchen das, damit duo funktioniert';

  @override
  String get permissionSetupFailed =>
      'Die Einrichtung konnte nicht abgeschlossen werden. Bitte versuche es erneut.';

  @override
  String get settingsTitle => 'Einstellungen';

  @override
  String get settingsLanguageSection => 'Sprache';

  @override
  String get settingsLanguageTitle => 'App-Sprache';

  @override
  String get settingsLanguageSubtitle =>
      'Du kannst jederzeit zu Englisch zurückwechseln.';
}
