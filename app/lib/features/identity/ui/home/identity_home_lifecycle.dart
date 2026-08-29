part of '../identity_home_screen.dart';

// 1. Device registration refresh on resume.
// 2. Identity session updates (settings / profile).
// 3. Connectivity watch → network-loss go-away.

mixin _IdentityHomeLifecycle on _IdentityHomeBase {
  /// One-shot STREAM_MUSIC self-report for every group this user is in.
  /// Android cannot expose another device's volume; this is the receiver
  /// half of the sender's post-send warning.
  @override
  Future<void> _reportMediaVolume() {
    return MediaVolumeStore.instance.reportForGroups(
      userId: _session.userId,
      groupIds: _groups.map((group) => group.groupId),
    );
  }

  Future<void> _refreshDeviceRegistration({bool force = false}) async {
    final lastRefresh = _lastRegistrationRefreshAt;
    if (_registrationRefreshInFlight ||
        (!force &&
            lastRefresh != null &&
            DateTime.now().difference(lastRefresh) <
                const Duration(seconds: 30))) {
      return;
    }
    _registrationRefreshInFlight = true;
    try {
      await widget.identityRepository.ensureIdentity();
      _lastRegistrationRefreshAt = DateTime.now();
    } catch (error, stack) {
      debugPrint(
        '[OneOneFCM][DART-E5] Resume-time device registration refresh failed: $error',
      );
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'device_registration_refresh_failed',
        ),
      );
    } finally {
      _registrationRefreshInFlight = false;
    }
  }

  void _onIdentitySessionChanged() {
    final next = widget.identityRepository.currentSession;
    if (!mounted || next == null || next.userId != _session.userId) return;
    // Defer two frames so Settings / edit-profile modal pop + deactivate can
    // settle first. Same-frame setState under a deactivating modal races the
    // framework as `_dependents.isEmpty`.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final latest = widget.identityRepository.currentSession;
        if (latest == null || latest.userId != _session.userId) return;
        setState(() => _session = latest);
        AccentThemeController.setAccentKey(latest.settings.accentColorKey);
      });
    });
  }

  Future<void> _startConnectivityMonitoring() async {
    final connectivity = Connectivity();
    try {
      final current = await connectivity.checkConnectivity();
      _handleConnectivityChanged(current);
    } catch (_) {
      // LiveKit connection quality remains the primary signal.
    }
    _connectivitySubscription = connectivity.onConnectivityChanged.listen((
      results,
    ) {
      _handleConnectivityChanged(results);
    });
  }

  void _handleConnectivityChanged(List<ConnectivityResult> results) {
    if (!mounted) return;
    setState(() => _connectivity = results);
    if (results.contains(ConnectivityResult.none) && _isOnline) {
      unawaited(
        _handleConnectionLoss('You were marked Away due to network loss.'),
      );
    }
  }
}
