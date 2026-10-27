import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sticker_flutter/services/creator_profile_service.dart';
import 'package:sticker_flutter/services/duplicate_stickers_service.dart';
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/ui/screens/account_screen.dart';
import 'package:sticker_flutter/ui/screens/duplicate_stickers_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  const channel = MethodChannel('com.pkri.sticko/stickers');

  // Helper to generate a dummy 512x512 PNG/WebP-like byte image
  List<int> createTestImageBytes(int r, int g, int b) {
    final image = img.Image(width: 100, height: 100);
    img.fill(image, color: img.ColorRgba8(r, g, b, 255));
    return img.encodePng(image);
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('duplicate_stickers_test_');

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

    final manager = StickerPackManager();
    manager.resetForTesting();
    await manager.initialize(customStickersDir: tempDir.path, force: true);

    final duplicateService = DuplicateStickersService();
    duplicateService.resetForTesting();

    final profileService = CreatorProfileService();
    profileService.resetForTesting(customDir: tempDir.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    StickerPackManager().resetForTesting();
    DuplicateStickersService().resetForTesting();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('DuplicateStickersService Unit Tests', () {
    test('Correctly identifies duplicate stickers across multiple packs', () async {
      final manager = StickerPackManager();
      final duplicateService = DuplicateStickersService();

      // Create two packs
      final packA = await manager.createPack(name: 'Paket Kucing Lucu');
      final packB = await manager.createPack(name: 'Paket Favorit');

      // Common duplicate image
      final duplicateImageBytes = Uint8List.fromList(createTestImageBytes(255, 0, 0));
      // Unique image
      final uniqueImageBytes = Uint8List.fromList(createTestImageBytes(0, 255, 0));

      // Add duplicate image to both packA and packB
      await manager.addStickerToPack(
        packIdentifier: packA.identifier,
        imageBytes: duplicateImageBytes,
      );
      await manager.addStickerToPack(
        packIdentifier: packB.identifier,
        imageBytes: duplicateImageBytes,
      );
      // Add unique image to packA
      await manager.addStickerToPack(
        packIdentifier: packA.identifier,
        imageBytes: uniqueImageBytes,
      );

      // Scan for duplicates
      final groups = await duplicateService.scanDuplicates(packManager: manager);

      expect(groups.length, equals(1));
      final group = groups.first;
      expect(group.occurrences.length, equals(2));
      expect(group.duplicateCount, equals(1));
      expect(group.potentialSavedBytes, greaterThan(0));

      // First occurrence is original, second is marked as duplicate
      expect(group.occurrences[0].isOriginal, isTrue);
      expect(group.occurrences[0].packName, equals('Paket Kucing Lucu'));
      expect(group.occurrences[1].isOriginal, isFalse);
      expect(group.occurrences[1].packName, equals('Paket Favorit'));
    });

    test('deleteDuplicate removes sticker from target pack and updates scan', () async {
      final manager = StickerPackManager();
      final duplicateService = DuplicateStickersService();

      final packA = await manager.createPack(name: 'Paket A');
      final packB = await manager.createPack(name: 'Paket B');

      final duplicateBytes = Uint8List.fromList(createTestImageBytes(100, 150, 200));

      await manager.addStickerToPack(
        packIdentifier: packA.identifier,
        imageBytes: duplicateBytes,
      );
      await manager.addStickerToPack(
        packIdentifier: packB.identifier,
        imageBytes: duplicateBytes,
      );

      var groups = await duplicateService.scanDuplicates(packManager: manager);
      expect(groups.length, equals(1));

      // Delete the duplicate in packB
      final itemToDelete = groups.first.occurrences.firstWhere((o) => !o.isOriginal);
      final deleted = await duplicateService.deleteDuplicate(
        itemToDelete,
        packManager: manager,
      );

      expect(deleted, isTrue);

      // Pack B should now have 0 stickers
      final updatedPackB = manager.getPack(packB.identifier);
      expect(updatedPackB?.stickers.length, equals(0));

      // Pack A should still keep its original sticker
      final updatedPackA = manager.getPack(packA.identifier);
      expect(updatedPackA?.stickers.length, equals(1));

      // Duplicates should now be 0
      expect(duplicateService.duplicateGroups.length, equals(0));
    });

    test('replaceDuplicate replaces duplicate sticker with fresh image bytes', () async {
      final manager = StickerPackManager();
      final duplicateService = DuplicateStickersService();

      final packA = await manager.createPack(name: 'Paket Alpha');
      final packB = await manager.createPack(name: 'Paket Beta');

      final duplicateBytes = Uint8List.fromList(createTestImageBytes(50, 50, 50));
      final newReplacementBytes = Uint8List.fromList(createTestImageBytes(200, 200, 200));

      await manager.addStickerToPack(
        packIdentifier: packA.identifier,
        imageBytes: duplicateBytes,
      );
      await manager.addStickerToPack(
        packIdentifier: packB.identifier,
        imageBytes: duplicateBytes,
      );

      var groups = await duplicateService.scanDuplicates(packManager: manager);
      expect(groups.length, equals(1));

      // Replace the duplicate in packB with new image bytes
      final itemToReplace = groups.first.occurrences.firstWhere((o) => !o.isOriginal);
      final replaced = await duplicateService.replaceDuplicate(
        itemToReplace,
        newReplacementBytes,
        packManager: manager,
      );

      expect(replaced, isNotNull);

      // Both packs still have 1 sticker
      expect(manager.getPack(packA.identifier)?.stickers.length, equals(1));
      expect(manager.getPack(packB.identifier)?.stickers.length, equals(1));

      // But duplicate groups is now 0 because the image is now unique
      expect(duplicateService.duplicateGroups.length, equals(0));
    });

    test('autoCleanDuplicates cleans redundant copies while keeping master', () async {
      final manager = StickerPackManager();
      final duplicateService = DuplicateStickersService();

      final packA = await manager.createPack(name: 'Paket 1');
      final packB = await manager.createPack(name: 'Paket 2');
      final packC = await manager.createPack(name: 'Paket 3');

      final duplicateBytes = Uint8List.fromList(createTestImageBytes(12, 34, 56));

      await manager.addStickerToPack(
        packIdentifier: packA.identifier,
        imageBytes: duplicateBytes,
      );
      await manager.addStickerToPack(
        packIdentifier: packB.identifier,
        imageBytes: duplicateBytes,
      );
      await manager.addStickerToPack(
        packIdentifier: packC.identifier,
        imageBytes: duplicateBytes,
      );

      await duplicateService.scanDuplicates(packManager: manager);
      expect(duplicateService.duplicateGroups.length, equals(1));
      expect(duplicateService.totalDuplicateCount, equals(2));

      // Auto clean with preserveThreeStickersRule=false for testing direct deletion
      final cleaned = await duplicateService.autoCleanDuplicates(
        preserveThreeStickersRule: false,
        packManager: manager,
      );

      expect(cleaned, equals(2));
      expect(duplicateService.duplicateGroups.length, equals(0));

      // Original copy in packA is preserved
      expect(manager.getPack(packA.identifier)?.stickers.length, equals(1));
      expect(manager.getPack(packB.identifier)?.stickers.length, equals(0));
      expect(manager.getPack(packC.identifier)?.stickers.length, equals(0));
    });
  });

  group('DuplicateStickersScreen UI Tests', () {
    testWidgets('Renders Hero card, scan button, and empty state when no duplicates', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DuplicateStickersScreen(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Header title
      expect(find.text('Pindai Stiker "Duplikat"'), findsWidgets);

      // Clean empty state (no background) is displayed when no duplicates exist
      expect(find.text('Tidak Ada Stiker Duplikat!'), findsOneWidget);
      expect(find.text('Pindai Ulang'), findsOneWidget);

      // Hero summary card with background is hidden when no duplicates exist
      expect(find.text('RINGKASAN & PEMINDAIAN'), findsNothing);
      expect(find.text('DAFTAR STIKER TERDETEKSI'), findsNothing);
    });

    testWidgets('Renders duplicates list and allows switching between format and one-by-one view', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final manager = StickerPackManager();
      final duplicateBytes = Uint8List.fromList(createTestImageBytes(20, 40, 60));

      await tester.runAsync(() async {
        final pack1 = await manager.createPack(name: 'Paket Stiker Memes');
        final pack2 = await manager.createPack(name: 'Koleksi Teman');
        await manager.addStickerToPack(
          packIdentifier: pack1.identifier,
          imageBytes: duplicateBytes,
        );
        await manager.addStickerToPack(
          packIdentifier: pack2.identifier,
          imageBytes: duplicateBytes,
        );
        final duplicateService = DuplicateStickersService();
        await duplicateService.scanDuplicates(packManager: manager);
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: DuplicateStickersScreen(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Hero stats
      expect(find.text('1 Stiker Duplikat Ditemukan'), findsOneWidget);
      expect(find.text('Pindai Lagi'), findsOneWidget);
      expect(find.text('Bersihkan Semua'), findsOneWidget);
      expect(find.text('Per Format Gambar'), findsOneWidget);
      expect(find.text('Satu per Satu'), findsOneWidget);

      // In format mode, occurrences are listed
      expect(find.text('Format Gambar Sama'), findsOneWidget);
      expect(find.text('Paket Stiker Memes'), findsOneWidget);
      expect(find.text('Koleksi Teman'), findsOneWidget);
      expect(find.text('Asli'), findsOneWidget);
      expect(find.text('Duplikat'), findsOneWidget);

      // Switch to 'Satu per Satu' view
      await tester.tap(find.text('Satu per Satu'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Stiker Asli'), findsOneWidget);
      expect(find.text('Stiker Duplikat'), findsOneWidget);
    });
  });

  group('AccountScreen Navigation Integration Test', () {
    testWidgets('AccountScreen shows Pindai Stiker Duplikat tile and navigates', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const AccountScreen(showAppBar: true),
        ),
      );
      await tester.pump();

      // Find the settings section header and duplicate tile
      expect(find.text('PENGATURAN SISTEM'), findsOneWidget);
      expect(find.text('Pindai Stiker "Duplikat"'), findsOneWidget);
      expect(
        find.text('Pindai otomatis & kelola stiker kembar antar paket'),
        findsOneWidget,
      );

      // Tap the tile
      await tester.tap(find.text('Pindai Stiker "Duplikat"'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Verify we navigated to DuplicateStickersScreen
      expect(find.byType(DuplicateStickersScreen), findsOneWidget);
      expect(find.text('Pindai Stiker "Duplikat"'), findsWidgets);
    });
  });
}
