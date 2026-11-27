import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';
import 'package:url_launcher/url_launcher.dart';

/// Payload item representing a single 512x512 animated WebP paired with its <=10s audio file.
class AudioStickerBridgeItem {
  final Uint8List webpBytes;
  final Uint8List audioBytes;
  final String audioExt;
  final int durationMs;
  final List<String> emojis;

  const AudioStickerBridgeItem({
    required this.webpBytes,
    required this.audioBytes,
    this.audioExt = 'm4a',
    this.durationMs = 5000,
    this.emojis = const ['🔊'],
  });

  Map<String, dynamic> toJson() => {
        'webpBase64': base64Encode(webpBytes),
        'audioBase64': base64Encode(audioBytes),
        'audioExt': audioExt,
        'durationMs': durationMs.clamp(500, 10000),
        'emojis': emojis,
      };
}

/// Result returned when checking or dispatching stickers through the Sticko Audio Bot Bridge.
class AudioBotBridgeResult {
  final bool success;
  final bool waConnected;
  final int sentCount;
  final String message;
  final String? botNumber;

  const AudioBotBridgeResult({
    required this.success,
    this.waConnected = false,
    this.sentCount = 0,
    required this.message,
    this.botNumber,
  });
}

/// Centralized Option 1 Bot Bridge Service:
/// Automatically discovers the developer's centralized Termux/Cloudflare bot URL from
/// `audio_bot_server.json` on GitHub (falling back to `http://127.0.0.1:3100` when Termux runs
/// on the same phone, or an optional manual URL override), so regular users ONLY need to enter
/// their own WhatsApp phone number!
class AudioStickerBotService extends ChangeNotifier {
  static final AudioStickerBotService _instance =
      AudioStickerBotService._internal();
  factory AudioStickerBotService() => _instance;
  AudioStickerBotService._internal();

  static const String defaultRemoteServerConfigUrl =
      'https://raw.githubusercontent.com/vikri546/sticko/main/audio_bot_server.json';
  static const String defaultLocalTermuxUrl = 'http://127.0.0.1:3100';

  String _bridgeUrl = '';
  String _remoteBridgeUrl = '';
  String _userWhatsAppNumber = '';
  String _botWhatsAppNumber = '';
  String _remoteBotWhatsAppNumber = '';
  String _apiKey = '';
  bool _useEnvelope = false;
  bool _isLoaded = false;
  DateTime? _lastRemoteFetchAt;
  String? _customStorageDir;

  @visibleForTesting
  static HttpClient Function()? mockHttpClientFactory;

  String get bridgeUrl => _bridgeUrl;
  String get remoteBridgeUrl => _remoteBridgeUrl;
  String get userWhatsAppNumber => _userWhatsAppNumber;
  String get botWhatsAppNumber =>
      _botWhatsAppNumber.isNotEmpty ? _botWhatsAppNumber : _remoteBotWhatsAppNumber;
  String get apiKey => _apiKey;
  bool get useEnvelope => _useEnvelope;
  bool get isLoaded => _isLoaded;

  /// Option 1: Regular users only need their own WhatsApp number configured;
  /// the server URL resolves automatically (custom override -> GitHub centralized URL -> local Termux).
  bool get isConfigured => normalizePhoneNumber(_userWhatsAppNumber) != null;

  @visibleForTesting
  void resetForTesting({String? customDir}) {
    _bridgeUrl = '';
    _remoteBridgeUrl = '';
    _userWhatsAppNumber = '';
    _botWhatsAppNumber = '';
    _remoteBotWhatsAppNumber = '';
    _apiKey = '';
    _useEnvelope = false;
    _isLoaded = false;
    _lastRemoteFetchAt = null;
    _customStorageDir = customDir;
    mockHttpClientFactory = null;
    notifyListeners();
  }

  /// Normalize Indonesian / international phone input into clean digits (e.g. `0812...` -> `62812...`).
  static String? normalizePhoneNumber(String raw) {
    var digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return null;
    if (digits.startsWith('08')) {
      digits = '62${digits.substring(1)}';
    } else if (digits.startsWith('8')) {
      digits = '62$digits';
    }
    if (digits.length < 8 || digits.length > 16) return null;
    return digits;
  }

  /// Normalize server base URL (auto-prepending `http://` for local LAN IPs if scheme is omitted).
  static String? normalizeBridgeBaseUrl(String raw) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      trimmed = 'http://$trimmed';
    }
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) return null;
    return trimmed;
  }

  /// Check if URL points to `0.0.0.0` (wildcard bind address, invalid as a client target on Android).
  static bool isWildcardBindHost(String raw) {
    final normalized = normalizeBridgeBaseUrl(raw);
    if (normalized == null) return false;
    final host = Uri.tryParse(normalized)?.host.toLowerCase() ?? '';
    return host == '0.0.0.0';
  }

  Future<File> _getConfigFile() async {
    if (_customStorageDir != null) {
      return File('$_customStorageDir/audio_bot_config.json');
    }
    final docDir = await getApplicationDocumentsDirectory();
    return File('${docDir.path}/audio_bot_config.json');
  }

  Future<void> loadConfig({String? customDir}) async {
    if (customDir != null) _customStorageDir = customDir;
    if (_isLoaded && customDir == null) return;
    try {
      final file = await _getConfigFile();
      if (file.existsSync()) {
        final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        _bridgeUrl = (data['bridgeUrl'] as String?)?.trim() ?? '';
        _userWhatsAppNumber =
            (data['userWhatsAppNumber'] as String?)?.trim() ?? '';
        _botWhatsAppNumber =
            (data['botWhatsAppNumber'] as String?)?.trim() ?? '';
        _apiKey = (data['apiKey'] as String?)?.trim() ?? '';
        _useEnvelope = data['useEnvelope'] as bool? ?? false;
      }
    } catch (e) {
      debugPrint('Error loading audio bot config: $e');
    } finally {
      _isLoaded = true;
      notifyListeners();
    }
  }

  Future<void> saveConfig({
    String bridgeUrl = '',
    required String userWhatsAppNumber,
    String botWhatsAppNumber = '',
    String apiKey = '',
    bool useEnvelope = false,
  }) async {
    final trimmedUrl = bridgeUrl.trim();
    _bridgeUrl = trimmedUrl.isEmpty
        ? ''
        : (normalizeBridgeBaseUrl(trimmedUrl) ?? trimmedUrl);
    _userWhatsAppNumber =
        normalizePhoneNumber(userWhatsAppNumber) ?? userWhatsAppNumber.trim();
    _botWhatsAppNumber = botWhatsAppNumber.trim().isEmpty
        ? ''
        : (normalizePhoneNumber(botWhatsAppNumber) ?? botWhatsAppNumber.trim());
    _apiKey = apiKey.trim();
    _useEnvelope = useEnvelope;
    _isLoaded = true;

    try {
      final file = await _getConfigFile();
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      file.writeAsStringSync(
        jsonEncode({
          'bridgeUrl': _bridgeUrl,
          'userWhatsAppNumber': _userWhatsAppNumber,
          'botWhatsAppNumber': _botWhatsAppNumber,
          'apiKey': _apiKey,
          'useEnvelope': _useEnvelope,
        }),
      );
    } catch (e) {
      debugPrint('Error saving audio bot config: $e');
    }
    notifyListeners();
  }

  HttpClient _createClient(HttpClient? customClient) {
    if (customClient != null) return customClient;
    if (mockHttpClientFactory != null) return mockHttpClientFactory!();
    return HttpClient()..connectionTimeout = const Duration(seconds: 8);
  }

  /// Fetch centralized developer bot server config (`audio_bot_server.json`) from GitHub.
  Future<String?> fetchCentralizedBridgeUrl({
    HttpClient? customClient,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh &&
        _remoteBridgeUrl.isNotEmpty &&
        _lastRemoteFetchAt != null &&
        DateTime.now().difference(_lastRemoteFetchAt!) <
            const Duration(minutes: 2)) {
      return _remoteBridgeUrl;
    }

    final client = _createClient(customClient);
    try {
      final cacheBuster = DateTime.now().millisecondsSinceEpoch ~/ 30000;
      final req = await client
          .getUrl(Uri.parse('$defaultRemoteServerConfigUrl?t=$cacheBuster'))
          .timeout(const Duration(seconds: 4));
      final res = await req.close().timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final raw = await utf8.decoder.bind(res).join();
        final data = jsonDecode(raw) as Map<String, dynamic>;
        final url = normalizeBridgeBaseUrl(
          (data['bridge_url'] as String?) ?? '',
        );
        final botNum = normalizePhoneNumber(
          (data['bot_whatsapp_number'] as String?) ?? '',
        );
        _lastRemoteFetchAt = DateTime.now();
        if (botNum != null) {
          _remoteBotWhatsAppNumber = botNum;
        }
        if (url != null) {
          _remoteBridgeUrl = url;
          notifyListeners();
          return url;
        }
      }
    } catch (_) {}
    return _remoteBridgeUrl.isNotEmpty ? _remoteBridgeUrl : null;
  }

  /// Resolve candidate server URLs in priority order:
  /// 1. Explicit manual override (if provided),
  /// 2. Centralized developer server URL from `audio_bot_server.json`,
  /// 3. Local same-phone Termux (`http://127.0.0.1:3100`).
  Future<List<String>> _resolveCandidateUrls({
    String? bridgeUrlOverride,
    HttpClient? customClient,
  }) async {
    final explicitRaw = (bridgeUrlOverride ?? _bridgeUrl).trim();
    if (explicitRaw.isNotEmpty) {
      final single = normalizeBridgeBaseUrl(explicitRaw);
      return single != null ? [single] : const [];
    }

    final candidates = <String>[];
    final remote = await fetchCentralizedBridgeUrl(customClient: customClient);
    if (remote != null && !candidates.contains(remote)) {
      candidates.add(remote);
    }
    if (!candidates.contains(defaultLocalTermuxUrl)) {
      candidates.add(defaultLocalTermuxUrl);
    }
    return candidates;
  }

  /// Check whether the Sticko Audio Bot HTTP server is reachable and connected to WhatsApp.
  Future<AudioBotBridgeResult> checkBridgeStatus({
    String? bridgeUrlOverride,
    HttpClient? customClient,
  }) async {
    await loadConfig();
    final rawUrl = (bridgeUrlOverride ?? _bridgeUrl).trim();
    if (rawUrl.isNotEmpty && isWildcardBindHost(rawUrl)) {
      return const AudioBotBridgeResult(
        success: false,
        message:
            'Jangan gunakan 0.0.0.0! Kosongkan kolom URL untuk Server Otomatis Sticko, atau gunakan http://127.0.0.1:3100 di HP Termux yang sama.',
      );
    }

    final candidates = await _resolveCandidateUrls(
      bridgeUrlOverride: bridgeUrlOverride,
      customClient: customClient,
    );
    if (candidates.isEmpty) {
      return const AudioBotBridgeResult(
        success: false,
        message: 'URL Server Bot tidak valid.',
      );
    }

    final client = _createClient(customClient);
    AudioBotBridgeResult? lastFailure;

    for (final baseUrl in candidates) {
      try {
        final req = await client
            .getUrl(Uri.parse('$baseUrl/api/status'))
            .timeout(const Duration(seconds: 5));
        final res = await req.close().timeout(const Duration(seconds: 5));
        final bodyStr = await utf8.decoder.bind(res).join();
        final data = jsonDecode(bodyStr) as Map<String, dynamic>;
        final connected = data['connected'] == true;
        final botNum = data['botNumber']?.toString();
        if (botNum != null && botNum.isNotEmpty && _remoteBotWhatsAppNumber.isEmpty) {
          _remoteBotWhatsAppNumber = botNum;
        }

        if (res.statusCode == 200 && data['ok'] == true) {
          return AudioBotBridgeResult(
            success: true,
            waConnected: connected,
            botNumber: botNum,
            message: connected
                ? 'Server Bot aktif & terhubung ke WhatsApp${botNum != null ? " ($botNum)" : ""}!'
                : 'Server Bot aktif, tetapi WhatsApp Bot belum login Pairing Code.',
          );
        }
        lastFailure = AudioBotBridgeResult(
          success: false,
          message: data['message']?.toString() ??
              'Server merespons dengan status ${res.statusCode}.',
        );
      } catch (_) {
        lastFailure = AudioBotBridgeResult(
          success: false,
          message:
              'Server Chatbot Sticko sedang offline atau belum dinyalakan di Termux.',
        );
      }
    }

    return lastFailure ??
        const AudioBotBridgeResult(
          success: false,
          message: 'Tidak dapat terhubung ke Server Chatbot Sticko.',
        );
  }

  /// Send one or more prepared WebP+Audio items to the Bot Bridge so the bot delivers
  /// native WhatsApp Sound Stickers straight to [userWhatsAppNumber].
  Future<AudioBotBridgeResult> sendItemsViaBridge({
    required List<AudioStickerBridgeItem> items,
    String? bridgeUrlOverride,
    String? targetPhoneOverride,
    String? apiKeyOverride,
    bool? useEnvelopeOverride,
    HttpClient? customClient,
  }) async {
    await loadConfig();
    final rawUrl = (bridgeUrlOverride ?? _bridgeUrl).trim();
    if (rawUrl.isNotEmpty && isWildcardBindHost(rawUrl)) {
      return const AudioBotBridgeResult(
        success: false,
        message:
            'Jangan gunakan 0.0.0.0! Kosongkan kolom URL untuk Server Otomatis, atau isi http://127.0.0.1:3100 jika Termux jalan di HP ini.',
      );
    }

    final phone = normalizePhoneNumber(targetPhoneOverride ?? _userWhatsAppNumber);
    if (phone == null) {
      return const AudioBotBridgeResult(
        success: false,
        message: 'Nomor WhatsApp penerima tidak valid (contoh: 08123456789).',
      );
    }

    if (items.isEmpty) {
      return const AudioBotBridgeResult(
        success: false,
        message: 'Tidak ada stiker audio untuk dikirim.',
      );
    }

    final candidates = await _resolveCandidateUrls(
      bridgeUrlOverride: bridgeUrlOverride,
      customClient: customClient,
    );
    if (candidates.isEmpty) {
      return const AudioBotBridgeResult(
        success: false,
        message: 'URL Server Bot tidak valid.',
      );
    }

    final effectiveKey = (apiKeyOverride ?? _apiKey).trim();
    final effectiveEnvelope = useEnvelopeOverride ?? _useEnvelope;
    final client = _createClient(customClient);
    AudioBotBridgeResult? lastError;

    for (final baseUrl in candidates) {
      try {
        final req = await client
            .postUrl(Uri.parse('$baseUrl/api/send-audio-sticker'))
            .timeout(const Duration(seconds: 15));
        req.headers.set('Content-Type', 'application/json; charset=utf-8');
        if (effectiveKey.isNotEmpty) {
          req.headers.set('X-Api-Key', effectiveKey);
        }

        final payloadBytes = utf8.encode(
          jsonEncode({
            'targetPhone': phone,
            if (effectiveKey.isNotEmpty) 'apiKey': effectiveKey,
            'envelope': effectiveEnvelope,
            'stickers': items.map((e) => e.toJson()).toList(),
          }),
        );
        req.add(payloadBytes);

        final res = await req.close().timeout(const Duration(seconds: 45));
        final bodyStr = await utf8.decoder.bind(res).join();
        final data = jsonDecode(bodyStr) as Map<String, dynamic>;

        if (res.statusCode == 200 && data['ok'] == true) {
          final count = (data['sentCount'] as num?)?.toInt() ?? items.length;
          final botNum = data['botNumber']?.toString();
          if (botNum != null && botNum.isNotEmpty) {
            _remoteBotWhatsAppNumber = botNum;
          }
          return AudioBotBridgeResult(
            success: true,
            waConnected: true,
            sentCount: count,
            botNumber: botNum,
            message: data['message']?.toString() ??
                '$count stiker audio berhasil dikirim ke WhatsApp ($phone)!',
          );
        }
        return AudioBotBridgeResult(
          success: false,
          message: data['message']?.toString() ??
              'Gagal mengirim stiker audio (HTTP ${res.statusCode}).',
        );
      } catch (_) {
        lastError = const AudioBotBridgeResult(
          success: false,
          message:
              'Server Chatbot Sticko belum terhubung. Pastikan bot Termux aktif atau cek pengaturan server.',
        );
      }
    }

    return lastError ??
        const AudioBotBridgeResult(
          success: false,
          message: 'Gagal menghubungi Server Chatbot Sticko.',
        );
  }

  /// Send a single sticker (from preview or existing file) to WhatsApp via the Audio Bot Bridge.
  Future<AudioBotBridgeResult> sendSingleStickerViaBot({
    required Uint8List webpBytes,
    required String audioFilePath,
    int? durationMs,
    List<String> emojis = const ['🔊'],
    HttpClient? customClient,
  }) async {
    final audioFile = File(audioFilePath);
    if (!audioFile.existsSync()) {
      return const AudioBotBridgeResult(
        success: false,
        message: 'Berkas audio stiker tidak ditemukan.',
      );
    }

    final dotIdx = audioFilePath.lastIndexOf('.');
    final ext = (dotIdx != -1 && dotIdx < audioFilePath.length - 1)
        ? audioFilePath.substring(dotIdx + 1).toLowerCase()
        : 'm4a';

    return sendItemsViaBridge(
      items: [
        AudioStickerBridgeItem(
          webpBytes: webpBytes,
          audioBytes: audioFile.readAsBytesSync(),
          audioExt: ext,
          durationMs: durationMs ?? 5000,
          emojis: emojis,
        ),
      ],
      customClient: customClient,
    );
  }

  /// Send all valid Video+Audio stickers in [pack] to the user's WhatsApp via the Bot Bridge.
  Future<AudioBotBridgeResult> sendPackViaBot(
    StickerPack pack, {
    StickerPackManager? packManager,
    HttpClient? customClient,
  }) async {
    final manager = packManager ?? StickerPackManager();
    final items = <AudioStickerBridgeItem>[];

    for (final sticker in pack.stickers) {
      if (!sticker.hasAudio) continue;
      final webpPath =
          manager.getStickerFilePath(pack.identifier, sticker.imageFileName);
      final audioPath =
          manager.getAudioFilePath(pack.identifier, sticker.audioFileName);
      if (webpPath == null || audioPath == null) continue;

      final webpFile = File(webpPath);
      final audioFile = File(audioPath);
      if (!webpFile.existsSync() || !audioFile.existsSync()) continue;

      final dotIdx = audioPath.lastIndexOf('.');
      final ext = (dotIdx != -1 && dotIdx < audioPath.length - 1)
          ? audioPath.substring(dotIdx + 1).toLowerCase()
          : 'm4a';

      items.add(
        AudioStickerBridgeItem(
          webpBytes: webpFile.readAsBytesSync(),
          audioBytes: audioFile.readAsBytesSync(),
          audioExt: ext,
          durationMs: sticker.durationMs ?? 5000,
          emojis: sticker.emojis,
        ),
      );
    }

    if (items.isEmpty) {
      return const AudioBotBridgeResult(
        success: false,
        message: 'Belum ada stiker bersuara yang valid di paket ini.',
      );
    }

    return sendItemsViaBridge(items: items, customClient: customClient);
  }

  /// Open direct WhatsApp chat to the Chatbot number (anti-spam first greeting `!ping` or `!sa`).
  Future<bool> openBotWhatsAppChat({String? botPhoneOverride}) async {
    await loadConfig();
    if (_remoteBotWhatsAppNumber.isEmpty) {
      await fetchCentralizedBridgeUrl();
    }
    final candidate = (botPhoneOverride != null && botPhoneOverride.trim().isNotEmpty)
        ? botPhoneOverride
        : botWhatsAppNumber;
    final botDigits = normalizePhoneNumber(candidate);
    if (botDigits == null) return false;

    final deepUri = Uri.parse('whatsapp://send?phone=$botDigits&text=!ping');
    final webUri = Uri.parse('https://wa.me/$botDigits?text=!ping');
    try {
      if (await canLaunchUrl(deepUri)) {
        return await launchUrl(deepUri, mode: LaunchMode.externalApplication);
      }
      return await launchUrl(webUri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
