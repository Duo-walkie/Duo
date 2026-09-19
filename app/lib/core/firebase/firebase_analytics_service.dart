import 'package:one_one_app/one_one.dart';

/// Production Analytics wrapper for Duo.
///
/// Event names follow Firebase conventions (snake_case, ≤40 chars).
class AnalyticsService {
  AnalyticsService._();

  static FirebaseAnalytics? _analyticsInstance;

  // `FirebaseAnalytics.instance` throws `[core/no-app]` until
  // `Firebase.initializeApp()` resolves, so this must stay lazy — accessing
  // it eagerly (e.g. as a `static final` field) crashes the very first
  // build of `OneOneApp`, which runs before Firebase finishes booting.
  static FirebaseAnalytics get _analytics =>
      _analyticsInstance ??= FirebaseAnalytics.instance;

  // Handed straight to `MaterialApp(navigatorObservers: ...)` at the first
  // build, so it cannot assume Firebase is ready yet — it resolves the real
  // observer lazily the first time Firebase is actually initialized.
  static NavigatorObserver get observer => _LazyAnalyticsObserver();

  static Future<void> initialize() async {
    await _analytics.setAnalyticsCollectionEnabled(true);
    await logAppOpen();
    _debug('initialized collectionEnabled=true');
  }

  // ─── Core ───────────────────────────────────────────────────────────────

  static Future<void> logCustomEvent(
    String name, {
    Map<String, Object>? parameters,
  }) {
    return _log(name, parameters: parameters);
  }

  static Future<void> logScreenView({
    required String screenName,
    String? screenClass,
  }) {
    return _log(
      AnalyticsEvents.screenView,
      parameters: {
        'screen_name': screenName,
        if (screenClass != null) 'screen_class': screenClass,
      },
    );
  }

  static Future<void> logButtonClick({
    required String buttonName,
    String? screenName,
    String? feature,
  }) {
    return _log(
      AnalyticsEvents.buttonClick,
      parameters: {
        'button_name': buttonName,
        if (screenName != null) 'screen_name': screenName,
        if (feature != null) 'feature': feature,
      },
    );
  }

  static Future<void> logFeatureUsed({
    required String feature,
    Map<String, Object>? parameters,
  }) {
    return _log(
      AnalyticsEvents.featureUsed,
      parameters: {'feature': feature, ...?parameters},
    );
  }

  static Future<void> logApiCall({
    required String endpoint,
    required String method,
    int? statusCode,
    bool success = true,
    int? durationMs,
  }) {
    return _log(
      success ? 'api_call' : 'api_failure',
      parameters: {
        'endpoint': _truncate(endpoint),
        'method': method,
        if (statusCode != null) 'status_code': statusCode,
        if (durationMs != null) 'duration_ms': durationMs,
      },
    );
  }

  static Future<void> logError({
    required String errorType,
    String? feature,
    String? screenName,
    bool isFatal = false,
    String? reason,
  }) {
    return _log(
      AnalyticsEvents.appError,
      parameters: {
        'error_type': _truncate(errorType),
        'is_fatal': isFatal ? 1 : 0,
        if (feature != null) 'feature': feature,
        if (screenName != null) 'screen_name': screenName,
        if (reason != null) 'reason': _truncate(reason),
      },
    );
  }

  // ─── Auth / identity ────────────────────────────────────────────────────

  static Future<void> logLogin({String method = 'google'}) {
    return _log(AnalyticsEvents.login, parameters: {'method': method});
  }

  static Future<void> logSignUp({String method = 'google'}) {
    return _log(AnalyticsEvents.signUp, parameters: {'method': method});
  }

  static Future<void> logLogout() {
    return _log(AnalyticsEvents.logout);
  }

  static Future<void> logAccountDeleted() {
    return _log(AnalyticsEvents.accountDeleted);
  }

  static Future<void> logProfileUpdated({String? field}) {
    return _log(
      AnalyticsEvents.profileUpdated,
      parameters: {if (field != null) 'field': field},
    );
  }

  static Future<void> logSetupCompleted() {
    return _log(AnalyticsEvents.setupCompleted);
  }

  // ─── Presence / talk ────────────────────────────────────────────────────

  static Future<void> logGoOnline({
    required String groupId,
    required String connectionMode,
    bool joinedCallMode = false,
  }) {
    return _log(
      AnalyticsEvents.goOnline,
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        'connection_mode': connectionMode,
        'joined_call_mode': joinedCallMode ? 1 : 0,
      },
    );
  }

  static Future<void> logGoAway({
    required String groupId,
    required String reason,
  }) {
    return _log(
      AnalyticsEvents.goAway,
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        'reason': reason,
      },
    );
  }

  static Future<void> logTalkStart({required String groupId}) {
    return _log(
      AnalyticsEvents.talkStart,
      parameters: {'group_id_suffix': _idSuffix(groupId)},
    );
  }

  static Future<void> logTalkStop({
    required String groupId,
    required String reason,
  }) {
    return _log(
      AnalyticsEvents.talkStop,
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        'reason': reason,
      },
    );
  }

  static Future<void> logConnectionModeChanged({
    required String groupId,
    required String mode,
  }) {
    return _log(
      AnalyticsEvents.connectionModeChanged,
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        'mode': mode,
      },
    );
  }

  static Future<void> logDailyUsageCapReached({required String groupId}) {
    return _log(
      AnalyticsEvents.dailyUsageCapReached,
      parameters: {'group_id_suffix': _idSuffix(groupId)},
    );
  }

  // ─── Groups / invites ───────────────────────────────────────────────────

  static Future<void> logGroupCreated({
    required String groupId,
    int? memberCount,
  }) {
    return _log(
      AnalyticsEvents.groupCreated,
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        if (memberCount != null) 'member_count': memberCount,
      },
    );
  }

  static Future<void> logGroupJoined({
    required String groupId,
    String source = 'invite',
    int? memberCount,
  }) {
    return _log(
      AnalyticsEvents.groupJoined,
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        'source': source,
        if (memberCount != null) 'member_count': memberCount,
      },
    );
  }

  static Future<void> logGroupLeft({
    required String groupId,
    int? memberCount,
  }) {
    return _log(
      AnalyticsEvents.groupLeft,
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        if (memberCount != null) 'member_count': memberCount,
      },
    );
  }

  static Future<void> logInviteCreated({required String groupId}) {
    return _log(
      AnalyticsEvents.inviteCreated,
      parameters: {'group_id_suffix': _idSuffix(groupId)},
    );
  }

  // ─── Nudges ─────────────────────────────────────────────────────────────

  static Future<void> logNudgeSent({
    required String groupId,
    required String kind,
    required String targetScope,
    int? audioBytes,
    int? durationMs,
  }) {
    return _log(
      AnalyticsEvents.nudgeSent,
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        'kind': kind,
        'nudge_type': kind,
        'target_scope': targetScope,
        'delivery_method': 'fcm',
        if (audioBytes != null) 'audio_bytes': audioBytes,
        if (durationMs != null) 'duration_ms': durationMs,
      },
    );
  }

  static Future<void> logNudgeResponded({
    required String groupId,
    required String action,
    int? snoozeMinutes,
  }) {
    return _log(
      AnalyticsEvents.nudgeResponded,
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        'action': action,
        if (snoozeMinutes != null) 'snooze_minutes': snoozeMinutes,
      },
    );
  }

  static Future<void> logNudgeReceived({
    required String groupId,
    String? kind,
    String deliveryMethod = 'fcm',
  }) {
    return _log(
      AnalyticsEvents.nudgeReceived,
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        if (kind != null) 'nudge_type': kind,
        'delivery_method': deliveryMethod,
      },
    );
  }

  static Future<void> logNudgeFailed({
    required String groupId,
    String? kind,
    String? failureReason,
    String? deliveryMethod,
  }) {
    return _log(
      AnalyticsEvents.nudgeFailed,
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        if (kind != null) 'nudge_type': kind,
        if (failureReason != null) 'failure_reason': _truncate(failureReason, 40),
        if (deliveryMethod != null) 'delivery_method': deliveryMethod,
      },
    );
  }

  // ─── LiveKit ────────────────────────────────────────────────────────────

  static Future<void> logLiveKitSessionStarted({required String groupId}) {
    return _log(
      AnalyticsEvents.livekitSessionStarted,
      parameters: {'group_id_suffix': _idSuffix(groupId)},
    );
  }

  static Future<void> logLiveKitSessionEnded({
    required String groupId,
    int? durationSeconds,
    int? participantCount,
  }) {
    return _log(
      AnalyticsEvents.livekitSessionEnded,
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        if (durationSeconds != null) 'duration': durationSeconds,
        if (participantCount != null) 'participant_count': participantCount,
      },
    );
  }

  // ─── Notifications ──────────────────────────────────────────────────────

  static Future<void> logNotificationReceived({
    String? kind,
    String source = 'fcm',
  }) {
    return _log(
      AnalyticsEvents.notificationReceived,
      parameters: {
        'source': source,
        if (kind != null) 'nudge_type': kind,
      },
    );
  }

  static Future<void> logNotificationOpened({
    String? kind,
    String? action,
  }) {
    return _log(
      AnalyticsEvents.notificationOpened,
      parameters: {
        if (kind != null) 'nudge_type': kind,
        if (action != null) 'action': action,
      },
    );
  }

  // ─── User journey / subscriptions ───────────────────────────────────────

  static Future<void> logFeatureSelected({
    required String feature,
    String? screenName,
  }) {
    return _log(
      AnalyticsEvents.featureSelected,
      parameters: {
        'feature': feature,
        if (screenName != null) 'screen_name': screenName,
      },
    );
  }

  static Future<void> logPaywallViewed({String? source}) {
    return _log(
      AnalyticsEvents.paywallViewed,
      parameters: {if (source != null) 'source': source},
    );
  }

  static Future<void> logTrialStarted({String? packageId}) {
    return _log(
      AnalyticsEvents.trialStarted,
      parameters: {if (packageId != null) 'package_id': _truncate(packageId)},
    );
  }

  static Future<void> logPurchaseStarted({String? packageId}) {
    return _log(
      AnalyticsEvents.purchaseStarted,
      parameters: {if (packageId != null) 'package_id': _truncate(packageId)},
    );
  }

  static Future<void> logPurchaseCompleted({
    String? packageId,
    String method = 'purchase',
  }) {
    return _log(
      AnalyticsEvents.purchaseCompleted,
      parameters: {
        'method': method,
        if (packageId != null) 'package_id': _truncate(packageId),
      },
    );
  }

  // ─── App lifecycle ──────────────────────────────────────────────────────

  static Future<void> logAppOpen() {
    return _log(AnalyticsEvents.appOpen);
  }

  static Future<void> logSessionStarted() {
    return _log(AnalyticsEvents.sessionStarted);
  }

  static Future<void> logServiceStatusBlocked({required String status}) {
    return _log(
      AnalyticsEvents.serviceStatusBlocked,
      parameters: {'status': status},
    );
  }

  // ─── User identity / properties ─────────────────────────────────────────

  static Future<void> setUserId(String? userId) async {
    final id = userId?.trim();
    _debug('setUserId=${id == null || id.isEmpty ? '(cleared)' : id}');
    await _analytics.setUserId(id: (id == null || id.isEmpty) ? null : id);
  }

  static Future<void> setUserProperty({
    required String name,
    required String? value,
  }) async {
    _debug('setUserProperty $name=$value');
    await _analytics.setUserProperty(name: name, value: value);
  }

  static Future<void> setUserProperties(Map<String, String?> properties) async {
    for (final entry in properties.entries) {
      await setUserProperty(name: entry.key, value: entry.value);
    }
  }

  static Future<void> resetAnalytics() async {
    _debug('resetAnalyticsData');
    await _analytics.resetAnalyticsData();
  }

  // ─── Internals ──────────────────────────────────────────────────────────

  static Future<void> _log(
    String name, {
    Map<String, Object>? parameters,
  }) async {
    try {
      // Always copy. `logEvent` may write into the parameters map, and
      // `session_started` is fired on every AppLifecycle foreground. Passing
      // `const {}` / an unmodifiable map fatals the root zone.
      final cleanParams = parameters == null
          ? null
          : mutableMapOf(
              Map<String, Object>.fromEntries(
                parameters.entries.where((e) => e.value.toString().isNotEmpty),
              ),
            );
      if (kDebugMode) {
        final buffer = StringBuffer('Analytics Event:\n$name');
        if (cleanParams != null && cleanParams.isNotEmpty) {
          buffer.write('\nparameters:');
          for (final entry in cleanParams.entries) {
            buffer.write('\n  ${entry.key}=${entry.value}');
          }
        }
        debugPrint(buffer.toString());
      }
      await _analytics.logEvent(name: name, parameters: cleanParams);
    } catch (error) {
      debugPrint('[Analytics] log failed name=$name error=$error');
    }
  }

  static String _idSuffix(String id) {
    final clean = id.trim();
    if (clean.length <= 8) return clean;
    return clean.substring(clean.length - 8);
  }

  static String _truncate(String value, [int max = 100]) {
    final clean = value.trim();
    if (clean.length <= max) return clean;
    return clean.substring(0, max);
  }

  static void _debug(String message) {
    if (kDebugMode) debugPrint('[Analytics] $message');
  }
}

/// Defers creating the real `FirebaseAnalyticsObserver` until Firebase has
/// finished initializing, so navigation events before that are silently
/// dropped instead of crashing the app on startup.
class _LazyAnalyticsObserver extends NavigatorObserver {
  FirebaseAnalyticsObserver? _delegate;

  FirebaseAnalyticsObserver? get _resolved {
    if (_delegate != null) return _delegate;
    if (Firebase.apps.isEmpty) return null;
    return _delegate = FirebaseAnalyticsObserver(
      analytics: AnalyticsService._analytics,
    );
  }

  @override
  void didPush(Route route, Route? previousRoute) =>
      _resolved?.didPush(route, previousRoute);

  @override
  void didPop(Route route, Route? previousRoute) =>
      _resolved?.didPop(route, previousRoute);

  @override
  void didRemove(Route route, Route? previousRoute) =>
      _resolved?.didRemove(route, previousRoute);

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) =>
      _resolved?.didReplace(newRoute: newRoute, oldRoute: oldRoute);

  @override
  void didStartUserGesture(Route route, Route? previousRoute) =>
      _resolved?.didStartUserGesture(route, previousRoute);

  @override
  void didStopUserGesture() => _resolved?.didStopUserGesture();
}
