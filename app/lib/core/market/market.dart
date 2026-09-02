import 'package:one_one_app/one_one.dart';

/// Country/market-specific product experience. Independent of language.
///
/// `Market.germany` + locale `en-DE` is valid, as is `Market.usa` + `es-US`.
enum Market {
  india,
  usa,
  unitedKingdom,
  germany,
  france,
  spain,
  italy,
  unknown;

  /// ISO 3166-1 alpha-2 used on the profile, cache, and logs.
  String get isoCode => switch (this) {
    Market.india => 'IN',
    Market.usa => 'US',
    Market.unitedKingdom => 'GB',
    Market.germany => 'DE',
    Market.france => 'FR',
    Market.spain => 'ES',
    Market.italy => 'IT',
    Market.unknown => 'XX',
  };

  String get debugLabel => switch (this) {
    Market.india => 'India',
    Market.usa => 'USA',
    Market.unitedKingdom => 'UK',
    Market.germany => 'Germany',
    Market.france => 'France',
    Market.spain => 'Spain',
    Market.italy => 'Italy',
    Market.unknown => 'Automatic / unknown',
  };

  static Market fromIsoCode(String? raw) {
    final code = raw?.trim().toUpperCase();
    if (code == null || code.isEmpty) return Market.unknown;
    return switch (code) {
      'IN' => Market.india,
      'US' => Market.usa,
      'GB' || 'UK' => Market.unitedKingdom,
      'DE' => Market.germany,
      'FR' => Market.france,
      'ES' => Market.spain,
      'IT' => Market.italy,
      _ => Market.unknown,
    };
  }
}

/// Why a [Market] was chosen. Logged so QA can tell production from fallback.
enum MarketSource {
  debugOverride,
  backend,
  playStore,
  cache,
  deviceRegion,
  unknown;

  String get logLabel => switch (this) {
    MarketSource.debugOverride => 'debug',
    MarketSource.backend => 'backend',
    MarketSource.playStore => 'playStore',
    MarketSource.cache => 'cache',
    MarketSource.deviceRegion => 'deviceRegion',
    MarketSource.unknown => 'unknown',
  };
}

/// Languages Duo ships in Phase 1. English is always available.
enum AppLanguage {
  english,
  french,
  german,
  spanish,
  italian;

  String get languageCode => switch (this) {
    AppLanguage.english => 'en',
    AppLanguage.french => 'fr',
    AppLanguage.german => 'de',
    AppLanguage.spanish => 'es',
    AppLanguage.italian => 'it',
  };

  /// Native name shown in the picker so the option is recognizable in any UI language.
  String get nativeName => switch (this) {
    AppLanguage.english => 'English',
    AppLanguage.french => 'Français',
    AppLanguage.german => 'Deutsch',
    AppLanguage.spanish => 'Español',
    AppLanguage.italian => 'Italiano',
  };

  Locale get locale => Locale(languageCode);

  static AppLanguage fromLanguageCode(String? raw) {
    final code = raw?.trim().toLowerCase();
    if (code == null || code.isEmpty) return AppLanguage.english;
    final language = code.split(RegExp('[-_]')).first;
    return switch (language) {
      'fr' => AppLanguage.french,
      'de' => AppLanguage.german,
      'es' => AppLanguage.spanish,
      'it' => AppLanguage.italian,
      _ => AppLanguage.english,
    };
  }

  static AppLanguage fromLocale(Locale locale) =>
      fromLanguageCode(locale.languageCode);
}

/// Country-specific screen family. Remote Config may select an already-built
/// variant; it never ships executable UI.
enum OnboardingVariant {
  defaultVariant,
  india,
  usa,
  unitedKingdom,
  germany,
  france,
  spain,
  italy;

  String get remoteValue => switch (this) {
    OnboardingVariant.defaultVariant => 'default',
    OnboardingVariant.india => 'india',
    OnboardingVariant.usa => 'usa',
    OnboardingVariant.unitedKingdom => 'united_kingdom',
    OnboardingVariant.germany => 'germany',
    OnboardingVariant.france => 'france',
    OnboardingVariant.spain => 'spain',
    OnboardingVariant.italy => 'italy',
  };

  static OnboardingVariant? tryParse(String? raw) {
    final value = raw?.trim().toLowerCase();
    if (value == null || value.isEmpty) return null;
    return switch (value) {
      'default' ||
      'default_variant' ||
      'global' => OnboardingVariant.defaultVariant,
      'india' || 'india_v1' => OnboardingVariant.india,
      'usa' || 'usa_v1' || 'us' => OnboardingVariant.usa,
      'united_kingdom' ||
      'uk' ||
      'gb' ||
      'uk_v1' => OnboardingVariant.unitedKingdom,
      'germany' || 'germany_v1' || 'de' => OnboardingVariant.germany,
      'france' || 'france_v1' || 'fr' => OnboardingVariant.france,
      'spain' || 'spain_v1' || 'es' => OnboardingVariant.spain,
      'italy' || 'italy_v1' || 'it' => OnboardingVariant.italy,
      _ => null,
    };
  }
}
