import 'package:flutter_test/flutter_test.dart';
import 'package:pixelcore_app/ble/fields.dart';
import 'package:pixelcore_app/ble/uuids.dart';

void main() {
  group('validateField port', () {
    test('accepts valid ports', () {
      expect(validateField(kUuidServerPort, '1'), isNull);
      expect(validateField(kUuidServerPort, '8080'), isNull);
      expect(validateField(kUuidServerPort, ' 65535 '), isNull);
    });

    test('rejects malformed and out-of-range ports', () {
      expect(validateField(kUuidServerPort, ''), isNotNull);
      expect(validateField(kUuidServerPort, 'abc'), isNotNull);
      expect(validateField(kUuidServerPort, '0'), isNotNull);
      expect(validateField(kUuidServerPort, '65536'), isNotNull);
    });
  });

  group('validateField brightness', () {
    test('accepts the firmware-clamped range', () {
      expect(validateField(kUuidBrightness, '$kBrightnessMin'), isNull);
      expect(validateField(kUuidBrightness, '$kBrightnessMax'), isNull);
    });

    test('rejects values outside the firmware range', () {
      expect(validateField(kUuidBrightness, '0'), isNotNull);
      expect(validateField(kUuidBrightness, '${kBrightnessMin - 1}'),
          isNotNull);
      expect(validateField(kUuidBrightness, '${kBrightnessMax + 1}'),
          isNotNull);
      expect(validateField(kUuidBrightness, 'abc'), isNotNull);
      expect(validateField(kUuidBrightness, ''), isNotNull);
    });
  });

  group('validateField text fields', () {
    test('hostname and SSID are required', () {
      expect(validateField(kUuidHostname, ''), isNotNull);
      expect(validateField(kUuidHostname, 'panel.local'), isNull);
      expect(validateField(kUuidWifiSsid, ''), isNotNull);
      expect(validateField(kUuidWifiSsid, 'home-net'), isNull);
    });

    test('password is optional but must be WPA-length when present', () {
      // Empty means "keep the current password".
      expect(validateField(kUuidWifiPassword, ''), isNull);
      expect(validateField(kUuidWifiPassword, 'short'), isNotNull);
      expect(validateField(kUuidWifiPassword, 'long-enough-pass'), isNull);
    });

    test('unknown characteristics always validate', () {
      expect(validateField('not-a-known-uuid', 'anything'), isNull);
    });
  });

  test('maxLengthFor matches protocol limits', () {
    expect(maxLengthFor(kUuidServerPort), 5);
    expect(maxLengthFor(kUuidBrightness), 3);
    expect(maxLengthFor(kUuidWifiSsid), 32);
    expect(maxLengthFor(kUuidWifiPassword), 63);
    expect(maxLengthFor(kUuidHostname), 253);
  });

  test('normalizeUuid lowercases for comparison', () {
    expect(
      normalizeUuid('38487A5B-F731-4118-BF66-4EE253D5F664'),
      kUuidHostname,
    );
  });
}
