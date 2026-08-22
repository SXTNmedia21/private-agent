// rpc_handlers_test.dart — the executor's dispatch contract (PHASE-P2 B8, B12).
//
// The native channel is mocked, so these assert what the DART side guarantees:
// every call answers, the gate runs before the screen is touched, and a gated op
// sends no native call at all. The real Android behaviour is a device criterion
// (B1–B5), not something a unit test can honestly claim.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/bridge/device_channel.dart';
import 'package:private_agent/bridge/gate.dart';
import 'package:private_agent/bridge/protocol.dart';
import 'package:private_agent/bridge/rpc_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.privateagent/device');
  late List<MethodCall> calls;
  late Map<String, Object?> replies;
  late Set<String> errors;

  void mockNative() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      if (errors.contains(call.method)) {
        throw PlatformException(code: 'SERVICE_NOT_RUNNING', message: 'accessibility off');
      }
      return replies[call.method];
    });
  }

  setUp(() {
    calls = <MethodCall>[];
    errors = <String>{};
    replies = <String, Object?>{
      'status': <Object?, Object?>{'accessibility_running': true, 'battery': 87},
      'screenState': <Object?, Object?>{
        'tsv': 'id\tclass\ttext\tdesc\tbounds\tclickable\tfocused',
        'screen_fp': 'fp-1',
        'node_count': 0,
        'foreground_app': 'com.instagram.android',
      },
      'tap': <Object?, Object?>{'ok': true, 'screen_fp': 'fp-2'},
      'doubleTap': <Object?, Object?>{'ok': true, 'screen_fp': 'fp-3'},
      'typeText': <Object?, Object?>{'ok': true, 'screen_fp': 'fp-4'},
      'press': <Object?, Object?>{'ok': true, 'screen_fp': 'fp-5'},
      'screenshot': Uint8List.fromList(List<int>.filled(2048, 7)),
      'notificationReply': <Object?, Object?>{'ok': true},
      'clipboard': <Object?, Object?>{'text': null, 'restricted': true},
      'screenRecordStart': <Object?, Object?>{'recording': true, 'max_s': 60, 'scale': 0.5},
      'screenRecordStatus': <Object?, Object?>{'recording': false, 'has_consent': false},
      'screenRecordStop': Uint8List.fromList(<int>[0, 0, 0, 24, 102, 116, 121, 112, 1, 2, 3]),
    };
    mockNative();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  RpcHandlers build({String? secret = 'test-secret', List<String>? events}) => RpcHandlers(
        channel: DeviceChannel(channel),
        deviceSecret: () => secret,
        onGateRefusal: events == null ? null : (e, d) => events.add('$e:${d['reason']}'),
      );

  RpcRequest req(String method, [Map<String, dynamic> params = const {}]) =>
      RpcRequest(id: 'r-$method', method: method, params: params);

  group('dispatch basics', () {
    test('a perception call reaches native and returns ok', () async {
      final out = await build().dispatch(req('device_get_screen_state'));
      expect(out.response.ok, isTrue);
      expect(calls.single.method, 'screenState');
      final data = out.response.data! as Map<String, dynamic>;
      expect(data['screen_fp'], 'fp-1');
    });

    test('a native PlatformException becomes an envelope, never a throw', () async {
      errors.add('status');
      final out = await build().dispatch(req('device_status'));
      expect(out.response.ok, isFalse);
      expect(out.response.error, contains('SERVICE_NOT_RUNNING'));
      // The bridge is waiting on this id — it must always get an answer.
      expect(out.response.id, 'r-device_status');
    });

    test('an unknown method answers instead of hanging', () async {
      final out = await build().dispatch(req('device_teleport'));
      expect(out.response.ok, isFalse);
      expect(out.response.error, contains('unimplemented_on_device'));
      expect(calls, isEmpty);
    });

    test('the recording trio is implemented now, and reaches native', () async {
      // Build-12 deferred these and said so. Build-13 must actually DISPATCH them: a
      // recording tool that answers ok without ever calling the platform channel would be
      // the same lie the deferral was written to avoid, wearing a success code.
      for (final m in const ['device_record_start', 'device_record_stop', 'device_record_status']) {
        calls.clear();
        final out = await build().dispatch(req(m));
        expect(RpcHandlers.implemented, contains(m));
        expect(out.response.error ?? '', isNot(contains('unimplemented_on_device')));
        expect(out.response.error ?? '', isNot(contains('not_implemented_until_p6')));
        expect(calls, isNotEmpty, reason: '$m must reach the native channel');
      }
    });

    test('a recording refused for want of consent reports THAT, not a generic failure', () async {
      // The single most confusing failure on this device: nothing is broken, a human simply
      // has not tapped the dialog. If that came back as a generic error someone would go
      // looking at the socket, the token and the accessibility service first.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        if (call.method == 'screenRecordStart') {
          throw PlatformException(
            code: 'RECORD_CONSENT_REQUIRED',
            message: 'Screen recording needs a one-time consent tap on the handset.',
          );
        }
        return replies[call.method];
      });
      final out = await build().dispatch(req('device_record_start'));
      expect(out.response.ok, isFalse);
      expect(out.response.error, contains('RECORD_CONSENT_REQUIRED'));
      expect(out.response.error, contains('one-time consent tap'));
    });

    test('a stopped recording comes back as an MP4 BINARY FRAME, never inside the JSON', () async {
      final out = await build().dispatch(req('device_record_stop'));
      expect(out.response.ok, isTrue);
      expect(out.binary, isNotNull);
      expect(out.binary!.length, (replies['screenRecordStop']! as Uint8List).length);
      expect(out.response.binaryMime, 'video/mp4');
      final data = out.response.data! as Map<String, dynamic>;
      expect(data['bytes'], out.binary!.length);
      // ADR-4 D3. A recording is far too large to ride in JSON, and the screenshot path
      // learned this the hard way when Uint8List was rebuilt as List<Object?>.
      expect(data.containsKey('base64'), isFalse);
      expect(data.containsKey('bytes_b64'), isFalse);
    });

    test('every advertised device_* method has a branch', () async {
      // A method in `implemented` that falls through to the default case would be a
      // tool the bridge offers and the phone silently cannot do.
      for (final m in RpcHandlers.implemented) {
        final out = await build().dispatch(req(m, _minimalArgsFor(m)));
        expect(
          out.response.error ?? '',
          isNot(contains('unimplemented_on_device')),
          reason: '$m is advertised but has no handler branch',
        );
      }
    });
  });

  group('the hard gate runs before anything touches the screen (B8)', () {
    test('device_double_tap with no signature is refused and sends NO native call', () async {
      final events = <String>[];
      final out = await build(events: events).dispatch(req('device_double_tap', {'node_id': 'n1'}));
      expect(out.response.ok, isFalse);
      expect(out.response.error, 'gate_signature_rejected');
      expect(calls, isEmpty, reason: 'a refused op must never reach the accessibility service');
      expect(events, <String>['gate_signature_rejected:missing_signature']);
    });

    test('device_notification_reply and device_share_file are equally refused', () async {
      for (final m in ['device_notification_reply', 'device_share_file']) {
        calls.clear();
        final out = await build().dispatch(req(m, {'id': 'x', 'text': 'hi', 'path': 'a.pdf'}));
        expect(out.response.error, 'gate_signature_rejected', reason: m);
        expect(calls, isEmpty, reason: m);
      }
    });

    test('device_type_text WITHOUT submit is not gated and does reach native', () async {
      final out = await build().dispatch(req('device_type_text', {'text': 'draft'}));
      expect(out.response.ok, isTrue);
      expect(calls.single.method, 'typeText');
    });

    test('device_type_text WITH submit is gated and reaches nothing', () async {
      final out = await build().dispatch(
        req('device_type_text', {'text': 'nice post!', 'submit': true}),
      );
      expect(out.response.error, 'gate_signature_rejected');
      expect(calls, isEmpty);
    });

    test('a correctly signed approval releases the op', () async {
      const secret = 'test-secret';
      final exp = DateTime.now().millisecondsSinceEpoch + 60000;
      final out = await build().dispatch(req('device_double_tap', <String, dynamic>{
        'node_id': 'n1',
        'approval': <String, dynamic>{
          'approval_id': 'a1',
          'target_hash': 'h1',
          'exp': exp,
          'op': 'device_double_tap',
          'signature': signPayload(
            deviceSecret: secret,
            op: 'device_double_tap',
            targetHash: 'h1',
            approvalId: 'a1',
            exp: exp,
          ),
        },
      }));
      expect(out.response.ok, isTrue);
      expect(calls.single.method, 'doubleTap');
    });

    test('with no device secret configured, even a signed op is refused', () async {
      final exp = DateTime.now().millisecondsSinceEpoch + 60000;
      final out = await build(secret: null).dispatch(req('device_double_tap', <String, dynamic>{
        'approval': <String, dynamic>{
          'approval_id': 'a1',
          'target_hash': 'h1',
          'exp': exp,
          'signature': 'whatever',
        },
      }));
      expect(out.response.error, 'gate_signature_rejected');
      expect((out.response.data! as Map)['reason'], 'no_device_secret');
      expect(calls, isEmpty);
    });
  });

  group('screenshot', () {
    test('returns raw bytes for a binary frame, not base64 in the JSON', () async {
      final out = await build().dispatch(req('device_screenshot', {'scale': 0.5}));
      expect(out.response.ok, isTrue);
      expect(out.binary, isNotNull);
      expect(out.binary!.length, 2048);
      expect(out.response.binaryMime, 'image/png');
      expect(out.response.binaryLength, 2048);

      // The JSON half announces the payload but must not contain it.
      final encoded = out.response.encode();
      expect(encoded.contains('BwcH'), isFalse);
      expect(encoded.length, lessThan(500));
    });

    test('a screenshot failure is an envelope with no binary attached', () async {
      errors.add('screenshot');
      final out = await build().dispatch(req('device_screenshot'));
      expect(out.response.ok, isFalse);
      expect(out.binary, isNull);
    });
  });

  group('argument handling', () {
    test('missing required arguments answer instead of throwing', () async {
      for (final m in ['device_node_details', 'device_press', 'device_open_url']) {
        final out = await build().dispatch(req(m));
        expect(out.response.ok, isFalse, reason: m);
        expect(out.response.error, isNotNull, reason: m);
      }
    });

    test('numeric arguments arriving as doubles are coerced for the native side', () async {
      await build().dispatch(req('device_tap', {'x': 10.0, 'y': 20.7}));
      final args = calls.single.arguments as Map<Object?, Object?>;
      expect(args['x'], 10);
      expect(args['y'], 21);
    });

    test('only the targeting keys that were supplied are forwarded', () async {
      await build().dispatch(req('device_tap', {'node_id': 'n5'}));
      final args = calls.single.arguments as Map<Object?, Object?>;
      expect(args.containsKey('node_id'), isTrue);
      expect(args.containsKey('x'), isFalse);
      expect(args.containsKey('text'), isFalse);
    });
  });
}

// Minimal valid-ish arguments so the completeness sweep exercises each branch
// rather than tripping on validation.
Map<String, dynamic> _minimalArgsFor(String method) => switch (method) {
      'device_node_details' => <String, dynamic>{'node_id': 'n1'},
      'device_type_text' => <String, dynamic>{'text': 'x'},
      'device_press' => <String, dynamic>{'key': 'back'},
      'device_open_url' => <String, dynamic>{'url': 'https://example.com'},
      'device_open_app' => <String, dynamic>{'package': 'com.example'},
      'device_close_app' => <String, dynamic>{'package': 'com.example'},
      'device_pixel' => <String, dynamic>{'x': 1, 'y': 1},
      'device_read_file' => <String, dynamic>{'path': 'a.txt'},
      'device_write_file' => <String, dynamic>{'path': 'a.txt', 'content': 'x'},
      'device_download_from_url' => <String, dynamic>{'url': 'https://example.com/a.bin'},
      'device_share_file' => <String, dynamic>{'path': 'a.pdf'},
      'device_notification_reply' => <String, dynamic>{'id': 'n', 'text': 't'},
      'device_notification_action' => <String, dynamic>{'id': 'n', 'action': 'a'},
      _ => const <String, dynamic>{},
    };
