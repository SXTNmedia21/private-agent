// bridge_socket_test.dart — the supersede loop, and why 4409 must not be retried.
//
// This is a regression test for a live incident. The handset connected, held the socket
// for about a second, redialled, and did it again roughly every 1.25 s for as long as
// anyone watched. Fast calls still worked, so the phone looked healthy; anything slower
// than a second — `device_logs`, any real mission step — timed out.
//
// The mechanism: the bridge allows one socket per device and closes the older one with
// 4409 when a newer arrives. The phone treated that close like any other and reconnected,
// which superseded the socket that had just replaced it, whose close then triggered
// another reconnect. Once two sockets overlapped even once, the phone spent forever
// killing its own working connection.
//
// The two properties below are what stop it. Both are asserted against a fake connector,
// so the loop is reproducible on a laptop rather than only on a phone at 1.25 s intervals.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:private_agent/bridge/bridge_socket.dart';
import 'package:private_agent/bridge/device_channel.dart';
import 'package:private_agent/bridge/rpc_handlers.dart';

/// A channel we can close from the test with any code we like.
class _FakeChannel extends StreamChannelMixin<dynamic> implements WebSocketChannel {
  _FakeChannel();

  final _incoming = StreamController<dynamic>.broadcast();
  final _sent = <dynamic>[];
  bool closed = false;
  int? _closeCode;
  String? _closeReason;

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _FakeSink(this);

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => _closeReason;

  List<dynamic> get sent => _sent;

  /// Simulate the bridge closing this socket, e.g. with 4409.
  Future<void> serverClose(int code, String reason) async {
    _closeCode = code;
    _closeReason = reason;
    closed = true;
    await _incoming.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._c);
  final _FakeChannel _c;

  @override
  void add(dynamic data) => _c._sent.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    _c.closed = true;
    if (!_c._incoming.isClosed) await _c._incoming.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late List<_FakeChannel> opened;

  BridgeSocket build() {
    opened = <_FakeChannel>[];
    return BridgeSocket(
      handlers: RpcHandlers(
        channel: DeviceChannel(),
        deviceSecret: () => 'secret',
      ),
      connector: (uri, headers) async {
        final c = _FakeChannel();
        opened.add(c);
        return c;
      },
    );
  }

  Future<void> configure(BridgeSocket s) => s.configure(
        baseUrl: 'https://bridge.example',
        token: 't' * 48,
        deviceId: 'a20e',
        enabled: true,
      );

  test('being superseded (4409) does NOT trigger a reconnect', () async {
    final s = build();
    await configure(s);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(opened.length, 1, reason: 'one dial to begin with');

    // The bridge replaced us with a newer connection for the same device id.
    await opened.first.serverClose(4409, 'superseded by a new connection');

    // Well past reconnectMinDelay (1 s). A redial here is the loop.
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    expect(
      opened.length,
      1,
      reason: 'the connection that superseded us is the live one — redialling fights it',
    );

    s.dispose();
  });

  test('an ordinary close still reconnects — the fix must not disable recovery', () async {
    final s = build();
    await configure(s);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(opened.length, 1);

    // A network drop, not a supersede.
    await opened.first.serverClose(1006, 'abnormal closure');

    await Future<void>.delayed(const Duration(milliseconds: 1600));
    expect(opened.length, 2, reason: 'a genuine drop must still be recovered from');

    s.dispose();
  });

  test('a reconnect never dials on top of a live socket', () async {
    // The other half of the fix: even if some path calls connect while a channel is open,
    // the old one is torn down first, so an orphan socket the bridge would supersede
    // cannot exist.
    final s = build();
    await configure(s);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final first = opened.first;
    expect(first.closed, isFalse);

    // Re-configuring is the one path a user can trigger at will (a Settings save).
    await configure(s);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(first.closed, isTrue, reason: 'the previous socket was closed, not abandoned');
    expect(opened.length, 2);

    s.dispose();
  });
}
