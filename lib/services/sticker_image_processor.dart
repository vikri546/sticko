import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

/// Thrown when a `.gif` file only contains a single static frame instead of animation.
class SingleFrameGifException implements Exception {
  final String message;
  const SingleFrameGifException(this.message);

  @override
  String toString() => message;
}

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

  /// Pick a single animated `.gif` file without re-encoding or stripping animation frames.
  static Future<PlatformFile?> pickGifFile() async {
    try {
      return await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['gif'],
        compressionQuality: 0,
      );
    } catch (e) {
      debugPrint('Error picking GIF file: $e');
      return null;
    }
  }

  /// Pick one or more animated `.gif` files cleanly from storage/gallery.
  /// Uses FilePicker with `compressionQuality: 0` so Android preserves the raw `.gif` bytes
  /// instead of flattening animation frames to a static image.
  static Future<List<PlatformFile>> pickMultipleGifFiles({int? limit}) async {
    if (limit != null && limit <= 1) {
      final single = await pickGifFile();
      return single != null ? [single] : [];
    }

    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['gif'],
        compressionQuality: 0,
      );
      if (limit != null && files.length > limit) {
        return files.take(limit).toList();
      }
      return files;
    } catch (e) {
      debugPrint('Error picking multiple GIF files: $e');
      return [];
    }
  }

  /// Check if file name or path has `.gif` extension.
  static bool isGifFile(String pathOrName) {
    return pathOrName.toLowerCase().trim().endsWith('.gif');
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

  /// Fast synchronous header check confirming GIF bytes contain more than 1 frame.
  /// Note: Prefer [hasMultipleGifFramesAsync] for web GIFs with XMP/custom extensions.
  static bool hasMultipleGifFrames(Uint8List bytes) {
    if (!isAnimatedGif(bytes)) return false;
    try {
      final decoder = img.GifDecoder()..maxPixels = 0;
      final info = decoder.startDecode(bytes);
      return (info?.numFrames ?? 0) > 1;
    } catch (_) {
      return false;
    }
  }

  /// Reliable frame-count check using Flutter's native C++ Skia GIF codec
  /// (handles Giphy/Photoshop XMP extensions and non-standard web GIFs),
  /// falling back to [hasMultipleGifFrames] when `dart:ui` is unavailable.
  static Future<bool> hasMultipleGifFramesAsync(Uint8List bytes) async {
    if (!isAnimatedGif(bytes)) return false;
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      return codec.frameCount > 1;
    } catch (_) {
      return hasMultipleGifFrames(bytes);
    } finally {
      codec?.dispose();
    }
  }

  /// Decode any GIF87a/GIF89a file (including Giphy delta-frame GCT/LCT,
  /// disposal 0/1/2/3, interlaced, XMP metadata, and transparent stickers)
  /// via Flutter's native Skia C++ GIF codec, capping duration to [maxDurationMs]
  /// and keeping at most 32 full-canvas RGBA frames in memory at <= 480px.
  static Future<({
    List<TransferableTypedData> rgbaFrames,
    int width,
    int height,
    List<int> durations,
  })?> _decodeGifWithNativeCodec(
    Uint8List gifBytes, {
    required int maxDurationMs,
    required bool requireMultipleFrames,
  }) async {
    int? targetWidth;
    int? targetHeight;
    if (gifBytes.length >= 10) {
      final logicalW = gifBytes[6] | (gifBytes[7] << 8);
      final logicalH = gifBytes[8] | (gifBytes[9] << 8);
      if (logicalW > 0 &&
          logicalH > 0 &&
          (logicalW > targetInnerBox || logicalH > targetInnerBox)) {
        if (logicalW >= logicalH) {
          targetWidth = targetInnerBox;
        } else {
          targetHeight = targetInnerBox;
        }
      }
    }

    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(
        gifBytes,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
    } catch (e) {
      debugPrint('Native GIF codec unavailable, falling back to Dart decoder: $e');
      return null;
    }

    try {
      final totalFrames = codec.frameCount;
      if (totalFrames <= 1) {
        if (requireMultipleFrames) {
          throw const SingleFrameGifException(
            'Berkas .gif ini tidak memiliki animasi bergerak (minimal 2 frame).',
          );
        }
        return null;
      }

      final keptBytes = <Uint8List>[];
      final keptDurations = <int>[];
      int frameWidth = 0;
      int frameHeight = 0;
      int accumulatedMs = 0;
      int sampleStep = 1;
      int pendingSkippedMs = 0;

      for (int i = 0; i < totalFrames; i++) {
        final frameInfo = await codec.getNextFrame();
        final image = frameInfo.image;
        try {
          final rawMs = frameInfo.duration.inMilliseconds;
          final dur = rawMs > 10 ? rawMs : 100;

          if (accumulatedMs + dur > maxDurationMs && keptBytes.isNotEmpty) {
            break;
          }
          accumulatedMs += dur;

          final shouldKeep = (i % sampleStep == 0) || keptBytes.isEmpty;
          if (!shouldKeep) {
            pendingSkippedMs += dur;
            continue;
          }

          final byteData = await image.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          );
          if (byteData == null) continue;

          if (pendingSkippedMs > 0 && keptDurations.isNotEmpty) {
            keptDurations[keptDurations.length - 1] += pendingSkippedMs;
            pendingSkippedMs = 0;
          }

          frameWidth = image.width;
          frameHeight = image.height;
          keptBytes.add(
            Uint8List.fromList(
              byteData.buffer.asUint8List(
                byteData.offsetInBytes,
                byteData.lengthInBytes,
              ),
            ),
          );
          keptDurations.add(dur);

          // Compact in-place when exceeding 32 kept frames (e.g. high-FPS Giphy GIFs)
          if (keptBytes.length >= 32 && i + 1 < totalFrames) {
            final compactedBytes = <Uint8List>[];
            final compactedDurations = <int>[];
            for (int k = 0; k < keptBytes.length; k += 2) {
              compactedBytes.add(keptBytes[k]);
              final d1 = keptDurations[k];
              final d2 = (k + 1 < keptDurations.length) ? keptDurations[k + 1] : 0;
              compactedDurations.add(d1 + d2);
            }
            keptBytes
              ..clear()
              ..addAll(compactedBytes);
            keptDurations
              ..clear()
              ..addAll(compactedDurations);
            sampleStep *= 2;
          }
        } finally {
          image.dispose();
        }
      }

      if (pendingSkippedMs > 0 && keptDurations.isNotEmpty) {
        keptDurations[keptDurations.length - 1] += pendingSkippedMs;
      }

      if (keptBytes.length <= 1 || frameWidth <= 0 || frameHeight <= 0) {
        if (requireMultipleFrames) {
          throw const SingleFrameGifException(
            'Berkas .gif ini tidak memiliki animasi bergerak (minimal 2 frame).',
          );
        }
        return null;
      }

      // Enforce hard cap <= maxDurationMs across all kept frames
      int totalDur = 0;
      for (int i = 0; i < keptDurations.length; i++) {
        totalDur += keptDurations[i];
        if (totalDur > maxDurationMs) {
          keptDurations[i] =
              (keptDurations[i] - (totalDur - maxDurationMs)).clamp(20, maxDurationMs);
          totalDur = maxDurationMs;
        }
      }

      return (
        rgbaFrames: keptBytes.map((b) => TransferableTypedData.fromList([b])).toList(),
        width: frameWidth,
        height: frameHeight,
        durations: keptDurations,
      );
    } finally {
      codec.dispose();
    }
  }

  /// Check if byte array has a valid WebP RIFF....WEBP header.
  static bool isWebpFormat(Uint8List bytes) {
    if (bytes.length < 12) return false;
    return bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50;
  }

  /// Check if byte array is an animated WebP (contains ANIM chunk)
  static bool isAnimatedWebp(Uint8List bytes) {
    if (bytes.length < 32) return false;
    if (!isWebpFormat(bytes)) return false;

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
    if (isWebpFormat(sourceBytes) &&
        !isAnimatedWebp(sourceBytes) &&
        sourceBytes.lengthInBytes <= maxBytes) {
      final decoded = img.decodeImage(sourceBytes);
      if (decoded != null &&
          decoded.width == stickerDimension &&
          decoded.height == stickerDimension) {
        return ProcessedStickerResult(
          webpBytes: sourceBytes,
          width: stickerDimension,
          height: stickerDimension,
          byteSize: sourceBytes.lengthInBytes,
        );
      }
    }
    return await compute(_isolateProcessSticker, {
      'bytes': sourceBytes,
      'maxBytes': maxBytes,
    });
  }

  /// Strictly validate and convert animated `.gif` bytes into compliant WhatsApp animated WebP
  /// (512x512, <= 500 KB, <= 10s, infinite loop). Rejects non-GIF or single-frame files.
  /// Uses native Skia C++ GIF decoding first for full Giphy/web GIF spec compliance.
  static Future<ProcessedStickerResult> processGifToStickerWebp({
    required Uint8List gifBytes,
    int maxDurationMs = 10000,
    int maxBytes = maxAnimatedFileSizeBytes,
  }) async {
    if (!isAnimatedGif(gifBytes)) {
      throw Exception('Format berkas tidak didukung. Gunakan format animasi .gif.');
    }

    final nativeDecoded = await _decodeGifWithNativeCodec(
      gifBytes,
      maxDurationMs: maxDurationMs,
      requireMultipleFrames: true,
    );

    if (nativeDecoded != null) {
      return await compute(_isolateProcessAnimatedSticker, {
        'rgbaFrames': nativeDecoded.rgbaFrames,
        'rgbaWidth': nativeDecoded.width,
        'rgbaHeight': nativeDecoded.height,
        'frameDurations': nativeDecoded.durations,
        'maxDurationMs': maxDurationMs,
        'maxBytes': maxBytes,
      });
    }

    if (!hasMultipleGifFrames(gifBytes)) {
      throw const SingleFrameGifException(
        'Berkas .gif ini tidak memiliki animasi bergerak (minimal 2 frame).',
      );
    }
    return processAnimatedToStickerWebp(
      bytes: gifBytes,
      maxDurationMs: maxDurationMs,
      maxBytes: maxBytes,
    );
  }

  /// Process animated media (GIF bytes, internal animated WebP bytes, or test frames)
  /// into compliant animated WebP (512x512, <= 500KB, <= 10s, infinite loop).
  static Future<ProcessedStickerResult> processAnimatedToStickerWebp({
    Uint8List? bytes,
    List<Uint8List>? frames,
    int? frameDurationMs,
    int maxDurationMs = 10000,
    int maxBytes = maxAnimatedFileSizeBytes,
  }) async {
    if (bytes != null && isAnimatedGif(bytes)) {
      final nativeDecoded = await _decodeGifWithNativeCodec(
        bytes,
        maxDurationMs: maxDurationMs,
        requireMultipleFrames: false,
      );
      if (nativeDecoded != null) {
        return await compute(_isolateProcessAnimatedSticker, {
          'rgbaFrames': nativeDecoded.rgbaFrames,
          'rgbaWidth': nativeDecoded.width,
          'rgbaHeight': nativeDecoded.height,
          'frameDurations': nativeDecoded.durations,
          'maxDurationMs': maxDurationMs,
          'maxBytes': maxBytes,
        });
      }
    }

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

    // If the input is already a compliant 512x512 static WebP within the size limit,
    // preserve its exact format and bytes without re-shrinking or re-encoding.
    if (isWebpFormat(sourceBytes) &&
        !isAnimatedWebp(sourceBytes) &&
        original.width == stickerDimension &&
        original.height == stickerDimension &&
        sourceBytes.lengthInBytes <= maxBytes) {
      return ProcessedStickerResult(
        webpBytes: sourceBytes,
        width: stickerDimension,
        height: stickerDimension,
        byteSize: sourceBytes.lengthInBytes,
      );
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

  /// Extract a standalone single-frame 4-channel RGBA image so palette-based GIF frames
  /// resize with smooth linear interpolation and preserve alpha without cloning all frames.
  static img.Image _toStandaloneRgbaFrame(img.Image src) {
    final singleFrame = src.hasAnimation ? img.Image.from(src, noAnimation: true) : src;
    if (singleFrame.hasPalette ||
        singleFrame.numChannels != 4 ||
        singleFrame.format != img.Format.uint8) {
      return singleFrame.convert(
        format: img.Format.uint8,
        numChannels: 4,
        noAnimation: true,
      );
    }
    return singleFrame;
  }

  /// Downsample frames evenly to at most [maxFrames] while merging durations
  /// to keep total animation playback speed accurate.
  static ({List<img.Image> frames, List<int> durations}) _downsampleFrames(
    List<img.Image> frames,
    List<int> durations,
    int maxFrames,
  ) {
    if (frames.length <= maxFrames || maxFrames < 2) {
      return (frames: frames, durations: durations);
    }
    final step = (frames.length / maxFrames).ceil();
    final outFrames = <img.Image>[];
    final outDurations = <int>[];
    for (int i = 0; i < frames.length; i += step) {
      outFrames.add(frames[i]);
      int combinedDur = 0;
      for (int j = i; j < i + step && j < durations.length; j++) {
        combinedDur += durations[j];
      }
      outDurations.add(combinedDur > 0 ? combinedDur : 100);
    }
    return (frames: outFrames, durations: outDurations);
  }

  /// Background isolate processor function for animated `.gif` (and internal `.webp`) stickers.
  /// Enforces WhatsApp constraints:
  /// - Maximum duration: 10 seconds (10,000 ms)
  /// - Dimensions: 512x512 with 16px transparent margins (480 inner box)
  /// - File size: <= 500 KB (500 * 1024 bytes)
  /// - Looping: Infinite loop (loopCount = 0)
  static ProcessedStickerResult _isolateProcessAnimatedSticker(dynamic input) {
    final map = input as Map<String, dynamic>;
    final bytes = map['bytes'] as Uint8List?;
    final rgbaTransferables = (map['rgbaFrames'] as List<dynamic>?)
        ?.cast<TransferableTypedData>()
        .toList();
    final rawFrames = (map['frames'] as List<dynamic>?)?.map((e) => e as Uint8List).toList();
    final defaultFrameDuration = (map['frameDurationMs'] as int?) ?? 100;
    final maxDurationMs = (map['maxDurationMs'] as int?) ?? 10000;
    final maxBytes = (map['maxBytes'] as int?) ?? maxAnimatedFileSizeBytes;

    List<img.Image> frameImages = [];
    List<int> frameDurations = [];

    if (rgbaTransferables != null && rgbaTransferables.isNotEmpty) {
      final width = map['rgbaWidth'] as int;
      final height = map['rgbaHeight'] as int;
      final durs = (map['frameDurations'] as List<dynamic>).cast<int>();
      final sourceFrames = <img.Image>[];
      final sourceDurations = <int>[];

      for (int i = 0; i < rgbaTransferables.length; i++) {
        final rawBytes = rgbaTransferables[i].materialize().asUint8List();
        sourceFrames.add(
          img.Image.fromBytes(
            width: width,
            height: height,
            bytes: rawBytes.buffer,
            bytesOffset: rawBytes.offsetInBytes,
            numChannels: 4,
            order: img.ChannelOrder.rgba,
          ),
        );
        sourceDurations.add(i < durs.length ? durs[i] : defaultFrameDuration);
      }

      final capped = _downsampleFrames(sourceFrames, sourceDurations, 28);
      frameImages = capped.frames;
      frameDurations = capped.durations;
    } else if (bytes != null) {
      img.Image? decodedAnim;
      if (isAnimatedGif(bytes)) {
        // Allow higher combined frame pixel budget for HD multi-frame GIFs.
        final gifDecoder = img.GifDecoder()..maxPixels = 1 << 30;
        decodedAnim = gifDecoder.decode(bytes);
      } else if (isAnimatedWebp(bytes)) {
        decodedAnim = img.decodeWebP(bytes);
      } else {
        decodedAnim = img.decodeImage(bytes);
      }

      if (decodedAnim == null) {
        throw Exception('Format animasi .gif tidak dapat dibaca oleh sistem.');
      }

      if (decodedAnim.numFrames <= 1) {
        return _isolateProcessSticker({
          'bytes': bytes,
          'maxBytes': maxBytes,
        });
      }

      // If the input is already a compliant 512x512 animated WebP within duration and size limits,
      // preserve its exact format and bytes without re-shrinking or re-encoding.
      if (isAnimatedWebp(bytes) &&
          decodedAnim.width == stickerDimension &&
          decodedAnim.height == stickerDimension &&
          bytes.lengthInBytes <= maxBytes) {
        int totalDur = 0;
        for (int i = 0; i < decodedAnim.numFrames; i++) {
          final d = decodedAnim.frames[i].frameDuration;
          totalDur += d > 10 ? d : 100;
        }
        if (totalDur <= maxDurationMs) {
          return ProcessedStickerResult(
            webpBytes: bytes,
            width: stickerDimension,
            height: stickerDimension,
            byteSize: bytes.lengthInBytes,
          );
        }
      }

      // Collect frames up to maxDurationMs (10,000 ms) and convert each to standalone RGBA.
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
        sourceFrames.add(_toStandaloneRgbaFrame(f));
        sourceDurations.add(dur);
      }

      if (sourceFrames.isEmpty) {
        sourceFrames.add(_toStandaloneRgbaFrame(decodedAnim.frames[0]));
        sourceDurations.add(100);
      }

      final capped = _downsampleFrames(sourceFrames, sourceDurations, 28);
      frameImages = capped.frames;
      frameDurations = capped.durations;
    } else if (rawFrames != null && rawFrames.isNotEmpty) {
      for (final fBytes in rawFrames) {
        final decoded = img.decodeImage(fBytes);
        if (decoded != null) {
          frameImages.add(_toStandaloneRgbaFrame(decoded));
          frameDurations.add(defaultFrameDuration);
        }
      }
      if (frameImages.isEmpty) {
        throw Exception('Gagal membaca frame animasi.');
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
        targetFrame.frameDuration = durations[i].clamp(20, maxDurationMs);

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

    ProcessedStickerResult? tryEncodeWithinLimit(
      img.Image animation,
      List<int> qualities, {
      int alphaQuality = 90,
    }) {
      for (final quality in qualities) {
        // Must explicitly pass lossless: false so quality parameter is applied by WebPEncoder.
        final webpBytes = Uint8List.fromList(
          img.encodeWebP(
            animation,
            singleFrame: false,
            lossless: false,
            exact: false,
            quality: quality,
            alphaQuality: alphaQuality,
          ),
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
      return null;
    }

    // Step 1: Full 480px inner canvas with progressive lossy VP8 quality
    final animation = buildAnimationSequence(frameImages, frameDurations, targetInnerBox);
    final step1 = tryEncodeWithinLimit(animation, const [80, 65, 50, 35]);
    if (step1 != null) return step1;

    // Step 2: Reduce frame count (up to 14 frames) and scale down canvas progressively
    final reduced14 = _downsampleFrames(frameImages, frameDurations, 14);
    for (final boxSize in const [420, 340, 260]) {
      final scaledAnim = buildAnimationSequence(
        reduced14.frames,
        reduced14.durations,
        boxSize,
      );
      final encoded = tryEncodeWithinLimit(
        scaledAnim,
        const [55, 40, 25],
        alphaQuality: 80,
      );
      if (encoded != null) return encoded;
    }

    // Fallback: cap to 10 frames and 240px inner canvas at low quality to respect 500 KB cap
    final fallbackFrames = _downsampleFrames(frameImages, frameDurations, 10);
    final fallbackAnim = buildAnimationSequence(
      fallbackFrames.frames,
      fallbackFrames.durations,
      240,
    );
    final webpBytes = Uint8List.fromList(
      img.encodeWebP(
        fallbackAnim,
        singleFrame: false,
        lossless: false,
        exact: false,
        quality: 15,
        alphaQuality: 70,
      ),
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

  /// Background isolate tray icon generator (decodes frame 0 only for animated inputs).
  static Uint8List _isolateProcessTrayIcon(Uint8List sourceBytes) {
    final decodedFrame0 = img.decodeImage(sourceBytes, frame: 0);
    if (decodedFrame0 == null) {
      throw Exception('Format gambar tidak dapat dibaca.');
    }
    final original = _toStandaloneRgbaFrame(decodedFrame0);

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
