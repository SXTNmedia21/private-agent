/// Device RPC wire protocol — the phone half.
///
/// This file is a CONTRACT, not a design. It must stay byte-for-byte compatible with
/// `agent-bridge/src/device/protocol.ts`. If you change a frame shape here, the bridge
/// stops understanding this phone, and the only symptom is a mission that silently
/// does nothing. Change both sides in the same commit or not at all.
///
/// Transport: one WebSocket to `/device/ws`. The phone dials OUT; the bridge never
/// dials the handset (there is no listening port on this device).
///
/// Frames:
///   text   — JSON: `hello` | `request` | `response` | `heartbeat` | `event`
///   binary — a payload (PNG) correlated to a request id, never base64 inside JSON
///
/// Binary frame layout (big-endian):
///   [0..3]      uint32  header length H
///   [4..4+H)    UTF-8 JSON header: { id, mime, name? }
///   [4+H..]     raw payload bytes
library;

import 'dart:convert';
import 'dart:typed_data';

/// The phone sends one of these every 15 s; the bridge closes the socket at 45 s.
const Duration heartbeatInterval = Duration(seconds: 15);

/// Reconnect backoff. Exponential, capped — a flaky link must not become a
/// reconnect storm against the bridge.
const Duration reconnectMinDelay = Duration(seconds: 1);
const Duration reconnectMaxDelay = Duration(minutes: 2);

/// Handshake headers. The bridge reads `device_id` / `app_version` / `build_number`
/// at the HTTP upgrade (ADR-4 D2), which is why they are headers and not a first frame.
const String headerAuthorization = 'Authorization';
const String headerDeviceId = 'x-device-id';
const String headerAppVersion = 'x-app-version';
const String headerBuildNumber = 'x-build-number';

/// One inbound RPC request from the bridge.
class RpcRequest {
  const RpcRequest({
    required this.id,
    required this.method,
    required this.params,
    this.timeoutMs,
  });

  final String id;
  final String method;
  final Map<String, dynamic> params;
  final int? timeoutMs;

  static RpcRequest fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final method = json['method'];
    if (id is! String || method is! String) {
      throw const FormatException('request frame needs a string id and method');
    }
    final rawParams = json['params'];
    return RpcRequest(
      id: id,
      method: method,
      params: rawParams is Map ? Map<String, dynamic>.from(rawParams) : <String, dynamic>{},
      timeoutMs: json['timeout_ms'] is int ? json['timeout_ms'] as int : null,
    );
  }
}

/// The response envelope every primitive returns (ADR-4 D3).
///
/// `binary` announces that a binary frame with the same id belongs to this response.
/// The bridge resolves the call only once BOTH have arrived, so the two must always
/// be sent as a pair.
class RpcResponse {
  const RpcResponse({
    required this.id,
    required this.ok,
    this.data,
    this.error,
    this.tookMs = 0,
    this.binaryMime,
    this.binaryName,
    this.binaryLength,
  });

  final String id;
  final bool ok;
  final Object? data;
  final String? error;
  final int tookMs;
  final String? binaryMime;
  final String? binaryName;
  final int? binaryLength;

  factory RpcResponse.ok(String id, Object? data, int tookMs) =>
      RpcResponse(id: id, ok: true, data: data, tookMs: tookMs);

  factory RpcResponse.failure(String id, String error, int tookMs) =>
      RpcResponse(id: id, ok: false, error: error, tookMs: tookMs);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': 'response',
        'id': id,
        'ok': ok,
        if (data != null) 'data': data,
        if (error != null) 'error': error,
        'took_ms': tookMs,
        if (binaryMime != null)
          'binary': <String, dynamic>{
            'mime': binaryMime,
            if (binaryName != null) 'name': binaryName,
            if (binaryLength != null) 'bytes': binaryLength,
          },
      };

  String encode() => jsonEncode(toJson());
}

/// Build the `hello` frame. Only used when the client cannot set upgrade headers;
/// the bridge accepts either path, and we send both belt and braces.
String encodeHello({
  required String deviceId,
  String? appVersion,
  int? buildNumber,
}) =>
    jsonEncode(<String, dynamic>{
      'type': 'hello',
      'device_id': deviceId,
      if (appVersion != null) 'app_version': appVersion,
      if (buildNumber != null) 'build_number': buildNumber,
    });

String encodeHeartbeat() => jsonEncode(<String, dynamic>{
      'type': 'heartbeat',
      'ts': DateTime.now().millisecondsSinceEpoch,
    });

/// An unsolicited notification to the bridge (screen changed, gate refused something).
String encodeEvent(String event, [Object? data]) => jsonEncode(<String, dynamic>{
      'type': 'event',
      'event': event,
      if (data != null) 'data': data,
    });

/// Encode a binary payload frame correlated to [id].
///
/// The 4-byte big-endian header length is what lets the bridge find the JSON header
/// without scanning for a delimiter that could occur inside the payload.
Uint8List encodeBinaryFrame({
  required String id,
  required String mime,
  String? name,
  required Uint8List payload,
}) {
  final header = utf8.encode(jsonEncode(<String, dynamic>{
    'id': id,
    'mime': mime,
    if (name != null) 'name': name,
  }));
  final out = BytesBuilder(copy: false);
  final len = ByteData(4)..setUint32(0, header.length, Endian.big);
  out.add(len.buffer.asUint8List());
  out.add(header);
  out.add(payload);
  return out.takeBytes();
}

/// Decoded binary frame — only used by the tests on this side; the phone sends
/// binary, it never receives it.
({String id, String mime, String? name, Uint8List payload}) decodeBinaryFrame(Uint8List buf) {
  if (buf.length < 4) {
    throw const FormatException('binary frame too short for a header length');
  }
  final h = ByteData.sublistView(buf, 0, 4).getUint32(0, Endian.big);
  if (h <= 0 || 4 + h > buf.length) {
    throw const FormatException('binary frame header length out of range');
  }
  final header = jsonDecode(utf8.decode(buf.sublist(4, 4 + h))) as Map<String, dynamic>;
  final id = header['id'];
  final mime = header['mime'];
  if (id is! String || mime is! String) {
    throw const FormatException('binary frame header must carry {id, mime}');
  }
  return (
    id: id,
    mime: mime,
    name: header['name'] as String?,
    payload: Uint8List.sublistView(buf, 4 + h),
  );
}
