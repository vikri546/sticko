import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:sticker_flutter/services/sticker_image_processor.dart';
import 'package:sticker_flutter/services/whatsapp_sticker_validator.dart';
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';

/// Central state manager for sticker packs and local collection storage.
class StickerPackManager extends ChangeNotifier {
  static final StickerPackManager _instance = StickerPackManager._internal();
  factory StickerPackManager() => _instance;
  StickerPackManager._internal();

  List<StickerPack> _packs = [];
  bool _isLoading = false;
  String? _stickersDirectory;
  final Map<String, bool> _installedStatus = {};

  bool _isInitialized = false;

  List<StickerPack> get packs => List.unmodifiable(_packs);
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;
  String? get stickersDirectory => _stickersDirectory;

  /// Reset manager state for tests
  @visibleForTesting
  void resetForTesting() {
    _packs = [];
    _installedStatus.clear();
    _isInitialized = false;
    _isLoading = false;
    _stickersDirectory = null;
  }

  /// Check whether a pack is currently installed in WhatsApp.
  bool isPackInstalled(String packIdentifier) =>
      _installedStatus[packIdentifier] ?? false;

  /// Get the absolute file path for a sticker image in a pack.
  String? getStickerFilePath(String packIdentifier, String fileName) {
    if (_stickersDirectory == null) return null;
    return '$_stickersDirectory/$packIdentifier/$fileName';
  }

  /// Get the absolute file path for a pack's tray icon.
  String? getTrayFilePath(String packIdentifier, String trayFileName) {
    if (_stickersDirectory == null) return null;
    return '$_stickersDirectory/$packIdentifier/$trayFileName';
  }

  /// Initialize manager, resolve stickers directory, and load existing packs.
  Future<void> initialize({String? customStickersDir, bool force = false}) async {
    if (_isInitialized && !force) return;
    _isLoading = true;
    notifyListeners();

    try {
      _stickersDirectory = customStickersDir ??
          await WhatsAppStickersService.getStickersDirectory();
      _packs = await WhatsAppStickersService.loadContentsJson(
        directoryPath: _stickersDirectory,
      );
      await refreshInstalledStatuses();
      _isInitialized = true;
    } catch (e) {
      debugPrint('Error initializing StickerPackManager: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Refresh installation status for all packs from WhatsApp.
  Future<void> refreshInstalledStatuses() async {
    for (final pack in _packs) {
      try {
        final isAdded =
            await WhatsAppStickersService.isStickerPackAdded(pack.identifier);
        _installedStatus[pack.identifier] = isAdded;
      } catch (_) {
        _installedStatus[pack.identifier] = false;
      }
    }
    notifyListeners();
  }

  /// Create a new sticker pack.
  Future<StickerPack> createPack({
    required String name,
    String publisher = 'Sticker Maker',
    bool animatedStickerPack = false,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final identifier = 'pack_$timestamp';

    final dirPath = _stickersDirectory ??
        await WhatsAppStickersService.getStickersDirectory();
    final packDir = Directory('$dirPath/$identifier');
    if (!packDir.existsSync()) {
      packDir.createSync(recursive: true);
    }

    final newPack = StickerPack(
      identifier: identifier,
      name: name.trim().isEmpty ? 'Koleksi Stiker Baru' : name.trim(),
      publisher: publisher.trim().isEmpty ? 'Sticker Maker' : publisher.trim(),
      trayImageFile: 'tray.png',
      imageDataVersion: '1',
      animatedStickerPack: animatedStickerPack,
      stickers: const [],
    );

    _packs = [..._packs, newPack];
    await _savePacks();
    notifyListeners();
    return newPack;
  }

  /// Add a sticker from raw image bytes into an existing pack.
  Future<StickerItem> addStickerToPack({
    required String packIdentifier,
    required Uint8List imageBytes,
    List<String> emojis = const ['😀'],
  }) async {
    final packIndex = _packs.indexWhere((p) => p.identifier == packIdentifier);
    if (packIndex == -1) {
      throw Exception('Paket stiker dengan ID $packIdentifier tidak ditemukan.');
    }

    final currentPack = _packs[packIndex];
    if (currentPack.stickers.length >= 30) {
      throw Exception('Paket stiker sudah mencapai batas maksimal 30 stiker.');
    }

    final isAnimated = StickerImageProcessor.isAnimatedMedia(imageBytes);
    bool shouldBeAnimated = currentPack.animatedStickerPack;

    if (isAnimated && currentPack.stickers.isEmpty) {
      shouldBeAnimated = true;
    } else if (isAnimated && !currentPack.animatedStickerPack) {
      throw Exception(
        'WhatsApp tidak mengizinkan mencampur stiker statis dan animasi dalam satu paket. Silakan gunakan atau buat Paket Animasi.',
      );
    } else if (!isAnimated && currentPack.animatedStickerPack) {
      throw Exception(
        'Paket ini adalah Paket Animasi. Stiker yang ditambahkan harus berupa animasi (GIF atau Video).',
      );
    }

    final dirPath = _stickersDirectory ??
        await WhatsAppStickersService.getStickersDirectory();
    final packDirPath = '$dirPath/$packIdentifier';
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final fileName = 'sticker_$timestamp.webp';

    final maxBytes = shouldBeAnimated
        ? WhatsAppStickerValidator.maxAnimatedStickerFileSizeBytes
        : WhatsAppStickerValidator.maxStickerFileSizeBytes;

    // 1. Process image to compliant 512x512 WebP (guaranteed <= maxBytes)
    final processed = await StickerImageProcessor.processToStickerWebp(
      imageBytes,
      maxBytes: maxBytes,
    );
    await StickerImageProcessor.saveStickerFile(
      packDirectoryPath: packDirPath,
      fileName: fileName,
      bytes: processed.webpBytes,
    );

    // 2. Generate tray icon from this sticker if it doesn't exist yet
    final trayFile = File('$packDirPath/tray.png');
    if (!trayFile.existsSync()) {
      final trayBytes =
          await StickerImageProcessor.generateTrayIcon(imageBytes);
      trayFile.writeAsBytesSync(trayBytes);
    }

    // 3. Increment image_data_version for WhatsApp update sync
    final currentVersion = int.tryParse(currentPack.imageDataVersion) ?? 1;
    final newVersion = (currentVersion + 1).toString();

    final newSticker = StickerItem(imageFileName: fileName, emojis: emojis);
    final updatedPack = currentPack.copyWith(
      animatedStickerPack: shouldBeAnimated,
      imageDataVersion: newVersion,
      stickers: [...currentPack.stickers, newSticker],
    );

    _packs[packIndex] = updatedPack;
    await _savePacks();
    notifyListeners();
    return newSticker;
  }

  /// Add an animated sticker directly from a video file path (up to 10s, <= 500 KB).
  Future<StickerItem> addVideoStickerToPack({
    required String packIdentifier,
    required String videoPath,
    List<String> emojis = const ['😀'],
    int maxDurationMs = 10000,
  }) async {
    final packIndex = _packs.indexWhere((p) => p.identifier == packIdentifier);
    if (packIndex == -1) {
      throw Exception('Paket stiker dengan ID $packIdentifier tidak ditemukan.');
    }

    final currentPack = _packs[packIndex];
    if (currentPack.stickers.length >= 30) {
      throw Exception('Paket stiker sudah mencapai batas maksimal 30 stiker.');
    }

    bool shouldBeAnimated = currentPack.animatedStickerPack;
    if (currentPack.stickers.isEmpty) {
      shouldBeAnimated = true;
    } else if (!currentPack.animatedStickerPack) {
      throw Exception(
        'WhatsApp tidak mengizinkan mencampur stiker statis dan stiker animasi dalam satu paket. Silakan gunakan atau buat Paket Animasi.',
      );
    }

    final dirPath = _stickersDirectory ??
        await WhatsAppStickersService.getStickersDirectory();
    final packDirPath = '$dirPath/$packIdentifier';
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final fileName = 'sticker_$timestamp.webp';

    final processed = await StickerImageProcessor.processVideoToStickerWebp(
      videoPath: videoPath,
      maxDurationMs: maxDurationMs,
      maxBytes: WhatsAppStickerValidator.maxAnimatedStickerFileSizeBytes,
    );

    await StickerImageProcessor.saveStickerFile(
      packDirectoryPath: packDirPath,
      fileName: fileName,
      bytes: processed.webpBytes,
    );

    final trayFile = File('$packDirPath/tray.png');
    if (!trayFile.existsSync()) {
      final trayBytes =
          await StickerImageProcessor.generateTrayIcon(processed.webpBytes);
      trayFile.writeAsBytesSync(trayBytes);
    }

    final currentVersion = int.tryParse(currentPack.imageDataVersion) ?? 1;
    final newVersion = (currentVersion + 1).toString();

    final newSticker = StickerItem(imageFileName: fileName, emojis: emojis);
    final updatedPack = currentPack.copyWith(
      animatedStickerPack: shouldBeAnimated,
      imageDataVersion: newVersion,
      stickers: [...currentPack.stickers, newSticker],
    );

    _packs[packIndex] = updatedPack;
    await _savePacks();
    notifyListeners();
    return newSticker;
  }

  /// Add multiple stickers in batch from raw image bytes into an existing pack.
  /// Automatically processes each to compliant 512x512 WebP (< 100 KB or < 500 KB for animated).
  /// Reports progress via optional [onProgress] callback.
  Future<List<StickerItem>> addMultipleStickersToPack({
    required String packIdentifier,
    required List<Uint8List> imagesBytesList,
    List<String> defaultEmojis = const ['😀'],
    void Function(int current, int total)? onProgress,
  }) async {
    final packIndex = _packs.indexWhere((p) => p.identifier == packIdentifier);
    if (packIndex == -1) {
      throw Exception('Paket stiker dengan ID $packIdentifier tidak ditemukan.');
    }

    final currentPack = _packs[packIndex];
    final remainingSlots = 30 - currentPack.stickers.length;
    if (remainingSlots <= 0) {
      throw Exception('Paket stiker sudah mencapai batas maksimal 30 stiker.');
    }

    final toAddBytes = imagesBytesList.take(remainingSlots).toList();
    final dirPath = _stickersDirectory ??
        await WhatsAppStickersService.getStickersDirectory();
    final packDirPath = '$dirPath/$packIdentifier';
    final maxBytes = currentPack.animatedStickerPack
        ? WhatsAppStickerValidator.maxAnimatedStickerFileSizeBytes
        : WhatsAppStickerValidator.maxStickerFileSizeBytes;

    final newStickers = <StickerItem>[];
    final total = toAddBytes.length;

    for (int i = 0; i < total; i++) {
      onProgress?.call(i + 1, total);
      final imageBytes = toAddBytes[i];
      final timestamp = DateTime.now().millisecondsSinceEpoch + i;
      final fileName = 'sticker_$timestamp.webp';

      // 1. Process image to compliant 512x512 WebP (guaranteed <= maxBytes)
      final processed = await StickerImageProcessor.processToStickerWebp(
        imageBytes,
        maxBytes: maxBytes,
      );
      await StickerImageProcessor.saveStickerFile(
        packDirectoryPath: packDirPath,
        fileName: fileName,
        bytes: processed.webpBytes,
      );

      // 2. Generate tray icon from this sticker if it doesn't exist yet
      final trayFile = File('$packDirPath/tray.png');
      if (!trayFile.existsSync()) {
        final trayBytes =
            await StickerImageProcessor.generateTrayIcon(imageBytes);
        trayFile.writeAsBytesSync(trayBytes);
      }

      newStickers.add(StickerItem(
        imageFileName: fileName,
        emojis: defaultEmojis.isNotEmpty ? defaultEmojis : ['😀'],
      ));
    }

    final currentVersion = int.tryParse(currentPack.imageDataVersion) ?? 1;
    final newVersion = (currentVersion + 1).toString();

    final updatedPack = currentPack.copyWith(
      imageDataVersion: newVersion,
      stickers: [...currentPack.stickers, ...newStickers],
    );

    _packs[packIndex] = updatedPack;
    await _savePacks();
    notifyListeners();
    return newStickers;
  }

  /// Remove a sticker from a pack and delete its file.
  Future<void> removeStickerFromPack({
    required String packIdentifier,
    required String fileName,
  }) async {
    final packIndex = _packs.indexWhere((p) => p.identifier == packIdentifier);
    if (packIndex == -1) return;

    final currentPack = _packs[packIndex];
    final dirPath = _stickersDirectory ??
        await WhatsAppStickersService.getStickersDirectory();
    final file = File('$dirPath/$packIdentifier/$fileName');
    if (file.existsSync()) {
      file.deleteSync();
    }

    final currentVersion = int.tryParse(currentPack.imageDataVersion) ?? 1;
    final newVersion = (currentVersion + 1).toString();

    final updatedStickers = currentPack.stickers
        .where((s) => s.imageFileName != fileName)
        .toList();

    _packs[packIndex] = currentPack.copyWith(
      imageDataVersion: newVersion,
      stickers: updatedStickers,
    );

    await _savePacks();
    notifyListeners();
  }

  /// Delete an entire pack and all its associated files.
  Future<void> deletePack(String packIdentifier) async {
    final dirPath = _stickersDirectory ??
        await WhatsAppStickersService.getStickersDirectory();
    final packDir = Directory('$dirPath/$packIdentifier');
    if (packDir.existsSync()) {
      packDir.deleteSync(recursive: true);
    }

    _packs.removeWhere((p) => p.identifier == packIdentifier);
    _installedStatus.remove(packIdentifier);
    await _savePacks();
    notifyListeners();
  }

  /// Automatically inspect and compress any oversized stickers or tray icon in a pack.
  /// Guarantees that all stickers comply with WhatsApp file size limits (< 100 KB for static, < 500 KB for animated).
  /// Returns the number of stickers/tray icons that were optimized.
  Future<int> autoOptimizePackStickers(String packIdentifier) async {
    final pack = getPack(packIdentifier);
    if (pack == null) return 0;

    final dirPath = _stickersDirectory ??
        await WhatsAppStickersService.getStickersDirectory();
    final packDir = '$dirPath/$packIdentifier';
    final maxBytes = pack.animatedStickerPack
        ? WhatsAppStickerValidator.maxAnimatedStickerFileSizeBytes
        : WhatsAppStickerValidator.maxStickerFileSizeBytes;

    int optimizedCount = 0;

    // 1. Check and optimize tray icon if oversized (> 50 KB)
    final trayFile = File('$packDir/${pack.trayImageFile}');
    if (trayFile.existsSync() &&
        trayFile.lengthSync() > WhatsAppStickerValidator.maxTrayFileSizeBytes) {
      try {
        final trayBytes = trayFile.readAsBytesSync();
        final newTray = await StickerImageProcessor.generateTrayIcon(trayBytes);
        trayFile.writeAsBytesSync(newTray);
        optimizedCount++;
      } catch (e) {
        debugPrint('Failed to optimize tray icon: $e');
      }
    }

    // 2. Check and optimize each sticker if exceeding WhatsApp limits
    for (final sticker in pack.stickers) {
      final stickerFile = File('$packDir/${sticker.imageFileName}');
      if (stickerFile.existsSync() && stickerFile.lengthSync() > maxBytes) {
        final success = await StickerImageProcessor.optimizeStickerFile(
          file: stickerFile,
          maxBytes: maxBytes,
        );
        if (success) {
          optimizedCount++;
        }
      }
    }

    if (optimizedCount > 0) {
      final currentVersion = int.tryParse(pack.imageDataVersion) ?? 1;
      final packIndex = _packs.indexWhere((p) => p.identifier == packIdentifier);
      if (packIndex != -1) {
        _packs[packIndex] = pack.copyWith(
          imageDataVersion: (currentVersion + 1).toString(),
        );
        await _savePacks();
        notifyListeners();
      }
    }

    return optimizedCount;
  }

  /// Send or update the pack in WhatsApp.
  /// Automatically optimizes oversized stickers to ensure compliance with WhatsApp limits.
  Future<Map<String, dynamic>> sendPackToWhatsApp(
    String packIdentifier, {
    bool isBusiness = false,
  }) async {
    final pack = getPack(packIdentifier);
    if (pack == null) {
      return {'status': 'error', 'message': 'Paket stiker tidak ditemukan'};
    }

    if (!pack.canAddToWhatsApp) {
      return {
        'status': 'error',
        'message':
            'Syarat minimal 3 stiker belum terpenuhi (kurang ${pack.remainingStickersNeeded} stiker lagi)',
      };
    }

    final dirPath = _stickersDirectory ??
        await WhatsAppStickersService.getStickersDirectory();

    // 1. Auto-optimize any oversized stickers or tray icon before sending
    await autoOptimizePackStickers(pack.identifier);

    final refreshedPack = getPack(packIdentifier) ?? pack;

    // 2. Pre-flight validation against official WhatsApp rules
    final validation = await WhatsAppStickerValidator.validatePack(
      refreshedPack,
      stickersDirectoryPath: dirPath,
    );
    if (!validation.isValid) {
      return {
        'status': 'error',
        'message': validation.errors.first,
      };
    }

    final result = await WhatsAppStickersService.addStickerPack(
      identifier: refreshedPack.identifier,
      name: refreshedPack.name,
      isBusiness: isBusiness,
    );

    if (result['status'] == 'success') {
      _installedStatus[refreshedPack.identifier] = true;
      notifyListeners();
    }

    return result;
  }

  /// Get pack by identifier.
  StickerPack? getPack(String identifier) {
    try {
      return _packs.firstWhere((p) => p.identifier == identifier);
    } catch (_) {
      return null;
    }
  }

  /// Save packs to contents.json.
  Future<void> _savePacks() async {
    await WhatsAppStickersService.saveContentsJson(
      _packs,
      directoryPath: _stickersDirectory,
    );
  }
}
