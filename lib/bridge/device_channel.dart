/// Typed Dart wrapper over the native `com.privateagent/device` MethodChannel.
///
/// One job: turn PlatformExceptions into values. Every method here returns a
/// result rather than throwing, because the caller is an RPC handler whose reply
/// must always reach the bridge — a thrown exception would leave the bridge waiting
/// 30 s for a timeout on a call the phone already knows failed.
///
/// The native contract lives in `android/.../DeviceChannel.kt`. Error codes are
/// stable strings: SERVICE_NOT_RUNNING, STALE_NODE, NOT_FOUND, BAD_ARGS,
/// UNSUPPORTED_VERSION, SCREENSHOT_FAILED, NO_NOTIFICATION_ACCESS, NOT_IMPLEMENTED,
/// INTERNAL.
library;

import 'dart:typed_data';

import 'package:flutter/services.dart';

/// A native call that either produced a value or a stable error code.
class NativeResult<T> {
  const NativeResult.ok(this.value)
      : error = null,
        message = null;
  const NativeResult.failure(this.error, this.message) : value = null;

  final T? value;
  final String? error;
  final String? message;

  bool get ok => error == null;
}

class DeviceChannel {
  DeviceChannel([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel('com.privateagent/device');

  final MethodChannel _channel;

  /// Every call funnels through here so no PlatformException can escape into the
  /// socket loop and kill the connection over one bad primitive.
  Future<NativeResult<T>> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(method, args);
      if (raw == null) {
        // A void-ish native return is a success, not a null-pointer bug.
        return NativeResult<T>.ok(null as T);
      }
      return NativeResult<T>.ok(_coerce<T>(raw));
    } on PlatformException catch (e) {
      return NativeResult<T>.failure(e.code, e.message ?? e.code);
    } on MissingPluginException {
      return NativeResult<T>.failure(
        'NOT_IMPLEMENTED',
        'the native side does not implement $method — the APK is older than the bridge',
      );
    } catch (e) {
      return NativeResult<T>.failure('INTERNAL', e.toString());
    }
  }

  /// Platform channels hand back `Map<Object?, Object?>`; normalise once here so
  /// no handler has to remember to cast.
  ///
  /// TypedData is checked FIRST and passed through untouched. `Uint8List` is also a
  /// `List<int>`, so the generic list branch below would happily rebuild a screenshot
  /// as a `List<Object?>` and then fail the cast — turning every screenshot into an
  /// INTERNAL error. Binary payloads are exactly what must not be re-boxed.
  static T _coerce<T>(Object raw) {
    if (raw is TypedData) return raw as T;
    if (raw is Map) {
      return Map<String, dynamic>.from(
        raw.map((k, v) => MapEntry(k.toString(), _normalise(v))),
      ) as T;
    }
    if (raw is List) return raw.map(_normalise).toList() as T;
    return raw as T;
  }

  static Object? _normalise(Object? v) {
    if (v is Map) {
      return Map<String, dynamic>.from(v.map((k, val) => MapEntry(k.toString(), _normalise(val))));
    }
    if (v is List) return v.map(_normalise).toList();
    return v;
  }

  // ---- perception -------------------------------------------------------

  Future<NativeResult<Map<String, dynamic>>> status() => _invoke('status');

  Future<NativeResult<Map<String, dynamic>>> screenState({
    int? maxNodes,
    bool? interactiveOnly,
  }) =>
      _invoke('screenState', <String, dynamic>{
        'max_nodes': ?maxNodes,
        'interactive_only': ?interactiveOnly,
      });

  Future<NativeResult<Map<String, dynamic>>> find({
    String? text,
    String? id,
    String? className,
    bool? exact,
  }) =>
      _invoke('find', <String, dynamic>{
        'text': ?text,
        'id': ?id,
        'class': ?className,
        'exact': ?exact,
      });

  Future<NativeResult<Map<String, dynamic>>> nodeDetails(String nodeId) =>
      _invoke('nodeDetails', <String, dynamic>{'node_id': nodeId});

  /// Raw PNG bytes. Deliberately NOT base64: the payload rides a binary WebSocket
  /// frame, and base64 would inflate it by a third for nothing.
  Future<NativeResult<Uint8List>> screenshot({double? scale}) =>
      _invoke<Uint8List>('screenshot', <String, dynamic>{'scale': ?scale});

  Future<NativeResult<Map<String, dynamic>>> pixel(int x, int y) =>
      _invoke('pixel', <String, dynamic>{'x': x, 'y': y});

  // ---- touch ------------------------------------------------------------

  Future<NativeResult<Map<String, dynamic>>> tap(Map<String, dynamic> target) =>
      _invoke('tap', target);

  Future<NativeResult<Map<String, dynamic>>> doubleTap(Map<String, dynamic> target) =>
      _invoke('doubleTap', target);

  Future<NativeResult<Map<String, dynamic>>> longPress(Map<String, dynamic> args) =>
      _invoke('longPress', args);

  Future<NativeResult<Map<String, dynamic>>> swipe(Map<String, dynamic> args) =>
      _invoke('swipe', args);

  Future<NativeResult<Map<String, dynamic>>> pinch(Map<String, dynamic> args) =>
      _invoke('pinch', args);

  Future<NativeResult<Map<String, dynamic>>> gesture(Map<String, dynamic> args) =>
      _invoke('gesture', args);

  // ---- input ------------------------------------------------------------

  Future<NativeResult<Map<String, dynamic>>> typeText(Map<String, dynamic> args) =>
      _invoke('typeText', args);

  Future<NativeResult<Map<String, dynamic>>> press(String key) =>
      _invoke('press', <String, dynamic>{'key': key});

  Future<NativeResult<Map<String, dynamic>>> waitFor(Map<String, dynamic> args) =>
      _invoke('waitFor', args);

  // ---- apps -------------------------------------------------------------

  Future<NativeResult<Map<String, dynamic>>> closeApp(String package) =>
      _invoke('closeApp', <String, dynamic>{'package': package});

  Future<NativeResult<Map<String, dynamic>>> sendIntent(Map<String, dynamic> args) =>
      _invoke('sendIntent', args);

  // ---- notifications ----------------------------------------------------

  Future<NativeResult<Map<String, dynamic>>> notifications(Map<String, dynamic> args) =>
      _invoke('notifications', args);

  Future<NativeResult<Map<String, dynamic>>> notificationReply(String id, String text) =>
      _invoke('notificationReply', <String, dynamic>{'id': id, 'text': text});

  Future<NativeResult<Map<String, dynamic>>> notificationAction(String id, String action) =>
      _invoke('notificationAction', <String, dynamic>{'id': id, 'action': action});

  Future<NativeResult<bool>> notificationAccessGranted() =>
      _invoke<bool>('notificationAccessGranted');

  Future<NativeResult<bool>> openNotificationAccessSettings() =>
      _invoke<bool>('openNotificationAccessSettings');

  // ---- data -------------------------------------------------------------

  Future<NativeResult<Map<String, dynamic>>> clipboard(String action, {String? text}) =>
      _invoke('clipboard', <String, dynamic>{
        'action': action,
        'text': ?text,
      });

  Future<NativeResult<Map<String, dynamic>>> logs({int? lines}) =>
      _invoke('logs', <String, dynamic>{'lines': ?lines});

  // ---- lifecycle --------------------------------------------------------

  Future<NativeResult<Map<String, dynamic>>> startForegroundService() =>
      _invoke('startForegroundService');

  Future<NativeResult<Map<String, dynamic>>> stopForegroundService() =>
      _invoke('stopForegroundService');

  Future<NativeResult<Map<String, dynamic>>> updateForegroundStatus(String text) =>
      _invoke('updateForegroundStatus', <String, dynamic>{'text': text});

  Future<NativeResult<bool>> isForegroundServiceRunning() =>
      _invoke<bool>('isForegroundServiceRunning');

  Future<NativeResult<bool>> batteryUnrestricted() => _invoke<bool>('batteryUnrestricted');

  Future<NativeResult<bool>> requestBatteryUnrestricted() =>
      _invoke<bool>('requestBatteryUnrestricted');

  // ---- accessibility onboarding (legacy channel, still the only opener) ----

  static const MethodChannel _a11y = MethodChannel('com.privateagent/accessibility');

  Future<bool> accessibilityRunning() async {
    try {
      return await _a11y.invokeMethod<bool>('isServiceRunning') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openAccessibilitySettings() async {
    try {
      await _a11y.invokeMethod('openAccessibilitySettings');
    } catch (_) {
      // The deep link can be missing on some OEM builds; the checklist still
      // tells the operator what is wrong, so this must not throw into the UI.
    }
  }
}
