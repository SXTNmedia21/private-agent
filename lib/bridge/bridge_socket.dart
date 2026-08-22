/// BridgeSocket — the phone's outbound connection to the bridge (ADR-4).
///
/// The phone dials OUT. There is no listening port on this handset and there never
/// will be: the device sits behind carrier NAT, and giving it an inbound RPC surface
/// would be the single worst thing you could do to a phone with accessibility
/// control over every app on it.
///
/// Replaces the 2 s polling loop. Polling gave a 2 s floor per action, one
/// instruction in flight, free text instead of typed calls, and no way to know the
/// phone was alive between polls. This gives sub-second primitives and makes
/// "offline" a fact rather than an inference.
///
/// Lifecycle: connect -> heartbeat every 15 s -> on drop, exponential backoff and
/// reconnect. Backoff rather than a fixed retry because a bridge that is down should
/// not be hammered by a phone that reconnects every second forever.
library;

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'protocol.dart';
import 'rpc_handlers.dart';

enum BridgeConnectionState { disabled, connecting, connected, reconnecting, refused }

class BridgeStatus {
  const BridgeStatus({
    required this.state,
    this.lastFrameAt,
    this.attempt = 0,
    this.detail,
  });

  final BridgeConnectionState state;
  final DateTime? lastFrameAt;
  final int attempt;
  final String? detail;

  /// The one line the operator actually reads on the settings screen
  /// (DESIGN §1) — the current app makes them guess.
  String get line => switch (state) {
        BridgeConnectionState.disabled => 'disabled',
        BridgeConnectionState.connecting => 'connecting…',
        BridgeConnectionState.connected => lastFrameAt == null
            ? 'connected'
            : 'connected · last frame ${_ago(lastFrameAt!)} ago',
        BridgeConnectionState.reconnecting => 'reconnecting (attempt $attempt)',
        BridgeConnectionState.refused => 'refused: ${detail ?? 'check the device token'}',
      };

  static String _ago(DateTime t) {
    final s = DateTime.now().difference(t).inSeconds;
    if (s < 60) return '${s}s';
    final m = s ~/ 60;
    if (m < 60) return '${m}m';
    return '${m ~/ 60}h';
  }
}

typedef StatusListener = void Function(BridgeStatus status);

class BridgeSocket {
  BridgeSocket({
    required RpcHandlers handlers,
    Future<WebSocketChannel> Function(Uri uri, Map<String, dynamic> headers)? connector,
  })  : _handlers = handlers,
        _connector = connector ?? _defaultConnector;

  final RpcHandlers _handlers;
  final Future<WebSocketChannel> Function(Uri, Map<String, dynamic>) _connector;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _heartbeat;
  Timer? _reconnect;
  int _attempt = 0;
  bool _enabled = false;
  bool _disposed = false;
  DateTime? _lastFrameAt;

  String _baseUrl = '';
  String _token = '';
  String _deviceId = 'a20e';
  String _appVersion = '0.0.0';
  int _buildNumber = 0;

  final List<StatusListener> _listeners = <StatusListener>[];
  BridgeStatus _status = const BridgeStatus(state: BridgeConnectionState.disabled);

  BridgeStatus get status => _status;

  void addListener(StatusListener l) => _listeners.add(l);
  void removeListener(StatusListener l) => _listeners.remove(l);

  void _setStatus(BridgeConnectionState state, {String? detail}) {
    _status = BridgeStatus(
      state: state,
      lastFrameAt: _lastFrameAt,
      attempt: _attempt,
      detail: detail,
    );
    for (final l in List<StatusListener>.from(_listeners)) {
      l(_status);
    }
  }

  /// Configure and (re)start. Safe to call repeatedly — a settings save does.
  Future<void> configure({
    required String baseUrl,
    required String token,
    required String deviceId,
    required bool enabled,
    String appVersion = '0.0.0',
    int buildNumber = 0,
  }) async {
    _baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    _token = token.trim();
    _deviceId = deviceId.trim().isEmpty ? 'a20e' : deviceId.trim();
    _appVersion = appVersion;
    _buildNumber = buildNumber;
    _enabled = enabled;

    await _teardown();
    if (_enabled && _ready) {
      _attempt = 0;
      unawaited(_connect());
    } else {
      _setStatus(BridgeConnectionState.disabled);
    }
  }

  bool get _ready => _baseUrl.isNotEmpty && _token.isNotEmpty;

  /// `https://host` -> `wss://host/device/ws`. The token rides an Authorization
  /// header, never the query string — a URL ends up in logs and proxies.
  Uri get wsUri {
    final base = Uri.parse(_baseUrl);
    final scheme = base.scheme == 'http' ? 'ws' : 'wss';
    return base.replace(scheme: scheme, path: '${base.path}/device/ws');
  }

  static Future<WebSocketChannel> _defaultConnector(
    Uri uri,
    Map<String, dynamic> headers,
  ) async =>
      IOWebSocketChannel.connect(uri, headers: headers, pingInterval: const Duration(seconds: 20));

  Future<void> _connect() async {
    if (_disposed || !_enabled || !_ready) return;
    _setStatus(_attempt == 0 ? BridgeConnectionState.connecting : BridgeConnectionState.reconnecting);

    try {
      final channel = await _connector(wsUri, <String, dynamic>{
        headerAuthorization: 'Bearer $_token',
        headerDeviceId: _deviceId,
        headerAppVersion: _appVersion,
        headerBuildNumber: '$_buildNumber',
      });
      _channel = channel;

      // Belt and braces: the bridge reads identity from the upgrade headers, but a
      // `hello` frame costs nothing and covers a proxy that strips custom headers.
      channel.sink.add(encodeHello(
        deviceId: _deviceId,
        appVersion: _appVersion,
        buildNumber: _buildNumber,
      ));

      _attempt = 0;
      _lastFrameAt = DateTime.now();
      _setStatus(BridgeConnectionState.connected);
      _startHeartbeat();

      _sub = channel.stream.listen(
        _onFrame,
        onError: (Object e) => _scheduleReconnect(e.toString()),
        onDone: () => _scheduleReconnect(
          _closeReason(channel.closeCode, channel.closeReason),
        ),
        cancelOnError: true,
      );
    } catch (e) {
      _scheduleReconnect(e.toString());
    }
  }

  /// 401/4401 means the token is wrong, not that the network blipped. Say so —
  /// the operator is otherwise left staring at "reconnecting" forever after a
  /// rotation they forgot to mirror into Settings.
  String _closeReason(int? code, String? reason) {
    if (code == 4401 || code == 401 || code == 1008) {
      return 'bad device token (bridge closed with $code)';
    }
    if (code == 4409) return 'superseded by another connection for this device id';
    if (code == 4408) return 'heartbeat timeout';
    return reason?.isNotEmpty == true ? reason! : 'connection closed (${code ?? 'no code'})';
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(heartbeatInterval, (_) {
      final ch = _channel;
      if (ch == null) return;
      try {
        ch.sink.add(encodeHeartbeat());
      } catch (_) {
        // The stream's onDone/onError path owns reconnection; do not double-trigger.
      }
    });
  }

  void _onFrame(dynamic raw) {
    _lastFrameAt = DateTime.now();
    if (raw is! String) return; // the phone sends binary, it never receives it
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return; // a malformed frame is dropped; the bridge will retry
    }
    if (decoded is! Map) return;
    final json = Map<String, dynamic>.from(decoded);
    if (json['type'] != 'request') return;

    RpcRequest req;
    try {
      req = RpcRequest.fromJson(json);
    } catch (_) {
      return;
    }
    unawaited(_handle(req));
  }

  Future<void> _handle(RpcRequest req) async {
    final outcome = await _handlers.dispatch(req);
    final ch = _channel;
    if (ch == null) return;
    try {
      // JSON first, then the binary frame it announced — the bridge pairs them by
      // id and tolerates either order, but this order keeps captures readable.
      ch.sink.add(outcome.response.encode());
      final bytes = outcome.binary;
      if (bytes != null && bytes.isNotEmpty) {
        ch.sink.add(encodeBinaryFrame(
          id: req.id,
          mime: outcome.response.binaryMime ?? 'application/octet-stream',
          name: outcome.response.binaryName,
          payload: bytes,
        ));
      }
      _setStatus(BridgeConnectionState.connected);
    } catch (_) {
      // Socket died mid-reply; the reconnect path will pick it up.
    }
  }

  /// Emit an unsolicited event (a gate refusal, for instance) so a refusal is
  /// evidence on the bridge rather than something only this phone knows.
  void emitEvent(String event, Map<String, dynamic> data) {
    try {
      _channel?.sink.add(encodeEvent(event, data));
    } catch (_) {
      // Best effort — never let telemetry break the executor.
    }
  }

  void _scheduleReconnect(String detail) {
    _sub?.cancel();
    _sub = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _channel = null;

    if (_disposed || !_enabled || !_ready) {
      _setStatus(BridgeConnectionState.disabled);
      return;
    }

    final isAuth = detail.contains('bad device token');
    _attempt++;
    // Exponential with a ceiling. A wrong token backs off to the cap fast rather
    // than retrying a doomed handshake every second until the battery dies.
    final delayMs = (reconnectMinDelay.inMilliseconds * (1 << (_attempt - 1).clamp(0, 10)))
        .clamp(reconnectMinDelay.inMilliseconds, reconnectMaxDelay.inMilliseconds);

    _setStatus(
      isAuth ? BridgeConnectionState.refused : BridgeConnectionState.reconnecting,
      detail: detail,
    );

    _reconnect?.cancel();
    _reconnect = Timer(Duration(milliseconds: delayMs), () {
      unawaited(_connect());
    });
  }

  Future<void> _teardown() async {
    _reconnect?.cancel();
    _reconnect = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    await _sub?.cancel();
    _sub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {
      // already gone
    }
    _channel = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    _enabled = false;
    _listeners.clear();
    await _teardown();
  }
}
