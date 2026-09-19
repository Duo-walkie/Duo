import 'package:one_one_app/one_one.dart';

/// Global navigator key used by the in-app live-session PiP overlay to pop
/// back to the home screen from any route without requiring a BuildContext.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Route observer shared by all screens that need to react to push/pop events
/// (e.g. the home screen showing/hiding the in-app live-session PiP overlay).
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();

const SystemUiOverlayStyle _systemOverlayStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarContrastEnforced: false,
  systemNavigationBarIconBrightness: Brightness.light,
  statusBarIconBrightness: Brightness.light,
);

class OneOneApp extends StatelessWidget {
  const OneOneApp({super.key});

  ThemeData _themeFor(Color seedColor) {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: Brightness.dark,
      ),
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xff101010),
      canvasColor: const Color(0xff101010),
      appBarTheme: const AppBarTheme(systemOverlayStyle: _systemOverlayStyle),
      fontFamily: GoogleFonts.poppins().fontFamily,
      textTheme: GoogleFonts.poppinsTextTheme(
        ThemeData(brightness: Brightness.dark).textTheme,
      ),
      primaryTextTheme: GoogleFonts.poppinsTextTheme(
        ThemeData(brightness: Brightness.dark).textTheme,
      ),
      useMaterial3: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    // MaterialApp must NOT live inside a ValueListenableBuilder that rebuilds
    // on accent changes — recreating MaterialApp tears down the navigator
    // element tree while screens are still mid setState/pop after save and
    // trips '_dependents.isEmpty'. Accent is applied via Theme in `builder`.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _systemOverlayStyle,
      child: MaterialApp(
        title: 'Duo',
        debugShowCheckedModeBanner: false,
        navigatorKey: appNavigatorKey,
        navigatorObservers: [AnalyticsService.observer, appRouteObserver],
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: LocaleController.locale.value,
        routes: {
          '/auth': (_) => const WithForegroundTask(
            child: _AuthSessionLifecycle(child: _FirebaseGate()),
          ),
        },
        theme: _themeFor(
          accentColorForKey(AccentThemeController.accentKey.value),
        ),
        builder: (context, child) {
          final media = withEnsuredBottomInset(MediaQuery.of(context));
          return ValueListenableBuilder<Locale>(
            valueListenable: LocaleController.locale,
            builder: (context, locale, _) {
              return Localizations.override(
                context: context,
                locale: locale,
                child: MediaQuery(
                  data: media,
                  child: ValueListenableBuilder<String>(
                    valueListenable: AccentThemeController.accentKey,
                    builder: (context, accentKey, _) {
                      return Theme(
                        data: _themeFor(accentColorForKey(accentKey)),
                        child: ScreenUtilInit(
                          designSize: const Size(393, 873),
                          minTextAdapt: true,
                          splitScreenMode: true,
                          // Stack the in-app live-session PiP overlay on top of
                          // all routes so it persists during in-app navigation.
                          child: Stack(
                            children: [
                              child!,
                              LiveSessionFloatingPip(
                                navigatorKey: appNavigatorKey,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              );
            },
          );
        },
        home: const WithForegroundTask(
          child: _AuthSessionLifecycle(child: _FirebaseGate()),
        ),
      ),
    );
  }
}

class _AuthSessionLifecycle extends StatefulWidget {
  const _AuthSessionLifecycle({required this.child});

  final Widget child;

  @override
  State<_AuthSessionLifecycle> createState() => _AuthSessionLifecycleState();
}

class _AuthSessionLifecycleState extends State<_AuthSessionLifecycle>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        LogManager.log(LogLevel.info, 'AppLifecycle', 'App foregrounded');
        unawaited(
          AnalyticsService.logSessionStarted().then(
            (_) {},
            onError: (Object error, StackTrace _) {
              debugPrint('[AppLifecycle] session_started failed: $error');
            },
          ),
        );
        unawaited(_refreshFirebaseToken());
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.hidden:
        break;
      case AppLifecycleState.paused:
        LogManager.log(LogLevel.info, 'AppLifecycle', 'App backgrounded');
      case AppLifecycleState.detached:
        LogManager.log(
          LogLevel.warn,
          'AppLifecycle',
          'App killed / detached (process teardown)',
        );
    }
  }

  Future<void> _refreshFirebaseToken() async {
    try {
      await FirebaseAuth.instance.currentUser?.getIdToken();
    } catch (_) {
      // Keep the mounted session intact; Firebase retries token refresh on use.
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _FirebaseGate extends StatefulWidget {
  const _FirebaseGate();

  @override
  State<_FirebaseGate> createState() => _FirebaseGateState();
}

class _FirebaseGateState extends State<_FirebaseGate> {
  late final Future<FirebaseApp> _firebaseInit = _initializeFirebase();

  Future<FirebaseApp> _initializeFirebase() async {
    final stopwatch = Stopwatch()..start();
    // main.dart kicks this off the instant runApp() returns, so by the time
    // this screen is on-screen the init is usually already in flight (or
    // done). Awaiting the shared future here — rather than calling
    // Firebase.initializeApp() again — guarantees Firebase only ever
    // initializes once.
    final app = await FirebaseBootstrap.start();
    logStartupMilestone('Firebase ready', stopwatch);
    await CrashlyticsService.log('firebase_gate_ready');
    return app;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FirebaseApp>(
      future: _firebaseInit,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          // Logo-less underlay matching the native splash. GoogleAuthScreen
          // constructs IdentityRepository, which touches FirebaseAuth and
          // must not run before init finishes.
          return const BrandSplashScreen();
        }

        if (snapshot.hasError) {
          return FirebaseSetupBlockedScreen(
            errorText: snapshot.error.toString(),
          );
        }

        return ServiceStatusGate(
          child: StreamBuilder<User?>(
            stream: FirebaseAuth.instance.userChanges(),
            initialData: FirebaseAuth.instance.currentUser,
            builder: (context, authSnapshot) {
              final user = authSnapshot.data;
              if (user == null ||
                  user.isAnonymous ||
                  !user.providerData.any(
                    (provider) => provider.providerId == 'google.com',
                  )) {
                return const GoogleAuthScreen();
              }

              return const StartupGateScreen();
            },
          ),
        );
      },
    );
  }
}
