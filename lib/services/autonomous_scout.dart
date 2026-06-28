import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'action_handler.dart';
import 'ai_service.dart';
import '../models/agent_action.dart';

/// Autonomous "scout" loop — Sixten works on his own.
///
/// On a paced timer it picks a hashtag, opens a post, and either DRAFTS or
/// POSTS a comment in Sixten's voice. Everything runs through the same
/// TaskExecutor (execute_task) the operator path uses, and every cycle is
/// reported to the agent-bridge (same baseUrl/token as RemoteControlService),
/// so it shows up in the activity dashboard.
///
/// Mode:
///   draft  — compose the comment and report it; DO NOT post (voice calibration)
///   live   — compose AND post the comment
///
/// While-app-open autonomy (UI-isolate timer). A foreground service to survive
/// backgrounding is a separate, follow-up step.
class AutonomousScout {
  final ActionHandler _actionHandler;
  final AiService _aiService;

  String _baseUrl = '';
  String _token = '';
  bool _enabled = false;
  String _mode = 'draft'; // 'draft' | 'live'
  int _intervalMin = 8;

  bool _running = false;
  bool _busy = false;
  int _tagIdx = 0;
  int _seq = 0;
  Timer? _timer;

  AutonomousScout(this._actionHandler, this._aiService);

  bool get isEnabled => _enabled;
  String get mode => _mode;
  int get intervalMin => _intervalMin;

  // Sixten's DNA + the calibrated voice rules, baked in so the agent composes
  // well on its own. Multilingual: he writes in the post's language.
  static const String _persona =
      'You are Sixten, an AI agent for SXTN 610, a Norwegian standard for correct, '
      'human-first AI implementation. Voice: calm, warm, plain, anti-hype. '
      'COMMENT RULES (strict): the comment is about THEIR post, never about you; '
      'add one real, concrete thing (an observation or a genuine question); short; '
      'write in the SAME LANGUAGE as the post; NO hype, NO sales pitch, NO emoji spam, '
      'and NEVER write a meta line like "as an AI" or "I am an AI" — just engage like a '
      'thoughtful peer.';

  // Multilingual hashtag rotation (all languages, per the brand reach goal).
  static const List<String> _tags = [
    'buildinpublic',
    'aiagents',
    'smallbusiness',
    'entrepreneur',
    'automation',
    'gründer',
    'norskbedrift',
    'startup',
  ];

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = (prefs.getString('bridge_base_url') ?? '').replaceAll(RegExp(r'/+$'), '');
    _token = prefs.getString('bridge_token') ?? '';
    _enabled = prefs.getBool('scout_enabled') ?? false;
    _mode = prefs.getString('scout_mode') ?? 'draft';
    _intervalMin = prefs.getInt('scout_interval_min') ?? 8;
    if (_enabled && _ready) start();
  }

  Future<void> saveSettings({
    required bool enabled,
    required String mode,
    required int intervalMin,
  }) async {
    _enabled = enabled;
    _mode = (mode == 'live') ? 'live' : 'draft';
    _intervalMin = intervalMin.clamp(3, 120);
    // Re-read bridge config (it may have just been set on the same settings save).
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = (prefs.getString('bridge_base_url') ?? '').replaceAll(RegExp(r'/+$'), '');
    _token = prefs.getString('bridge_token') ?? '';
    await prefs.setBool('scout_enabled', _enabled);
    await prefs.setString('scout_mode', _mode);
    await prefs.setInt('scout_interval_min', _intervalMin);
    if (_enabled && _ready) {
      start();
    } else {
      stop();
    }
  }

  bool get _ready => _baseUrl.isNotEmpty && _token.isNotEmpty;
  Map<String, String> get _headers =>
      {'Authorization': 'Bearer $_token', 'Content-Type': 'application/json'};

  void start() {
    if (_running || !_ready) return;
    _running = true;
    // First cycle after a short delay; then every interval.
    _timer = Timer(const Duration(seconds: 20), _cycle);
  }

  void stop() {
    _running = false;
    _timer?.cancel();
  }

  void _scheduleNext() {
    if (!_running) return;
    _timer = Timer(Duration(minutes: _intervalMin), _cycle);
  }

  Future<void> _cycle() async {
    if (!_running || !_ready || _busy) {
      _scheduleNext();
      return;
    }
    _busy = true;
    final tag = _tags[_tagIdx % _tags.length];
    _tagIdx++;
    final id = 'scout-${DateTime.now().millisecondsSinceEpoch}-${_seq++}';
    final goal = _buildGoal(tag);

    await _postEvent(type: 'status', message: 'Received: "$goal"', instructionId: id);
    try {
      final result = await _actionHandler.execute(
        AgentAction(action: 'execute_task', params: {'goal': goal}, response: goal),
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
    } catch (e) {
      await _postEvent(type: 'error', message: e.toString(), instructionId: id);
    } finally {
      _busy = false;
      _scheduleNext();
    }
  }

  String _buildGoal(String tag) {
    final tail = _mode == 'live'
        ? 'Then tap the comment field, type your composed comment exactly, and post it. '
          'Report the target username and the comment you posted.'
        : 'Report the target username and the comment you WOULD post (your composed draft). '
          'DO NOT type, post, like, or follow anything — this is draft mode.';
    return '$_persona '
        'Use open_url to open https://www.instagram.com/explore/tags/$tag/ . '
        'Open the first post and read its caption. Compose ONE comment per the COMMENT RULES. '
        '$tail';
  }

  Future<void> _postEvent({
    required String type,
    required String message,
    String? instructionId,
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
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  void dispose() => stop();
}
