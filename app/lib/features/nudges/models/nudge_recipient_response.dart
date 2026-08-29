// Sender-facing accept / decline / snooze from a recipient.
class NudgeRecipientResponse {
  const NudgeRecipientResponse({
    required this.eventId,
    required this.groupId,
    required this.action,
    this.responderUserId,
    this.responderName,
    this.snoozeMinutes,
  });

  final String eventId;
  final String groupId;

  /// `accept`, `decline`, or `snooze`.
  final String action;
  final String? responderUserId;
  final String? responderName;
  final int? snoozeMinutes;

  bool get isDecline => action == 'decline';
  bool get isSnooze => action == 'snooze';
  bool get isAccept => action == 'accept';

  static NudgeRecipientResponse? tryParse(Map<String, dynamic> raw) {
    final eventId = raw['eventId']?.toString().trim() ?? '';
    final groupId = raw['groupId']?.toString().trim() ?? '';
    final action = raw['responseAction']?.toString().trim() ?? '';
    if (eventId.isEmpty ||
        groupId.isEmpty ||
        !const {'accept', 'decline', 'snooze'}.contains(action)) {
      return null;
    }
    final snoozeMinutes = int.tryParse(
      raw['snoozeMinutes']?.toString().trim() ?? '',
    );
    final responderUserId = raw['responderUserId']?.toString().trim();
    final responderName = raw['responderName']?.toString().trim();
    return NudgeRecipientResponse(
      eventId: eventId,
      groupId: groupId,
      action: action,
      responderUserId: responderUserId == null || responderUserId.isEmpty
          ? null
          : responderUserId,
      responderName: responderName == null || responderName.isEmpty
          ? null
          : responderName,
      snoozeMinutes: snoozeMinutes,
    );
  }
}
