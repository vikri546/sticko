import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';

/// Data class holding processed sticker details.
class ProcessedStickerResult {
  final Uint8List webpBytes;
  final int width;
  final int height;
  final int byteSize;

  const ProcessedStickerResult({
    required this.webpBytes,
    required this.width,
    required this.height,
    required this.byteSize,
  });

  /// Check if the result is valid according to WhatsApp sticker specifications.
  bool get isValid =>
      width == 512 && height == 512 && byteSize <= (100 * 1024);

  /// Check if valid under custom or animated limit (up to 500 KB).
  bool isValidForLimit(int maxLimitBytes) =>
      width == 512 && height == 512 && byteSize <= maxLimitBytes;
}

/// Service that handles picking, resizing, padding, and WebP encoding for WhatsApp Stickers.
class StickerImageProcessor {
  static const int stickerDimension = 512;
  static const int maxFileSizeBytes = 100 * 1024; // 100 KB limit for static stickers (102,400 bytes)
  static const int maxAnimatedFileSizeBytes = 500 * 1024; // 500 KB limit for animated stickers
  static const int targetInnerBox = 480; // 512 - (16px margin * 2)

  static const int trayDimension = 96;
  static const int maxTrayFileSizeBytes = 50 * 1024; // 50 KB limit for tray icon

  static final ImagePicker _picker = ImagePicker();

  /// Pick an image from device gallery or camera.
  static Future<XFile?> pickImage({ImageSource source = ImageSource.gallery}) async {
    try {
      return await _picker.pickImage(
        source: source,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 95,
      );
    } catch (e) {
      debugPrint('Error picking image: $e');
      return null;
    }
  }

  /// Pick multiple images from device gallery for batch sticker creation.
  static Future<List<XFile>> pickMultiImage({int? limit}) async {
    try {
      final files = await _picker.pickMultiImage(
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 95,
        limit: limit,
      );
      if (limit != null && files.length > limit) {
        return files.take(limit).toList();
      }
      return files;
    } catch (e) {
      try {
        final files = await _picker.pickMultiImage(
          maxWidth: 2048,
          maxHeight: 2048,
          imageQuality: 95,
        );
        if (limit != null && files.length > limit) {
          return files.take(limit).toList();
        }
        return files;
      } catch (e2) {
        debugPrint('Error picking multiple images: $e2');
        return [];
      }
    }
  }

  /// Pick a video from gallery for animated sticker creation (up to 10 seconds).
  static Future<XFile?> pickVideo({
    ImageSource source = ImageSource.gallery,
    Duration maxDuration = const Duration(seconds: 10),
  }) async {
    try {
      return await _picker.pickVideo(
        source: source,
        maxDuration: maxDuration,
      );
    } catch (e) {
      debugPrint('Error picking video: $e');
      return null;
    }
  }

  /// Pick animated media (both Videos and GIFs) from device gallery.
  /// Unlike pickVideo which filters only video/*, pickMedia allows both Videos and GIFs to appear.
  static Future<XFile?> pickAnimatedMedia() async {
    try {
      return await _picker.pickMedia(
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 95,
      );
    } catch (e) {
      debugPrint('Error picking animated media: $e');
      return null;
    }
  }

  /// Pick multiple animated media (both Videos and GIFs) from gallery.
  static Future<List<XFile>> pickMultipleAnimatedMedia({int? limit}) async {
    try {
      final files = await _picker.pickMultipleMedia(
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 95,
        limit: limit,
      );
      if (limit != null && files.length > limit) {
        return files.take(limit).toList();
      }
      return files;
    } catch (e) {
      try {
        final files = await _picker.pickMultipleMedia(
          maxWidth: 2048,
          maxHeight: 2048,
          imageQuality: 95,
        );
        if (limit != null && files.length > limit) {
          return files.take(limit).toList();
        }
        return files;
      } catch (e2) {
        debugPrint('Error picking multiple animated media: $e2');
        return [];
      }
    }
  }

  /// Check if file path corresponds to a video format
  static bool isVideoFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.3gp') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.m4v');
  }

  /// Check if byte array starts with GIF magic header (GIF87a / GIF89a)
  static bool isAnimatedGif(Uint8List bytes) {
    if (bytes.length < 6) return false;
    return bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38 &&
        (bytes[4] == 0x37 || bytes[4] == 0x39) &&
        bytes[5] == 0x61;
  }

  /// Check if byte array is an animated WebP (contains ANIM chunk)
  static bool isAnimatedWebp(Uint8List bytes) {
    if (bytes.length < 32) return false;
    final isWebpHeader = bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50;
    if (!isWebpHeader) return false;

    final limit = bytes.length - 4;
    for (int i = 12; i < limit; i++) {
      if (bytes[i] == 0x41 &&
          bytes[i + 1] == 0x4E &&
          bytes[i + 2] == 0x49 &&
          bytes[i + 3] == 0x4D) {
        return true;
      }
    }
    return false;
  }

  /// Check if raw bytes belong to an animated media format
  static bool isAnimatedMedia(Uint8List bytes) {
    return isAnimatedGif(bytes) || isAnimatedWebp(bytes);
  }

  /// Process raw image/animation bytes into compliant 512x512 WebP with transparent margins.
  /// Automatically detects animated GIF / WebP and preserves animation up to 10 seconds.
  /// Runs in background compute isolate to keep UI smooth and responsive.
  static Future<ProcessedStickerResult> processToStickerWebp(
    Uint8List sourceBytes, {
    int maxBytes = maxFileSizeBytes,
  }) async {
    if (isAnimatedMedia(sourceBytes)) {
      return await processAnimatedToStickerWebp(
        bytes: sourceBytes,
        maxBytes: maxBytes > maxFileSizeBytes ? maxBytes : maxAnimatedFileSizeBytes,
      );
    }
    return await compute(_isolateProcessSticker, {
      'bytes': sourceBytes,
      'maxBytes': maxBytes,
    });
  }

  /// Convert a video file to an animated WebP sticker (up to 10s, <= 500 KB).
  static Future<ProcessedStickerResult> processVideoToStickerWebp({
    required String videoPath,
    int maxDurationMs = 10000,
    int maxBytes = maxAnimatedFileSizeBytes,
  }) async {
    final extracted = await WhatsAppStickersService.extractVideoFrames(
      videoPath: videoPath,
      maxDurationMs: maxDurationMs,
    );

    if (extracted == null || (extracted['frames'] as List).isEmpty) {
      throw Exception('Gagal mengekstrak frame dari video untuk dijadikan stiker animasi.');
    }

    final frames = extracted['frames'] as List<Uint8List>;
    final frameDurationMs = extracted['frameDurationMs'] as int;

    return await processAnimatedToStickerWebp(
      frames: frames,
      frameDurationMs: frameDurationMs,
      maxDurationMs: maxDurationMs,
      maxBytes: maxBytes,
    );
  }

  /// Process animated media (GIF bytes, animated WebP bytes, or extracted video frames)
  /// into compliant animated WebP (512x512, <= 500KB, <= 10s, infinite loop).
  static Future<ProcessedStickerResult> processAnimatedToStickerWebp({
    Uint8List? bytes,
    List<Uint8List>? frames,
    int? frameDurationMs,
    int maxDurationMs = 10000,
    int maxBytes = maxAnimatedFileSizeBytes,
  }) async {
    return await compute(_isolateProcessAnimatedSticker, {
      'bytes': bytes,
      'frames': frames,
      'frameDurationMs': frameDurationMs,
      'maxDurationMs': maxDurationMs,
      'maxBytes': maxBytes,
    });
  }

  /// Background isolate processor function. Supports both Uint8List and Map arguments.
  static ProcessedStickerResult _isolateProcessSticker(dynamic input) {
    Uint8List sourceBytes;
    int maxBytes = maxFileSizeBytes;

    if (input is Uint8List) {
      sourceBytes = input;
    } else if (input is Map) {
      sourceBytes = input['bytes'] as Uint8List;
      maxBytes = (input['maxBytes'] as int?) ?? maxFileSizeBytes;
    } else {
      throw Exception('Format argumen pemrosesan stiker tidak valid.');
    }

    final original = img.decodeImage(sourceBytes);
    if (original == null) {
      throw Exception('Format gambar tidak dapat dibaca oleh sistem.');
    }

    img.Image makeCanvas(img.Image src, int boxSize) {
      int targetWidth;
      int targetHeight;
      if (src.width >= src.height) {
        targetWidth = boxSize;
        targetHeight = (src.height * boxSize / src.width).round();
      } else {
        targetHeight = boxSize;
        targetWidth = (src.width * boxSize / src.height).round();
      }

      if (targetWidth <= 0) targetWidth = 1;
      if (targetHeight <= 0) targetHeight = 1;

      final resized = img.copyResize(
        src,
        width: targetWidth,
        height: targetHeight,
        interpolation: img.Interpolation.linear,
      );

      final canvas = img.Image(
        width: stickerDimension,
        height: stickerDimension,
        numChannels: 4,
      );

      final dstX = (stickerDimension - resized.width) ~/ 2;
      final dstY = (stickerDimension - resized.height) ~/ 2;
      img.compositeImage(canvas, resized, dstX: dstX, dstY: dstY);
      return canvas;
    }

    // Step 1: Standard high-quality 480px box on 512x512 canvas
    img.Image canvas = makeCanvas(original, targetInnerBox);
    Uint8List webpBytes = Uint8List.fromList(img.encodeWebP(canvas));
    if (webpBytes.lengthInBytes <= maxBytes) {
      return ProcessedStickerResult(
        webpBytes: webpBytes,
        width: stickerDimension,
        height: stickerDimension,
        byteSize: webpBytes.lengthInBytes,
      );
    }

    // Step 2: Progressive color quantization on 480px box (preserving alpha transparency)
    for (final colors in [256, 192, 128, 96, 64, 48, 32]) {
      final quant = _quantizePreservingAlpha(canvas, colors);
      webpBytes = Uint8List.fromList(img.encodeWebP(quant));
      if (webpBytes.lengthInBytes <= maxBytes) {
        return ProcessedStickerResult(
          webpBytes: webpBytes,
          width: stickerDimension,
          height: stickerDimension,
          byteSize: webpBytes.lengthInBytes,
        );
      }
    }

    // Step 3: Progressively reduce inner box + quantize (preserving alpha on 512x512 canvas)
    for (final boxSize in [420, 380, 340, 300, 260]) {
      final smallerCanvas = makeCanvas(original, boxSize);
      for (final colors in [128, 64, 32, 16]) {
        final quant = _quantizePreservingAlpha(smallerCanvas, colors);
        webpBytes = Uint8List.fromList(img.encodeWebP(quant));
        if (webpBytes.lengthInBytes <= maxBytes) {
          return ProcessedStickerResult(
            webpBytes: webpBytes,
            width: stickerDimension,
            height: stickerDimension,
            byteSize: webpBytes.lengthInBytes,
          );
        }
      }
    }

    // Step 4: Fallback for extreme entropy / high-noise camera shots
    final smoothed = img.gaussianBlur(original, radius: 2);
    final smoothCanvas = makeCanvas(smoothed, 280);
    final quantFallback = _quantizePreservingAlpha(smoothCanvas, 16);
    webpBytes = Uint8List.fromList(img.encodeWebP(quantFallback));

    return ProcessedStickerResult(
      webpBytes: webpBytes,
      width: stickerDimension,
      height: stickerDimension,
      byteSize: webpBytes.lengthInBytes,
    );
  }

  /// Background isolate processor function for animated stickers (GIF, WebP, Video frames).
  /// Enforces WhatsApp constraints:
  /// - Maximum duration: 10 seconds (10,000 ms)
  /// - Dimensions: 512x512 with 16px transparent margins (480 inner box)
  /// - File size: <= 500 KB (500 * 1024 bytes)
  /// - Looping: Infinite loop (loopCount = 0)
  static ProcessedStickerResult _isolateProcessAnimatedSticker(dynamic input) {
    final map = input as Map<String, dynamic>;
    final bytes = map['bytes'] as Uint8List?;
    final rawFrames = (map['frames'] as List<dynamic>?)?.map((e) => e as Uint8List).toList();
    final defaultFrameDuration = (map['frameDurationMs'] as int?) ?? 100;
    final maxDurationMs = (map['maxDurationMs'] as int?) ?? 10000;
    final maxBytes = (map['maxBytes'] as int?) ?? maxAnimatedFileSizeBytes;

    List<img.Image> frameImages = [];
    List<int> frameDurations = [];

    if (bytes != null) {
      img.Image? decodedAnim;
      if (isAnimatedGif(bytes)) {
        decodedAnim = img.decodeGif(bytes);
      } else if (isAnimatedWebp(bytes)) {
        decodedAnim = img.decodeWebP(bytes);
      } else {
        decodedAnim = img.decodeImage(bytes);
      }

      if (decodedAnim == null) {
        throw Exception('Format animasi tidak dapat dibaca oleh sistem.');
      }

      if (decodedAnim.numFrames <= 1) {
        return _isolateProcessSticker({
          'bytes': bytes,
          'maxBytes': maxBytes,
        });
      }

      // Calculate total duration and trim to max 10,000 ms (10 seconds)
      int accumulatedDuration = 0;
      final sourceFrames = <img.Image>[];
      final sourceDurations = <int>[];

      for (int i = 0; i < decodedAnim.numFrames; i++) {
        final f = decodedAnim.frames[i];
        final dur = f.frameDuration > 10 ? f.frameDuration : 100;
        if (accumulatedDuration + dur > maxDurationMs && sourceFrames.isNotEmpty) {
          break; // Hard cap at 10 seconds
        }
        accumulatedDuration += dur;
        sourceFrames.add(f);
        sourceDurations.add(dur);
      }

      if (sourceFrames.isEmpty) {
        sourceFrames.add(decodedAnim.frames[0]);
        sourceDurations.add(100);
      }

      // If frame count is very large (> 32), downsample to keep file size under 500 KB
      if (sourceFrames.length > 32) {
        final step = (sourceFrames.length / 28).ceil();
        for (int i = 0; i < sourceFrames.length; i += step) {
          frameImages.add(sourceFrames[i]);
          int combinedDur = 0;
          for (int j = i; j < i + step && j < sourceDurations.length; j++) {
            combinedDur += sourceDurations[j];
          }
          frameDurations.add(combinedDur > 0 ? combinedDur : 100);
        }
      } else {
        frameImages = sourceFrames;
        frameDurations = sourceDurations;
      }
    } else if (rawFrames != null && rawFrames.isNotEmpty) {
      for (final fBytes in rawFrames) {
        final decoded = img.decodeImage(fBytes);
        if (decoded != null) {
          frameImages.add(decoded);
          frameDurations.add(defaultFrameDuration);
        }
      }
      if (frameImages.isEmpty) {
        throw Exception('Gagal membaca frame video untuk stiker animasi.');
      }
    } else {
      throw Exception('Data animasi tidak valid.');
    }

    img.Image buildAnimationSequence(List<img.Image> frames, List<int> durations, int innerSize) {
      final animation = img.Image(
        width: stickerDimension,
        height: stickerDimension,
        numChannels: 4,
      );
      animation.loopCount = 0; // Infinite loop required by WhatsApp

      for (int i = 0; i < frames.length; i++) {
        final src = frames[i];
        final targetFrame = i == 0
            ? animation
            : animation.addFrame(img.Image(
                width: stickerDimension,
                height: stickerDimension,
                numChannels: 4,
              ));
        targetFrame.frameDuration = durations[i].clamp(20, 1000);

        int targetWidth;
        int targetHeight;
        if (src.width >= src.height) {
          targetWidth = innerSize;
          targetHeight = (src.height * innerSize / src.width).round();
        } else {
          targetHeight = innerSize;
          targetWidth = (src.width * innerSize / src.height).round();
        }
        if (targetWidth <= 0) targetWidth = 1;
        if (targetHeight <= 0) targetHeight = 1;

        final resized = img.copyResize(
          src,
          width: targetWidth,
          height: targetHeight,
          interpolation: img.Interpolation.linear,
        );

        final dstX = (stickerDimension - resized.width) ~/ 2;
        final dstY = (stickerDimension - resized.height) ~/ 2;
        img.compositeImage(targetFrame, resized, dstX: dstX, dstY: dstY);
      }
      return animation;
    }

    // Step 1: Standard high-quality 480px box on 512x512 canvas
    img.Image animation = buildAnimationSequence(frameImages, frameDurations, targetInnerBox);

    // Progressive lossy quality compression
    for (final quality in [80, 65, 50, 40, 30]) {
      final webpBytes = Uint8List.fromList(
        img.encodeWebP(animation, singleFrame: false, quality: quality),
      );
      if (webpBytes.lengthInBytes <= maxBytes) {
        return ProcessedStickerResult(
          webpBytes: webpBytes,
          width: stickerDimension,
          height: stickerDimension,
          byteSize: webpBytes.lengthInBytes,
        );
      }
    }

    // Step 2: Downsample frames if still > 500 KB (halving frame count)
    if (frameImages.length > 8) {
      final reducedFrames = <img.Image>[];
      final reducedDurations = <int>[];
      for (int i = 0; i < frameImages.length; i += 2) {
        reducedFrames.add(frameImages[i]);
        final d1 = frameDurations[i];
        final d2 = (i + 1 < frameDurations.length) ? frameDurations[i + 1] : 0;
        reducedDurations.add(d1 + d2);
      }

      final smallerAnim = buildAnimationSequence(reducedFrames, reducedDurations, 440);
      for (final quality in [60, 45, 30, 20]) {
        final webpBytes = Uint8List.fromList(
          img.encodeWebP(smallerAnim, singleFrame: false, quality: quality),
        );
        if (webpBytes.lengthInBytes <= maxBytes) {
          return ProcessedStickerResult(
            webpBytes: webpBytes,
            width: stickerDimension,
            height: stickerDimension,
            byteSize: webpBytes.lengthInBytes,
          );
        }
      }
    }

    // Fallback: aggressive compression under limit
    final webpBytes = Uint8List.fromList(
      img.encodeWebP(animation, singleFrame: false, quality: 20),
    );
    return ProcessedStickerResult(
      webpBytes: webpBytes,
      width: stickerDimension,
      height: stickerDimension,
      byteSize: webpBytes.lengthInBytes,
    );
  }

  /// Quantize colors while strictly preserving the alpha channel.
  /// Prevents transparent borders/padding or transparent PNG cutouts from becoming solid black.
  static img.Image _quantizePreservingAlpha(img.Image src, int numberOfColors) {
    final quant = img.quantize(src, numberOfColors: numberOfColors);
    if (!src.hasAlpha) return quant;

    final result = img.Image(
      width: src.width,
      height: src.height,
      numChannels: 4,
    );
    for (int y = 0; y < src.height; y++) {
      for (int x = 0; x < src.width; x++) {
        final pOrig = src.getPixel(x, y);
        final pQuant = quant.getPixel(x, y);
        result.setPixelRgba(x, y, pQuant.r, pQuant.g, pQuant.b, pOrig.a);
      }
    }
    return result;
  }

  /// Generate tray icon (96x96 PNG, under 50KB) from source image bytes.
  static Future<Uint8List> generateTrayIcon(Uint8List sourceBytes) async {
    return await compute(_isolateProcessTrayIcon, sourceBytes);
  }

  /// Background isolate tray icon generator.
  static Uint8List _isolateProcessTrayIcon(Uint8List sourceBytes) {
    final original = img.decodeImage(sourceBytes);
    if (original == null) {
      throw Exception('Format gambar tidak dapat dibaca.');
    }

    int targetWidth;
    int targetHeight;
    if (original.width >= original.height) {
      targetWidth = trayDimension;
      targetHeight =
          (original.height * trayDimension / original.width).round();
    } else {
      targetHeight = trayDimension;
      targetWidth =
          (original.width * trayDimension / original.height).round();
    }

    if (targetWidth <= 0) targetWidth = 1;
    if (targetHeight <= 0) targetHeight = 1;

    final resized = img.copyResize(
      original,
      width: targetWidth,
      height: targetHeight,
      interpolation: img.Interpolation.linear,
    );

    final canvas = img.Image(
      width: trayDimension,
      height: trayDimension,
      numChannels: 4,
    );

    final dstX = (trayDimension - resized.width) ~/ 2;
    final dstY = (trayDimension - resized.height) ~/ 2;
    img.compositeImage(canvas, resized, dstX: dstX, dstY: dstY);

    Uint8List pngBytes = Uint8List.fromList(img.encodePng(canvas));
    if (pngBytes.lengthInBytes > maxTrayFileSizeBytes) {
      final quant = _quantizePreservingAlpha(canvas, 128);
      pngBytes = Uint8List.fromList(img.encodePng(quant));
    }
    if (pngBytes.lengthInBytes > maxTrayFileSizeBytes) {
      final quant = _quantizePreservingAlpha(canvas, 64);
      pngBytes = Uint8List.fromList(img.encodePng(quant));
    }

    return pngBytes;
  }

  /// Optimize an existing sticker file on disk so that its byte size is guaranteed <= maxBytes.
  static Future<bool> optimizeStickerFile({
    required File file,
    int maxBytes = maxFileSizeBytes,
  }) async {
    if (!file.existsSync()) return false;
    final currentSize = file.lengthSync();
    if (currentSize <= maxBytes) return true; // Already compliant

    try {
      final bytes = file.readAsBytesSync();
      final result = await processToStickerWebp(bytes, maxBytes: maxBytes);
      file.writeAsBytesSync(result.webpBytes);
      return true;
    } catch (e) {
      debugPrint('Failed to optimize sticker file ${file.path}: $e');
      return false;
    }
  }

  static Future<File> saveStickerFile({
    required String packDirectoryPath,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final packDir = Directory(packDirectoryPath);
    if (!packDir.existsSync()) {
      packDir.createSync(recursive: true);
    }

    final file = File('$packDirectoryPath/$fileName');
    file.writeAsBytesSync(bytes);
    return file;
  }
}
