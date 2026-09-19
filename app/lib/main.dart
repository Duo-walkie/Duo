import 'package:one_one_app/one_one.dart';

final RawReceivePort _isolateErrorPort = RawReceivePort((dynamic pair) {
  final errorAndStack = pair as List<dynamic>;
  final error = errorAndStack.first;
  final stack = errorAndStack.length > 1
      ? StackTrace.fromString(errorAndStack[1].toString())
      : StackTrace.empty;
  LogManager.log(LogLevel.fatal, 'Isolate', 'Uncaught isolate error: $error');
  _reportFatalToCrashlytics(
    () => CrashlyticsService.recordFatalError(
      error ?? 'unknown isolate error',
      stack,
      reason: 'isolate',
    ),
  );
});

/// Reports a fatal error to Crashlytics only if Firebase has actually
/// finished initializing. Errors that happen before that (extremely rare —
/// only possible in the sliver of time between [runApp] and Firebase
/// becoming ready) are still captured locally via [LogManager].
void _reportFatalToCrashlytics(Future<void> Function() report) {
  if (Firebase.apps.isEmpty) return;
  unawaited(report());
}

Future<void> main() async {
  // Do not pass `zoneValues:` here. Zone value maps are unmodifiable; any
  // later write (or a plugin that mutates the map it was given) becomes a
  // fatal `Cannot modify unmodifiable map` inside this zone. If zone values
  // are ever needed, pass `mutableMapOf(values)` — never `const {}`.
  await runZonedGuarded(
    () async {
      // Nothing below this line may `await` — every millisecond here is a
      // millisecond the user stares at a blank/frozen screen. All I/O
      // (Firebase, disk-backed logging, orientation lock, etc.) is deferred
      // until *after* runApp() so the first Flutter frame paints immediately.
      WidgetsFlutterBinding.ensureInitialized();

      // Use bundled Poppins under google_fonts/ — never fetch from gstatic.
      GoogleFonts.config.allowRuntimeFetching = false;

      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        LogManager.log(
          LogLevel.fatal,
          'FlutterError',
          'Uncaught Flutter error: ${details.exceptionAsString()}',
        );
        _reportFatalToCrashlytics(
          () => CrashlyticsService.recordFlutterFatalError(details),
        );
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        LogManager.log(
          LogLevel.fatal,
          'PlatformDispatcher',
          'Uncaught platform error: $error',
        );
        _reportFatalToCrashlytics(
          () => CrashlyticsService.recordFatalError(
            error,
            stack,
            reason: 'platform_dispatcher',
          ),
        );
        return true;
      };

      Isolate.current.addErrorListener(_isolateErrorPort.sendPort);

      WidgetsBinding.instance.addPostFrameCallback(
        (_) => logStartupMilestone('first Flutter frame'),
      );

      // Paint now. Everything else boots in the background afterwards.
      runApp(const OneOneApp());
      logStartupMilestone('runApp called');

      // ── Background bootstrap (all unawaited / non-blocking) ──────────────
      unawaited(LogManager.initialize());
      LogManager.log(LogLevel.info, 'AppLifecycle', 'Process starting');

      // Touch-load the WebRTC native library in the background now so the
      // jingle_peerconnection_so load does not sit on the first go-online path.
      unawaited(LiveKitConnectionWarmer.instance.ensureWebRtcInitialized());

      unawaited(
        SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
      );
      FlutterForegroundTask.initCommunicationPort();

      // _FirebaseGate (logo-less underlay under the native splash) awaits this
      // same future, so Firebase only ever initializes once and the first
      // frame never waits on it.
      final firebaseReady = FirebaseBootstrap.start();
      unawaited(
        firebaseReady.then((_) {
          // Firebase Auth/Crashlytics wiring needs Firebase; telemetry is
          // best-effort and never blocks the UI either way.
          unawaited(CrashlyticsService.initialize());
          unawaited(AnalyticsService.initialize());
          unawaited(PerformanceService.initialize());
        }),
      );
      // RevenueCat has no Firebase dependency — initializes fully in parallel
      // so subscription state is available by the time the user reaches any
      // gated feature.
      unawaited(RevenueCatService.initialize());
      unawaited(DuoLocalization.start());
    },
    (error, stack) {
      debugPrint('[Crashlytics] zone error: $error');
      LogManager.log(LogLevel.fatal, 'Zone', 'Uncaught zone error: $error');
      _reportFatalToCrashlytics(
        () => CrashlyticsService.recordFatalError(
          error,
          stack,
          reason: 'runZonedGuarded',
        ),
      );
    },
  );
}
