import 'package:one_one_app/one_one.dart';

/// Layered automatic market detection. No country selector is shown.
///
/// Order:
/// 1. Debug override (debug builds only)
/// 2. Backend/account market when the signed-in profile has one
/// 3. Play/App Store storefront country (Play Billing via RevenueCat)
/// 4. Previously cached Play/backend market
/// 5. Device locale region (not GPS, not SIM)
/// 6. [Market.unknown]
class MarketResolver {
  MarketResolver({
    DebugMarketReader? readDebugOverride,
    BackendMarketReader? readBackendMarket,
    PlayCountryReader? readPlayCountry,
    DeviceRegionReader? readDeviceRegion,
  }) : _readDebugOverride = readDebugOverride ?? DebugMarketOverride.read,
       _readBackendMarket = readBackendMarket ?? (() async => null),
       _readPlayCountry = readPlayCountry ?? PlayStorefrontCountry.read,
       _readDeviceRegion = readDeviceRegion ?? DeviceRegionCountry.read;

  final DebugMarketReader _readDebugOverride;
  final BackendMarketReader _readBackendMarket;
  final PlayCountryReader _readPlayCountry;
  final DeviceRegionReader _readDeviceRegion;

  Future<MarketSnapshot> resolve({MarketSnapshot? cached}) async {
    final debugMarket = kDebugMode ? await _readDebugOverride() : null;
    if (debugMarket != null && debugMarket != Market.unknown) {
      return MarketSnapshot(
        market: debugMarket,
        source: MarketSource.debugOverride,
        isoCountryCode: debugMarket.isoCode,
      );
    }

    final backendIso = await _readBackendMarket();
    final backendMarket = Market.fromIsoCode(backendIso);
    if (backendMarket != Market.unknown) {
      return MarketSnapshot(
        market: backendMarket,
        source: MarketSource.backend,
        isoCountryCode: backendMarket.isoCode,
      );
    }

    final playIso = await _readPlayCountry();
    final playMarket = Market.fromIsoCode(playIso);
    if (playIso != null && playIso.trim().isNotEmpty) {
      return MarketSnapshot(
        market: playMarket,
        source: MarketSource.playStore,
        isoCountryCode: playIso.trim().toUpperCase(),
      );
    }

    if (cached != null &&
        cached.market != Market.unknown &&
        (cached.source == MarketSource.playStore ||
            cached.source == MarketSource.backend ||
            cached.source == MarketSource.cache)) {
      return MarketSnapshot(
        market: cached.market,
        source: MarketSource.cache,
        isoCountryCode: cached.isoCountryCode ?? cached.market.isoCode,
      );
    }

    final deviceIso = _readDeviceRegion();
    final deviceMarket = Market.fromIsoCode(deviceIso);
    if (deviceMarket != Market.unknown) {
      return MarketSnapshot(
        market: deviceMarket,
        source: MarketSource.deviceRegion,
        isoCountryCode: deviceMarket.isoCode,
      );
    }

    return MarketSnapshot.unknown;
  }
}

typedef DebugMarketReader = Future<Market?> Function();
typedef BackendMarketReader = Future<String?> Function();
typedef PlayCountryReader = Future<String?> Function();
typedef DeviceRegionReader = String? Function();

/// Play Billing / App Store account country, via RevenueCat's storefront.
///
/// On Android this is the Google Play Billing `BillingConfig.countryCode`
/// (the store account country), not GPS and not the Play Console listing
/// country of the APK. It can be null on sideloads, emulators without Play,
/// or if billing is not ready.
abstract final class PlayStorefrontCountry {
  static const _timeout = Duration(seconds: 4);

  static Future<String?> read() async {
    try {
      await RevenueCatService.initialize().timeout(_timeout);
      final storefront = await Purchases.storefront.timeout(_timeout);
      final code = storefront?.countryCode.trim();
      if (code == null || code.isEmpty) return null;
      return code.toUpperCase();
    } catch (error) {
      debugPrint('[Market] Play storefront unavailable (${error.runtimeType})');
      return null;
    }
  }
}

/// Device locale region. Fallback only — not Play country, not GPS.
abstract final class DeviceRegionCountry {
  static String? read() {
    final locales = WidgetsBinding.instance.platformDispatcher.locales;
    for (final locale in locales) {
      final country = locale.countryCode?.trim();
      if (country != null && country.isNotEmpty) {
        return country.toUpperCase();
      }
    }
    final fallback = WidgetsBinding.instance.platformDispatcher.locale;
    final country = fallback.countryCode?.trim();
    if (country == null || country.isEmpty) return null;
    return country.toUpperCase();
  }
}

abstract final class DebugMarketOverride {
  static const prefKey = 'one_one_debug_market';

  static Future<Market?> read() async {
    if (!kDebugMode) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefKey)?.trim();
      if (raw == null || raw.isEmpty || raw == 'automatic') return null;
      final market = Market.values
          .where((item) => item.name == raw)
          .firstOrNull;
      return market;
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(Market? market) async {
    if (!kDebugMode) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (market == null) {
        await prefs.remove(prefKey);
        return;
      }
      await prefs.setString(prefKey, market.name);
    } catch (_) {}
  }
}

abstract final class MarketCache {
  static const _marketKey = 'one_one_cached_market';
  static const _sourceKey = 'one_one_cached_market_source';
  static const _isoKey = 'one_one_cached_market_iso';

  static Future<MarketSnapshot?> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawMarket = prefs.getString(_marketKey);
      if (rawMarket == null) return null;
      final market = Market.values
          .where((item) => item.name == rawMarket)
          .firstOrNull;
      if (market == null) return null;
      final rawSource = prefs.getString(_sourceKey);
      final source = MarketSource.values
          .where((item) => item.name == rawSource)
          .firstOrNull;
      return MarketSnapshot(
        market: market,
        source: source ?? MarketSource.cache,
        isoCountryCode: prefs.getString(_isoKey),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(MarketSnapshot snapshot) async {
    if (snapshot.source == MarketSource.debugOverride) return;
    if (snapshot.source == MarketSource.deviceRegion) {
      // Device region is a weak signal; do not permanently lock the user to it.
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_marketKey, snapshot.market.name);
      await prefs.setString(_sourceKey, snapshot.source.name);
      final iso = snapshot.isoCountryCode ?? snapshot.market.isoCode;
      await prefs.setString(_isoKey, iso);
    } catch (_) {}
  }
}
