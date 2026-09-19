import 'package:flutter_test/flutter_test.dart';

import 'package:one_one_app/one_one.dart';

void main() {
  testWidgets('privacy policy identifies collected information and providers', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: LegalDocumentScreen(document: LegalDocument.privacy),
      ),
    );

    expect(find.text('Privacy'), findsOneWidget);
    expect(find.text('2. Information we collect'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('5. Service providers'),
      300,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('5. Service providers'), findsOneWidget);
  });

  testWidgets('terms page presents service and user responsibilities', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: LegalDocumentScreen(document: LegalDocument.terms),
      ),
    );

    expect(find.text('Terms'), findsOneWidget);
    expect(find.text('2. The service'), findsOneWidget);
    expect(find.text('3. Your responsibilities'), findsOneWidget);
  });
}
