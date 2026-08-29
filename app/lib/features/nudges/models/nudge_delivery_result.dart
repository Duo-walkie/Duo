// Playback started/failed for a ring/voice nudge this device sent.
class NudgeDeliveryResult {
  const NudgeDeliveryResult({
    required this.eventId,
    required this.status,
    this.reason,
    this.attention,
    this.recipientName,
    this.recipientUserId,
  });

  final String eventId;

  /// `played` or `failed`. Reflects whether playback genuinely started, NOT
  /// whether the recipient could hear it.
  final String status;

  /// Machine-readable reason code when playback genuinely failed (e.g.
  /// `download_error`, `playback_error`, `timeout`).
  final String? reason;

  /// Audibility concern for an otherwise-successful playback
  /// (`volume_muted`, `volume_very_low`, or `volume_low`). This is a
  /// warning, never a failure.
  final String? attention;

  final String? recipientName;
  final String? recipientUserId;

  bool get played => status == 'played';

  /// True when the nudge played but the recipient probably didn't hear it
  /// (muted / very low volume).
  bool get playedButNotAudible => played && attention != null;

  /// Human-readable description of the audibility concern for UI display.
  String? get attentionLabel {
    return switch (attention) {
      'volume_muted' => 'their volume was muted',
      'volume_very_low' => 'their volume was very low',
      'volume_low' => 'their volume was too low',
      _ => null,
    };
  }

  static NudgeDeliveryResult? tryParse(Map<String, dynamic> raw) {
    final eventId = raw['eventId']?.toString().trim() ?? '';
    final status = raw['status']?.toString().trim() ?? '';
    if (eventId.isEmpty || !const {'played', 'failed'}.contains(status)) {
      return null;
    }
    return NudgeDeliveryResult(
      eventId: eventId,
      status: status,
      reason: raw['reason']?.toString().trim().isEmpty ?? true
          ? null
          : raw['reason'].toString().trim(),
      attention: raw['attention']?.toString().trim().isEmpty ?? true
          ? null
          : raw['attention'].toString().trim(),
      recipientName: raw['recipientName']?.toString().trim().isEmpty ?? true
          ? null
          : raw['recipientName'].toString().trim(),
      recipientUserId: raw['recipientUserId']?.toString().trim().isEmpty ?? true
          ? null
          : raw['recipientUserId'].toString().trim(),
    );
  }
}

/// Shared delivery-failure reason normalization.
abstract final class NudgeDeliveryFailure {
  static String? canonicalReason(String? reason) {
    if (reason == null || reason.trim().isEmpty) return null;
    switch (reason.trim()) {
      case 'permission_denied_foreground_service':
        return 'background_fg_service_blocked';
      case 'download_error':
        return 'download_failed';
      case 'playback_service_start_error':
        return 'playback_error';
      default:
        return reason.trim();
    }
  }
}
