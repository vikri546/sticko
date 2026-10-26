import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/ui/widgets/add_sticker_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Multi-Image Picker & Batch Sticker Addition Tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('multi_picker_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('StickerPackManager.addMultipleStickersToPack adds a batch of stickers with progress tracking', () async {
      final manager = StickerPackManager();
      manager.resetForTesting();
      await manager.initialize(customStickersDir: tempDir.path, force: true);

      final pack = await manager.createPack(name: 'Batch Pack');

      // Generate 4 dummy images as bytes
      final imagesList = <Uint8List>[];
      for (int i = 0; i < 4; i++) {
        final image = img.Image(width: 400, height: 400);
        img.fill(image, color: img.ColorRgb8(50 * i, 100 + i * 20, 200 - i * 30));
        imagesList.add(Uint8List.fromList(img.encodePng(image)));
      }

      final progressReports = <Map<String, int>>[];

      final addedStickers = await manager.addMultipleStickersToPack(
        packIdentifier: pack.identifier,
        imagesBytesList: imagesList,
        defaultEmojis: ['🔥', '🎉'],
        onProgress: (current, total) {
          progressReports.add({'current': current, 'total': total});
        },
      );

      // Verify returned stickers count
      expect(addedStickers.length, equals(4));

      // Verify progress callback was called 4 times
      expect(progressReports.length, equals(4));
      expect(progressReports.first, equals({'current': 1, 'total': 4}));
      expect(progressReports.last, equals({'current': 4, 'total': 4}));

      // Verify pack state in manager
      final updatedPack = manager.getPack(pack.identifier);
      expect(updatedPack, isNotNull);
      expect(updatedPack!.stickers.length, equals(4));
      expect(updatedPack.canAddToWhatsApp, isTrue); // 4 >= 3
      expect(updatedPack.stickers.first.emojis, equals(['🔥', '🎉']));

      // Verify files exist on disk and are valid WebP under 100 KB
      final packDir = '${tempDir.path}/${pack.identifier}';
      for (final s in updatedPack.stickers) {
        final file = File('$packDir/${s.imageFileName}');
        expect(file.existsSync(), isTrue);
        expect(file.lengthSync(), lessThanOrEqualTo(100 * 1024));

        final decoded = img.decodeWebP(file.readAsBytesSync());
        expect(decoded, isNotNull);
        expect(decoded!.width, equals(512));
        expect(decoded.height, equals(512));
      }

      // Verify tray icon was automatically generated
      final trayFile = File('$packDir/tray.png');
      expect(trayFile.existsSync(), isTrue);
      expect(trayFile.lengthSync(), lessThanOrEqualTo(50 * 1024));
    });

    test('StickerPackManager.addMultipleStickersToPack respects 30-sticker max limit', () async {
      final manager = StickerPackManager();
      manager.resetForTesting();
      await manager.initialize(customStickersDir: tempDir.path, force: true);

      final pack = await manager.createPack(name: 'Limit Pack');

      // Create dummy image
      final image = img.Image(width: 100, height: 100);
      final imageBytes = Uint8List.fromList(img.encodePng(image));

      // Prepare 32 images
      final imagesList = List.generate(32, (_) => imageBytes);

      // Add batch
      final addedStickers = await manager.addMultipleStickersToPack(
        packIdentifier: pack.identifier,
        imagesBytesList: imagesList,
      );

      // Should cap at 30
      expect(addedStickers.length, equals(30));
      expect(manager.getPack(pack.identifier)!.stickers.length, equals(30));

      // Adding any more should throw an exception
      expect(
        () => manager.addMultipleStickersToPack(
          packIdentifier: pack.identifier,
          imagesBytesList: [imageBytes],
        ),
        throwsA(isA<Exception>()),
      );
    });

    testWidgets('AddStickerSheet displays multi-select option and options cards', (WidgetTester tester) async {
      final manager = StickerPackManager();
      manager.resetForTesting();
      await manager.initialize(customStickersDir: tempDir.path, force: true);

      final pack = await manager.createPack(name: 'UI Test Pack');

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AddStickerSheet(packIdentifier: pack.identifier),
        ),
      ));
      await tester.pump();

      // Verify sheet title and options
      expect(find.text('Tambah Stiker Baru'), findsOneWidget);
      expect(find.text('Galeri Foto'), findsOneWidget);
      expect(find.text('Kamera'), findsOneWidget);
    });
  });
}
