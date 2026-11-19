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

  test('processGifToStickerWebp converts complex noisy animated GIF strictly under 500 KB', () async {
    final rnd = Random(42);
    final gif = img.Image(width: 300, height: 300);
    gif.frameDuration = 120;
    for (int y = 0; y < 300; y++) {
      for (int x = 0; x < 300; x++) {
        gif.setPixelRgb(x, y, rnd.nextInt(256), (x * 3) % 256, (y * 5) % 256);
      }
    }
    for (int f = 0; f < 5; f++) {
      final frame = img.Image(width: 300, height: 300);
      frame.frameDuration = 120;
      for (int y = 0; y < 300; y++) {
        for (int x = 0; x < 300; x++) {
          frame.setPixelRgb(
            x,
            y,
            rnd.nextInt(256),
            ((x + f * 30) * 3) % 256,
            ((y + f * 20) * 5) % 256,
          );
        }
      }
      gif.addFrame(frame);
    }

    final gifBytes = Uint8List.fromList(img.encodeGif(gif));
    expect(StickerImageProcessor.isAnimatedGif(gifBytes), isTrue);
    expect(StickerImageProcessor.hasMultipleGifFrames(gifBytes), isTrue);

    final result = await StickerImageProcessor.processGifToStickerWebp(
      gifBytes: gifBytes,
    );

    expect(result.width, equals(512));
    expect(result.height, equals(512));
    expect(result.byteSize, lessThanOrEqualTo(500 * 1024));
    expect(StickerImageProcessor.isAnimatedWebp(result.webpBytes), isTrue);

    final decoded = img.decodeWebP(result.webpBytes);
    expect(decoded, isNotNull);
    expect(decoded!.numFrames, greaterThan(1));
  });

  test('processGifToStickerWebp rejects non-GIF bytes and single-frame GIFs', () async {
    // 1. Static PNG bytes must be rejected
    final pngImg = img.Image(width: 100, height: 100);
    img.fill(pngImg, color: img.ColorRgb8(10, 200, 100));
    final pngBytes = Uint8List.fromList(img.encodePng(pngImg));

    expect(StickerImageProcessor.isAnimatedGif(pngBytes), isFalse);
    await expectLater(
      () => StickerImageProcessor.processGifToStickerWebp(gifBytes: pngBytes),
      throwsA(isA<Exception>()),
    );

    // 2. Single-frame GIF must be rejected for animated stickers
    final singleGif = img.Image(width: 100, height: 100);
    img.fill(singleGif, color: img.ColorRgb8(255, 100, 0));
    final singleGifBytes = Uint8List.fromList(img.encodeGif(singleGif));

    expect(StickerImageProcessor.isAnimatedGif(singleGifBytes), isTrue);
    expect(StickerImageProcessor.hasMultipleGifFrames(singleGifBytes), isFalse);
    await expectLater(
      () => StickerImageProcessor.processGifToStickerWebp(gifBytes: singleGifBytes),
      throwsA(isA<Exception>()),
    );
  });

  test('StickerPackManager adds converted GIF sticker and generates tray icon', () async {
    final tempDir = Directory.systemTemp.createTempSync('gif_pack_mgr_');
    try {
      final manager = StickerPackManager();
      manager.resetForTesting();
      await manager.initialize(customStickersDir: tempDir.path, force: true);

      final pack = await manager.createPack(
        name: 'GIF Pack',
        animatedStickerPack: true,
      );

      final gifAnim = img.Image(width: 120, height: 120);
      img.fill(gifAnim, color: img.ColorRgb8(255, 0, 128));
      gifAnim.frameDuration = 150;
      final f2 = gifAnim.addFrame(img.Image(width: 120, height: 120));
      img.fill(f2, color: img.ColorRgb8(0, 128, 255));
      f2.frameDuration = 150;
      final gifBytes = Uint8List.fromList(img.encodeGif(gifAnim));

      final processed = await StickerImageProcessor.processGifToStickerWebp(
        gifBytes: gifBytes,
      );
      final item = await manager.addStickerToPack(
        packIdentifier: pack.identifier,
        imageBytes: processed.webpBytes,
        emojis: ['✨'],
      );

      final updatedPack = manager.getPack(pack.identifier)!;
      expect(updatedPack.animatedStickerPack, isTrue);
      expect(updatedPack.stickers.length, equals(1));
      expect(File('${tempDir.path}/${pack.identifier}/${item.imageFileName}').existsSync(), isTrue);
      expect(File('${tempDir.path}/${pack.identifier}/tray.png').existsSync(), isTrue);
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  group('Real-world Giphy / Web GIF variant compatibility', () {
    /// Minimal uncompressed LZW encoder for 2-bit (4-color) GIF image sub-blocks.
    List<int> encodeUncompressedLzw2Bit(List<int> indices) {
      // minCodeSize = 2 -> clear = 4, eoi = 5, 3-bit codes emitted without building dictionary
      final bits = <int>[];
      void writeCode(int code, int width) {
        for (int b = 0; b < width; b++) {
          bits.add((code >> b) & 1);
        }
      }

      writeCode(4, 3); // clear code
      int sinceClear = 0;
      for (final idx in indices) {
        writeCode(idx & 0x03, 3);
        sinceClear++;
        // Emit clear code every 2 pixels so code width stays safely at 3 bits
        if (sinceClear >= 2) {
          writeCode(4, 3);
          sinceClear = 0;
        }
      }
      writeCode(5, 3); // EOI

      final bytes = <int>[];
      for (int i = 0; i < bits.length; i += 8) {
        int val = 0;
        for (int b = 0; b < 8 && i + b < bits.length; b++) {
          val |= (bits[i + b] << b);
        }
        bytes.add(val);
      }

      final out = <int>[2]; // LZW minimum code size = 2
      for (int i = 0; i < bytes.length; i += 255) {
        final end = (i + 255 < bytes.length) ? i + 255 : bytes.length;
        out.add(end - i);
        out.addAll(bytes.sublist(i, end));
      }
      out.add(0); // block terminator
      return out;
    }

    List<int> buildGce({
      required int disposal,
      required int delayCs,
      int? transparentIndex,
    }) {
      final packed = ((disposal & 0x07) << 2) | (transparentIndex != null ? 1 : 0);
      return [
        0x21, 0xF9, 0x04,
        packed,
        delayCs & 0xFF, (delayCs >> 8) & 0xFF,
        transparentIndex ?? 0,
        0x00,
      ];
    }

    List<int> buildImageDescriptor({
      required int x,
      required int y,
      required int w,
      required int h,
    }) {
      return [
        0x2C,
        x & 0xFF, (x >> 8) & 0xFF,
        y & 0xFF, (y >> 8) & 0xFF,
        w & 0xFF, (w >> 8) & 0xFF,
        h & 0xFF, (h >> 8) & 0xFF,
        0x00, // no LCT, not interlaced
      ];
    }

    test('Preserves Giphy-style partial delta frames with Global Color Table (disposal=1)', () async {
      // 16x16 GIF89a: GCT [0:Black, 1:Red, 2:Green, 3:Blue]
      final bytes = <int>[
        // Header GIF89a
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61,
        // Logical screen 16x16
        16, 0, 16, 0,
        0x91, // GCT flag=1, size=2^(1+1)=4 colors
        0x00, 0x00,
        // GCT: Black, Red, Green, Blue
        0, 0, 0,
        255, 0, 0,
        0, 255, 0,
        0, 0, 255,
        // NETSCAPE2.0 loop extension
        0x21, 0xFF, 0x0B,
        0x4E, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45, 0x32, 0x2E, 0x30,
        0x03, 0x01, 0x00, 0x00, 0x00,
        // Frame 0: full 16x16 solid Red, disposal=1 (do not dispose)
        ...buildGce(disposal: 1, delayCs: 15),
        ...buildImageDescriptor(x: 0, y: 0, w: 16, h: 16),
        ...encodeUncompressedLzw2Bit(List.filled(16 * 16, 1)),
        // Frame 1: partial 8x8 delta at (8,8) solid Green, disposal=1
        ...buildGce(disposal: 1, delayCs: 15),
        ...buildImageDescriptor(x: 8, y: 8, w: 8, h: 8),
        ...encodeUncompressedLzw2Bit(List.filled(8 * 8, 2)),
        // Trailer
        0x3B,
      ];

      final gifBytes = Uint8List.fromList(bytes);
      expect(await StickerImageProcessor.hasMultipleGifFramesAsync(gifBytes), isTrue);

      final result = await StickerImageProcessor.processGifToStickerWebp(
        gifBytes: gifBytes,
      );
      expect(result.width, equals(512));
      expect(result.height, equals(512));
      expect(result.byteSize, lessThanOrEqualTo(500 * 1024));

      final decoded = img.decodeWebP(result.webpBytes)!;
      expect(decoded.numFrames, equals(2));

      // Frame 1 top-left (inside 480px box) MUST remain Red from Frame 0, not turn black
      final frame1 = decoded.frames[1];
      final topLeft = frame1.getPixel(120, 120);
      expect(topLeft.r, greaterThan(180));
      expect(topLeft.g, lessThan(80));

      // Frame 1 bottom-right (inside 480px box) MUST be Green delta
      final bottomRight = frame1.getPixel(380, 380);
      expect(bottomRight.g, greaterThan(180));
      expect(bottomRight.r, lessThan(80));
    });

    test('Preserves transparent Giphy Sticker GIF with disposal=2 (clear to transparent)', () async {
      // 16x16 GIF89a with transparent index 0
      final frame0Pixels = List<int>.generate(16 * 16, (i) => (i % 16) < 8 ? 1 : 0);
      final frame1Pixels = List<int>.generate(16 * 16, (i) => (i % 16) >= 8 ? 3 : 0);

      final bytes = <int>[
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61,
        16, 0, 16, 0,
        0x91, 0x00, 0x00,
        0, 0, 0,
        255, 0, 0,
        0, 255, 0,
        0, 0, 255,
        // Frame 0: left half Red, right half Transparent, disposal=2
        ...buildGce(disposal: 2, delayCs: 15, transparentIndex: 0),
        ...buildImageDescriptor(x: 0, y: 0, w: 16, h: 16),
        ...encodeUncompressedLzw2Bit(frame0Pixels),
        // Frame 1: left half Transparent, right half Blue, disposal=2
        ...buildGce(disposal: 2, delayCs: 15, transparentIndex: 0),
        ...buildImageDescriptor(x: 0, y: 0, w: 16, h: 16),
        ...encodeUncompressedLzw2Bit(frame1Pixels),
        0x3B,
      ];

      final gifBytes = Uint8List.fromList(bytes);
      final result = await StickerImageProcessor.processGifToStickerWebp(
        gifBytes: gifBytes,
      );

      final decoded = img.decodeWebP(result.webpBytes)!;
      expect(decoded.numFrames, equals(2));

      final frame1 = decoded.frames[1];
      // Outer 16px margin must be transparent
      expect(frame1.getPixel(2, 2).a, equals(0));
      // Left half cleared to transparent by disposal=2
      expect(frame1.getPixel(120, 256).a, lessThan(30));
      // Right half opaque Blue
      final rightPixel = frame1.getPixel(380, 256);
      expect(rightPixel.a, greaterThan(220));
      expect(rightPixel.b, greaterThan(180));
    });

    test('Handles Giphy / Photoshop GIF with XMP Application Extension and GIF87a header', () async {
      // Build valid 2-frame GIF and inject XMP DataXMP extension before frames
      final xmpPayload = '<x:xmpmeta></x:xmpmeta>'.codeUnits;
      final xmpMagicTrailer = <int>[
        0x01,
        for (int i = 255; i >= 0; i--) i,
        0x00,
      ];

      final xmpGif = Uint8List.fromList([
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61,
        16, 0, 16, 0,
        0x91, 0x00, 0x00,
        0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255,
        // XMP DataXMP extension block
        0x21, 0xFF, 0x0B,
        ...'XMP DataXMP'.codeUnits,
        ...xmpPayload,
        ...xmpMagicTrailer,
        // Frame 0 & 1
        ...buildGce(disposal: 1, delayCs: 12),
        ...buildImageDescriptor(x: 0, y: 0, w: 16, h: 16),
        ...encodeUncompressedLzw2Bit(List.filled(16 * 16, 1)),
        ...buildGce(disposal: 1, delayCs: 12),
        ...buildImageDescriptor(x: 0, y: 0, w: 16, h: 16),
        ...encodeUncompressedLzw2Bit(List.filled(16 * 16, 3)),
        0x3B,
      ]);

      expect(await StickerImageProcessor.hasMultipleGifFramesAsync(xmpGif), isTrue);
      final xmpRes = await StickerImageProcessor.processGifToStickerWebp(gifBytes: xmpGif);
      expect(img.decodeWebP(xmpRes.webpBytes)!.numFrames, equals(2));

      // Also test GIF87a header variant (multi-frame without GCE)
      final gif87a = Uint8List.fromList([
        0x47, 0x49, 0x46, 0x38, 0x37, 0x61, // GIF87a
        16, 0, 16, 0,
        0x91, 0x00, 0x00,
        0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255,
        ...buildImageDescriptor(x: 0, y: 0, w: 16, h: 16),
        ...encodeUncompressedLzw2Bit(List.filled(16 * 16, 1)),
        ...buildImageDescriptor(x: 0, y: 0, w: 16, h: 16),
        ...encodeUncompressedLzw2Bit(List.filled(16 * 16, 2)),
        0x3B,
      ]);

      expect(StickerImageProcessor.isAnimatedGif(gif87a), isTrue);
      final res87a = await StickerImageProcessor.processGifToStickerWebp(gifBytes: gif87a);
      expect(img.decodeWebP(res87a.webpBytes)!.numFrames, equals(2));
    });

    test('Caps long high-FPS Giphy GIF (> 10s, 60 frames) cleanly under 10s and 500 KB', () async {
      // 60 frames x 200ms = 12 seconds total
      final gif = img.Image(width: 120, height: 120);
      gif.frameDuration = 200;
      img.fill(gif, color: img.ColorRgb8(255, 0, 0));
      for (int i = 1; i < 60; i++) {
        final f = img.Image(width: 120, height: 120);
        f.frameDuration = 200;
        img.fill(f, color: img.ColorRgb8((i * 15) % 256, (i * 25) % 256, 180));
        gif.addFrame(f);
      }
      final longGifBytes = Uint8List.fromList(img.encodeGif(gif));

      final result = await StickerImageProcessor.processGifToStickerWebp(
        gifBytes: longGifBytes,
        maxDurationMs: 10000,
      );

      expect(result.width, equals(512));
      expect(result.height, equals(512));
      expect(result.byteSize, lessThanOrEqualTo(500 * 1024));

      final decoded = img.decodeWebP(result.webpBytes)!;
      expect(decoded.numFrames, greaterThan(1));
      expect(decoded.numFrames, lessThanOrEqualTo(32));

      int totalMs = 0;
      for (final f in decoded.frames) {
        totalMs += f.frameDuration;
      }
      expect(totalMs, lessThanOrEqualTo(10000));
    });
  });
}
