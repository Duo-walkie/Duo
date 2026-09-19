import 'package:one_one_app/one_one.dart';

/// Structured production logs for the monitoring dashboard.
///
/// Written through [LogManager] so they land in the retained daily files
/// that [DeviceLogReport] zips into Firebase Storage. Do not use this for
/// routine UI/DB chatter — only actionable operational events.
class OperationalLog {
  OperationalLog._();

  static const eventTypeNudge = 'nudge';
  static const eventTypeChat = 'chat';
  static const eventTypeLiveKit = 'livekit';
  static const eventTypeNotification = 'notification';

  static const eventConnectionAttempt = 'connection_attempt';
  static const eventConnectionSuccess = 'connection_success';
  static const eventConnectionFailed = 'connection_failed';
  static const eventDisconnect = 'disconnect';
  static const eventSessionStart = 'session_start';
  static const eventSessionEnd = 'session_end';
  static const eventNudgeFailed = 'nudge_failed';
  static const eventMessageSendFailed = 'message_send_failed';
  static const eventMessageDeliveryFailed = 'message_delivery_failed';

  static void record({
    required String event,
    required String eventType,
    String? status,
    String? error,
    String? userId,
    String? groupId,
    String? sender,
    String? receiver,
    String? nudgeId,
    String? sessionId,
    Map<String, Object?> debugMetadata = const {},
    LogLevel level = LogLevel.info,
    String? tag,
  }) {
    final message = format({
      'event': event,
      'event_type': eventType,
      'status': status,
      'error': error,
      'sender': sender,
      'receiver': receiver,
      'nudge_id': nudgeId,
      'session_id': sessionId,
      ...debugMetadata,
    });
    LogManager.log(
      level,
      tag ?? _tagFor(eventType),
      message,
      userId: userId ?? sender ?? receiver,
      groupId: groupId,
    );
  }

  static String format(Map<String, Object?> fields) {
    final parts = <String>[];
    for (final entry in fields.entries) {
      if (entry.value == null) continue;
      final text = entry.value.toString().trim();
      if (text.isEmpty) continue;
      parts.add('${entry.key}=${_escape(text)}');
    }
    return parts.join(' ');
  }

  static String _escape(String value) {
    if (!value.contains(RegExp(r'[\s="]'))) return value;
    return '"${value.replaceAll('"', "'")}"';
  }

  static String _tagFor(String eventType) {
    return switch (eventType) {
      eventTypeNudge => 'NudgeService',
      eventTypeChat => 'ChatService',
      eventTypeLiveKit => 'LiveKitManager',
      eventTypeNotification => 'NotificationService',
      _ => 'OperationalLog',
    };
  }
}

/// Reachability / delivery outcomes that the architecture can actually prove.
///
/// Powered-off vs no-network on the receiver cannot be distinguished, so
/// missing ACKs map to [deviceUnreachable] rather than a guessed cause.
abstract final class NudgeReachability {
  static const delivered = 'delivered';
  static const deviceUnreachable = 'device_unreachable';
  static const networkUnavailable = 'network_unavailable';
  static const timedOut = 'timed_out';
  static const unknown = 'unknown';

  static String fromMissingAck({required bool timedOut}) {
    return timedOut ? deviceUnreachable : unknown;
  }

  static String fromReportedReason(String? reason) {
    switch (NudgeDeliveryFailure.canonicalReason(reason)) {
      case 'timeout':
        return timedOut;
      case 'download_failed':
        return networkUnavailable;
      case null:
        return unknown;
      default:
        return deviceUnreachable;
    }
  }

  static String fromSendError(Object error) {
    if (error is TimeoutException) return timedOut;
    if (error is ApiException) {
      final code = error.code.toLowerCase();
      if (code.contains('network') || error.statusCode == 0) {
        return networkUnavailable;
      }
      if (code.contains('timeout')) return timedOut;
    }
    final text = error.toString().toLowerCase();
    if (text.contains('socket') ||
        text.contains('network') ||
        text.contains('offline') ||
        text.contains('failed host lookup')) {
      return networkUnavailable;
    }
    if (text.contains('timeout')) return timedOut;
    return unknown;
  }
}
