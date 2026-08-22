/// The one screen this app has (DESIGN §1).
///
/// It is configured once and restored after every reinstall, so it is built for
/// that job and no other: the bridge connection, a permissions checklist where
/// every row has silently broken a session before, and the update card.
///
/// The AI / Telegram / Autonomous-Scout sections are gone with the on-device brain
/// (ADR-2). Nothing here talks to a model.
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/bridge_socket.dart';
import '../bridge/device_channel.dart';
import '../services/shizuku_service.dart';
import '../services/update_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.socket,
    required this.channel,
    required this.onSettingsSaved,
  });

  final BridgeSocket socket;
  final DeviceChannel channel;
  final Future<void> Function() onSettingsSaved;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  final _secretCtrl = TextEditingController();
  final _deviceIdCtrl = TextEditingController();

  bool _enabled = false;
  bool _loading = true;
  bool _saving = false;

  /// Secrets are never rendered back after a save — the field shows that one is
  /// stored and offers to replace it. A token on screen is a token in a screenshot.
  bool _tokenStored = false;
  bool _secretStored = false;
  bool _replacingToken = false;
  bool _replacingSecret = false;

  _Health _health = const _Health();
  BridgeStatus _status = const BridgeStatus(state: BridgeConnectionState.disabled);

  final _shizuku = ShizukuService();
  final _updates = UpdateService();

  @override
  void initState() {
    super.initState();
    widget.socket.addListener(_onStatus);
    _status = widget.socket.status;
    _load();
  }

  @override
  void dispose() {
    widget.socket.removeListener(_onStatus);
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    _secretCtrl.dispose();
    _deviceIdCtrl.dispose();
    super.dispose();
  }

  void _onStatus(BridgeStatus s) {
    if (mounted) setState(() => _status = s);
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('bridge_token') ?? '';
    final secret = prefs.getString('device_secret') ?? '';
    if (!mounted) return;
    setState(() {
      _urlCtrl.text = prefs.getString('bridge_base_url') ?? 'https://agent-bridge.sxtn.online';
      _deviceIdCtrl.text = prefs.getString('device_id') ?? 'a20e';
      _enabled = prefs.getBool('bridge_enabled') ?? false;
      _tokenStored = token.isNotEmpty;
      _secretStored = secret.isNotEmpty;
      _loading = false;
    });
    await _refreshHealth();
  }

  Future<void> _refreshHealth() async {
    final a11y = await widget.channel.accessibilityRunning();
    final notif = await widget.channel.notificationAccessGranted();
    final battery = await widget.channel.batteryUnrestricted();
    final fg = await widget.channel.isForegroundServiceRunning();
    await _shizuku.checkAvailability();
    if (!mounted) return;
    setState(() {
      _health = _Health(
        accessibility: a11y,
        notificationAccess: notif.value ?? false,
        batteryUnrestricted: battery.value ?? false,
        foregroundRunning: fg.value ?? false,
        shizukuAvailable: _shizuku.isAvailable,
        shizukuGranted: _shizuku.hasPermission,
      );
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final prefs = await SharedPreferences.getInstance();

    final url = _urlCtrl.text.trim();
    if (url.isNotEmpty && !url.startsWith('https://') && !url.startsWith('http://')) {
      _toast('Bridge URL must start with https://');
      setState(() => _saving = false);
      return;
    }
    await prefs.setString('bridge_base_url', url);
    await prefs.setString('device_id', _deviceIdCtrl.text.trim());

    // Only overwrite a stored secret when the operator actually typed a new one.
    if (_tokenCtrl.text.trim().isNotEmpty) {
      await prefs.setString('bridge_token', _tokenCtrl.text.trim());
      _tokenStored = true;
    }
    if (_secretCtrl.text.trim().isNotEmpty) {
      await prefs.setString('device_secret', _secretCtrl.text.trim());
      _secretStored = true;
    }
    // BootReceiver reads this key (as "flutter.bridge_enabled") to decide whether to
    // start the service after a reboot.
    await prefs.setBool('bridge_enabled', _enabled);

    _tokenCtrl.clear();
    _secretCtrl.clear();
    setState(() {
      _replacingToken = false;
      _replacingSecret = false;
      _saving = false;
    });

    await widget.onSettingsSaved();
    if (mounted) _toast('Saved');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('PrivateAgent'),
        actions: [
          IconButton(
            tooltip: 'Refresh checks',
            onPressed: _refreshHealth,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle('Bridge'),
          _connectionCard(),
          const SizedBox(height: 12),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: 'Bridge URL',
              hintText: 'https://agent-bridge.sxtn.online',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
          const SizedBox(height: 12),
          _secretField(
            label: 'Device token',
            controller: _tokenCtrl,
            stored: _tokenStored,
            replacing: _replacingToken,
            onReplace: () => setState(() => _replacingToken = true),
            help: 'op://sxtn-os/agent-bridge/device_token',
          ),
          const SizedBox(height: 12),
          _secretField(
            label: 'Device secret',
            controller: _secretCtrl,
            stored: _secretStored,
            replacing: _replacingSecret,
            onReplace: () => setState(() => _replacingSecret = true),
            help: 'op://sxtn-os/agent-bridge/device_secret — signs the approval gate',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _deviceIdCtrl,
            decoration: const InputDecoration(
              labelText: 'Device id',
              helperText: 'Must match a devices row on the bridge, or the socket is refused',
              border: OutlineInputBorder(),
            ),
            autocorrect: false,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled'),
            subtitle: const Text('Dial out to the bridge and auto-reconnect'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
            label: const Text('Save'),
          ),

          const SizedBox(height: 28),
          _sectionTitle('Permissions & health'),
          _checkRow(
            'Accessibility service',
            _health.accessibility,
            onFix: widget.channel.openAccessibilitySettings,
          ),
          _checkRow(
            'Notification access',
            _health.notificationAccess,
            onFix: () => widget.channel.openNotificationAccessSettings(),
          ),
          _checkRow(
            'Battery unrestricted',
            _health.batteryUnrestricted,
            onFix: () => widget.channel.requestBatteryUnrestricted(),
            why: 'OEM battery saver kills the socket otherwise',
          ),
          _checkRow('Foreground service', _health.foregroundRunning),
          _checkRow(
            'Shizuku',
            _health.shizukuGranted,
            optional: true,
            why: _health.shizukuAvailable ? 'installed, not granted' : 'not installed (optional)',
            onFix: _health.shizukuAvailable ? () => _shizuku.requestPermission() : null,
          ),

          const SizedBox(height: 28),
          _sectionTitle('App updates'),
          _UpdateCard(updates: _updates),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );

  /// The most useful widget on the screen: it says what the connection is actually
  /// doing, including *why* it was refused.
  Widget _connectionCard() {
    final (icon, color) = switch (_status.state) {
      BridgeConnectionState.connected => (Icons.check_circle, Colors.green),
      BridgeConnectionState.connecting => (Icons.sync, Colors.amber),
      BridgeConnectionState.reconnecting => (Icons.sync_problem, Colors.amber),
      BridgeConnectionState.refused => (Icons.error, Colors.red),
      BridgeConnectionState.disabled => (Icons.pause_circle, Colors.grey),
    };
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(_status.line),
        subtitle: _status.state == BridgeConnectionState.refused
            ? const Text('Check the device token — it was rotated on 2026-08-22')
            : null,
      ),
    );
  }

  Widget _secretField({
    required String label,
    required TextEditingController controller,
    required bool stored,
    required bool replacing,
    required VoidCallback onReplace,
    required String help,
  }) {
    if (stored && !replacing) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.lock),
          title: Text(label),
          subtitle: Text('•••••••••••  ·  $help'),
          trailing: TextButton(onPressed: onReplace, child: const Text('Replace')),
        ),
      );
    }
    return TextField(
      controller: controller,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        helperText: help,
        helperMaxLines: 2,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _checkRow(
    String label,
    bool ok, {
    Future<void> Function()? onFix,
    VoidCallback? onFixSync,
    String? why,
    bool optional = false,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        ok ? Icons.check_circle : (optional ? Icons.remove_circle_outline : Icons.cancel),
        color: ok ? Colors.green : (optional ? Colors.grey : Colors.red),
      ),
      title: Text(label),
      subtitle: why == null ? null : Text(why),
      trailing: (!ok && (onFix != null || onFixSync != null))
          ? TextButton(
              onPressed: () async {
                if (onFix != null) await onFix();
                onFixSync?.call();
                await Future<void>.delayed(const Duration(milliseconds: 400));
                await _refreshHealth();
              },
              child: const Text('Fix'),
            )
          : null,
    );
  }
}

class _Health {
  const _Health({
    this.accessibility = false,
    this.notificationAccess = false,
    this.batteryUnrestricted = false,
    this.foregroundRunning = false,
    this.shizukuAvailable = false,
    this.shizukuGranted = false,
  });

  final bool accessibility;
  final bool notificationAccess;
  final bool batteryUnrestricted;
  final bool foregroundRunning;
  final bool shizukuAvailable;
  final bool shizukuGranted;
}

/// Unchanged in substance from the shipped build-11 guard: shows the installed
/// build and warns when build < 8, which cannot update in place because the
/// signing key changed (see docs/GOTCHA-apk-update-signing.md).
class _UpdateCard extends StatefulWidget {
  const _UpdateCard({required this.updates});
  final UpdateService updates;

  @override
  State<_UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<_UpdateCard> {
  InstalledVersion? _installed;
  String _status = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadInstalled();
  }

  Future<void> _loadInstalled() async {
    final v = await widget.updates.currentVersion();
    if (mounted) setState(() => _installed = v);
  }

  Future<void> _checkAndInstall() async {
    setState(() {
      _busy = true;
      _status = 'Checking…';
    });
    try {
      final info = await widget.updates.check();
      if (info == null) {
        if (mounted) setState(() => _status = 'Up to date.');
        return;
      }
      if (mounted) setState(() => _status = 'Downloading build ${info.build}…');
      final msg = await widget.updates.downloadAndInstall(
        info,
        onProgress: (p) {
          if (mounted && p > 0) {
            setState(() => _status = 'Downloading build ${info.build}… ${(p * 100).round()}%');
          }
        },
      );
      if (mounted) setState(() => _status = msg.isEmpty ? 'Installer launched.' : msg);
    } catch (e) {
      // Surface the installer error rather than silently doing nothing — the
      // "App not installed" case has a specific cause and a specific fix.
      if (mounted) setState(() => _status = '$e\n\n${UpdateService.reinstallHint}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _installed;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Installed: ${v?.toString() ?? '…'}'),
            if (v != null && v.needsReinstall) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'This build predates the fixed signing key (build '
                  '${UpdateService.firstFixedKeyBuild}). Android cannot update it in '
                  'place — uninstall once, then install the new build.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_status, style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _checkAndInstall,
              icon: _busy
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.system_update),
              label: const Text('Check for updates'),
            ),
          ],
        ),
      ),
    );
  }
}
