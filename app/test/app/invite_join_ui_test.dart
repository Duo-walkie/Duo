import 'package:flutter_test/flutter_test.dart';

import 'package:one_one_app/one_one.dart';

void main() {
  testWidgets('InviteJoinOverlay shows a pulsing Duo logo and no copy', (
    tester,
  ) async {
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(393, 873),
        minTextAdapt: true,
        builder: (context, child) {
          return MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(body: child),
          );
        },
        child: const InviteJoinOverlay(),
      ),
    );
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Joining your friends…'), findsNothing);
    await tester.pump(const Duration(milliseconds: 700));
  });

  testWidgets('invite join error snackbar shows the exact reason', (
    tester,
  ) async {
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(393, 873),
        minTextAdapt: true,
        builder: (context, child) {
          return MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  return TextButton(
                    onPressed: () => showInviteJoinErrorSnackBar(
                      context,
                      'Invite is expired or fully used.',
                    ),
                    child: const Text('fail'),
                  );
                },
              ),
            ),
          );
        },
      ),
    );

    await tester.tap(find.text('fail'));
    await tester.pump();

    expect(find.text('Couldn’t join invite'), findsOneWidget);
    expect(find.text('Invite is expired or fully used.'), findsOneWidget);
  });
}
