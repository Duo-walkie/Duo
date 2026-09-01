import 'package:one_one_app/one_one.dart';

/// Mutable Remote Config defaults. Must stay growable — `setDefaults` is
/// invoked on every app resume and must never receive `const {}`.
Map<String, Object> serviceStatusRemoteDefaults() {
  return mutableMapOf(<String, Object>{
    'service_status': 'operational',
    'service_status_guidance': '',
    'service_status_updates_url': '',
    MarketRemoteConfig.onboardingVariantKey: '',
  });
}

enum ServiceStatus {
  operational,
  maintenance,
  countryRestricted,
  offline,
  slowNetwork,
  backendFailure;

  static ServiceStatus fromRemoteValue(String value) {
    return switch (value.trim().toLowerCase()) {
      'maintenance' => maintenance,
      'country_restricted' => countryRestricted,
      'slow_network' => slowNetwork,
      'backend_failure' => backendFailure,
      _ => operational,
    };
  }
}

class ServiceStatusGate extends StatefulWidget {
  const ServiceStatusGate({super.key, required this.child});

  final Widget child;

  @override
  State<ServiceStatusGate> createState() => _ServiceStatusGateState();
}

class _ServiceStatusGateState extends State<ServiceStatusGate>
    with WidgetsBindingObserver {
  final FirebaseRemoteConfig _remoteConfig = FirebaseRemoteConfig.instance;
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  ServiceStatus _remoteStatus = ServiceStatus.operational;
  List<ConnectivityResult> _connectivityResults = const [];
  bool _slowNetworkDismissed = false;
  ServiceStatus? _lastLoggedBlockedStatus;

  ServiceStatus get _status {
    if (_connectivityResults.contains(ConnectivityResult.none)) {
      return ServiceStatus.offline;
    }
    return _remoteStatus;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen((
      results,
    ) {
      if (!mounted) return;
      setState(() => _connectivityResults = results);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // While the gate is actively blocking the app, a resume should be able
    // to clear a status that has since recovered without waiting out the
    // background poll interval below.
    unawaited(_refresh(force: _status != ServiceStatus.operational));
  }

  /// Refreshes connectivity + the cached Remote Config `service_status`.
  ///
  /// [force] bypasses Remote Config's `minimumFetchInterval` throttle. This
  /// must be true for user-initiated retries (the "Try again" button) and
  /// for resume-while-blocked above - otherwise a status change made on the
  /// backend/console (e.g. ending maintenance) can be invisible to an
  /// already-open app for up to the full poll interval, which looks like a
  /// broken "reconnect" button even though nothing is actually wrong.
  Future<void> _refresh({bool force = false}) async {
    try {
      final results = await _connectivity.checkConnectivity();
      if (mounted) {
        setState(() => _connectivityResults = results);
      }
      // Copy before setDefaults — this runs on every AppLifecycle resume.
      // A `const {}` (or any unmodifiable map) thrown into the plugin can be
      // written in place and fatals the root zone as
      // "Cannot modify unmodifiable map".
      await _remoteConfig.setDefaults(serviceStatusRemoteDefaults());
      await _remoteConfig.setConfigSettings(
        RemoteConfigSettings(
          fetchTimeout: const Duration(seconds: 5),
          minimumFetchInterval: force
              ? Duration.zero
              : const Duration(minutes: 15),
        ),
      );
      try {
        await _remoteConfig.fetchAndActivate();
      } catch (_) {
        // Cached/default values keep the app usable when Remote Config fails.
      }
      if (!mounted) return;
      setState(() {
        _remoteStatus = ServiceStatus.fromRemoteValue(
          _remoteConfig.getString('service_status'),
        );
        _slowNetworkDismissed = false;
      });
    } catch (_) {
      // LiveKit and Firebase surface their own failures after this best effort.
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    if (status == ServiceStatus.operational ||
        (status == ServiceStatus.slowNetwork && _slowNetworkDismissed)) {
      _lastLoggedBlockedStatus = null;
      return widget.child;
    }

    if (_lastLoggedBlockedStatus != status) {
      _lastLoggedBlockedStatus = status;
      unawaited(AnalyticsService.logServiceStatusBlocked(status: status.name));
    }

    final screen = ServiceStatusScreen(
      status: status,
      guidance: _remoteConfig.getString('service_status_guidance'),
      updatesUrl: _remoteConfig.getString('service_status_updates_url'),
      onRetry: () => _refresh(force: true),
      onContinue: status == ServiceStatus.slowNetwork
          ? () => setState(() => _slowNetworkDismissed = true)
          : null,
    );
    if (status == ServiceStatus.slowNetwork) {
      return Stack(fit: StackFit.expand, children: [widget.child, screen]);
    }
    return screen;
  }
}

class ServiceStatusScreen extends StatelessWidget {
  const ServiceStatusScreen({
    super.key,
    required this.status,
    required this.guidance,
    required this.updatesUrl,
    required this.onRetry,
    this.onContinue,
  });

  final ServiceStatus status;
  final String guidance;
  final String updatesUrl;
  final Future<void> Function() onRetry;
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) {
    final content = _contentFor(status);
    final cleanGuidance = guidance.trim();
    final cleanUpdatesUrl = updatesUrl.trim();

    return Scaffold(
      backgroundColor: const Color(0xff101010),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Semantics(
              liveRegion: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(content.icon, color: const Color(0xffF8BE03), size: 64),
                  const SizedBox(height: 24),
                  Text(
                    content.title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    cleanGuidance.isEmpty ? content.message : cleanGuidance,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, height: 1.5),
                  ),
                  if (status == ServiceStatus.maintenance &&
                      cleanUpdatesUrl.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: cleanUpdatesUrl),
                        );
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Updates link copied')),
                        );
                      },
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text('Copy Reddit updates link'),
                    ),
                  ],
                  const SizedBox(height: 28),
                  if (onContinue != null)
                    FilledButton(
                      onPressed: onContinue,
                      child: const Text('Continue'),
                    )
                  else
                    OutlinedButton.icon(
                      onPressed: () => unawaited(onRetry()),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Try again'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

({String title, String message, IconData icon}) _contentFor(
  ServiceStatus status,
) {
  return switch (status) {
    ServiceStatus.maintenance => (
      title: 'Services are currently unavailable.',
      message: 'Please check our Reddit page for updates.',
      icon: Icons.construction_rounded,
    ),
    ServiceStatus.countryRestricted => (
      title: 'This service is currently unavailable in your country.',
      message:
          'Voice service availability depends on local service and regulatory support.',
      icon: Icons.public_off_rounded,
    ),
    ServiceStatus.offline => (
      title: 'No internet connection.',
      message: 'Reconnect to continue.',
      icon: Icons.wifi_off_rounded,
    ),
    ServiceStatus.slowNetwork => (
      title: 'Network quality is poor.',
      message: 'Voice quality may be affected.',
      icon: Icons.network_check_rounded,
    ),
    ServiceStatus.backendFailure => (
      title: "We're experiencing server issues.",
      message: 'Please try again shortly.',
      icon: Icons.cloud_off_rounded,
    ),
    ServiceStatus.operational => (
      title: '',
      message: '',
      icon: Icons.check_circle_rounded,
    ),
  };
}
