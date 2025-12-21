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
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: seed,
        brightness: Brightness.dark,
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
  // BLE UUIDs
  static final Uuid serviceUuid =
      Uuid.parse("12345678-1234-1234-1234-1234567890ab");
  static final Uuid rxCharUuid =
      Uuid.parse("87654321-4321-4321-4321-ba0987654321");

  // ESP32 has modes 0..101 → app shows 1..102
  static const int kMaxMode = 102;

  final _ble = FlutterReactiveBle();
  final TextEditingController _modeInputCtrl = TextEditingController();
  final TextEditingController _msgCtrl = TextEditingController();

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;

  String? _deviceId;
  bool _connected = false;
  String _status = "Not connected";

  // UI state
  double _brightnessPct = 50.0;
  double _smoothing = 100.0;
  double _peakDelay = 10;
  int _mode = 55;
  bool _autoCycle = false;

  // CLOCK COLOR (default gold)
  Color _clockColor = const Color.fromARGB(255, 255, 200, 0);

  // SCROLLER COLOR (default pink-ish)
  Color _scrollColor = const Color.fromARGB(255, 255, 0, 80);

  @override
  void initState() {
    super.initState();
    _modeInputCtrl.text = _mode.toString();
  }

  // Permissions (Android)
  Future<bool> _ensureBlePermissions() async {
    if (!Platform.isAndroid) return true;
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    final ok = statuses.values.every((s) => s.isGranted);
    if (!ok) setState(() => _status = "Bluetooth permissions denied");
    return ok;
  }

  // BLE Scan + Connect
  Future<void> _scanAndConnect() async {
    if (!await _ensureBlePermissions()) return;

    await _scanSub?.cancel();
    setState(() => _status = "Scanning...");

    _scanSub = _ble.scanForDevices(withServices: [serviceUuid]).listen(
      (d) async {
        await _scanSub?.cancel();
        setState(() => _status =
            "Connecting to ${d.name.isNotEmpty ? d.name : d.id}...");
        _connect(d.id);
      },
      onError: (e) => setState(() => _status = "Scan error: $e"),
    );
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
        .listen(
      (update) {
        switch (update.connectionState) {
          case DeviceConnectionState.connected:
            setState(() {
              _connected = true;
              _status = "Connected";
            });
            _requestMtuIfAndroid();
            break;

          case DeviceConnectionState.disconnected:
            setState(() {
              _connected = false;
              _status = "Disconnected";
            });
            break;

          default:
            setState(() => _status = update.connectionState.toString());
        }
      },
      onError: (e) => setState(() => _status = "Connection error: $e"),
    );
  }

  Future<void> _disconnect() async {
    await _connSub?.cancel();
    _connSub = null;
    setState(() {
      _connected = false;
      _status = "Disconnected";
    });
  }

  int _pctToByte(double pct) =>
      ((pct.clamp(1.0, 100.0) * 255.0) / 100).round();

  // BLE Write
  Future<void> _writeAscii(String s) async {
    if (!_connected || _deviceId == null) return;

    final q = QualifiedCharacteristic(
      serviceId: serviceUuid,
      characteristicId: rxCharUuid,
      deviceId: _deviceId!,
    );

    final bytes = s.codeUnits;
    try {
      await _ble.writeCharacteristicWithoutResponse(q, value: bytes);
    } catch (_) {
      await _ble.writeCharacteristicWithResponse(q, value: bytes);
    }
  }

  // RTC Sync
  void _sendTimeUpdate() {
    if (!_connected) return;

    DateTime now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');

    final msg =
        "SETTIME:${now.year}-${two(now.month)}-${two(now.day)} "
        "${two(now.hour)}:${two(now.minute)}:${two(now.second)}";

    _writeAscii(msg);
  }

  // Send clock color to ESP32
  void _sendClockColor(Color c) {
    final msg = "CLOCKCOLOR:${c.red},${c.green},${c.blue}";
    _writeAscii(msg);
  }

  // Send scroller text color to ESP32
  void _sendScrollColor(Color c) {
    final msg = "SCROLLCOLOR:${c.red},${c.green},${c.blue}";
    _writeAscii(msg);
  }

  // Request larger MTU for long packets
  Future<void> _requestMtuIfAndroid() async {
    if (Platform.isAndroid && _deviceId != null) {
      try {
        await _ble.requestMtu(deviceId: _deviceId!, mtu: 185);
      } catch (_) {}
    }
  }

  // Mode control
  void _sendModeOneBased(int m) {
    final newMode = m.clamp(1, kMaxMode);
    setState(() => _mode = newMode);
    _modeInputCtrl.text = newMode.toString();

    _writeAscii("M:${newMode - 1}");
    setState(() => _autoCycle = false);
  }

  void _sendAuto(bool enabled) {
    setState(() => _autoCycle = enabled);
    _writeAscii(enabled ? "A:1" : "A:0");
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    _modeInputCtrl.dispose();
    _msgCtrl.dispose();
    super.dispose();
  }

  void _setSmoothing(double v) {
    final num p = v.clamp(1, 100);
    setState(() => _smoothing = p.toDouble());
    _writeAscii("S:${p.round()}");
  }

  Widget _card(String title, Widget child) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            child,
          ]),
        ),
      );

  // Clock color picker dialog
  Future<void> _pickClockColor() async {
    Color preview = _clockColor;

    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Clock Color"),
          content: StatefulBuilder(
            builder: (context, setStateDialog) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: preview,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Slider(
                    min: 0,
                    max: 255,
                    value: preview.red.toDouble(),
                    onChanged: (v) =>
                        setStateDialog(() => preview = preview.withRed(v.toInt())),
                  ),
                  Slider(
                    min: 0,
                    max: 255,
                    value: preview.green.toDouble(),
                    onChanged: (v) => setStateDialog(
                        () => preview = preview.withGreen(v.toInt())),
                  ),
                  Slider(
                    min: 0,
                    max: 255,
                    value: preview.blue.toDouble(),
                    onChanged: (v) =>
                        setStateDialog(() => preview = preview.withBlue(v.toInt())),
                  ),
                ],
              );
            },
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel")),
            TextButton(
                onPressed: () {
                  setState(() => _clockColor = preview);
                  _sendClockColor(preview);
                  Navigator.pop(context);
                },
                child: const Text("Apply")),
          ],
        );
      },
    );
  }

  // Scroller text color picker dialog
  Future<void> _pickScrollColor() async {
    Color preview = _scrollColor;

    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Scroller Text Color"),
          content: StatefulBuilder(
            builder: (context, setStateDialog) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: preview,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Slider(
                    min: 0,
                    max: 255,
                    value: preview.red.toDouble(),
                    onChanged: (v) =>
                        setStateDialog(() => preview = preview.withRed(v.toInt())),
                  ),
                  Slider(
                    min: 0,
                    max: 255,
                    value: preview.green.toDouble(),
                    onChanged: (v) => setStateDialog(
                        () => preview = preview.withGreen(v.toInt())),
                  ),
                  Slider(
                    min: 0,
                    max: 255,
                    value: preview.blue.toDouble(),
                    onChanged: (v) =>
                        setStateDialog(() => preview = preview.withBlue(v.toInt())),
                  ),
                ],
              );
            },
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel")),
            TextButton(
                onPressed: () {
                  setState(() => _scrollColor = preview);
                  _sendScrollColor(preview);
                  Navigator.pop(context);
                },
                child: const Text("Apply")),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("AudioAnimator Remote")),
      body: ListView(
        children: [
          // CONNECTION
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

          // RTC SYNC
          _card(
  "Clock Settings",
  Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [

      // --- TIME SYNC BUTTON ---
      ElevatedButton(
        onPressed: _connected ? _sendTimeUpdate : null,
        child: const Text("Sync Time to Set Clock"),
      ),
      const SizedBox(height: 6),
      //const Text(
        //"Sets the DS3231 RTC using your phone’s current time.",
      //),

      //const SizedBox(height: 16),
      //const Divider(height: 1),

      const SizedBox(height: 16),

      // --- CLOCK COLOR PICKER ---
      Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _clockColor,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.white30),
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: _connected ? _pickClockColor : null,
            child: const Text("Set Clock Color For Mode 102"),
          ),
        ],
      ),
      const SizedBox(height: 6),
      //const Text(
        //"Controls the color of the RTC clock display (mode 102).",
      //),
    ],
  ),
),


          // AUTO CYCLE
          _card(
            "Auto Cycle",
            SwitchListTile(
              title: const Text("Cycle modes automatically"),
              value: _autoCycle,
              onChanged: _connected ? (v) => _sendAuto(v) : null,
              contentPadding: EdgeInsets.zero,
            ),
          ),

          // MODE CONTROL
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
                        child: Text(
                          "$_mode",
                          style: const TextStyle(fontSize: 18),
                        ),
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
                          labelText: "Go to (1–102)",
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

          // SCROLLER TEXT + COLOR (same card)
          _card(
            "Scrolling Text",
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
                              _writeAscii("T:$s\n");
                            }
                          : null,
                      child: const Text("Send"),
                    ),
                    const SizedBox(width: 12),
                    TextButton(
                      onPressed: _connected
                          ? () {
                              _msgCtrl.clear();
                              _writeAscii("T:\n"); // explicit clear
                            }
                          : null,
                      child: const Text("Clear"),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: _scrollColor,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.white30),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: _connected ? _pickScrollColor : null,
                      child: const Text("Set Scroller Color For Mode 101"),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                //const Text(
                  //"Controls the color of the scrolling text (mode 101 and T: messages).",
                //),
              ],
            ),
          ),

          // BRIGHTNESS
          _card(
            "Brightness",
            Column(
              children: [
                Slider(
                  min: 1,
                  max: 100,
                  value: _brightnessPct.clamp(1.0, 100.0),
                  label: "${_brightnessPct.round()}%",
                  onChanged: _connected
                      ? (v) {
                          setState(() => _brightnessPct = v);
                          _writeAscii("B:${_pctToByte(v)}");
                        }
                      : null,
                ),
                Text("Value: ${_brightnessPct.round()}%"),
              ],
            ),
          ),

          // SMOOTHING
          _card(
            "Sensitivity (Smoothing)",
            Column(
              children: [
                Slider(
                  min: 1,
                  max: 100,
                  value: _smoothing.clamp(1.0, 100.0),
                  label: _smoothing.round().toString(),
                  onChanged: _connected ? _setSmoothing : null,
                ),
                Text("Value: ${_smoothing.round()}%"),
              ],
            ),
          ),

          // PEAK DELAY
          _card(
            "Peak Delay",
            Column(
              children: [
                Slider(
                  min: 1,
                  max: 50,
                  value: _peakDelay.clamp(1.0, 50.0),
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

          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

