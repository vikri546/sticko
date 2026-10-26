import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sticker_flutter/services/sticker_image_processor.dart';
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/services/whatsapp_sticker_validator.dart';
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WhatsApp Sticker Size & Adaptive Optimization Tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('sticker_size_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('StickerImageProcessor adaptive compression guarantees WebP size <= 100 KB for textured images', () async {
      // Create a high-entropy image with texture and grain
      final image = img.Image(width: 600, height: 600, numChannels: 4);
      final rnd = Random(42);
      for (int y = 0; y < 600; y++) {
        for (int x = 0; x < 600; x++) {
          final r = ((x * y) % 255 + rnd.nextInt(70)).clamp(0, 255);
          final g = ((x + y * 2) % 255 + rnd.nextInt(70)).clamp(0, 255);
          final b = ((x * 3 + y) % 255 + rnd.nextInt(70)).clamp(0, 255);
          image.setPixelRgba(x, y, r, g, b, 255);
        }
      }
      final rawPng = Uint8List.fromList(img.encodePng(image));

      // Process with adaptive compression
      final result = await StickerImageProcessor.processToStickerWebp(rawPng);

      expect(result.width, equals(512));
      expect(result.height, equals(512));
      expect(result.byteSize, lessThanOrEqualTo(100 * 1024));
      expect(result.isValid, isTrue);

      final decoded = img.decodeWebP(result.webpBytes);
      expect(decoded, isNotNull);
      expect(decoded!.width, equals(512));
      expect(decoded.height, equals(512));
    });

    test('StickerImageProcessor preserves transparent margins/background and does not turn them black', () async {
      // Create a 400x200 rectangular image with transparent background outside
      final image = img.Image(width: 400, height: 200, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(0, 150, 255, 255));
      final rawPng = Uint8List.fromList(img.encodePng(image));

      final result = await StickerImageProcessor.processToStickerWebp(rawPng);
      final decoded = img.decodeWebP(result.webpBytes);
      expect(decoded, isNotNull);
      expect(decoded!.width, equals(512));
      expect(decoded.height, equals(512));

      // Margins at (0, 0) should be transparent (alpha == 0), NOT solid black (alpha == 255)
      final pixel00 = decoded.getPixel(0, 0);
      expect(pixel00.a, equals(0));

      // Center should be opaque blue
      final centerPixel = decoded.getPixel(256, 256);
      expect(centerPixel.a, equals(255));
    });

    test('WhatsAppStickerValidator permits up to 500 KB for animated sticker packs and 100 KB for static packs', () async {
      const staticPackId = 'pack_static_test';
      final staticPackDir = Directory('${tempDir.path}/$staticPackId');
      await staticPackDir.create(recursive: true);

      // Create valid 96x96 tray icon
      final tray = img.Image(width: 96, height: 96);
      await File('${staticPackDir.path}/tray.png').writeAsBytes(img.encodePng(tray));

      // Create a valid 512x512 WebP sticker that is ~140 KB (> 100 KB but < 500 KB)
      final complexImg = img.Image(width: 512, height: 512, numChannels: 4);
      final rnd = Random(999);
      for (int y = 0; y < 512; y++) {
        for (int x = 0; x < 512; x++) {
          complexImg.setPixelRgba(x, y, (x * y) % 255, (x + y) % 255, rnd.nextInt(256), 255);
        }
      }
      // Quantizing to 64 colors yields a valid WebP around 140 KB
      final quantized = img.quantize(complexImg, numberOfColors: 64);
      final oversizedWebp = Uint8List.fromList(img.encodeWebP(quantized));
      expect(oversizedWebp.length, greaterThan(100 * 1024));
      expect(oversizedWebp.length, lessThan(500 * 1024));

      for (int i = 1; i <= 3; i++) {
        await File('${staticPackDir.path}/sticker_$i.webp').writeAsBytes(oversizedWebp);
      }

      final stickers = [
        const StickerItem(imageFileName: 'sticker_1.webp', emojis: ['😀']),
        const StickerItem(imageFileName: 'sticker_2.webp', emojis: ['😀']),
        const StickerItem(imageFileName: 'sticker_3.webp', emojis: ['😀']),
      ];

      // 1. Static pack should FAIL because stickers exceed 100 KB
      final staticPack = StickerPack(
        identifier: staticPackId,
        name: 'Static Pack',
        trayImageFile: 'tray.png',
        animatedStickerPack: false,
        stickers: stickers,
      );

      final staticResult = await WhatsAppStickerValidator.validatePack(
        staticPack,
        stickersDirectoryPath: tempDir.path,
      );
      expect(staticResult.isValid, isFalse);
      expect(
        staticResult.errors.any((e) => e.contains('100 KB')),
        isTrue,
      );

      // 2. Animated pack should PASS because 140 KB is well under the 500 KB animated limit
      final animatedPack = StickerPack(
        identifier: staticPackId,
        name: 'Animated Pack',
        trayImageFile: 'tray.png',
        animatedStickerPack: true,
        stickers: stickers,
      );

      final animatedResult = await WhatsAppStickerValidator.validatePack(
        animatedPack,
        stickersDirectoryPath: tempDir.path,
      );
      expect(animatedResult.isValid, isTrue);
      expect(animatedResult.errors, isEmpty);
    });

    test('StickerPackManager automatically optimizes oversized stickers in existing pack', () async {
      final manager = StickerPackManager();
      manager.resetForTesting();
      await manager.initialize(customStickersDir: tempDir.path, force: true);

      // Create a pack
      final pack = await manager.createPack(name: 'Auto-Repair Pack');
      final packDir = '${tempDir.path}/${pack.identifier}';

      // Create valid 96x96 tray icon
      final trayImage = img.Image(width: 96, height: 96);
      File('$packDir/tray.png').writeAsBytesSync(img.encodePng(trayImage));

      // Create an oversized sticker (> 100 KB) with real high-frequency image data
      final oversizedImage = img.Image(width: 512, height: 512, numChannels: 4);
      final rnd = Random(123);
      for (var p in oversizedImage) {
        p.setRgba(rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256), 255);
      }
      final uncompressedWebp = img.encodeWebP(oversizedImage);
      expect(uncompressedWebp.length, greaterThan(100 * 1024)); // Verify it exceeds 100 KB

      // Write 3 stickers (2 oversized, 1 normal)
      for (int i = 1; i <= 3; i++) {
        final fileName = 'sticker_$i.webp';
        final file = File('$packDir/$fileName');
        if (i < 3) {
          file.writeAsBytesSync(uncompressedWebp);
        } else {
          final smallImage = img.Image(width: 512, height: 512);
          img.fill(smallImage, color: img.ColorRgb8(10, 20, 30));
          file.writeAsBytesSync(img.encodeWebP(smallImage));
        }
      }

      // Add stickers to manager state
      final updatedPack = pack.copyWith(
        stickers: [
          const StickerItem(imageFileName: 'sticker_1.webp', emojis: ['😀']),
          const StickerItem(imageFileName: 'sticker_2.webp', emojis: ['😀']),
          const StickerItem(imageFileName: 'sticker_3.webp', emojis: ['😀']),
        ],
      );
      await WhatsAppStickersService.saveContentsJson(
        [updatedPack],
        directoryPath: tempDir.path,
      );
      await manager.initialize(customStickersDir: tempDir.path, force: true);

      // Verify validator initially reports error for oversized stickers
      final preValidation = await WhatsAppStickerValidator.validatePack(
        updatedPack,
        stickersDirectoryPath: tempDir.path,
      );
      expect(preValidation.isValid, isFalse);
      expect(preValidation.errors.any((e) => e.contains('100 KB')), isTrue);

      // Execute auto-optimization
      final repairedCount = await manager.autoOptimizePackStickers(pack.identifier);
      expect(repairedCount, equals(2)); // The 2 oversized stickers were repaired

      // Verify all files on disk are now <= 100 KB
      for (int i = 1; i <= 3; i++) {
        final file = File('$packDir/sticker_$i.webp');
        expect(file.lengthSync(), lessThanOrEqualTo(100 * 1024));
      }

      // Verify post-optimization validation now passes completely
      final postValidation = await WhatsAppStickerValidator.validatePack(
        manager.getPack(pack.identifier)!,
        stickersDirectoryPath: tempDir.path,
      );
      expect(postValidation.isValid, isTrue);
      expect(postValidation.errors, isEmpty);
    });
  });
}
