import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'secure_storage.dart';

/// One release, as published in the version manifest at
/// `<downloadsBaseUrl>/version.json` — a small static JSON file uploaded
/// alongside the APK itself by deploy/cloudflare/upload-downloads.sh, not a
/// backend API call. There's no tenant/auth concept here at all, so this
/// doesn't belong on the Go API — it's plain static metadata sitting next
/// to the file it describes, the same R2 bucket the download link already
/// uses.
class UpdateInfo {
  final int latestVersionCode;
  final String latestVersionName;
  final String apkUrl;
  final String releaseNotes;
  final int? minSupportedVersionCode;

  UpdateInfo({
    required this.latestVersionCode,
    required this.latestVersionName,
    required this.apkUrl,
    required this.releaseNotes,
    this.minSupportedVersionCode,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      latestVersionCode: json['latest_version_code'] as int,
      latestVersionName: json['latest_version_name'] as String,
      apkUrl: json['apk_url'] as String,
      releaseNotes: json['release_notes'] as String? ?? '',
      minSupportedVersionCode: json['min_supported_version_code'] as int?,
    );
  }
}

/// Checks for and installs app updates on Android, for this sideloaded
/// (non-Play-Store) distribution — see app_update_service's companion
/// dialog widget for the UI this drives. Deliberately Android-only: iOS
/// isn't shipped, web/Windows builds have no APK to install and keep using
/// a manual re-download for now.
class AppUpdateService {
  final String downloadsBaseUrl;
  final http.Client _http;
  final KeyValueStore _store;

  static const _keyDismissedVersion = 'update_dismissed_version_code';

  AppUpdateService({required this.downloadsBaseUrl, http.Client? httpClient, KeyValueStore? store})
      : _http = httpClient ?? http.Client(),
        _store = store ?? PlatformSecureKeyValueStore();

  /// Returns the available update, or null if already up to date, already
  /// dismissed by the user for this exact version, or the check failed for
  /// any reason (no network, the manifest briefly unreachable, malformed
  /// JSON). A failed check is never surfaced as an error — this must not
  /// block or interrupt app startup, same convention as BrandingProvider's
  /// "offline keeps the last-known-good state" handling.
  Future<UpdateInfo?> checkForUpdate({bool ignoreDismissed = false}) async {
    if (downloadsBaseUrl.isEmpty) return null;
    try {
      final response = await _http.get(Uri.parse('$downloadsBaseUrl/version.json')).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final info = UpdateInfo.fromJson(jsonDecode(response.body) as Map<String, dynamic>);

      final packageInfo = await PackageInfo.fromPlatform();
      final installedVersionCode = int.tryParse(packageInfo.buildNumber) ?? 0;
      if (info.latestVersionCode <= installedVersionCode) return null;

      if (!ignoreDismissed) {
        final dismissed = int.tryParse(await _store.read(_keyDismissedVersion) ?? '');
        if (dismissed != null && dismissed >= info.latestVersionCode) return null;
      }
      return info;
    } catch (_) {
      return null;
    }
  }

  /// Remembers that the user chose "Later" for this version, so the launch
  /// check stops nagging about it — but a further version bump still
  /// prompts normally, since that's a strictly newer `latest_version_code`.
  Future<void> dismiss(UpdateInfo info) => _store.write(_keyDismissedVersion, info.latestVersionCode.toString());

  /// Downloads the APK to the app's cache directory with progress
  /// reporting, then hands it to Android's own package installer via
  /// open_filex (which bundles its own FileProvider — no manual Android
  /// setup needed beyond the REQUEST_INSTALL_PACKAGES permission already
  /// declared in AndroidManifest.xml). Android shows its own "allow installs
  /// from this source" system prompt automatically on first use if not
  /// already granted, and its own install confirmation screen after that —
  /// neither is something this app drives directly.
  Future<void> downloadAndInstall(UpdateInfo info, {void Function(double progress)? onProgress}) async {
    final request = http.Request('GET', Uri.parse(info.apkUrl));
    final response = await _http.send(request);
    final total = response.contentLength ?? 0;

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/feedmate-update-${info.latestVersionCode}.apk');
    final sink = file.openWrite();
    var received = 0;
    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress?.call(received / total);
    }
    await sink.close();

    final result = await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
    if (result.type != ResultType.done) {
      throw Exception(result.message);
    }
  }
}
