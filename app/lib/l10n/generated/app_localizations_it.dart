// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Italian (`it`).
class AppLocalizationsIt extends AppLocalizations {
  AppLocalizationsIt([String locale = 'it']) : super(locale);

  @override
  String get welcomeTitle => 'Benvenuto su Duo';

  @override
  String get welcomeSubtitle =>
      'Accedi o crea il tuo account prima di configurare il profilo.';

  @override
  String get continueWithGoogle => 'Continua con Google';

  @override
  String get signingIn => 'Accesso in corso…';

  @override
  String get termsFooter =>
      'Continuando, accetti i nostri termini e le nostre policy.';

  @override
  String get googleSignInCancelled => 'Accesso con Google annullato. Riprova.';

  @override
  String get googleSignInFailed =>
      'Impossibile completare l\'accesso con Google. Controlla la connessione internet e riprova.';

  @override
  String get languageMenuTooltip => 'Lingua';

  @override
  String get chooseAvatarTitle => 'scegli un avatar';

  @override
  String get chooseAvatarSubtitle =>
      'Puoi aggiungere una foto personalizzata più tardi in Impostazioni.';

  @override
  String get displayNameHint => 'il tuo nome';

  @override
  String get displayNameSubtitle => 'è così che ti vedranno i tuoi amici';

  @override
  String get permissionMicTitle => 'microfono';

  @override
  String get permissionMicSubtitle =>
      'così i tuoi amici possono sentirti\nquando parli...';

  @override
  String get permissionNotificationsTitle => 'notifiche';

  @override
  String get permissionNotificationsSubtitle =>
      'sapere quando i tuoi amici\nti stanno parlando';

  @override
  String get permissionBackgroundTitle => 'attività in background';

  @override
  String get permissionBackgroundSubtitle =>
      'ricevere nudge quando duo\nnon è aperto';

  @override
  String get permissionFootnote => '*ne abbiamo bisogno perché duo funzioni';

  @override
  String get permissionSetupFailed =>
      'Impossibile completare la configurazione. Riprova.';

  @override
  String get settingsTitle => 'Impostazioni';

  @override
  String get settingsLanguageSection => 'Lingua';

  @override
  String get settingsLanguageTitle => 'Lingua dell\'app';

  @override
  String get settingsLanguageSubtitle =>
      'Puoi tornare all\'inglese in qualsiasi momento.';
}
