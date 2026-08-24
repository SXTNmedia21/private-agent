/// One handler per `device_*` primitive (API-MANIFEST §1).
///
/// This is the whole brain the phone has left: receive one typed call, do exactly
/// that one thing, report what was observed. No planning, no loop, no deciding what
/// comes next — that lives on the bridge (ADR-2).
///
/// Two rules hold for every handler:
///   1. It never throws. A failure is `RpcResponse.failure`, because the bridge is
///      waiting on this id and a swallowed exception becomes a 30 s timeout.
///   2. A gated op is checked by `gate.dart` BEFORE the native call. The bridge
///      also refuses ungated calls, but the phone does not take the bridge's word
///      for it (ADR-3 D4).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:installed_apps/installed_apps.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'device_channel.dart';
import 'gate.dart';
import 'protocol.dart';

/// What a handler produced: the JSON half, plus optional bytes for a binary frame.
class HandlerOutcome {
  const HandlerOutcome(this.response, {this.binary});
  final RpcResponse response;
  final Uint8List? binary;
}

typedef GateEventSink = void Function(String event, Map<String, dynamic> data);

class RpcHandlers {
  RpcHandlers({
    required DeviceChannel channel,
    required String? Function() deviceSecret,
    GateEventSink? onGateRefusal,
    int Function()? clock,
  })  : _c = channel,
        _deviceSecret = deviceSecret,
        _onGateRefusal = onGateRefusal,
        _now = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final DeviceChannel _c;
  final String? Function() _deviceSecret;
  final GateEventSink? _onGateRefusal;
  final int Function() _now;

  /// The methods this build can execute — all 33 `device_*` tools the bridge
  /// advertises, complete as of build-13. Anything absent from this set is
  /// reported as unimplemented rather than silently succeeding.
  static const Set<String> implemented = <String>{
    'device_status', 'device_get_screen_state', 'device_find', 'device_node_details',
    'device_screenshot', 'device_pixel',
    'device_tap', 'device_double_tap', 'device_long_press', 'device_swipe',
    'device_pinch', 'device_gesture',
    'device_type_text', 'device_press', 'device_wait_for',
    'device_open_app', 'device_close_app', 'device_list_apps', 'device_open_url',
    'device_send_intent',
    'device_notifications', 'device_notification_reply', 'device_notification_action',
    'device_clipboard', 'device_logs',
    'device_list_files', 'device_read_file', 'device_write_file',
    'device_download_from_url', 'device_share_file',
    'device_record_start', 'device_record_stop', 'device_record_status',
  };

  Future<HandlerOutcome> dispatch(RpcRequest req) async {
    final started = _now();
    int elapsed() => _now() - started;

    // The hard gate runs first, before anything touches the screen.
    if (requiresHardGate(req.method, req.params)) {
      final verdict = verifyHardGate(
        method: req.method,
        params: req.params,
        deviceSecret: _deviceSecret(),
        nowMs: _now(),
      );
      if (!verdict.allowed) {
        _onGateRefusal?.call('gate_signature_rejected', <String, dynamic>{
          'op': req.method,
          'reason': verdict.reason,
        });
        return HandlerOutcome(RpcResponse(
          id: req.id,
          ok: false,
          error: 'gate_signature_rejected',
          data: <String, dynamic>{'reason': verdict.reason, 'op': req.method},
          tookMs: elapsed(),
        ));
      }
    }

    try {
      return await _run(req, elapsed);
    } catch (e) {
      // Belt and braces: a handler bug must still answer the bridge.
      return HandlerOutcome(RpcResponse.failure(req.id, 'handler_error: $e', elapsed()));
    }
  }

  Future<HandlerOutcome> _run(RpcRequest req, int Function() elapsed) async {
    final p = req.params;

    HandlerOutcome done(NativeResult<Map<String, dynamic>> r) => HandlerOutcome(
          r.ok
              ? RpcResponse.ok(req.id, r.value ?? <String, dynamic>{}, elapsed())
              : RpcResponse.failure(req.id, '${r.error}: ${r.message}', elapsed()),
        );

    switch (req.method) {
      // ---- perception --------------------------------------------------
      case 'device_status':
        return done(await _c.status());

      case 'device_get_screen_state':
        return done(await _c.screenState(
          maxNodes: _int(p['max_nodes']),
          interactiveOnly: p['interactive_only'] as bool?,
        ));

      case 'device_find':
        return done(await _c.find(
          text: p['text'] as String?,
          id: p['id'] as String?,
          className: p['class'] as String?,
          exact: p['exact'] as bool?,
        ));

      case 'device_node_details':
        final nodeId = p['node_id'];
        if (nodeId is! String) {
          return HandlerOutcome(RpcResponse.failure(req.id, 'node_id is required', elapsed()));
        }
        return done(await _c.nodeDetails(nodeId));

      case 'device_screenshot':
        final shot = await _c.screenshot(scale: _double(p['scale']));
        if (!shot.ok) {
          return HandlerOutcome(
            RpcResponse.failure(req.id, '${shot.error}: ${shot.message}', elapsed()),
          );
        }
        final bytes = shot.value!;
        return HandlerOutcome(
          RpcResponse(
            id: req.id,
            ok: true,
            data: <String, dynamic>{
              'mime': 'image/png',
              'bytes': bytes.length,
              'scale': _double(p['scale']) ?? 0.5,
            },
            tookMs: elapsed(),
            binaryMime: 'image/png',
            binaryName: 'screen.png',
            binaryLength: bytes.length,
          ),
          binary: bytes,
        );

      case 'device_pixel':
        final x = _int(p['x']);
        final y = _int(p['y']);
        if (x == null || y == null) {
          return HandlerOutcome(RpcResponse.failure(req.id, 'x and y are required', elapsed()));
        }
        return done(await _c.pixel(x, y));

      // ---- touch -------------------------------------------------------
      case 'device_tap':
        return done(await _c.tap(_target(p)));

      case 'device_double_tap':
        return done(await _c.doubleTap(_target(p)));

      case 'device_long_press':
        return done(await _c.longPress(<String, dynamic>{
          ..._target(p),
          if (p['duration_ms'] != null) 'duration_ms': _int(p['duration_ms']),
        }));

      case 'device_swipe':
        return done(await _c.swipe(<String, dynamic>{
          if (p['direction'] != null) 'direction': p['direction'],
          if (p['distance'] != null) 'distance': _int(p['distance']),
          if (p['from'] != null) 'from': p['from'],
          if (p['to'] != null) 'to': p['to'],
          if (p['duration_ms'] != null) 'duration_ms': _int(p['duration_ms']),
        }));

      case 'device_pinch':
        return done(await _c.pinch(<String, dynamic>{
          'direction': p['direction'] ?? 'out',
          if (p['scale'] != null) 'scale': _double(p['scale']),
          if (p['x'] != null) 'x': _int(p['x']),
          if (p['y'] != null) 'y': _int(p['y']),
        }));

      case 'device_gesture':
        return done(await _c.gesture(<String, dynamic>{
          'path': p['path'] ?? const <dynamic>[],
          if (p['duration_ms'] != null) 'duration_ms': _int(p['duration_ms']),
        }));

      // ---- input -------------------------------------------------------
      case 'device_type_text':
        final text = p['text'];
        if (text is! String) {
          return HandlerOutcome(RpcResponse.failure(req.id, 'text is required', elapsed()));
        }
        return done(await _c.typeText(<String, dynamic>{
          'text': text,
          if (p['node_id'] != null) 'node_id': p['node_id'],
          if (p['mode'] != null) 'mode': p['mode'],
          if (p['submit'] != null) 'submit': p['submit'],
        }));

      case 'device_press':
        final key = p['key'];
        if (key is! String) {
          return HandlerOutcome(RpcResponse.failure(req.id, 'key is required', elapsed()));
        }
        return done(await _c.press(key));

      case 'device_wait_for':
        return done(await _c.waitFor(<String, dynamic>{
          if (p['text'] != null) 'text': p['text'],
          if (p['node'] != null) 'node': p['node'],
          if (p['idle'] != null) 'idle': p['idle'],
          if (p['timeout_ms'] != null) 'timeout_ms': _int(p['timeout_ms']),
        }));

      // ---- apps --------------------------------------------------------
      case 'device_open_app':
        return HandlerOutcome(await _openApp(req, p, elapsed));

      case 'device_close_app':
        final pkg = p['package'];
        if (pkg is! String) {
          return HandlerOutcome(
            RpcResponse.failure(req.id, 'package is required', elapsed()),
          );
        }
        return done(await _c.closeApp(pkg));

      case 'device_list_apps':
        return HandlerOutcome(await _listApps(req, p, elapsed));

      case 'device_open_url':
        return HandlerOutcome(await _openUrl(req, p, elapsed));

      case 'device_send_intent':
        return done(await _c.sendIntent(<String, dynamic>{
          'action': p['action'] ?? '',
          if (p['package'] != null) 'package': p['package'],
          if (p['component'] != null) 'component': p['component'],
          if (p['data'] != null) 'data': p['data'],
          if (p['extras'] != null) 'extras': p['extras'],
        }));

      // ---- notifications -----------------------------------------------
      case 'device_notifications':
        return done(await _c.notifications(<String, dynamic>{
          'action': p['action'] ?? 'list',
          if (p['id'] != null) 'id': p['id'],
          if (p['snooze_ms'] != null) 'snooze_ms': _int(p['snooze_ms']),
        }));

      case 'device_notification_reply':
        return done(await _c.notificationReply(
          (p['id'] ?? '').toString(),
          (p['text'] ?? '').toString(),
        ));

      case 'device_notification_action':
        return done(await _c.notificationAction(
          (p['id'] ?? '').toString(),
          (p['action'] ?? '').toString(),
        ));

      // ---- data --------------------------------------------------------
      case 'device_clipboard':
        return done(await _c.clipboard(
          (p['action'] ?? 'get').toString(),
          text: p['text'] as String?,
        ));

      case 'device_logs':
        return done(await _c.logs(lines: _int(p['lines'])));

      // ---- files (Dart-side; the scoped dir is app-private) --------------
      case 'device_list_files':
        return HandlerOutcome(await _listFiles(req, p, elapsed));

      case 'device_read_file':
        return HandlerOutcome(await _readFile(req, p, elapsed));

      case 'device_write_file':
        return HandlerOutcome(await _writeFile(req, p, elapsed));

      case 'device_download_from_url':
        return HandlerOutcome(await _downloadFromUrl(req, p, elapsed));

      case 'device_share_file':
        // Gated above. Native builds the share intent properly — see DeviceChannel.
        // The path is resolved and scope-checked HERE, so a path that escapes the
        // bridge directory never reaches the platform at all.
        final target = await _resolveScoped((p['path'] ?? '').toString());
        if (target == null) {
          return HandlerOutcome(
            RpcResponse.failure(req.id, 'path_escapes_scope', elapsed()),
          );
        }
        if (!await target.exists()) {
          return HandlerOutcome(
            RpcResponse.failure(req.id, 'no such file: ${p['path']}', elapsed()),
          );
        }
        return done(await _c.shareFile(
          path: target.path,
          package: p['package'] as String?,
          mime: p['mime'] as String?,
        ));

      // ---- recording (P6) ----------------------------------------------
      //
      // The one primitive that is not fully remote. MediaProjection needs a human to tap a
      // system dialog and it cannot be granted any other way, so a missing consent is
      // surfaced as its own error rather than dressed up as a transient failure.
      case 'device_record_start':
        final rec = await _c.recordStart(
          maxS: _int(p['max_s']),
          scale: _double(p['scale']),
        );
        if (!rec.ok) {
          return HandlerOutcome(
            RpcResponse.failure(req.id, '${rec.error}: ${rec.message}', elapsed()),
          );
        }
        return done(rec);

      case 'device_record_status':
        return done(await _c.recordStatus());

      case 'device_record_stop':
        final out = await _c.recordStop();
        if (!out.ok) {
          return HandlerOutcome(
            RpcResponse.failure(req.id, '${out.error}: ${out.message}', elapsed()),
          );
        }
        final mp4 = out.value!;
        return HandlerOutcome(
          RpcResponse(
            id: req.id,
            ok: true,
            data: <String, dynamic>{
              'mime': 'video/mp4',
              'bytes': mp4.length,
            },
            tookMs: elapsed(),
            binaryMime: 'video/mp4',
            binaryName: 'recording.mp4',
            binaryLength: mp4.length,
          ),
          binary: mp4,
        );

      default:
        return HandlerOutcome(
          RpcResponse.failure(req.id, 'unimplemented_on_device: ${req.method}', elapsed()),
        );
    }
  }

  // ---- app helpers --------------------------------------------------------

  /// Language-proof alias map. A Swedish handset shows "Inställningar", not
  /// "Settings", and system apps are invisible to `getInstalledApps`, so
  /// launching by package is the only reliable path for them.
  static const Map<String, String> _aliases = <String, String>{
    'settings': 'com.android.settings',
    'play store': 'com.android.vending',
    'google play': 'com.android.vending',
    'youtube': 'com.google.android.youtube',
    'instagram': 'com.instagram.android',
    'whatsapp': 'com.whatsapp',
    'chrome': 'com.android.chrome',
    'browser': 'com.android.chrome',
    'gmail': 'com.google.android.gm',
    'maps': 'com.google.android.apps.maps',
    'google maps': 'com.google.android.apps.maps',
    'camera': 'com.android.camera',
    'phone': 'com.android.dialer',
    'dialer': 'com.android.dialer',
    'messages': 'com.google.android.apps.messaging',
    'clock': 'com.android.deskclock',
    'calendar': 'com.google.android.calendar',
    'photos': 'com.google.android.apps.photos',
    'files': 'com.google.android.documentsui',
    'facebook': 'com.facebook.katana',
    'spotify': 'com.spotify.music',
    'tiktok': 'com.zhiliaoapp.musically',
    'telegram': 'org.telegram.messenger',
    'x': 'com.twitter.android',
    'twitter': 'com.twitter.android',
    'linkedin': 'com.linkedin.android',
  };

  Future<RpcResponse> _openApp(
    RpcRequest req,
    Map<String, dynamic> p,
    int Function() elapsed,
  ) async {
    final pkg = p['package'] as String?;
    final name = p['name'] as String?;
    try {
      if (pkg != null && pkg.isNotEmpty) {
        final ok = await InstalledApps.startApp(pkg);
        return RpcResponse.ok(
          req.id,
          <String, dynamic>{'ok': ok != false, 'package': pkg},
          elapsed(),
        );
      }
      if (name == null || name.trim().isEmpty) {
        return RpcResponse.failure(req.id, 'name or package is required', elapsed());
      }
      final key = name.toLowerCase().trim();
      final alias = _aliases[key];
      if (alias != null) {
        try {
          final ok = await InstalledApps.startApp(alias);
          if (ok != false) {
            return RpcResponse.ok(
              req.id,
              <String, dynamic>{'ok': true, 'package': alias, 'resolved_by': 'alias'},
              elapsed(),
            );
          }
        } catch (_) {
          // Not installed on this handset — fall through to a fuzzy match.
        }
      }
      final apps = await InstalledApps.getInstalledApps(false, false);
      final matches = apps.where((a) => a.name.toLowerCase().contains(key)).toList();
      if (matches.isEmpty) {
        return RpcResponse.failure(req.id, 'app_not_found: $name', elapsed());
      }
      final exact = matches.firstWhere(
        (a) => a.name.toLowerCase() == key,
        orElse: () => matches.first,
      );
      await InstalledApps.startApp(exact.packageName);
      return RpcResponse.ok(
        req.id,
        <String, dynamic>{
          'ok': true,
          'package': exact.packageName,
          'label': exact.name,
          'resolved_by': 'name',
        },
        elapsed(),
      );
    } catch (e) {
      return RpcResponse.failure(req.id, 'open_app_failed: $e', elapsed());
    }
  }

  Future<RpcResponse> _listApps(
    RpcRequest req,
    Map<String, dynamic> p,
    int Function() elapsed,
  ) async {
    try {
      final apps = await InstalledApps.getInstalledApps(false, false);
      final filter = (p['filter'] as String?)?.toLowerCase();
      final list = apps
          .where((a) => filter == null || a.name.toLowerCase().contains(filter))
          .map((a) => <String, dynamic>{'package': a.packageName, 'label': a.name})
          .toList();
      return RpcResponse.ok(
        req.id,
        <String, dynamic>{'apps': list, 'count': list.length},
        elapsed(),
      );
    } catch (e) {
      return RpcResponse.failure(req.id, 'list_apps_failed: $e', elapsed());
    }
  }

  Future<RpcResponse> _openUrl(
    RpcRequest req,
    Map<String, dynamic> p,
    int Function() elapsed,
  ) async {
    final url = p['url'];
    if (url is! String || url.isEmpty) {
      return RpcResponse.failure(req.id, 'url is required', elapsed());
    }
    try {
      final uri = Uri.parse(url);
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      return RpcResponse.ok(req.id, <String, dynamic>{'ok': ok, 'url': url}, elapsed());
    } catch (e) {
      return RpcResponse.failure(req.id, 'open_url_failed: $e', elapsed());
    }
  }

  // ---- file helpers -------------------------------------------------------

  /// Everything file-related is confined to one app-private directory. A path that
  /// escapes it is refused rather than clamped — silently rewriting a caller's path
  /// is how you end up reading the wrong file and never noticing.
  Future<Directory> _scopedDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/bridge');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File?> _resolveScoped(String relative) async {
    final dir = await _scopedDir();
    final candidate = File('${dir.path}/$relative').absolute;
    final normalisedRoot = Directory(dir.path).absolute.path;
    if (!candidate.path.startsWith('$normalisedRoot/')) return null;
    return candidate;
  }

  Future<RpcResponse> _listFiles(
    RpcRequest req,
    Map<String, dynamic> p,
    int Function() elapsed,
  ) async {
    try {
      final sub = (p['path'] ?? '').toString();
      final dir = sub.isEmpty
          ? await _scopedDir()
          : Directory((await _resolveScoped(sub))?.path ?? '');
      if (sub.isNotEmpty && dir.path.isEmpty) {
        return RpcResponse.failure(req.id, 'path_escapes_scope', elapsed());
      }
      if (!await dir.exists()) {
        return RpcResponse.ok(req.id, <String, dynamic>{'files': <dynamic>[]}, elapsed());
      }
      final entries = <Map<String, dynamic>>[];
      await for (final e in dir.list()) {
        final stat = await e.stat();
        entries.add(<String, dynamic>{
          'name': e.uri.pathSegments.where((s) => s.isNotEmpty).last,
          'is_dir': stat.type == FileSystemEntityType.directory,
          'bytes': stat.size,
          'modified_at': stat.modified.millisecondsSinceEpoch,
        });
      }
      return RpcResponse.ok(
        req.id,
        <String, dynamic>{'files': entries, 'dir': dir.path},
        elapsed(),
      );
    } catch (e) {
      return RpcResponse.failure(req.id, 'list_files_failed: $e', elapsed());
    }
  }

  Future<RpcResponse> _readFile(
    RpcRequest req,
    Map<String, dynamic> p,
    int Function() elapsed,
  ) async {
    final rel = p['path'];
    if (rel is! String || rel.isEmpty) {
      return RpcResponse.failure(req.id, 'path is required', elapsed());
    }
    final file = await _resolveScoped(rel);
    if (file == null) return RpcResponse.failure(req.id, 'path_escapes_scope', elapsed());
    if (!await file.exists()) {
      return RpcResponse.failure(req.id, 'file_not_found: $rel', elapsed());
    }
    try {
      final bytes = await file.readAsBytes();
      final encoding = (p['encoding'] ?? 'utf8').toString();
      return RpcResponse.ok(
        req.id,
        <String, dynamic>{
          'path': rel,
          'bytes': bytes.length,
          'encoding': encoding,
          'content': encoding == 'base64' ? base64Encode(bytes) : utf8.decode(bytes, allowMalformed: true),
        },
        elapsed(),
      );
    } catch (e) {
      return RpcResponse.failure(req.id, 'read_file_failed: $e', elapsed());
    }
  }

  Future<RpcResponse> _writeFile(
    RpcRequest req,
    Map<String, dynamic> p,
    int Function() elapsed,
  ) async {
    final rel = p['path'];
    final content = p['content'];
    if (rel is! String || rel.isEmpty || content is! String) {
      return RpcResponse.failure(req.id, 'path and content are required', elapsed());
    }
    final file = await _resolveScoped(rel);
    if (file == null) return RpcResponse.failure(req.id, 'path_escapes_scope', elapsed());
    try {
      await file.parent.create(recursive: true);
      final encoding = (p['encoding'] ?? 'utf8').toString();
      final bytes = encoding == 'base64' ? base64Decode(content) : utf8.encode(content);
      await file.writeAsBytes(bytes);
      return RpcResponse.ok(
        req.id,
        <String, dynamic>{'path': rel, 'bytes': bytes.length},
        elapsed(),
      );
    } catch (e) {
      return RpcResponse.failure(req.id, 'write_file_failed: $e', elapsed());
    }
  }

  Future<RpcResponse> _downloadFromUrl(
    RpcRequest req,
    Map<String, dynamic> p,
    int Function() elapsed,
  ) async {
    final url = p['url'];
    if (url is! String || url.isEmpty) {
      return RpcResponse.failure(req.id, 'url is required', elapsed());
    }
    final rel = (p['path'] ?? Uri.parse(url).pathSegments.last).toString();
    final file = await _resolveScoped(rel);
    if (file == null) return RpcResponse.failure(req.id, 'path_escapes_scope', elapsed());
    HttpClient? client;
    try {
      client = HttpClient();
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode >= 400) {
        return RpcResponse.failure(req.id, 'download_failed: HTTP ${response.statusCode}', elapsed());
      }
      await file.parent.create(recursive: true);
      final sink = file.openWrite();
      await response.pipe(sink);
      final size = await file.length();
      return RpcResponse.ok(
        req.id,
        <String, dynamic>{'path': rel, 'bytes': size, 'status': response.statusCode},
        elapsed(),
      );
    } catch (e) {
      return RpcResponse.failure(req.id, 'download_failed: $e', elapsed());
    } finally {
      client?.close();
    }
  }

  // ---- coercion -----------------------------------------------------------

  static Map<String, dynamic> _target(Map<String, dynamic> p) => <String, dynamic>{
        if (p['x'] != null) 'x': _int(p['x']),
        if (p['y'] != null) 'y': _int(p['y']),
        if (p['node_id'] != null) 'node_id': p['node_id'],
        if (p['text'] != null) 'text': p['text'],
      };

  static int? _int(Object? v) {
    if (v is int) return v;
    if (v is double) return v.round();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static double? _double(Object? v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }
}
