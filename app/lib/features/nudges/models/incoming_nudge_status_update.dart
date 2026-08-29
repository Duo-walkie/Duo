import 'package:one_one_app/one_one.dart';

// Native accept/decline/snooze that happened outside Flutter.
class IncomingNudgeStatusUpdate {
  const IncomingNudgeStatusUpdate({
    required this.nudgeId,
    required this.status,
    this.snoozedUntil,
  });

  final String nudgeId;
  final ActiveNudgeStatus status;
  final DateTime? snoozedUntil;

  static IncomingNudgeStatusUpdate? tryParse(Map<String, dynamic> raw) {
    final nudgeId =
        raw['eventId']?.toString().trim() ??
        raw['nudgeId']?.toString().trim() ??
        '';
    if (nudgeId.isEmpty) return null;
    final statusName = raw['status']?.toString().trim() ?? '';
    final status = ActiveNudgeStatus.values
        .where((value) => value.name == statusName)
        .firstOrNull;
    if (status == null) return null;
    final snoozedUntilMs = int.tryParse(
      raw['snoozedUntilMs']?.toString() ?? '',
    );
    return IncomingNudgeStatusUpdate(
      nudgeId: nudgeId,
      status: status,
      snoozedUntil: snoozedUntilMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(snoozedUntilMs),
    );
  }
}
