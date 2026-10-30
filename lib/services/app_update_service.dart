import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
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

/// Service that handles app version comparison, remote check, and APK download & installation.
class AppUpdateService {
  static const String defaultCurrentVersion = '1.0.2+3';
  static const String defaultStoreUrl =
      'https://play.google.com/store/apps/details?id=com.pkri.sticko';
  static const String defaultGitHubReleasesApi =
      'https://api.github.com/repos/vikri546/sticko/releases/latest';
  static const String defaultUpdateCheckUrl =
      'https://raw.githubusercontent.com/vikri546/sticko/main/version.json';

  /// Compare two semantic version strings (e.g., '1.0.0' vs '1.1.0' or 'v1.0.0' vs 'v1.1.0').
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

  /// Check remote server or GitHub for new APK updates in real-time.
  /// If an update is detected, automatically displays a system status bar notification.
  static Future<AppUpdateInfo?> checkRemoteUpdate({
    String currentVersion = defaultCurrentVersion,
    String? checkUrl,
    HttpClient? customClient,
    bool showStatusBarNotification = true,
  }) async {
    final targetUrl = checkUrl ?? defaultUpdateCheckUrl;
    final client = customClient ?? HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);

    try {
      final request = await client.getUrl(Uri.parse(targetUrl));
      request.headers.set('User-Agent', 'Sticko-App-Update-Checker');
      request.headers.set('Accept', 'application/json');
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
                currentVersion)
            .toString()
            .replaceFirst('v', '')
            .trim();

        final minRequired = (data['min_required_version'] ?? '1.0.0').toString();
        final title = (data['title'] ?? data['name'] ?? 'Pembaruan Sticko Tersedia').toString();
        final message = (data['message'] ??
                data['body'] ??
                'Versi terbaru Sticko ($latestVersion) tersedia. Ketuk untuk memperbarui.')
            .toString();

        // Extract APK url if available
        String apkUrl = defaultStoreUrl;
        if (data['apk_url'] != null) {
          apkUrl = data['apk_url'].toString();
        } else if (data['assets'] is List && (data['assets'] as List).isNotEmpty) {
          for (final asset in data['assets']) {
            if (asset is Map && asset['browser_download_url']?.toString().endsWith('.apk') == true) {
              apkUrl = asset['browser_download_url'].toString();
              break;
            }
          }
        }

        final isForce = data['is_force_update'] as bool? ?? false;

        final info = AppUpdateInfo(
          currentVersion: currentVersion,
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
  static Future<void> checkForUpdateInBackground() async {
    try {
      await checkRemoteUpdate(showStatusBarNotification: true);
    } catch (_) {}
  }

  /// Launch the update URL in the browser or Google Play Store.
  static Future<bool> launchUpdateUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('Error launching update URL: $e');
    }
    return false;
  }

  /// Download the APK directly and trigger Android Package Installer on completion.
  /// Calls [onProgress] with values ranging from 0.0 to 1.0 and streams progress to status bar.
  static Future<void> downloadAndInstallApk({
    required String apkUrl,
    required void Function(double progress) onProgress,
    String targetVersion = '1.0.3',
    bool showNotification = true,
  }) async {
    // If in demo/test mode with a non-direct URL, simulate download progress
    if (apkUrl.isEmpty ||
        apkUrl == defaultStoreUrl ||
        apkUrl.endsWith('.test') ||
        !apkUrl.endsWith('.apk')) {
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

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    final request = await client.getUrl(Uri.parse(apkUrl));
    request.followRedirects = true;
    request.maxRedirects = 8;
    final response = await request.close();

    if (response.statusCode != 200) {
      if (showNotification) {
        await AppUpdateNotificationService().clearNotification();
      }
      throw Exception('Server mengembalikan kode status ${response.statusCode}');
    }

    final contentLength = response.contentLength;
    final tempDir = await getTemporaryDirectory();
    final savePath = '${tempDir.path}/app_update.apk';
    final file = File(savePath);
    if (file.existsSync()) {
      file.deleteSync();
    }

    final sink = file.openWrite();
    int received = 0;

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

    await sink.flush();
    await sink.close();
    onProgress(1.0);

    if (showNotification) {
      await AppUpdateNotificationService().showDownloadComplete(
        apkPath: savePath,
        version: targetVersion,
      );
    }

    // Trigger Android package installer prompt automatically
    final result = await OpenFilex.open(
      savePath,
      type: 'application/vnd.android.package-archive',
    );

    if (result.type != ResultType.done) {
      debugPrint('Hasil eksekusi installer: ${result.message}');
    }
  }

  /// Show the non-dismissible Force Update dialog.
  static Future<void> showForceUpdateDialog(
    BuildContext context, {
    String title = 'New version available',
    String message = 'There are new features available,\nplease update your app',
    String updateUrl = defaultStoreUrl,
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
        onUpdatePressed: onUpdatePressed,
      ),
    );
  }
}
