/// PrivateAgent — an executor for the agent-bridge control plane.
///
/// This app holds no plan, no model, no schedule and no Telegram token. It opens
/// one outbound socket to the bridge, performs one primitive at a time, and reports
/// what it observed (ADR-2). Everything that decides what to do next lives on the
/// bridge, off this device, because the on-device model was the proven failure point.
library;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bridge/bridge_socket.dart';
import 'bridge/device_channel.dart';
import 'bridge/rpc_handlers.dart';
import 'screens/settings_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PrivateAgentApp());
}

class PrivateAgentApp extends StatefulWidget {
  const PrivateAgentApp({super.key});

  @override
  State<PrivateAgentApp> createState() => _PrivateAgentAppState();
}

class _PrivateAgentAppState extends State<PrivateAgentApp> {
  late final DeviceChannel _channel;
  late final BridgeSocket _socket;
  String? _deviceSecret;

  @override
  void initState() {
    super.initState();
    _channel = DeviceChannel();
    _socket = BridgeSocket(
      handlers: RpcHandlers(
        channel: _channel,
        // Read through a closure so a Settings save takes effect on the next call
        // without rebuilding the handler graph.
        deviceSecret: () => _deviceSecret,
        onGateRefusal: (event, data) => _socket.emitEvent(event, data),
      ),
    );
    _applySettings();
  }

  /// Load persisted settings and (re)start the socket. Called at boot and after
  /// every Settings save.
  Future<void> _applySettings() async {
    final prefs = await SharedPreferences.getInstance();
    final info = await PackageInfo.fromPlatform();
    _deviceSecret = prefs.getString('device_secret');

    final enabled = prefs.getBool('bridge_enabled') ?? false;

    // The foreground service is what keeps the socket alive when the app is
    // backgrounded; without it One UI kills the connection within minutes.
    if (enabled) {
      await _channel.startForegroundService();
    } else {
      await _channel.stopForegroundService();
    }

    await _socket.configure(
      baseUrl: prefs.getString('bridge_base_url') ?? '',
      token: prefs.getString('bridge_token') ?? '',
      deviceId: prefs.getString('device_id') ?? 'a20e',
      enabled: enabled,
      appVersion: info.version,
      buildNumber: int.tryParse(info.buildNumber) ?? 0,
    );

    // Mirror the connection state into the ongoing notification so the operator
    // can see it without opening the app.
    _socket.addListener((s) {
      _channel.updateForegroundStatus(s.line);
    });
  }

  @override
  void dispose() {
    _socket.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PrivateAgent',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: SettingsScreen(
        socket: _socket,
        channel: _channel,
        onSettingsSaved: _applySettings,
      ),
    );
  }
}
