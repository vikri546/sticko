import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sticker_flutter/services/sticker_image_processor.dart';
import 'package:sticker_flutter/services/whatsapp_sticker_validator.dart';
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';

/// Konfigurasi satu paket stiker bawaan (default) dari developer.
///
/// Cara menambah koleksi paket stiker baru di kemudian hari:
/// 1. Buat folder baru di `lib/images/` (misal: `lib/images/template-2/`) berisi 3-30 gambar
///    (atau file `.gif` animasi jika [animatedStickerPack] = `true`).
/// 2. Daftarkan folder tersebut pada `pubspec.yaml` di bagian `flutter -> assets:`.
/// 3. Tambahkan 1 entri [DeveloperStickerPackTemplate] baru ke list [DeveloperStickerPacks.packs].
class DeveloperStickerPackTemplate {
  /// ID unik & stabil untuk WhatsApp ContentProvider (hanya huruf, angka, `_`, `-`, maks 128 karakter).
  final String identifier;

  /// Nama paket stiker yang tampil di Explore, Koleksi Kreator, dan WhatsApp.
  final String name;

  /// Nama pembuat / author paket stiker.
  final String publisher;

  /// Path folder aset Flutter (contoh: `lib/images/template-1`).
  final String assetFolder;

  /// `false` untuk stiker statis (< 100 KB), `true` untuk paket animasi `.gif` (< 500 KB).
  final bool animatedStickerPack;

  /// Emoji bawaan untuk setiap stiker dalam paket ini (1-3 emoji).
  final List<String> defaultEmojis;

  /// Opsional: daftar path aset spesifik bila ingin urutan manual.
  /// Jika `null`, semua berkas gambar valid di [assetFolder] dimuat otomatis (maks 30).
  final List<String>? assetFiles;

  const DeveloperStickerPackTemplate({
    required this.identifier,
    required this.name,
    this.publisher = 'pkri',
    required this.assetFolder,
    this.animatedStickerPack = false,
    this.defaultEmojis = const ['😀'],
    this.assetFiles,
  });
}

/// Registry & seeder lokal untuk koleksi paket stiker bawaan developer.
///
/// Paket bawaan otomatis muncul di halaman Explore, dapat diedit/diurutkan/diekspor ke WhatsApp
/// seperti paket biasa, tetapi paket maupun stiker di dalamnya tidak dapat dihapus.
class DeveloperStickerPacks {
  DeveloperStickerPacks._();

  static const int _maxStickersPerPack = 30;
  static const int _processBatchSize = 4;

  /// Daftar koleksi paket stiker bawaan developer.
  /// Tambahkan entri baru di sini untuk merilis paket stiker lokal baru pada pembaruan aplikasi.
  static const List<DeveloperStickerPackTemplate> packs = [
    DeveloperStickerPackTemplate(
      identifier: 'dev_stiker_kucing_1',
      name: 'Stiker-Kucing-1',
      publisher: 'pkri',
      assetFolder: 'lib/images/template-1',
      animatedStickerPack: false,
      defaultEmojis: ['🐱'],
    ),
  ];

  /// Cek apakah [identifier] termasuk ID paket bawaan developer.
  static bool isDeveloperPackId(String identifier) {
    return packs.any((p) => p.identifier == identifier);
  }

  /// Cek apakah [pack] dilindungi dari penghapusan (paket bawaan developer).
  static bool isProtectedPack(StickerPack pack) {
    return pack.isDeveloperPack || isDeveloperPackId(pack.identifier);
  }

  static bool _isSupportedAsset(String assetPath, {required bool animatedOnly}) {
    final lower = assetPath.toLowerCase();
    if (animatedOnly) {
      return lower.endsWith('.gif');
    }
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp');
  }

  static Future<List<String>> _resolveAssetPaths(
    DeveloperStickerPackTemplate template,
    AssetBundle bundle,
    AssetManifest? manifest,
  ) async {
    if (template.assetFiles != null && template.assetFiles!.isNotEmpty) {
      return template.assetFiles!.take(_maxStickersPerPack).toList();
    }

    if (manifest == null) return const [];

    final prefix = template.assetFolder.endsWith('/')
        ? template.assetFolder
        : '${template.assetFolder}/';

    final matched = manifest
        .listAssets()
        .where((key) {
          if (!key.startsWith(prefix)) return false;
          final relative = key.substring(prefix.length);
          if (relative.isEmpty || relative.contains('/')) return false;
          return _isSupportedAsset(
            relative,
            animatedOnly: template.animatedStickerPack,
          );
        })
        .toList()
      ..sort();

    return matched.take(_maxStickersPerPack).toList();
  }

  static bool _isPackIntactOnDisk(StickerPack pack, String stickersDirectory) {
    if (pack.stickers.isEmpty) return false;
    final packDir = '$stickersDirectory/${pack.identifier}';
    final trayFile = File('$packDir/${pack.trayImageFile}');
    if (!trayFile.existsSync()) return false;
    final firstSticker = File('$packDir/${pack.stickers.first.imageFileName}');
    return firstSticker.existsSync();
  }

  /// Menjamin semua paket bawaan developer sudah tersedia secara lokal dalam format WebP WhatsApp.
  ///
  /// Paket yang sudah ada di [existingPacks] dan utuh di disk tidak akan ditimpa,
  /// sehingga seluruh hasil edit stiker oleh pengguna tetap tersimpan.
  static Future<({List<StickerPack> packs, bool changed})> seedMissingPacks({
    required String stickersDirectory,
    required List<StickerPack> existingPacks,
    List<DeveloperStickerPackTemplate>? templates,
    AssetBundle? bundle,
  }) async {
    final activeTemplates = templates ?? packs;
    if (activeTemplates.isEmpty) {
      return (packs: existingPacks, changed: false);
    }

    final updatedPacks = List<StickerPack>.from(existingPacks);
    bool changed = false;

    // Pastikan flag isDeveloperPack selalu aktif pada paket bawaan yang sudah tersimpan
    for (int i = 0; i < updatedPacks.length; i++) {
      final pack = updatedPacks[i];
      if (!pack.isDeveloperPack && isDeveloperPackId(pack.identifier)) {
        updatedPacks[i] = pack.copyWith(isDeveloperPack: true);
        changed = true;
      }
    }

    // Kumpulkan template yang belum ada atau berkas lokalnya belum terbentuk
    final pendingTemplates = <DeveloperStickerPackTemplate>[];
    for (final template in activeTemplates) {
      final existingIdx =
          updatedPacks.indexWhere((p) => p.identifier == template.identifier);
      if (existingIdx == -1 ||
          !_isPackIntactOnDisk(updatedPacks[existingIdx], stickersDirectory)) {
        pendingTemplates.add(template);
      }
    }

    if (pendingTemplates.isEmpty) {
      return (packs: updatedPacks, changed: changed);
    }

    final activeBundle = bundle ?? rootBundle;
    AssetManifest? manifest;
    try {
      manifest = await AssetManifest.loadFromAssetBundle(activeBundle);
    } catch (e) {
      debugPrint('Failed to load AssetManifest for developer packs: $e');
    }

    for (final template in pendingTemplates) {
      final seededPack = await _buildAndWritePack(
        template: template,
        stickersDirectory: stickersDirectory,
        bundle: activeBundle,
        manifest: manifest,
      );
      if (seededPack == null) continue;

      final existingIdx =
          updatedPacks.indexWhere((p) => p.identifier == template.identifier);
      if (existingIdx >= 0) {
        updatedPacks[existingIdx] = seededPack;
      } else {
        updatedPacks.add(seededPack);
      }
      changed = true;
    }

    return (packs: updatedPacks, changed: changed);
  }

  static Future<StickerPack?> _buildAndWritePack({
    required DeveloperStickerPackTemplate template,
    required String stickersDirectory,
    required AssetBundle bundle,
    required AssetManifest? manifest,
  }) async {
    final assetPaths = await _resolveAssetPaths(template, bundle, manifest);
    if (assetPaths.isEmpty) {
      debugPrint(
        'DeveloperStickerPacks: no assets found in ${template.assetFolder}',
      );
      return null;
    }

    final packDirPath = '$stickersDirectory/${template.identifier}';
    final packDir = Directory(packDirPath);
    if (!packDir.existsSync()) {
      packDir.createSync(recursive: true);
    }

    final maxBytes = template.animatedStickerPack
        ? WhatsAppStickerValidator.maxAnimatedStickerFileSizeBytes
        : WhatsAppStickerValidator.maxStickerFileSizeBytes;

    // Load asset bytes upfront in exact order
    final loadedBytes = <Uint8List>[];
    for (final assetPath in assetPaths) {
      try {
        final data = await bundle.load(assetPath);
        loadedBytes.add(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      } catch (e) {
        debugPrint('DeveloperStickerPacks: failed loading $assetPath: $e');
      }
    }

    if (loadedBytes.isEmpty) return null;

    // Process stickers in small parallel batches for fast first-launch seeding
    final processedList = List<ProcessedStickerResult?>.filled(
      loadedBytes.length,
      null,
    );

    for (int start = 0; start < loadedBytes.length; start += _processBatchSize) {
      final end = (start + _processBatchSize < loadedBytes.length)
          ? start + _processBatchSize
          : loadedBytes.length;
      final futures = <Future<void>>[];
      for (int idx = start; idx < end; idx++) {
        final rawBytes = loadedBytes[idx];
        futures.add(() async {
          try {
            processedList[idx] = template.animatedStickerPack
                ? await StickerImageProcessor.processGifToStickerWebp(
                    gifBytes: rawBytes,
                    maxBytes: maxBytes,
                  )
                : await StickerImageProcessor.processToStickerWebp(
                    rawBytes,
                    maxBytes: maxBytes,
                  );
          } catch (e) {
            debugPrint(
              'DeveloperStickerPacks: failed processing sticker #$idx for ${template.identifier}: $e',
            );
          }
        }());
      }
      await Future.wait(futures);
    }

    final now = DateTime.now();
    final stickers = <StickerItem>[];
    Uint8List? traySourceBytes;

    for (int i = 0; i < processedList.length; i++) {
      final processed = processedList[i];
      if (processed == null) continue;

      final fileIndex = (stickers.length + 1).toString().padLeft(2, '0');
      final fileName = 'dev_sticker_$fileIndex.webp';
      await StickerImageProcessor.saveStickerFile(
        packDirectoryPath: packDirPath,
        fileName: fileName,
        bytes: processed.webpBytes,
      );

      traySourceBytes ??= loadedBytes[i];
      stickers.add(
        StickerItem(
          imageFileName: fileName,
          emojis: template.defaultEmojis.isNotEmpty
              ? template.defaultEmojis
              : const ['😀'],
          createdAt: now,
          updatedAt: now,
        ),
      );
    }

    if (stickers.isEmpty || traySourceBytes == null) return null;

    // Generate 96x96 PNG tray icon (< 50 KB)
    final trayBytes = await StickerImageProcessor.generateTrayIcon(traySourceBytes);
    File('$packDirPath/tray.png').writeAsBytesSync(trayBytes);

    return StickerPack(
      identifier: template.identifier,
      name: template.name,
      publisher: template.publisher,
      trayImageFile: 'tray.png',
      imageDataVersion: '1',
      animatedStickerPack: template.animatedStickerPack,
      isDeveloperPack: true,
      stickers: stickers,
    );
  }
}
