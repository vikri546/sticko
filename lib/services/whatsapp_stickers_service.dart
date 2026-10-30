import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:sticker_flutter/services/google_analytics_service.dart';
import 'package:url_launcher/url_launcher.dart';

/// Model representing a single sticker item in a pack.
class StickerItem {
  final String imageFileName;
  final List<String> emojis;

  const StickerItem({
    required this.imageFileName,
    this.emojis = const ['😀'],
  });

  Map<String, dynamic> toJson() => {
        'image_file': imageFileName,
        'emojis': emojis,
      };

  factory StickerItem.fromJson(Map<String, dynamic> json) {
    return StickerItem(
      imageFileName: json['image_file'] as String,
      emojis: (json['emojis'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          ['😀'],
    );
  }
}

/// Represents a detected WhatsApp clone / duplicate / mod app.
class WhatsAppCloneItem {
  final String packageName;
  final String name;
  final String version;

  const WhatsAppCloneItem({
    required this.packageName,
    required this.name,
    this.version = '',
  });

  Map<String, dynamic> toJson() => {
        'packageName': packageName,
        'name': name,
        'version': version,
      };

  factory WhatsAppCloneItem.fromJson(Map<String, dynamic> json) {
    return WhatsAppCloneItem(
      packageName: json['packageName'] as String? ?? '',
      name: json['name'] as String? ?? 'WhatsApp Duplikat',
      version: json['version'] as String? ?? '',
    );
  }
}

/// Comprehensive status of all detected WhatsApp applications on the device.
class WhatsAppDetailedStatus {
  final bool isWhatsAppInstalled;
  final String whatsAppVersion;
  final bool isBusinessInstalled;
  final String businessVersion;
  final List<WhatsAppCloneItem> clones;

  const WhatsAppDetailedStatus({
    this.isWhatsAppInstalled = false,
    this.whatsAppVersion = '',
    this.isBusinessInstalled = false,
    this.businessVersion = '',
    this.clones = const [],
  });

  bool get hasAnyWhatsAppInstalled =>
      isWhatsAppInstalled || isBusinessInstalled || clones.isNotEmpty;

  int get totalInstalledCount =>
      (isWhatsAppInstalled ? 1 : 0) +
      (isBusinessInstalled ? 1 : 0) +
      clones.length;
}

/// Model representing a WhatsApp sticker pack.
class StickerPack {
  final String identifier;
  final String name;
  final String publisher;
  final String trayImageFile;
  final String imageDataVersion;
  final bool avoidCache;
  final bool animatedStickerPack;
  final List<StickerItem> stickers;

  const StickerPack({
    required this.identifier,
    required this.name,
    this.publisher = 'Sticker Maker',
    this.trayImageFile = 'tray.png',
    this.imageDataVersion = '1',
    this.avoidCache = false,
    this.animatedStickerPack = false,
    this.stickers = const [],
  });

  bool get canAddToWhatsApp => stickers.length >= 3 && stickers.length <= 30;

  int get remainingStickersNeeded =>
      stickers.length < 3 ? 3 - stickers.length : 0;

  StickerPack copyWith({
    String? identifier,
    String? name,
    String? publisher,
    String? trayImageFile,
    String? imageDataVersion,
    bool? avoidCache,
    bool? animatedStickerPack,
    List<StickerItem>? stickers,
  }) {
    return StickerPack(
      identifier: identifier ?? this.identifier,
      name: name ?? this.name,
      publisher: publisher ?? this.publisher,
      trayImageFile: trayImageFile ?? this.trayImageFile,
      imageDataVersion: imageDataVersion ?? this.imageDataVersion,
      avoidCache: avoidCache ?? this.avoidCache,
      animatedStickerPack: animatedStickerPack ?? this.animatedStickerPack,
      stickers: stickers ?? this.stickers,
    );
  }

  Map<String, dynamic> toJson() => {
        'identifier': identifier,
        'name': name,
        'publisher': publisher,
        'tray_image_file': trayImageFile,
        'image_data_version': imageDataVersion,
        'avoid_cache': avoidCache,
        'animated_sticker_pack': animatedStickerPack,
        'stickers': stickers.map((s) => s.toJson()).toList(),
      };

  factory StickerPack.fromJson(Map<String, dynamic> json) {
    return StickerPack(
      identifier: json['identifier'] as String,
      name: json['name'] as String,
      publisher: json['publisher'] as String? ?? 'Sticker Maker',
      trayImageFile: json['tray_image_file'] as String? ?? 'tray.png',
      imageDataVersion: json['image_data_version'] as String? ?? '1',
      avoidCache: json['avoid_cache'] as bool? ?? false,
      animatedStickerPack: json['animated_sticker_pack'] as bool? ?? false,
      stickers: (json['stickers'] as List<dynamic>?)
              ?.map((s) => StickerItem.fromJson(s as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// Service that communicates directly with Android native WhatsApp Sticker Protocol via MethodChannel.
class WhatsAppStickersService {
  static const MethodChannel _channel =
      MethodChannel('com.pkri.sticko/stickers');

  /// Get the directory path where sticker packs and files must be saved.
  static Future<String> getStickersDirectory() async {
    final String? path =
        await _channel.invokeMethod<String>('getStickersDirectory');
    if (path == null) {
      throw Exception('Failed to resolve stickers directory path');
    }
    return path;
  }

  /// Check whether standard WhatsApp and/or WhatsApp Business are installed on the device.
  static Future<Map<String, bool>> checkWhatsAppInstalled() async {
    try {
      final Map<dynamic, dynamic>? result =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('checkWhatsAppInstalled');
      return {
        'whatsapp': result?['whatsapp'] == true,
        'whatsapp_business': result?['whatsapp_business'] == true,
      };
    } catch (_) {
      return {'whatsapp': false, 'whatsapp_business': false};
    }
  }

  /// Check detailed installation status including versions and duplicate/mod clones.
  static Future<WhatsAppDetailedStatus> checkDetailedWhatsAppStatus() async {
    try {
      final Map<dynamic, dynamic>? result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('checkDetailedWhatsAppStatus');

      if (result == null) {
        return const WhatsAppDetailedStatus();
      }

      final rawClones = result['clones'] as List<dynamic>? ?? [];
      final clones = rawClones
          .whereType<Map<dynamic, dynamic>>()
          .map((m) => WhatsAppCloneItem.fromJson(Map<String, dynamic>.from(m)))
          .toList();

      return WhatsAppDetailedStatus(
        isWhatsAppInstalled: result['whatsapp'] == true,
        whatsAppVersion: result['whatsappVersion'] as String? ?? '',
        isBusinessInstalled: result['whatsappBusiness'] == true,
        businessVersion: result['whatsappBusinessVersion'] as String? ?? '',
        clones: clones,
      );
    } catch (_) {
      return const WhatsAppDetailedStatus();
    }
  }

  /// Launch application in Google Play Store for downloading/installing.
  static Future<bool> openPlayStore(String packageName) async {
    try {
      final bool? res = await _channel.invokeMethod<bool>(
        'openPlayStore',
        {'packageName': packageName},
      );
      if (res == true) return true;
    } catch (_) {}

    try {
      final marketUri = Uri.parse('market://details?id=$packageName');
      final webUri =
          Uri.parse('https://play.google.com/store/apps/details?id=$packageName');
      if (await canLaunchUrl(marketUri)) {
        return await launchUrl(marketUri, mode: LaunchMode.externalApplication);
      } else if (await canLaunchUrl(webUri)) {
        return await launchUrl(webUri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
    return false;
  }

  /// Open installed WhatsApp or WhatsApp Business / Clone app.
  static Future<bool> openWhatsAppApp([String packageName = 'com.whatsapp']) async {
    try {
      final bool? res = await _channel.invokeMethod<bool>(
        'openWhatsAppApp',
        {'packageName': packageName},
      );
      if (res == true) return true;
    } catch (_) {}

    try {
      final uri = Uri.parse('whatsapp://');
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
    return false;
  }

  /// Check if a specific sticker pack is already added/whitelisted in WhatsApp.
  static Future<bool> isStickerPackAdded(
    String identifier, {
    bool isBusiness = false,
  }) async {
    final bool? isAdded = await _channel.invokeMethod<bool>(
      'isStickerPackAdded',
      {
        'identifier': identifier,
        'isBusiness': isBusiness,
      },
    );
    return isAdded ?? false;
  }

  /// Launch intent to add the sticker pack to WhatsApp.
  /// Returns a map with 'status' ('success', 'error', 'cancelled') and 'message'.
  static Future<Map<String, dynamic>> addStickerPack({
    required String identifier,
    required String name,
    bool isBusiness = false,
  }) async {
    final Map<dynamic, dynamic>? result =
        await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'addStickerPack',
      {
        'identifier': identifier,
        'name': name,
        'isBusiness': isBusiness,
      },
    );

    final status = result?['status'] ?? 'error';
    final message = result?['message'] ?? 'Unknown error occurred';

    GoogleAnalyticsService().logAddToWhatsApp(
      packId: identifier,
      stickerCount: 0,
      success: status == 'success',
    );

    return {
      'status': status,
      'message': message,
    };
  }

  /// Save or update the `contents.json` metadata file in the stickers directory.
  /// This file is read by [StickerContentProvider] whenever WhatsApp queries the app.
  static Future<void> saveContentsJson(
    List<StickerPack> packs, {
    String? directoryPath,
  }) async {
    final stickersDirPath = directoryPath ?? await getStickersDirectory();
    final file = File('$stickersDirPath/contents.json');
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }

    final data = {
      'android_play_store_link': '',
      'ios_app_store_link': '',
      'sticker_packs': packs.map((p) => p.toJson()).toList(),
    };

    file.writeAsStringSync(jsonEncode(data));
  }

  /// Read the `contents.json` file if it exists, returning the list of saved packs.
  static Future<List<StickerPack>> loadContentsJson({
    String? directoryPath,
  }) async {
    try {
      final stickersDirPath = directoryPath ?? await getStickersDirectory();
      final file = File('$stickersDirPath/contents.json');
      if (!file.existsSync()) {
        return [];
      }
      final content = file.readAsStringSync();
      final data = jsonDecode(content) as Map<String, dynamic>;
      final packsJson = data['sticker_packs'] as List<dynamic>? ?? [];
      return packsJson
          .map((p) => StickerPack.fromJson(p as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Extract video frames natively for animated WhatsApp sticker creation.
  /// Caps duration at [maxDurationMs] (default 10,000ms = 10 seconds).
  static Future<Map<String, dynamic>?> extractVideoFrames({
    required String videoPath,
    int maxDurationMs = 10000,
  }) async {
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'extractVideoFrames',
        {
          'videoPath': videoPath,
          'maxDurationMs': maxDurationMs,
        },
      );
      if (res == null) return null;
      final rawFrames = res['frames'] as List<dynamic>? ?? [];
      final frames = rawFrames.map((f) => f as Uint8List).toList();
      final frameDurationMs = (res['frameDurationMs'] as num?)?.toInt() ?? 100;
      final totalDurationMs = (res['totalDurationMs'] as num?)?.toInt() ?? 0;
      return {
        'frames': frames,
        'frameDurationMs': frameDurationMs,
        'totalDurationMs': totalDurationMs,
      };
    } catch (_) {
      return null;
    }
  }
}
