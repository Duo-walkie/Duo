import 'package:one_one_app/one_one.dart';

const _nudgeEventTypes = {'nudge', 'ring_nudge', 'voice_nudge'};

class ActiveNudgeSync {
  ActiveNudgeSync({FirebaseDatabase? database, DateTime Function()? clock})
    : _database = database ?? AppDatabase.instance(),
      _clock = clock ?? DateTime.now;

  final FirebaseDatabase _database;
  final DateTime Function() _clock;

  Future<List<ActiveNudge>> loadForGroups({
    required Iterable<String> groupIds,
    required String currentUserId,
  }) async {
    if (currentUserId.isEmpty) return const [];
    final uniqueGroupIds = groupIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (uniqueGroupIds.isEmpty) return const [];

    final results = await Future.wait(
      uniqueGroupIds.map(
        (groupId) => _loadGroup(groupId: groupId, currentUserId: currentUserId),
      ),
    );
    return [for (final batch in results) ...batch];
  }

  Future<List<ActiveNudge>> _loadGroup({
    required String groupId,
    required String currentUserId,
  }) async {
    try {
      final snapshot = await _database.ref('notificationEvents/$groupId').get();
      final value = snapshot.value;
      if (value is! Map) return const [];
      final now = _clock();
      final nudges = <ActiveNudge>[];
      value.forEach((key, raw) {
        final parsed = parseEvent(
          eventId: key.toString(),
          groupId: groupId,
          raw: raw,
          currentUserId: currentUserId,
          now: now,
        );
        if (parsed != null) nudges.add(parsed);
      });
      return nudges;
    } catch (_) {
      return const [];
    }
  }

  /// Visible for tests — parses one RTDB `notificationEvents` row.
  static ActiveNudge? parseEvent({
    required String eventId,
    required String groupId,
    required Object? raw,
    required String currentUserId,
    required DateTime now,
  }) {
    if (raw is! Map) return null;
    final data = raw.map((key, value) => MapEntry(key.toString(), value));
    final type = data['eventType']?.toString() ?? '';
    if (!_nudgeEventTypes.contains(type)) return null;

    final senderId =
        data['senderUserId']?.toString().trim() ??
        data['senderId']?.toString().trim() ??
        '';
    if (senderId.isEmpty || senderId == currentUserId) return null;

    final targets = _readUserIds(data['targetUserIds']);
    if (targets.isNotEmpty && !targets.contains(currentUserId)) return null;

    final sentAt = _readSentAt(data['createdAt']) ?? now;
    final eventKey = data['notificationEventId']?.toString().trim() ?? '';
    final groupKey = data['groupId']?.toString().trim() ?? '';
    final nudge = ActiveNudge(
      nudgeId: eventKey.isNotEmpty ? eventKey : eventId,
      groupId: groupKey.isNotEmpty ? groupKey : groupId,
      senderId: senderId,
      sentAt: sentAt,
      senderName: _readSenderName(data),
    );
    if (!nudge.isActiveAt(now)) return null;
    return nudge;
  }

  static String? _readSenderName(Map<String, Object?> data) {
    final direct = data['senderName']?.toString().trim();
    if (direct != null && direct.isNotEmpty) return direct;
    final metadata = data['metadata'];
    if (metadata is Map) {
      final nested = metadata['senderName']?.toString().trim();
      if (nested != null && nested.isNotEmpty) return nested;
    }
    return null;
  }

  static List<String> _readUserIds(Object? value) {
    if (value is List) {
      return value
          .map((item) => item.toString().trim())
          .where((id) => id.isNotEmpty)
          .toList(growable: false);
    }
    if (value is Map) {
      return value.values
          .map((item) => item.toString().trim())
          .where((id) => id.isNotEmpty)
          .toList(growable: false);
    }
    return const [];
  }

  static DateTime? _readSentAt(Object? value) {
    if (value is DateTime) return value;
    num? epoch;
    if (value is num) {
      epoch = value;
    } else {
      epoch = num.tryParse(value?.toString() ?? '');
    }
    if (epoch == null) return null;
    // RTDB stores unix seconds; tolerate millisecond timestamps.
    final millis = epoch > 9999999999 ? epoch.round() : (epoch * 1000).round();
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }
}
