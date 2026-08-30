part of 'nudge_screen.dart';

mixin _NudgeSheetBuild
    on _NudgeSheetStateBase, _NudgeSheetDelivery, _NudgeSheetSend {
  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ringCooldown = _cooldownRemaining(NudgeKind.ring);
    final pushCooldown = _cooldownRemaining(NudgeKind.push);
    final voiceCooldown = _cooldownRemaining(NudgeKind.voice);
    final actionEnabled = _canSend;
    final ringEnabled = actionEnabled && ringCooldown <= Duration.zero;
    final pushEnabled = actionEnabled && pushCooldown <= Duration.zero;
    final voiceBlockedByLiveMic = _liveMicBlocksVoice;
    final voiceEnabled =
        _canSend && voiceCooldown <= Duration.zero && !voiceBlockedByLiveMic;
    final recordingProgress = _voiceHoldActive
        ? (_elapsed.inMilliseconds /
                  VoiceNudgeAudio.maxRecordingDuration.inMilliseconds)
              .clamp(0.0, 1.0)
        : 0.0;
    final accent = widget.accent;

    // Errors, confirming, received/failed confirmation, and empty-group guards.
    final showStatus =
        _friends.isEmpty || _nudgeableFriends.isEmpty || _message != null;

    return PopScope(
      canPop: !_blockDismissWhileHolding,
      child: Material(
        color: const Color(0xff141414),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28.r)),
        clipBehavior: Clip.antiAlias,
        child: BottomSystemSafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 15),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.68,
              ),
              child: SingleChildScrollView(
                physics: _blockDismissWhileHolding
                    ? const NeverScrollableScrollPhysics()
                    : null,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── Drag handle ──
                    Center(
                      child: Padding(
                        padding: EdgeInsets.only(top: 8.h, bottom: 8.h),
                        child: Container(
                          width: 38.w,
                          height: 4.h,
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ),

                    // ── Header ──
                    Padding(
                      padding: EdgeInsets.fromLTRB(20.w, 0, 8.w, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Get their attention',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18.sp,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: _blockDismissWhileHolding
                                ? null
                                : () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close_rounded),
                            color: Colors.white38,
                            iconSize: 20.sp,
                            tooltip: 'Close',
                          ),
                        ],
                      ),
                    ),

                    SizedBox(height: 10.h),

                    // ── Recipient picker (selection is self-explanatory) ──
                    FadedHorizontalRow(
                      height: 92.h,
                      clipBehavior: Clip.none,
                      listPadding: EdgeInsets.symmetric(horizontal: 20.w),
                      children: [
                        // "Everyone" group chip — no delivery badge (not a user)
                        _NudgeRecipient(
                          label: 'Everyone',
                          selected: _isEveryoneSelected,
                          accent: accent,
                          enabled:
                              actionEnabled && _nudgeableFriends.isNotEmpty,
                          onTap: actionEnabled && _nudgeableFriends.isNotEmpty
                              ? _selectEveryone
                              : null,
                          avatar: Container(
                            color: accent.withValues(alpha: 0.18),
                            child: Icon(
                              Icons.group_rounded,
                              color: accent,
                              size: 22.sp,
                            ),
                          ),
                        ),
                        for (final friend in _friends) ...[
                          SizedBox(width: 12.w),
                          Builder(
                            builder: (context) {
                              final online = _isOnline(friend.userId);
                              final failed = _isDeliveryFailed(friend.userId);
                              final reply = _replyFor(friend.userId);
                              final volumeBand = _volumeBandFor(friend.userId);
                              final Widget? deliveryBadge = failed
                                  ? null
                                  : reply != null
                                  ? _ResponseBadgeIcon(reply: reply)
                                  : volumeBand != null
                                  ? _VolumeBadgeIcon(band: volumeBand)
                                  : null;
                              return _NudgeRecipient(
                                label: friend.displayName,
                                subtitle: online ? 'already online' : null,
                                selected:
                                    !online &&
                                    _selectedUserIds.contains(friend.userId),
                                accent: accent,
                                enabled: actionEnabled && !online,
                                dimmed: online,
                                onTap: actionEnabled && !online
                                    ? () => _toggleFriend(friend.userId)
                                    : null,
                                deliveryBadge: deliveryBadge,
                                avatar: Opacity(
                                  opacity: online ? 0.38 : 1,
                                  child: _buildFriendAvatar(
                                    friend: friend,
                                    failed: failed,
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ],
                    ),

                    SizedBox(height: 12.h),
                    _SheetDivider(),
                    SizedBox(height: 18.h),

                    // ── Primary action: hold-to-speak (centered lower sheet) ──
                    Center(
                      child: _buildVoiceMicButton(
                        accent: accent,
                        voiceEnabled: voiceEnabled,
                        recordingProgress: recordingProgress,
                        voiceCooldown: voiceCooldown,
                      ),
                    ),

                    SizedBox(height: 18.h),

                    // ── Secondary actions: ring + push ──
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24.w),
                      child: Text(
                        'More ways to get their attention',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14.sp,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                        ),
                      ),
                    ),
                    SizedBox(height: 12.h),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 48.w),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _RingActionButton(
                            enabled: ringEnabled,
                            cooldownLabel: ringCooldown > Duration.zero
                                ? _cooldownLabel(ringCooldown)
                                : null,
                            onRingCount: (count) => unawaited(
                              _sendRing(durationSeconds: count * 3),
                            ),
                          ),
                          _PushActionButton(
                            enabled: pushEnabled,
                            cooldownLabel: pushCooldown > Duration.zero
                                ? _cooldownLabel(pushCooldown)
                                : null,
                            onTap: _sendPush,
                          ),
                        ],
                      ),
                    ),

                    if (showStatus) ...[
                      SizedBox(height: 14.h),
                      Padding(
                        padding: EdgeInsets.fromLTRB(20.w, 0, 20.w, 0),
                        child: _NudgeStatus(
                          message: _friends.isEmpty
                              ? 'Invite a friend before sending a nudge.'
                              : _nudgeableFriends.isEmpty && _message == null
                              ? 'Everyone is already online \u2014 no nudge needed.'
                              : UserFacingCopy.sanitize(
                                  _message!,
                                  fallback: UserFacingCopy
                                      .notificationDeliveryFailure,
                                ),
                          isError:
                              _friends.isEmpty ||
                              (_messageIsError && _message != null),
                          isWarning: _messageIsWarning && _message != null,
                          isPending: _friends.isEmpty ? false : _messagePending,
                        ),
                      ),
                    ],

                    SizedBox(height: 18.h),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Builds a friend's avatar with an optional skull overlay when the nudge
  /// was not received.
  Widget _buildFriendAvatar({
    required GroupMemberSummary friend,
    required bool failed,
  }) {
    final baseAvatar = ProfileAvatar(
      key: ValueKey(friend.userId),
      profilePhotoUrl: friend.profilePhotoUrl,
      profilePhotoBase64: friend.profilePhotoBase64,
      avatarAsset: friend.avatarAsset,
      radius: 24.r,
      fallback: Text(
        friend.displayName.trim().isEmpty
            ? '?'
            : String.fromCharCode(
                friend.displayName.trim().runes.first,
              ).toUpperCase(),
        style: TextStyle(
          color: Colors.white,
          fontSize: 17.sp,
          fontWeight: FontWeight.w700,
        ),
      ),
    );

    if (!failed) return baseAvatar;

    // Grayscale + skull for "nudge not received" states.
    final overlay = Text(
      '\u{1F480}',
      textScaler: TextScaler.noScaling,
      style: TextStyle(fontSize: 18.sp),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        ColorFiltered(
          colorFilter: const ColorFilter.matrix([
            0.2126,
            0.7152,
            0.0722,
            0,
            0,
            0.2126,
            0.7152,
            0.0722,
            0,
            0,
            0.2126,
            0.7152,
            0.0722,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
          ]),
          child: baseAvatar,
        ),
        Center(child: overlay),
      ],
    );
  }

  /// Builds the primary voice mic button (press-and-hold; swipe up to cancel).
  Widget _buildVoiceMicButton({
    required Color accent,
    required bool voiceEnabled,
    required double recordingProgress,
    required Duration voiceCooldown,
  }) {
    final muteFirstLabel =
        _liveMicBlocksVoice && !_voiceHoldActive && !_sendingVoice;
    final showCancelHint = _pointerHeld || _voiceHoldActive;
    final cancelArmed = _swipeCancel.isArmed;
    final deleteColor = _swipeCancel.deleteColor;
    final cappedAwaitingRelease =
        _stoppingAtCap || _pendingVoicePath != null;
    final buttonColor = cancelArmed
        ? deleteColor
        : _voiceHoldActive
        ? accent
        : _sendingVoice
        ? accent.withValues(alpha: 0.18)
        : const Color(0xff202020);
    final ringColor = cancelArmed
        ? deleteColor
        : _voiceHoldActive || _sendingVoice
        ? accent
        : Colors.white.withValues(alpha: 0.09);
    final maxSecondsLabel =
        (VoiceNudgeAudio.maxRecordingDuration.inMilliseconds / 1000)
            .toStringAsFixed(1);
    final micButton = Semantics(
      button: true,
      enabled: voiceEnabled,
      label: _voiceHoldActive
          ? cancelArmed
                ? 'Release to delete recording'
                : cappedAwaitingRelease
                ? 'Recording complete, swipe up to cancel, release to send'
                : 'Recording voice nudge, swipe up to cancel, release to send'
          : _sendingVoice
          ? 'Sending voice nudge'
          : muteFirstLabel
          ? 'Mute your microphone first to record a voice nudge'
          : 'Voice nudge, press and hold to record, swipe up to cancel',
      child: Listener(
        onPointerDown: (event) {
          if (!voiceEnabled) {
            if (_liveMicBlocksVoice) {
              setState(() {
                _message = 'Mute your mic first to send a voice nudge.';
                _messageIsError = false;
                _messageIsWarning = true;
                _messagePending = false;
              });
            }
            return;
          }
          // Fixed default while holding to record (not Settings intensity).
          unawaited(HapticFeedback.lightImpact());
          // Lock back/close on the same frame as press — before async
          // mic start — so a second gesture cannot pop the sheet.
          _swipeCancel.begin(
            pointer: event.pointer,
            startDy: event.position.dy,
            onHoldEnded: _onVoiceHoldEnded,
          );
          setState(() {
            _pointerHeld = true;
            _sendAfterPointerEnd = true;
          });
          unawaited(_beginRecording());
        },
        child: Transform.translate(
          offset: _swipeCancel.buttonLiftOffset,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 104.r,
            height: 104.r,
            decoration: BoxDecoration(
              color: buttonColor,
              shape: BoxShape.circle,
              border: Border.all(color: ringColor),
              boxShadow: _voiceHoldActive || _sendingVoice || cancelArmed
                  ? [
                      BoxShadow(
                        color: (cancelArmed ? deleteColor : accent).withValues(
                          alpha: 0.35,
                        ),
                        blurRadius: 26.r,
                      ),
                    ]
                  : null,
            ),
            child: _sendingVoice
                ? _SendingVoicePulse(accent: accent)
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      Padding(
                        padding: EdgeInsets.all(6.r),
                        child: CircularProgressIndicator(
                          value: _voiceHoldActive ? recordingProgress : 0,
                          strokeWidth: 4.r,
                          color: Colors.white,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                      Icon(
                        muteFirstLabel
                            ? Icons.mic_off_rounded
                            : cancelArmed
                            ? Icons.delete_rounded
                            : _voiceHoldActive
                            ? Icons.mic_rounded
                            : Icons.mic_none_rounded,
                        size: 42.sp,
                        color: cancelArmed
                            ? Colors.white
                            : _voiceHoldActive
                            ? Colors.black
                            : voiceEnabled
                            ? Colors.white
                            : Colors.white24,
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Normal in-flow sibling (not an overlay) so it only ever pushes the
        // button down when it grows — it can never overlap the divider above.
        AnimatedSize(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          alignment: Alignment.bottomCenter,
          child: showCancelHint
              ? Padding(
                  padding: EdgeInsets.only(bottom: 10.h),
                  child: IgnorePointer(
                    child: VoiceRecordSwipeCancelHint(
                      progress: _swipeCancel.progress,
                      armed: cancelArmed,
                      color: deleteColor,
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity, height: 0),
        ),
        micButton,
        SizedBox(height: 8.h),
        Text(
          voiceCooldown > Duration.zero
              ? _cooldownLabel(voiceCooldown)
              : cancelArmed
              ? 'Release to delete'
              : cappedAwaitingRelease
              ? 'Release to send'
              : _recording
              ? '${(_elapsed.inMilliseconds / 1000).toStringAsFixed(1)} / ${maxSecondsLabel}s'
              : _sendingVoice
              ? 'Sending\u2026'
              : muteFirstLabel
              ? 'Mute first'
              : 'Hold to speak',
          style: TextStyle(
            color: cancelArmed
                ? deleteColor
                : _voiceHoldActive || _sendingVoice
                ? accent
                : voiceEnabled
                ? Colors.white70
                : Colors.white24,
            fontSize: 13.sp,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (showCancelHint && !cancelArmed) ...[
          SizedBox(height: 4.h),
          Text(
            'Swipe up to cancel',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 12.sp,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }
}
