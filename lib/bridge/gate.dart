/// The hard gate — the ON-DEVICE half of the approval system (ADR-3 D4).
///
/// The bridge already refuses a gated op that has no approval. This exists because
/// that is not enough: if the bridge is compromised or a bug bypasses its check, the
/// phone must still refuse. So the phone verifies an HMAC-SHA256 signature made with
/// the per-device secret before executing any of the four gated phone ops:
///
///   device_type_text (submit) · device_double_tap · device_notification_reply · device_share_file
///
/// The phone does not trust the bridge's word that something was approved. It checks.
///
/// P2 SCOPE: this is the verifier, wired and refusing by default. The bridge side that
/// ISSUES signatures lands in P3 — until then every gated op is refused here, which is
/// the correct failure direction and is exactly what acceptance criterion B8 asserts.
library;

import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Why a gated op was refused. Sent up as a `blocked` event so a refusal is evidence,
/// never a silent no-op.
enum GateRefusal {
  /// No signature block at all — the normal P2 case, and the P3 case where the bridge
  /// forgot to sign.
  missingSignature,

  /// The signature did not match. Either the wrong device secret, tampering, or a
  /// mismatched canonical form between the two repos.
  badSignature,

  /// `exp` is in the past. An approval is worth 15 minutes (ADR-3 D3).
  expired,

  /// The op or target the bridge signed is not the op or target we were asked to run.
  targetMismatch,

  /// The device secret is not configured — the operator has not finished Settings.
  noDeviceSecret,
}

extension GateRefusalWire on GateRefusal {
  /// Stable strings; these end up in bridge `events` rows and in P3's telemetry.
  String get wire => switch (this) {
        GateRefusal.missingSignature => 'missing_signature',
        GateRefusal.badSignature => 'bad_signature',
        GateRefusal.expired => 'expired',
        GateRefusal.targetMismatch => 'target_mismatch',
        GateRefusal.noDeviceSecret => 'no_device_secret',
      };
}

class GateVerdict {
  const GateVerdict.allowed()
      : allowed = true,
        refusal = null;
  const GateVerdict.refused(GateRefusal this.refusal) : allowed = false;

  final bool allowed;
  final GateRefusal? refusal;

  String get reason => refusal?.wire ?? 'allowed';
}

/// The four phone ops the hard gate covers (ARCHITECTURE §3).
///
/// `sms_send` and `sms_reply` are deliberately ABSENT: SMS goes through capcom6, a
/// separate app this agent does not control, so the hard gate cannot cover it. Those
/// are bridge-gated only. Do not "fix" this by adding them — it would create a gate
/// that silently never runs.
const Set<String> hardGatedOps = <String>{
  'device_type_text',
  'device_double_tap',
  'device_notification_reply',
  'device_share_file',
};

/// Whether this specific call needs a signature.
///
/// `device_type_text` is conditional: only a SUBMIT is outbound. Typing a draft that
/// nobody sends is not an outbound action, and gating it would make the agent unusable.
bool requiresHardGate(String method, Map<String, dynamic> params) {
  if (method == 'device_type_text') {
    return params['submit'] == true;
  }
  return hardGatedOps.contains(method);
}

/// The canonical string that gets signed.
///
/// NUL-delimited rather than JSON on purpose: JSON key order, whitespace and unicode
/// escaping all differ between Dart and TypeScript encoders, and a signature that
/// depends on any of them is a signature that breaks in production for reasons nobody
/// can see. NUL cannot appear in any of these fields, so the framing is unambiguous.
///
/// The `v1` prefix means a future change to this format fails loudly as a bad
/// signature instead of silently verifying something different.
///
/// MUST match `canonicalSigningString()` in `agent-bridge/src/device/gate-signing.ts`.
/// The shared fixture in `test/fixtures/gate_vectors.json` pins both.
String canonicalSigningString({
  required String op,
  required String targetHash,
  required String approvalId,
  required int exp,
}) =>
    'v1\u0000$op\u0000$targetHash\u0000$approvalId\u0000$exp';

/// Compute the expected signature. Lowercase hex, HMAC-SHA256.
String signPayload({
  required String deviceSecret,
  required String op,
  required String targetHash,
  required String approvalId,
  required int exp,
}) {
  final mac = Hmac(sha256, utf8.encode(deviceSecret));
  final msg = canonicalSigningString(
    op: op,
    targetHash: targetHash,
    approvalId: approvalId,
    exp: exp,
  );
  return mac.convert(utf8.encode(msg)).toString();
}

/// Constant-time comparison. A timing-variable compare on a signature leaks the
/// signature one byte at a time to anything that can retry.
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// The approval block the bridge attaches to a gated request.
class ApprovalEnvelope {
  const ApprovalEnvelope({
    required this.approvalId,
    required this.targetHash,
    required this.exp,
    required this.signature,
    this.op,
  });

  final String approvalId;
  final String targetHash;
  final int exp;
  final String signature;

  /// The op the bridge says it signed. When present it must match the method being
  /// executed — otherwise an approval for "type a draft" could release a "share file".
  final String? op;

  static ApprovalEnvelope? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final approvalId = raw['approval_id'];
    final targetHash = raw['target_hash'];
    final exp = raw['exp'];
    final signature = raw['signature'];
    if (approvalId is! String || targetHash is! String || signature is! String) {
      return null;
    }
    if (exp is! int) return null;
    return ApprovalEnvelope(
      approvalId: approvalId,
      targetHash: targetHash,
      exp: exp,
      signature: signature,
      op: raw['op'] is String ? raw['op'] as String : null,
    );
  }
}

/// Verify a gated call.
///
/// [nowMs] is injectable so the expiry case is testable without sleeping.
GateVerdict verifyHardGate({
  required String method,
  required Map<String, dynamic> params,
  required String? deviceSecret,
  required int nowMs,
}) {
  final envelope = ApprovalEnvelope.tryParse(params['approval']);
  if (envelope == null) {
    return const GateVerdict.refused(GateRefusal.missingSignature);
  }
  if (deviceSecret == null || deviceSecret.isEmpty) {
    // Refuse rather than skip. An unconfigured secret must never mean "allow".
    return const GateVerdict.refused(GateRefusal.noDeviceSecret);
  }
  if (envelope.op != null && envelope.op != method) {
    return const GateVerdict.refused(GateRefusal.targetMismatch);
  }
  if (envelope.exp <= nowMs) {
    return const GateVerdict.refused(GateRefusal.expired);
  }

  final expected = signPayload(
    deviceSecret: deviceSecret,
    op: method,
    targetHash: envelope.targetHash,
    approvalId: envelope.approvalId,
    exp: envelope.exp,
  );
  if (!constantTimeEquals(expected, envelope.signature.toLowerCase())) {
    return const GateVerdict.refused(GateRefusal.badSignature);
  }
  return const GateVerdict.allowed();
}
