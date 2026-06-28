import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'action_handler.dart';
import 'ai_service.dart';

/// Connects the on-device agent to the agent-bridge control plane.
///
/// Polls the bridge for instructions (queued by Claude over MCP, or from the
/// web dashboard), runs each through the same AI + ActionHandler pipeline the
/// chat screen uses, and posts events (status / progress / result / error)
/// back so Claude and the dashboard can see what happened.
///
/// Mirrors TelegramService so the moving parts are identical and auditable.
class RemoteControlService {
  final ActionHandler _actionHandler;
  final AiService _aiService;

  String _baseUrl = '';   // e.g. https://agent-bridge.yourdomain.tld
  String _token = '';     // == DEVICE_TOKEN on the bridge
  bool _isEnabled = false;
  bool _isPolling = false;
  bool _busy = false;
  Timer? _pollTimer;
  Timer? _heartbeatTimer;

  RemoteControlService(this._actionHandler, this._aiService);

  String get baseUrl => _baseUrl;
  String get token => _token;
  bool get isEnabled => _isEnabled;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString('bridge_base_url') ?? '';
    _token = prefs.getString('bridge_token') ?? '';
    _isEnabled = prefs.getBool('bridge_enabled') ?? false;
    if (_isEnabled && _ready) start();
  }

  Future<void> saveSettings({
    required String baseUrl,
    required String token,
    required bool isEnabled,
  }) async {
    _baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    _token = token.trim();
    _isEnabled = isEnabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bridge_base_url', _baseUrl);
    await prefs.setString('bridge_token', _token);
    await prefs.setBool('bridge_enabled', _isEnabled);

    if (_isEnabled && _ready) {
      start();
    } else {
      stop();
    }
  }

  bool get _ready => _baseUrl.isNotEmpty && _token.isNotEmpty;
  Map<String, String> get _headers =>
      {'Authorization': 'Bearer $_token', 'Content-Type': 'application/json'};

  void start() {
    if (_isPolling || !_ready) return;
    _isPolling = true;
    _poll();
    _heartbeatTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _heartbeat());
  }

  void stop() {
    _isPolling = false;
    _pollTimer?.cancel();
    _heartbeatTimer?.cancel();
  }

  Future<void> _poll() async {
    if (!_isPolling || !_ready) return;

    if (!_busy) {
      try {
        final res = await http
            .get(Uri.parse('$_baseUrl/device/poll'), headers: _headers)
            .timeout(const Duration(seconds: 10));

        if (res.statusCode == 200 && res.body.isNotEmpty) {
          final ins = jsonDecode(res.body) as Map<String, dynamic>;
          // Run sequentially; don't pull the next task until this one finishes.
          await _handleInstruction(
            ins['id'] as String,
            (ins['text'] ?? '').toString(),
          );
        }
        // 204 = nothing queued; just loop again.
      } catch (e) {
        // Network blip — back off and retry on the next tick.
      }
    }

    if (_isPolling) {
      _pollTimer = Timer(const Duration(seconds: 2), _poll);
    }
  }

  Future<void> _handleInstruction(String id, String text) async {
    _busy = true;
    await _postEvent(type: 'status', message: 'Received: "$text"', instructionId: id);
    try {
      final aiResponse = await _aiService.sendMessage(text);

      // An empty reply means the on-device model returned nothing — usually a
      // rate-limit / out-of-credits / network blip. Surface it as an error so
      // the operator never receives a silent, empty result event.
      if (aiResponse.trim().isEmpty) {
        await _postEvent(
          type: 'error',
          message:
              'On-device AI returned an empty response (check API key / credits '
              'or rate limit on the device).',
          instructionId: id,
        );
        return;
      }

      final action = _aiService.parseAction(aiResponse);

      if (action != null) {
        final result = await _actionHandler.execute(
          action,
          aiService: _aiService,
          onProgress: (msg) =>
              _postEvent(type: 'action', message: msg, instructionId: id),
        );
        final details = result.details?.trim();
        await _postEvent(
          type: 'result',
          message: (details == null || details.isEmpty) ? 'Done' : details,
          instructionId: id,
        );
      } else {
        // Plain conversational reply — still a result for this instruction.
        await _postEvent(type: 'result', message: aiResponse, instructionId: id);
      }
    } catch (e) {
      await _postEvent(type: 'error', message: e.toString(), instructionId: id);
    } finally {
      _busy = false;
    }
  }

  Future<void> _postEvent({
    required String type,
    required String message,
    String? instructionId,
    Object? data,
  }) async {
    if (!_ready) return;
    try {
      await http
          .post(
            Uri.parse('$_baseUrl/device/events'),
            headers: _headers,
            body: jsonEncode({
              'type': type,
              'message': message,
              if (instructionId != null) 'instructionId': instructionId,
              if (data != null) 'data': data,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Best-effort telemetry; never block the agent on a failed event post.
    }
  }

  Future<void> _heartbeat() async {
    if (!_ready) return;
    try {
      await http
          .post(Uri.parse('$_baseUrl/device/heartbeat'), headers: _headers)
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  void dispose() => stop();
}
