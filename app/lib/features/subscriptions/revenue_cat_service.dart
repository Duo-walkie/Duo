import 'package:purchases_flutter/purchases_flutter.dart';

import 'package:one_one_app/one_one.dart' hide LogLevel;

/// Typed error surfaced to the UI layer — never a raw PlatformException.
class RevenueCatException implements Exception {
  const RevenueCatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Thin wrapper around RevenueCat's Purchases SDK.
///
/// All "is subscribed" checks key off the [AppConfig.proEntitlementId]
/// entitlement, never a specific product ID, so products/offerings can be
/// swapped or added later without touching this code.
class RevenueCatService {
  static RevenueCatService? _instance;

  /// Initialises the SDK. Safe to call more than once — subsequent calls are
  /// no-ops. Must be called before any other method.
  static Future<RevenueCatService> initialize() async {
    if (_instance != null) return _instance!;

    final apiKey = Platform.isIOS
        ? AppConfig.revenueCatAppleApiKey
        : AppConfig.revenueCatGoogleApiKey;

    // Release / Play builds must never configure the Test Store key — that
    // triggers RevenueCat's "Wrong API Key" dialog and force-closes the app.
    if (!kDebugMode && apiKey.startsWith('test_')) {
      throw StateError(
        'RevenueCat Test Store API key used in a non-debug build. '
        'Pass --dart-define=REVENUECAT_GOOGLE_API_KEY=goog_... '
        '(or ONE_ONE_REVENUECAT_ANDROID_API_KEY) when building release.',
      );
    }

    debugPrint(
      '[RevenueCat] configure key kind='
      '${apiKey.startsWith('goog_') ? 'goog' : apiKey.startsWith('appl_') ? 'appl' : apiKey.startsWith('test_') ? 'test' : 'other'} '
      'len=${apiKey.length}',
    );

    await Purchases.configure(PurchasesConfiguration(apiKey));
    if (kDebugMode) {
      await Purchases.setLogLevel(LogLevel.debug);
    }

    _instance = RevenueCatService._();
    return _instance!;
  }

  RevenueCatService._();

  /// Fetches the current RevenueCat offerings (products/packages) from the
  /// server. Packages correspond to `monthly`, `three_month`, `yearly`.
  Future<Offerings> getOfferings() async {
    try {
      // Drop cached customer info so Play/App Store price changes
      // (e.g. INR 60 → 29) surface on the next offerings fetch.
      await Purchases.invalidateCustomerInfoCache();
      return await Purchases.getOfferings();
    } on PlatformException catch (e) {
      throw RevenueCatException(_friendlyMessage(e));
    }
  }

  /// Initiates the purchase flow for [packageToPurchase] and returns the
  /// updated [CustomerInfo]. Throws [RevenueCatException] on error or
  /// cancellation.
  Future<CustomerInfo> purchasePackage(Package packageToPurchase) async {
    try {
      final result = await Purchases.purchase(
        PurchaseParams.package(packageToPurchase),
      );
      return result.customerInfo;
    } on PlatformException catch (e) {
      final code = PurchasesErrorHelper.getErrorCode(e);
      if (code == PurchasesErrorCode.purchaseCancelledError) {
        throw const RevenueCatException('Purchase was cancelled.');
      }
      throw RevenueCatException(_friendlyMessage(e));
    }
  }

  /// Restores any previous purchases the user may have made.
  Future<CustomerInfo> restorePurchases() async {
    try {
      return await Purchases.restorePurchases();
    } on PlatformException catch (e) {
      throw RevenueCatException(_friendlyMessage(e));
    }
  }

  /// Fetches the latest customer info from RevenueCat (and therefore from
  /// the app stores). Use periodically or on app resume.
  Future<CustomerInfo> getCustomerInfo() async {
    try {
      return await Purchases.getCustomerInfo();
    } on PlatformException catch (e) {
      throw RevenueCatException(_friendlyMessage(e));
    }
  }

  /// Returns true when the current user has an active "Duo Pro"
  /// entitlement, whether through subscription or lifetime purchase.
  Future<bool> isEntitledToPro() async {
    try {
      final customerInfo = await Purchases.getCustomerInfo();
      return customerInfo.entitlements.active
          .containsKey(AppConfig.proEntitlementId);
    } on PlatformException {
      // If we can't reach RevenueCat, don't block Pro features — the user
      // may be offline but previously entitled. The next online check will
      // correct the state.
      return false;
    }
  }

  /// Registers a listener for customer-info updates (purchases, restores,
  /// entitlement changes pushed from the server). The callback is invoked
  /// with the latest [CustomerInfo] whenever it changes.
  static void addCustomerInfoListener(
    void Function(CustomerInfo) listener,
  ) {
    Purchases.addCustomerInfoUpdateListener(listener);
  }

  /// Translates the most common PurchasesErrorCode cases into user-friendly
  /// strings. Everything else falls back to a generic message so the UI
  /// never displays a raw PlatformException stack.
  String _friendlyMessage(PlatformException e) {
    final code = PurchasesErrorHelper.getErrorCode(e);

    switch (code) {
      case PurchasesErrorCode.purchaseCancelledError:
        return 'Purchase was cancelled.';
      case PurchasesErrorCode.storeProblemError:
        return 'The app store is unavailable. Try again later.';
      case PurchasesErrorCode.purchaseNotAllowedError:
        return 'This purchase is not allowed on this device.';
      case PurchasesErrorCode.purchaseInvalidError:
        return 'This product is no longer available.';
      case PurchasesErrorCode.productNotAvailableForPurchaseError:
        return 'This product is not available for purchase right now.';
      case PurchasesErrorCode.productAlreadyPurchasedError:
        return 'You already own this. Restore purchases if needed.';
      case PurchasesErrorCode.receiptAlreadyInUseError:
        return 'This receipt is already in use on another account.';
      case PurchasesErrorCode.invalidReceiptError:
        return 'The purchase receipt could not be verified.';
      case PurchasesErrorCode.missingReceiptFileError:
        return 'No purchase receipt was found on this device.';
      case PurchasesErrorCode.networkError:
        return 'No internet connection. Check your network and try again.';
      case PurchasesErrorCode.invalidCredentialsError:
        return 'There was a problem with your account. Please try again.';
      case PurchasesErrorCode.unexpectedBackendResponseError:
        return 'The store responded unexpectedly. Try again.';
      case PurchasesErrorCode.receiptInUseByOtherSubscriberError:
        return 'Your subscription is linked to a different account.';
      case PurchasesErrorCode.unknownBackendError:
        return 'Something went wrong on the server. Try again later.';
      case PurchasesErrorCode.unknownError:
      default:
        return 'Something went wrong. Please try again.';
    }
  }
}

// ── Sandbox Testing Guide ───────────────────────────────────────────
//
// This app currently uses a RevenueCat **sandbox / Test Store** API key.
// To test purchases during closed testing:
//
// 1. Add your Google account as a **License Tester** in the Google Play
//    Console (Play Console → Setup → License testing).
// 2. Join the closed test track with that same account.
// 3. Install the app from the test track.
// 4. When prompted for payment, select a test card (always approved) or
//    use the "Test card, always approves" option.
//
// RevenueCat automatically detects the test track and routes purchases
// through the sandbox environment.
//
// ═══════════════════════════════════════════════════════════════════
// BEFORE GOING TO PRODUCTION:
// 1. In the RevenueCat dashboard, link your real Google Play app
//    (upload the service account JSON key).
// 2. Generate a **production** public API key in the RevenueCat
//    dashboard (under API Keys).
// 3. Replace `test_xyMARSpeunlaQbPftjTriypqInZ` in AppConfig (or the
//    REVENUECAT_GOOGLE_API_KEY / REVENUECAT_APPLE_API_KEY env vars)
//    with the production key.
// 4. The entitlement ID (`Eleven Pro` in RC; shown as Duo Pro in UI) and package identifiers
//    (`monthly`, `three_month`, `yearly`) carry over unchanged between
//    sandbox and production — no code changes needed.
// ═══════════════════════════════════════════════════════════════════
