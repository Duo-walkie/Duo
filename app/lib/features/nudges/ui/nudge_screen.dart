import 'package:one_one_app/one_one.dart';

part 'nudge_screen_delivery.dart';
part 'nudge_screen_send.dart';
part 'nudge_screen_build.dart';
part 'nudge_screen_widgets.dart';

// 1. Open sheet
// 2. Restore last status + pick recipients
// 3. Send ring / push / voice  (see send mixin)
// 4. Await delivery            (see delivery mixin)
// 5. Render sheet              (see build mixin)

Future<void> showNudgeBottomSheet(
  BuildContext context, {
  required GroupSummary group,
  required String currentUserId,
  required List<GroupMemberSummary> members,
  required Color accent,
  Set<String> onlineUserIds = const {},
  bool Function()? isLiveMicrophoneInUse,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: false,
    backgroundColor: Colors.transparent,
    isDismissible: true,
    enableDrag: true,
    builder: (_) => _QuickNudgeSheet(
      group: group,
      currentUserId: currentUserId,
      members: members,
      accent: accent,
      onlineUserIds: onlineUserIds,
      isLiveMicrophoneInUse: isLiveMicrophoneInUse,
    ),
  );
}

class _QuickNudgeSheet extends StatefulWidget {
  const _QuickNudgeSheet({
    required this.group,
    required this.currentUserId,
    required this.members,
    required this.accent,
    required this.onlineUserIds,
    this.isLiveMicrophoneInUse,
  });

  final GroupSummary group;
  final String currentUserId;
  final List<GroupMemberSummary> members;
  final Color accent;
  final Set<String> onlineUserIds;
  final bool Function()? isLiveMicrophoneInUse;

  @override
  State<_QuickNudgeSheet> createState() => _QuickNudgeSheetState();
}

abstract class _NudgeSheetStateBase extends State<_QuickNudgeSheet> {
  static const _autoDismissDelay = Duration(seconds: 5);
  final Duration _deliveryStatusCheckTimeout = const Duration(seconds: 4);
  final Duration _deliveryGracePeriod = const Duration(seconds: 3);

  final NudgeRepository _repository = NudgeRepository();
  final AudioRecorder _recorder = AudioRecorder();
  final Stopwatch _recordingWatch = Stopwatch();
  final NudgeCooldownTracker _cooldowns = NudgeCooldownTracker.instance;
  final Set<String> _selectedUserIds = {};
  Timer? _recordingTimer;
  Timer? _recordingCapTimer;
  Timer? _cooldownTicker;
  Timer? _autoDismissTimer;
  bool _recording = false;
  bool _startingRecording = false;
  bool _finishingRecording = false;
  bool _pointerHeld = false;
  bool _sendAfterPointerEnd = true;
  bool _busy = false;
  bool _sendingVoice = false;
  Duration _elapsed = Duration.zero;
  String? _message;
  bool _messageIsError = false;
  bool _messageIsWarning = false;
  bool _messagePending = false;

  bool _showDeliveryBadges = false;
  bool _showConfirmingText = false;
  NudgeKind? _lastSentNudgeKind;

  StreamSubscription<NudgeDeliveryResult>? _deliverySub;
  StreamSubscription<NudgeRecipientResponse>? _responseSub;
  StreamSubscription<List<NudgeDeliveryResult>>? _deliveryStatusSub;
  String? _awaitingEventId;
  String? _lastEventId;

  String? _voiceRequestId;
  String? _voiceNudgeId;
  Future<Map<String, dynamic>>? _voiceUploadReservation;
  final Stopwatch _voiceNudgeWatch = Stopwatch();
  bool _voiceConfirmationLogged = false;
  Timer? _deliveryTimeoutTimer;
  DateTime? _deliveryWaitStartedAt;
  final Map<String, _PendingRecipient> _expectedRecipients = {};
  final Map<String, NudgeDeliveryResult> _resultsByUserId = {};
  final Map<String, NudgeRecipientReply> _repliesByUserId = {};
  MediaVolumeFeedback _rtdbVolumeFeedback = MediaVolumeFeedback.none;

  void _scheduleSenderExpiry(String eventId, List<_PendingRecipient> expected) {
    if (!Platform.isAndroid) return;
    final first = expected.firstOrNull;
    if (first == null) return;
    unawaited(
      AndroidVoiceNudgeBridge.shared.scheduleSenderNudgeExpiry(
        eventId: eventId,
        recipientName: first.displayName,
        recipientUserId: first.userId,
      ),
    );
  }

  void _restorePersistedFailures() {
    final failure = NudgeFailureMemory.instance.forGroup(widget.group.groupId);
    if (failure == null) return;
    _message = failure.message;
    _messageIsError = true;
    _messageIsWarning = false;
    _messagePending = false;
  }

  void _restoreLastNudgeStatus() {
    final last = NudgeStatusMemory.instance.forGroup(widget.group.groupId);
    if (last == null) return;
    _lastSentNudgeKind = last.kind;
    if (last.eventId.isNotEmpty) _lastEventId = last.eventId;
    if (last.signifiers.isNotEmpty &&
        last.status != LastNudgeStatus.sent &&
        last.status != LastNudgeStatus.waiting) {
      _showDeliveryBadges = true;
      for (final signifier in last.signifiers) {
        _expectedRecipients[signifier.userId] = _PendingRecipient(
          userId: signifier.userId,
          displayName: signifier.displayName,
        );
        final reply = signifier.reply;
        if (reply != null) {
          _repliesByUserId[signifier.userId] = reply;
        }
        _resultsByUserId[signifier.userId] = NudgeDeliveryResult(
          eventId: last.eventId,
          status: signifier.failed ? 'failed' : 'played',
          reason: signifier.failed
              ? (signifier.failureReason ?? 'unknown')
              : null,
          attention: switch (signifier.band) {
            MediaVolumeBand.muted => 'volume_muted',
            MediaVolumeBand.veryLow => 'volume_very_low',
            MediaVolumeBand.low => 'volume_low',
            MediaVolumeBand.ok => null,
            null => null,
          },
          recipientUserId: signifier.userId,
          recipientName: signifier.displayName,
        );
      }
    }
    switch (last.status) {
      case LastNudgeStatus.sent:
      case LastNudgeStatus.waiting:
        _message = last.message;
        _messageIsError = false;
        _messageIsWarning = false;
        _messagePending = last.status == LastNudgeStatus.waiting;
        break;
      case LastNudgeStatus.played:
      case LastNudgeStatus.volumeLow:
      case LastNudgeStatus.volumeMuted:
      case LastNudgeStatus.declined:
      case LastNudgeStatus.snoozed:
        if (last.message.isNotEmpty) {
          _message = last.message;
          _messageIsError = false;
          _messageIsWarning =
              last.status == LastNudgeStatus.volumeLow ||
              last.status == LastNudgeStatus.volumeMuted;
          _messagePending = false;
        }
        break;
      case LastNudgeStatus.failed:
        _message = last.message;
        _messageIsError = true;
        _messageIsWarning = false;
        _messagePending = false;
        break;
    }
  }

  void _recordLastStatus(
    LastNudgeStatus status,
    String message, {
    List<LastNudgeRecipientSignifier>? signifiers,
    String? eventId,
  }) {
    NudgeStatusMemory.instance.record(
      widget.group.groupId,
      LastNudgeState(
        eventId: eventId ?? _lastEventId ?? _awaitingEventId ?? '',
        status: status,
        message: message,
        at: DateTime.now(),
        kind: _lastSentNudgeKind,
        signifiers: signifiers ?? const [],
      ),
    );
  }

  List<GroupMemberSummary> get _friends => widget.members
      .where(
        (member) =>
            member.userId != widget.currentUserId &&
            member.memberState == 'active',
      )
      .toList(growable: false);

  bool _isOnline(String userId) => widget.onlineUserIds.contains(userId);

  List<GroupMemberSummary> get _nudgeableFriends =>
      _friends.where((f) => !_isOnline(f.userId)).toList(growable: false);

  bool get _canSend =>
      _nudgeableFriends.isNotEmpty &&
      _selectedUserIds.isNotEmpty &&
      !_busy &&
      !_startingRecording &&
      !_finishingRecording &&
      !_recording &&
      _awaitingEventId == null;

  List<_PendingRecipient> _recipientsForTarget() {
    final selected = _nudgeableFriends
        .where((f) => _selectedUserIds.contains(f.userId))
        .toList(growable: false);
    return selected
        .map(
          (f) =>
              _PendingRecipient(userId: f.userId, displayName: f.displayName),
        )
        .toList(growable: false);
  }

  List<_PendingRecipient> _acceptedRecipients(
    Object? response,
    List<_PendingRecipient> requested,
  ) {
    if (response is! Map || response['recipientUserIds'] is! List) {
      return requested;
    }
    final accepted = (response['recipientUserIds'] as List)
        .map((value) => value.toString())
        .toSet();
    return requested
        .where((recipient) => accepted.contains(recipient.userId))
        .toList(growable: false);
  }

  bool get _isEveryoneSelected {
    final nudgeable = _nudgeableFriends;
    return nudgeable.isNotEmpty &&
        nudgeable.every((f) => _selectedUserIds.contains(f.userId));
  }

  void _selectEveryone() {
    setState(() {
      _selectedUserIds
        ..clear()
        ..addAll(_nudgeableFriends.map((f) => f.userId));
    });
  }

  void _toggleFriend(String userId) {
    if (_isOnline(userId)) return;
    setState(() {
      // Starting from "Everyone": first friend tap narrows to only that
      // person. Further taps then add/remove individuals selectively.
      if (_isEveryoneSelected) {
        _selectedUserIds
          ..clear()
          ..add(userId);
        return;
      }
      if (_selectedUserIds.contains(userId)) {
        if (_selectedUserIds.length == 1) return;
        _selectedUserIds.remove(userId);
      } else {
        _selectedUserIds.add(userId);
      }
    });
  }

  List<MediaVolumeRecipient> _volumeRecipients(
    List<_PendingRecipient> expected,
  ) => [
    for (final recipient in expected)
      MediaVolumeRecipient(
        userId: recipient.userId,
        displayName: recipient.displayName,
      ),
  ];

  Future<MediaVolumeFeedback> _loadVolumeFeedback(
    List<_PendingRecipient> expected,
  ) async {
    try {
      return await MediaVolumeStore.instance
          .feedbackFor(
            groupId: widget.group.groupId,
            recipients: _volumeRecipients(expected),
          )
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      return MediaVolumeFeedback.none;
    }
  }

  void _scheduleAutoDismiss() {
    _autoDismissTimer?.cancel();
    _autoDismissTimer = Timer(_autoDismissDelay, () {
      if (!mounted) return;
      if (_pointerHeld ||
          _recording ||
          _startingRecording ||
          _finishingRecording ||
          _awaitingEventId != null) {
        return;
      }
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }
}

class _QuickNudgeSheetState extends _NudgeSheetStateBase
    with _NudgeSheetDelivery, _NudgeSheetSend, _NudgeSheetBuild {
  @override
  void initState() {
    super.initState();
    _cooldownTicker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
    _deliverySub = AndroidVoiceNudgeBridge.deliveryResults.listen(
      _onDeliveryResult,
    );
    _responseSub = AndroidVoiceNudgeBridge.recipientResponses.listen(
      _onRecipientResponse,
    );
    _selectedUserIds.addAll(_nudgeableFriends.map((f) => f.userId));
    _restorePersistedFailures();
    _restoreLastNudgeStatus();
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _recordingCapTimer?.cancel();
    _cooldownTicker?.cancel();
    _cancelDeliveryWaitTimers();
    _stopDeliveryStatusWatch();
    _autoDismissTimer?.cancel();
    unawaited(_deliverySub?.cancel());
    unawaited(_responseSub?.cancel());
    if (_recording) unawaited(_recorder.stop());
    unawaited(_recorder.dispose());
    super.dispose();
  }
}
