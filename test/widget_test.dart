// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:campus_guia/main.dart';

void main() {
  testWidgets('CampusGuía renders main entry points', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const CampusGuiaApp());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 900));

    expect(find.text('CampusGuía'), findsOneWidget);
    expect(find.text('Iniciar navegación'), findsOneWidget);
    expect(find.text('Ayuda'), findsOneWidget);
  });
}
