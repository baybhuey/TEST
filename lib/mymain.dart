// lib/main.dart
import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const BleApp());

class BleApp extends StatelessWidget {
  const BleApp({super.key});

  @override
  Widget build(BuildContext context) {
    final seed = Colors.teal;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      useInheritedMediaQuery: true,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: seed,
        brightness: Brightness.light,
        cardTheme: const CardThemeData(
          margin: EdgeInsets.all(12),
          elevation: 0,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: seed,
        brightness: Brightness.dark,
        cardTheme: const CardThemeData(
          margin: EdgeInsets.all(12),
          elevation: 0,
        ),
      ),
      home: const BleRemote(),
    );
  }
}

class BleRemote extends StatefulWidget {
  const BleRemote({super.key});
  @override
  State<BleRemote> createState() => _BleRemoteState();
}

class _BleRemoteState extends State<BleRemote> {
  // ⬇⬇⬇  SET YOUR UUIDs  ⬇⬇⬇
  static final Uuid serviceUuid =
      Uuid.parse("12345678-1234-1234-1234-1234567890ab"); // Service UUID
  static final Uuid rxCharUuid =
      Uuid.parse("87654321-4321-4321-4321-ba0987654321"); // WRITE characteristic UUID

  // UI shows 1..101; ESP32 expects 0..100 (we send -1)
  static const int kMaxMode = 101;

  final _ble = FlutterReactiveBle();

  // Text controllers
  //final _nameFilterCtrl = TextEditingController();
  final _modeInputCtrl = TextEditingController();
  final _msgCtrl = TextEditingController(); // <-- NEW: for scroller text

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;

  String? _deviceId;
  bool _connected = false;
  String _status = "Not connected";

  // UI values
  double _brightnessPct = 50.0; // 0..100% (mapped to 0..255 when sending)
  double _smoothing = 100.0;    // default 100%
  double _peakDelay = 10;     // 1..50
  int _mode = 55;             // one-based for UI (1..101)

  bool _autoCycle = false;    // Auto Cycle toggle

  @override
  void initState() {
    super.initState();
    _modeInputCtrl.text = _mode.toString();
  }

  Future<bool> _ensureBlePermissions() async {
    if (!Platform.isAndroid) return true;
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse, // needed on Android <= 11
    ].request();
    final ok = statuses.values.every((s) => s.isGranted);
    if (!ok) setState(() => _status = "Bluetooth permissions denied");
    return ok;
  }

  Future<void> _scanAndConnect() async {
  if (!await _ensureBlePermissions()) return;
  await _scanSub?.cancel();
  setState(() => _status = "Scanning...");

  _scanSub = _ble.scanForDevices(withServices: [serviceUuid]).listen((d) async {
    // Connect to the first device that advertises our service
    await _scanSub?.cancel();
    setState(() => _status = "Connecting to ${d.name.isNotEmpty ? d.name : d.id}...");
    _connect(d.id);
  }, onError: (e) => setState(() => _status = "Scan error: $e"));
}

  void _connect(String id) {
    _connSub?.cancel();
    setState(() {
      _status = "Connecting...";
      _deviceId = id;
    });

    _connSub = _ble
        .connectToDevice(
          id: id,
          servicesWithCharacteristicsToDiscover: {serviceUuid: [rxCharUuid]},
          connectionTimeout: const Duration(seconds: 10),
        )
        .listen((u) {
      switch (u.connectionState) {
        case DeviceConnectionState.connected:
          setState(() {
            _connected = true;
            _status = "Connected";
          });
          _requestMtuIfAndroid(); // <-- NEW: helps long text writes on Android
          break;
        case DeviceConnectionState.disconnected:
          setState(() {
            _connected = false;
            _status = "Disconnected";
          });
          break;
        default:
          setState(() => _status = u.connectionState.toString());
      }
    }, onError: (e) => setState(() => _status = "Conn error: $e"));
  }

  Future<void> _disconnect() async {
    await _connSub?.cancel(); // end the GATT connection
    _connSub = null;
    setState(() {
      _connected = false;
      _status = "Disconnected";
    });
  }

  int _pctToByte(double pct) {
  final double p = pct.clamp(1.0, 100.0).toDouble();
  return ((p * 255.0) / 100.0).round();
}

  Future<void> _writeAscii(String s) async {
    if (!_connected || _deviceId == null) return;
    final q = QualifiedCharacteristic(
      serviceId: serviceUuid,
      characteristicId: rxCharUuid,
      deviceId: _deviceId!,
    );
    final bytes = s.codeUnits; // ASCII

    try {
      await _ble.writeCharacteristicWithoutResponse(q, value: bytes);
    } catch (_) {
      await _ble.writeCharacteristicWithResponse(q, value: bytes);
    }
  }

  // Request a larger MTU (Android) so longer texts fit comfortably
  Future<void> _requestMtuIfAndroid() async {
    if (Platform.isAndroid && _deviceId != null) {
      try { await _ble.requestMtu(deviceId: _deviceId!, mtu: 185); } catch (_) {}
    }
  }

  // UI 1..101 -> send 0..100 (firmware 0-based)
  void _sendModeOneBased(int m) {
    final clamped = m.clamp(1, kMaxMode);
    setState(() => _mode = clamped);
    _modeInputCtrl.text = _mode.toString();
    final zeroBased = _mode - 1;
    _writeAscii("M:$zeroBased");
    // Many sketches turn off auto when a manual mode arrives; reflect that:
    setState(() => _autoCycle = false);
  }

  void _sendAuto(bool on) {
    setState(() => _autoCycle = on);
    _writeAscii(on ? "A:1" : "A:0");
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    //_nameFilterCtrl.dispose();
    _modeInputCtrl.dispose();
    _msgCtrl.dispose(); // <-- NEW
    super.dispose();
  }

    void _setSmoothing(double v) {
  final double p = v.clamp(1.0, 100.0).toDouble();
  setState(() => _smoothing = p);
  _writeAscii("S:${p.round()}");   // still sending integer percent to ESP32
}

  Widget _card(String title, Widget child) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              child,
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("AudioAnimator Remote")),
      body: ListView(
        children: [
          _card(
            "Connection",
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Status: $_status"),
                const SizedBox(height: 8),
                Row(
        children: [
          ElevatedButton(
            onPressed: _scanAndConnect,
            child: const Text("Scan & Connect"),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: _connected ? _disconnect : null,
            child: const Text("Disconnect"),
          ),
        ],
      ),
    ],
  ),
),

          _card(
            "Auto Cycle",
            SwitchListTile(
              title: const Text("Cycle modes automatically"),
              value: _autoCycle,
              onChanged: _connected ? (v) => _sendAuto(v) : null,
              contentPadding: EdgeInsets.zero,
            ),
          ),

         
          _card(
            "Mode",
            Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: _connected && _mode > 1
                          ? () => _sendModeOneBased(_mode - 1)
                          : null,
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    Expanded(
                      child: Center(
                        child: Text("$_mode", style: const TextStyle(fontSize: 18)),
                      ),
                    ),
                    IconButton(
                      onPressed: _connected && _mode < kMaxMode
                          ? () => _sendModeOneBased(_mode + 1)
                          : null,
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    SizedBox(
                      width: 140,
                      child: TextField(
                        controller: _modeInputCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: const InputDecoration(
                          labelText: "Go to (1–101)",
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: (text) {
                          final v = int.tryParse(text);
                          if (v != null && _connected) _sendModeOneBased(v);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _connected
                          ? () {
                              final v = int.tryParse(_modeInputCtrl.text);
                              if (v != null) _sendModeOneBased(v);
                            }
                          : null,
                      child: const Text("Go"),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // -------- Scroller Text card (allows blank to clear) --------
_card(
  "Scroller Text",
  Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextField(
        controller: _msgCtrl,
        decoration: const InputDecoration(
          labelText: "Text to scroll (leave empty then Send to clear)",
          border: OutlineInputBorder(),
          isDense: true,
        ),
        onSubmitted: (t) {
          if (_connected) {
            // send even if empty -> "T:\n" clears the display
            _writeAscii("T:${t.trimRight()}\n");
          }
        },
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          ElevatedButton(
            onPressed: _connected
                ? () {
                    final s = _msgCtrl.text.trimRight();
                    _writeAscii("T:$s\n");      // send even if s == ""
                  }
                : null,
            child: const Text("Send"),
          ),
          const SizedBox(width: 12),
          TextButton(
            onPressed: _connected
                ? () {
                    _msgCtrl.clear();
                    _writeAscii("T:\n");        // explicit clear
                  }
                : null,
            child: const Text("Clear"),
          ),
        ],
      ),
    ],
  ),
),
// -------- end Scroller Text card --------

          _card(
            "Brightness",
            Column(
              children: [
                Slider(
                  min: 1,
                  max: 100,
                  divisions: 99, // 1..100 in 1% steps
                  value: _brightnessPct.clamp(1.0, 100.0).toDouble(),
                  label: "${_brightnessPct.round()}%",
                  onChanged: _connected
                      ? (v) {
                          final double p = v.clamp(1.0, 100.0).toDouble();
                            setState(() => _brightnessPct = p);
                          _writeAscii("B:${_pctToByte(p)}");
                        }
                      : null,
                ),
                Text("Value: ${_brightnessPct.round()}%"),
              ],
            ),
          ),

            _card(
            "Sensitivity",
            Column(
              children: [
                Slider(
                  min: 1.0,
                  max: 100.0,
                  divisions: 99, // 1..100 in 1% steps
                  value: _smoothing.clamp(1.0, 100.0).toDouble(),
                  label: _smoothing.round().toString(),
                  onChanged: _connected ? _setSmoothing : null,
                  ),
                Text("Value: ${_smoothing.round()}%"),
              ],
            ),
          ),

          _card(
            "Peak Delay",
            Column(
              children: [
                Slider(
                  min: 1,
                  max: 50,
                  divisions: 49,
                  value: _peakDelay,
                  label: _peakDelay.round().toString(),
                  onChanged: _connected
                      ? (v) {
                          setState(() => _peakDelay = v);
                          _writeAscii("P:${v.round()}");
                        }
                      : null,
                ),
                Text("Value: ${_peakDelay.round()}"),
              ],
            ),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

