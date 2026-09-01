// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get welcomeTitle => 'Welcome to Duo';

  @override
  String get welcomeSubtitle =>
      'Sign in or create your account before setting up your profile.';

  @override
  String get continueWithGoogle => 'Continue with Google';

  @override
  String get signingIn => 'Signing in…';

  @override
  String get termsFooter => 'By continuing, you agree to our terms & policies.';

  @override
  String get googleSignInCancelled =>
      'Google sign-in was cancelled. Please try again.';

  @override
  String get googleSignInFailed =>
      'Google sign-in couldn\'t be completed. Check your internet connection and try again.';

  @override
  String get languageMenuTooltip => 'Language';

  @override
  String get chooseAvatarTitle => 'choose an avatar';

  @override
  String get chooseAvatarSubtitle =>
      'You can add a custom photo later in Settings.';

  @override
  String get displayNameHint => 'your name';

  @override
  String get displayNameSubtitle => 'this is how your friends will see you';

  @override
  String get permissionMicTitle => 'mic';

  @override
  String get permissionMicSubtitle =>
      'so your friends can hear you\nwhen you talk...';

  @override
  String get permissionNotificationsTitle => 'notifications';

  @override
  String get permissionNotificationsSubtitle =>
      'know when your friends are\ntalking to you';

  @override
  String get permissionBackgroundTitle => 'background activity';

  @override
  String get permissionBackgroundSubtitle =>
      'receive nudges when duo\nisn\'t open';

  @override
  String get permissionFootnote => '*we need those for duo to work';

  @override
  String get permissionSetupFailed =>
      'Setup could not be completed. Please try again.';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsLanguageSection => 'Language';

  @override
  String get settingsLanguageTitle => 'App language';

  @override
  String get settingsLanguageSubtitle =>
      'You can switch back to English at any time.';
}
