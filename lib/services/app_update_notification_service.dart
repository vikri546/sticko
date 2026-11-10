import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Service responsible for managing Android Status Bar system notifications
/// strictly and exclusively dedicated to APK version updates and download progress.
class AppUpdateNotificationService {
  static final AppUpdateNotificationService _instance =
      AppUpdateNotificationService._internal();

  factory AppUpdateNotificationService() => _instance;

  AppUpdateNotificationService._internal();

  static const String channelName = 'com.pkri.sticko/update_notifications';
  final MethodChannel _channel = const MethodChannel(channelName);

  bool _isInitialized = false;
  bool _isNotificationActive = false;
  String? _lastNotifiedVersion;
  int _lastProgress = -1;

  void Function(Map<String, dynamic> payload)? _onNotificationTapped;

  // Testing hook
  Future<dynamic> Function(String method, Map<String, dynamic>? arguments)?
      _mockHandler;

  /// Visible for unit testing to override platform channel calls.
  @visibleForTesting
  void setMockHandler(
    Future<dynamic> Function(String method, Map<String, dynamic>? arguments)?
        handler,
  ) {
    _mockHandler = handler;
  }

  /// Register a listener invoked when the user taps an APK update status bar notification.
  void setOnNotificationTapListener(
    void Function(Map<String, dynamic> payload)? listener,
  ) {
    _onNotificationTapped = listener;
  }

  /// Simulate a status bar notification tap in tests.
  @visibleForTesting
  void simulateNotificationTap(Map<String, dynamic> payload) {
    _onNotificationTapped?.call(payload);
  }

  /// Whether an APK update notification is currently shown in the status bar.
  bool get isNotificationActive => _isNotificationActive;

  /// The version string associated with the active update notification.
  String? get lastNotifiedVersion => _lastNotifiedVersion;

  /// Ensure Android 13+ (API 33+) runtime POST_NOTIFICATIONS permission is granted
  /// so status bar notifications are visible to the user.
  Future<bool> ensurePermissionGranted() async {
    if (_mockHandler != null) return true;
    if (kIsWeb || !Platform.isAndroid) return true;

    try {
      final status = await Permission.notification.status;
      if (status.isGranted) return true;
      if (status.isDenied) {
        final requested = await Permission.notification.request();
        return requested.isGranted;
      }
      return false;
    } catch (e) {
      debugPrint('[AppUpdateNotificationService] ensurePermissionGranted error: $e');
      return true;
    }
  }

  /// Initialize the Android NotificationChannel for APK updates and listen for tap callbacks.
  Future<bool> initialize() async {
    if (_isInitialized) return true;
    try {
      if (_mockHandler != null) {
        await _mockHandler!('initNotificationChannel', null);
      } else {
        _channel.setMethodCallHandler((call) async {
          if (call.method == 'onNotificationTapped' && call.arguments is Map) {
            final raw = Map<Object?, Object?>.from(call.arguments as Map);
            final payload = <String, dynamic>{};
            raw.forEach((key, value) {
              if (key != null) {
                payload[key.toString()] = value;
              }
            });
            _onNotificationTapped?.call(payload);
          }
        });
        await _channel.invokeMethod('initNotificationChannel');
      }
      _isInitialized = true;
      return true;
    } catch (e) {
      debugPrint('[AppUpdateNotificationService] Failed to initialize channel: $e');
      return false;
    }
  }

  /// Retrieve the installed APK version ("versionName+versionCode") from native PackageManager.
  Future<String?> getInstalledAppVersion() async {
    try {
      final dynamic res = _mockHandler != null
          ? await _mockHandler!('getAppVersion', null)
          : await _channel.invokeMethod('getAppVersion');
      if (res is String && res.trim().isNotEmpty) {
        return res.trim();
      }
    } catch (_) {}
    return null;
  }

  /// Consume any cold-start notification tap payload stored by MainActivity.
  Future<Map<String, dynamic>?> consumePendingNotificationAction() async {
    try {
      final dynamic res = _mockHandler != null
          ? await _mockHandler!('consumePendingNotificationAction', null)
          : await _channel.invokeMethod('consumePendingNotificationAction');
      if (res is Map) {
        final payload = <String, dynamic>{};
        res.forEach((key, value) {
          if (key != null) {
            payload[key.toString()] = value;
          }
        });
        return payload;
      }
    } catch (_) {}
    return null;
  }

  /// Check whether system status bar notifications are enabled by the user.
  Future<bool> areNotificationsEnabled() async {
    try {
      if (_mockHandler != null) {
        final res = await _mockHandler!('areNotificationsEnabled', null);
        return res as bool? ?? true;
      }
      final bool? enabled =
          await _channel.invokeMethod<bool>('areNotificationsEnabled');
      return enabled ?? true;
    } catch (e) {
      debugPrint('[AppUpdateNotificationService] areNotificationsEnabled error: $e');
      return true;
    }
  }

  /// Shows an alert on the system status bar notifying that a new Sticko APK version is available.
  Future<bool> showUpdateAvailable({
    required String version,
    String? title,
    String? message,
    String? downloadUrl,
  }) async {
    try {
      await ensurePermissionGranted();
      await initialize();
      final effectiveTitle = title ?? 'Pembaruan Sticko Tersedia';
      final effectiveBody = message ??
          'Versi terbaru ($version) telah dirilis. Ketuk untuk memperbarui aplikasi.';

      final args = {
        'title': effectiveTitle,
        'body': effectiveBody,
        'version': version,
        'downloadUrl': downloadUrl ?? '',
      };

      if (_mockHandler != null) {
        await _mockHandler!('showUpdateNotification', args);
      } else {
        await _channel.invokeMethod('showUpdateNotification', args);
      }

      _isNotificationActive = true;
      _lastNotifiedVersion = version;
      _lastProgress = -1;
      return true;
    } catch (e) {
      debugPrint('[AppUpdateNotificationService] showUpdateAvailable error: $e');
      return false;
    }
  }

  /// Updates the status bar notification in real-time with download progress (0% - 100%).
  Future<bool> showDownloadProgress({
    required int progress,
    int max = 100,
    required String version,
    String? title,
    String? body,
  }) async {
    // Throttle duplicate progress numbers to avoid spamming platform calls
    final clamped = progress.clamp(0, max);
    if (clamped == _lastProgress && clamped != 0 && clamped != max) {
      return true;
    }
    _lastProgress = clamped;

    try {
      await initialize();
      final effectiveTitle = title ?? 'Mengunduh Pembaruan Sticko';
      final effectiveBody = body ?? 'Progres unduhan: $clamped%';

      final args = {
        'progress': clamped,
        'max': max,
        'version': version,
        'title': effectiveTitle,
        'body': effectiveBody,
      };

      if (_mockHandler != null) {
        await _mockHandler!('updateDownloadProgress', args);
      } else {
        await _channel.invokeMethod('updateDownloadProgress', args);
      }

      _isNotificationActive = true;
      return true;
    } catch (e) {
      debugPrint('[AppUpdateNotificationService] showDownloadProgress error: $e');
      return false;
    }
  }

  /// Updates the status bar notification once download finishes and prompts the user to install the APK.
  Future<bool> showDownloadComplete({
    required String apkPath,
    required String version,
    String? title,
    String? message,
  }) async {
    try {
      await initialize();
      final effectiveTitle = title ?? 'Pembaruan Sticko Siap Dipasang';
      final effectiveBody = message ??
          'Unduhan Sticko $version selesai. Ketuk untuk memasang versi terbaru.';

      final args = {
        'apkPath': apkPath,
        'version': version,
        'title': effectiveTitle,
        'body': effectiveBody,
      };

      if (_mockHandler != null) {
        await _mockHandler!('showDownloadComplete', args);
      } else {
        await _channel.invokeMethod('showDownloadComplete', args);
      }

      _isNotificationActive = true;
      _lastProgress = 100;
      return true;
    } catch (e) {
      debugPrint('[AppUpdateNotificationService] showDownloadComplete error: $e');
      return false;
    }
  }

  /// Cancels and removes the APK update notification from the status bar.
  Future<bool> clearNotification() async {
    try {
      if (_mockHandler != null) {
        await _mockHandler!('clearNotification', null);
      } else {
        await _channel.invokeMethod('clearNotification');
      }
      _isNotificationActive = false;
      _lastProgress = -1;
      return true;
    } catch (e) {
      debugPrint('[AppUpdateNotificationService] clearNotification error: $e');
      return false;
    }
  }

  /// Reset internal state for testing.
  @visibleForTesting
  void resetForTesting() {
    _isInitialized = false;
    _isNotificationActive = false;
    _lastNotifiedVersion = null;
    _lastProgress = -1;
    _mockHandler = null;
    _onNotificationTapped = null;
  }
}
