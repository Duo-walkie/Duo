import 'package:one_one_app/one_one.dart';

abstract class ActiveNudgeStatusStore {
  Future<Map<String, ActiveNudgeStatusRecord>> load(String userId);
  Future<void> save(
    String userId,
    Map<String, ActiveNudgeStatusRecord> records,
  );
}

class MemoryActiveNudgeStatusStore implements ActiveNudgeStatusStore {
  MemoryActiveNudgeStatusStore([Map<String, ActiveNudgeStatusRecord>? seed])
    : _records = Map.of(seed ?? const {});

  final Map<String, ActiveNudgeStatusRecord> _records;

  @override
  Future<Map<String, ActiveNudgeStatusRecord>> load(String userId) async =>
      Map.of(_records);

  @override
  Future<void> save(
    String userId,
    Map<String, ActiveNudgeStatusRecord> records,
  ) async {
    _records
      ..clear()
      ..addAll(records);
  }
}

class PrefsActiveNudgeStatusStore implements ActiveNudgeStatusStore {
  const PrefsActiveNudgeStatusStore();

  static String _key(String userId) => 'one_one_incoming_nudge_status_$userId';

  @override
  Future<Map<String, ActiveNudgeStatusRecord>> load(String userId) async {
    if (userId.isEmpty) return <String, ActiveNudgeStatusRecord>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(userId));
      if (raw == null || raw.isEmpty) {
        return <String, ActiveNudgeStatusRecord>{};
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, ActiveNudgeStatusRecord>{};
      final records = <String, ActiveNudgeStatusRecord>{};
      decoded.forEach((key, value) {
        final record = ActiveNudgeStatusRecord.tryParse(value);
        if (record != null) records[key.toString()] = record;
      });
      return records;
    } catch (_) {
      return <String, ActiveNudgeStatusRecord>{};
    }
  }

  @override
  Future<void> save(
    String userId,
    Map<String, ActiveNudgeStatusRecord> records,
  ) async {
    if (userId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = <String, Object?>{
        for (final entry in records.entries) entry.key: entry.value.toJson(),
      };
      await prefs.setString(_key(userId), jsonEncode(encoded));
    } catch (_) {
      // Local persistence is best-effort; the in-memory map still holds.
    }
  }
}

/// In-memory inbox of incoming nudges plus a persisted status map.
///
/// Presentation is **one nudge per group** (most recently sent pending
/// event). Accept still fans out to other still-active events in that group
/// so simultaneous senders can all connect. Decline applies to the presented
/// event and any rings that share its shade notification batch — not every
/// unrelated nudge in the group.
class ActiveNudgeInbox extends ChangeNotifier {
  ActiveNudgeInbox({ActiveNudgeStatusStore? store, DateTime Function()? clock})
    : _store = store ?? const PrefsActiveNudgeStatusStore(),
      _clock = clock ?? DateTime.now;

  static final ActiveNudgeInbox instance = ActiveNudgeInbox();

  final ActiveNudgeStatusStore _store;
  final DateTime Function() _clock;

  static const Duration _statusRetention = Duration(hours: 24);

  final Map<String, ActiveNudge> _byId = {};
  Map<String, ActiveNudgeStatusRecord> _statusById = {};
  String? _userId;
  bool _loaded = false;

  DateTime get _now => _clock();

  Future<void> bindUser(String userId) async {
    if (userId.isEmpty) return;
    if (_loaded && _userId == userId) return;
    _userId = userId;
    // Always copy — stores may return an unmodifiable empty map (`const {}`).
    _statusById = Map<String, ActiveNudgeStatusRecord>.of(
      await _store.load(userId),
    );
    _pruneStatusLocked(_now);
    _applyStatusLocked();
    _loaded = true;
    notifyListeners();
  }

  void upsert(ActiveNudge nudge) {
    _upsertLocked(nudge);
    notifyListeners();
  }

  void _upsertLocked(ActiveNudge nudge) {
    if (nudge.nudgeId.isEmpty || nudge.groupId.isEmpty) return;
    final existing = _byId[nudge.nudgeId];
    final merged = existing == null
        ? nudge
        : existing.copyWith(
            senderName: nudge.senderName ?? existing.senderName,
            senderId: existing.senderId.isNotEmpty
                ? existing.senderId
                : nudge.senderId,
            sentAt: _earlier(existing.sentAt, nudge.sentAt),
          );
    final status = _statusById[nudge.nudgeId];
    _byId[nudge.nudgeId] = status == null
        ? merged
        : merged.copyWith(
            status: status.status,
            snoozedUntil: status.snoozedUntil,
          );
  }

  void upsertAll(Iterable<ActiveNudge> nudges) {
    for (final nudge in nudges) {
      _upsertLocked(nudge);
    }
    notifyListeners();
  }

  Future<void> mark({
    required String nudgeId,
    required ActiveNudgeStatus status,
    DateTime? snoozedUntil,
  }) async {
    if (nudgeId.isEmpty) return;
    final now = _now;
    // Copy before write — `_statusById` may still be an unmodifiable store
    // map if bindUser's copy is ever skipped or reverted.
    _statusById = Map<String, ActiveNudgeStatusRecord>.of(_statusById);
    _statusById[nudgeId] = ActiveNudgeStatusRecord(
      status: status,
      at: now,
      snoozedUntil: snoozedUntil,
    );
    final current = _byId[nudgeId];
    if (current != null) {
      _byId[nudgeId] = current.copyWith(
        status: status,
        snoozedUntil: snoozedUntil,
      );
    }
    _pruneStatusLocked(now);
    notifyListeners();
    final userId = _userId;
    if (userId != null) await _store.save(userId, _statusById);
  }

  Future<void> markAllInGroup({
    required String groupId,
    required ActiveNudgeStatus status,
  }) async {
    final ids = activeInGroup(groupId).map((nudge) => nudge.nudgeId).toList();
    for (final id in ids) {
      await mark(nudgeId: id, status: status);
    }
  }

  /// All still-active events, newest first. Includes multiple senders in
  /// the same group — use [presentationQueue] for the dialogue.
  List<ActiveNudge> activeNudges() {
    final now = _now;
    return _byId.values.where((nudge) => nudge.isActiveAt(now)).toList()
      ..sort((a, b) => b.sentAt.compareTo(a.sentAt));
  }

  List<ActiveNudge> activeInGroup(String groupId) {
    return activeNudges()
        .where((nudge) => nudge.groupId == groupId)
        .toList(growable: false);
  }

  /// True when this group had an accept within [ActiveNudge.expiry].
  bool wasGroupAcceptedRecently(String groupId) {
    if (groupId.isEmpty) return false;
    final now = _now;
    for (final entry in _statusById.entries) {
      final nudge = _byId[entry.key];
      if (nudge?.groupId != groupId) continue;
      if (entry.value.status == ActiveNudgeStatus.accepted &&
          now.difference(entry.value.at) <= ActiveNudge.expiry) {
        return true;
      }
    }
    return false;
  }

  /// One pending nudge per group, most recent first.
  List<ActiveNudge> presentationQueue({
    String? preferGroupId,
    String? preferNudgeId,
  }) {
    var groupId = preferGroupId;
    if ((groupId == null || groupId.isEmpty) &&
        preferNudgeId != null &&
        preferNudgeId.isNotEmpty) {
      groupId = _byId[preferNudgeId]?.groupId;
    }
    final newestByGroup = <String, ActiveNudge>{};
    for (final nudge in activeNudges()) {
      newestByGroup.putIfAbsent(nudge.groupId, () => nudge);
    }
    final queue = newestByGroup.values.toList()
      ..sort((a, b) => b.sentAt.compareTo(a.sentAt));
    if (groupId == null || groupId.isEmpty) return queue;
    final preferred = queue.where((nudge) => nudge.groupId == groupId).toList();
    if (preferred.isEmpty) return queue;
    return [...preferred, ...queue.where((nudge) => nudge.groupId != groupId)];
  }

  void clearMemory() {
    _byId.clear();
    notifyListeners();
  }

  void _applyStatusLocked() {
    for (final entry in _byId.entries.toList()) {
      final status = _statusById[entry.key];
      if (status == null) continue;
      _byId[entry.key] = entry.value.copyWith(
        status: status.status,
        snoozedUntil: status.snoozedUntil,
      );
    }
  }

  void _pruneStatusLocked(DateTime now) {
    // Copy before write. Store loads and `const {}` are unmodifiable; hydrate
    // also runs after AppLifecycle resume on every foreground.
    _statusById = Map<String, ActiveNudgeStatusRecord>.of(_statusById);
    _statusById.removeWhere(
      (_, record) => now.difference(record.at) > _statusRetention,
    );
    _byId.removeWhere((_, nudge) => nudge.isExpiredAt(now));
  }

  DateTime _earlier(DateTime a, DateTime b) => a.isBefore(b) ? a : b;
}
