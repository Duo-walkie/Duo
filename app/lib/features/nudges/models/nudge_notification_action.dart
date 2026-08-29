// Notification tap: accept/connect auto-join, open shows the in-app prompt.
class NudgeNotificationAction {
  const NudgeNotificationAction({
    required this.action,
    required this.eventId,
    required this.groupId,
    this.senderUserId,
  });

  /// `accept` and `connect` auto-join live (Case 1 / sender connect).
  /// `open` is a notification-body tap — show the in-app prompt (Case 2).
  final String action;
  final String eventId;
  final String groupId;
  final String? senderUserId;

  bool get isOpenOnly => action == 'open';
  bool get isAutoJoin => action == 'accept' || action == 'connect';

  static NudgeNotificationAction? tryParse(Map<String, dynamic> raw) {
    final action = raw['action']?.toString().trim() ?? '';
    final eventId = raw['eventId']?.toString().trim() ?? '';
    final groupId = raw['groupId']?.toString().trim() ?? '';
    if (!const {'accept', 'connect', 'open'}.contains(action) ||
        eventId.isEmpty ||
        groupId.isEmpty) {
      return null;
    }
    final senderUserId = raw['senderUserId']?.toString().trim();
    return NudgeNotificationAction(
      action: action,
      eventId: eventId,
      groupId: groupId,
      senderUserId: senderUserId == null || senderUserId.isEmpty
          ? null
          : senderUserId,
    );
  }
}
