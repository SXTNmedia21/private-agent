import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

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
/// tag; if the release is newer we hand its public APK URL to `ota_update`,
/// which downloads it and launches the system installer.
///
/// The repo is PUBLIC, so the APK URL needs no auth — nothing secret ships in
/// the app.
class UpdateService {
  static const String _repo = 'SXTNmedia21/private-agent';
  static final RegExp _buildTag = RegExp(r'build-(\d+)');

  /// Returns the current installed build number (versionCode), 0 if unknown.
  Future<int> currentBuild() async {
    final info = await PackageInfo.fromPlatform();
    return int.tryParse(info.buildNumber) ?? 0;
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

  /// Download and install the update. Emits ota_update progress events; the
  /// system installer is launched automatically once the download completes.
  Stream<OtaEvent> install(UpdateInfo info) {
    return OtaUpdate().execute(
      info.apkUrl,
      destinationFilename: 'private-agent-update.apk',
    );
  }
}
