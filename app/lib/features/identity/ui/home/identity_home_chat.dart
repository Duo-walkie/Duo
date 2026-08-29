part of '../identity_home_screen.dart';

// 1. Live chat bubble window + unread pile clear.
// 2. Send message / emoji burst; drop expired bubbles.

mixin _IdentityHomeChat on _IdentityHomeBase {
  /// Live-syncs the last [ChatMessageRepository.visibleLimit] chat bubbles
  /// for a group. Uses push-key order (`limitToLast` without `orderByChild`)
  /// so the query doesn't depend on a deployed secondary index, then sorts
  /// by `createdAt` client-side. Caps client-side again so even a partial
  /// snapshot never shows more than the rolling window.
  @override
  void _listenToChatMessages(String groupId) {
    unawaited(_chatMessagesSubscription?.cancel());
    unawaited(_clearChatPile(groupId));
    _chatMessagesSubscription = _chatMessageRepository
        .groupMessagesRef(groupId)
        .limitToLast(ChatMessageRepository.visibleLimit)
        .onValue
        .listen(
          (event) {
            if (!mounted || _selectedGroup?.groupId != groupId) return;
            final value = event.snapshot.value;
            final messages = <GroupChatMessage>[];
            // Accept any Map shape Firebase returns (String/Object keys).
            if (value is Map) {
              for (final entry in value.entries) {
                final parsed = GroupChatMessage.tryParse(
                  entry.key.toString(),
                  entry.value,
                );
                if (parsed == null || parsed.isExpired) continue;
                messages.add(parsed);
              }
            }
            // Deterministic order: createdAt, then messageId (not arrival order).
            messages.sort((a, b) {
              final byTime = a.createdAt.compareTo(b.createdAt);
              return byTime != 0 ? byTime : a.messageId.compareTo(b.messageId);
            });
            final window = messages.length > ChatMessageRepository.visibleLimit
                ? messages.sublist(
                    messages.length - ChatMessageRepository.visibleLimit,
                  )
                : messages;
            setState(() => _chatMessages = window);
            unawaited(_clearChatPile(groupId));
          },
          onError: (Object error, StackTrace stackTrace) {
            // Don't leave the feed stuck empty after a transient deny/blip —
            // log and keep the last good list; next group reselect resubscribes.
            CrashlyticsService.recordError(
              error,
              stackTrace,
              reason: 'chat_messages_listen_failed groupId=$groupId',
            );
          },
        );
  }

  // ── B8: Emoji burst listener ──
  /// Listens for emoji bursts from remote participants and triggers the
  /// local burst animation.
  @override
  void _listenToEmojiBursts(String groupId) {
    unawaited(_emojiBurstSubscription?.cancel());
    _emojiBurstSubscription = _chatMessageRepository
        .watchEmojiBursts(groupId)
        .listen(
          (data) {
            if (!mounted || _selectedGroup?.groupId != groupId) return;
            final senderUserId = data['senderUserId']?.toString();
            if (senderUserId == null || senderUserId == _session.userId) {
              return;
            }
            final emoji = data['emoji']?.toString().trim() ?? '';
            if (emoji.isEmpty) return;
            final senderName =
                data['senderDisplayName']?.toString().trim() ?? 'friend';
            final burstId = data['burstId']?.toString();
            if (burstId == null) return;

            final id = 'remote-$burstId';
            if (!mounted) return;
            setState(() {
              _emojiBursts = [
                ..._emojiBursts.where((item) => item.id != id),
                EmojiBurst(id: id, emoji: emoji, senderName: senderName),
              ];
              if (_emojiBursts.length > 2) {
                _emojiBursts = _emojiBursts.sublist(_emojiBursts.length - 2);
              }
            });
          },
          onError: (Object error, StackTrace stackTrace) {
            unawaited(
              CrashlyticsService.recordError(
                error,
                stackTrace,
                reason: 'emoji_burst_listener_failed groupId=$groupId',
                feature: 'chat',
              ),
            );
            // Stream dies after a deny/disconnect — resubscribe if still here.
            if (!mounted || _selectedGroup?.groupId != groupId) return;
            Future<void>.delayed(const Duration(seconds: 2), () {
              if (!mounted || _selectedGroup?.groupId != groupId) return;
              _listenToEmojiBursts(groupId);
            });
          },
        );
  }

  @override
  Future<void> _clearOpenedChatPiles() async {
    final tappedGroupId = await _nudgeActionBridge.takePendingChatPileOpen();
    if (tappedGroupId != null && tappedGroupId.isNotEmpty) {
      unawaited(_clearChatPile(tappedGroupId, force: true));
    }
    final selected = _selectedGroup;
    if (selected != null && selected.groupId != tappedGroupId) {
      unawaited(_clearChatPile(selected.groupId));
    }
  }

  Future<void> _clearChatPile(String groupId, {bool force = false}) async {
    // Only the foreground app clears the pile. The RTDB listener keeps
    // firing in the background, and clearing there would cancel the pile
    // notification and reset the server unread count right after the FCM
    // service posts it — breaking the WhatsApp-style collapse.
    // Tapping the notification is an explicit read, so [force] skips the
    // lifecycle gate and zeros the count immediately.
    if (!force && _appLifecycle != AppLifecycleState.resumed) return;
    unawaited(
      _chatMessageRepository.clearUnreadPile(
        groupId: groupId,
        userId: _session.userId,
      ),
    );
    await _nudgeActionBridge.clearChatPile(groupId);
  }

  void _dismissExpiredChatMessage(String messageId) {
    if (!mounted) return;
    setState(() {
      _chatMessages = _chatMessages
          .where((message) => message.messageId != messageId)
          .toList(growable: false);
    });
  }

  String _chatDisplayNameForUser(String userId, String fallback) {
    if (userId == _session.userId) {
      return _session.user.displayName;
    }
    for (final member in _members) {
      if (member.userId == userId) {
        return member.displayName;
      }
    }
    return fallback;
  }

  Future<void> _sendChatMessage(String text) async {
    final group = _selectedGroup;
    if (group == null) return;
    if (_session.settings.hapticsEnabled) {
      unawaited(HapticFeedback.selectionClick());
    }
    try {
      await _chatMessageRepository.sendMessage(
        groupId: group.groupId,
        senderUserId: _session.userId,
        senderDisplayName: _session.user.displayName,
        text: text,
      );
    } catch (error) {
      if (!mounted) rethrow;
      setState(() => _message = 'Couldn’t send message. Try again.');
      rethrow;
    }
  }

  void _triggerEmojiBurst(String emoji) {
    final trimmed = emoji.trim();
    if (trimmed.isEmpty || !mounted) return;
    if (_session.settings.hapticsEnabled) {
      unawaited(HapticFeedback.selectionClick());
    }
    final id =
        '${_session.userId}-${DateTime.now().microsecondsSinceEpoch}-$trimmed';
    setState(() {
      _emojiBursts = [
        ..._emojiBursts.where((item) => item.id != id),
        EmojiBurst(
          id: id,
          emoji: trimmed,
          senderName: _session.user.displayName,
        ),
      ];
      // Cap concurrent streams so rapid taps don't flood the overlay.
      if (_emojiBursts.length > 2) {
        _emojiBursts = _emojiBursts.sublist(_emojiBursts.length - 2);
      }
    });

    // B8: Send emoji burst to remote participants via RTDB.
    final group = _selectedGroup;
    if (group != null && _isOnline) {
      unawaited(
        _chatMessageRepository.sendEmojiBurst(
          groupId: group.groupId,
          senderUserId: _session.userId,
          senderDisplayName: _session.user.displayName,
          emoji: trimmed,
        ),
      );
    }
  }

  void _onEmojiBurstFinished(String id) {
    if (!mounted) return;
    setState(() {
      _emojiBursts = _emojiBursts
          .where((burst) => burst.id != id)
          .toList(growable: false);
    });
  }
}
