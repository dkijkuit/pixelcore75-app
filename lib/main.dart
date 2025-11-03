// =============================
// lib/main.dart
// =============================

import 'dart:async';
import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BleConfigApp());
}

// ======= CONFIG =======
// Your custom service UUID (iOS/Android only)
const String kTargetServiceUuid = "975a3183-e5f1-448a-acab-2016d89c1fe7";

// Friendly characteristic UUIDs
const String kUuidHostname = "38487a5b-f731-4118-bf66-4ee253d5f664";
const String kUuidServerPort = "e67e6360-99f3-4c6b-8e60-2e9266100718";
const String kUuidWifiSsid = "7a034f21-a679-4d51-a284-e6b4b69ceea9";
const String kUuidWifiPassword = "3f007796-2fd1-42d2-b122-458f1f0b90bf";
const String kUuidBrightness = "a7423ece-dced-4fb2-ac67-ddf97323726b";
const String kUuidRestart = "81ed8290-f167-47b9-b183-2f248c543889";

const Map<String, String> kCharNames = {
  kUuidHostname: "Server hostname",
  kUuidServerPort: "Server port",
  kUuidWifiSsid: "Wifi SSID",
  kUuidWifiPassword: "Wifi password",
  kUuidBrightness: "Brightness",
  kUuidRestart: "Restart device",
};

class BleConfigApp extends StatelessWidget {
  const BleConfigApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Config',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const ScanPage(),
    );
  }
}

// =============================
// Scan page
// =============================
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  late final FlutterReactiveBle _ble;
  late final Uuid _serviceUuid;
  StreamSubscription<DiscoveredDevice>? _scanSub;
  final Map<String, DiscoveredDevice> _found = {};
  bool _scanning = false;
  String? _error;

  bool get _isSupportedPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  void initState() {
    super.initState();
    _serviceUuid = Uuid.parse(kTargetServiceUuid);
    if (!_isSupportedPlatform) {
      _error = 'BLE is only supported on iOS/Android physical devices.';
      return;
    }
    _ble = FlutterReactiveBle();
    _ensurePermissionsAndStart();
  }

  Future<void> _ensurePermissionsAndStart() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.bluetooth,
          Permission.locationWhenInUse,
        ].request();
      } else {
        await [Permission.bluetooth, Permission.locationWhenInUse].request();
      }
      await _startScan();
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _startScan() async {
    setState(() {
      _found.clear();
      _scanning = true;
      _error = null;
    });

    _scanSub?.cancel();
    if (!_isSupportedPlatform) return;

    _scanSub = _ble
        .scanForDevices(
          withServices: [_serviceUuid],
          scanMode: ScanMode.lowLatency,
        )
        .listen(
          (device) => setState(() => _found[device.id] = device),
          onError: (e) {
            setState(() {
              _error = e.toString();
              _scanning = false;
            });
          },
          onDone: () => setState(() => _scanning = false),
        );

    Future.delayed(const Duration(seconds: 15), () {
      if (mounted && _scanning) {
        _scanSub?.cancel();
        setState(() => _scanning = false);
      }
    });
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final devices = _found.values.sortedBy(
      (d) => d.name.isEmpty ? '\uFFFF' : d.name,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('BLE Devices')),
      body: RefreshIndicator(
        onRefresh: _startScan,
        child: ListView(
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Error: $_error',
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            if (_scanning) const LinearProgressIndicator(minHeight: 2),
            for (final d in devices)
              ListTile(
                leading: const Icon(Icons.bluetooth),
                title: Text(
                  d.name.isEmpty
                      ? 'Unnamed (${d.id.substring(0, 6)}…) '
                      : d.name,
                ),
                subtitle: Text('RSSI ${d.rssi}  •  ${d.id}'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        DeviceDetailsPage(device: d, serviceUuid: _serviceUuid),
                  ),
                ),
              ),
            if (!_scanning && devices.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('No devices found yet. Pull to rescan.'),
              ),
            const SizedBox(height: 24),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scanning ? null : _startScan,
        label: Text(_scanning ? 'Scanning…' : 'Rescan'),
        icon: const Icon(Icons.search),
      ),
    );
  }
}

// =============================
// Device details page
// =============================
class DeviceDetailsPage extends StatefulWidget {
  final DiscoveredDevice device;
  final Uuid serviceUuid;
  const DeviceDetailsPage({
    super.key,
    required this.device,
    required this.serviceUuid,
  });

  @override
  State<DeviceDetailsPage> createState() => _DeviceDetailsPageState();
}

class _DeviceDetailsPageState extends State<DeviceDetailsPage> {
  late final FlutterReactiveBle _ble;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  DiscoveredService? _targetService;
  String? _status;
  String? _error;

  final Map<QualifiedCharacteristic, TextEditingController> _controllers = {};
  final Map<QualifiedCharacteristic, List<int>> _originalValues = {};

  // For the bottom Restart button
  QualifiedCharacteristic? _restartChar;

  @override
  void initState() {
    super.initState();
    if (kIsWeb ||
        !(defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android)) {
      _error = 'BLE not supported on this platform (use iOS/Android device).';
      return;
    }
    _ble = FlutterReactiveBle();
    _connectAndLoad();
  }

  Future<void> _connectAndLoad() async {
    setState(() {
      _status = 'Connecting…';
      _error = null;
    });

    _connSub?.cancel();
    _connSub = _ble
        .connectToDevice(
          id: widget.device.id,
          connectionTimeout: const Duration(seconds: 10),
        )
        .listen((update) async {
          switch (update.connectionState) {
            case DeviceConnectionState.connected:
              setState(() => _status = 'Discovering services…');
              final services = await _ble.discoverServices(widget.device.id);

              _targetService = services.firstWhereOrNull(
                (s) => s.serviceId == widget.serviceUuid,
              );

              if (_targetService == null) {
                setState(() => _error = 'Target service not found on device.');
                return;
              }

              // Debug (optional): print characteristics of the matched service
              // for (final ch in _targetService!.characteristics) {
              //   debugPrint('Char: ${ch.characteristicId} '
              //       'read=${ch.isReadable} '
              //       'write=${ch.isWritableWithResponse || ch.isWritableWithoutResponse}');
              // }

              await _buildFields();
              setState(() => _status = '');
              break;

            case DeviceConnectionState.disconnecting:
            case DeviceConnectionState.disconnected:
              if (mounted) setState(() => _status = 'Disconnected');
              break;

            case DeviceConnectionState.connecting:
              setState(() => _status = 'Connecting…');
              break;
          }
        }, onError: (e) => setState(() => _error = e.toString()));
  }

  Future<void> _buildFields() async {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    _originalValues.clear();
    _restartChar = null;

    if (_targetService == null) return;

    for (final ch in _targetService!.characteristics) {
      final q = QualifiedCharacteristic(
        deviceId: widget.device.id,
        serviceId: widget.serviceUuid,
        characteristicId: ch.characteristicId,
      );

      final uuid = ch.characteristicId.toString().toLowerCase();

      // Capture restart characteristic for the bottom button
      if (uuid == kUuidRestart) {
        _restartChar = q;
      }

      // For non-restart fields, prep controllers (read if readable)
      if (uuid == kUuidRestart) continue;

      List<int> value = [];
      if (ch.isReadable) {
        try {
          value = await _ble.readCharacteristic(q);
        } catch (_) {}
      }

      String displayValue = "";
      if (uuid == kUuidBrightness && value.isNotEmpty) {
        // Brightness: ASCII decimal preferred; fallback to first byte
        try {
          final asText = utf8.decode(value, allowMalformed: true).trim();
          final parsed = int.tryParse(asText);
          displayValue = parsed != null
              ? parsed.toString()
              : value.first.toString();
        } catch (_) {
          displayValue = value.first.toString();
        }
      } else if (uuid == kUuidServerPort && value.isNotEmpty) {
        try {
          final asText = utf8.decode(value, allowMalformed: true).trim();
          final parsed = int.tryParse(asText);
          displayValue = (parsed != null) ? parsed.toString() : '';
        } catch (_) {
          displayValue = '';
        }
      } else if (value.isNotEmpty) {
        try {
          displayValue = utf8.decode(value, allowMalformed: true);
        } catch (_) {
          displayValue = '';
        }
      }

      final controller = TextEditingController(text: displayValue);
      _controllers[q] = controller;
      _originalValues[q] = value;
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _connSub?.cancel();
    super.dispose();
  }

  Future<void> _writeAll() async {
    if (_targetService == null) return;

    setState(() {
      _status = 'Writing…';
      _error = null;
    });

    try {
      for (final ch in _targetService!.characteristics) {
        final q = QualifiedCharacteristic(
          deviceId: widget.device.id,
          serviceId: widget.serviceUuid,
          characteristicId: ch.characteristicId,
        );
        final uuid = ch.characteristicId.toString().toLowerCase();

        if (uuid == kUuidRestart) {
          // Restart handled by its own button
          continue;
        }

        final controller = _controllers[q]!;
        List<int> newBytes;

        if (uuid == kUuidBrightness) {
          final min = 10;
          final max = 255;
          int v = int.tryParse(controller.text.trim()) ?? min;
          v = v.clamp(min, max);
          newBytes = utf8.encode(v.toString()); // ASCII
        } else if (uuid == kUuidServerPort) {
          int p = int.tryParse(controller.text.trim()) ?? 0;
          if (p < 1) p = 1;
          if (p > 65535) p = 65535;
          newBytes = utf8.encode(p.toString()); // ASCII
        } else {
          newBytes = utf8.encode(controller.text); // ASCII UTF-8
        }

        final orig = _originalValues[q] ?? const <int>[];
        final changed = !const ListEquality<int>().equals(newBytes, orig);

        if (changed &&
            (ch.isWritableWithResponse || ch.isWritableWithoutResponse)) {
          await _ble.writeCharacteristicWithResponse(q, value: newBytes);
          _originalValues[q] = newBytes;
        }
      }
      if (mounted) setState(() => _status = 'Write complete');
    } catch (e) {
      setState(() => _error = 'Write failed: $e');
    } finally {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _status = '');
      });
    }
  }

  Future<void> _restartDevice(QualifiedCharacteristic q) async {
    try {
      // Send ASCII "1" or single byte [1]; keep it consistent with firmware
      await _ble.writeCharacteristicWithResponse(q, value: [1]);
      if (mounted) setState(() => _status = 'Restart command sent');
    } catch (e) {
      setState(() => _error = 'Restart failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = _targetService;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.device.name.isEmpty ? widget.device.id : widget.device.name,
        ),
      ),
      body: service == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_status?.isNotEmpty == true) ...[
                      const CircularProgressIndicator(),
                      const SizedBox(height: 12),
                      Text(_status!),
                    ],
                    if (_error != null)
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                if (_status?.isNotEmpty == true)
                  LinearProgressIndicator(
                    minHeight: 2,
                    semanticsLabel: _status,
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      ..._buildCharacteristicWidgets(service),
                      const SizedBox(height: 80),
                    ],
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Restart button (full-width, same style as Write All)
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () async {
                              if (_restartChar == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Restart characteristic not found in this service.',
                                    ),
                                  ),
                                );
                                return;
                              }
                              await _restartDevice(_restartChar!);
                            },
                            icon: const Icon(Icons.restart_alt),
                            label: const Text('Restart Device'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Write All button
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _writeAll,
                            icon: const Icon(Icons.save),
                            label: const Text('Write All Modified Values'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  // Build UI for all characteristics (hostname+port side-by-side)
  List<Widget> _buildCharacteristicWidgets(DiscoveredService service) {
    final widgets = <Widget>[];

    // Index by UUID
    final byUuid = {
      for (final ch in service.characteristics)
        ch.characteristicId.toString().toLowerCase(): ch,
    };

    // Hostname + Port together
    final host = byUuid[kUuidHostname];
    final port = byUuid[kUuidServerPort];
    final rendered = <String>{};

    if (host != null && port != null) {
      widgets.add(_buildHostPortCard(host, port));
      rendered.add(host.characteristicId.toString().toLowerCase());
      rendered.add(port.characteristicId.toString().toLowerCase());
    }

    // Remaining characteristics
    for (final ch in service.characteristics) {
      final id = ch.characteristicId.toString().toLowerCase();
      if (rendered.contains(id)) continue;
      // Do not render Restart here (handled by bottom button)
      if (id == kUuidRestart) continue;
      widgets.add(_buildCharacteristicCard(ch));
    }

    return widgets;
  }

  Widget _buildHostPortCard(
    DiscoveredCharacteristic host,
    DiscoveredCharacteristic port,
  ) {
    final qHost = QualifiedCharacteristic(
      deviceId: widget.device.id,
      serviceId: widget.serviceUuid,
      characteristicId: host.characteristicId,
    );
    final qPort = QualifiedCharacteristic(
      deviceId: widget.device.id,
      serviceId: widget.serviceUuid,
      characteristicId: port.characteristicId,
    );

    final ctrlHost = _controllers[qHost]!;
    final ctrlPort = _controllers[qPort]!;

    final canWriteHost =
        host.isWritableWithResponse || host.isWritableWithoutResponse;
    final canWritePort =
        port.isWritableWithResponse || port.isWritableWithoutResponse;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Server', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: ctrlHost,
                    enabled: canWriteHost,
                    decoration: const InputDecoration(
                      labelText: 'Hostname',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: ctrlPort,
                    enabled: canWritePort,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCharacteristicCard(DiscoveredCharacteristic ch) {
    final q = QualifiedCharacteristic(
      deviceId: widget.device.id,
      serviceId: widget.serviceUuid,
      characteristicId: ch.characteristicId,
    );
    final uuid = ch.characteristicId.toString().toLowerCase();
    final name = kCharNames[uuid] ?? uuid;
    final ctrl = _controllers[q]!;
    final isWritable =
        ch.isWritableWithResponse || ch.isWritableWithoutResponse;

    // Brightness: slider + number (10–255), ASCII when writing
    if (uuid == kUuidBrightness) {
      final min = 10;
      final max = 255;
      int current = int.tryParse(ctrl.text) ?? min;
      current = current.clamp(min, max);
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: current.toDouble(),
                      min: min.toDouble(),
                      max: max.toDouble(),
                      divisions: (max - min),
                      label: current.toString(),
                      onChanged: isWritable
                          ? (v) {
                              ctrl.text = v.round().toString();
                              setState(() {});
                            }
                          : null,
                    ),
                  ),
                  SizedBox(
                    width: 76,
                    child: TextField(
                      controller: ctrl,
                      enabled: isWritable,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Value',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    // Text / Password fields
    final isPassword = uuid == kUuidWifiPassword;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              enabled: isWritable,
              obscureText: isPassword,
              decoration: InputDecoration(
                labelText: isPassword ? 'Enter password' : 'Value',
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
