import 'package:flutter_test/flutter_test.dart';

import 'package:one_one_app/one_one.dart';

void main() {
  group('OperationalLog.format', () {
    test('omits null and empty fields and quotes spaced values', () {
      expect(
        OperationalLog.format({
          'event': 'nudge_failed',
          'event_type': 'nudge',
          'status': 'device_unreachable',
          'error': null,
          'sender': '',
          'nudge_id': 'evt-1',
        }),
        'event=nudge_failed event_type=nudge status=device_unreachable '
        'nudge_id=evt-1',
      );
      expect(
        OperationalLog.format({'error': 'no registered device'}),
        'error="no registered device"',
      );
    });
  });

  group('NudgeReachability', () {
    test('missing ACK is device_unreachable, not powered_off', () {
      expect(
        NudgeReachability.fromMissingAck(timedOut: true),
        NudgeReachability.deviceUnreachable,
      );
      expect(
        NudgeReachability.fromMissingAck(timedOut: false),
        NudgeReachability.unknown,
      );
    });

    test('maps reported receiver reasons', () {
      expect(
        NudgeReachability.fromReportedReason('timeout'),
        NudgeReachability.timedOut,
      );
      expect(
        NudgeReachability.fromReportedReason('download_error'),
        NudgeReachability.networkUnavailable,
      );
      expect(
        NudgeReachability.fromReportedReason('playback_error'),
        NudgeReachability.deviceUnreachable,
      );
    });

    test('maps send errors without inventing powered-off', () {
      expect(
        NudgeReachability.fromSendError(TimeoutException('nudge')),
        NudgeReachability.timedOut,
      );
      expect(
        NudgeReachability.fromSendError(
          const ApiException(
            statusCode: 0,
            code: 'network_error',
            message: 'offline',
          ),
        ),
        NudgeReachability.networkUnavailable,
      );
    });
  });
}
