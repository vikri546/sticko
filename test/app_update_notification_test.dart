import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sticker_flutter/services/app_update_notification_service.dart';
import 'package:sticker_flutter/services/app_update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppUpdateNotificationService notificationService;

  setUp(() {
    notificationService = AppUpdateNotificationService();
    notificationService.resetForTesting();
  });

  tearDown(() {
    notificationService.resetForTesting();
  });

  group('AppUpdateNotificationService Status Bar Notification Tests', () {
    test('Initializes notification channel on Android', () async {
      String? invokedMethod;
      notificationService.setMockHandler((method, arguments) async {
        invokedMethod = method;
        return true;
      });

      final result = await notificationService.initialize();

      expect(result, isTrue);
      expect(invokedMethod, equals('initNotificationChannel'));
    });

    test('showUpdateAvailable sends correct payload for status bar notification', () async {
      String? invokedMethod;
      Map<String, dynamic>? capturedArgs;

      notificationService.setMockHandler((method, arguments) async {
        invokedMethod = method;
        capturedArgs = arguments;
        return true;
      });

      final success = await notificationService.showUpdateAvailable(
        version: '1.0.4',
        title: 'Pembaruan Sticko Tersedia',
        message: 'Versi 1.0.4 siap diunduh.',
        downloadUrl: 'https://example.com/sticko-1.0.4.apk',
      );

      expect(success, isTrue);
      expect(invokedMethod, equals('showUpdateNotification'));
      expect(capturedArgs?['version'], equals('1.0.4'));
      expect(capturedArgs?['title'], equals('Pembaruan Sticko Tersedia'));
      expect(capturedArgs?['body'], equals('Versi 1.0.4 siap diunduh.'));
      expect(capturedArgs?['downloadUrl'], equals('https://example.com/sticko-1.0.4.apk'));
      expect(notificationService.isNotificationActive, isTrue);
      expect(notificationService.lastNotifiedVersion, equals('1.0.4'));
    });

    test('showDownloadProgress streams progress and throttles redundant values', () async {
      final progressUpdates = <int>[];

      notificationService.setMockHandler((method, arguments) async {
        if (method == 'updateDownloadProgress') {
          progressUpdates.add(arguments?['progress'] as int);
        }
        return true;
      });

      await notificationService.showDownloadProgress(progress: 10, version: '1.0.4');
      await notificationService.showDownloadProgress(progress: 10, version: '1.0.4'); // duplicate
      await notificationService.showDownloadProgress(progress: 45, version: '1.0.4');
      await notificationService.showDownloadProgress(progress: 100, version: '1.0.4');

      expect(progressUpdates, equals([10, 45, 100]));
    });

    test('showDownloadComplete transitions status bar to installation ready state', () async {
      String? invokedMethod;
      Map<String, dynamic>? capturedArgs;

      notificationService.setMockHandler((method, arguments) async {
        invokedMethod = method;
        capturedArgs = arguments;
        return true;
      });

      final success = await notificationService.showDownloadComplete(
        apkPath: '/data/user/0/com.pkri.sticko/cache/app_update.apk',
        version: '1.0.4',
      );

      expect(success, isTrue);
      expect(invokedMethod, equals('showDownloadComplete'));
      expect(capturedArgs?['apkPath'], equals('/data/user/0/com.pkri.sticko/cache/app_update.apk'));
      expect(capturedArgs?['version'], equals('1.0.4'));
      expect(notificationService.isNotificationActive, isTrue);
    });

    test('clearNotification removes status bar notification', () async {
      String? invokedMethod;

      notificationService.setMockHandler((method, arguments) async {
        invokedMethod = method;
        return true;
      });

      await notificationService.showUpdateAvailable(version: '1.0.4');
      expect(notificationService.isNotificationActive, isTrue);

      final cleared = await notificationService.clearNotification();
      expect(cleared, isTrue);
      expect(invokedMethod, equals('clearNotification'));
      expect(notificationService.isNotificationActive, isFalse);
    });
  });

  group('AppUpdateService Remote Update & Status Bar Integration Tests', () {
    test('checkRemoteUpdate triggers status bar notification when new version detected', () async {
      bool notificationTriggered = false;
      String? notifiedVersion;

      notificationService.setMockHandler((method, arguments) async {
        if (method == 'showUpdateNotification') {
          notificationTriggered = true;
          notifiedVersion = arguments?['version'] as String?;
        }
        return true;
      });

      final mockClient = _MockHttpClient(
        responseBody: jsonEncode({
          'latest_version': '2.0.0',
          'min_required_version': '1.0.0',
          'title': 'Pembaruan Besar Sticko',
          'message': 'Versi 2.0.0 hadir dengan fitur baru!',
          'apk_url': 'https://github.com/vikri546/sticko/releases/download/v2.0.0/sticko.apk',
          'is_force_update': false,
        }),
      );

      final info = await AppUpdateService.checkRemoteUpdate(
        currentVersion: '1.0.2',
        checkUrl: 'https://example.com/version.json',
        customClient: mockClient,
        showStatusBarNotification: true,
      );

      expect(info, isNotNull);
      expect(info!.hasUpdate, isTrue);
      expect(info.latestVersion, equals('2.0.0'));
      expect(notificationTriggered, isTrue);
      expect(notifiedVersion, equals('2.0.0'));
    });

    test('checkRemoteUpdate does not trigger notification if current is up-to-date', () async {
      bool notificationTriggered = false;

      notificationService.setMockHandler((method, arguments) async {
        if (method == 'showUpdateNotification') {
          notificationTriggered = true;
        }
        return true;
      });

      final mockClient = _MockHttpClient(
        responseBody: jsonEncode({
          'latest_version': '1.0.0',
          'min_required_version': '1.0.0',
        }),
      );

      final info = await AppUpdateService.checkRemoteUpdate(
        currentVersion: '1.0.2',
        checkUrl: 'https://example.com/version.json',
        customClient: mockClient,
        showStatusBarNotification: true,
      );

      expect(info, isNotNull);
      expect(info!.hasUpdate, isFalse);
      expect(notificationTriggered, isFalse);
    });

    test('downloadAndInstallApk streams download progress to status bar', () async {
      final recordedProgress = <int>[];

      notificationService.setMockHandler((method, arguments) async {
        if (method == 'updateDownloadProgress') {
          recordedProgress.add(arguments?['progress'] as int);
        }
        return true;
      });

      await AppUpdateService.downloadAndInstallApk(
        apkUrl: 'https://example.com/test.apk.test',
        onProgress: (_) {},
        targetVersion: '1.1.0',
        showNotification: true,
      );

      expect(recordedProgress, isNotEmpty);
      expect(recordedProgress.last, equals(100));
    });
  });
}

/// Helper Mock HttpClient for unit testing
class _MockHttpClient implements HttpClient {
  final String responseBody;
  final int statusCode;

  _MockHttpClient({required this.responseBody}) : statusCode = 200;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    return _MockHttpClientRequest(responseBody: responseBody, statusCode: statusCode);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpClientRequest implements HttpClientRequest {
  final String responseBody;
  final int statusCode;

  _MockHttpClientRequest({required this.responseBody, required this.statusCode});

  @override
  final HttpHeaders headers = _MockHttpHeaders();

  @override
  Future<HttpClientResponse> close() async {
    return _MockHttpClientResponse(responseBody: responseBody, statusCode: statusCode);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpClientResponse extends Stream<List<int>> implements HttpClientResponse {
  final String responseBody;
  @override
  final int statusCode;

  _MockHttpClientResponse({required this.responseBody, required this.statusCode});

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable([utf8.encode(responseBody)]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
