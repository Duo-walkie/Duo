import 'package:one_one_app/one_one.dart';

/// User language preference. Independent of [Market].
///
/// Restored from SharedPreferences before auth so the welcome screen can
/// switch language. After sign-in the same value is stored on user settings.
class LocaleController {
  LocaleController._();

  static const prefKey = 'one_one_preferred_locale';

  static final ValueNotifier<Locale> locale = ValueNotifier<Locale>(
    AppLanguage.english.locale,
  );

  static bool _userPicked = false;
  static Future<void>? _restore;

  static AppLanguage get language => AppLanguage.fromLocale(locale.value);

  static String get languageCode => language.languageCode;

  static Future<void> restore() => _restore ??= _restoreInternal();

  static Future<void> _restoreInternal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(prefKey);
      if (stored != null && stored.trim().isNotEmpty) {
        _userPicked = true;
        _setLanguage(AppLanguage.fromLanguageCode(stored), persist: false);
        return;
      }
    } catch (_) {}
    _applyMarketDefault(MarketController.config);
  }

  /// Applies a signed-in settings value. Account wins on a new device;
  /// otherwise the local welcome-screen pick is kept and can be persisted.
  static Future<void> syncWithAccount(String? preferredLocale) async {
    await restore();
    final accountLanguage = preferredLocale == null || preferredLocale.isEmpty
        ? null
        : AppLanguage.fromLanguageCode(preferredLocale);
    if (accountLanguage != null) {
      _userPicked = true;
      _setLanguage(
        MarketController.config.coerce(accountLanguage),
        persist: true,
      );
      return;
    }
    reconcileWithMarket(MarketController.config);
  }

  static Future<void> setLanguage(AppLanguage language) async {
    _userPicked = true;
    _setLanguage(MarketController.config.coerce(language), persist: true);
  }

  static void reconcileWithMarket(MarketConfig config) {
    if (_userPicked) {
      _setLanguage(config.coerce(language), persist: true);
      return;
    }
    _applyMarketDefault(config);
  }

  static void _applyMarketDefault(MarketConfig config) {
    _setLanguage(config.defaultLanguage, persist: false);
  }

  static void _setLanguage(AppLanguage language, {required bool persist}) {
    final next = language.locale;
    if (locale.value.languageCode != next.languageCode) {
      final phase = WidgetsBinding.instance.schedulerPhase;
      void apply() {
        if (locale.value.languageCode == next.languageCode) return;
        locale.value = next;
      }

      if (phase == SchedulerPhase.idle ||
          phase == SchedulerPhase.postFrameCallbacks) {
        apply();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) => apply());
      }
    }
    if (persist) {
      unawaited(_persist(language.languageCode));
    }
    unawaited(_recordDiagnostics(language));
  }

  static Future<void> _persist(String languageCode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefKey, languageCode);
    } catch (_) {}
  }

  static Future<void> _recordDiagnostics(AppLanguage language) async {
    if (Firebase.apps.isEmpty) return;
    try {
      final tag = MarketController.config.localeTagFor(language);
      await AnalyticsService.setUserProperty(name: 'app_locale', value: tag);
      await CrashlyticsService.setCustomKey('app_locale', tag);
    } catch (_) {}
  }
}

/// Starts cache restore immediately; Play/backend refinement is background.
abstract final class DuoLocalization {
  static Future<void>? _start;

  static Future<void> start() => _start ??= _startInternal();

  static Future<void> _startInternal() async {
    await LocaleController.restore();
    await MarketController.start();
  }
}
