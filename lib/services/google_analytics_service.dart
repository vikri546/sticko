import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Central Google Analytics 4 (GA4) Service for Sticko.
///
/// Implements the official Google Analytics 4 Measurement Protocol:
/// - Supports sending events directly to GA4 via HTTPS POST (`/mp/collect` and `/debug/mp/collect`).
/// - Operates seamlessly without requiring `google-services.json` or native Gradle plugins.
/// - Persists anonymous client identity, session tracking, and offline event queueing.
/// - Fully respects user privacy with opt-in/opt-out controls.
class GoogleAnalyticsService extends ChangeNotifier {
  static final GoogleAnalyticsService _instance = GoogleAnalyticsService._internal();
  factory GoogleAnalyticsService() => _instance;
  GoogleAnalyticsService._internal();

  static const String defaultMeasurementId = 'G-STICKO2026';
  static const String defaultApiSecret = 'sticko_ga4_secret';
  static const String gaEndpoint = 'https://www.google-analytics.com/mp/collect';
  static const String gaDebugEndpoint = 'https://www.google-analytics.com/debug/mp/collect';

  String _measurementId = defaultMeasurementId;
  String _apiSecret = defaultApiSecret;
  bool _isEnabled = true;
  bool _isDebugMode = kDebugMode;

  String? _clientId;
  int _sessionId = DateTime.now().millisecondsSinceEpoch;
  final List<Map<String, dynamic>> _eventQueue = [];
  bool _isInitialized = false;
  String? _customStorageDir;

  /// Custom HTTP handler for unit testing or custom networking.
  @visibleForTesting
  Future<int> Function(Uri uri, String jsonBody)? testHttpHandler;

  String get measurementId => _measurementId;
  String get apiSecret => _apiSecret;
  bool get isEnabled => _isEnabled;
  bool get isDebugMode => _isDebugMode;
  String get clientId => _clientId ?? 'anonymous_sticko_client';
  int get sessionId => _sessionId;
  int get queueLength => _eventQueue.length;
  bool get isInitialized => _isInitialized;
  List<Map<String, dynamic>> get eventQueue => List.unmodifiable(_eventQueue);

  /// Reset service state for isolated test execution.
  @visibleForTesting
  void resetForTesting({
    String? measurementId,
    String? apiSecret,
    bool? isEnabled,
    bool? isDebugMode,
    String? clientId,
    String? customStorageDir,
    Future<int> Function(Uri uri, String jsonBody)? httpHandler,
  }) {
    _measurementId = measurementId ?? defaultMeasurementId;
    _apiSecret = apiSecret ?? defaultApiSecret;
    _isEnabled = isEnabled ?? true;
    _isDebugMode = isDebugMode ?? false;
    _clientId = clientId ?? 'test_client_${DateTime.now().millisecondsSinceEpoch}';
    _sessionId = 1700000000;
    _eventQueue.clear();
    _isInitialized = true;
    _customStorageDir = customStorageDir;
    testHttpHandler = httpHandler;
    notifyListeners();
  }

  /// Initialize analytics, resolve client identity, and load offline queue.
  Future<void> initialize({
    String? measurementId,
    String? apiSecret,
    bool? isEnabled,
    bool? isDebugMode,
    String? customStorageDir,
  }) async {
    if (measurementId != null && measurementId.isNotEmpty) {
      _measurementId = measurementId;
    }
    if (apiSecret != null && apiSecret.isNotEmpty) {
      _apiSecret = apiSecret;
    }
    if (isEnabled != null) {
      _isEnabled = isEnabled;
    }
    if (isDebugMode != null) {
      _isDebugMode = isDebugMode;
    }
    if (customStorageDir != null) {
      _customStorageDir = customStorageDir;
    }

    _sessionId = DateTime.now().millisecondsSinceEpoch;

    try {
      await _loadSettingsFromDisk();
    } catch (e) {
      debugPrint('[GoogleAnalytics] Error loading settings: $e');
      _clientId ??= _generateRandomClientId();
    }

    _isInitialized = true;
    notifyListeners();

    // Attempt to flush any offline events stored previously
    if (_isEnabled && _eventQueue.isNotEmpty) {
      unawaited(flushQueue());
    }
  }

  /// Toggle analytics data collection.
  Future<void> setEnabled(bool enabled) async {
    _isEnabled = enabled;
    if (!enabled) {
      _eventQueue.clear();
    }
    notifyListeners();
    await _saveSettingsToDisk();
  }

  /// Update Google Analytics Measurement ID and API Secret credentials.
  Future<void> setCredentials({
    required String measurementId,
    required String apiSecret,
  }) async {
    _measurementId = measurementId.trim();
    _apiSecret = apiSecret.trim();
    notifyListeners();
    await _saveSettingsToDisk();
  }

  /// Log a custom GA4 event with optional key-value parameters.
  Future<bool> logEvent({
    required String name,
    Map<String, dynamic>? parameters,
  }) async {
    if (!_isEnabled) {
      if (_isDebugMode) {
        debugPrint('[GoogleAnalytics] Tracking disabled by user. Skipped: $name');
      }
      return false;
    }

    // Sanitize event name to comply with GA4 (alphanumeric + underscores, <= 40 chars)
    final sanitizedName = name.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_').take(40);

    final eventParams = <String, dynamic>{
      'session_id': _sessionId,
      'engagement_time_msec': 100,
      'platform': Platform.isAndroid ? 'Android' : (Platform.isIOS ? 'iOS' : 'Other'),
    };

    if (parameters != null) {
      parameters.forEach((key, value) {
        final sanitizedKey = key.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_').take(40);
        eventParams[sanitizedKey] = value;
      });
    }

    final eventItem = {
      'name': sanitizedName,
      'params': eventParams,
      'timestamp_micros': DateTime.now().microsecondsSinceEpoch,
    };

    _eventQueue.add(eventItem);
    notifyListeners();

    return await flushQueue();
  }

  /// Log a screen view event compatible with Google Analytics 4 standard `screen_view`.
  Future<bool> logScreenView({
    required String screenName,
    String? screenClass,
  }) async {
    return await logEvent(
      name: 'screen_view',
      parameters: {
        'screen_name': screenName,
        'screen_class': screenClass ?? screenName,
      },
    );
  }

  /// Convenience helper: App open event.
  Future<bool> logAppOpen() async {
    return await logEvent(name: 'app_open', parameters: {
      'app_version': '1.0.2',
    });
  }

  /// Convenience helper: Sticker pack created.
  Future<bool> logCreatePack({
    required String packName,
    required bool isAnimated,
  }) async {
    return await logEvent(
      name: 'create_sticker_pack',
      parameters: {
        'pack_name': packName,
        'is_animated': isAnimated ? 1 : 0,
      },
    );
  }

  /// Convenience helper: Sticker added to pack.
  Future<bool> logAddSticker({
    required String packId,
    required int stickerCount,
    required bool isAnimated,
  }) async {
    return await logEvent(
      name: 'add_sticker',
      parameters: {
        'pack_id': packId,
        'sticker_count': stickerCount,
        'is_animated': isAnimated ? 1 : 0,
      },
    );
  }

  /// Convenience helper: Add sticker pack to WhatsApp.
  Future<bool> logAddToWhatsApp({
    required String packId,
    required int stickerCount,
    required bool success,
  }) async {
    return await logEvent(
      name: 'add_to_whatsapp',
      parameters: {
        'pack_id': packId,
        'sticker_count': stickerCount,
        'success': success ? 1 : 0,
      },
    );
  }

  /// Convenience helper: Duplicate scan performed.
  Future<bool> logScanDuplicates({
    required int duplicatesFound,
  }) async {
    return await logEvent(
      name: 'scan_duplicate_stickers',
      parameters: {
        'duplicates_found': duplicatesFound,
      },
    );
  }

  /// Convenience helper: Duplicate stickers cleaned.
  Future<bool> logCleanDuplicates({
    required int cleanedCount,
    required int savedBytes,
  }) async {
    return await logEvent(
      name: 'clean_duplicate_stickers',
      parameters: {
        'cleaned_count': cleanedCount,
        'saved_bytes': savedBytes,
      },
    );
  }

  /// Convenience helper: Cloud/Local backup created.
  Future<bool> logBackupCreated({
    required int packCount,
    required int stickerCount,
  }) async {
    return await logEvent(
      name: 'backup_created',
      parameters: {
        'pack_count': packCount,
        'sticker_count': stickerCount,
      },
    );
  }

  /// Convenience helper: Cloud/Local backup restored.
  Future<bool> logBackupRestored({
    required int packCount,
  }) async {
    return await logEvent(
      name: 'backup_restored',
      parameters: {
        'pack_count': packCount,
      },
    );
  }

  /// Flush pending queued events to Google Analytics 4 Measurement Protocol.
  Future<bool> flushQueue() async {
    if (!_isEnabled || _eventQueue.isEmpty) return true;

    // GA4 allows max 25 events per request
    final batch = List<Map<String, dynamic>>.from(_eventQueue.take(25));
    final eventsPayload = batch.map((e) => {
          'name': e['name'],
          'params': e['params'],
        }).toList();

    final payload = {
      'client_id': clientId,
      'non_personalized_ads': true,
      'events': eventsPayload,
    };

    final jsonString = jsonEncode(payload);
    final endpointBase = _isDebugMode ? gaDebugEndpoint : gaEndpoint;
    final uri = Uri.parse('$endpointBase?measurement_id=$_measurementId&api_secret=$_apiSecret');

    try {
      int statusCode;
      if (testHttpHandler != null) {
        statusCode = await testHttpHandler!(uri, jsonString);
      } else {
        statusCode = await _sendHttpRequest(uri, jsonString);
      }

      // GA4 /mp/collect returns 200, 204 on success
      if (statusCode >= 200 && statusCode < 300) {
        _eventQueue.removeRange(0, batch.length);
        notifyListeners();
        await _saveSettingsToDisk();
        if (_isDebugMode) {
          debugPrint('[GoogleAnalytics] Dispatched ${batch.length} event(s) to GA4 ($statusCode).');
        }
        return true;
      } else {
        if (_isDebugMode) {
          debugPrint('[GoogleAnalytics] GA4 server returned $statusCode. Events retained in queue.');
        }
        await _saveSettingsToDisk();
        return false;
      }
    } catch (e) {
      if (_isDebugMode) {
        debugPrint('[GoogleAnalytics] Network error dispatching events: $e. Events retained in queue.');
      }
      await _saveSettingsToDisk();
      return false;
    }
  }

  /// Clear the local offline event queue.
  void clearQueue() {
    _eventQueue.clear();
    notifyListeners();
  }

  Future<int> _sendHttpRequest(Uri uri, String jsonBody) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonBody);
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close();
    }
  }

  Future<File?> _getStorageFile() async {
    if (_customStorageDir != null) {
      return File('$_customStorageDir/google_analytics_settings.json');
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      return File('${dir.path}/google_analytics_settings.json');
    } catch (_) {
      // Safe fallback when running in tests without path_provider channel
      return null;
    }
  }

  Future<void> _loadSettingsFromDisk() async {
    try {
      final file = await _getStorageFile();
      if (file != null && await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content) as Map<String, dynamic>;
        _measurementId = data['measurement_id'] as String? ?? _measurementId;
        _apiSecret = data['api_secret'] as String? ?? _apiSecret;
        _isEnabled = data['is_enabled'] as bool? ?? _isEnabled;
        _clientId = data['client_id'] as String?;

        final queued = data['queue'] as List<dynamic>?;
        if (queued != null) {
          _eventQueue.clear();
          for (final item in queued) {
            if (item is Map<String, dynamic>) {
              _eventQueue.add(item);
            }
          }
        }
      }
    } catch (_) {}
    _clientId ??= _generateRandomClientId();
  }

  Future<void> _saveSettingsToDisk() async {
    try {
      final file = await _getStorageFile();
      if (file == null) return;
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      final data = {
        'measurement_id': _measurementId,
        'api_secret': _apiSecret,
        'is_enabled': _isEnabled,
        'client_id': clientId,
        'queue': _eventQueue.take(100).toList(), // Limit offline queue to 100 items
      };
      await file.writeAsString(jsonEncode(data));
    } catch (_) {
      // Ignored for testing and background persistence resilience
    }
  }

  String _generateRandomClientId() {
    final rand = Random.secure();
    final hexDigits = List<int>.generate(16, (_) => rand.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'sticko_$hexDigits';
  }
}

/// Automatically tracks screen views across the application as users navigate.
class AnalyticsRouteObserver extends NavigatorObserver {
  final GoogleAnalyticsService analytics = GoogleAnalyticsService();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _logRoute(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute != null) {
      _logRoute(newRoute);
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (previousRoute != null) {
      _logRoute(previousRoute);
    }
  }

  void _logRoute(Route<dynamic> route) {
    String? screenName = route.settings.name;
    if (screenName == null || screenName.isEmpty) {
      // Fallback to widget class name or route type
      screenName = route.runtimeType.toString();
      if (screenName.startsWith('MaterialPageRoute') || screenName.startsWith('PageRouteBuilder')) {
        screenName = 'Screen';
      }
    }
    analytics.logScreenView(screenName: screenName);
  }
}

extension _StringTruncate on String {
  String take(int length) => this.length <= length ? this : substring(0, length);
}
