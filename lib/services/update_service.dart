import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// Info about an available update.
class UpdateInfo {
  final int build; // build number of the latest release (from tag build-N)
  final String name; // release name
  final String notes; // release body / changelog
  final String apkUrl; // public browser_download_url of the .apk asset

  UpdateInfo({
    required this.build,
    required this.name,
    required this.notes,
    required this.apkUrl,
  });
}

/// In-app self-update.
///
/// The app publishes every CI build to a GitHub Release tagged `build-<N>`,
/// where N is the (monotonic) CI run number and is also baked into the APK's
/// versionCode via `--build-number`. On check we compare this device's
/// versionCode (PackageInfo.buildNumber) against the latest release's `build-N`
/// tag; if the release is newer we download its public APK and hand it to the
/// system package installer (via open_filex).
///
/// The repo is PUBLIC, so the APK URL needs no auth — nothing secret ships in
/// the app.
/// What is installed right now, as shown in Settings → App Updates.
class InstalledVersion {
  final String versionName; // e.g. 0.1.0
  final int build; // versionCode = CI build number (0 if unknown)

  const InstalledVersion({required this.versionName, required this.build});

  /// Builds before [UpdateService.firstFixedKeyBuild] were signed with a
  /// throwaway CI debug key. Android refuses to update across signing keys, so
  /// such an install can never be updated in place — it must be uninstalled
  /// once and a fixed-key build installed fresh.
  bool get needsReinstall => build > 0 && build < UpdateService.firstFixedKeyBuild;

  @override
  String toString() => build > 0 ? '$versionName (build $build)' : versionName;
}

class UpdateService {
  static const String _repo = 'SXTNmedia21/private-agent';
  static final RegExp _buildTag = RegExp(r'build-(\d+)');

  /// First CI build signed with the committed release.keystore (commit
  /// 93f7bee). Everything older carries a per-run debug key.
  static const int firstFixedKeyBuild = 8;

  /// Shown when the system installer reports "App not installed".
  static const String reinstallHint =
      'Android only updates an app in place when the new APK is signed with '
      'the same key as the installed one. Builds before build-'
      '$firstFixedKeyBuild used a temporary key. Fix (one time): uninstall '
      'PrivateAgent, then install the latest build from GitHub Releases. '
      'Settings are lost on uninstall — note them first.';

  /// Returns the current installed build number (versionCode), 0 if unknown.
  Future<int> currentBuild() async => (await currentVersion()).build;

  /// Returns installed version name + build number.
  Future<InstalledVersion> currentVersion() async {
    final info = await PackageInfo.fromPlatform();
    return InstalledVersion(
      versionName: info.version,
      build: int.tryParse(info.buildNumber) ?? 0,
    );
  }

  /// Check GitHub for a newer release. Returns null if up to date or on error.
  Future<UpdateInfo?> check() async {
    final current = await currentBuild();

    final resp = await http.get(
      Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json'},
    );
    if (resp.statusCode != 200) return null;

    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final tag = json['tag_name'] as String? ?? '';
    final match = _buildTag.firstMatch(tag);
    if (match == null) return null; // not a build-N release
    final latest = int.tryParse(match.group(1)!) ?? 0;
    if (latest <= current) return null; // already up to date

    final assets = (json['assets'] as List?) ?? const [];
    String? apkUrl;
    for (final a in assets) {
      final name = (a['name'] as String?) ?? '';
      if (name.toLowerCase().endsWith('.apk')) {
        apkUrl = a['browser_download_url'] as String?;
        break;
      }
    }
    if (apkUrl == null) return null;

    return UpdateInfo(
      build: latest,
      name: (json['name'] as String?) ?? tag,
      notes: (json['body'] as String?) ?? '',
      apkUrl: apkUrl,
    );
  }

  /// Download the update APK (reporting 0..1 progress) and launch the system
  /// installer. Throws on download failure or if the installer could not be
  /// launched (with the platform's message). The user still confirms the
  /// install in the Android dialog — the outcome of THAT is only visible there
  /// (the app is replaced on success, so it cannot observe it).
  Future<String> downloadAndInstall(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
  }) async {
    final dir =
        await getExternalStorageDirectory() ?? await getTemporaryDirectory();
    final file = File('${dir.path}/private-agent-update.apk');

    final client = http.Client();
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(info.apkUrl)));
      if (resp.statusCode != 200) {
        throw HttpException('Download failed (HTTP ${resp.statusCode})');
      }
      final total = resp.contentLength ?? 0;
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.flush();
      await sink.close();
    } finally {
      client.close();
    }

    final result = await OpenFilex.open(
      file.path,
      type: 'application/vnd.android.package-archive',
    );
    if (result.type != ResultType.done) {
      throw Exception(
        'Could not launch installer (${result.type.name}): ${result.message}',
      );
    }
    return result.message;
  }
}
