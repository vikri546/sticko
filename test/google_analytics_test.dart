import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sticker_flutter/services/google_analytics_service.dart';
import 'package:sticker_flutter/ui/screens/permissions_preferences_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  late GoogleAnalyticsService analytics;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ga_test_');
    analytics = GoogleAnalyticsService();
    analytics.resetForTesting(
      customStorageDir: tempDir.path,
      measurementId: 'G-TEST123456',
      apiSecret: 'test_secret_xyz',
      isEnabled: true,
      isDebugMode: true,
      clientId: 'test_client_001',
    );
  });

  tearDown(() async {
    analytics.clearQueue();
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  group('GoogleAnalyticsService Core Tests', () {
    test('Initialization resolves client ID and settings', () async {
      await analytics.initialize(
        customStorageDir: tempDir.path,
        measurementId: 'G-MYCUSTOMID',
      );

      expect(analytics.measurementId, equals('G-MYCUSTOMID'));
      expect(analytics.isEnabled, isTrue);
      expect(analytics.clientId, isNotEmpty);
      expect(analytics.sessionId, isPositive);
    });

    test('Dispatches event successfully via mock HTTP handler', () async {
      Uri? capturedUri;
      Map<String, dynamic>? capturedBody;

      analytics.resetForTesting(
        customStorageDir: tempDir.path,
        clientId: 'test_client_001',
        httpHandler: (uri, body) async {
          capturedUri = uri;
          capturedBody = jsonDecode(body) as Map<String, dynamic>;
          return 204; // GA4 success code
        },
      );

      final success = await analytics.logEvent(
        name: 'test_event',
        parameters: {'score': 100, 'label': 'awesome'},
      );

      expect(success, isTrue);
      expect(capturedUri, isNotNull);
      expect(capturedUri.toString(), contains('measurement_id='));
      expect(capturedBody, isNotNull);
      expect(capturedBody!['client_id'], equals('test_client_001'));

      final events = capturedBody!['events'] as List<dynamic>;
      expect(events.length, equals(1));
      expect(events[0]['name'], equals('test_event'));
      expect(events[0]['params']['score'], equals(100));
      expect(analytics.queueLength, equals(0));
    });

    test('Queues events when HTTP request fails and flushes on recovery', () async {
      int callCount = 0;

      analytics.resetForTesting(
        customStorageDir: tempDir.path,
        httpHandler: (uri, body) async {
          callCount++;
          if (callCount == 1) {
            return 500; // Simulated server error
          }
          return 200; // Recovery
        },
      );

      // First call fails -> event should be retained in queue
      final firstResult = await analytics.logEvent(name: 'event_offline');
      expect(firstResult, isFalse);
      expect(analytics.queueLength, equals(1));

      // Second call succeeds -> queue should be flushed
      final secondResult = await analytics.logEvent(name: 'event_online');
      expect(secondResult, isTrue);
      expect(analytics.queueLength, equals(0));
    });

    test('Respects user opt-out: setEnabled(false) suppresses tracking and clears queue', () async {
      int requestCount = 0;

      analytics.resetForTesting(
        customStorageDir: tempDir.path,
        httpHandler: (uri, body) async {
          requestCount++;
          return 200;
        },
      );

      await analytics.setEnabled(false);
      expect(analytics.isEnabled, isFalse);

      final logged = await analytics.logEvent(name: 'user_action');
      expect(logged, isFalse);
      expect(requestCount, equals(0));
      expect(analytics.queueLength, equals(0));
    });

    test('Sanitizes event names and parameter keys according to GA4 specs', () async {
      Map<String, dynamic>? payload;

      analytics.resetForTesting(
        customStorageDir: tempDir.path,
        httpHandler: (uri, body) async {
          payload = jsonDecode(body) as Map<String, dynamic>;
          return 200;
        },
      );

      await analytics.logEvent(
        name: 'Sticker Pack: Created @2026!',
        parameters: {
          'Pack Name#1': 'Memes',
        },
      );

      expect(payload, isNotNull);
      final events = payload!['events'] as List<dynamic>;
      expect(events[0]['name'], equals('Sticker_Pack__Created__2026_'));
      expect(events[0]['params']['Pack_Name_1'], equals('Memes'));
    });

    test('Convenience methods construct correct GA4 event schemas', () async {
      final loggedEvents = <String>[];

      analytics.resetForTesting(
        customStorageDir: tempDir.path,
        httpHandler: (uri, body) async {
          final data = jsonDecode(body) as Map<String, dynamic>;
          final events = data['events'] as List<dynamic>;
          for (final ev in events) {
            loggedEvents.add(ev['name'] as String);
          }
          return 200;
        },
      );

      await analytics.logAppOpen();
      await analytics.logCreatePack(packName: 'Cute Cats', isAnimated: false);
      await analytics.logAddSticker(packId: 'pack_1', stickerCount: 5, isAnimated: true);
      await analytics.logAddToWhatsApp(packId: 'pack_1', stickerCount: 5, success: true);
      await analytics.logScanDuplicates(duplicatesFound: 3);
      await analytics.logCleanDuplicates(cleanedCount: 2, savedBytes: 102400);
      await analytics.logBackupCreated(packCount: 4, stickerCount: 40);
      await analytics.logBackupRestored(packCount: 4);

      expect(loggedEvents, containsAll([
        'app_open',
        'create_sticker_pack',
        'add_sticker',
        'add_to_whatsapp',
        'scan_duplicate_stickers',
        'clean_duplicate_stickers',
        'backup_created',
        'backup_restored',
      ]));
    });

    test('AnalyticsRouteObserver automatically captures screen_view events', () async {
      final recordedScreens = <String>[];

      analytics.resetForTesting(
        customStorageDir: tempDir.path,
        httpHandler: (uri, body) async {
          final data = jsonDecode(body) as Map<String, dynamic>;
          final events = data['events'] as List<dynamic>;
          for (final ev in events) {
            if (ev['name'] == 'screen_view') {
              recordedScreens.add(ev['params']['screen_name'] as String);
            }
          }
          return 200;
        },
      );

      final observer = AnalyticsRouteObserver();
      final route1 = MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'HomeScreen'),
        builder: (_) => const SizedBox(),
      );
      final route2 = MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'PackDetailScreen'),
        builder: (_) => const SizedBox(),
      );

      observer.didPush(route1, null);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      observer.didPush(route2, route1);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(recordedScreens, contains('HomeScreen'));
      expect(recordedScreens, contains('PackDetailScreen'));
    });
  });

  group('PermissionsPreferencesScreen Google Analytics Integration UI Tests', () {
    testWidgets('Keeps Google Analytics active in background while hidden from screen UI', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      analytics.resetForTesting(
        customStorageDir: tempDir.path,
        isEnabled: true,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: PermissionsPreferencesScreen(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Verify that analytics is active in background
      expect(analytics.isEnabled, isTrue);

      // Verify that analytics card and section are cleanly hidden from screen UI
      expect(find.text('PRIVASI & ANALITIK'), findsNothing);
      expect(find.text('Google Analytics 4'), findsNothing);
      expect(find.text('GA4'), findsNothing);

      // Verify standard permissions UI still displays normally
      expect(find.text('PERIZINAN APLIKASI'), findsOneWidget);
      expect(find.text('SETELAN SISTEM ANDROID'), findsOneWidget);
    });
  });
}
