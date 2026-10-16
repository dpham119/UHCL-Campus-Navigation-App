import 'package:flutter_test/flutter_test.dart';

import 'package:uhcl_campus_navigation/app/app.dart';

void main() {
  testWidgets('Campus Navigation App loads', (WidgetTester tester) async {
    await tester.pumpWidget(const CampusNavigationApp());

    expect(find.text('UHCL Campus Navigation'), findsOneWidget);
  });
}
