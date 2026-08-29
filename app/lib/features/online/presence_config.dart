/// Configurable timing constants for the "go online together" presence
/// model. Centralized here (rather than inlined as magic numbers) so the
/// grace period and related tuning can be adjusted in one place.
class PresenceConfig {
  PresenceConfig._();

  /// How long we wait after a peer drops off availability before treating
  /// the session as over and forcing the remaining participant offline.
  /// Covers brief connectivity blips (e.g. a tunnel, a Wi-Fi handoff)
  /// without punishing the user who stayed online.
  static const Duration disconnectGracePeriod = Duration(seconds: 60);

  /// If the same remote participant rejoins within this window, skip the
  /// "lost connection" snackbar and show a single "back live" message.
  /// Covers kill-and-relaunch identity swaps and RTDB onDisconnect races.
  static const Duration peerRejoinWindow = Duration(seconds: 15);

  /// How long the room stays open with no voice activity before it
  /// auto-closes. Set short for testing; raise for production.
  static const Duration inactivityTimeout = Duration(minutes: 5);

  /// How long a user may remain the *sole* connected participant in a LiveKit
  /// room before the app treats it as an invalid state: it reports a non-fatal
  /// Crashlytics bug (with on-device logs) and auto-disconnects the user.
  ///
  /// Driven entirely by LiveKit room state (`room.remoteParticipants`) so it
  /// needs no backend/DB presence round-trips. Applies in every connection
  /// mode (walkie-talkie, call, any state).
  static const Duration soloParticipantTimeout = Duration(minutes: 1);

  /// Maximum total online time per user per group per day. Beyond this,
  /// the app blocks further "go online" attempts until the next UTC day.
  /// Prevents runaway sessions from unattended devices.
  static const Duration dailyUsageCap = Duration(minutes: 180);

  /// How long a single continuous stretch of call mode (latched-on mic) is
  /// allowed before the local user is automatically switched back to
  /// walkie-talkie. Does not disconnect them from the group — only their
  /// own connection mode changes. They can tap the main button to talk again.
  static const Duration callModeTimeout = Duration(minutes: 15);
}
