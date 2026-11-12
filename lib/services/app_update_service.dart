import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:sticker_flutter/services/app_update_notification_service.dart';
import 'package:sticker_flutter/ui/widgets/force_update_dialog.dart';

/// Information regarding app versioning and update requirements.
class AppUpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final String minRequiredVersion;
  final String updateUrl;
  final String title;
  final String message;
  final bool isForceUpdate;

  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.minRequiredVersion,
    required this.updateUrl,
    this.title = 'New version available',
    this.message = 'There are new features available,\nplease update your app',
    this.isForceUpdate = false,
  });

  /// Check whether an update is available (current < latest).
  bool get hasUpdate => AppUpdateService.isVersionOlder(currentVersion, latestVersion);

  /// Check whether an update is strictly required (current < minRequired or explicitly forced).
  bool get requiresForceUpdate =>
      isForceUpdate || AppUpdateService.isVersionOlder(currentVersion, minRequiredVersion);
}

/// Service that handles app version comparison, remote check, status bar notifications,
/// and automatic APK download & installation.
class AppUpdateService {
  static const String defaultCurrentVersion = '1.0.5+6';
  static const String defaultReleaseTag = 'sticko-3';
  static const String defaultStoreUrl =
      'https://play.google.com/store/apps/details?id=com.pkri.sticko';
  static const String defaultGitHubReleasesApi =
      'https://api.github.com/repos/vikri546/sticko/releases/latest';
  static const String defaultGitHubAllReleasesApi =
      'https://api.github.com/repos/vikri546/sticko/releases?per_page=10';
  static const String defaultUpdateCheckUrl =
      'https://raw.githubusercontent.com/vikri546/sticko/main/version.json';
  static const String defaultDirectApkUrl =
      'https://github.com/vikri546/sticko/releases/download/sticko-3/sticko-app-1.0.5.apk';

  static bool _isDialogShowing = false;

  /// Optional test hook allowing widget tests to simulate remote update responses.
  @visibleForTesting
  static Future<AppUpdateInfo?> Function()? mockUpdateChecker;

  /// Reset static test hooks.
  @visibleForTesting
  static void resetForTesting() {
    mockUpdateChecker = null;
    _isDialogShowing = false;
  }

  /// Retrieve the installed application version dynamically from Android PackageManager,
  /// falling back to [defaultCurrentVersion].
  static Future<String> getCurrentAppVersion() async {
    final installed = await AppUpdateNotificationService().getInstalledAppVersion();
    if (installed != null && installed.isNotEmpty) {
      return installed;
    }
    return defaultCurrentVersion;
  }

  /// Clean version string without leading 'v'/'V' or trailing '+build' number
  /// (e.g. '1.0.5+6' -> '1.0.5').
  static String cleanVersionName(String version) {
    return version
        .replaceFirst(RegExp(r'^[vV]'), '')
        .split('+')
        .first
        .trim();
  }

  /// Generate the standard Sticko APK file name for a given [version]
  /// (e.g. '1.0.5+6' -> 'sticko-app-1.0.5.apk').
  static String apkFileNameForVersion(String version) {
    final cleanVer = cleanVersionName(version);
    if (cleanVer.isEmpty) return 'app-release.apk';
    return 'sticko-app-$cleanVer.apk';
  }

  /// Extract a semantic version (e.g. '1.0.5' or '1.0.5+6') from a string such as
  /// a release title or asset filename ('sticko-app-1.0.5.apk' -> '1.0.5').
  static String? extractSemanticVersion(String input) {
    final match = RegExp(r'(\d+\.\d+\.\d+(?:\+\d+)?)').firstMatch(input);
    return match?.group(1);
  }

  /// Extract GitHub `<owner>`, `<repo>`, and optional `<tag>` from a GitHub Release URL.
  static ({String owner, String repo, String? tag})? parseGitHubReleaseUrl(
    String url,
  ) {
    final trimmed = url.trim();
    final tagPageMatch = RegExp(
      r'^https?://github\.com/([^/]+)/([^/]+)/releases/tag/([^/?#]+)',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (tagPageMatch != null) {
      return (
        owner: tagPageMatch.group(1)!,
        repo: tagPageMatch.group(2)!,
        tag: tagPageMatch.group(3)!,
      );
    }

    final downloadTagMatch = RegExp(
      r'^https?://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (downloadTagMatch != null) {
      return (
        owner: downloadTagMatch.group(1)!,
        repo: downloadTagMatch.group(2)!,
        tag: downloadTagMatch.group(3)!,
      );
    }

    final generalRepoMatch = RegExp(
      r'^https?://github\.com/([^/]+)/([^/]+)/releases',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (generalRepoMatch != null) {
      return (
        owner: generalRepoMatch.group(1)!,
        repo: generalRepoMatch.group(2)!,
        tag: null,
      );
    }

    return null;
  }

  /// Normalize GitHub Release URLs into direct `.apk` download URLs automatically.
  ///
  /// Supports:
  /// - `https://github.com/<owner>/<repo>/releases/latest/download/<file>.apk` (kept as-is)
  /// - `https://github.com/<owner>/<repo>/releases/download/<tag>/<file>.apk` (kept as-is)
  /// - `https://github.com/<owner>/<repo>/releases/latest` -> `.../releases/latest/download/<apkName>`
  /// - `https://github.com/<owner>/<repo>/releases/tag/<tag>` -> `.../releases/download/<tag>/<apkName>`
  static String normalizeApkUrl(
    String rawUrl, {
    String? targetVersion,
    String? defaultApkName,
  }) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return trimmed;

    final resolvedApkName = defaultApkName ??
        (targetVersion != null && targetVersion.trim().isNotEmpty
            ? apkFileNameForVersion(targetVersion)
            : 'app-release.apk');

    // Match https://github.com/<owner>/<repo>/releases/latest[/]
    final latestMatch = RegExp(
      r'^https?://github\.com/([^/]+)/([^/]+)/releases/latest/?$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (latestMatch != null) {
      final owner = latestMatch.group(1)!;
      final repo = latestMatch.group(2)!;
      return 'https://github.com/$owner/$repo/releases/latest/download/$resolvedApkName';
    }

    // Match https://github.com/<owner>/<repo>/releases/tag/<tag>[/]
    final tagMatch = RegExp(
      r'^https?://github\.com/([^/]+)/([^/]+)/releases/tag/([^/?#]+)/?$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (tagMatch != null) {
      final owner = tagMatch.group(1)!;
      final repo = tagMatch.group(2)!;
      final tag = tagMatch.group(3)!;
      return 'https://github.com/$owner/$repo/releases/download/$tag/$resolvedApkName';
    }

    return trimmed;
  }

  /// Build an ordered list of candidate direct APK download URLs for [rawUrl] and [targetVersion].
  /// Handles tag changes (`sticko-3`, `sticko-4`, ...) and filename variations
  /// (`sticko-app-1.0.5.apk`, `sticko-app-1.0.5`, `app-release.apk`).
  static List<String> buildCandidateApkUrls(
    String rawUrl, {
    String? targetVersion,
    String? releaseTag,
  }) {
    final candidates = <String>[];
    void addCandidate(String url) {
      final u = url.trim();
      if (u.isNotEmpty && !candidates.contains(u)) {
        candidates.add(u);
      }
    }

    final cleanVer = targetVersion != null ? cleanVersionName(targetVersion) : '';
    final versionedApk = cleanVer.isNotEmpty ? 'sticko-app-$cleanVer.apk' : null;
    final versionedNoExt = cleanVer.isNotEmpty ? 'sticko-app-$cleanVer' : null;

    final parsed = parseGitHubReleaseUrl(rawUrl);
    final owner = parsed?.owner ?? 'vikri546';
    final repo = parsed?.repo ?? 'sticko';
    final tag = (releaseTag != null && releaseTag.trim().isNotEmpty)
        ? releaseTag.trim()
        : parsed?.tag;

    // 1. If rawUrl is already a direct download URL (not a /releases/tag/ HTML page), try it
    final normalizedWithVersion = normalizeApkUrl(
      rawUrl,
      targetVersion: targetVersion,
    );
    if (isDirectApkUrl(normalizedWithVersion)) {
      addCandidate(normalizedWithVersion);
    }

    // 2. If we have a specific release tag (e.g. sticko-3, sticko-4), try versioned & standard filenames on that tag
    if (tag != null && tag.isNotEmpty) {
      if (versionedApk != null) {
        addCandidate(
          'https://github.com/$owner/$repo/releases/download/$tag/$versionedApk',
        );
      }
      if (versionedNoExt != null) {
        addCandidate(
          'https://github.com/$owner/$repo/releases/download/$tag/$versionedNoExt',
        );
      }
      addCandidate(
        'https://github.com/$owner/$repo/releases/download/$tag/app-release.apk',
      );
    }

    // 3. Also try /releases/latest/download/ with versioned & standard filenames
    if (versionedApk != null) {
      addCandidate(
        'https://github.com/$owner/$repo/releases/latest/download/$versionedApk',
      );
    }
    if (versionedNoExt != null) {
      addCandidate(
        'https://github.com/$owner/$repo/releases/latest/download/$versionedNoExt',
      );
    }
    addCandidate(
      'https://github.com/$owner/$repo/releases/latest/download/app-release.apk',
    );

    final normalizedDefault = normalizeApkUrl(rawUrl);
    if (isDirectApkUrl(normalizedDefault)) {
      addCandidate(normalizedDefault);
    }

    return candidates;
  }

  /// Returns `true` if [url] points directly to a downloadable `.apk` package
  /// or a GitHub Release binary asset download path (`/releases/download/...` or `/releases/latest/download/...`).
  static bool isDirectApkUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty ||
        trimmed == defaultStoreUrl ||
        trimmed.endsWith('.test')) {
      return false;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return false;
    final lowerPath = uri.path.toLowerCase();
    if (lowerPath.contains('/releases/tag/')) {
      return false;
    }
    if (lowerPath.endsWith('.apk')) {
      return true;
    }
    if (lowerPath.contains('/releases/download/') ||
        lowerPath.contains('/releases/latest/download/')) {
      return true;
    }
    return false;
  }

  /// Compare two semantic version strings (e.g., '1.0.0' vs '1.1.0' or '1.0.3+4' vs '1.0.4+5').
  /// Returns `true` if [current] is strictly older than [target].
  static bool isVersionOlder(String current, String target) {
    try {
      // Clean build numbers (+1, etc.) and strip optional 'v' / 'V' prefixes
      final cleanCurrent = current.replaceFirst(RegExp(r'^[vV]'), '').split('+').first.trim();
      final cleanTarget = target.replaceFirst(RegExp(r'^[vV]'), '').split('+').first.trim();

      final currentParts = cleanCurrent.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      final targetParts = cleanTarget.split('.').map((e) => int.tryParse(e) ?? 0).toList();

      final maxLength = currentParts.length > targetParts.length ? currentParts.length : targetParts.length;

      for (int i = 0; i < maxLength; i++) {
        final cur = i < currentParts.length ? currentParts[i] : 0;
        final tar = i < targetParts.length ? targetParts[i] : 0;
        if (cur < tar) return true;
        if (cur > tar) return false;
      }

      // If semantic versions match, compare build numbers if available
      final curBuild = int.tryParse(current.contains('+') ? current.split('+').last : '0') ?? 0;
      final tarBuild = int.tryParse(target.contains('+') ? target.split('+').last : '0') ?? 0;
      return curBuild < tarBuild;
    } catch (_) {
      return false;
    }
  }

  /// Check if a GitHub Release asset JSON object represents an APK binary
  /// (supports both `sticko-app-1.0.5.apk` and `sticko-app-1.0.5` without `.apk` extension).
  static bool _isApkReleaseAsset(Map asset) {
    final name = (asset['name']?.toString() ?? '').trim().toLowerCase();
    final dlUrl =
        (asset['browser_download_url']?.toString() ?? '').trim().toLowerCase();
    final contentType =
        (asset['content_type']?.toString() ?? '').trim().toLowerCase();

    if (name.endsWith('.zip') ||
        name.endsWith('.tar.gz') ||
        name.endsWith('.txt') ||
        name.endsWith('.json') ||
        name.endsWith('.sha256') ||
        name.endsWith('.md')) {
      return false;
    }

    if (name.endsWith('.apk') || dlUrl.endsWith('.apk')) {
      return true;
    }
    if (contentType == 'application/vnd.android.package-archive') {
      return true;
    }
    if (name.startsWith('sticko-app') ||
        name.startsWith('sticko_') ||
        name.startsWith('app-release')) {
      return dlUrl.isNotEmpty;
    }
    return false;
  }

  /// Extract the best matching APK `browser_download_url` from a single GitHub Release JSON map.
  static String? _extractApkUrlFromReleaseMap(
    Map releaseData, {
    String? targetVersion,
  }) {
    final assets = releaseData['assets'];
    if (assets is! List || assets.isEmpty) return null;

    final cleanVer =
        targetVersion != null ? cleanVersionName(targetVersion) : '';
    String? firstValidUrl;

    for (final asset in assets) {
      if (asset is Map && _isApkReleaseAsset(asset)) {
        final dlUrl = asset['browser_download_url']?.toString().trim() ?? '';
        if (dlUrl.isEmpty) continue;
        firstValidUrl ??= dlUrl;

        final name = asset['name']?.toString().toLowerCase() ?? '';
        if (cleanVer.isNotEmpty &&
            (name.contains(cleanVer.toLowerCase()) ||
                dlUrl.toLowerCase().contains(cleanVer.toLowerCase()))) {
          return dlUrl;
        }
      }
    }

    return firstValidUrl;
  }

  /// Resolve the exact `.apk` asset URL from GitHub Releases API if available.
  /// Checks specific tag (`/releases/tags/<tag>`), `/releases/latest`, and `/releases?per_page=10`.
  static Future<String?> _resolveGitHubReleaseAssetApkUrl(
    HttpClient client, {
    String? rawUrl,
    String? targetVersion,
    String? releaseTag,
  }) async {
    final parsed = rawUrl != null ? parseGitHubReleaseUrl(rawUrl) : null;
    final owner = parsed?.owner ?? 'vikri546';
    final repo = parsed?.repo ?? 'sticko';
    final tag = (releaseTag != null && releaseTag.trim().isNotEmpty)
        ? releaseTag.trim()
        : parsed?.tag;

    final apiUrls = <String>[
      if (tag != null && tag.isNotEmpty)
        'https://api.github.com/repos/$owner/$repo/releases/tags/$tag',
      'https://api.github.com/repos/$owner/$repo/releases/latest',
      'https://api.github.com/repos/$owner/$repo/releases?per_page=10',
    ];

    final cleanVer =
        targetVersion != null ? cleanVersionName(targetVersion) : '';

    for (final apiUrl in apiUrls) {
      try {
        final req = await client.getUrl(Uri.parse(apiUrl));
        req.headers.set('User-Agent', 'Sticko-App-Update-Checker');
        req.headers.set('Accept', 'application/vnd.github+json');
        final res = await req.close();
        if (res.statusCode == 200) {
          final body = await res.transform(utf8.decoder).join();
          final data = jsonDecode(body);

          if (data is Map) {
            final found = _extractApkUrlFromReleaseMap(
              data,
              targetVersion: targetVersion,
            );
            if (found != null) return found;
          } else if (data is List) {
            // 1. Prefer a release whose asset or tag matches targetVersion or tag
            if (cleanVer.isNotEmpty) {
              for (final rel in data) {
                if (rel is Map) {
                  final found = _extractApkUrlFromReleaseMap(
                    rel,
                    targetVersion: targetVersion,
                  );
                  if (found != null &&
                      found.toLowerCase().contains(cleanVer.toLowerCase())) {
                    return found;
                  }
                }
              }
            }
            // 2. Otherwise return the newest release that has an APK asset
            for (final rel in data) {
              if (rel is Map) {
                final found = _extractApkUrlFromReleaseMap(
                  rel,
                  targetVersion: targetVersion,
                );
                if (found != null) return found;
              }
            }
          }
        } else {
          await res.drain().catchError((_) {});
        }
      } catch (_) {}
    }
    return null;
  }

  /// Check remote server or GitHub for new APK updates in real-time.
  /// If an update is detected, automatically displays a system status bar notification.
  static Future<AppUpdateInfo?> checkRemoteUpdate({
    String? currentVersion,
    String? checkUrl,
    HttpClient? customClient,
    bool showStatusBarNotification = true,
  }) async {
    if (mockUpdateChecker != null && checkUrl == null && customClient == null) {
      final mocked = await mockUpdateChecker!();
      if (mocked != null && mocked.hasUpdate && showStatusBarNotification) {
        await AppUpdateNotificationService().showUpdateAvailable(
          version: mocked.latestVersion,
          title: mocked.title,
          message: mocked.message,
          downloadUrl: mocked.updateUrl,
        );
      }
      return mocked;
    }

    final effectiveCurrentVersion = currentVersion ?? await getCurrentAppVersion();
    final targetUrl = checkUrl ??
        '$defaultUpdateCheckUrl?t=${DateTime.now().millisecondsSinceEpoch}';
    final client = customClient ?? HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);

    try {
      final request = await client.getUrl(Uri.parse(targetUrl));
      request.headers.set('User-Agent', 'Sticko-App-Update-Checker');
      request.headers.set('Accept', 'application/json');
      request.headers.set('Cache-Control', 'no-cache');
      HttpClientResponse response = await request.close();

      // If version.json is not available and no custom checkUrl was provided, fallback to GitHub Releases API
      if (response.statusCode != 200 && checkUrl == null) {
        await response.drain().catchError((_) {});
        final fallbackReq = await client.getUrl(Uri.parse(defaultGitHubReleasesApi));
        fallbackReq.headers.set('User-Agent', 'Sticko-App-Update-Checker');
        fallbackReq.headers.set('Accept', 'application/vnd.github+json');
        response = await fallbackReq.close();

        if (response.statusCode != 200) {
          await response.drain().catchError((_) {});
          final allReleasesReq =
              await client.getUrl(Uri.parse(defaultGitHubAllReleasesApi));
          allReleasesReq.headers.set('User-Agent', 'Sticko-App-Update-Checker');
          allReleasesReq.headers.set('Accept', 'application/vnd.github+json');
          response = await allReleasesReq.close();
        }
      }

      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final dynamic decoded = jsonDecode(body);
        final Map<String, dynamic> data = decoded is List && decoded.isNotEmpty
            ? Map<String, dynamic>.from(decoded.first as Map)
            : Map<String, dynamic>.from(decoded as Map);

        final releaseTag =
            (data['release_tag'] ?? data['tag_name'])?.toString().trim();

        // Extract raw version or infer semantic version from tag/title/asset name (e.g. sticko-app-1.0.5)
        String rawVersion = (data['latest_version'] ??
                data['version'] ??
                data['tag_name'] ??
                effectiveCurrentVersion)
            .toString()
            .replaceFirst(RegExp(r'^[vV]'), '')
            .trim();

        if (!RegExp(r'^\d+\.\d+').hasMatch(rawVersion)) {
          final fromTitle =
              extractSemanticVersion(data['name']?.toString() ?? '');
          String? fromAsset;
          if (data['assets'] is List) {
            for (final asset in data['assets'] as List) {
              if (asset is Map) {
                fromAsset =
                    extractSemanticVersion(asset['name']?.toString() ?? '');
                if (fromAsset != null) break;
              }
            }
          }
          rawVersion = fromAsset ?? fromTitle ?? rawVersion;
        }
        final latestVersion = rawVersion;

        final minRequired = (data['min_required_version'] ?? '1.0.0').toString();
        final title = (data['title'] ?? data['name'] ?? 'Pembaruan Sticko Tersedia').toString();
        final message = (data['message'] ??
                data['body'] ??
                'Versi terbaru Sticko ($latestVersion) tersedia. Ketuk untuk memperbarui.')
            .toString();

        // Extract and normalize APK download URL
        String apkUrl = defaultDirectApkUrl;
        final assetUrlFromData = _extractApkUrlFromReleaseMap(
          data,
          targetVersion: latestVersion,
        );
        if (assetUrlFromData != null) {
          apkUrl = assetUrlFromData;
        } else if (data['apk_url'] != null &&
            data['apk_url'].toString().trim().isNotEmpty) {
          final rawApkUrl = data['apk_url'].toString().trim();
          if (customClient == null && rawApkUrl.contains('github.com/')) {
            final resolvedAssetUrl = await _resolveGitHubReleaseAssetApkUrl(
              client,
              rawUrl: rawApkUrl,
              targetVersion: latestVersion,
              releaseTag: releaseTag,
            );
            apkUrl = resolvedAssetUrl ??
                normalizeApkUrl(rawApkUrl, targetVersion: latestVersion);
          } else {
            apkUrl = isDirectApkUrl(rawApkUrl)
                ? rawApkUrl
                : normalizeApkUrl(rawApkUrl, targetVersion: latestVersion);
          }
        }

        final isForce = data['is_force_update'] as bool? ?? false;

        final info = AppUpdateInfo(
          currentVersion: effectiveCurrentVersion,
          latestVersion: latestVersion,
          minRequiredVersion: minRequired,
          updateUrl: apkUrl,
          title: title,
          message: message,
          isForceUpdate: isForce,
        );

        // If an update is available, trigger Android status bar notification in real-time
        if (info.hasUpdate && showStatusBarNotification) {
          await AppUpdateNotificationService().showUpdateAvailable(
            version: info.latestVersion,
            title: info.title,
            message: info.message,
            downloadUrl: info.updateUrl,
          );
        }

        return info;
      }
    } catch (e) {
      debugPrint('[AppUpdateService] checkRemoteUpdate error: $e');
    } finally {
      if (customClient == null) {
        client.close();
      }
    }

    return null;
  }

  /// Silently check for APK updates in background upon app startup.
  static Future<AppUpdateInfo?> checkForUpdateInBackground() async {
    try {
      return await checkRemoteUpdate(showStatusBarNotification: true);
    } catch (_) {
      return null;
    }
  }

  /// Launch the update URL in the browser or Google Play Store.
  static Future<bool> launchUpdateUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return await launchUrl(uri, mode: LaunchMode.platformDefault);
    } catch (e) {
      debugPrint('Error launching update URL: $e');
    }
    return false;
  }

  /// Trigger Android Package Installer for an already downloaded APK file,
  /// automatically requesting unknown-sources install permission on Android 8+ if needed.
  static Future<OpenResult?> installApkFile(String apkPath) async {
    if (apkPath.trim().isEmpty) return null;
    final file = File(apkPath);
    if (!file.existsSync()) return null;

    if (!kIsWeb && Platform.isAndroid) {
      try {
        final installStatus = await Permission.requestInstallPackages.status;
        if (!installStatus.isGranted) {
          await Permission.requestInstallPackages.request();
        }
      } catch (_) {}
    }

    final result = await OpenFilex.open(
      apkPath,
      type: 'application/vnd.android.package-archive',
    );
    if (result.type != ResultType.done) {
      debugPrint('[AppUpdateService] Hasil eksekusi installer: ${result.message}');
    }
    return result;
  }

  /// Open an HTTP GET request and follow up to 8 cross-host redirects
  /// (e.g., `github.com` -> `objects.githubusercontent.com`).
  static Future<HttpClientResponse> _openUrlFollowingRedirects(
    HttpClient client,
    Uri initialUri,
  ) async {
    Uri currentUri = initialUri;
    late HttpClientResponse response;

    for (int redirectCount = 0; redirectCount <= 8; redirectCount++) {
      final request = await client.getUrl(currentUri);
      request.headers.set('User-Agent', 'Sticko-App-Update-Checker');
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      request.followRedirects = false;
      response = await request.close();

      if (response.isRedirect ||
          response.statusCode == HttpStatus.movedPermanently ||
          response.statusCode == HttpStatus.found ||
          response.statusCode == HttpStatus.seeOther ||
          response.statusCode == HttpStatus.temporaryRedirect ||
          response.statusCode == HttpStatus.permanentRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain().catchError((_) {});
        if (location != null && location.isNotEmpty) {
          currentUri = currentUri.resolve(location);
          continue;
        }
      }
      break;
    }

    return response;
  }

  /// Download the APK directly and trigger Android Package Installer on completion.
  /// Automatically resolves dynamic GitHub release tags (`sticko-3`, `sticko-4`, ...) and
  /// versioned APK filenames (`sticko-app-1.0.5.apk`, `sticko-app-1.0.5`, `app-release.apk`).
  /// Calls [onProgress] with values ranging from 0.0 to 1.0 and streams progress to status bar.
  static Future<void> downloadAndInstallApk({
    required String apkUrl,
    required void Function(double progress) onProgress,
    String targetVersion = defaultCurrentVersion,
    bool showNotification = true,
    HttpClient? customClient,
    Directory? customSaveDirectory,
    bool triggerInstaller = true,
  }) async {
    final resolvedUrl = normalizeApkUrl(
      apkUrl,
      targetVersion: targetVersion,
    );

    // If in demo/test mode with a non-direct URL, simulate download progress
    if (!isDirectApkUrl(resolvedUrl) && !apkUrl.contains('github.com/')) {
      for (int i = 1; i <= 20; i++) {
        await Future.delayed(const Duration(milliseconds: 60));
        final p = i / 20.0;
        onProgress(p);
        if (showNotification) {
          AppUpdateNotificationService().showDownloadProgress(
            progress: (p * 100).toInt(),
            version: targetVersion,
          );
        }
      }
      if (showNotification) {
        await AppUpdateNotificationService().showDownloadComplete(
          apkPath: '',
          version: targetVersion,
        );
      }
      return;
    }

    final client = customClient ??
        (HttpClient()..connectionTimeout = const Duration(seconds: 20));
    try {
      final candidateUrls = <String>[];
      void addCandidate(String? url) {
        if (url == null) return;
        final u = url.trim();
        if (u.isNotEmpty && !candidateUrls.contains(u)) {
          candidateUrls.add(u);
        }
      }

      // 1. If targeting GitHub Releases, query GitHub API first to get exact asset URL
      if (apkUrl.contains('github.com/')) {
        final apiAssetUrl = await _resolveGitHubReleaseAssetApkUrl(
          client,
          rawUrl: apkUrl,
          targetVersion: targetVersion,
        );
        addCandidate(apiAssetUrl);
      }

      // 2. Add all normalized & fallback candidate URLs (tag-specific + latest + versioned filenames)
      for (final candidate in buildCandidateApkUrls(
        apkUrl,
        targetVersion: targetVersion,
      )) {
        addCandidate(candidate);
      }

      HttpClientResponse? validResponse;
      int lastStatusCode = 0;

      for (final candidateUrl in candidateUrls) {
        final uri = Uri.tryParse(candidateUrl);
        if (uri == null) continue;
        try {
          final res = await _openUrlFollowingRedirects(client, uri);
          lastStatusCode = res.statusCode;
          final mimeType =
              res.headers.contentType?.mimeType.toLowerCase() ?? '';

          // Ensure response is 200 OK and not an HTML web page
          if (res.statusCode == 200 && mimeType != 'text/html') {
            validResponse = res;
            break;
          } else {
            await res.drain().catchError((_) {});
          }
        } catch (e) {
          debugPrint(
            '[AppUpdateService] Candidate APK URL failed ($candidateUrl): $e',
          );
        }
      }

      if (validResponse == null) {
        if (showNotification) {
          await AppUpdateNotificationService().clearNotification();
        }
        throw Exception(
          'Server mengembalikan kode status ${lastStatusCode != 0 ? lastStatusCode : 404}',
        );
      }

      final response = validResponse;
      final contentLength = response.contentLength;
      final tempDir = customSaveDirectory ?? await getTemporaryDirectory();
      final cleanVer = cleanVersionName(targetVersion);
      final fileVersionSuffix =
          cleanVer.isNotEmpty ? cleanVer : targetVersion.replaceAll('+', '_');
      final savePath = '${tempDir.path}/sticko-app-$fileVersionSuffix.apk';
      final file = File(savePath);
      if (file.existsSync()) {
        file.deleteSync();
      }

      if (showNotification) {
        await AppUpdateNotificationService().showDownloadProgress(
          progress: 0,
          version: targetVersion,
        );
      }

      final sink = file.openWrite();
      int received = 0;

      try {
        await for (final chunk in response) {
          received += chunk.length;
          sink.add(chunk);
          if (contentLength > 0) {
            final progress = (received / contentLength).clamp(0.0, 1.0);
            onProgress(progress);
            if (showNotification) {
              AppUpdateNotificationService().showDownloadProgress(
                progress: (progress * 100).toInt(),
                version: targetVersion,
              );
            }
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      onProgress(1.0);

      if (showNotification) {
        await AppUpdateNotificationService().showDownloadComplete(
          apkPath: savePath,
          version: targetVersion,
        );
      }

      // Trigger Android package installer prompt automatically
      if (triggerInstaller) {
        await installApkFile(savePath);
      }
    } finally {
      if (customClient == null) {
        client.close();
      }
    }
  }

  /// Show the interactive Auto-Update (or Force-Update) dialog in the foreground.
  static Future<void> showUpdateDialog(
    BuildContext context,
    AppUpdateInfo updateInfo,
  ) async {
    if (_isDialogShowing || !context.mounted) return;
    _isDialogShowing = true;

    try {
      if (updateInfo.requiresForceUpdate) {
        await showForceUpdateDialog(
          context,
          title: updateInfo.title,
          message: updateInfo.message,
          updateUrl: updateInfo.updateUrl,
          targetVersion: updateInfo.latestVersion,
        );
      } else {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => _AutoUpdateDialog(updateInfo: updateInfo),
        );
      }
    } finally {
      _isDialogShowing = false;
    }
  }

  /// Show the non-dismissible Force Update dialog.
  static Future<void> showForceUpdateDialog(
    BuildContext context, {
    String title = 'New version available',
    String message = 'There are new features available,\nplease update your app',
    String updateUrl = defaultStoreUrl,
    String targetVersion = defaultCurrentVersion,
    VoidCallback? onUpdatePressed,
  }) async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withAlpha(120),
      builder: (ctx) => ForceUpdateDialog(
        title: title,
        message: message,
        updateUrl: updateUrl,
        targetVersion: targetVersion,
        onUpdatePressed: onUpdatePressed,
      ),
    );
  }
}

/// Interactive in-app update dialog displaying release notes, live download progress,
/// background status bar download support, and automatic installer execution.
class _AutoUpdateDialog extends StatefulWidget {
  final AppUpdateInfo updateInfo;

  const _AutoUpdateDialog({required this.updateInfo});

  @override
  State<_AutoUpdateDialog> createState() => _AutoUpdateDialogState();
}

class _AutoUpdateDialogState extends State<_AutoUpdateDialog> {
  bool _isDownloading = false;
  double _progress = 0.0;
  String? _errorMessage;

  Future<void> _startUpdate() async {
    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _errorMessage = null;
    });

    try {
      await AppUpdateService.downloadAndInstallApk(
        apkUrl: widget.updateInfo.updateUrl,
        targetVersion: widget.updateInfo.latestVersion,
        showNotification: true,
        onProgress: (p) {
          if (mounted) {
            setState(() {
              _progress = p;
            });
          }
        },
      );

      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _errorMessage = 'Gagal mengunduh APK pembaruan. Periksa koneksi internet Anda.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pct = (_progress * 100).clamp(0, 100).toInt();

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: Row(
        children: [
          const Icon(Icons.system_update_rounded, color: Color(0xFF128C7E), size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.updateInfo.title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF128C7E).withAlpha(30),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              'v${widget.updateInfo.currentVersion} → v${widget.updateInfo.latestVersion}',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF25D366),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            widget.updateInfo.message,
            style: const TextStyle(fontSize: 14, height: 1.45),
          ),
          if (_isDownloading) ...[
            const SizedBox(height: 18),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 7,
                backgroundColor: Colors.grey.withAlpha(50),
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF25D366)),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Mengunduh APK ($pct%) • Pantau juga di bilah status',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              _errorMessage!,
              style: const TextStyle(fontSize: 12.5, color: Colors.redAccent),
            ),
          ],
        ],
      ),
      actions: _isDownloading
          ? [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Latar Belakang'),
              ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Nanti'),
              ),
              if (_errorMessage != null)
                TextButton(
                  onPressed: () => AppUpdateService.launchUpdateUrl(
                    widget.updateInfo.updateUrl,
                  ),
                  child: const Text('Buka Browser'),
                ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF128C7E),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
                onPressed: _startUpdate,
                child: Text(_errorMessage != null ? 'Coba Lagi' : 'Perbarui Sekarang'),
              ),
            ],
    );
  }
}
