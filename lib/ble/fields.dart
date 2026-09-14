import 'uuids.dart';

/// Minimum brightness the firmware accepts (it clamps to this range).
const int kBrightnessMin = 10;
/// Maximum brightness the firmware accepts (it clamps to this range).
const int kBrightnessMax = 255;

/// Maximum length per field, in characters.
///
/// These keep payloads sane before they are written over BLE; the firmware
/// stores each value as an ASCII/UTF-8 string (see its `onWrite` handlers).
int maxLengthFor(String uuid) => switch (uuid) {
      kUuidHostname => 253, // RFC 1035 max hostname length
      kUuidServerPort => 5, // '65535'
      kUuidWifiSsid => 32, // 802.11 SSID limit
      kUuidWifiPassword => 63, // WPA2 passphrase limit
      kUuidBrightness => 3, // '255'
      _ => 253,
    };

/// Returns an error message for [uuid] given the user's [input], or null when
/// the value is valid. Pure function so it can be unit-tested without BLE.
///
/// Convention: empty input is an error only for fields the firmware requires
/// to be non-empty (hostname, SSID, port, brightness). The WiFi password is
/// write-only and unreadable, so an empty password means "leave unchanged".
String? validateField(String uuid, String input) {
  final text = input.trim();
  switch (uuid) {
    case kUuidServerPort:
      if (text.isEmpty) return 'Enter a port.';
      final port = int.tryParse(text);
      if (port == null) return 'Port must be a number.';
      if (port < 1 || port > 65535) {
        return 'Port must be between 1 and 65535.';
      }
      return null;
    case kUuidBrightness:
      if (text.isEmpty) return 'Enter a brightness.';
      final value = int.tryParse(text);
      if (value == null) return 'Brightness must be a number.';
      if (value < kBrightnessMin || value > kBrightnessMax) {
        return 'Brightness must be between $kBrightnessMin and $kBrightnessMax.';
      }
      return null;
    case kUuidHostname:
      if (text.isEmpty) return 'Enter a hostname.';
      return null;
    case kUuidWifiSsid:
      if (text.isEmpty) return 'Enter a Wifi SSID.';
      return null;
    case kUuidWifiPassword:
      if (text.isNotEmpty && text.length < 8) {
        return 'WPA password must be at least 8 characters (leave empty to keep the current one).';
      }
      return null;
    default:
      return null;
  }
}
