import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sticker_flutter/services/google_analytics_service.dart';
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';

/// Metadata representation of a backup file archive.
class BackupMetadata {
  final String filePath;
  final String fileName;
  final int fileSizeBytes;
  final DateTime createdAt;
  final int packCount;
  final int stickerCount;

  const BackupMetadata({
    required this.filePath,
    required this.fileName,
    required this.fileSizeBytes,
    required this.createdAt,
    required this.packCount,
    required this.stickerCount,
  });

  String get formattedFileSize {
    if (fileSizeBytes < 1024) return '$fileSizeBytes B';
    if (fileSizeBytes < 1024 * 1024) {
      return '${(fileSizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String get formattedDate {
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun',
      'Jul', 'Agt', 'Sep', 'Okt', 'Nov', 'Des'
    ];
    final day = createdAt.day.toString().padLeft(2, '0');
    final month = months[createdAt.month - 1];
    final year = createdAt.year;
    final hour = createdAt.hour.toString().padLeft(2, '0');
    final minute = createdAt.minute.toString().padLeft(2, '0');
    return '$day $month $year, $hour:$minute';
  }
}

/// Result of inspecting a ZIP archive before importing.
class InspectionResult {
  final bool isValid;
  final String? error;
  final List<StickerPack> packs;
  final int totalStickers;
  final List<String> existingConflicts;
  final int fileSizeBytes;
  final DateTime? createdAt;

  const InspectionResult({
    required this.isValid,
    this.error,
    this.packs = const [],
    this.totalStickers = 0,
    this.existingConflicts = const [],
    this.fileSizeBytes = 0,
    this.createdAt,
  });

  String get formattedFileSize {
    if (fileSizeBytes < 1024) return '$fileSizeBytes B';
    if (fileSizeBytes < 1024 * 1024) {
      return '${(fileSizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
}

/// Result of a restore/import operation.
class RestoreResult {
  final bool success;
  final int restoredPacksCount;
  final int restoredStickersCount;
  final String? error;

  const RestoreResult({
    required this.success,
    this.restoredPacksCount = 0,
    this.restoredStickersCount = 0,
    this.error,
  });
}

/// Service handling ZIP export, backup inspection, and import/restore for sticker packs.
class BackupRestoreService {
  static final BackupRestoreService _instance = BackupRestoreService._internal();
  factory BackupRestoreService() => _instance;
  BackupRestoreService._internal();

  /// Directory name for storing local backups.
  static const String backupSubDir = 'sticko_backups';

  String? _customDir;

  /// Reset service state and configure custom directory for testing.
  @visibleForTesting
  void resetForTesting({String? customDir}) {
    _customDir = customDir;
  }

  /// Get the directory path where backup ZIP files are saved.
  Future<String> getBackupsDirectoryPath({String? customDir}) async {
    final effectiveDir = customDir ?? _customDir;
    if (effectiveDir != null) {
      final dir = Directory(effectiveDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      return dir.path;
    }

    final appDocDir = await getApplicationDocumentsDirectory();
    final backupDir = Directory('${appDocDir.path}/$backupSubDir');
    if (!backupDir.existsSync()) {
      backupDir.createSync(recursive: true);
    }
    return backupDir.path;
  }

  /// Export all (or specified) sticker packs into a portable ZIP backup archive.
  Future<BackupMetadata> exportBackupZip({
    String? customBackupDir,
    String? customStickersDir,
    List<String>? selectedPackIdentifiers,
    List<StickerPack>? packsToExport,
  }) async {
    // 1. Resolve packs
    final manager = StickerPackManager();
    final allPacks = packsToExport ?? manager.packs;

    final targetPacks = selectedPackIdentifiers != null
        ? allPacks.where((p) => selectedPackIdentifiers.contains(p.identifier)).toList()
        : allPacks;

    if (targetPacks.isEmpty) {
      throw Exception('Tidak ada paket stiker yang dapat diekspor.');
    }

    // 2. Build manifest
    final now = DateTime.now();
    int totalStickers = 0;
    for (final pack in targetPacks) {
      totalStickers += pack.stickers.length;
    }

    final manifestData = {
      'app': 'Sticko',
      'version': 1,
      'createdAt': now.toIso8601String(),
      'totalPacks': targetPacks.length,
      'totalStickers': totalStickers,
      'packs': targetPacks.map((p) => p.toJson()).toList(),
    };

    final manifestJsonString = const JsonEncoder.withIndent('  ').convert(manifestData);
    final manifestBytes = utf8.encode(manifestJsonString);

    // 3. Create ZIP archive
    final archive = Archive();

    // Add manifest file
    archive.addFile(
      ArchiveFile(
        'backup_manifest.json',
        manifestBytes.length,
        manifestBytes,
      ),
    );

    // Add contents.json for backward compatibility with WhatsApp sticker structure
    final contentsData = {
      'android_play_store_link': '',
      'ios_app_store_link': '',
      'sticker_packs': targetPacks.map((p) => p.toJson()).toList(),
    };
    final contentsJsonString = jsonEncode(contentsData);
    final contentsBytes = utf8.encode(contentsJsonString);
    archive.addFile(
      ArchiveFile('contents.json', contentsBytes.length, contentsBytes),
    );

    // Add each pack's tray and sticker files
    for (final pack in targetPacks) {
      // Tray Icon
      final trayPath = manager.getTrayFilePath(pack.identifier, pack.trayImageFile) ??
          (customStickersDir != null
              ? '$customStickersDir/${pack.identifier}/${pack.trayImageFile}'
              : null);

      if (trayPath != null && File(trayPath).existsSync()) {
        final trayBytes = File(trayPath).readAsBytesSync();
        archive.addFile(
          ArchiveFile(
            '${pack.identifier}/${pack.trayImageFile}',
            trayBytes.length,
            trayBytes,
          ),
        );
      }

      // Sticker Images
      for (final sticker in pack.stickers) {
        final stickerPath = manager.getStickerFilePath(pack.identifier, sticker.imageFileName) ??
            (customStickersDir != null
                ? '$customStickersDir/${pack.identifier}/${sticker.imageFileName}'
                : null);

        if (stickerPath != null && File(stickerPath).existsSync()) {
          final stickerBytes = File(stickerPath).readAsBytesSync();
          archive.addFile(
            ArchiveFile(
              '${pack.identifier}/${sticker.imageFileName}',
              stickerBytes.length,
              stickerBytes,
            ),
          );
        }
      }
    }

    // 4. Encode archive to ZIP
    final zipEncoder = ZipEncoder();
    final zipData = zipEncoder.encode(archive);

    // 5. Save ZIP to backups directory
    final backupsDir = await getBackupsDirectoryPath(customDir: customBackupDir);
    final timestamp = now.millisecondsSinceEpoch;
    final fileName = 'sticko_backup_$timestamp.zip';
    final targetFilePath = '$backupsDir/$fileName';

    final backupFile = File(targetFilePath);
    backupFile.writeAsBytesSync(zipData, flush: true);

    GoogleAnalyticsService().logBackupCreated(
      packCount: targetPacks.length,
      stickerCount: totalStickers,
    );

    return BackupMetadata(
      filePath: targetFilePath,
      fileName: fileName,
      fileSizeBytes: zipData.length,
      createdAt: now,
      packCount: targetPacks.length,
      stickerCount: totalStickers,
    );
  }

  /// List all local backup archives stored in the backups directory.
  Future<List<BackupMetadata>> getLocalBackups({String? customBackupDir}) async {
    final backupsDir = await getBackupsDirectoryPath(customDir: customBackupDir);
    final dir = Directory(backupsDir);
    if (!dir.existsSync()) return [];

    final List<BackupMetadata> results = [];
    final entities = dir.listSync();

    for (final entity in entities) {
      if (entity is File &&
          (entity.path.endsWith('.zip') || entity.path.endsWith('.sticko'))) {
        try {
          final stat = entity.statSync();
          final inspection = await inspectBackupZip(entity.path);

          results.add(
            BackupMetadata(
              filePath: entity.path,
              fileName: entity.uri.pathSegments.isNotEmpty
                  ? entity.uri.pathSegments.last
                  : 'backup.zip',
              fileSizeBytes: stat.size,
              createdAt: inspection.createdAt ?? stat.modified,
              packCount: inspection.packs.length,
              stickerCount: inspection.totalStickers,
            ),
          );
        } catch (e) {
          debugPrint('Error reading backup file ${entity.path}: $e');
        }
      }
    }

    // Sort newest first
    results.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return results;
  }

  /// Delete a backup file.
  Future<bool> deleteBackup(String filePath) async {
    try {
      final file = File(filePath);
      if (file.existsSync()) {
        file.deleteSync();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Error deleting backup file $filePath: $e');
      return false;
    }
  }

  /// Inspect and validate a ZIP archive without modifying user's current stickers.
  Future<InspectionResult> inspectBackupZip(
    String zipFilePath, {
    List<StickerPack>? currentPacks,
  }) async {
    final file = File(zipFilePath);
    if (!file.existsSync()) {
      return const InspectionResult(
        isValid: false,
        error: 'File cadangan tidak ditemukan.',
      );
    }

    final bytes = file.readAsBytesSync();
    if (bytes.isEmpty) {
      return const InspectionResult(
        isValid: false,
        error: 'File cadangan kosong atau rusak.',
      );
    }

    try {
      final archive = ZipDecoder().decodeBytes(bytes);

      // Check for manifest
      ArchiveFile? manifestFile;
      ArchiveFile? contentsFile;

      for (final entry in archive) {
        if (entry.name == 'backup_manifest.json') {
          manifestFile = entry;
          break;
        } else if (entry.name == 'contents.json' || entry.name.endsWith('/contents.json')) {
          contentsFile = entry;
        }
      }

      List<StickerPack> parsedPacks = [];
      DateTime? createdAt;

      if (manifestFile != null) {
        final contentStr = utf8.decode(manifestFile.content as List<int>);
        final json = jsonDecode(contentStr) as Map<String, dynamic>;

        if (json['createdAt'] != null) {
          createdAt = DateTime.tryParse(json['createdAt'] as String);
        }

        final rawPacks = json['packs'] as List<dynamic>? ?? [];
        for (final raw in rawPacks) {
          if (raw is Map<String, dynamic>) {
            parsedPacks.add(StickerPack.fromJson(raw));
          }
        }
      } else if (contentsFile != null) {
        final contentStr = utf8.decode(contentsFile.content as List<int>);
        final json = jsonDecode(contentStr) as Map<String, dynamic>;
        final rawPacks = json['sticker_packs'] as List<dynamic>? ?? [];
        for (final raw in rawPacks) {
          if (raw is Map<String, dynamic>) {
            parsedPacks.add(StickerPack.fromJson(raw));
          }
        }
      } else {
        return const InspectionResult(
          isValid: false,
          error:
              'Format cadangan tidak valid: File backup_manifest.json atau contents.json tidak ditemukan dalam ZIP.',
        );
      }

      if (parsedPacks.isEmpty) {
        return const InspectionResult(
          isValid: false,
          error: 'Tidak ditemukan paket stiker yang valid di dalam file cadangan.',
        );
      }

      int totalStickers = 0;
      for (final pack in parsedPacks) {
        totalStickers += pack.stickers.length;
      }

      // Check conflicts
      final existingPacks = currentPacks ?? StickerPackManager().packs;
      final existingIdentifiers = existingPacks.map((p) => p.identifier).toSet();
      final conflicts = <String>[];

      for (final pack in parsedPacks) {
        if (existingIdentifiers.contains(pack.identifier)) {
          conflicts.add(pack.name);
        }
      }

      return InspectionResult(
        isValid: true,
        packs: parsedPacks,
        totalStickers: totalStickers,
        existingConflicts: conflicts,
        fileSizeBytes: bytes.length,
        createdAt: createdAt ?? file.statSync().modified,
      );
    } catch (e) {
      debugPrint('Error inspecting backup ZIP: $e');
      return InspectionResult(
        isValid: false,
        error: 'Gagal membaca isi file ZIP: Format tidak didukung atau arsip rusak.',
      );
    }
  }

  /// Restore sticker packs from a valid ZIP backup archive.
  Future<RestoreResult> restoreFromZip({
    required String zipFilePath,
    required bool overwriteConflicts,
    String? customStickersDir,
  }) async {
    final inspection = await inspectBackupZip(zipFilePath);
    if (!inspection.isValid || inspection.packs.isEmpty) {
      return RestoreResult(
        success: false,
        error: inspection.error ?? 'File cadangan tidak valid.',
      );
    }

    try {
      final file = File(zipFilePath);
      final bytes = file.readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);

      final manager = StickerPackManager();
      final targetStickersDir = customStickersDir ??
          manager.stickersDirectory ??
          await WhatsAppStickersService.getStickersDirectory();

      // Read current packs
      final currentPacks = List<StickerPack>.from(manager.packs);
      int restoredPacksCount = 0;
      int restoredStickersCount = 0;

      for (final incomingPack in inspection.packs) {
        final existingIndex = currentPacks.indexWhere(
          (p) => p.identifier == incomingPack.identifier,
        );

        StickerPack finalPackToSave = incomingPack;
        String finalIdentifier = incomingPack.identifier;

        if (existingIndex != -1) {
          if (overwriteConflicts) {
            // Overwrite existing pack
            finalPackToSave = incomingPack;
            finalIdentifier = incomingPack.identifier;
          } else {
            // Create a copy / rename
            final uniqueSuffix = DateTime.now().millisecondsSinceEpoch;
            finalIdentifier = '${incomingPack.identifier}_$uniqueSuffix';
            finalPackToSave = incomingPack.copyWith(
              identifier: finalIdentifier,
              name: '${incomingPack.name} (Pulihan)',
            );
          }
        }

        // Create pack directory
        final packDir = Directory('$targetStickersDir/$finalIdentifier');
        if (!packDir.existsSync()) {
          packDir.createSync(recursive: true);
        }

        // Extract files from archive matching this pack
        for (final entry in archive) {
          if (!entry.isFile) continue;

          // Match entry starting with original pack identifier
          final prefix = '${incomingPack.identifier}/';
          if (entry.name.startsWith(prefix)) {
            final relativeName = entry.name.substring(prefix.length);
            if (relativeName.isNotEmpty) {
              final outFile = File('${packDir.path}/$relativeName');
              outFile.parent.createSync(recursive: true);
              outFile.writeAsBytesSync(entry.content as List<int>);
            }
          }
        }

        // Update list
        if (existingIndex != -1 && overwriteConflicts) {
          currentPacks[existingIndex] = finalPackToSave;
        } else {
          currentPacks.add(finalPackToSave);
        }

        restoredPacksCount++;
        restoredStickersCount += finalPackToSave.stickers.length;
      }

      // Save updated contents.json
      await WhatsAppStickersService.saveContentsJson(
        currentPacks,
        directoryPath: targetStickersDir,
      );

      // Refresh manager
      await manager.initialize(
        customStickersDir: targetStickersDir,
        force: true,
      );

      GoogleAnalyticsService().logBackupRestored(
        packCount: restoredPacksCount,
      );

      return RestoreResult(
        success: true,
        restoredPacksCount: restoredPacksCount,
        restoredStickersCount: restoredStickersCount,
      );
    } catch (e) {
      debugPrint('Error restoring from ZIP: $e');
      return RestoreResult(
        success: false,
        error: 'Terjadi kesalahan saat memulihkan file: $e',
      );
    }
  }
}
