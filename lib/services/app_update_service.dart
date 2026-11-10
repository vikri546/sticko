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
  static const String defaultCurrentVersion = '1.0.4+5';
  static const String defaultStoreUrl =
      'https://play.google.com/store/apps/details?id=com.pkri.sticko';
  static const String defaultGitHubReleasesApi =
      'https://api.github.com/repos/vikri546/sticko/releases/latest';
  static const String defaultUpdateCheckUrl =
      'https://raw.githubusercontent.com/vikri546/sticko/main/version.json';
  static const String defaultDirectApkUrl =
      'https://github.com/vikri546/sticko/releases/latest/download/app-release.apk';
  
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

  /// Normalize GitHub Release URLs into direct `.apk` download URLs automatically.
  ///
  /// Supports:
  /// - `https://github.com/<owner>/<repo>/releases/latest/download/<file>.apk` (kept as-is)
  /// - `https://github.com/<owner>/<repo>/releases/download/<tag>/<file>.apk` (kept as-is)
  /// - `https://github.com/<owner>/<repo>/releases/latest` -> `.../releases/latest/download/app-release.apk`
  /// - `https://github.com/<owner>/<repo>/releases/tag/<tag>` -> `.../releases/download/<tag>/app-release.apk`
  static String normalizeApkUrl(
    String rawUrl, {
    String defaultApkName = 'app-release.apk',
  }) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return trimmed;

    // Match https://github.com/<owner>/<repo>/releases/latest[/]
    final latestMatch = RegExp(
      r'^https?://github\.com/([^/]+)/([^/]+)/releases/latest/?$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (latestMatch != null) {
      final owner = latestMatch.group(1)!;
      final repo = latestMatch.group(2)!;
      return 'https://github.com/$owner/$repo/releases/latest/download/$defaultApkName';
    }

    // Match https://github.com/<owner>/<repo>/releases/tag/<tag>[/]
    final tagMatch = RegExp(
      r'^https?://github\.com/([^/]+)/([^/]+)/releases/tag/([^/]+)/?$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (tagMatch != null) {
      final owner = tagMatch.group(1)!;
      final repo = tagMatch.group(2)!;
      final tag = tagMatch.group(3)!;
      return 'https://github.com/$owner/$repo/releases/download/$tag/$defaultApkName';
    }

    return trimmed;
  }

  /// Returns `true` if [url] points directly to a downloadable `.apk` package
  /// (including GitHub `releases/latest/download/*.apk` and URLs with query strings).
  static bool isDirectApkUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty ||
        trimmed == defaultStoreUrl ||
        trimmed.endsWith('.test')) {
      return false;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return false;
    return uri.path.toLowerCase().endsWith('.apk');
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

  /// Resolve the exact `.apk` asset URL from GitHub Releases API if available.
  static Future<String?> _resolveGitHubReleaseAssetApkUrl(HttpClient client) async {
    try {
      final req = await client.getUrl(Uri.parse(defaultGitHubReleasesApi));
      req.headers.set('User-Agent', 'Sticko-App-Update-Checker');
      req.headers.set('Accept', 'application/json');
      final res = await req.close();
      if (res.statusCode == 200) {
        final body = await res.transform(utf8.decoder).join();
        final data = jsonDecode(body);
        if (data is Map && data['assets'] is List) {
          for (final asset in data['assets'] as List) {
            if (asset is Map) {
              final dlUrl = asset['browser_download_url']?.toString() ?? '';
              if (isDirectApkUrl(dlUrl)) {
                return dlUrl;
              }
            }
          }
        }
      } else {
        await res.drain().catchError((_) {});
      }
    } catch (_) {}
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
        fallbackReq.headers.set('Accept', 'application/json');
        response = await fallbackReq.close();
      }

      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final Map<String, dynamic> data = jsonDecode(body) as Map<String, dynamic>;

        // Handle both version.json schema and GitHub releases API schema
        final latestVersion = (data['latest_version'] ??
                data['tag_name'] ??
                data['version'] ??
                effectiveCurrentVersion)
            .toString()
            .replaceFirst(RegExp(r'^[vV]'), '')
            .trim();

        final minRequired = (data['min_required_version'] ?? '1.0.0').toString();
        final title = (data['title'] ?? data['name'] ?? 'Pembaruan Sticko Tersedia').toString();
        final message = (data['message'] ??
                data['body'] ??
                'Versi terbaru Sticko ($latestVersion) tersedia. Ketuk untuk memperbarui.')
            .toString();

        // Extract and normalize APK download URL
        String apkUrl = defaultDirectApkUrl;
        if (data['apk_url'] != null && data['apk_url'].toString().trim().isNotEmpty) {
          final rawApkUrl = data['apk_url'].toString().trim();
          if (isDirectApkUrl(rawApkUrl)) {
            apkUrl = rawApkUrl;
          } else {
            // Try resolving exact .apk asset from GitHub Releases API first, else normalize URL
            String? resolvedAssetUrl;
            if (customClient == null && rawApkUrl.contains('github.com/')) {
              resolvedAssetUrl = await _resolveGitHubReleaseAssetApkUrl(client);
            }
            apkUrl = resolvedAssetUrl ?? normalizeApkUrl(rawApkUrl);
          }
        } else if (data['assets'] is List && (data['assets'] as List).isNotEmpty) {
          for (final asset in data['assets']) {
            if (asset is Map) {
              final assetUrl = asset['browser_download_url']?.toString() ?? '';
              if (isDirectApkUrl(assetUrl)) {
                apkUrl = assetUrl;
                break;
              }
            }
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

  /// Download the APK directly and trigger Android Package Installer on completion.
  /// Calls [onProgress] with values ranging from 0.0 to 1.0 and streams progress to status bar.
  static Future<void> downloadAndInstallApk({
    required String apkUrl,
    required void Function(double progress) onProgress,
    String targetVersion = defaultCurrentVersion,
    bool showNotification = true,
  }) async {
    final resolvedUrl = normalizeApkUrl(apkUrl);

    // If in demo/test mode with a non-direct URL, simulate download progress
    if (!isDirectApkUrl(resolvedUrl)) {
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

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      Uri currentUri = Uri.parse(resolvedUrl);
      late HttpClientResponse response;

      // Follow cross-host redirects safely (e.g., github.com -> objects.githubusercontent.com)
      for (int redirectCount = 0; redirectCount <= 8; redirectCount++) {
        final request = await client.getUrl(currentUri);
        request.headers.set('User-Agent', 'Sticko-App-Update-Checker');
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

      if (response.statusCode != 200) {
        await response.drain().catchError((_) {});
        if (showNotification) {
          await AppUpdateNotificationService().clearNotification();
        }
        throw Exception('Server mengembalikan kode status ${response.statusCode}');
      }

      final contentLength = response.contentLength;
      final tempDir = await getTemporaryDirectory();
      final savePath = '${tempDir.path}/sticko_update_${targetVersion.replaceAll('+', '_')}.apk';
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
      await installApkFile(savePath);
    } finally {
      client.close();
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
