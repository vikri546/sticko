import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sticker_flutter/services/app_update_notification_service.dart';
import 'package:sticker_flutter/services/app_update_service.dart';
import 'package:sticker_flutter/ui/screens/home_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppUpdateNotificationService notificationService;

  setUp(() {
    notificationService = AppUpdateNotificationService();
    notificationService.resetForTesting();
    AppUpdateService.resetForTesting();
  });

  tearDown(() {
    notificationService.resetForTesting();
    AppUpdateService.resetForTesting();
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
        currentVersion: '1.0.3',
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
        currentVersion: '1.0.3',
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

    test('normalizeApkUrl, buildCandidateApkUrls, and isDirectApkUrl handle dynamic tags (sticko-3, sticko-4) and sticko-app-<version> filenames', () {
      expect(
        AppUpdateService.normalizeApkUrl('https://github.com/vikri546/sticko/releases/latest'),
        equals('https://github.com/vikri546/sticko/releases/latest/download/app-release.apk'),
      );
      expect(
        AppUpdateService.normalizeApkUrl('https://github.com/vikri546/sticko/releases/tag/v1.0.4'),
        equals('https://github.com/vikri546/sticko/releases/download/v1.0.4/app-release.apk'),
      );
      expect(
        AppUpdateService.normalizeApkUrl(
          'https://github.com/vikri546/sticko/releases/tag/sticko-3',
          targetVersion: '1.0.5+6',
        ),
        equals('https://github.com/vikri546/sticko/releases/download/sticko-3/sticko-app-1.0.5.apk'),
      );
      expect(
        AppUpdateService.normalizeApkUrl(
          'https://github.com/vikri546/sticko/releases/tag/sticko-4',
          targetVersion: '1.0.6+7',
        ),
        equals('https://github.com/vikri546/sticko/releases/download/sticko-4/sticko-app-1.0.6.apk'),
      );

      final candidates = AppUpdateService.buildCandidateApkUrls(
        'https://github.com/vikri546/sticko/releases/tag/sticko-3',
        targetVersion: '1.0.5+6',
      );
      expect(
        candidates,
        containsAll(<String>[
          'https://github.com/vikri546/sticko/releases/download/sticko-3/sticko-app-1.0.5.apk',
          'https://github.com/vikri546/sticko/releases/download/sticko-3/sticko-app-1.0.5',
          'https://github.com/vikri546/sticko/releases/download/sticko-3/app-release.apk',
          'https://github.com/vikri546/sticko/releases/latest/download/sticko-app-1.0.5.apk',
        ]),
      );

      expect(
        AppUpdateService.isDirectApkUrl(
          'https://github.com/vikri546/sticko/releases/latest/download/app-release.apk',
        ),
        isTrue,
      );
      expect(
        AppUpdateService.isDirectApkUrl(
          'https://github.com/vikri546/sticko/releases/download/sticko-3/sticko-app-1.0.5',
        ),
        isTrue,
      );
      expect(
        AppUpdateService.isDirectApkUrl(
          'https://github.com/vikri546/sticko/releases/tag/sticko-3',
        ),
        isFalse,
      );
      expect(
        AppUpdateService.isDirectApkUrl(
          'https://github.com/vikri546/sticko/releases/download/v1.0.4/sticko.apk?raw=true',
        ),
        isTrue,
      );
      expect(
        AppUpdateService.isDirectApkUrl('https://example.com/test.apk.test'),
        isFalse,
      );
    });

    test('checkRemoteUpdate extracts version and APK download URL when GitHub tag is sticko-3 / sticko-4 and asset is sticko-app-1.0.5', () async {
      final mockClient = _MockHttpClient(
        responseBody: jsonEncode({
          'tag_name': 'sticko-3',
          'name': 'Sticko Release 1.0.5',
          'body': 'Pembaruan fitur stiker',
          'assets': [
            {
              'name': 'sticko-app-1.0.5',
              'content_type': 'application/vnd.android.package-archive',
              'browser_download_url':
                  'https://github.com/vikri546/sticko/releases/download/sticko-3/sticko-app-1.0.5',
            },
          ],
        }),
      );

      final info = await AppUpdateService.checkRemoteUpdate(
        currentVersion: '1.0.4+5',
        checkUrl: 'https://api.github.com/repos/vikri546/sticko/releases/latest',
        customClient: mockClient,
        showStatusBarNotification: false,
      );

      expect(info, isNotNull);
      expect(info!.hasUpdate, isTrue);
      expect(info.latestVersion, equals('1.0.5'));
      expect(
        info.updateUrl,
        equals(
          'https://github.com/vikri546/sticko/releases/download/sticko-3/sticko-app-1.0.5',
        ),
      );
    });

    test('version.json matches current app version and uses direct APK URL', () {
      final versionFile = File('version.json');
      expect(versionFile.existsSync(), isTrue);
      final data = jsonDecode(versionFile.readAsStringSync()) as Map<String, dynamic>;
      expect(data['latest_version'], equals(AppUpdateService.defaultCurrentVersion));
      expect(AppUpdateService.isDirectApkUrl(data['apk_url'].toString()), isTrue);
    });

    testWidgets('HomeScreen automatically displays status bar notification and update dialog on startup', (
      WidgetTester tester,
    ) async {
      bool statusBarNotified = false;
      notificationService.setMockHandler((method, arguments) async {
        if (method == 'showUpdateNotification') {
          statusBarNotified = true;
        }
        return null;
      });

      AppUpdateService.mockUpdateChecker = () async => const AppUpdateInfo(
            currentVersion: '1.0.3+4',
            latestVersion: '1.0.4+5',
            minRequiredVersion: '1.0.0',
            updateUrl: 'https://example.com/sticko-update.apk.test',
            title: 'Pembaruan Sticko Tersedia',
            message: 'Versi terbaru telah tersedia!',
          );

      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await tester.pump();
      await tester.pump();

      // Both status bar notification AND foreground dialog must appear automatically
      expect(statusBarNotified, isTrue);
      expect(find.text('Pembaruan Sticko Tersedia'), findsOneWidget);
      expect(find.text('v1.0.3+4 → v1.0.4+5'), findsOneWidget);
      expect(find.text('Perbarui Sekarang'), findsOneWidget);

      await tester.tap(find.text('Nanti'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Perbarui Sekarang'), findsNothing);
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
