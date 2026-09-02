import 'package:flutter_test/flutter_test.dart';

import 'package:one_one_app/one_one.dart';

void main() {
  test('event names stay within Firebase limits and are unique', () {
    expect(AnalyticsEvents.all.length, greaterThan(20));
    expect(AnalyticsEvents.all.length, AnalyticsEvents.all.toSet().length);
    for (final name in AnalyticsEvents.all) {
      expect(name, isNotEmpty);
      expect(name.length, lessThanOrEqualTo(40));
      expect(name, matches(RegExp(r'^[a-z][a-z0-9_]*$')));
    }
  });

  test('parameter names stay within Firebase limits', () {
    const params = [
      AnalyticsParams.buttonName,
      AnalyticsParams.screenName,
      AnalyticsParams.nudgeType,
      AnalyticsParams.failureReason,
      AnalyticsParams.deliveryMethod,
      AnalyticsParams.groupIdSuffix,
      AnalyticsParams.memberCount,
      AnalyticsParams.duration,
      AnalyticsParams.participantCount,
    ];
    for (final name in params) {
      expect(name.length, lessThanOrEqualTo(40));
    }
  });

  test('talk and livekit names reuse existing taxonomy', () {
    expect(AnalyticsEvents.talkStart, 'talk_start');
    expect(AnalyticsEvents.talkStop, 'talk_stop');
    expect(AnalyticsEvents.nudgeSent, 'nudge_sent');
    expect(AnalyticsEvents.livekitSessionStarted, 'livekit_session_started');
    expect(AnalyticsEvents.buttonClick, 'button_click');
  });
}
