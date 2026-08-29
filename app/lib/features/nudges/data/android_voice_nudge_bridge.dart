import 'package:one_one_app/one_one.dart';

class AndroidVoiceNudgeBridge {
  static const MethodChannel _channel = MethodChannel('app.oneone/voice_nudge');
  static final StreamController<void> _actionSignals =
      StreamController<void>.broadcast();
  static final StreamController<void> _registrationSignals =
      StreamController<void>.broadcast();
  static final StreamController<NudgeDeliveryResult> _deliveryResults =
      StreamController<NudgeDeliveryResult>.broadcast();
  static final StreamController<NudgeRecipientResponse> _recipientResponses =
      StreamController<NudgeRecipientResponse>.broadcast();
  static final StreamController<String> _receivedSignals =
      StreamController<String>.broadcast();
  static final StreamController<ActiveNudge> _incomingSignals =
      StreamController<ActiveNudge>.broadcast();
  static final StreamController<IncomingNudgeStatusUpdate>
  _incomingStatusSignals =
      StreamController<IncomingNudgeStatusUpdate>.broadcast();
  static bool _handlerInstalled = false;

  static Stream<void> get actionSignals {
    _installHandler();
    return _actionSignals.stream;
  }

  static Stream<void> get registrationSignals {
    _installHandler();
    return _registrationSignals.stream;
  }

  // Incoming FCM payload while Flutter is alive.
  static Stream<ActiveNudge> get incomingSignals {
    _installHandler();
    return _incomingSignals.stream;
  }

  // Native accept/decline/snooze from notification actions.
  static Stream<IncomingNudgeStatusUpdate> get incomingStatusSignals {
    _installHandler();
    return _incomingStatusSignals.stream;
  }

  // groupId as soon as native receives the nudge — used to warm LiveKit.
  static Stream<String> get receivedSignals {
    _installHandler();
    return _receivedSignals.stream;
  }

  // Played/failed for ring+voice this device sent (foreground only).
  static Stream<NudgeDeliveryResult> get deliveryResults {
    _installHandler();
    return _deliveryResults.stream;
  }

  // Accept / decline / snooze for nudges this device sent.
  static Stream<NudgeRecipientResponse> get recipientResponses {
    _installHandler();
    return _recipientResponses.stream;
  }

  static void _installHandler() {
    if (_handlerInstalled || !Platform.isAndroid) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      try {
        await _handleNativeCall(call);
      } catch (error, stack) {
        debugPrint(
          '[OneOneFCM][DART-FCM-W2] Native FCM bridge handler failed '
          'method=${call.method} ${error.runtimeType}: $error',
        );
        final raw = call.arguments;
        final map = raw is Map
            ? raw.map((key, value) => MapEntry(key.toString(), value))
            : const <String, dynamic>{};
        unawaited(
          CrashlyticsService.recordFcmNotificationHandlingFailure(
            error: error,
            stack: stack,
            worker: 'DART-FCM-W2',
            groupId: map['groupId']?.toString(),
            eventId: map['eventId']?.toString() ?? map['nudgeId']?.toString(),
            kind: map['type']?.toString() ?? map['kind']?.toString(),
          ),
        );
      }
    });
  }

  // Native → Dart. Each case is one incoming event.
  static Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onNudgeActionAvailable':
        _onNudgeActionAvailable();
        break;
      case 'onFcmRegistrationRenewed':
        _onFcmRegistrationRenewed();
        break;
      case 'onNudgeReceived':
        _onNudgeReceived(call.arguments);
        break;
      case 'onIncomingNudge':
        _onIncomingNudge(call.arguments);
        break;
      case 'onIncomingNudgeStatus':
        _onIncomingNudgeStatus(call.arguments);
        break;
      case 'onNudgeDeliveryResult':
        _onNudgeDeliveryResult(call.arguments);
        break;
      case 'onNudgeResponse':
        _onNudgeResponse(call.arguments);
        break;
    }
  }

  // 1. Notification action is waiting to be read.
  static void _onNudgeActionAvailable() {
    _actionSignals.add(null);
  }

  // 2. Native FCM registration renewed.
  static void _onFcmRegistrationRenewed() {
    debugPrint('[OneOneFCM][DART-06] Native registration renewed');
    _registrationSignals.add(null);
  }

  // 3. Nudge arrived — emit groupId so LiveKit can warm.
  static void _onNudgeReceived(Object? arguments) {
    final groupId = arguments?.toString().trim() ?? '';
    if (groupId.isNotEmpty) _receivedSignals.add(groupId);
  }

  // 4. Full incoming payload while Flutter is alive.
  static void _onIncomingNudge(Object? arguments) {
    if (arguments is! Map) return;
    final map = arguments.map((key, value) => MapEntry(key.toString(), value));
    final nudge = parseIncomingNudge(map);
    if (nudge != null) {
      _incomingSignals.add(nudge);
      return;
    }
    debugPrint(
      '[OneOneFCM][DART-FCM-W1] Incoming nudge payload missing fields',
    );
    unawaited(
      CrashlyticsService.recordFcmNotificationHandlingFailure(
        error: StateError('Incoming FCM nudge payload missing required fields'),
        worker: 'DART-FCM-W1',
        groupId: map['groupId']?.toString(),
        eventId: map['eventId']?.toString() ?? map['nudgeId']?.toString(),
        kind: map['type']?.toString() ?? map['kind']?.toString(),
      ),
    );
  }

  // 5. Native accept/decline/snooze already happened.
  static void _onIncomingNudgeStatus(Object? arguments) {
    if (arguments is! Map) return;
    final update = IncomingNudgeStatusUpdate.tryParse(
      arguments.map((key, value) => MapEntry(key.toString(), value)),
    );
    if (update != null) _incomingStatusSignals.add(update);
  }

  // 6. Receiver started (or failed) playback.
  static void _onNudgeDeliveryResult(Object? arguments) {
    if (arguments is! Map) return;
    final result = NudgeDeliveryResult.tryParse(
      arguments.map((key, value) => MapEntry(key.toString(), value)),
    );
    if (result != null) _deliveryResults.add(result);
  }

  // 7. Recipient accept / decline / snooze.
  static void _onNudgeResponse(Object? arguments) {
    if (arguments is! Map) return;
    final response = NudgeRecipientResponse.tryParse(
      arguments.map((key, value) => MapEntry(key.toString(), value)),
    );
    if (response != null) _recipientResponses.add(response);
  }

  Future<String?> getFcmToken() async {
    if (!Platform.isAndroid) return null;
    debugPrint('[OneOneFCM][DART-01] Requesting Android FCM registration');
    try {
      final token = await _channel.invokeMethod<String>('getFcmToken');
      final cleanToken = token?.trim();
      if (cleanToken == null || cleanToken.isEmpty) {
        debugPrint(
          '[OneOneFCM][DART-E1] Native registration returned no identifier',
        );
        return null;
      }
      debugPrint(
        '[OneOneFCM][DART-02] Registration identifier received '
        'length=${cleanToken.length} suffix=${_suffix(cleanToken)}',
      );
      return cleanToken;
    } on PlatformException catch (error, stack) {
      debugPrint(
        '[OneOneFCM][DART-E2] Native registration failed '
        'code=${error.code} message=${error.message}',
      );
      await CrashlyticsService.recordError(
        error,
        stack,
        reason: 'fcm_native_registration_failed',
      );
      rethrow;
    } catch (error, stack) {
      debugPrint(
        '[OneOneFCM][DART-E3] Registration bridge failed '
        '${error.runtimeType}: $error',
      );
      await CrashlyticsService.recordError(
        error,
        stack,
        reason: 'fcm_registration_bridge_failed',
      );
      rethrow;
    }
  }

  Future<NudgeNotificationAction?> takePendingNudgeAction() async {
    if (!Platform.isAndroid) return null;
    _installHandler();
    final raw = await _channel.invokeMapMethod<String, dynamic>(
      'takePendingNudgeAction',
    );
    if (raw == null) return null;
    return NudgeNotificationAction.tryParse(raw);
  }

  /// Cached incoming nudges recorded by the native FCM receiver, including
  /// locally declined/accepted statuses from notification actions.
  Future<List<ActiveNudge>> listIncomingNudges() async {
    if (!Platform.isAndroid) return const [];
    _installHandler();
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'listIncomingNudges',
      );
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map(
            (item) => parseIncomingNudge(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
          )
          .whereType<ActiveNudge>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> dismissIncomingNudge(String eventId) async {
    if (!Platform.isAndroid || eventId.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('dismissIncomingNudge', eventId);
    } catch (_) {
      // Local notification cancel is best-effort.
    }
  }

  /// Event IDs that share the same shade notification as [eventId].
  ///
  /// Rings batched within a 10-minute window return every member; voice and
  /// unpaired events return `[eventId]` alone.
  Future<List<String>> eventIdsSharingNotification(String eventId) async {
    if (!Platform.isAndroid || eventId.isEmpty) return [eventId];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'eventIdsSharingNotification',
        eventId,
      );
      final ids = raw
          ?.map((value) => value?.toString().trim() ?? '')
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
      if (ids == null || ids.isEmpty) return [eventId];
      return ids;
    } catch (_) {
      return [eventId];
    }
  }

  /// Shows a "you are online" shade notification on the sender's device after
  /// a background auto-connect completes (the app never came to the foreground).
  Future<void> showYouAreOnlineNotification({
    required String groupId,
    String? groupName,
  }) async {
    if (!Platform.isAndroid || groupId.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('showYouAreOnlineNotification', {
        'groupId': groupId,
        if (groupName != null && groupName.isNotEmpty) 'groupName': groupName,
      });
    } catch (_) {
      // Best-effort — the sender is already live.
    }
  }

  /// B5: Schedule a 10-minute expiry alarm on the sender's device after a
  /// nudge is successfully dispatched. Cancelled on accept / decline / snooze
  /// (native FCM response and Flutter defense-in-depth). Delivery ("played")
  /// does not clear the accept window.
  Future<void> scheduleSenderNudgeExpiry({
    required String eventId,
    required String recipientName,
    required String recipientUserId,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('scheduleSenderNudgeExpiry', {
        'eventId': eventId,
        'recipientName': recipientName,
        'recipientUserId': recipientUserId,
      });
    } catch (_) {
      // Non-fatal — expiry is best-effort.
    }
  }

  Future<void> cancelSenderNudgeExpiry(String eventId) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('cancelSenderNudgeExpiry', eventId);
    } catch (_) {
      // Non-fatal.
    }
  }

  Future<void> clearChatPile(String groupId) async {
    if (!Platform.isAndroid || groupId.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('clearChatPile', groupId);
    } catch (_) {
      // Local notification cancel is best-effort.
    }
  }

  /// Group whose chat-pile notification the user just tapped, if any.
  Future<String?> takePendingChatPileOpen() async {
    if (!Platform.isAndroid) return null;
    _installHandler();
    try {
      final groupId = await _channel.invokeMethod<String>(
        'takePendingChatPileOpen',
      );
      final trimmed = groupId?.trim();
      return trimmed == null || trimmed.isEmpty ? null : trimmed;
    } catch (_) {
      return null;
    }
  }

  /// Local STREAM_MUSIC level as 0–100. Null on non-Android or if native
  /// read fails. Another device's volume cannot be read from here.
  Future<int?> getMediaVolumePercent() async {
    if (!Platform.isAndroid) return null;
    try {
      final raw = await _channel.invokeMethod<int>('getMediaVolumePercent');
      if (raw == null) return null;
      return raw.clamp(0, 100);
    } catch (_) {
      return null;
    }
  }

  /// Pushes the Settings haptic tier to native so incoming nudge playback
  /// (which can run with Flutter paused) uses the same pattern.
  static Future<void> setHapticsIntensity(HapticsIntensity intensity) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>(
        'setHapticsIntensity',
        intensity.storageKey,
      );
    } catch (_) {
      // Native sync is best-effort; Light remains the native default.
    }
  }

  /// Shared instance so multiple widgets can call platform methods without
  /// re-creating the channel handler.
  static final AndroidVoiceNudgeBridge shared = AndroidVoiceNudgeBridge();
}

String _suffix(String value) =>
    value.length <= 6 ? value : value.substring(value.length - 6);
