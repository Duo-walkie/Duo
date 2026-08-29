import 'package:one_one_app/one_one.dart';

class NudgeDeliveryStatusStore {
  NudgeDeliveryStatusStore({FirebaseDatabase? database})
    : _database = database ?? AppDatabase.instance();

  static final NudgeDeliveryStatusStore instance = NudgeDeliveryStatusStore();

  final FirebaseDatabase _database;

  /// Live updates for one nudge event (fires as each recipient writes RTDB).
  Stream<List<NudgeDeliveryResult>> watch({
    required String senderUserId,
    required String eventId,
  }) {
    if (senderUserId.isEmpty || eventId.isEmpty) {
      return const Stream.empty();
    }
    final path = 'userNudgeDeliveries/$senderUserId/$eventId';
    LogManager.log(
      LogLevel.info,
      'NudgeService',
      'Delivery RTDB watch start path=$path eventId=$eventId',
    );
    return _database.ref(path).onValue.map((event) {
      final results = _parseDeliveries(eventId, event.snapshot.value);
      LogManager.log(
        LogLevel.info,
        'NudgeService',
        'Delivery RTDB watch update eventId=$eventId count=${results.length} '
            'results=[${results.map((r) => '${r.recipientUserId ?? '?'}:${r.status}').join(', ')}]',
      );
      return results;
    });
  }

  /// One-shot RTDB read before synthesizing timeout/dead.
  Future<List<NudgeDeliveryResult>> loadFromRtdb({
    required String senderUserId,
    required String eventId,
  }) async {
    if (senderUserId.isEmpty || eventId.isEmpty) return const [];
    final path = 'userNudgeDeliveries/$senderUserId/$eventId';
    final sw = Stopwatch()..start();
    try {
      final snapshot = await _database.ref(path).get();
      sw.stop();
      final results = _parseDeliveries(eventId, snapshot.value);
      LogManager.log(
        LogLevel.info,
        'NudgeService',
        'Delivery RTDB get eventId=$eventId path=$path '
            'elapsedMs=${sw.elapsedMilliseconds} count=${results.length} '
            'exists=${snapshot.exists} '
            'results=[${results.map((r) => '${r.recipientUserId ?? '?'}:${r.status}').join(', ')}]',
      );
      return results;
    } catch (error) {
      sw.stop();
      LogManager.log(
        LogLevel.warn,
        'NudgeService',
        'Delivery RTDB get failed eventId=$eventId path=$path '
            'elapsedMs=${sw.elapsedMilliseconds} detail=$error',
      );
      return const [];
    }
  }

  static List<NudgeDeliveryResult> _parseDeliveries(
    String eventId,
    Object? raw,
  ) {
    if (raw is! Map) return const [];
    final results = <NudgeDeliveryResult>[];
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      final map = <String, dynamic>{
        for (final e in value.entries) e.key.toString(): e.value,
        'eventId': eventId,
        'recipientUserId':
            value['recipientUserId']?.toString() ?? entry.key.toString(),
      };
      final parsed = NudgeDeliveryResult.tryParse(map);
      if (parsed != null) results.add(parsed);
    }
    return results;
  }
}
