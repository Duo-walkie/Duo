part of '../identity_home_screen.dart';

// 1. In-app floating PiP when live but not on the active group home.
// 2. Native PiP actions (mic toggle) and session-state sync.

mixin _IdentityHomePip on _IdentityHomeBase {
  // ── In-app PiP overlay helpers ───────────────────────────────────────────

  /// Keep the floating live-session control available when live but not already
  /// on the active group's home screen (PiP is for returning from other routes).
  @override
  void _showPipOverlayIfLive() {
    if (!_isOnline) return;
    if (_isViewingActiveGroup && !_routeCovered) {
      _hidePipOverlay();
      return;
    }
    LiveSessionOverlayController.instance.setSession(
      LiveSessionOverlayData(
        member: _localLiveMember,
        groupName: _activeLiveGroupName,
        microphoneMuted: !_microphoneEnabled,
        onToggleMicrophone: _toggleMicrophone,
        accentColor: accentColorForKey(_session.settings.accentColorKey),
      ),
    );
  }

  /// Refresh the PiP data (speaker / mute state) while the overlay is live.
  @override
  void _updatePipOverlay() {
    if (LiveSessionOverlayController.instance.state.value == null) return;
    LiveSessionOverlayController.instance.updateSession(
      LiveSessionOverlayData(
        member: _localLiveMember,
        groupName: _activeLiveGroupName,
        microphoneMuted: !_microphoneEnabled,
        onToggleMicrophone: _toggleMicrophone,
        accentColor: accentColorForKey(_session.settings.accentColorKey),
      ),
    );
  }

  /// Clear the in-app PiP only when the LiveKit session ends.
  void _hidePipOverlay() {
    LiveSessionOverlayController.instance.clearSession();
  }

  void _onPipModeChanged() {
    if (!mounted) return;
    setState(() {
      _inPictureInPicture = _voicePipBridge.isInPictureInPicture.value;
    });
  }

  Future<void> _handlePipAction(VoicePipAction action) async {
    if (_onlineSession == null) return;
    switch (action) {
      case VoicePipAction.toggleMicrophone:
        await _toggleConnectionMode();
        return;
    }
  }

  @override
  void _syncPipSessionState() {
    final session = _onlineSession;
    LogManager.log(
      LogLevel.info,
      'PresenceRing',
      'syncPipSessionState active=${session != null} '
          'sessionSuffix=${session == null ? "none" : session.serviceSessionId.substring(session.serviceSessionId.length - 6)} '
          'state=$_state',
      userId: _session.userId,
      groupId: session?.groupId ?? _selectedGroup?.groupId,
    );
    unawaited(
      _voicePipBridge.setSessionState(
        active: _onlineSession != null,
        isTalking: _isTransmitting,
        session: _onlineSession,
      ),
    );
    // Keep the in-app floating PiP in sync with the same state changes that
    // drive the OS-level PiP — going away clears it, going live updates it.
    if (_onlineSession == null) {
      _hidePipOverlay();
    } else {
      _showPipOverlayIfLive();
    }
  }
}
