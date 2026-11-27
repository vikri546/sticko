import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';

/// Thrown when a `.gif` file only contains a single static frame instead of animation.
class SingleFrameGifException implements Exception {
  final String message;
  const SingleFrameGifException(this.message);

  @override
  String toString() => message;
}

/// Thrown when a selected video file does not contain any audio track.
class VideoNoAudioException implements Exception {
  final String message;
  const VideoNoAudioException(this.message);

  @override
  String toString() => message;
}

/// Thrown when a selected video file exceeds the maximum allowed 10-second duration.
class VideoDurationExceededException implements Exception {
  final String message;
  final int durationMs;
  const VideoDurationExceededException(this.message, {this.durationMs = 0});

  @override
  String toString() => message;
}

/// Data class holding processed video-with-audio sticker details.
class ProcessedVideoAudioStickerResult {
  final Uint8List webpBytes;
  final String tempAudioFilePath;
  final String audioExtension;
  final int durationMs;

  const ProcessedVideoAudioStickerResult({
    required this.webpBytes,
    required this.tempAudioFilePath,
    required this.audioExtension,
    required this.durationMs,
  });
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

  /// Supported video container extensions for Video+Audio stickers.
  static const List<String> supportedVideoExtensions = [
    'mp4',
    'mov',
    'webm',
    'mkv',
    '3gp',
    'm4v',
  ];

  /// Check if file name or path has a supported video extension (`.mp4`, `.mov`, `.webm`, `.mkv`, `.3gp`, `.m4v`).
  static bool isSupportedVideoFile(String pathOrName) {
    final lower = pathOrName.toLowerCase().trim();
    return supportedVideoExtensions.any((ext) => lower.endsWith('.$ext'));
  }

  /// Pick a single video file (`.mp4` and similar formats) without pre-compression.
  static Future<PlatformFile?> pickVideoFile() async {
    try {
      return await FilePicker.pickFile(
        type: FileType.video,
        compressionQuality: 0,
      );
    } catch (e) {
      debugPrint('Error picking video file: $e');
      return null;
    }
  }

  /// Pick one or more video files (`.mp4` and similar formats) from storage/gallery.
  static Future<List<PlatformFile>> pickMultipleVideoFiles({int? limit}) async {
    if (limit != null && limit <= 1) {
      final single = await pickVideoFile();
      return single != null ? [single] : [];
    }

    try {
      final files = await FilePicker.pickFiles(
        type: FileType.video,
        compressionQuality: 0,
      );
      if (limit != null && files.length > limit) {
        return files.take(limit).toList();
      }
      return files;
    } catch (e) {
      debugPrint('Error picking multiple video files: $e');
      return [];
    }
  }

  /// Process a video file (`<= 10s` with audio) into a compliant 512x512 animated WebP
  /// (`<= 500 KB`) paired with its extracted native audio track.
  static Future<ProcessedVideoAudioStickerResult> processVideoToStickerWithAudio({
    required String videoPath,
    required String tempOutputDirPath,
    int maxDurationMs = 10000,
    int maxBytes = maxAnimatedFileSizeBytes,
  }) async {
    final extracted = await WhatsAppStickersService.extractVideoStickerWithAudio(
      videoPath: videoPath,
      outputDirPath: tempOutputDirPath,
      maxDurationMs: maxDurationMs,
    );

    if (!extracted.ok) {
      if (extracted.errorCode == 'NO_AUDIO') {
        throw VideoNoAudioException(
          extracted.errorMessage ??
              'Video yang dipilih tidak memiliki suara (audio). Pilih video dengan suara.',
        );
      }
      if (extracted.errorCode == 'DURATION_EXCEEDED') {
        final secs = (extracted.originalDurationMs / 1000).toStringAsFixed(1);
        throw VideoDurationExceededException(
          'Durasi video ($secs detik) melebihi batas maksimal 10 detik.',
          durationMs: extracted.originalDurationMs,
        );
      }
      throw Exception(
        extracted.errorMessage ?? 'Gagal memproses berkas video.',
      );
    }

    if (!extracted.hasAudio ||
        extracted.audioFilePath == null ||
        extracted.audioFilePath!.isEmpty) {
      throw const VideoNoAudioException(
        'Video yang dipilih tidak memiliki suara (audio). Pilih video dengan suara.',
      );
    }

    if (extracted.frames.isEmpty) {
      throw Exception('Gagal mengekstrak frame visual dari berkas video.');
    }

    final processedWebp = await processAnimatedToStickerWebp(
      frames: extracted.frames,
      frameDurationMs: extracted.frameDurationMs,
      maxDurationMs: maxDurationMs,
      maxBytes: maxBytes,
    );

    return ProcessedVideoAudioStickerResult(
      webpBytes: processedWebp.webpBytes,
      tempAudioFilePath: extracted.audioFilePath!,
      audioExtension: extracted.audioExtension,
      durationMs: extracted.totalDurationMs.clamp(100, maxDurationMs),
    );
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
      int pendingSkippedMs = 0;

      // High frame budget (120 frames = 30 FPS for 4s, 20 FPS for 6s, 12 FPS for 10s)
      // so normal Giphy/web GIFs keep 100% of their original frames and exact timing.
      const int maxDecodedFrames = 120;
      double sampleStride = 1.0;
      double nextKeepIndex = 0.0;

      for (int i = 0; i < totalFrames; i++) {
        final frameInfo = await codec.getNextFrame();
        final image = frameInfo.image;
        try {
          final rawMs = frameInfo.duration.inMilliseconds;
          // Skia already normalizes 0ms/10ms GIF delays to 100ms per Chrome/browser spec.
          final dur = rawMs >= 16 ? rawMs : (rawMs > 0 ? 20 : 100);

          if (i == 0 && totalFrames > maxDecodedFrames) {
            final estimatedFramesInWindow =
                (maxDurationMs / dur).ceil().clamp(2, totalFrames);
            if (estimatedFramesInWindow > maxDecodedFrames) {
              sampleStride = estimatedFramesInWindow / maxDecodedFrames;
            }
          }

          if (accumulatedMs + dur > maxDurationMs && keptBytes.isNotEmpty) {
            break;
          }
          accumulatedMs += dur;

          final shouldKeep = (i == 0) || (i + 1e-6 >= nextKeepIndex);
          if (!shouldKeep) {
            pendingSkippedMs += dur;
            continue;
          }
          nextKeepIndex += sampleStride;

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

          // Safety guard only for extreme variable-delay GIFs exceeding memory ceiling
          if (keptBytes.length >= 160 && i + 1 < totalFrames) {
            final resampled = _resampleGenericUniformly(
              keptBytes,
              keptDurations,
              maxDecodedFrames,
              maxDurationMs,
            );
            keptBytes
              ..clear()
              ..addAll(resampled.items);
            keptDurations
              ..clear()
              ..addAll(resampled.durations);
            sampleStride = (sampleStride * 1.35).clamp(1.0, 16.0);
            nextKeepIndex = i + sampleStride;
          }
        } finally {
          image.dispose();
        }
      }

      if (pendingSkippedMs > 0 && keptDurations.isNotEmpty) {
        keptDurations[keptDurations.length - 1] += pendingSkippedMs;
      }

      if (keptBytes.length > maxDecodedFrames) {
        final resampled = _resampleGenericUniformly(
          keptBytes,
          keptDurations,
          maxDecodedFrames,
          maxDurationMs,
        );
        keptBytes
          ..clear()
          ..addAll(resampled.items);
        keptDurations
          ..clear()
          ..addAll(resampled.durations);
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
              (keptDurations[i] - (totalDur - maxDurationMs)).clamp(16, maxDurationMs);
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

  /// Check if two single-frame RGBA images have identical pixel buffers.
  static bool _areFramesIdentical(img.Image a, img.Image b) {
    if (a.width != b.width || a.height != b.height || a.numChannels != b.numChannels) {
      return false;
    }
    final bytesA = a.toUint8List();
    final bytesB = b.toUint8List();
    if (bytesA.length != bytesB.length) return false;
    // Fast-fail probe at start, middle, end before full scan
    final len = bytesA.length;
    if (len == 0) return true;
    if (bytesA[0] != bytesB[0] ||
        bytesA[len >> 1] != bytesB[len >> 1] ||
        bytesA[len - 1] != bytesB[len - 1]) {
      return false;
    }
    for (int i = 0; i < len; i++) {
      if (bytesA[i] != bytesB[i]) return false;
    }
    return true;
  }

  /// Merge identical consecutive frames by folding their durations together.
  /// Saves WebP bytes without dropping any real motion or altering playback speed.
  static ({List<img.Image> frames, List<int> durations}) _deduplicateConsecutiveFrames(
    List<img.Image> frames,
    List<int> durations,
    int maxDurationMs,
  ) {
    if (frames.length <= 2) {
      return (frames: frames, durations: durations);
    }
    final outFrames = <img.Image>[frames.first];
    final outDurations = <int>[durations.first];

    for (int i = 1; i < frames.length; i++) {
      final candidate = frames[i];
      final dur = durations[i];
      final mergedDur = outDurations.last + dur;
      if (_areFramesIdentical(outFrames.last, candidate) &&
          mergedDur <= maxDurationMs) {
        outDurations[outDurations.length - 1] = mergedDur;
      } else {
        outFrames.add(candidate);
        outDurations.add(dur);
      }
    }

    // Never collapse an animated sequence down to 1 single frame
    if (outFrames.length < 2) {
      return (frames: frames, durations: durations);
    }
    return (frames: outFrames, durations: outDurations);
  }

  /// Time-uniform fractional resampling to exactly [targetCount] frames while preserving
  /// total playback duration and Frame 0 intact (avoids 50% integer `ceil()` FPS cliffs).
  static ({List<T> items, List<int> durations}) _resampleGenericUniformly<T>(
    List<T> items,
    List<int> durations,
    int targetCount,
    int maxDurationMs,
  ) {
    if (items.length <= targetCount || targetCount < 2) {
      return (items: List<T>.from(items), durations: List<int>.from(durations));
    }

    int totalMs = 0;
    final endTimes = <int>[];
    for (int i = 0; i < items.length; i++) {
      final d = i < durations.length && durations[i] > 0 ? durations[i] : 50;
      totalMs += d;
      endTimes.add(totalMs);
    }
    final cappedTotalMs = totalMs > maxDurationMs ? maxDurationMs : totalMs;

    final outItems = <T>[];
    final outDurations = <int>[];
    int srcIdx = 0;
    int prevEnd = 0;

    for (int k = 0; k < targetCount; k++) {
      final targetEnd = ((k + 1) * cappedTotalMs / targetCount).round();
      final sampleTime = (k == 0) ? 0 : ((k * totalMs) / targetCount).floor();

      while (srcIdx + 1 < items.length && endTimes[srcIdx] <= sampleTime) {
        srcIdx++;
      }

      outItems.add(items[srcIdx]);
      final sliceDur = (targetEnd - prevEnd).clamp(16, maxDurationMs);
      outDurations.add(sliceDur);
      prevEnd = targetEnd;
    }

    return (items: outItems, durations: outDurations);
  }

  /// Background isolate processor function for animated `.gif` (and internal `.webp`) stickers.
  /// Prioritizes keeping 100% of original GIF frames & timing for smooth playback while
  /// enforcing WhatsApp constraints:
  /// - Maximum duration: 10 seconds (10,000 ms)
  /// - Dimensions: 512x512 with transparent padding
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

    const int maxWorkingFrames = 120;
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

      // Preserve ALL decoded frames (already capped cleanly at 120 in native decoder)
      frameImages = sourceFrames;
      frameDurations = sourceDurations;
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
          totalDur += d >= 8 ? d : 100;
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

      // Collect all frames up to maxDurationMs (10,000 ms) preserving original timing.
      int accumulatedDuration = 0;
      final sourceFrames = <img.Image>[];
      final sourceDurations = <int>[];

      for (int i = 0; i < decodedAnim.numFrames; i++) {
        final f = decodedAnim.frames[i];
        final dur = f.frameDuration >= 20 ? f.frameDuration : 100;
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

      if (sourceFrames.length > maxWorkingFrames) {
        final resampled = _resampleGenericUniformly(
          sourceFrames,
          sourceDurations,
          maxWorkingFrames,
          maxDurationMs,
        );
        frameImages = resampled.items;
        frameDurations = resampled.durations;
      } else {
        frameImages = sourceFrames;
        frameDurations = sourceDurations;
      }
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

    // Step 0: Merge identical consecutive frames (free size win, zero motion loss)
    final deduped = _deduplicateConsecutiveFrames(
      frameImages,
      frameDurations,
      maxDurationMs,
    );
    frameImages = deduped.frames;
    frameDurations = deduped.durations;

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
        // WhatsApp allows >= 8ms; clamping >= 16ms supports smooth playback up to 60 FPS
        targetFrame.frameDuration = durations[i].clamp(16, maxDurationMs);

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

    Uint8List encodeLossyWebp(
      img.Image animation, {
      required int quality,
      int method = 2,
      int alphaQuality = 90,
    }) {
      return Uint8List.fromList(
        img.encodeWebP(
          animation,
          singleFrame: false,
          lossless: false,
          exact: false,
          quality: quality,
          method: method,
          alphaQuality: alphaQuality,
        ),
      );
    }

    ProcessedStickerResult toResult(Uint8List bytes) => ProcessedStickerResult(
          webpBytes: bytes,
          width: stickerDimension,
          height: stickerDimension,
          byteSize: bytes.lengthInBytes,
        );

    // Step 1: 100% ORIGINAL FPS on full 480px inner canvas with adaptive quality jump
    final fullAnim = buildAnimationSequence(frameImages, frameDurations, targetInnerBox);
    final initialQuality = frameImages.length >= 60 ? 65 : 75;
    final probeBytes = encodeLossyWebp(
      fullAnim,
      quality: initialQuality,
      method: 2,
      alphaQuality: 90,
    );
    if (probeBytes.lengthInBytes <= maxBytes) {
      return toResult(probeBytes);
    }

    final overshoot = probeBytes.lengthInBytes / maxBytes;
    final List<({int q, int m, int aq})> step1Tiers;
    if (overshoot <= 1.25) {
      step1Tiers = const [
        (q: 55, m: 2, aq: 88),
        (q: 40, m: 2, aq: 85),
        (q: 28, m: 4, aq: 80),
      ];
    } else if (overshoot <= 2.0) {
      step1Tiers = const [
        (q: 40, m: 2, aq: 85),
        (q: 25, m: 4, aq: 80),
        (q: 18, m: 4, aq: 75),
      ];
    } else {
      step1Tiers = const [
        (q: 25, m: 4, aq: 80),
        (q: 16, m: 4, aq: 75),
      ];
    }

    for (final tier in step1Tiers) {
      final candidate = encodeLossyWebp(
        fullAnim,
        quality: tier.q,
        method: tier.m,
        alphaQuality: tier.aq,
      );
      if (candidate.lengthInBytes <= maxBytes) {
        return toResult(candidate);
      }
    }

    // Step 2: STILL 100% ORIGINAL FPS — gently scale inner sticker box before ever dropping frames
    for (final cfg in const [
      (box: 400, tiers: [(q: 40, m: 2, aq: 80), (q: 24, m: 4, aq: 75)]),
      (box: 336, tiers: [(q: 34, m: 2, aq: 75), (q: 20, m: 4, aq: 70)]),
    ]) {
      final scaledAnim = buildAnimationSequence(frameImages, frameDurations, cfg.box);
      for (final tier in cfg.tiers) {
        final candidate = encodeLossyWebp(
          scaledAnim,
          quality: tier.q,
          method: tier.m,
          alphaQuality: tier.aq,
        );
        if (candidate.lengthInBytes <= maxBytes) {
          return toResult(candidate);
        }
      }
    }

    // Step 3: Last resort — smooth time-uniform FPS resampling (gradual, never abrupt 50% cliffs)
    for (final plan in const [
      (ratio: 0.75, maxCap: 60, box: 384, q1: 35, q2: 22),
      (ratio: 0.55, maxCap: 42, box: 340, q1: 30, q2: 18),
      (ratio: 0.38, maxCap: 28, box: 300, q1: 25, q2: 15),
    ]) {
      final targetCount =
          (frameImages.length * plan.ratio).round().clamp(2, plan.maxCap);
      if (targetCount >= frameImages.length) continue;

      final resampled = _resampleGenericUniformly(
        frameImages,
        frameDurations,
        targetCount,
        maxDurationMs,
      );
      final resampledAnim = buildAnimationSequence(
        resampled.items,
        resampled.durations,
        plan.box,
      );
      for (final q in [plan.q1, plan.q2]) {
        final candidate = encodeLossyWebp(
          resampledAnim,
          quality: q,
          method: q >= 30 ? 2 : 4,
          alphaQuality: 75,
        );
        if (candidate.lengthInBytes <= maxBytes) {
          return toResult(candidate);
        }
      }
    }

    // Fallback: cap to 20 time-uniform frames at 256px inner box to guarantee <= 500 KB
    final fallbackResampled = _resampleGenericUniformly(
      frameImages,
      frameDurations,
      frameImages.length > 20 ? 20 : frameImages.length,
      maxDurationMs,
    );
    final fallbackAnim = buildAnimationSequence(
      fallbackResampled.items,
      fallbackResampled.durations,
      256,
    );
    final webpBytes = encodeLossyWebp(
      fallbackAnim,
      quality: 15,
      method: 4,
      alphaQuality: 65,
    );
    return toResult(webpBytes);
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

  /// Compute the automatic scale factor needed to make non-transparent video content
  /// fill the entire 512x512 square canvas edge-to-edge (`Penuh` / `Bulat` crop modes).
  static double computeContentFillScale(Uint8List bytes) {
    try {
      final frame0 = img.decodeImage(bytes, frame: 0);
      if (frame0 == null || frame0.width <= 0 || frame0.height <= 0) {
        return 1.0;
      }
      final rgba = _toStandaloneRgbaFrame(frame0);
      int minX = rgba.width;
      int maxX = -1;
      int minY = rgba.height;
      int maxY = -1;

      for (int y = 0; y < rgba.height; y++) {
        for (int x = 0; x < rgba.width; x++) {
          if (rgba.getPixel(x, y).a > 8) {
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
          }
        }
      }

      if (maxX < minX || maxY < minY) return 1.0;
      final contentW = (maxX - minX + 1).toDouble();
      final contentH = (maxY - minY + 1).toDouble();
      final scaleX = rgba.width / contentW;
      final scaleY = rgba.height / contentH;
      return math.max(scaleX, scaleY).clamp(1.0, 3.5);
    } catch (_) {
      return 1.0;
    }
  }

  /// Apply interactive crop (`Fit` / `Penuh` / `Bulat`), pan offset, and zoom scale
  /// across every frame of an animated WebP sticker while keeping `512x512` and `<= 500 KB`.
  static Future<Uint8List> transformAnimatedStickerWebp({
    required Uint8List webpBytes,
    required double userScale,
    required double panX,
    required double panY,
    required double canvasSize,
    double modeBaseScale = 1.0,
    bool circleMask = false,
    int maxBytes = maxAnimatedFileSizeBytes,
  }) async {
    return compute(_isolateTransformAnimatedSticker, {
      'bytes': webpBytes,
      'userScale': userScale,
      'panX': panX,
      'panY': panY,
      'canvasSize': canvasSize,
      'modeBaseScale': modeBaseScale,
      'circleMask': circleMask,
      'maxBytes': maxBytes,
    });
  }

  static Uint8List _isolateTransformAnimatedSticker(Map<String, dynamic> args) {
    final bytes = args['bytes'] as Uint8List;
    final userScale = ((args['userScale'] as num?)?.toDouble() ?? 1.0).clamp(0.25, 6.0);
    final panX = (args['panX'] as num?)?.toDouble() ?? 0.0;
    final panY = (args['panY'] as num?)?.toDouble() ?? 0.0;
    final canvasSize = ((args['canvasSize'] as num?)?.toDouble() ?? 240.0).clamp(1.0, 4096.0);
    final modeBaseScale = ((args['modeBaseScale'] as num?)?.toDouble() ?? 1.0).clamp(0.25, 6.0);
    final circleMask = args['circleMask'] == true;
    final maxBytes = (args['maxBytes'] as int?) ?? maxAnimatedFileSizeBytes;

    final decoded = img.decodeWebP(bytes) ?? img.decodeImage(bytes);
    if (decoded == null) return bytes;

    final srcFrames = <img.Image>[];
    final durations = <int>[];
    final frameCount = decoded.numFrames;
    for (int i = 0; i < frameCount; i++) {
      final f = decoded.frames[i];
      srcFrames.add(_toStandaloneRgbaFrame(f));
      final d = f.frameDuration;
      durations.add(d >= 16 ? d : 100);
    }
    if (srcFrames.isEmpty) return bytes;

    List<img.Image> renderTransformedFrames(int targetDim) {
      final srcW = srcFrames.first.width;
      final srcH = srcFrames.first.height;
      final halfCanvas = canvasSize * 0.5;
      final outToCanvas = canvasSize / targetDim;

      // Precompute source X/Y coordinates & bilinear weights once for all frames
      final x0Arr = Int32List(targetDim);
      final x1Arr = Int32List(targetDim);
      final wxArr = Int32List(targetDim); // 0..256 fixed-point
      final xValid = Uint8List(targetDim);

      final y0Arr = Int32List(targetDim);
      final y1Arr = Int32List(targetDim);
      final wyArr = Int32List(targetDim);
      final yValid = Uint8List(targetDim);

      for (int ox = 0; ox < targetDim; ox++) {
        final vx = (ox + 0.5) * outToCanvas;
        final cx = (vx - panX) / userScale;
        final nx = (cx - halfCanvas) / (halfCanvas * modeBaseScale);
        final sx = (nx + 1.0) * 0.5 * srcW - 0.5;
        if (sx >= -0.5 && sx <= srcW - 0.5) {
          xValid[ox] = 1;
          final clamped = sx.clamp(0.0, (srcW - 1).toDouble());
          final x0 = clamped.floor();
          x0Arr[ox] = x0;
          x1Arr[ox] = (x0 + 1 < srcW) ? x0 + 1 : x0;
          wxArr[ox] = ((clamped - x0) * 256.0).round().clamp(0, 256);
        }
      }

      for (int oy = 0; oy < targetDim; oy++) {
        final vy = (oy + 0.5) * outToCanvas;
        final cy = (vy - panY) / userScale;
        final ny = (cy - halfCanvas) / (halfCanvas * modeBaseScale);
        final sy = (ny + 1.0) * 0.5 * srcH - 0.5;
        if (sy >= -0.5 && sy <= srcH - 0.5) {
          yValid[oy] = 1;
          final clamped = sy.clamp(0.0, (srcH - 1).toDouble());
          final y0 = clamped.floor();
          y0Arr[oy] = y0;
          y1Arr[oy] = (y0 + 1 < srcH) ? y0 + 1 : y0;
          wyArr[oy] = ((clamped - y0) * 256.0).round().clamp(0, 256);
        }
      }

      // Precompute smooth circular alpha mask (0..256) when circleMask is enabled
      Int32List? circleAlphaMask;
      if (circleMask) {
        circleAlphaMask = Int32List(targetDim * targetDim);
        final center = (targetDim - 1) * 0.5;
        final radius = targetDim * 0.5;
        for (int oy = 0; oy < targetDim; oy++) {
          final dy = oy - center;
          final rowOffset = oy * targetDim;
          for (int ox = 0; ox < targetDim; ox++) {
            final dx = ox - center;
            final dist = math.sqrt(dx * dx + dy * dy);
            if (dist <= radius - 1.0) {
              circleAlphaMask[rowOffset + ox] = 256;
            } else if (dist < radius + 0.5) {
              circleAlphaMask[rowOffset + ox] =
                  (((radius + 0.5 - dist) / 1.5) * 256.0).round().clamp(0, 256);
            }
          }
        }
      }

      final rendered = <img.Image>[];
      for (int fIdx = 0; fIdx < srcFrames.length; fIdx++) {
        final src = srcFrames[fIdx];
        final srcBuf = src.toUint8List();
        final dst = img.Image(
          width: stickerDimension,
          height: stickerDimension,
          numChannels: 4,
        );
        final dstBuf = dst.toUint8List();
        final padOffset = (stickerDimension - targetDim) ~/ 2;

        for (int oy = 0; oy < targetDim; oy++) {
          if (yValid[oy] == 0) continue;
          final y0 = y0Arr[oy];
          final y1 = y1Arr[oy];
          final wy = wyArr[oy];
          final iwy = 256 - wy;
          final dstRow = ((oy + padOffset) * stickerDimension + padOffset) * 4;
          final maskRow = oy * targetDim;

          for (int ox = 0; ox < targetDim; ox++) {
            if (xValid[ox] == 0) continue;
            final maskVal = circleAlphaMask != null ? circleAlphaMask[maskRow + ox] : 256;
            if (maskVal == 0) continue;

            final x0 = x0Arr[ox];
            final x1 = x1Arr[ox];
            final wx = wxArr[ox];
            final iwx = 256 - wx;

            final p00 = (y0 * srcW + x0) * 4;
            final p10 = (y0 * srcW + x1) * 4;
            final p01 = (y1 * srcW + x0) * 4;
            final p11 = (y1 * srcW + x1) * 4;

            final w00 = iwx * iwy;
            final w10 = wx * iwy;
            final w01 = iwx * wy;
            final w11 = wx * wy;

            final dIdx = dstRow + ox * 4;
            dstBuf[dIdx] = (srcBuf[p00] * w00 +
                    srcBuf[p10] * w10 +
                    srcBuf[p01] * w01 +
                    srcBuf[p11] * w11 +
                    32768) >>
                16;
            dstBuf[dIdx + 1] = (srcBuf[p00 + 1] * w00 +
                    srcBuf[p10 + 1] * w10 +
                    srcBuf[p01 + 1] * w01 +
                    srcBuf[p11 + 1] * w11 +
                    32768) >>
                16;
            dstBuf[dIdx + 2] = (srcBuf[p00 + 2] * w00 +
                    srcBuf[p10 + 2] * w10 +
                    srcBuf[p01 + 2] * w01 +
                    srcBuf[p11 + 2] * w11 +
                    32768) >>
                16;
            final rawAlpha = (srcBuf[p00 + 3] * w00 +
                    srcBuf[p10 + 3] * w10 +
                    srcBuf[p01 + 3] * w01 +
                    srcBuf[p11 + 3] * w11 +
                    32768) >>
                16;
            dstBuf[dIdx + 3] = (rawAlpha * maskVal) >> 8;
          }
        }
        rendered.add(dst);
      }
      return rendered;
    }

    Uint8List encodeAnim(List<img.Image> frames, List<int> durs, int quality, int method, int alphaQ) {
      final anim = frames.first.clone(noAnimation: true);
      anim.loopCount = 0;
      anim.frameDuration = durs.first;
      for (int i = 1; i < frames.length; i++) {
        final f = anim.addFrame(frames[i]);
        f.frameDuration = durs[i];
      }
      return Uint8List.fromList(
        img.encodeWebP(
          anim,
          singleFrame: false,
          lossless: false,
          exact: false,
          quality: quality,
          method: method,
          alphaQuality: alphaQ,
        ),
      );
    }

    // Try full 512x512 canvas first across quality tiers
    final fullFrames = renderTransformedFrames(stickerDimension);
    for (final tier in const [
      (q: 72, m: 2, aq: 88),
      (q: 50, m: 2, aq: 84),
      (q: 34, m: 4, aq: 78),
      (q: 22, m: 4, aq: 72),
      (q: 15, m: 4, aq: 65),
    ]) {
      final encoded = encodeAnim(fullFrames, durations, tier.q, tier.m, tier.aq);
      if (encoded.lengthInBytes <= maxBytes) {
        return encoded;
      }
    }

    // Fallback for dense high-frame-count clips: time-uniform resample while preserving crop/zoom
    for (final ratio in const [0.7, 0.5, 0.35]) {
      final targetCount = (fullFrames.length * ratio).round().clamp(2, 45);
      if (targetCount >= fullFrames.length) continue;
      final resampled = _resampleGenericUniformly(
        fullFrames,
        durations,
        targetCount,
        10000,
      );
      for (final q in const [32, 20, 14]) {
        final encoded = encodeAnim(resampled.items, resampled.durations, q, 4, 70);
        if (encoded.lengthInBytes <= maxBytes) {
          return encoded;
        }
      }
    }

    final compactFrames = renderTransformedFrames(360);
    final capped = _resampleGenericUniformly(
      compactFrames,
      durations,
      compactFrames.length > 20 ? 20 : compactFrames.length,
      10000,
    );
    return encodeAnim(capped.items, capped.durations, 14, 4, 65);
  }
}
