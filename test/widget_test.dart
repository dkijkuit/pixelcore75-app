import 'package:flutter_test/flutter_test.dart';
import 'package:pixelcore_app/main.dart';

void main() {
  testWidgets('BleConfigApp renders the scan page', (tester) async {
    await tester.pumpWidget(const BleConfigApp());

    expect(find.text('PixelCore75 Setup'), findsOneWidget);
    // The test host is not a phone, so the page explains itself instead of
    // touching the BLE stack.
    expect(find.textContaining('BLE is only supported'), findsOneWidget);
  });
}
