// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get welcomeTitle => 'Bienvenido a Duo';

  @override
  String get welcomeSubtitle =>
      'Inicia sesión o crea tu cuenta antes de configurar tu perfil.';

  @override
  String get continueWithGoogle => 'Continuar con Google';

  @override
  String get signingIn => 'Iniciando sesión…';

  @override
  String get termsFooter =>
      'Al continuar, aceptas nuestros términos y políticas.';

  @override
  String get googleSignInCancelled =>
      'Se canceló el inicio de sesión de Google. Inténtalo de nuevo.';

  @override
  String get googleSignInFailed =>
      'No se pudo completar el inicio de sesión de Google. Comprueba tu conexión a internet e inténtalo de nuevo.';

  @override
  String get languageMenuTooltip => 'Idioma';

  @override
  String get chooseAvatarTitle => 'elige un avatar';

  @override
  String get chooseAvatarSubtitle =>
      'Puedes añadir una foto personalizada más tarde en Ajustes.';

  @override
  String get displayNameHint => 'tu nombre';

  @override
  String get displayNameSubtitle => 'así es como te verán tus amigos';

  @override
  String get permissionMicTitle => 'micrófono';

  @override
  String get permissionMicSubtitle =>
      'para que tus amigos te oigan\ncuando hables...';

  @override
  String get permissionNotificationsTitle => 'notificaciones';

  @override
  String get permissionNotificationsSubtitle =>
      'entérate cuando tus amigos\nte hablen';

  @override
  String get permissionBackgroundTitle => 'actividad en segundo plano';

  @override
  String get permissionBackgroundSubtitle =>
      'recibe nudges cuando duo\nno esté abierto';

  @override
  String get permissionFootnote => '*los necesitamos para que duo funcione';

  @override
  String get permissionSetupFailed =>
      'No se pudo completar la configuración. Inténtalo de nuevo.';

  @override
  String get settingsTitle => 'Ajustes';

  @override
  String get settingsLanguageSection => 'Idioma';

  @override
  String get settingsLanguageTitle => 'Idioma de la app';

  @override
  String get settingsLanguageSubtitle =>
      'Puedes volver al inglés en cualquier momento.';
}
