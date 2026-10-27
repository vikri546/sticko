import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';

/// Represents an individual appearance of a duplicate sticker inside a specific pack.
class DuplicateStickerOccurrence {
  final String packIdentifier;
  final String packName;
  final StickerItem sticker;
  final String filePath;
  final int fileSizeBytes;
  final bool isOriginal;

  const DuplicateStickerOccurrence({
    required this.packIdentifier,
    required this.packName,
    required this.sticker,
    required this.filePath,
    required this.fileSizeBytes,
    this.isOriginal = false,
  });

  DuplicateStickerOccurrence copyWith({
    String? packIdentifier,
    String? packName,
    StickerItem? sticker,
    String? filePath,
    int? fileSizeBytes,
    bool? isOriginal,
  }) {
    return DuplicateStickerOccurrence(
      packIdentifier: packIdentifier ?? this.packIdentifier,
      packName: packName ?? this.packName,
      sticker: sticker ?? this.sticker,
      filePath: filePath ?? this.filePath,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      isOriginal: isOriginal ?? this.isOriginal,
    );
  }
}

/// Represents a group of 2 or more stickers that share the identical image format/bytes.
class DuplicateGroup {
  final String hash;
  final Uint8List? previewBytes;
  final int fileSizeBytes;
  final List<DuplicateStickerOccurrence> occurrences;

  const DuplicateGroup({
    required this.hash,
    this.previewBytes,
    required this.fileSizeBytes,
    required this.occurrences,
  });

  /// The number of redundant duplicates beyond the single original/master copy.
  int get duplicateCount => occurrences.length > 1 ? occurrences.length - 1 : 0;

  /// Total copies in this group across all packs.
  int get totalCount => occurrences.length;

  /// Space in bytes that can be recovered if all redundant duplicates are removed.
  int get potentialSavedBytes => fileSizeBytes * duplicateCount;

  /// Formatted size string (e.g., "78.4 KB").
  String get formattedSize => DuplicateStickersService.formatBytes(fileSizeBytes);

  /// Formatted potential savings string.
  String get formattedPotentialSavings =>
      DuplicateStickersService.formatBytes(potentialSavedBytes);
}

/// Service that scans, identifies, groups, and manages duplicate stickers across user packs.
class DuplicateStickersService extends ChangeNotifier {
  static final DuplicateStickersService _instance =
      DuplicateStickersService._internal();
  factory DuplicateStickersService() => _instance;
  DuplicateStickersService._internal();

  List<DuplicateGroup> _duplicateGroups = [];
  bool _isScanning = false;
  DateTime? _lastScanTime;

  List<DuplicateGroup> get duplicateGroups =>
      List.unmodifiable(_duplicateGroups);
  bool get isScanning => _isScanning;
  DateTime? get lastScanTime => _lastScanTime;

  /// Reset state for test isolation.
  @visibleForTesting
  void resetForTesting() {
    _duplicateGroups = [];
    _isScanning = false;
    _lastScanTime = null;
  }

  /// Scans all packs and checks for duplicate stickers with identical format/bytes.
  Future<List<DuplicateGroup>> scanDuplicates({
    StickerPackManager? packManager,
  }) async {
    _isScanning = true;
    notifyListeners();

    try {
      final manager = packManager ?? StickerPackManager();
      final packs = manager.packs;

      final Map<String, List<DuplicateStickerOccurrence>> groupedMap = {};
      final Map<String, Uint8List> previewBytesMap = {};
      final Map<String, int> fileSizesMap = {};

      for (final pack in packs) {
        for (final sticker in pack.stickers) {
          final filePath =
              manager.getStickerFilePath(pack.identifier, sticker.imageFileName);
          if (filePath == null) continue;

          final file = File(filePath);
          if (!file.existsSync()) continue;

          try {
            final bytes = file.readAsBytesSync();
            if (bytes.isEmpty) continue;

            final hash = sha256.convert(bytes).toString();

            previewBytesMap.putIfAbsent(hash, () => bytes);
            fileSizesMap.putIfAbsent(hash, () => bytes.length);

            final occurrence = DuplicateStickerOccurrence(
              packIdentifier: pack.identifier,
              packName: pack.name,
              sticker: sticker,
              filePath: filePath,
              fileSizeBytes: bytes.length,
            );

            groupedMap.putIfAbsent(hash, () => []).add(occurrence);
          } catch (e) {
            debugPrint('Error reading sticker file $filePath: $e');
          }
        }
      }

      // Filter only groups with 2 or more occurrences (actual duplicates)
      final List<DuplicateGroup> results = [];
      for (final entry in groupedMap.entries) {
        if (entry.value.length >= 2) {
          // Designate first occurrence as master/original, others as duplicates
          final markedOccurrences = <DuplicateStickerOccurrence>[];
          for (int i = 0; i < entry.value.length; i++) {
            markedOccurrences.add(
              entry.value[i].copyWith(isOriginal: i == 0),
            );
          }

          results.add(DuplicateGroup(
            hash: entry.key,
            previewBytes: previewBytesMap[entry.key],
            fileSizeBytes: fileSizesMap[entry.key] ?? 0,
            occurrences: markedOccurrences,
          ));
        }
      }

      // Sort so highest space savings come first
      results.sort((a, b) => b.potentialSavedBytes.compareTo(a.potentialSavedBytes));

      _duplicateGroups = results;
      _lastScanTime = DateTime.now();
      return _duplicateGroups;
    } finally {
      _isScanning = false;
      notifyListeners();
    }
  }

  /// Delete a specific duplicate sticker from its pack.
  Future<bool> deleteDuplicate(
    DuplicateStickerOccurrence occurrence, {
    StickerPackManager? packManager,
  }) async {
    final manager = packManager ?? StickerPackManager();
    try {
      await manager.removeStickerFromPack(
        packIdentifier: occurrence.packIdentifier,
        fileName: occurrence.sticker.imageFileName,
      );
      // Automatically refresh duplicate detection
      await scanDuplicates(packManager: manager);
      return true;
    } catch (e) {
      debugPrint('Error deleting duplicate sticker: $e');
      return false;
    }
  }

  /// Replace a specific duplicate sticker in its pack with new image bytes.
  Future<StickerItem?> replaceDuplicate(
    DuplicateStickerOccurrence occurrence,
    Uint8List newImageBytes, {
    StickerPackManager? packManager,
    List<String>? newEmojis,
  }) async {
    final manager = packManager ?? StickerPackManager();
    try {
      final updated = await manager.replaceStickerInPack(
        packIdentifier: occurrence.packIdentifier,
        oldFileName: occurrence.sticker.imageFileName,
        newImageBytes: newImageBytes,
        newEmojis: newEmojis,
      );
      // Automatically refresh duplicate detection
      await scanDuplicates(packManager: manager);
      return updated;
    } catch (e) {
      debugPrint('Error replacing duplicate sticker: $e');
      return null;
    }
  }

  /// Automatically clean redundant duplicates while retaining 1 original copy per group.
  /// If [preserveThreeStickersRule] is true, avoids deleting if it drops a pack below 3 stickers.
  /// Returns the number of duplicates successfully removed.
  Future<int> autoCleanDuplicates({
    bool preserveThreeStickersRule = true,
    StickerPackManager? packManager,
  }) async {
    final manager = packManager ?? StickerPackManager();
    int cleanedCount = 0;

    for (final group in _duplicateGroups) {
      // Keep the first item as original, delete occurrences 1..n
      final redundantItems = group.occurrences.skip(1).toList();
      for (final item in redundantItems) {
        final pack = manager.getPack(item.packIdentifier);
        if (pack == null) continue;

        if (preserveThreeStickersRule && pack.stickers.length <= 3) {
          // Do not violate WhatsApp minimum 3 stickers limit
          continue;
        }

        try {
          await manager.removeStickerFromPack(
            packIdentifier: item.packIdentifier,
            fileName: item.sticker.imageFileName,
          );
          cleanedCount++;
        } catch (e) {
          debugPrint('Error in autoClean for sticker ${item.sticker.imageFileName}: $e');
        }
      }
    }

    await scanDuplicates(packManager: manager);
    return cleanedCount;
  }

  /// Total count of redundant duplicate stickers found.
  int get totalDuplicateCount =>
      _duplicateGroups.fold<int>(0, (sum, g) => sum + g.duplicateCount);

  /// Total potential storage savings in bytes.
  int get totalPotentialSavedBytes =>
      _duplicateGroups.fold<int>(0, (sum, g) => sum + g.potentialSavedBytes);

  /// Helper to format byte counts into human-readable strings.
  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
