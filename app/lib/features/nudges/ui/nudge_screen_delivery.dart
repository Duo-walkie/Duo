part of 'nudge_screen.dart';

mixin _NudgeSheetDelivery on _NudgeSheetStateBase {
  bool _isDeliveryFailed(String userId) {
    if (!_showDeliveryBadges) return false;
    if (!_expectedRecipients.containsKey(userId)) return false;
    final result = _resultsByUserId[userId];
    return result != null && !result.played;
  }

  NudgeRecipientReply? _replyFor(String userId) {
    if (!_showDeliveryBadges) return null;
    return _repliesByUserId[userId];
  }

  MediaVolumeBand? _volumeBandFor(String userId) {
    if (!_showDeliveryBadges) return null;
    if (_isDeliveryFailed(userId)) return null;
    if (_replyFor(userId) != null) return null;
    if (!_expectedRecipients.containsKey(userId)) return null;
    if (_lastSentNudgeKind != NudgeKind.voice) return null;

    // Ground truth: live playback attention flag from the receiver.
    final result = _resultsByUserId[userId];
    if (result != null && result.played) {
      final band = MediaVolumeBandX.fromAttention(result.attention);
      if (band != null) return band;
      // Played with no attention = volume was OK; show green badge.
      return MediaVolumeBand.ok;
    }

    // Fallback: RTDB self-report for recipients where we have no result yet
    // (e.g. awaiting-mid-delivery partial results) or for voice nudges whose
    // event IDs did not return a delivery ack (rare edge case).
    return _rtdbVolumeFeedback.bandsByUserId[userId];
  }

  // ── 1. Start confirmation window ─────────────────────────────────────────

  Future<void> _prepareDeliveryWait({
    required String eventId,
    required List<_PendingRecipient> expected,
    required String waitingMessage,
  }) async {
    // Start timers immediately — do not wait on volume RTDB.
    _beginAwaitingDeliveryConfirmation(
      eventId,
      waitingMessage: waitingMessage,
      expected: expected,
    );
    // Volume badges load in the background; shown after finalize.
    final feedback = await _loadVolumeFeedback(expected);
    if (mounted && _awaitingEventId == eventId) {
      _rtdbVolumeFeedback = feedback;
    }
  }

  void _beginAwaitingDeliveryConfirmation(
    String? eventId, {
    required String waitingMessage,
    required List<_PendingRecipient> expected,
  }) {
    if (eventId == null || eventId.isEmpty) return;
    final sentAt = DateTime.now();
    LogManager.log(
      LogLevel.info,
      'NudgeService',
      'Awaiting delivery confirmation eventId=$eventId '
          'sentAt=${sentAt.toIso8601String()} '
          'statusCheckMs=${_deliveryStatusCheckTimeout.inMilliseconds} '
          'graceMs=${_deliveryGracePeriod.inMilliseconds} '
          'totalWindowMs=${_deliveryStatusCheckTimeout.inMilliseconds + _deliveryGracePeriod.inMilliseconds} '
          'expected=[${expected.map((e) => '${e.displayName}:${e.userId}').join(', ')}]',
      groupId: widget.group.groupId,
    );
    _cancelDeliveryWaitTimers();
    _autoDismissTimer?.cancel();
    _deliveryWaitStartedAt = sentAt;
    setState(() {
      _awaitingEventId = eventId;
      _lastEventId = eventId;
      _expectedRecipients
        ..clear()
        ..addEntries(expected.map((e) => MapEntry(e.userId, e)));
      _resultsByUserId.clear();
      _repliesByUserId.clear();
      // Step 2 text only for voice nudges — ring skips straight to icons.
      if (_showConfirmingText && waitingMessage.isNotEmpty) {
        _message = waitingMessage;
        _messageIsError = false;
        _messageIsWarning = false;
        _messagePending = true;
      }
    });
    _startDeliveryStatusWatch(eventId);
    _recordLastStatus(
      LastNudgeStatus.waiting,
      'Waiting for receiver',
      eventId: eventId,
      signifiers: [
        for (final pending in expected)
          LastNudgeRecipientSignifier(
            userId: pending.userId,
            displayName: pending.displayName,
            failed: false,
          ),
      ],
    );
    // 2. Wait for acks (~4s). Do not mark dead yet.
    _deliveryTimeoutTimer = Timer(_deliveryStatusCheckTimeout, () {
      if (!mounted || _awaitingEventId != eventId) return;
      _onDeliveryStatusCheckElapsed(eventId);
    });
  }

  // 3. Status check: RTDB get, then grace if still pending
  void _onDeliveryStatusCheckElapsed(String eventId) {
    unawaited(_runDeliveryStatusCheck(eventId));
  }

  Future<void> _runDeliveryStatusCheck(String eventId) async {
    if (!mounted || _awaitingEventId != eventId) return;
    final pendingBefore = _pendingRecipientIds();
    final checkAt = DateTime.now();
    LogManager.log(
      LogLevel.info,
      'NudgeService',
      'Delivery status check eventId=$eventId '
          'checkAt=${checkAt.toIso8601String()} '
          'elapsedSinceSentMs=${_deliveryElapsedMs()} '
          'acked=[${_resultsByUserId.entries.map((e) => '${e.key}:${e.value.status}').join(', ')}] '
          'pending=[${pendingBefore.map((id) {
            final p = _expectedRecipients[id];
            return '${p?.displayName ?? '?'}:$id';
          }).join(', ')}]',
      groupId: widget.group.groupId,
    );

    if (pendingBefore.isEmpty) {
      _cancelDeliveryWaitTimers();
      _finalizeDeliverySummary(timedOut: false);
      return;
    }

    // Authoritative RTDB get
    await _reconcileFromRtdb(eventId, source: 'status_check');
    if (!mounted || _awaitingEventId != eventId) return;

    final pendingAfter = _pendingRecipientIds();
    if (pendingAfter.isEmpty) {
      LogManager.log(
        LogLevel.info,
        'NudgeService',
        'Delivery status check complete via RTDB eventId=$eventId '
            'elapsedSinceSentMs=${_deliveryElapsedMs()}',
        groupId: widget.group.groupId,
      );
      _cancelDeliveryWaitTimers();
      _finalizeDeliverySummary(timedOut: false);
      return;
    }

    // 4. Grace buffer — still pending, not dead
    LogManager.log(
      LogLevel.info,
      'NudgeService',
      'Delivery grace period start eventId=$eventId '
          'graceAt=${DateTime.now().toIso8601String()} '
          'graceMs=${_deliveryGracePeriod.inMilliseconds} '
          'pending=[${pendingAfter.map((id) {
            final p = _expectedRecipients[id];
            return '${p?.displayName ?? '?'}:$id';
          }).join(', ')}]',
      groupId: widget.group.groupId,
    );
    _deliveryTimeoutTimer = Timer(_deliveryGracePeriod, () {
      if (!mounted || _awaitingEventId != eventId) return;
      unawaited(_onDeliveryGraceElapsed(eventId));
    });
  }

  // 5. Window elapsed — last RTDB get, then timeout/dead
  Future<void> _onDeliveryGraceElapsed(String eventId) async {
    final timeoutAt = DateTime.now();
    LogManager.log(
      LogLevel.warn,
      'NudgeService',
      'Delivery confirmation window elapsed eventId=$eventId '
          'timeoutAt=${timeoutAt.toIso8601String()} '
          'elapsedSinceSentMs=${_deliveryElapsedMs()} '
          'stillPendingBeforeReconcile=[${_pendingRecipientIds().map((id) {
            final p = _expectedRecipients[id];
            return '${p?.displayName ?? '?'}:$id';
          }).join(', ')}]',
      groupId: widget.group.groupId,
    );

    await _reconcileFromRtdb(eventId, source: 'grace_timeout');
    if (!mounted || _awaitingEventId != eventId) return;

    final stillPending = _pendingRecipientIds();
    LogManager.log(
      stillPending.isEmpty ? LogLevel.info : LogLevel.warn,
      'NudgeService',
      'Delivery confirmation after RTDB reconcile eventId=$eventId '
          'elapsedSinceSentMs=${_deliveryElapsedMs()} '
          'stillPending=[${stillPending.map((id) {
            final p = _expectedRecipients[id];
            return '${p?.displayName ?? '?'}:$id';
          }).join(', ')}] '
          'acked=[${_resultsByUserId.entries.map((e) => '${e.key}:${e.value.status}').join(', ')}]',
      groupId: widget.group.groupId,
    );
    _finalizeDeliverySummary(timedOut: stillPending.isNotEmpty);
  }

  // 6. Pull RTDB acks into local results
  Future<void> _reconcileFromRtdb(
    String eventId, {
    required String source,
  }) async {
    LogManager.log(
      LogLevel.info,
      'NudgeService',
      'Delivery RTDB reconcile start eventId=$eventId source=$source '
          'elapsedSinceSentMs=${_deliveryElapsedMs()}',
      groupId: widget.group.groupId,
    );
    final results = await NudgeDeliveryStatusStore.instance.loadFromRtdb(
      senderUserId: widget.currentUserId,
      eventId: eventId,
    );
    for (final result in results) {
      _onDeliveryResult(result, source: 'rtdb_$source');
    }
  }

  void _startDeliveryStatusWatch(String eventId) {
    _stopDeliveryStatusWatch();
    LogManager.log(
      LogLevel.info,
      'NudgeService',
      'Delivery RTDB listen attach eventId=$eventId '
          'senderUserId=${widget.currentUserId} '
          'elapsedSinceSentMs=${_deliveryElapsedMs()}',
      groupId: widget.group.groupId,
    );
    _deliveryStatusSub = NudgeDeliveryStatusStore.instance
        .watch(senderUserId: widget.currentUserId, eventId: eventId)
        .listen(
          (results) {
            for (final result in results) {
              _onDeliveryResult(result, source: 'rtdb');
            }
          },
          onError: (Object error) {
            LogManager.log(
              LogLevel.warn,
              'NudgeService',
              'Delivery RTDB watch error eventId=$eventId detail=$error',
              groupId: widget.group.groupId,
            );
          },
        );
  }

  void _stopDeliveryStatusWatch() {
    if (_deliveryStatusSub != null) {
      LogManager.log(
        LogLevel.info,
        'NudgeService',
        'Delivery RTDB listen detach eventId=${_lastEventId ?? _awaitingEventId}',
        groupId: widget.group.groupId,
      );
    }
    unawaited(_deliveryStatusSub?.cancel());
    _deliveryStatusSub = null;
  }

  List<String> _pendingRecipientIds() {
    if (_expectedRecipients.isEmpty) {
      return _resultsByUserId.isEmpty ? const ['unknown'] : const [];
    }
    return _expectedRecipients.keys
        .where((id) => !_resultsByUserId.containsKey(id))
        .toList(growable: false);
  }

  int _deliveryElapsedMs() {
    final started = _deliveryWaitStartedAt;
    if (started == null) return -1;
    return DateTime.now().difference(started).inMilliseconds;
  }

  // 7. Apply one ack (FCM or RTDB)
  void _onDeliveryResult(NudgeDeliveryResult result, {String source = 'fcm'}) {
    if (!mounted) return;
    final awaiting = _awaitingEventId;
    final lastId = _lastEventId;
    final isActiveWait = awaiting != null && result.eventId == awaiting;
    final isLateForLast =
        !isActiveWait && lastId != null && result.eventId == lastId;
    if (!isActiveWait && !isLateForLast) {
      LogManager.log(
        LogLevel.warn,
        'NudgeService',
        'Delivery result ignored: eventId mismatch result=${result.eventId} '
            'awaiting=$awaiting last=$lastId status=${result.status} '
            'source=$source elapsedSinceSentMs=${_deliveryElapsedMs()}',
        groupId: widget.group.groupId,
      );
      return;
    }

    final ackAt = DateTime.now();
    LogManager.log(
      LogLevel.info,
      'NudgeService',
      'Delivery result matched eventId=${result.eventId} status=${result.status} '
          'source=$source late=$isLateForLast '
          'ackAt=${ackAt.toIso8601String()} '
          'elapsedSinceSentMs=${_deliveryElapsedMs()} '
          'reason=${result.reason ?? '-'} attention=${result.attention ?? '-'} '
          'recipientUserId=${result.recipientUserId ?? '-'} '
          'recipientName=${result.recipientName ?? '-'}',
      groupId: widget.group.groupId,
    );
    if (result.played && result.attention != null) {
      LogManager.log(
        LogLevel.warn,
        'NudgeService',
        'NUDGE_SILENT_PLAYBACK nudgeId=${result.eventId} '
            'attention=${result.attention} '
            'recipientUserId=${result.recipientUserId ?? '-'} '
            'recipientName=${result.recipientName ?? '-'}',
        groupId: widget.group.groupId,
      );
    }
    if (result.played && _voiceNudgeId == result.eventId) {
      LogManager.log(
        LogLevel.info,
        'NudgeService',
        'VOICE_NUDGE_PLAYBACK_STARTED nudgeId=${result.eventId} '
            'recipientUserId=${result.recipientUserId ?? '-'} '
            'recipientName=${result.recipientName ?? '-'} '
            'attention=${result.attention ?? '-'} '
            'elapsedSinceRecordEndMs=${_voiceNudgeWatch.elapsedMilliseconds} '
            'elapsedSinceSentMs=${_deliveryElapsedMs()}',
        groupId: widget.group.groupId,
      );
    }

    final matchedId = _matchDeliveryRecipientId(result);
    final existing = _resultsByUserId[matchedId];
    // Never let a timeout/failed overwrite a real played ACK (stale timer /
    // duplicate reconcile), and skip no-op re-applies from RTDB watches.
    if (existing != null && existing.played && !result.played) {
      return;
    }
    if (existing != null &&
        existing.status == result.status &&
        existing.attention == result.attention &&
        existing.reason == result.reason) {
      if (isLateForLast) return;
      // Active wait: still check whether everyone is done (e.g. RTDB replay).
    } else {
      _resultsByUserId[matchedId] = result;
      if (!result.played) {
        final reachability = NudgeReachability.fromReportedReason(result.reason);
        unawaited(
          AnalyticsService.logNudgeFailed(
            groupId: widget.group.groupId,
            kind: _lastSentNudgeKind?.name,
            failureReason: reachability,
            deliveryMethod: 'fcm',
          ),
        );
        OperationalLog.record(
          event: OperationalLog.eventNudgeFailed,
          eventType: OperationalLog.eventTypeNudge,
          status: reachability,
          error: result.reason,
          sender: widget.currentUserId,
          receiver: matchedId,
          groupId: widget.group.groupId,
          nudgeId: result.eventId,
          level: LogLevel.warn,
          debugMetadata: {
            'nudge_type': _lastSentNudgeKind?.name,
            'send_status': 'sent',
            'delivery_status': result.status,
            'source': source,
          },
        );
      }
    }

    if (isLateForLast) {
      LogManager.log(
        LogLevel.info,
        'NudgeService',
        'Delivery late reconcile eventId=${result.eventId} source=$source '
            'recipientUserId=$matchedId status=${result.status} '
            'clearsPriorFailure=${existing != null && !existing.played && result.played} '
            'elapsedSinceSentMs=${_deliveryElapsedMs()}',
        groupId: widget.group.groupId,
      );
      _refreshFinalDeliveryUiFromResults();
      return;
    }

    _refreshInProgressDeliveryUi();

    final expectedCount = _expectedRecipients.isEmpty
        ? 1
        : _expectedRecipients.length;
    final resolvedExpected = _expectedRecipients.isEmpty
        ? _resultsByUserId.length
        : _expectedRecipients.keys
              .where((id) => _resultsByUserId.containsKey(id))
              .length;
    if (resolvedExpected >= expectedCount) {
      _cancelDeliveryWaitTimers();
      _finalizeDeliverySummary(timedOut: false);
    } else {
      setState(() {});
    }
  }

  String _matchDeliveryRecipientId(NudgeDeliveryResult result) {
    String? matchedId = result.recipientUserId;
    if (matchedId == null || !_expectedRecipients.containsKey(matchedId)) {
      final name = result.recipientName?.trim().toLowerCase();
      if (name != null && name.isNotEmpty) {
        matchedId = _expectedRecipients.entries
            .where((e) => e.value.displayName.trim().toLowerCase() == name)
            .map((e) => e.key)
            .firstOrNull;
      }
    }
    matchedId ??= _expectedRecipients.length == 1
        ? _expectedRecipients.keys.first
        : null;
    if (matchedId == null || matchedId.isEmpty) {
      matchedId =
          result.recipientUserId ??
          result.recipientName ??
          'unknown_${_resultsByUserId.length}';
    }
    return matchedId;
  }

  /// Rebuild badges/message after a late ACK clears a premature timeout skull.
  void _refreshFinalDeliveryUiFromResults() {
    final summaryMessage = _buildDeliveryMessage(partial: false);
    final signifiers = _snapshotSignifiers();
    final failed = _resultsByUserId.values.where((r) => !r.played).toList();
    final volumeWarnings = _mergedVolumeWarnings();
    LogManager.log(
      LogLevel.info,
      'NudgeService',
      'Delivery UI refresh after late/RTDB update '
          'eventId=$_lastEventId failed=${failed.length} '
          'results=[${_resultsByUserId.entries.map((e) => '${e.key}:${e.value.status}').join(', ')}] '
          'elapsedSinceSentMs=${_deliveryElapsedMs()}',
      groupId: widget.group.groupId,
    );
    final anyDeclined = _repliesByUserId.values.any(
      (r) => r == NudgeRecipientReply.declined,
    );
    final anySnoozed = _repliesByUserId.values.any(
      (r) => r == NudgeRecipientReply.snoozed,
    );

    if (failed.isEmpty) {
      NudgeFailureMemory.instance.clearGroup(widget.group.groupId);
    }

    if (failed.isNotEmpty) {
      _recordLastStatus(
        LastNudgeStatus.failed,
        summaryMessage,
        signifiers: signifiers,
      );
    } else if (anyDeclined) {
      _recordLastStatus(
        LastNudgeStatus.declined,
        summaryMessage,
        signifiers: signifiers,
      );
    } else if (anySnoozed) {
      _recordLastStatus(
        LastNudgeStatus.snoozed,
        summaryMessage,
        signifiers: signifiers,
      );
    } else if (volumeWarnings.isNotEmpty) {
      final allMuted = volumeWarnings.every((l) => l.contains(' is muted'));
      _recordLastStatus(
        allMuted ? LastNudgeStatus.volumeMuted : LastNudgeStatus.volumeLow,
        summaryMessage,
        signifiers: signifiers,
      );
    } else {
      _recordLastStatus(
        LastNudgeStatus.played,
        summaryMessage,
        signifiers: signifiers,
      );
    }

    setState(() {
      _showDeliveryBadges = true;
      _messagePending = false;
      _message = summaryMessage;
      _messageIsError = failed.isNotEmpty;
      _messageIsWarning = failed.isEmpty && volumeWarnings.isNotEmpty;
    });
  }

  void _refreshInProgressDeliveryUi() {
    if (_awaitingEventId == null || !_showConfirmingText) return;
    _message = _buildInProgressDeliveryMessage();
    _messageIsError = false;
    _messageIsWarning = false;
    _messagePending = true;
  }

  String _deliveryResultFirstName(NudgeDeliveryResult result) {
    final full = result.recipientName?.trim();
    if (full != null && full.isNotEmpty) {
      return full.split(RegExp(r'\s+')).first;
    }
    final userId = result.recipientUserId;
    if (userId != null) {
      final pending = _expectedRecipients[userId];
      if (pending != null) {
        return pending.displayName.trim().split(RegExp(r'\s+')).first;
      }
    }
    return 'Someone';
  }

  /// Live status line while awaiting acks — updates the moment playback starts
  /// on a receiver, before the final per-person summary replaces it.
  String _buildInProgressDeliveryMessage() {
    final results = _resultsByUserId.values.toList(growable: false);
    final played = results.where((r) => r.played).toList(growable: false);

    if (played.isNotEmpty) {
      final names = played
          .map(_deliveryResultFirstName)
          .toList(growable: false);
      if (_lastSentNudgeKind == NudgeKind.voice) {
        if (names.length == 1) {
          return 'Started playing on ${names.first}\'s device\u2026';
        }
        return 'Started playing for ${_joinNames(names)}\u2026';
      }
      if (names.length == 1) {
        return '${names.first} received it\u2026';
      }
      return '${_joinNames(names)} received it\u2026';
    }

    return switch (_lastSentNudgeKind) {
      NudgeKind.voice => 'Delivering voice nudge\u2026',
      NudgeKind.ring => 'Delivering ring nudge\u2026',
      NudgeKind.push => 'Delivering nudge\u2026',
      null => 'Confirming if they received\u2026',
    };
  }

  void _cancelDeliveryWaitTimers() {
    _deliveryTimeoutTimer?.cancel();
    _deliveryTimeoutTimer = null;
  }

  void _onRecipientResponse(NudgeRecipientResponse response) {
    if (!mounted) return;
    if (response.groupId != widget.group.groupId) return;
    final lastId = _lastEventId ?? _awaitingEventId;
    if (lastId != null &&
        lastId.isNotEmpty &&
        response.eventId != lastId &&
        response.isAccept) {
      return;
    }

    // Cancel sender 10-min expiry on any terminal reply (accept/decline/snooze).
    unawaited(
      AndroidVoiceNudgeBridge.shared.cancelSenderNudgeExpiry(response.eventId),
    );

    if (response.isAccept) {
      NudgeStatusMemory.instance.clear(widget.group.groupId);
      if (mounted) {
        setState(() {
          _repliesByUserId.clear();
          _showDeliveryBadges = false;
        });
      }
      return;
    }

    final reply = response.isDecline
        ? NudgeRecipientReply.declined
        : response.isSnooze
        ? NudgeRecipientReply.snoozed
        : null;
    if (reply == null) return;

    String? matchedId = response.responderUserId;
    if (matchedId == null || matchedId.isEmpty) {
      final name = response.responderName?.trim().toLowerCase();
      if (name != null && name.isNotEmpty) {
        matchedId = _expectedRecipients.entries
            .where((e) => e.value.displayName.trim().toLowerCase() == name)
            .map((e) => e.key)
            .firstOrNull;
      }
    }
    matchedId ??= _expectedRecipients.length == 1
        ? _expectedRecipients.keys.first
        : null;
    if (matchedId == null || matchedId.isEmpty) return;

    final displayName =
        response.responderName ??
        _expectedRecipients[matchedId]?.displayName ??
        'Friend';
    _expectedRecipients.putIfAbsent(
      matchedId,
      () => _PendingRecipient(userId: matchedId!, displayName: displayName),
    );
    _repliesByUserId[matchedId] = reply;
    _lastEventId ??= response.eventId;

    NudgeStatusMemory.instance.applyRecipientResponse(
      eventId: response.eventId,
      groupId: response.groupId,
      responderUserId: matchedId,
      responderName: displayName,
      action: response.action,
    );

    setState(() {
      _showDeliveryBadges = true;
      _message = null;
      _messageIsError = false;
      _messageIsWarning = false;
      _messagePending = false;
    });
    // Give the sender time to see the new reply badge.
    _scheduleAutoDismiss();
  }

  // 8. Close the wait: synthesize timeouts, persist, show badges
  void _finalizeDeliverySummary({required bool timedOut}) {
    if (!mounted) return;
    // Claim this wait cycle immediately so a racing status-check/grace timer
    // cannot re-enter and overwrite a successful ack with synthesized failures.
    final eventId = _awaitingEventId;
    if (eventId == null) return;
    _awaitingEventId = null;
    _cancelDeliveryWaitTimers();

    final elapsedMs = _deliveryElapsedMs();
    if (_voiceNudgeId != null && !_voiceConfirmationLogged) {
      _voiceConfirmationLogged = true;
      _voiceNudgeWatch.stop();
      final totalMs = _voiceNudgeWatch.elapsedMilliseconds;
      if (timedOut) {
        LogManager.log(
          LogLevel.warn,
          'NudgeService',
          'VOICE_NUDGE_CONFIRMATION_TIMEOUT nudgeId=$_voiceNudgeId '
              'totalMs=$totalMs elapsedSinceSentMs=$elapsedMs',
          groupId: widget.group.groupId,
        );
      } else {
        LogManager.log(
          LogLevel.info,
          'NudgeService',
          'VOICE_NUDGE_CONFIRMATION_RECEIVED nudgeId=$_voiceNudgeId '
              'VOICE_NUDGE_TOTAL_TIME nudgeId=$_voiceNudgeId totalMs=$totalMs '
              'elapsedSinceSentMs=$elapsedMs',
          groupId: widget.group.groupId,
        );
      }
    }
    LogManager.log(
      timedOut ? LogLevel.warn : LogLevel.info,
      'NudgeService',
      'Finalizing delivery summary timedOut=$timedOut '
          'eventId=$eventId '
          'finalizeAt=${DateTime.now().toIso8601String()} '
          'elapsedSinceSentMs=$elapsedMs '
          'results=[${_resultsByUserId.entries.map((e) => '${e.key}:${e.value.status}').join(', ')}] '
          'expected=[${_expectedRecipients.keys.join(', ')}]',
      groupId: widget.group.groupId,
    );
    final expected = _expectedRecipients.values.toList(growable: false);
    // Synthesize timeout failures only after the full confirmation window
    // (status check + grace). Recipients are evaluated independently — only
    // those still missing a result become conclusive failures.
    for (final pending in expected) {
      if (!_resultsByUserId.containsKey(pending.userId)) {
        LogManager.log(
          LogLevel.warn,
          'NudgeService',
          'No delivery result for ${pending.displayName} (${pending.userId}); '
              'synthesizing failed/${timedOut ? 'timeout' : 'unknown'} '
              'elapsedSinceSentMs=$elapsedMs',
          groupId: widget.group.groupId,
        );
        _resultsByUserId[pending.userId] = NudgeDeliveryResult(
          eventId: eventId,
          status: 'failed',
          reason: timedOut ? 'timeout' : 'unknown',
          recipientUserId: pending.userId,
          recipientName: pending.displayName,
        );
        final reachability = NudgeReachability.fromMissingAck(timedOut: timedOut);
        unawaited(
          AnalyticsService.logNudgeFailed(
            groupId: widget.group.groupId,
            kind: _lastSentNudgeKind?.name,
            failureReason: reachability,
            deliveryMethod: 'fcm',
          ),
        );
        OperationalLog.record(
          event: OperationalLog.eventNudgeFailed,
          eventType: OperationalLog.eventTypeNudge,
          status: reachability,
          error: timedOut ? 'timeout' : 'unknown',
          sender: widget.currentUserId,
          receiver: pending.userId,
          groupId: widget.group.groupId,
          nudgeId: eventId,
          level: LogLevel.warn,
          debugMetadata: {
            'nudge_type': _lastSentNudgeKind?.name,
            'send_status': 'sent',
            'delivery_status': reachability,
          },
        );
      }
    }

    _deliveryWaitStartedAt = null;

    // Persist failure summaries so they can be shown on sheet reopen.
    final failed = <NudgeDeliveryResult>[];
    final failedNames = <String>[];
    final failedReasons = <String?>[];
    for (final entry in _resultsByUserId.entries) {
      final result = entry.value;
      final name =
          result.recipientName ??
          _expectedRecipients[entry.key]?.displayName ??
          'them';
      if (!result.played) {
        failed.add(result);
        failedNames.add(name.trim().split(RegExp(r'\s+')).first);
        failedReasons.add(result.reason);
      }
    }
    final volumeWarnings = _mergedVolumeWarnings();
    final totalRecipients = _resultsByUserId.length;
    if (failed.isEmpty) {
      NudgeFailureMemory.instance.clearGroup(widget.group.groupId);
    } else {
      final persistMsg = _persistedFailureMessage(
        failed.length,
        totalRecipients,
        failedNames,
        reasons: failedReasons,
      );
      NudgeFailureMemory.instance.record(
        widget.group.groupId,
        failed.length >= totalRecipients
            ? NudgeErrorSeverity.full
            : NudgeErrorSeverity.partial,
        persistMsg,
      );
    }

    // Record status to memory for sheet reopen restoration.
    final summaryMessage = _buildDeliveryMessage(partial: false);
    final signifiers = _snapshotSignifiers();
    final anyDeclined = _repliesByUserId.values.any(
      (r) => r == NudgeRecipientReply.declined,
    );
    final anySnoozed = _repliesByUserId.values.any(
      (r) => r == NudgeRecipientReply.snoozed,
    );
    if (failed.isNotEmpty) {
      _recordLastStatus(
        LastNudgeStatus.failed,
        summaryMessage,
        signifiers: signifiers,
      );
    } else if (anyDeclined) {
      _recordLastStatus(
        LastNudgeStatus.declined,
        summaryMessage,
        signifiers: signifiers,
      );
    } else if (anySnoozed) {
      _recordLastStatus(
        LastNudgeStatus.snoozed,
        summaryMessage,
        signifiers: signifiers,
      );
    } else if (volumeWarnings.isNotEmpty) {
      final allMuted = volumeWarnings.every((l) => l.contains(' is muted'));
      _recordLastStatus(
        allMuted ? LastNudgeStatus.volumeMuted : LastNudgeStatus.volumeLow,
        summaryMessage,
        signifiers: signifiers,
      );
    } else {
      _recordLastStatus(
        LastNudgeStatus.played,
        summaryMessage,
        signifiers: signifiers,
      );
    }

    // Record status to memory for sheet reopen restoration. Keep the
    // confirmation text on screen — delivery badges alone were too easy
    // to miss, and auto-dismiss made "received" vanish.
    setState(() {
      _awaitingEventId = null;
      _messagePending = false;
      _showDeliveryBadges = true;
      _message = summaryMessage;
      _messageIsError = failed.isNotEmpty;
      _messageIsWarning = failed.isEmpty && volumeWarnings.isNotEmpty;
    });
  }

  String _buildDeliveryMessage({required bool partial}) {
    final expected = _expectedRecipients;
    final results = _resultsByUserId.values.toList(growable: false);
    if (results.isEmpty) {
      return partial
          ? 'Confirming delivery\u2026'
          : 'Nudge wasn\u2019t played, try again.';
    }

    final failed = results.where((r) => !r.played).toList(growable: false);
    final attention = results
        .where((r) => r.playedButNotAudible)
        .toList(growable: false);
    final cleanPlayed = results
        .where((r) => r.played && r.attention == null)
        .toList(growable: false);

    String nameOf(NudgeDeliveryResult r) {
      if (r.recipientName != null && r.recipientName!.trim().isNotEmpty) {
        return r.recipientName!.trim().split(RegExp(r'\s+')).first;
      }
      if (r.recipientUserId != null) {
        final pending = expected[r.recipientUserId!];
        if (pending != null) {
          return pending.displayName.trim().split(RegExp(r'\s+')).first;
        }
      }
      return 'Someone';
    }

    if (failed.isNotEmpty) {
      if (failed.length == 1) {
        return _shortFailureWithReason(
          nameOf(failed.first),
          failed.first.reason,
        );
      }
      // Prefer per-person lines when there are only a couple of failures so
      // the sender sees exactly who did not receive the nudge.
      if (failed.length <= 2) {
        return failed
            .map((f) => _shortFailureWithReason(nameOf(f), f.reason))
            .join('\n');
      }
      final names = failed.map(nameOf).toList(growable: false);
      final named = _joinNames(names);
      if (cleanPlayed.isEmpty && attention.isEmpty) {
        return '$named did not receive the nudge.';
      }
      return '$named did not receive the nudge \u2014 everyone else did.';
    }

    final volumeWarnings = _mergedVolumeWarnings();
    if (volumeWarnings.isNotEmpty) return volumeWarnings.join('\n');

    if (expected.length <= 1 && results.length == 1) {
      final name =
          results.first.recipientName ??
          expected.values.firstOrNull?.displayName;
      if (name == null) return 'Everyone received the nudge \u2713';
      if (_lastSentNudgeKind == NudgeKind.push) {
        return 'Nudge received on ${name.trim().split(RegExp(r'\s+')).first}\u2019s device';
      }
      return 'Played on ${name.trim().split(RegExp(r'\s+')).first}\u2019s device';
    }
    return 'Everyone received the nudge \u2713';
  }

  List<String> _mergedVolumeWarnings() {
    final warnings = <String>[];
    final covered = <String>{};

    void addWarning(String userId, String displayName, MediaVolumeBand? band) {
      if (band == null || !band.isWarning) return;
      if (!covered.add(userId)) return;
      warnings.add(band.warningMessage(mediaVolumeFirstName(displayName))!);
    }

    for (final entry in _resultsByUserId.entries) {
      final result = entry.value;
      if (!result.played) {
        covered.add(entry.key);
        continue;
      }
      final pending = _expectedRecipients[entry.key];
      final name = result.recipientName ?? pending?.displayName ?? 'They';
      addWarning(
        entry.key,
        name,
        MediaVolumeBandX.fromAttention(result.attention),
      );
      covered.add(entry.key);
    }

    for (final entry in _expectedRecipients.entries) {
      if (covered.contains(entry.key)) continue;
      final band = _rtdbVolumeFeedback.bandsByUserId[entry.key];
      addWarning(entry.key, entry.value.displayName, band);
    }
    return warnings;
  }

  String _joinNames(List<String> names) {
    if (names.isEmpty) return 'Someone';
    if (names.length == 1) return names.first;
    if (names.length == 2) return '${names[0]} and ${names[1]}';
    return '${names.sublist(0, names.length - 1).join(', ')}, and ${names.last}';
  }

  String _shortFailureWithReason(String name, String? reason) {
    switch (NudgeDeliveryFailure.canonicalReason(reason)) {
      case 'playback_error':
      case 'download_failed':
        return 'Nudge did not reach $name \u2014 something went wrong on '
            'Duo\u2019s end.';
      default:
        return 'Nudge did not reach $name.';
    }
  }

  String _persistedFailureMessage(
    int failedCount,
    int totalRecipients,
    List<String> failedNames, {
    List<String?> reasons = const [],
  }) {
    if (failedCount == 1 && failedNames.isNotEmpty) {
      return _shortFailureWithReason(
        failedNames.first,
        reasons.isNotEmpty ? reasons.first : null,
      );
    }
    if (failedCount <= 2 &&
        failedNames.length == failedCount &&
        reasons.length == failedCount) {
      return [
        for (var i = 0; i < failedCount; i++)
          _shortFailureWithReason(failedNames[i], reasons[i]),
      ].join('\n');
    }
    if (failedCount >= totalRecipients) {
      return 'Nudge wasn\u2019t delivered to anyone in this group.';
    }
    if (failedNames.length == failedCount && failedNames.length <= 2) {
      return 'Last nudge to ${_joinNames(failedNames)} wasn\u2019t received.';
    }
    return 'Nudge wasn\u2019t delivered to $failedCount of $totalRecipients people.';
  }

  List<LastNudgeRecipientSignifier> _snapshotSignifiers() {
    // Read results directly — do NOT gate on [_showDeliveryBadges]. Finalize
    // snapshots signifiers before flipping that flag so reopen restores the
    // same per-recipient failure state.
    final signifiers = <LastNudgeRecipientSignifier>[];
    for (final pending in _expectedRecipients.values) {
      final result = _resultsByUserId[pending.userId];
      final failed = result?.played == false;
      signifiers.add(
        LastNudgeRecipientSignifier(
          userId: pending.userId,
          displayName: pending.displayName,
          failed: failed,
          failureReason: failed ? result?.reason : null,
          band: _snapshotBandFor(pending.userId),
          reply: _repliesByUserId[pending.userId],
        ),
      );
    }
    return signifiers;
  }

  MediaVolumeBand? _snapshotBandFor(String userId) {
    final result = _resultsByUserId[userId];
    if (result != null && !result.played) return null;
    if (_lastSentNudgeKind != NudgeKind.voice) return null;
    if (result != null && result.played) {
      return MediaVolumeBandX.fromAttention(result.attention) ??
          MediaVolumeBand.ok;
    }
    return _rtdbVolumeFeedback.bandsByUserId[userId];
  }
}
