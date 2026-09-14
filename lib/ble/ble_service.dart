import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

/// Result of a permission request, with the UI-facing verdict baked in.
class BlePermissionResult {
  const BlePermissionResult(this.statuses);

  final Map<Permission, PermissionStatus> statuses;

  bool get granted =>
      statuses.values.every((s) => s == PermissionStatus.granted);

  /// True when the user must change the permission in OS settings; another
  /// in-app request dialog will never be shown again.
  bool get needsSettings => statuses.values
      .any((s) => s == PermissionStatus.permanentlyDenied || s.isRestricted);

  String get message {
    if (granted) return '';
    return needsSettings
        ? 'Bluetooth permission was denied. Enable it in Settings to scan for panels.'
        : 'Bluetooth permission is needed to scan for panels.';
  }
}

/// App-wide BLE access point.
///
/// Exposes the single [FlutterReactiveBle] instance for the whole app plus
/// the platform-aware permission flow and user-friendly error mapping, so
/// pages never talk to the plugin or raw exceptions directly.
class BleService {
  BleService._();

  static final BleService instance = BleService._();

  /// The single BLE instance for the whole app. Created lazily so that
  /// building the service on unsupported platforms (desktop, tests) never
  /// touches the BLE stack.
  late final FlutterReactiveBle ble = FlutterReactiveBle();

  /// The app is provisioned over BLE on physical phones only.
  bool get isSupportedPlatform =>
      !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  bool get isAndroid => !kIsWeb && Platform.isAndroid;

  /// Permissions needed for scanning/connecting on this platform.
  ///
  /// iOS deliberately requests only the Bluetooth permission: the app
  /// declares only NSBluetoothAlwaysUsageDescription in Info.plist, and
  /// requesting the undeclared location permission crashes on first BLE use.
  List<Permission> get requiredPermissions => isAndroid
      ? const [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.bluetooth,
          Permission.locationWhenInUse,
        ]
      : const [Permission.bluetooth];

  Future<BlePermissionResult> requestPermissions() async {
    final statuses = await requiredPermissions.request();
    return BlePermissionResult(statuses);
  }

  /// Maps low-level BLE errors to something a user can act on, instead of
  /// dumping raw exception strings into the UI.
  String friendlyError(Object error) {
    if (error is GenericFailure<ConnectionError>) {
      return 'Could not connect to the panel. '
          'Make sure it is powered and in range.';
    }
    if (error is GenericFailure) {
      final message = error.message.trim();
      return message.isEmpty ? 'The device rejected the operation.' : message;
    }
    if (error is MissingPluginException) {
      return 'Bluetooth is unavailable on this device.';
    }
    final text = error.toString();
    // Strip exception class noise like "Exception: ..." where possible.
    final colon = text.indexOf(':');
    final detail = (colon >= 0 && colon + 2 < text.length)
        ? text.substring(colon + 2)
        : text;
    return detail.isEmpty ? 'Unexpected Bluetooth error.' : detail;
  }
}
