import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';

/// Class containing the result of sticker pack validation against official WhatsApp rules.
class ValidationResult {
  final bool isValid;
  final List<String> errors;

  const ValidationResult({
    required this.isValid,
    this.errors = const [],
  });

  String get errorMessage => errors.join('\n');
}

/// Pre-flight validator implementing the exact validation rules from official WhatsApp documentation.
class WhatsAppStickerValidator {
  static const int minStickersPerPack = 3;
  static const int maxStickersPerPack = 30;
  static const int maxStickerFileSizeBytes = 100 * 1024; // 100 KB limit for static stickers
  static const int maxAnimatedStickerFileSizeBytes = 500 * 1024; // 500 KB limit for animated stickers
  static const int maxTrayFileSizeBytes = 50 * 1024; // 50 KB
  static const int stickerDimension = 512;
  static const int trayDimension = 96;

  /// Validate a sticker pack and all its underlying image files before sending to WhatsApp.
  static Future<ValidationResult> validatePack(
    StickerPack pack, {
    required String stickersDirectoryPath,
  }) async {
    final errors = <String>[];

    // 1. Validate Identifier
    if (pack.identifier.trim().isEmpty) {
      errors.add('Identifier paket stiker tidak boleh kosong.');
    } else if (pack.identifier.length > 128) {
      errors.add('Identifier paket stiker melebihi batas maksimal 128 karakter.');
    }

    // 2. Validate Name & Publisher
    if (pack.name.trim().isEmpty) {
      errors.add('Nama paket stiker tidak boleh kosong.');
    } else if (pack.name.length > 128) {
      errors.add('Nama paket stiker melebihi batas maksimal 128 karakter.');
    }

    if (pack.publisher.trim().isEmpty) {
      errors.add('Nama pembuat (publisher) tidak boleh kosong.');
    } else if (pack.publisher.length > 128) {
      errors.add('Nama pembuat melebihi batas maksimal 128 karakter.');
    }

    // 3. Validate Stickers Count (Strict 3..30)
    final count = pack.stickers.length;
    if (count < minStickersPerPack) {
      errors.add(
        'WhatsApp mewajibkan minimal 3 stiker dalam 1 paket (saat ini hanya ada $count stiker).',
      );
    } else if (count > maxStickersPerPack) {
      errors.add(
        'WhatsApp membatasi maksimal 30 stiker dalam 1 paket (saat ini ada $count stiker).',
      );
    }

    final packDir = '$stickersDirectoryPath/${pack.identifier}';

    // 4. Validate Tray Icon
    final trayFile = File('$packDir/${pack.trayImageFile}');
    if (!trayFile.existsSync()) {
      errors.add('Ikon thumbnail (tray icon) paket tidak ditemukan di $packDir.');
    } else {
      final trayLength = trayFile.lengthSync();
      if (trayLength > maxTrayFileSizeBytes) {
        errors.add(
          'Ukuran file tray icon (${(trayLength / 1024).toStringAsFixed(1)} KB) melebihi batas maksimal 50 KB.',
        );
      }
      try {
        final bytes = trayFile.readAsBytesSync();
        final image = img.decodeImage(bytes);
        if (image == null) {
          errors.add('Format file tray icon tidak valid atau rusak.');
        } else if (image.width != trayDimension || image.height != trayDimension) {
          errors.add(
            'Dimensi tray icon harus tepat 96x96 piksel (ditemukan: ${image.width}x${image.height}).',
          );
        }
      } catch (e) {
        errors.add('Gagal memvalidasi file tray icon: $e');
      }
    }

    // 5. Validate Each Sticker
    for (int i = 0; i < pack.stickers.length; i++) {
      final sticker = pack.stickers[i];
      final stickerFile = File('$packDir/${sticker.imageFileName}');

      if (!stickerFile.existsSync()) {
        errors.add(
          'Berkas stiker #${i + 1} (${sticker.imageFileName}) tidak ditemukan di penyimpanan.',
        );
        continue;
      }

      final maxAllowedSize = pack.animatedStickerPack
          ? maxAnimatedStickerFileSizeBytes
          : maxStickerFileSizeBytes;
      final maxAllowedKb = pack.animatedStickerPack ? 500 : 100;

      final fileLength = stickerFile.lengthSync();
      if (fileLength > maxAllowedSize) {
        errors.add(
          'Stiker #${i + 1} (${(fileLength / 1024).toStringAsFixed(1)} KB) melebihi batas maksimal WhatsApp $maxAllowedKb KB.',
        );
      }

      if (sticker.emojis.isEmpty) {
        errors.add('Stiker #${i + 1} wajib memiliki minimal 1 emoji.');
      } else if (sticker.emojis.length > 3) {
        errors.add(
          'Stiker #${i + 1} memiliki ${sticker.emojis.length} emoji (maksimal 3 emoji).',
        );
      }

      try {
        final bytes = stickerFile.readAsBytesSync();
        final image = img.decodeImage(bytes);
        if (image == null) {
          errors.add('Stiker #${i + 1} tidak dapat dibaca atau formatnya rusak.');
        } else if (image.width != stickerDimension || image.height != stickerDimension) {
          errors.add(
            'Dimensi stiker #${i + 1} harus tepat 512x512 piksel (ditemukan: ${image.width}x${image.height}).',
          );
        }
      } catch (e) {
        errors.add('Gagal memeriksa stiker #${i + 1}: $e');
      }
    }

    return ValidationResult(
      isValid: errors.isEmpty,
      errors: errors,
    );
  }
}
