import 'package:flutter_test/flutter_test.dart';

import 'package:one_one_app/one_one.dart';

void main() {
  group('NudgeDeliveryFailure', () {
    test('normalizes delivery failure reasons', () {
      expect(
        NudgeDeliveryFailure.canonicalReason('permission_denied_foreground_service'),
        'background_fg_service_blocked',
      );
      expect(
        NudgeDeliveryFailure.canonicalReason('download_error'),
        'download_failed',
      );
      expect(
        NudgeDeliveryFailure.canonicalReason('playback_service_start_error'),
        'playback_error',
      );
      expect(
        NudgeDeliveryFailure.canonicalReason('playback_error'),
        'playback_error',
      );
      expect(NudgeDeliveryFailure.canonicalReason(null), isNull);
    });
  });

  group('NudgeDeliveryWindow', () {
    test('is long enough for a cold first-nudge confirmation', () {
      expect(NudgeDeliveryWindow.statusCheck, const Duration(seconds: 10));
      expect(NudgeDeliveryWindow.grace, const Duration(seconds: 10));
      expect(NudgeDeliveryWindow.total, const Duration(seconds: 20));
      expect(
        NudgeDeliveryWindow.total,
        greaterThan(const Duration(seconds: 7)),
      );
    });
  });

  group('NudgeDeliveryResult.shouldApply', () {
    const played = NudgeDeliveryResult(
      eventId: 'evt',
      status: 'played',
      recipientUserId: 'u1',
    );
    const failed = NudgeDeliveryResult(
      eventId: 'evt',
      status: 'failed',
      reason: 'timeout',
      recipientUserId: 'u1',
    );

    test('applies the first result', () {
      expect(NudgeDeliveryResult.shouldApply(failed), isTrue);
      expect(NudgeDeliveryResult.shouldApply(played), isTrue);
    });

    test('late played ACK replaces a synthesized timeout', () {
      expect(
        NudgeDeliveryResult.shouldApply(played, existing: failed),
        isTrue,
      );
    });

    test('timeout cannot overwrite a real played ACK', () {
      expect(
        NudgeDeliveryResult.shouldApply(failed, existing: played),
        isFalse,
      );
    });
  });

  group('LastNudgeRecipientSignifier persistence (B1)', () {
    late NudgeStatusMemory memory;

    setUp(() {
      memory = NudgeStatusMemory.instance;
      memory.clear('group-a');
    });

    tearDown(() {
      memory.clear('group-a');
    });

    test('reopen keeps failureReason for failed recipients', () {
      memory.record(
        'group-a',
        LastNudgeState(
          eventId: 'evt-1',
          status: LastNudgeStatus.failed,
          message: 'failed',
          at: DateTime.now(),
          kind: NudgeKind.ring,
          signifiers: const [
            LastNudgeRecipientSignifier(
              userId: 'u1',
              displayName: 'Ada',
              failed: true,
              failureReason: 'battery_optimization_active',
            ),
            LastNudgeRecipientSignifier(
              userId: 'u2',
              displayName: 'Bob',
              failed: true,
              failureReason: 'playback_error',
            ),
          ],
        ),
      );

      final restored = memory.forGroup('group-a')!;
      expect(restored.signifiers[0].failureReason, 'battery_optimization_active');
      expect(restored.signifiers[1].failureReason, 'playback_error');
    });

    test('decline with newer eventId still updates same group', () {
      memory.record(
        'group-a',
        LastNudgeState(
          eventId: 'evt-old',
          status: LastNudgeStatus.sent,
          message: 'sent',
          at: DateTime.now(),
          kind: NudgeKind.voice,
          signifiers: const [],
        ),
      );

      final updated = memory.applyRecipientResponse(
        eventId: 'evt-new',
        groupId: 'group-a',
        responderUserId: 'u1',
        responderName: 'Ada',
        action: 'decline',
      );
      expect(updated, isTrue);
      expect(memory.forGroup('group-a')!.eventId, 'evt-new');
      expect(
        memory.forGroup('group-a')!.signifiers.single.reply,
        NudgeRecipientReply.declined,
      );
    });

    test('decline/snooze reply preserves failureReason', () {
      memory.record(
        'group-a',
        LastNudgeState(
          eventId: 'evt-2',
          status: LastNudgeStatus.failed,
          message: 'failed',
          at: DateTime.now(),
          kind: NudgeKind.voice,
          signifiers: const [
            LastNudgeRecipientSignifier(
              userId: 'u1',
              displayName: 'Ada',
              failed: true,
              failureReason: 'timeout',
            ),
          ],
        ),
      );

      final updated = memory.applyRecipientResponse(
        eventId: 'evt-2',
        groupId: 'group-a',
        responderUserId: 'u1',
        responderName: 'Ada',
        action: 'decline',
      );
      expect(updated, isTrue);

      final signifier = memory.forGroup('group-a')!.signifiers.single;
      expect(signifier.reply, NudgeRecipientReply.declined);
      expect(signifier.failureReason, 'timeout');
      expect(signifier.failed, isTrue);
      expect(memory.forGroup('group-a')!.message, 'Ada declined');
    });
  });
}
