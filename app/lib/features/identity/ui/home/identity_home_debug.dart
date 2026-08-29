part of '../identity_home_screen.dart';

// 1. Numbered start/end logs for receiver go-live latency (nudge accept → LiveKit).
// 2. Temporary Aug 12 tracing — keep until the 3–7s delay is attributed.

// [DEBUG] Go-live latency tracing helpers added Aug 12. Remove before
// production release. Logs a numbered start/end pair for each major step of
// the receiver's go-live flow (nudge accept -> LiveKit connected) so the
// ~3-4s/~6-7s latency can be attributed to a specific step from device logs.
int _goLiveStepStart(int step, String description) {
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  debugPrint('[GO-LIVE STEP $step START] $description — timestamp: $timestamp');
  return timestamp;
}

void _goLiveStepEnd(int step, String description, int startedAtMs) {
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final elapsed = timestamp - startedAtMs;
  debugPrint(
    '[GO-LIVE STEP $step END] $description — timestamp: $timestamp | elapsed: ${elapsed}ms',
  );
}
