import 'package:flutter_test/flutter_test.dart';

import 'package:one_one_app/one_one.dart';

void main() {
  group('ActiveNudge', () {
    test('expires after 10 minutes and skips accepted or declined', () {
      final sentAt = DateTime(2026, 8, 18, 10, 0);
      final pending = ActiveNudge(
        nudgeId: 'n1',
        groupId: 'g1',
        senderId: 's1',
        sentAt: sentAt,
      );
      expect(
        pending.isActiveAt(sentAt.add(const Duration(minutes: 9))),
        isTrue,
      );
      expect(
        pending.isActiveAt(sentAt.add(const Duration(minutes: 10, seconds: 1))),
        isFalse,
      );
      expect(
        pending
            .copyWith(status: ActiveNudgeStatus.accepted)
            .isActiveAt(sentAt.add(const Duration(minutes: 1))),
        isFalse,
      );
      expect(
        pending
            .copyWith(status: ActiveNudgeStatus.declined)
            .isActiveAt(sentAt.add(const Duration(minutes: 1))),
        isFalse,
      );
    });
  });

  group('ActiveNudgeInbox', () {
    late DateTime now;
    late ActiveNudgeInbox inbox;

    setUp(() async {
      now = DateTime(2026, 8, 18, 12, 0);
      inbox = ActiveNudgeInbox(
        store: MemoryActiveNudgeStatusStore(),
        clock: () => now,
      );
      await inbox.bindUser('me');
    });

    ActiveNudge nudge({
      required String id,
      required String group,
      required int minutesAgo,
      String sender = 's1',
    }) {
      return ActiveNudge(
        nudgeId: id,
        groupId: group,
        senderId: sender,
        sentAt: now.subtract(Duration(minutes: minutesAgo)),
      );
    }

    test('orders presentation by sentAt descending and one per group', () {
      inbox.upsertAll([
        nudge(id: 'old', group: 'g1', minutesAgo: 8),
        nudge(id: 'new', group: 'g1', minutesAgo: 1),
        nudge(id: 'other', group: 'g2', minutesAgo: 3),
      ]);

      final queue = inbox.presentationQueue();
      expect(queue.map((item) => item.nudgeId), ['new', 'other']);
    });

    test('prefers the notification-body group at the front of the queue', () {
      inbox.upsertAll([
        nudge(id: 'a', group: 'g1', minutesAgo: 1),
        nudge(id: 'b', group: 'g2', minutesAgo: 2),
      ]);

      final queue = inbox.presentationQueue(preferGroupId: 'g2');
      expect(queue.map((item) => item.groupId), ['g2', 'g1']);
    });

    test('silently skips expired nudges', () {
      inbox.upsertAll([
        nudge(id: 'fresh', group: 'g1', minutesAgo: 2),
        nudge(id: 'stale', group: 'g2', minutesAgo: 11),
      ]);

      expect(inbox.activeNudges().map((item) => item.nudgeId), ['fresh']);
    });

    test('does not re-show a declined or accepted nudge', () async {
      inbox.upsert(nudge(id: 'n1', group: 'g1', minutesAgo: 1));
      await inbox.mark(nudgeId: 'n1', status: ActiveNudgeStatus.declined);
      inbox.upsert(nudge(id: 'n1', group: 'g1', minutesAgo: 1));

      expect(inbox.activeNudges(), isEmpty);

      inbox.upsert(nudge(id: 'n2', group: 'g2', minutesAgo: 1));
      await inbox.mark(nudgeId: 'n2', status: ActiveNudgeStatus.accepted);
      expect(inbox.presentationQueue(), isEmpty);
    });

    test('decline cycles to the next group chronologically', () async {
      inbox.upsertAll([
        nudge(id: 'newest', group: 'g1', minutesAgo: 1),
        nudge(id: 'mid', group: 'g2', minutesAgo: 2),
        nudge(id: 'oldest', group: 'g3', minutesAgo: 3),
      ]);

      var queue = inbox.presentationQueue();
      expect(queue.first.nudgeId, 'newest');

      await inbox.markAllInGroup(
        groupId: queue.first.groupId,
        status: ActiveNudgeStatus.declined,
      );
      queue = inbox.presentationQueue();
      expect(queue.map((item) => item.nudgeId), ['mid', 'oldest']);

      await inbox.markAllInGroup(
        groupId: queue.first.groupId,
        status: ActiveNudgeStatus.declined,
      );
      queue = inbox.presentationQueue();
      expect(queue.single.nudgeId, 'oldest');

      await inbox.markAllInGroup(
        groupId: queue.first.groupId,
        status: ActiveNudgeStatus.declined,
      );
      expect(inbox.presentationQueue(), isEmpty);
    });

    test('accepting a group answers every sender in that group', () async {
      inbox.upsertAll([
        nudge(id: 's1', group: 'g1', minutesAgo: 1, sender: 'alice'),
        nudge(id: 's2', group: 'g1', minutesAgo: 2, sender: 'bob'),
        nudge(id: 's3', group: 'g2', minutesAgo: 3, sender: 'cara'),
      ]);

      await inbox.markAllInGroup(
        groupId: 'g1',
        status: ActiveNudgeStatus.accepted,
      );

      expect(inbox.activeInGroup('g1'), isEmpty);
      expect(inbox.presentationQueue().single.nudgeId, 's3');
    });

    test('wasGroupAcceptedRecently is true within 10 minutes', () async {
      inbox.upsert(nudge(id: 'n1', group: 'g1', minutesAgo: 1));
      expect(inbox.wasGroupAcceptedRecently('g1'), isFalse);

      await inbox.mark(nudgeId: 'n1', status: ActiveNudgeStatus.accepted);
      expect(inbox.wasGroupAcceptedRecently('g1'), isTrue);

      now = now.add(const Duration(minutes: 11));
      expect(inbox.wasGroupAcceptedRecently('g1'), isFalse);
    });

    test('persisted status survives a new inbox bind', () async {
      final store = MemoryActiveNudgeStatusStore();
      final first = ActiveNudgeInbox(store: store, clock: () => now);
      await first.bindUser('me');
      first.upsert(nudge(id: 'n1', group: 'g1', minutesAgo: 1));
      await first.mark(nudgeId: 'n1', status: ActiveNudgeStatus.declined);

      final second = ActiveNudgeInbox(store: store, clock: () => now);
      await second.bindUser('me');
      second.upsert(nudge(id: 'n1', group: 'g1', minutesAgo: 1));
      expect(second.activeNudges(), isEmpty);
    });

    test(
      'bindUser copies an unmodifiable empty store map before pruning',
      () async {
        final inbox = ActiveNudgeInbox(
          store: _ConstEmptyStatusStore(),
          clock: () => now,
        );
        await inbox.bindUser('me');
        inbox.upsert(nudge(id: 'n1', group: 'g1', minutesAgo: 1));
        await inbox.mark(nudgeId: 'n1', status: ActiveNudgeStatus.declined);
        expect(inbox.activeNudges(), isEmpty);
      },
    );
  });

  group('ActiveNudgeSync.parseEvent', () {
    final now = DateTime(2026, 8, 18, 12, 0);

    test('parses a targeted nudge and skips the sender and expired rows', () {
      final parsed = ActiveNudgeSync.parseEvent(
        eventId: 'evt1',
        groupId: 'g1',
        currentUserId: 'me',
        now: now,
        raw: {
          'notificationEventId': 'evt1',
          'groupId': 'g1',
          'senderUserId': 'alice',
          'eventType': 'nudge',
          'targetUserIds': ['me', 'bob'],
          'createdAt':
              now.subtract(const Duration(minutes: 2)).millisecondsSinceEpoch ~/
              1000,
          'metadata': {'senderName': 'Alice'},
        },
      );
      expect(parsed, isNotNull);
      expect(parsed!.senderName, 'Alice');
      expect(parsed.senderId, 'alice');
      expect(parsed.kind, NudgeKind.push);

      expect(
        ActiveNudgeSync.parseEvent(
          eventId: 'own',
          groupId: 'g1',
          currentUserId: 'me',
          now: now,
          raw: {
            'senderUserId': 'me',
            'eventType': 'nudge',
            'targetUserIds': ['alice'],
            'createdAt': now.millisecondsSinceEpoch ~/ 1000,
          },
        ),
        isNull,
      );

      expect(
        ActiveNudgeSync.parseEvent(
          eventId: 'stale',
          groupId: 'g1',
          currentUserId: 'me',
          now: now,
          raw: {
            'senderUserId': 'alice',
            'eventType': 'voice_nudge',
            'targetUserIds': ['me'],
            'createdAt':
                now
                    .subtract(const Duration(minutes: 11))
                    .millisecondsSinceEpoch ~/
                1000,
          },
        ),
        isNull,
      );
    });

    test('ignores events that did not target this user', () {
      expect(
        ActiveNudgeSync.parseEvent(
          eventId: 'other',
          groupId: 'g1',
          currentUserId: 'me',
          now: now,
          raw: {
            'senderUserId': 'alice',
            'eventType': 'ring_nudge',
            'targetUserIds': ['bob'],
            'createdAt': now.millisecondsSinceEpoch ~/ 1000,
          },
        ),
        isNull,
      );
    });

    test('maps ring and voice event types onto NudgeKind', () {
      final ring = ActiveNudgeSync.parseEvent(
        eventId: 'ring1',
        groupId: 'g1',
        currentUserId: 'me',
        now: now,
        raw: {
          'senderUserId': 'alice',
          'eventType': 'ring_nudge',
          'targetUserIds': ['me'],
          'createdAt': now.millisecondsSinceEpoch ~/ 1000,
        },
      );
      expect(ring?.kind, NudgeKind.ring);

      final voice = ActiveNudgeSync.parseEvent(
        eventId: 'voice1',
        groupId: 'g1',
        currentUserId: 'me',
        now: now,
        raw: {
          'senderUserId': 'alice',
          'eventType': 'voice_nudge',
          'targetUserIds': ['me'],
          'createdAt': now.millisecondsSinceEpoch ~/ 1000,
        },
      );
      expect(voice?.kind, NudgeKind.voice);
    });
  });

  group('parseIncomingNudge', () {
    test('reads kind and arrivedAtMs from the native payload', () {
      final nudge = parseIncomingNudge({
        'eventId': 'e1',
        'groupId': 'g1',
        'senderUserId': 'alice',
        'senderName': 'Alice',
        'kind': 'voice_nudge',
        'arrivedAtMs': DateTime(2026, 8, 18, 11, 58).millisecondsSinceEpoch,
      });
      expect(nudge, isNotNull);
      expect(nudge!.kind, NudgeKind.voice);
      expect(nudge.senderName, 'Alice');
      expect(nudge.sentAt, DateTime(2026, 8, 18, 11, 58));
    });
  });

  group('IncomingNudgePromptItem', () {
    test('formats type and received labels for the dialogue', () {
      final item = IncomingNudgePromptItem(
        nudge: ActiveNudge(
          nudgeId: 'n1',
          groupId: 'g1',
          senderId: 'alice',
          senderName: 'Alice',
          sentAt: DateTime(2026, 8, 18, 11, 57),
          kind: NudgeKind.ring,
        ),
        groupName: 'Weekend Crew',
        remainingOtherCount: 0,
      );
      expect(item.typeLabel, 'Ring');
      expect(
        item.receivedLabel(now: DateTime(2026, 8, 18, 12, 0)),
        '3 min ago',
      );
    });
  });
}

class _ConstEmptyStatusStore implements ActiveNudgeStatusStore {
  @override
  Future<Map<String, ActiveNudgeStatusRecord>> load(String userId) async =>
      const {};

  @override
  Future<void> save(
    String userId,
    Map<String, ActiveNudgeStatusRecord> records,
  ) async {}
}
