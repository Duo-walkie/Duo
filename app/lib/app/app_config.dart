class AppConfig {
  static const String apiBaseUrl = String.fromEnvironment(
    'ONE_ONE_API_BASE_URL',
    defaultValue: 'https://one-one-xw00.onrender.com',
  );

  static const String firebaseDatabaseUrl = String.fromEnvironment(
    'ONE_ONE_FIREBASE_DATABASE_URL',
    defaultValue:
        'https://oneone-3adb5-default-rtdb.asia-southeast1.firebasedatabase.app',
  );

  static const String cloudinaryCloudName = String.fromEnvironment(
    'ONE_ONE_CLOUDINARY_CLOUD_NAME',
    defaultValue: 'dfmdfwxlu',
  );

  static const String cloudinaryUploadPreset = String.fromEnvironment(
    'ONE_ONE_CLOUDINARY_UPLOAD_PRESET',
    defaultValue: 'one-one',
  );

  static const String cloudinaryProfileFolder = 'one_one/profile_photos';

  // RevenueCat public SDK keys (safe to ship in the client binary).
  // Override locally with --dart-define if needed:
  //   REVENUECAT_GOOGLE_API_KEY / ONE_ONE_REVENUECAT_ANDROID_API_KEY
  //   REVENUECAT_APPLE_API_KEY / ONE_ONE_REVENUECAT_APPLE_API_KEY
  // Default Google key is the Play Store `goog_` key so release AABs never
  // silently fall back to the Test Store `test_` key.
  static const String revenueCatAppleApiKey = String.fromEnvironment(
    'REVENUECAT_APPLE_API_KEY',
    defaultValue: String.fromEnvironment(
      'ONE_ONE_REVENUECAT_APPLE_API_KEY',
      defaultValue: 'test_xyMARSpeunlaQbPftjTriypqInZ',
    ),
  );

  static const String revenueCatGoogleApiKey = String.fromEnvironment(
    'REVENUECAT_GOOGLE_API_KEY',
    defaultValue: String.fromEnvironment(
      'ONE_ONE_REVENUECAT_ANDROID_API_KEY',
      defaultValue: 'goog_bSeWFliqjLOwZUssFuBzRTRxfBT',
    ),
  );

  /// RevenueCat entitlement identifier (must match the dashboard exactly).
  /// Display name in the app is "Duo Pro"; rename in RevenueCat to `Duo Pro`
  /// when ready, then update this string to match.
  static const String proEntitlementId = 'Eleven Pro';

  /// Support inbox for Duo Pro billing questions and product feedback.
  static const String teamDuoContactEmail = 'duowalkie@gmail.com';
}
