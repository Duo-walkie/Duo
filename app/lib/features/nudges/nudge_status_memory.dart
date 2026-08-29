import 'package:one_one_app/one_one.dart';

/// Explicit reply from a recipient after a nudge was delivered.
enum NudgeRecipientReply { declined, snoozed }

/// Per-recipient delivery signifier restored when the sheet is reopened.
class LastNudgeRecipientSignifier {
  const LastNudgeRecipientSignifier({
    required this.userId,
    required this.displayName,
    required this.failed,
    this.band,
    this.reply,
    this.failureReason,
  });

  final String userId;
  final String displayName;
  final bool failed;

  /// Machine-readable delivery failure reason (e.g. `timeout`,
  /// `playback_error`). Preserved so reopen restores the same failure
  /// summary instead of collapsing to a synthetic reason.
  final String? failureReason;
  final MediaVolumeBand? band;

  /// Set when the recipient declined or snoozed; takes precedence over [band]
  /// for the corner badge on their profile avatar.
  final NudgeRecipientReply? reply;

  LastNudgeRecipientSignifier copyWith({
    String? userId,
    String? displayName,
    bool? failed,
    String? failureReason,
    MediaVolumeBand? band,
    NudgeRecipientReply? reply,
    bool clearReply = false,
  }) {
    return LastNudgeRecipientSignifier(
      userId: userId ?? this.userId,
      displayName: displayName ?? this.displayName,
      failed: failed ?? this.failed,
      failureReason: failureReason ?? this.failureReason,
      band: band ?? this.band,
      reply: clearReply ? null : (reply ?? this.reply),
    );
  }
}

/// Lifecycle stage of the most recently sent nudge in a group.
///
/// Unlike [NudgeErrorSeverity]/[NudgeFailureMemory], which only record delivery
/// *failures*, this tracks the full pending lifecycle so the sender can re-open
/// the nudge sheet (or tap the main nudge button) and see where the last nudge
/// stands until the receiver accepts it.
enum LastNudgeStatus {
  sent,
  waiting,
  played,
  volumeLow,
  volumeMuted,
  declined,
  snoozed,
  failed,
}

/// A single group's most recently sent nudge, ready to render as a status line
/// in the nudge sheet.
class LastNudgeState {
  const LastNudgeState({
    required this.eventId,
    required this.status,
    required this.message,
    required this.at,
    this.kind,
    this.signifiers = const [],
  });

  final String eventId;
  final LastNudgeStatus status;
  final String message;
  final DateTime at;
  final NudgeKind? kind;
  final List<LastNudgeRecipientSignifier> signifiers;
}

/// In-memory (per app process) record of the most recently sent nudge **per
/// group**, so the sender can revisit its status after dismissing the sheet.
/// Scoped by group so a nudge in one group is never shown while viewing a
/// different group.
///
/// The entry is replaced on each new send and cleared as soon as the receiver
/// accepts (or the entry expires after [timeout], mirroring the sender-side
/// nudge expiry window).
class NudgeStatusMemory {
  NudgeStatusMemory._();

  static final NudgeStatusMemory instance = NudgeStatusMemory._();

  /// How long a pending status stays re-openable after the last send.
  static const Duration timeout = Duration(minutes: 10);

  final Map<String, LastNudgeState> _byGroupId = {};

  /// The active pending status for [groupId], or null if there isn't one.
  LastNudgeState? forGroup(String groupId) {
    final entry = _byGroupId[groupId];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.at) > timeout) {
      _byGroupId.remove(groupId);
      return null;
    }
    return entry;
  }

  /// Reply stored for [userId] in [groupId], if any (and still fresh).
  NudgeRecipientReply? replyFor({
    required String groupId,
    required String userId,
  }) {
    final entry = forGroup(groupId);
    if (entry == null) return null;
    for (final signifier in entry.signifiers) {
      if (signifier.userId == userId) return signifier.reply;
    }
    return null;
  }

  void record(String groupId, LastNudgeState state) {
    if (groupId.isEmpty) return;
    _byGroupId[groupId] = state;
  }

  /// Clears the pending status for [groupId] — call this when the receiver
  /// accepts the nudge so it stops showing as the active pending state.
  void clear(String groupId) {
    _byGroupId.remove(groupId);
  }

  /// Applies a decline/snooze (or clears on accept) for the matching send.
  ///
  /// Returns true when memory was updated. Accept clears the group entry.
  bool applyRecipientResponse({
    required String eventId,
    required String groupId,
    required String responderUserId,
    required String responderName,
    required String action,
  }) {
    if (groupId.isEmpty || eventId.isEmpty) return false;
    if (responderUserId.isEmpty) return false;
    if (action == 'accept') {
      if (forGroup(groupId) != null) {
        clear(groupId);
        return true;
      }
      return false;
    }

    final reply = switch (action) {
      'decline' => NudgeRecipientReply.declined,
      'snooze' => NudgeRecipientReply.snoozed,
      _ => null,
    };
    if (reply == null) return false;

    final existing = forGroup(groupId);
    if (existing == null) return false;

    final firstName = _firstName(responderName);
    final replyLabel = reply == NudgeRecipientReply.declined
        ? '$firstName declined'
        : '$firstName snoozed';
    final status = reply == NudgeRecipientReply.declined
        ? LastNudgeStatus.declined
        : LastNudgeStatus.snoozed;

    final signifiers = <LastNudgeRecipientSignifier>[...existing.signifiers];
    final index = signifiers.indexWhere((s) => s.userId == responderUserId);
    final prior = index >= 0 ? signifiers[index] : null;

    final updated = LastNudgeRecipientSignifier(
      userId: responderUserId,
      displayName: responderName.trim().isEmpty
          ? (prior?.displayName ?? 'Friend')
          : responderName.trim(),
      failed: prior?.failed ?? false,
      failureReason: prior?.failureReason,
      band: prior?.band,
      reply: reply,
    );
    if (index >= 0) {
      signifiers[index] = updated;
    } else {
      signifiers.add(updated);
    }

    record(
      groupId,
      LastNudgeState(
        eventId: eventId,
        status: status,
        message: replyLabel,
        at: DateTime.now(),
        kind: existing.kind,
        signifiers: signifiers,
      ),
    );
    return true;
  }

  static String _firstName(String displayName) {
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) return 'They';
    return trimmed.split(RegExp(r'\s+')).first;
  }
}
