// protocol_test.dart — the wire contract with the bridge (ADR-4, PHASE-P2 B12).
//
// These assertions are deliberately about BYTES and FIELD NAMES, not about Dart
// ergonomics. The bridge parses what this file produces; a rename here that looks
// harmless is a phone that silently stops working, because the failure mode of a
// protocol mismatch is a mission that does nothing rather than an error anyone sees.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/bridge/protocol.dart';

void main() {
  group('RpcRequest', () {
    test('parses a well-formed request frame', () {
      final r = RpcRequest.fromJson(<String, dynamic>{
        'type': 'request',
        'id': 'req-1',
        'method': 'device_tap',
        'params': <String, dynamic>{'x': 10, 'y': 20},
        'timeout_ms': 15000,
      });
      expect(r.id, 'req-1');
      expect(r.method, 'device_tap');
      expect(r.params['x'], 10);
      expect(r.timeoutMs, 15000);
    });

    test('tolerates a missing params block', () {
      final r = RpcRequest.fromJson(<String, dynamic>{
        'type': 'request',
        'id': 'req-2',
        'method': 'device_status',
      });
      expect(r.params, isEmpty);
      expect(r.timeoutMs, isNull);
    });

    test('rejects a frame with no id or no method', () {
      expect(
        () => RpcRequest.fromJson(<String, dynamic>{'type': 'request', 'method': 'x'}),
        throwsFormatException,
      );
      expect(
        () => RpcRequest.fromJson(<String, dynamic>{'type': 'request', 'id': 'a'}),
        throwsFormatException,
      );
    });
  });

  group('RpcResponse envelope (ADR-4 D3)', () {
    test('a success carries ok/data/took_ms and no error key', () {
      final json = jsonDecode(RpcResponse.ok('r1', <String, dynamic>{'a': 1}, 42).encode())
          as Map<String, dynamic>;
      expect(json['type'], 'response');
      expect(json['id'], 'r1');
      expect(json['ok'], isTrue);
      expect(json['data'], <String, dynamic>{'a': 1});
      expect(json['took_ms'], 42);
      expect(json.containsKey('error'), isFalse);
    });

    test('a failure carries ok:false and an error string', () {
      final json = jsonDecode(RpcResponse.failure('r2', 'device_offline', 7).encode())
          as Map<String, dynamic>;
      expect(json['ok'], isFalse);
      expect(json['error'], 'device_offline');
      expect(json['took_ms'], 7);
      expect(json.containsKey('data'), isFalse);
    });

    test('a binary announcement uses the exact field names the bridge reads', () {
      final json = jsonDecode(const RpcResponse(
        id: 'r3',
        ok: true,
        data: <String, dynamic>{'mime': 'image/png'},
        tookMs: 900,
        binaryMime: 'image/png',
        binaryName: 'screen.png',
        binaryLength: 1234,
      ).encode()) as Map<String, dynamic>;

      final bin = json['binary'] as Map<String, dynamic>;
      expect(bin['mime'], 'image/png');
      expect(bin['name'], 'screen.png');
      expect(bin['bytes'], 1234);
    });

    test('no `binary` key at all when there is no payload', () {
      final json = jsonDecode(RpcResponse.ok('r4', null, 1).encode()) as Map<String, dynamic>;
      expect(json.containsKey('binary'), isFalse);
    });
  });

  group('binary frames (ADR-4 D3)', () {
    test('round-trips a payload with its id and mime', () {
      final payload = Uint8List.fromList(List<int>.generate(5000, (i) => i % 256));
      final frame = encodeBinaryFrame(
        id: 'req-9',
        mime: 'image/png',
        name: 'screen.png',
        payload: payload,
      );
      final decoded = decodeBinaryFrame(frame);
      expect(decoded.id, 'req-9');
      expect(decoded.mime, 'image/png');
      expect(decoded.name, 'screen.png');
      expect(decoded.payload, payload);
    });

    test('the first four bytes are a big-endian header length', () {
      final frame = encodeBinaryFrame(
        id: 'x',
        mime: 'image/png',
        payload: Uint8List.fromList(<int>[1, 2, 3]),
      );
      final headerLen = ByteData.sublistView(frame, 0, 4).getUint32(0, Endian.big);
      final header = jsonDecode(utf8.decode(frame.sublist(4, 4 + headerLen)))
          as Map<String, dynamic>;
      expect(header['id'], 'x');
      expect(header['mime'], 'image/png');
      // The payload sits immediately after the header, unencoded.
      expect(frame.sublist(4 + headerLen), <int>[1, 2, 3]);
    });

    test('a payload containing the header delimiter is still parsed correctly', () {
      // This is why the length prefix exists rather than scanning for a separator:
      // real PNG bytes will contain braces, quotes and nulls.
      final nasty = Uint8List.fromList(utf8.encode('}{"id":"spoof","mime":"x"}'));
      final decoded = decodeBinaryFrame(
        encodeBinaryFrame(id: 'real', mime: 'image/png', payload: nasty),
      );
      expect(decoded.id, 'real');
      expect(decoded.payload, nasty);
    });

    test('an empty payload is legal', () {
      final decoded = decodeBinaryFrame(
        encodeBinaryFrame(id: 'e', mime: 'image/png', payload: Uint8List(0)),
      );
      expect(decoded.payload, isEmpty);
    });

    test('a truncated or corrupt frame throws rather than returning garbage', () {
      expect(() => decodeBinaryFrame(Uint8List.fromList(<int>[1, 2])), throwsFormatException);
      final bad = Uint8List(8);
      ByteData.sublistView(bad, 0, 4).setUint32(0, 9999, Endian.big);
      expect(() => decodeBinaryFrame(bad), throwsFormatException);
    });
  });

  group('outbound frames', () {
    test('hello carries the identity the bridge registers', () {
      final json = jsonDecode(encodeHello(
        deviceId: 'a20e',
        appVersion: '0.2.0',
        buildNumber: 12,
      )) as Map<String, dynamic>;
      expect(json['type'], 'hello');
      expect(json['device_id'], 'a20e');
      expect(json['app_version'], '0.2.0');
      expect(json['build_number'], 12);
    });

    test('heartbeat is typed and timestamped', () {
      final json = jsonDecode(encodeHeartbeat()) as Map<String, dynamic>;
      expect(json['type'], 'heartbeat');
      expect(json['ts'], isA<int>());
    });

    test('event carries a name and optional data', () {
      final json = jsonDecode(encodeEvent('gate_signature_rejected', <String, dynamic>{
        'op': 'device_double_tap',
        'reason': 'missing_signature',
      })) as Map<String, dynamic>;
      expect(json['type'], 'event');
      expect(json['event'], 'gate_signature_rejected');
      expect((json['data'] as Map)['reason'], 'missing_signature');
    });
  });

  group('timings match the bridge', () {
    test('heartbeat is 15 s — the bridge closes the socket at 45 s', () {
      expect(heartbeatInterval, const Duration(seconds: 15));
    });

    test('reconnect backoff is bounded', () {
      expect(reconnectMinDelay.inMilliseconds, greaterThan(0));
      expect(reconnectMaxDelay, greaterThan(reconnectMinDelay));
      expect(reconnectMaxDelay.inMinutes, lessThanOrEqualTo(5));
    });

    test('the handshake header names are the ones the bridge reads', () {
      expect(headerAuthorization, 'Authorization');
      expect(headerDeviceId, 'x-device-id');
      expect(headerAppVersion, 'x-app-version');
      expect(headerBuildNumber, 'x-build-number');
    });
  });
}
