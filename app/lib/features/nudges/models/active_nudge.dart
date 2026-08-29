enum ActiveNudgeStatus { pending, accepted, declined, snoozed }

// Incoming nudge this user still needs to answer. [nudgeId] = notificationEventId.
class ActiveNudge {
  const ActiveNudge({
    required this.nudgeId,
    required this.groupId,
    required this.senderId,
    required this.sentAt,
    this.status = ActiveNudgeStatus.pending,
    this.senderName,
    this.snoozedUntil,
  });

  final String nudgeId;
  final String groupId;
  final String senderId;
  final DateTime sentAt;
  final ActiveNudgeStatus status;
  final String? senderName;
  final DateTime? snoozedUntil;

  static const Duration expiry = Duration(minutes: 10);

  bool isExpiredAt(DateTime now) => now.difference(sentAt) > expiry;

  bool isSnoozedAt(DateTime now) {
    if (status != ActiveNudgeStatus.snoozed) return false;
    final until = snoozedUntil;
    return until != null && now.isBefore(until);
  }

  bool isActiveAt(DateTime now) {
    if (isExpiredAt(now)) return false;
    if (status == ActiveNudgeStatus.accepted) return false;
    if (status == ActiveNudgeStatus.declined) return false;
    if (isSnoozedAt(now)) return false;
    return true;
  }

  ActiveNudge copyWith({
    ActiveNudgeStatus? status,
    DateTime? snoozedUntil,
    String? senderName,
    String? senderId,
    DateTime? sentAt,
  }) {
    return ActiveNudge(
      nudgeId: nudgeId,
      groupId: groupId,
      senderId: senderId ?? this.senderId,
      sentAt: sentAt ?? this.sentAt,
      status: status ?? this.status,
      senderName: senderName ?? this.senderName,
      snoozedUntil: snoozedUntil ?? this.snoozedUntil,
    );
  }
}

class ActiveNudgeStatusRecord {
  const ActiveNudgeStatusRecord({
    required this.status,
    required this.at,
    this.snoozedUntil,
  });

  final ActiveNudgeStatus status;
  final DateTime at;
  final DateTime? snoozedUntil;

  Map<String, Object?> toJson() => {
    'status': status.name,
    'at': at.toIso8601String(),
    if (snoozedUntil != null) 'snoozedUntil': snoozedUntil!.toIso8601String(),
  };

  static ActiveNudgeStatusRecord? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final statusName = raw['status']?.toString();
    final status = ActiveNudgeStatus.values
        .where((value) => value.name == statusName)
        .firstOrNull;
    if (status == null) return null;
    final at = DateTime.tryParse(raw['at']?.toString() ?? '');
    if (at == null) return null;
    return ActiveNudgeStatusRecord(
      status: status,
      at: at,
      snoozedUntil: DateTime.tryParse(raw['snoozedUntil']?.toString() ?? ''),
    );
  }
}

// Native FCM payload → ActiveNudge. Null when eventId or groupId is missing.
ActiveNudge? parseIncomingNudge(Map<String, dynamic> raw) {
  final nudgeId =
      raw['eventId']?.toString().trim() ??
      raw['nudgeId']?.toString().trim() ??
      '';
  final groupId = raw['groupId']?.toString().trim() ?? '';
  final senderId =
      raw['senderUserId']?.toString().trim() ??
      raw['senderId']?.toString().trim() ??
      '';
  if (nudgeId.isEmpty || groupId.isEmpty) return null;
  final arrivedAtMs = int.tryParse(raw['arrivedAtMs']?.toString() ?? '');
  final sentAt = arrivedAtMs != null
      ? DateTime.fromMillisecondsSinceEpoch(arrivedAtMs)
      : DateTime.now();
  final statusName = raw['status']?.toString().trim();
  final status = ActiveNudgeStatus.values
      .where((value) => value.name == statusName)
      .firstOrNull;
  final snoozedUntilMs = int.tryParse(raw['snoozedUntilMs']?.toString() ?? '');
  final senderName = raw['senderName']?.toString().trim();
  return ActiveNudge(
    nudgeId: nudgeId,
    groupId: groupId,
    senderId: senderId,
    sentAt: sentAt,
    status: status ?? ActiveNudgeStatus.pending,
    senderName: senderName == null || senderName.isEmpty ? null : senderName,
    snoozedUntil: snoozedUntilMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(snoozedUntilMs),
  );
}
