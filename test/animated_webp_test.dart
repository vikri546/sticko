import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sticker_flutter/services/sticker_image_processor.dart';
import 'package:sticker_flutter/services/whatsapp_sticker_validator.dart';
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';

void main() {
  test('Test if image package can encode and decode animated WebP', () {
    // 1. Create a multi-frame Image
    final animation = img.Image(width: 512, height: 512, numChannels: 4);
    img.fill(animation, color: img.ColorRgba8(255, 0, 0, 255));
    animation.frameDuration = 100; // 100ms

    final frame2 = animation.addFrame(img.Image(width: 512, height: 512, numChannels: 4));
    img.fill(frame2, color: img.ColorRgba8(0, 255, 0, 255));
    frame2.frameDuration = 100;

    final frame3 = animation.addFrame(img.Image(width: 512, height: 512, numChannels: 4));
    img.fill(frame3, color: img.ColorRgba8(0, 0, 255, 255));
    frame3.frameDuration = 100;

    expect(animation.numFrames, equals(3));

    // 2. Encode to animated WebP
    final webpBytes = img.encodeWebP(animation, singleFrame: false);
    expect(webpBytes, isNotEmpty);

    // 3. Decode back to check frames
    final decoded = img.decodeWebP(Uint8List.fromList(webpBytes));
    expect(decoded, isNotNull);
    expect(decoded!.numFrames, equals(3));
  });

  test('Test decoding animated GIF and encoding to animated WebP with duration', () async {
    // 1. Create an animated GIF in memory
    final gifAnim = img.Image(width: 100, height: 100);
    img.fill(gifAnim, color: img.ColorRgb8(255, 0, 0));
    gifAnim.frameDuration = 200; // 200ms

    final f2 = gifAnim.addFrame(img.Image(width: 100, height: 100));
    img.fill(f2, color: img.ColorRgb8(0, 255, 0));
    f2.frameDuration = 200;

    final gifBytes = Uint8List.fromList(img.encodeGif(gifAnim));
    expect(gifBytes, isNotEmpty);
    expect(StickerImageProcessor.isAnimatedGif(gifBytes), isTrue);

    // 2. Process via StickerImageProcessor
    final result = await StickerImageProcessor.processAnimatedToStickerWebp(
      bytes: gifBytes,
      maxDurationMs: 10000,
      maxBytes: 500 * 1024,
    );

    expect(result.width, equals(512));
    expect(result.height, equals(512));
    expect(result.byteSize, lessThanOrEqualTo(500 * 1024));

    final verify = img.decodeWebP(result.webpBytes);
    expect(verify, isNotNull);
    expect(verify!.numFrames, equals(2));
  });

  test('Test 10-second multi-frame animation capped and compressed under 500 KB', () async {
    // Simulate a 10-second animation with 20 frames (each 500ms = 10,000ms total)
    const totalDurationMs = 10000;
    const frameCount = 20;
    const durationPerFrame = totalDurationMs ~/ frameCount;

    final frameBytesList = <Uint8List>[];
    for (int i = 0; i < frameCount; i++) {
      final frame = img.Image(width: 480, height: 480, numChannels: 4);
      img.fillCircle(
        frame,
        x: 40 + (i * 20),
        y: 240,
        radius: 35,
        color: img.ColorRgba8(255, (i * 12) % 255, 100, 255),
      );
      frameBytesList.add(Uint8List.fromList(img.encodePng(frame)));
    }

    final result = await StickerImageProcessor.processAnimatedToStickerWebp(
      frames: frameBytesList,
      frameDurationMs: durationPerFrame,
      maxDurationMs: 10000,
      maxBytes: 500 * 1024,
    );

    expect(result.width, equals(512));
    expect(result.height, equals(512));
    expect(result.byteSize, lessThanOrEqualTo(500 * 1024));

    final decoded = img.decodeWebP(result.webpBytes);
    expect(decoded, isNotNull);
    expect(decoded!.numFrames, equals(frameCount));

    int computedTotalDuration = 0;
    for (final f in decoded.frames) {
      computedTotalDuration += f.frameDuration;
    }
    expect(computedTotalDuration, lessThanOrEqualTo(10000));
  });

  test('WhatsAppStickerValidator validates animated pack correctly', () async {
    final tempDir = Directory.systemTemp.createTempSync('wa_anim_test_');
    try {
      final packDir = Directory('${tempDir.path}/test_anim_pack');
      packDir.createSync(recursive: true);

      // Create valid 96x96 tray icon
      final trayImg = img.Image(width: 96, height: 96, numChannels: 4);
      img.fill(trayImg, color: img.ColorRgba8(0, 200, 100, 255));
      File('${packDir.path}/tray.png').writeAsBytesSync(img.encodePng(trayImg));

      // Create 3 valid animated stickers (< 500 KB, 512x512, <= 10s)
      final stickers = <StickerItem>[];
      for (int i = 0; i < 3; i++) {
        final anim = img.Image(width: 512, height: 512, numChannels: 4);
        anim.frameDuration = 500;
        final f2 = anim.addFrame(img.Image(width: 512, height: 512, numChannels: 4));
        f2.frameDuration = 500;
        final webpBytes = img.encodeWebP(anim, singleFrame: false);
        final fileName = 'anim_$i.webp';
        File('${packDir.path}/$fileName').writeAsBytesSync(webpBytes);
        stickers.add(StickerItem(imageFileName: fileName, emojis: ['🔥']));
      }

      final pack = StickerPack(
        identifier: 'test_anim_pack',
        name: 'Animated Pack',
        animatedStickerPack: true,
        trayImageFile: 'tray.png',
        stickers: stickers,
      );

      final valResult = await WhatsAppStickerValidator.validatePack(
        pack,
        stickersDirectoryPath: tempDir.path,
      );

      expect(valResult.isValid, isTrue);
      expect(valResult.errors, isEmpty);
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });
}
