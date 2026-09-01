/// Canonical Firebase Analytics event names for Duo.
///
/// Names are snake_case and ≤40 characters. Prefer these over ad-hoc strings
/// so BigQuery export stays consistent.
abstract final class AnalyticsEvents {
  static const buttonClick = 'button_click';
  static const screenView = 'screen_view';
  static const featureSelected = 'feature_selected';
  static const featureUsed = 'feature_used';
  static const appError = 'app_error';

  static const login = 'login';
  static const signUp = 'sign_up';
  static const logout = 'logout';
  static const accountDeleted = 'account_deleted';
  static const profileUpdated = 'profile_updated';
  static const setupCompleted = 'setup_completed';

  static const goOnline = 'go_online';
  static const goAway = 'go_away';
  static const talkStart = 'talk_start';
  static const talkStop = 'talk_stop';
  static const connectionModeChanged = 'connection_mode_changed';
  static const dailyUsageCapReached = 'daily_usage_cap_reached';

  static const groupCreated = 'group_created';
  static const groupJoined = 'group_joined';
  static const groupLeft = 'group_left';
  static const inviteCreated = 'invite_created';

  static const nudgeSent = 'nudge_sent';
  static const nudgeReceived = 'nudge_received';
  static const nudgeFailed = 'nudge_failed';
  static const nudgeResponded = 'nudge_responded';

  static const livekitSessionStarted = 'livekit_session_started';
  static const livekitSessionEnded = 'livekit_session_ended';

  static const notificationReceived = 'notification_received';
  static const notificationOpened = 'notification_opened';

  static const paywallViewed = 'paywall_viewed';
  static const trialStarted = 'trial_started';
  static const purchaseStarted = 'purchase_started';
  static const purchaseCompleted = 'purchase_completed';

  static const appOpen = 'app_open';
  static const sessionStarted = 'session_started';
  static const serviceStatusBlocked = 'service_status_blocked';

  static const all = <String>{
    buttonClick,
    screenView,
    featureSelected,
    featureUsed,
    appError,
    login,
    signUp,
    logout,
    accountDeleted,
    profileUpdated,
    setupCompleted,
    goOnline,
    goAway,
    talkStart,
    talkStop,
    connectionModeChanged,
    dailyUsageCapReached,
    groupCreated,
    groupJoined,
    groupLeft,
    inviteCreated,
    nudgeSent,
    nudgeReceived,
    nudgeFailed,
    nudgeResponded,
    livekitSessionStarted,
    livekitSessionEnded,
    notificationReceived,
    notificationOpened,
    paywallViewed,
    trialStarted,
    purchaseStarted,
    purchaseCompleted,
    appOpen,
    sessionStarted,
    serviceStatusBlocked,
  };
}

abstract final class AnalyticsParams {
  static const buttonName = 'button_name';
  static const screenName = 'screen_name';
  static const screenClass = 'screen_class';
  static const feature = 'feature';
  static const groupIdSuffix = 'group_id_suffix';
  static const memberCount = 'member_count';
  static const nudgeType = 'nudge_type';
  static const targetScope = 'target_scope';
  static const deliveryMethod = 'delivery_method';
  static const failureReason = 'failure_reason';
  static const duration = 'duration';
  static const participantCount = 'participant_count';
  static const source = 'source';
  static const action = 'action';
  static const packageId = 'package_id';
  static const method = 'method';
}
