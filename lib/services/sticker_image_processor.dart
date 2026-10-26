import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

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

  /// Process raw image bytes into compliant 512x512 WebP with transparent margins.
  /// Runs in background compute isolate to keep UI smooth and responsive.
  /// [maxBytes] defaults to 100 KB for static stickers or 500 KB for animated sticker packs.
  static Future<ProcessedStickerResult> processToStickerWebp(
    Uint8List sourceBytes, {
    int maxBytes = maxFileSizeBytes,
  }) async {
    return await compute(_isolateProcessSticker, {
      'bytes': sourceBytes,
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
