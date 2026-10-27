import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openoia/main.dart';

void main() {
  testWidgets('Openoia smoke test', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const VpnOpenoiaApp());
    expect(find.text('Openoia'), findsWidgets);
    expect(find.text('DataBase'), findsOneWidget);
    expect(find.text('SSH & SFTP'), findsOneWidget);
    expect(find.text('VPN'), findsOneWidget);
  });
}
