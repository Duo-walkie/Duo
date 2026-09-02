import 'package:one_one_app/one_one.dart';

/// App-wide resolved market. Restores cache immediately so the first frame
/// is never blank, then refines from Play/backend in the background.
class MarketController {
  MarketController._();

  static final ValueNotifier<MarketSnapshot> snapshot =
      ValueNotifier<MarketSnapshot>(MarketSnapshot.unknown);

  static Future<void>? _start;

  static Market get market => snapshot.value.market;
  static MarketSource get source => snapshot.value.source;
  static MarketConfig get config => snapshot.value.config;

  static Future<void> start() => _start ??= _startInternal();

  static Future<void> _startInternal() async {
    final cached = await MarketCache.read();
    if (cached != null && cached.market != Market.unknown) {
      _publish(
        MarketSnapshot(
          market: cached.market,
          source: MarketSource.cache,
          isoCountryCode: cached.isoCountryCode ?? cached.market.isoCode,
        ),
      );
    } else {
      final deviceIso = DeviceRegionCountry.read();
      final deviceMarket = Market.fromIsoCode(deviceIso);
      if (deviceMarket != Market.unknown) {
        _publish(
          MarketSnapshot(
            market: deviceMarket,
            source: MarketSource.deviceRegion,
            isoCountryCode: deviceMarket.isoCode,
          ),
        );
      }
    }

    await _resolveLive(cached: cached);
  }

  static Future<void> refresh() async {
    final cached = await MarketCache.read();
    await _resolveLive(cached: cached);
  }

  /// Called after identity sync. Backend market wins over Play/cache/device.
  /// If the profile has no market yet and Play resolved one, [persistIfAbsent]
  /// writes it so the next launch uses the account value.
  static Future<void> syncWithAccount({
    String? backendMarketIso,
    Future<void> Function(String isoCode)? persistIfAbsent,
  }) async {
    await start();
    if (_isDebugOverride) return;

    final backendMarket = Market.fromIsoCode(backendMarketIso);
    if (backendMarket != Market.unknown) {
      _publish(
        MarketSnapshot(
          market: backendMarket,
          source: MarketSource.backend,
          isoCountryCode: backendMarket.isoCode,
        ),
      );
      await MarketCache.write(snapshot.value);
      LocaleController.reconcileWithMarket(config);
      return;
    }

    final current = snapshot.value;
    if (current.source == MarketSource.playStore &&
        current.market != Market.unknown &&
        persistIfAbsent != null) {
      try {
        await persistIfAbsent(current.isoCountryCode ?? current.market.isoCode);
      } catch (error) {
        debugPrint(
          '[Market] Persist to profile skipped (${error.runtimeType})',
        );
      }
    }
  }

  static bool get _isDebugOverride =>
      kDebugMode && snapshot.value.source == MarketSource.debugOverride;

  static Future<void> setDebugOverride(Market? market) async {
    if (!kDebugMode) return;
    await DebugMarketOverride.write(market);
    if (market == null) {
      snapshot.value = MarketSnapshot.unknown;
      await _resolveLive(cached: await MarketCache.read());
      return;
    }
    _publish(
      MarketSnapshot(
        market: market,
        source: MarketSource.debugOverride,
        isoCountryCode: market.isoCode,
      ),
    );
    LocaleController.reconcileWithMarket(config);
  }

  static Future<void> _resolveLive({MarketSnapshot? cached}) async {
    final resolver = MarketResolver();
    final resolved = await resolver.resolve(cached: cached);
    _publish(resolved);
    await MarketCache.write(resolved);
    LocaleController.reconcileWithMarket(resolved.config);
  }

  static void _publish(MarketSnapshot next) {
    snapshot.value = next;
    _log(next);
    unawaited(_recordDiagnostics(next));
  }

  static void _log(MarketSnapshot next) {
    final config = next.config;
    final language = LocaleController.language;
    debugPrint(
      '[Market] Resolved market: ${next.isoCountryCode ?? next.market.isoCode} '
      'source: ${next.source.logLabel} '
      'locale: ${config.localeTagFor(language)} '
      'onboarding_variant: ${config.onboardingVariant.remoteValue}',
    );
  }

  static Future<void> _recordDiagnostics(MarketSnapshot next) async {
    if (Firebase.apps.isEmpty) return;
    try {
      final iso = next.isoCountryCode ?? next.market.isoCode;
      await AnalyticsService.setUserProperties({
        'market': iso,
        'market_source': next.source.logLabel,
      });
      await CrashlyticsService.setCustomKeys({
        'market': iso,
        'market_source': next.source.logLabel,
        'onboarding_variant': next.config.onboardingVariant.remoteValue,
      });
    } catch (_) {}
  }
}
