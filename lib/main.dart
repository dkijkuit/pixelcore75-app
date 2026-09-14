import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:pixelcore_app/ble/ble_service.dart';
import 'package:pixelcore_app/ble/fields.dart';
import 'package:pixelcore_app/ble/uuids.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BleConfigApp());
}

class BleConfigApp extends StatelessWidget {
  const BleConfigApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PixelCore75',
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
  final BleService _bleService = BleService.instance;
  StreamSubscription<DiscoveredDevice>? _scanSub;
  Timer? _scanTimeout;
  final Map<String, DiscoveredDevice> _found = {};
  bool _scanning = false;
  String? _error;
  bool _needsSettings = false;

  @override
  void initState() {
    super.initState();
    if (!_bleService.isSupportedPlatform) {
      _error = 'BLE is only supported on iOS/Android physical devices.';
      return;
    }
    _ensurePermissionsAndStart();
  }

  Future<void> _ensurePermissionsAndStart() async {
    BlePermissionResult result;
    try {
      result = await _bleService.requestPermissions();
    } catch (e) {
      if (mounted) {
        setState(() => _error = _bleService.friendlyError(e));
      }
      return;
    }
    if (!mounted) return;
    if (!result.granted) {
      setState(() {
        _scanning = false;
        _needsSettings = result.needsSettings;
        _error = result.message;
      });
      return;
    }
    await _startScan();
  }

  Future<void> _startScan() async {
    setState(() {
      _found.clear();
      _scanning = true;
      _error = null;
      _needsSettings = false;
    });

    unawaited(_scanSub?.cancel());
    _scanTimeout?.cancel();
    if (!_bleService.isSupportedPlatform) return;

    _scanSub = _bleService.ble
        .scanForDevices(
          withServices: [Uuid.parse(kTargetServiceUuid)],
          scanMode: ScanMode.lowLatency,
        )
        .listen(
          (device) => setState(() => _found[device.id] = device),
          onError: (Object e) {
            setState(() {
              _error = _bleService.friendlyError(e);
              _scanning = false;
            });
          },
          onDone: () {
            if (mounted) setState(() => _scanning = false);
          },
        );

    _scanTimeout = Timer(const Duration(seconds: 15), () {
      if (mounted && _scanning) {
        unawaited(_scanSub?.cancel());
        setState(() => _scanning = false);
      }
    });
  }

  @override
  void dispose() {
    _scanTimeout?.cancel();
    unawaited(_scanSub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final devices = _found.values.sortedBy(
      (d) => d.name.isEmpty ? '\uFFFF' : d.name,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('PixelCore75 Setup')),
      body: RefreshIndicator(
        onRefresh: _startScan,
        child: ListView(
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                    if (_needsSettings)
                      TextButton.icon(
                        onPressed: openAppSettings,
                        icon: const Icon(Icons.settings),
                        label: const Text('Open Settings'),
                      ),
                  ],
                ),
              ),
            if (_scanning) const LinearProgressIndicator(minHeight: 2),
            for (final d in devices)
              ListTile(
                leading: const Icon(Icons.bluetooth),
                title: Text(
                  d.name.isEmpty
                      ? 'Unnamed (${d.id.substring(0, d.id.length < 6 ? d.id.length : 6)}…)'
                      : d.name,
                ),
                subtitle: Text('RSSI ${d.rssi}  •  ${d.id}'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => DeviceDetailsPage(
                      device: d,
                      serviceUuid: Uuid.parse(kTargetServiceUuid),
                    ),
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
  final BleService _bleService = BleService.instance;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  Service? _targetService;
  String? _status;
  String? _error;

  /// Max bytes per write, derived from the negotiated MTU (ATT MTU minus
  /// 3 bytes of header). Falls back to the conservative 20-byte default.
  int _maxWriteLen = 20;

  final Map<QualifiedCharacteristic, TextEditingController> _controllers = {};
  final Map<QualifiedCharacteristic, List<int>> _originalValues = {};

  /// Per-field user-visible problems (read failures, validation errors,
  /// failed writes), shown as the field's errorText.
  final Map<QualifiedCharacteristic, String> _fieldErrors = {};

  /// Fields whose current value could not be read (e.g. write-only
  /// characteristics). An untouched unread field is never written back.
  final Set<QualifiedCharacteristic> _unreadable = {};

  // For the bottom Restart button
  QualifiedCharacteristic? _restartChar;
  Timer? _statusReset;

  @override
  void initState() {
    super.initState();
    if (!_bleService.isSupportedPlatform) {
      _error = 'BLE not supported on this platform (use iOS/Android device).';
      return;
    }
    _connectAndLoad();
  }

  Future<void> _connectAndLoad() async {
    setState(() {
      _status = 'Connecting…';
      _error = null;
    });

    unawaited(_connSub?.cancel());
    _connSub = _bleService.ble
        .connectToDevice(
          id: widget.device.id,
          connectionTimeout: const Duration(seconds: 10),
        )
        .listen((update) async {
          switch (update.connectionState) {
            case DeviceConnectionState.connected:
              if (!mounted) return;
              setState(() => _status = 'Discovering services…');
              final List<Service> services;
              try {
                await _bleService.ble.discoverAllServices(widget.device.id);
                services = await _bleService.ble
                    .getDiscoveredServices(widget.device.id);
              } catch (e) {
                if (mounted) {
                  setState(() {
                    _status = '';
                    _error = _bleService.friendlyError(e);
                  });
                }
                return;
              }
              if (!mounted) return;

              _targetService = services.firstWhereOrNull(
                (s) => s.id == widget.serviceUuid,
              );

              if (_targetService == null) {
                setState(() {
                  _status = '';
                  _error = 'Target service not found on device.';
                });
                return;
              }

              await _negotiateMtu();
              await _buildFields();
              if (!mounted) return;
              setState(() => _status = '');
              break;

            case DeviceConnectionState.disconnecting:
            case DeviceConnectionState.disconnected:
              if (!mounted) return;
              setState(() {
                _status = 'Disconnected';
                if (update.failure != null) {
                  _error = _bleService.friendlyError(update.failure!);
                }
              });
              break;

            case DeviceConnectionState.connecting:
              if (!mounted) return;
              setState(() => _status = 'Connecting…');
              break;
          }
        }, onError: (Object e) {
          if (mounted) setState(() => _error = _bleService.friendlyError(e));
        });
  }

  /// Ask Android for a large MTU so multi-byte values (long passwords,
  /// hostnames) fit in a single write. iOS negotiates its own (larger) MTU.
  Future<void> _negotiateMtu() async {
    if (!_bleService.isAndroid) return;
    try {
      final mtu = await _bleService.ble
          .requestMtu(deviceId: widget.device.id, mtu: 517);
      _maxWriteLen = mtu > 3 ? mtu - 3 : 20;
    } catch (_) {
      _maxWriteLen = 20;
    }
  }

  Future<void> _buildFields() async {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    _originalValues.clear();
    _fieldErrors.clear();
    _unreadable.clear();
    _restartChar = null;

    final service = _targetService;
    if (service == null) return;

    for (final ch in service.characteristics) {
      if (!mounted) return;

      final q = QualifiedCharacteristic(
        deviceId: widget.device.id,
        serviceId: widget.serviceUuid,
        characteristicId: ch.id,
      );
      final uuid = normalizeUuid(ch.id.toString());

      // Capture restart characteristic for the bottom button
      if (uuid == kUuidRestart) {
        _restartChar = q;
        continue;
      }

      List<int> value = [];
      if (ch.isReadable) {
        try {
          value = await _bleService.ble.readCharacteristic(q);
        } catch (_) {
          if (!mounted) return;
          _unreadable.add(q);
          _fieldErrors[q] = 'Could not read current value.';
        }
      } else {
        _unreadable.add(q);
      }

      String displayValue = '';
      if (value.isNotEmpty) {
        try {
          final asText = utf8.decode(value, allowMalformed: true).trim();
          if (uuid == kUuidBrightness || uuid == kUuidServerPort) {
            // Brightness/port are stored as ASCII decimal on the firmware.
            final parsed = int.tryParse(asText);
            displayValue = parsed != null ? parsed.toString() : '';
          } else {
            displayValue = asText;
          }
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
    _statusReset?.cancel();
    for (final c in _controllers.values) {
      c.dispose();
    }
    unawaited(_connSub?.cancel());
    super.dispose();
  }

  /// Builds the bytes to write for a characteristic, or returns null when
  /// the field should be skipped (restart, unchanged values).
  List<int>? _encodeValue(String uuid, String text) {
    if (uuid == kUuidBrightness || uuid == kUuidServerPort) {
      return utf8.encode(text.trim());
    }
    return utf8.encode(text);
  }

  Future<void> _writeAll() async {
    final service = _targetService;
    if (service == null) return;

    _statusReset?.cancel();
    setState(() {
      _status = 'Saving…';
      _error = null;
      _fieldErrors.removeWhere((q, _) => !_unreadable.contains(q));
    });

    // Validate everything first and abort before touching the device, so a
    // rejected field can never leave the panel half-provisioned.
    final problems = <QualifiedCharacteristic, String>{};
    for (final ch in service.characteristics) {
      final q = QualifiedCharacteristic(
        deviceId: widget.device.id,
        serviceId: widget.serviceUuid,
        characteristicId: ch.id,
      );
      final uuid = normalizeUuid(ch.id.toString());
      if (uuid == kUuidRestart) continue;
      final controller = _controllers[q];
      if (controller == null) continue;

      final text = controller.text;
      if (text.isEmpty && _unreadable.contains(q)) {
        // Could not read and user typed nothing: leave the stored value.
        continue;
      }
      final problem = validateField(uuid, text);
      if (problem != null) problems[q] = problem;
    }

    if (problems.isNotEmpty) {
      if (!mounted) return;
      setState(() {
        _fieldErrors.addAll(problems);
        _status = '';
        _error = 'Fix the highlighted fields, then save again.';
      });
      return;
    }

    var attempted = 0;
    var written = 0;
    var failed = 0;

    try {
      for (final ch in service.characteristics) {
        final q = QualifiedCharacteristic(
          deviceId: widget.device.id,
          serviceId: widget.serviceUuid,
          characteristicId: ch.id,
        );
        final uuid = normalizeUuid(ch.id.toString());

        if (uuid == kUuidRestart) continue; // handled by its own button

        final controller = _controllers[q];
        if (controller == null) continue;

        // An untouched field we could not read must never be written back.
        if (controller.text.isEmpty && _unreadable.contains(q)) {
          continue;
        }

        final newBytes = _encodeValue(uuid, controller.text)!;
        final orig = _originalValues[q] ?? const <int>[];
        final changed = !const ListEquality<int>().equals(newBytes, orig);
        if (!changed) continue;
        if (!(ch.isWritableWithResponse || ch.isWritableWithoutResponse)) {
          continue;
        }

        attempted++;
        if (newBytes.length > _maxWriteLen) {
          failed++;
          setState(() {
            _fieldErrors[q] =
                'Value is ${newBytes.length} bytes but the device accepts '
                '$_maxWriteLen per write. Shorten it.';
          });
          continue;
        }

        try {
          await _bleService.ble.writeCharacteristicWithResponse(
            q,
            value: newBytes,
          );
          _originalValues[q] = newBytes;
          written++;
          if (mounted) {
            setState(() => _fieldErrors.remove(q));
          }
        } catch (e) {
          failed++;
          if (mounted) {
            setState(() {
              _fieldErrors[q] = 'Write failed: ${_bleService.friendlyError(e)}';
            });
          }
        }
      }

      if (!mounted) return;
      setState(() {
        if (failed > 0) {
          _error =
              'Saved $written of $attempted changed values. '
              'See the highlighted fields.';
        } else if (attempted == 0) {
          _status = 'Nothing to save';
        } else {
          _status = 'Write complete';
        }
      });
    } finally {
      _statusReset = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _status = '');
      });
    }
  }

  Future<void> _restartDevice(QualifiedCharacteristic q) async {
    try {
      // Firmware writes a single 0x01 to trigger a restart.
      await _bleService.ble.writeCharacteristicWithResponse(q, value: [1]);
      if (mounted) setState(() => _status = 'Restart command sent');
    } catch (e) {
      if (mounted) setState(() => _error = _bleService.friendlyError(e));
    }
    _statusReset?.cancel();
    _statusReset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _status = '');
    });
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
  List<Widget> _buildCharacteristicWidgets(Service service) {
    final widgets = <Widget>[];

    // Index by UUID
    final byUuid = {
      for (final ch in service.characteristics) normalizeUuid(ch.id.toString()): ch,
    };

    // Hostname + Port together
    final host = byUuid[kUuidHostname];
    final port = byUuid[kUuidServerPort];
    final rendered = <String>{};

    if (host != null && port != null) {
      widgets.add(_buildHostPortCard(host, port));
      rendered.add(normalizeUuid(host.id.toString()));
      rendered.add(normalizeUuid(port.id.toString()));
    }

    // Remaining characteristics
    for (final ch in service.characteristics) {
      final id = normalizeUuid(ch.id.toString());
      if (rendered.contains(id)) continue;
      // Do not render Restart here (handled by bottom button)
      if (id == kUuidRestart) continue;
      widgets.add(_buildCharacteristicCard(ch));
    }

    return widgets;
  }

  InputDecoration _fieldDecoration(String label, QualifiedCharacteristic q) {
    return InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      errorText: _fieldErrors[q],
      counterText: '',
    );
  }

  Widget _buildHostPortCard(
    Characteristic host,
    Characteristic port,
  ) {
    final qHost = QualifiedCharacteristic(
      deviceId: widget.device.id,
      serviceId: widget.serviceUuid,
      characteristicId: host.id,
    );
    final qPort = QualifiedCharacteristic(
      deviceId: widget.device.id,
      serviceId: widget.serviceUuid,
      characteristicId: port.id,
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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: ctrlHost,
                    enabled: canWriteHost,
                    maxLength: maxLengthFor(kUuidHostname),
                    decoration: _fieldDecoration('Hostname', qHost),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: ctrlPort,
                    enabled: canWritePort,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    maxLength: maxLengthFor(kUuidServerPort),
                    decoration: _fieldDecoration('Port', qPort),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCharacteristicCard(Characteristic ch) {
    final q = QualifiedCharacteristic(
      deviceId: widget.device.id,
      serviceId: widget.serviceUuid,
      characteristicId: ch.id,
    );
    final uuid = normalizeUuid(ch.id.toString());
    final name = kCharNames[uuid] ?? uuid;
    final ctrl = _controllers[q]!;
    final isWritable =
        ch.isWritableWithResponse || ch.isWritableWithoutResponse;

    // Brightness: slider + number (10–255), ASCII when writing
    if (uuid == kUuidBrightness) {
      final min = kBrightnessMin;
      final max = kBrightnessMax;
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
                              setState(() => _fieldErrors.remove(q));
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
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      maxLength: maxLengthFor(kUuidBrightness),
                      decoration: _fieldDecoration('Value', q),
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
              maxLength: maxLengthFor(uuid),
              decoration: _fieldDecoration(
                isPassword ? 'Enter password (empty = keep current)' : 'Value',
                q,
              ),
              onChanged: (_) => setState(() => _fieldErrors.remove(q)),
            ),
          ],
        ),
      ),
    );
  }
}
