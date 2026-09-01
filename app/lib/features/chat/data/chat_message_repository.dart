import 'package:one_one_app/one_one.dart';

/// Reads/writes ephemeral group chat bubbles (Prompt 5).
///
/// Messages live at `groupMessages/{groupId}/{messageId}` — a push-keyed
/// sibling of `memberAvailability`/`handRaises` — so RTDB security rules and
/// listener teardown follow the same shape already used elsewhere in the
/// screen. Sending writes the bubble directly (client has write access, same
/// as presence) then best-effort asks the backend to fan out a push
/// notification, mirroring `OnlineRepository.notifyGoneOffline`.
class ChatMessageRepository {
  ChatMessageRepository({ApiClient? apiClient, FirebaseDatabase? database})
    : _apiClient = apiClient ?? ApiClient(),
      _database = database ?? AppDatabase.instance();

  final ApiClient _apiClient;
  final FirebaseDatabase _database;

  /// Short, chip-style bubbles — not a full chat thread.
  static const int maxWords = 10;

  /// Rolling window of past messages kept visible on every client.
  static const int visibleLimit = 5;

  /// Full-opacity window after send.
  static const Duration lifetime = Duration(minutes: 10);

  /// After [lifetime], bubbles fade to 0 over this duration, then drop.
  static const Duration fadeDuration = Duration(minutes: 2);

  DatabaseReference groupMessagesRef(String groupId) =>
      _database.ref('groupMessages/$groupId');

  /// Collapses whitespace and enforces the [maxWords] cap. Returns null for
  /// empty or over-length input so callers can treat that as "don't send".
  static String? sanitize(String rawText) {
    final normalized = rawText.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) return null;
    if (normalized.split(' ').length > maxWords) return null;
    return normalized;
  }

  Future<void> sendMessage({
    required String groupId,
    required String senderUserId,
    required String senderDisplayName,
    required String text,
  }) async {
    final sanitized = sanitize(text);
    if (sanitized == null) {
      throw ArgumentError.value(
        text,
        'text',
        'Message must be 1-$maxWords words.',
      );
    }

    // Guard against unauthenticated writes that would fail at the RTDB layer.
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      throw StateError('Cannot send chat message — no authenticated user.');
    }
    if (currentUser.uid != senderUserId) {
      throw StateError(
        'Cannot send chat message — authenticated user (${currentUser.uid}) '
        'does not match senderUserId ($senderUserId).',
      );
    }

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final ref = groupMessagesRef(groupId).push();
    final messageId = ref.key;
    if (messageId == null) {
      throw StateError('Failed to allocate a chat message id.');
    }

    try {
      await ref.set({
        'messageId': messageId,
        'groupId': groupId,
        'senderUserId': senderUserId,
        'senderDisplayName': senderDisplayName,
        'text': sanitized,
        'createdAt': now,
        'expiresAt': now + lifetime.inSeconds + fadeDuration.inSeconds,
      });
    } on FirebaseException catch (error, stack) {
      final denied = _isPermissionDenied(error);
      OperationalLog.record(
        event: OperationalLog.eventMessageSendFailed,
        eventType: OperationalLog.eventTypeChat,
        status: denied ? 'permission_error' : 'database_error',
        error: error.code,
        userId: senderUserId,
        groupId: groupId,
        level: LogLevel.error,
        debugMetadata: {'message_id': messageId},
      );
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'chat_message_write_failed groupId=$groupId',
          feature: 'chat',
        ),
      );
      throw Exception(
        'Could not send message. '
        '${denied ? 'You may need to re-authenticate.' : 'Please try again.'}',
      );
    }

    unawaited(_notifyGroup(groupId, messageId: messageId, text: sanitized));
  }

  /// Clears the collapsing chat notification pile when the group is opened.
  Future<void> clearUnreadPile({
    required String groupId,
    required String userId,
  }) async {
    try {
      await _database.ref('chatUnread/$groupId/$userId').update({
        'count': 0,
        'updatedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      });
    } catch (_) {
      // Best-effort — the local notification cancel still runs.
    }
  }

  /// Best-effort push fan-out — the bubble is already live in-app via RTDB,
  /// so a failed/slow notification call must never block or fail sendMessage.
  Future<void> _notifyGroup(
    String groupId, {
    required String messageId,
    required String text,
  }) async {
    try {
      await _apiClient.postJson(
        '/v1/groups/$groupId/chat-messages/notify',
        {'messageId': messageId, 'text': text},
      );
    } catch (error) {
      final timeout = error is TimeoutException;
      OperationalLog.record(
        event: OperationalLog.eventMessageDeliveryFailed,
        eventType: OperationalLog.eventTypeChat,
        status: timeout ? 'timeout' : 'notify_failed',
        error: error.toString(),
        groupId: groupId,
        level: LogLevel.warn,
        debugMetadata: {'message_id': messageId},
      );
    }
  }

  // ── B8: Emoji burst transport via RTDB ──
  //
  // Emoji bursts during live sessions are written to a short-lived RTDB
  // node.  Remote participants listen and trigger the local burst animation.
  // Each burst auto-expires after 3 seconds via `expiresAt`.

  static const Duration emojiBurstLifetime = Duration(seconds: 3);

  DatabaseReference emojiBurstsRef(String groupId) =>
      _database.ref('emojiBursts/$groupId');

  /// Best-effort remote fan-out for a local emoji burst.
  ///
  /// Never throws: the local animation already played, so failures are logged
  /// as non-fatal and ignored. Callers must not depend on a thrown error.
  Future<void> sendEmojiBurst({
    required String groupId,
    required String senderUserId,
    required String senderDisplayName,
    required String emoji,
  }) async {
    // Guard: the Firebase RTDB security rule requires auth.uid == senderUserId
    // for writes to emojiBursts/{groupId}/{burstId}.
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      unawaited(
        CrashlyticsService.recordError(
          StateError('emoji burst skipped — no authenticated user'),
          StackTrace.current,
          reason: 'emoji_burst_unauthenticated groupId=$groupId',
          feature: 'chat',
        ),
      );
      return;
    }
    if (currentUser.uid != senderUserId) {
      unawaited(
        CrashlyticsService.recordError(
          StateError(
            'emoji burst skipped — auth uid ${currentUser.uid} '
            '!= senderUserId $senderUserId',
          ),
          StackTrace.current,
          reason: 'emoji_burst_uid_mismatch groupId=$groupId',
          feature: 'chat',
        ),
      );
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final ref = emojiBurstsRef(groupId).push();
    final burstId = ref.key;
    if (burstId == null) return;

    try {
      await ref.set({
        'burstId': burstId,
        'groupId': groupId,
        'senderUserId': senderUserId,
        'senderDisplayName': senderDisplayName,
        'emoji': emoji,
        'createdAt': now,
        'expiresAt': now + emojiBurstLifetime.inSeconds,
      });
    } on FirebaseException catch (error, stack) {
      // SDK often reports permission-denied as code "unknown" with the message
      // "Permission denied" — match either form.
      final denied = _isPermissionDenied(error);
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason:
              'emoji_burst_write_failed groupId=$groupId '
              'code=${error.code} denied=$denied',
          feature: 'chat',
        ),
      );
    } catch (error, stack) {
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'emoji_burst_write_failed groupId=$groupId',
          feature: 'chat',
        ),
      );
    }
  }

  static bool _isPermissionDenied(FirebaseException error) {
    final code = error.code.toLowerCase();
    final message = (error.message ?? '').toLowerCase();
    return code == 'permission-denied' ||
        code == 'permission_denied' ||
        message.contains('permission denied');
  }

  /// Live remote emoji stream for a group.
  ///
  /// Uses push-key `onChildAdded` (no secondary index). On attach Firebase
  /// replays existing children — drop anything older than a couple of
  /// seconds so stale history does not explode as a burst stack.
  Stream<Map<String, dynamic>> watchEmojiBursts(String groupId) {
    final subscribedAtSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return emojiBurstsRef(groupId).onChildAdded
        .map((event) {
          final raw = event.snapshot.value;
          if (raw is! Map) return <String, dynamic>{};
          final data = <String, dynamic>{};
          raw.forEach((key, value) {
            data[key.toString()] = value;
          });
          // Prefer key from the path when the payload omitted burstId.
          data['burstId'] ??= event.snapshot.key;
          return data;
        })
        .where((data) {
          if (data['senderUserId'] == null) return false;
          final createdAt = data['createdAt'];
          final createdSec = createdAt is int
              ? createdAt
              : int.tryParse(createdAt?.toString() ?? '');
          // Keep only near-live events (+ small clock skew window).
          if (createdSec != null && createdSec < subscribedAtSec - 3) {
            return false;
          }
          final expiresAt = data['expiresAt'];
          final expiresSec = expiresAt is int
              ? expiresAt
              : int.tryParse(expiresAt?.toString() ?? '');
          if (expiresSec != null &&
              expiresSec < DateTime.now().millisecondsSinceEpoch ~/ 1000) {
            return false;
          }
          return true;
        });
  }
}
