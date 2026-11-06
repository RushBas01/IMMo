import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ayach/main.dart';

void main() {
  testWidgets('App builds', (WidgetTester tester) async {
    await tester.pumpWidget(const AyachImmoApp());
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
