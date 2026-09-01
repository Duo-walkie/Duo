// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class AppLocalizationsFr extends AppLocalizations {
  AppLocalizationsFr([String locale = 'fr']) : super(locale);

  @override
  String get welcomeTitle => 'Bienvenue sur Duo';

  @override
  String get welcomeSubtitle =>
      'Connectez-vous ou créez un compte avant de configurer votre profil.';

  @override
  String get continueWithGoogle => 'Continuer avec Google';

  @override
  String get signingIn => 'Connexion…';

  @override
  String get termsFooter =>
      'En continuant, vous acceptez nos conditions et politiques.';

  @override
  String get googleSignInCancelled =>
      'La connexion Google a été annulée. Veuillez réessayer.';

  @override
  String get googleSignInFailed =>
      'La connexion Google n\'a pas pu aboutir. Vérifiez votre connexion internet et réessayez.';

  @override
  String get languageMenuTooltip => 'Langue';

  @override
  String get chooseAvatarTitle => 'choisissez un avatar';

  @override
  String get chooseAvatarSubtitle =>
      'Vous pourrez ajouter une photo personnalisée plus tard dans Réglages.';

  @override
  String get displayNameHint => 'votre nom';

  @override
  String get displayNameSubtitle => 'c\'est ainsi que vos amis vous verront';

  @override
  String get permissionMicTitle => 'micro';

  @override
  String get permissionMicSubtitle =>
      'pour que vos amis vous entendent\nquand vous parlez...';

  @override
  String get permissionNotificationsTitle => 'notifications';

  @override
  String get permissionNotificationsSubtitle =>
      'savoir quand vos amis vous\nparlent';

  @override
  String get permissionBackgroundTitle => 'activité en arrière-plan';

  @override
  String get permissionBackgroundSubtitle =>
      'recevoir des nudges quand duo\nn\'est pas ouvert';

  @override
  String get permissionFootnote =>
      '*nous en avons besoin pour que duo fonctionne';

  @override
  String get permissionSetupFailed =>
      'La configuration n\'a pas pu aboutir. Veuillez réessayer.';

  @override
  String get settingsTitle => 'Réglages';

  @override
  String get settingsLanguageSection => 'Langue';

  @override
  String get settingsLanguageTitle => 'Langue de l\'application';

  @override
  String get settingsLanguageSubtitle =>
      'Vous pouvez revenir à l\'anglais à tout moment.';
}
