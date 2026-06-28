import 'package:installed_apps/installed_apps.dart';
import 'package:installed_apps/app_info.dart';
import 'package:url_launcher/url_launcher.dart';

class AppLauncherService {
  List<AppInfo>? _cachedApps;

  /// Common English app name -> package name. Tried BEFORE fuzzy name match so
  /// that core apps resolve regardless of the device's display language
  /// (e.g. a Swedish phone shows "Inställningar"/"Play Butik", not "Settings").
  /// System apps (Settings, dialer, Play Store) are also invisible to the
  /// default `getInstalledApps` call, so launching them by package is the only
  /// reliable path.
  static const Map<String, String> _aliases = {
    'settings': 'com.android.settings',
    'play store': 'com.android.vending',
    'google play': 'com.android.vending',
    'play': 'com.android.vending',
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

  /// Get all installed apps (cached). Includes system apps so that built-in
  /// apps like Settings are findable by fuzzy match too.
  Future<List<AppInfo>> getInstalledApps() async {
    _cachedApps ??= await InstalledApps.getInstalledApps(false, false);
    return _cachedApps!;
  }

  /// Clear app cache
  void clearCache() {
    _cachedApps = null;
  }

  /// Find apps matching a query
  Future<List<AppInfo>> searchApps(String query) async {
    final apps = await getInstalledApps();
    final lowerQuery = query.toLowerCase();
    return apps.where((app) {
      return app.name.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  /// Open an app by name. Resolution order:
  /// 1. Known-package alias (language-proof, works for system apps).
  /// 2. Fuzzy display-name match against installed apps.
  Future<String> openApp(String appName) async {
    final key = appName.toLowerCase().trim();

    // 1. Alias -> launch by package directly.
    final aliasPkg = _aliases[key];
    if (aliasPkg != null) {
      try {
        final ok = await InstalledApps.startApp(aliasPkg);
        if (ok != false) return 'Opened $appName';
      } catch (_) {
        // package not present on this device — fall through to fuzzy match
      }
    }

    // 2. Fuzzy display-name match.
    final matches = await searchApps(appName);
    if (matches.isEmpty) {
      return 'Could not find app "$appName". Try a different name, '
          'or use click_text/click_at on a visible icon.';
    }

    AppInfo? target;
    for (final app in matches) {
      if (app.name.toLowerCase() == key) {
        target = app;
        break;
      }
    }
    target ??= matches.first;

    try {
      await InstalledApps.startApp(target.packageName);
      return 'Opened ${target.name}';
    } catch (e) {
      return 'Error opening ${target.name}: $e';
    }
  }

  /// Open a URL
  Future<String> openUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return 'Opened $url';
      }
      return 'Cannot open $url';
    } catch (e) {
      return 'Error opening URL: $e';
    }
  }
}
