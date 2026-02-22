import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flash_sheets/main.dart';

void main() {
  testWidgets('Flash Sheets initial state renders', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 2200));
    await tester.pumpWidget(const FlashSheetsApp());

    expect(find.text('Flash Sheets'), findsOneWidget);
    expect(find.text('Load Your Sheet'), findsOneWidget);
  });
}
