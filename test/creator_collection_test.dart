import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';
import 'package:sticker_flutter/ui/screens/creator_collection_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final manager = StickerPackManager();
  const channel = MethodChannel('com.pkri.sticko/stickers');

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('creator_collection_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      switch (methodCall.method) {
        case 'getStickersDirectory':
          return tempDir.path;
        case 'checkWhatsAppInstalled':
          return {'whatsapp': true, 'whatsapp_business': false};
        case 'isStickerPackAdded':
          return false;
        default:
          return null;
      }
    });
    manager.resetForTesting();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
    manager.resetForTesting();
  });

  group('CreatorCollectionScreen Tests', () {
    test('CreatorCollectionScreen.route() provides zoom in/out ScaleTransition', () {
      final route = CreatorCollectionScreen.route(initialTabIndex: 1);
      expect(route, isA<PageRouteBuilder<void>>());

      final pageRoute = route as PageRouteBuilder<void>;
      expect(pageRoute.transitionDuration, const Duration(milliseconds: 300));
      expect(pageRoute.reverseTransitionDuration, const Duration(milliseconds: 250));
    });

    testWidgets('Renders empty states with unique descriptions on each tab', (WidgetTester tester) async {
      await manager.initialize(customStickersDir: tempDir.path);

      // Open at tab 0 (Paket)
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const CreatorCollectionScreen(initialTabIndex: 0),
        ),
      );
      await tester.pumpAndSettle();

      // Check App Title
      expect(find.text('Koleksi Kreator'), findsOneWidget);

      // Check Tab Bar Items
      expect(find.text('Paket'), findsOneWidget);
      expect(find.text('Stiker'), findsOneWidget);
      expect(find.text('Di WA'), findsOneWidget);

      // Check Empty State for Tab 1 (Paket)
      expect(find.text('Belum Ada Paket Stiker'), findsOneWidget);
      expect(
        find.textContaining('Ketuk tombol \'+\' di bawah untuk mulai membuat paket stiker pertamamu!'),
        findsOneWidget,
      );

      // Switch to Tab 2 (Stiker)
      await tester.tap(find.text('Stiker'));
      await tester.pumpAndSettle();

      expect(find.text('Koleksi Stiker Masih Kosong'), findsOneWidget);
      expect(
        find.textContaining('Belum ada stiker yang ditambahkan'),
        findsOneWidget,
      );

      // Switch to Tab 3 (Di WA)
      await tester.tap(find.text('Di WA'));
      await tester.pumpAndSettle();

      expect(find.text('Belum Ada Stiker di WhatsApp'), findsOneWidget);
      expect(
        find.textContaining('Paket stiker kamu belum diekspor ke WhatsApp'),
        findsOneWidget,
      );

      // Check FloatingActionButton exists
      expect(find.byKey(const Key('creator_collection_fab')), findsOneWidget);
    });

    testWidgets('Opens directly to initialTabIndex when specified', (WidgetTester tester) async {
      await manager.initialize(customStickersDir: tempDir.path);

      // Open directly at tab 2 (Di WA)
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const CreatorCollectionScreen(initialTabIndex: 2),
        ),
      );
      await tester.pumpAndSettle();

      // Should directly show Di WA empty state
      expect(find.text('Belum Ada Stiker di WhatsApp'), findsOneWidget);
    });

    testWidgets('Renders packs with stacked 3-image preview and modal layer', (WidgetTester tester) async {
      await manager.initialize(customStickersDir: tempDir.path);

      // Create a test pack with 3 stickers directly via JSON to avoid isolate overhead
      final testPack = StickerPack(
        identifier: 'pack_test_123',
        name: 'Paket Emoji Keren',
        publisher: 'Sticko Pro',
        trayImageFile: 'tray.png',
        stickers: const [
          StickerItem(imageFileName: 'sticker_1.webp', emojis: ['😎']),
          StickerItem(imageFileName: 'sticker_2.webp', emojis: ['🔥']),
          StickerItem(imageFileName: 'sticker_3.webp', emojis: ['🎉']),
        ],
      );

      await WhatsAppStickersService.saveContentsJson(
        [testPack],
        directoryPath: tempDir.path,
      );
      await manager.initialize(customStickersDir: tempDir.path, force: true);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const CreatorCollectionScreen(initialTabIndex: 0),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Paket Emoji Keren'), findsOneWidget);
      expect(find.text('3 Stiker • Sticko Pro'), findsOneWidget);

      await tester.tap(find.text('Paket Emoji Keren').first);
      await tester.pumpAndSettle();

      // Modal layer should show details and action button
      expect(find.text('Buka & Kelola Paket'), findsOneWidget);
      expect(find.text('3 Stiker • Kreator: Sticko Pro'), findsOneWidget);

      // Tapping a sticker inside the pack modal should show preview-only modal (NO edit controls)
      await tester.tap(find.text('😎'));
      await tester.pumpAndSettle();

      expect(find.text('Paket: Paket Emoji Keren'), findsOneWidget);
      expect(find.text('Emoji: 😎'), findsOneWidget);
      expect(find.text('Tutup'), findsOneWidget);
      expect(find.text('Edit Stiker'), findsNothing);
      expect(find.text('Edit Stiker Animasi'), findsNothing);
      expect(find.text('Simpan Perubahan'), findsNothing);

      // Closing preview returns to the pack modal
      await tester.tap(find.text('Tutup'));
      await tester.pumpAndSettle();
      expect(find.text('Buka & Kelola Paket'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Buka & Kelola Paket'), findsNothing);

      await tester.tap(find.text('Stiker'));
      await tester.pumpAndSettle();

      // All stickers grid should show emojis
      expect(find.text('😎'), findsOneWidget);
      expect(find.text('🔥'), findsOneWidget);
      expect(find.text('🎉'), findsOneWidget);

      await tester.tap(find.text('😎'));
      await tester.pumpAndSettle();

      expect(find.text('Paket: Paket Emoji Keren'), findsOneWidget);
      expect(find.text('Emoji: 😎'), findsOneWidget);
      expect(find.text('Lihat di Paket'), findsOneWidget);
    });
  });
}
