import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sticker_flutter/services/audio_sticker_bot_service.dart';
import 'package:sticker_flutter/ui/widgets/app_notification.dart';

/// Centralized Option 1 Bottom Sheet:
/// Regular users simply enter their own WhatsApp phone number and tap Send
/// (server connects automatically to the developer's centralized Termux/Cloudflare bot,
/// while still offering an optional server override field for developers).
class AudioBotBridgeSheet extends StatefulWidget {
  final String title;
  final List<AudioStickerBridgeItem>? itemsToSend;

  const AudioBotBridgeSheet({
    super.key,
    this.title = 'Kirim Stiker Audio ke WhatsApp',
    this.itemsToSend,
  });

  static Future<bool?> show(
    BuildContext context, {
    String title = 'Kirim Stiker Audio ke WhatsApp',
    List<AudioStickerBridgeItem>? itemsToSend,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AudioBotBridgeSheet(
        title: title,
        itemsToSend: itemsToSend,
      ),
    );
  }

  @override
  State<AudioBotBridgeSheet> createState() => _AudioBotBridgeSheetState();
}

class _AudioBotBridgeSheetState extends State<AudioBotBridgeSheet> {
  final _service = AudioStickerBotService();
  late final TextEditingController _urlController;
  late final TextEditingController _userPhoneController;
  late final TextEditingController _botPhoneController;
  late final TextEditingController _apiKeyController;

  bool _isChecking = false;
  bool _isSending = false;
  AudioBotBridgeResult? _statusResult;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: _service.bridgeUrl);
    _userPhoneController =
        TextEditingController(text: _service.userWhatsAppNumber);
    _botPhoneController =
        TextEditingController(text: _service.botWhatsAppNumber);
    _apiKeyController = TextEditingController(text: _service.apiKey);
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    await _service.loadConfig();
    if (!mounted) return;
    setState(() {
      if (_urlController.text.isEmpty) {
        _urlController.text = _service.bridgeUrl;
      }
      if (_userPhoneController.text.isEmpty) {
        _userPhoneController.text = _service.userWhatsAppNumber;
      }
      if (_botPhoneController.text.isEmpty) {
        _botPhoneController.text = _service.botWhatsAppNumber;
      }
      if (_apiKeyController.text.isEmpty) {
        _apiKeyController.text = _service.apiKey;
      }
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userPhoneController.dispose();
    _botPhoneController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _persistInputs() async {
    await _service.saveConfig(
      bridgeUrl: _urlController.text,
      userWhatsAppNumber: _userPhoneController.text,
      botWhatsAppNumber: _botPhoneController.text,
      apiKey: _apiKeyController.text,
    );
  }

  Future<void> _checkConnection() async {
    setState(() => _isChecking = true);
    await _persistInputs();
    final res = await _service.checkBridgeStatus(
      bridgeUrlOverride: _urlController.text,
    );
    if (!mounted) return;
    setState(() {
      _isChecking = false;
      _statusResult = res;
      if (res.botNumber != null &&
          res.botNumber!.isNotEmpty &&
          _botPhoneController.text.trim().isEmpty) {
        _botPhoneController.text = res.botNumber!;
      }
    });
  }

  Future<void> _saveOrSend() async {
    final rawUrl = _urlController.text.trim();
    if (rawUrl.isNotEmpty) {
      if (AudioStickerBotService.isWildcardBindHost(rawUrl) ||
          AudioStickerBotService.normalizeBridgeBaseUrl(rawUrl) == null) {
        AppNotification.show(
          context,
          message:
              'URL Server manual tidak valid (jangan gunakan 0.0.0.0, atau kosongkan untuk Server Otomatis Sticko).',
          isSuccess: false,
        );
        return;
      }
    }

    final normalizedPhone =
        AudioStickerBotService.normalizePhoneNumber(_userPhoneController.text);
    if (normalizedPhone == null) {
      AppNotification.show(
        context,
        message: 'Masukkan nomor WhatsApp Anda yang valid (contoh: 08123456789).',
        isSuccess: false,
      );
      return;
    }

    await _persistInputs();

    final items = widget.itemsToSend;
    if (items == null || items.isEmpty) {
      if (!mounted) return;
      Navigator.of(context).pop(true);
      AppNotification.show(
        context,
        message: 'Pengaturan nomor penerima Stiker Audio berhasil disimpan!',
        isSuccess: true,
      );
      return;
    }

    setState(() => _isSending = true);
    final result = await _service.sendItemsViaBridge(items: items);
    if (!mounted) return;
    setState(() => _isSending = false);

    if (result.success) {
      Navigator.of(context).pop(true);
      AppNotification.show(
        context,
        message: result.message,
        isSuccess: true,
      );
    } else {
      AppNotification.show(
        context,
        message: result.message,
        isSuccess: false,
      );
    }
  }

  Future<void> _openChatHandshake() async {
    await _persistInputs();
    final opened = await _service.openBotWhatsAppChat(
      botPhoneOverride: _botPhoneController.text,
    );
    if (!opened && mounted) {
      AppNotification.show(
        context,
        message: 'Ketuk Cek Bot terlebih dahulu atau isi Nomor WA Bot untuk menyapa bot.',
        isSuccess: false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasItems = widget.itemsToSend != null && widget.itemsToSend!.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF131E24) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 14,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.withAlpha(90),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF09A06).withAlpha(35),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.smart_toy_rounded,
                    color: Color(0xFFF09A06),
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 16.5,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      Text(
                        'Cukup masukkan nomor WA Anda — Chatbot resmi Sticko otomatis mengirimkan Stiker Audio ke chat Anda.',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 11.5,
                          color: isDark ? Colors.grey[400] : Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 1. Primary User Field: Target User WhatsApp Number
            Text(
              'NOMOR WHATSAPP PENERIMA (NOMOR ANDA) *',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              key: const Key('bot_target_phone_field'),
              controller: _userPhoneController,
              keyboardType: TextInputType.phone,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : Colors.black87,
              ),
              decoration: _inputDecoration(
                hint: 'Contoh: 081234567890',
                icon: Icons.phone_android_rounded,
                isDark: isDark,
              ),
            ),

            const SizedBox(height: 14),

            // 2. Optional Server URL (auto-resolves to Sticko centralized server when left empty!)
            Text(
              'SERVER BOT (KOSONGKAN = OTOMATIS SERVER STICKO)',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 10.5,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.grey[400] : Colors.grey[700],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('bot_bridge_url_field'),
                    controller: _urlController,
                    keyboardType: TextInputType.url,
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                    decoration: _inputDecoration(
                      hint: 'Otomatis (Server Terpusat Sticko)',
                      icon: Icons.cloud_done_rounded,
                      isDark: isDark,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  key: const Key('bot_check_status_button'),
                  onPressed: (_isChecking || _isSending) ? null : _checkConnection,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF25D366),
                    side: const BorderSide(color: Color(0xFF25D366)),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _isChecking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF25D366),
                          ),
                        )
                      : const Text(
                          'Cek Bot',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
                        ),
                ),
              ],
            ),

            if (_statusResult != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: (_statusResult!.success && _statusResult!.waConnected
                          ? const Color(0xFF25D366)
                          : Colors.orange)
                      .withAlpha(28),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      _statusResult!.success && _statusResult!.waConnected
                          ? Icons.check_circle_rounded
                          : Icons.info_outline_rounded,
                      size: 16,
                      color: _statusResult!.success && _statusResult!.waConnected
                          ? const Color(0xFF25D366)
                          : Colors.orange,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _statusResult!.message,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 18),

            // Primary Action: Send Audio Stickers via Bot (or Save Config)
            FilledButton.icon(
              key: const Key('bot_submit_send_button'),
              onPressed: _isSending ? null : _saveOrSend,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFF09A06),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: _isSending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Colors.black,
                      ),
                    )
                  : Icon(
                      hasItems ? Icons.send_rounded : Icons.save_rounded,
                      size: 19,
                    ),
              label: Text(
                _isSending
                    ? 'Memproses & Mengirim via Bot WA...'
                    : (hasItems
                        ? 'Kirim ${widget.itemsToSend!.length} Stiker Bersuara ke WA Saya'
                        : 'Simpan Pengaturan Nomor WA'),
                style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.bold,
                  fontSize: 13.5,
                ),
              ),
            ),

            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _isSending ? null : _openChatHandshake,
              icon: const Icon(
                Icons.waving_hand_rounded,
                size: 16,
                color: Color(0xFF25D366),
              ),
              label: const Text(
                'Baru Pertama Kali? Sapa Bot di WA Dulu (!ping)',
                style: TextStyle(
                  color: Color(0xFF25D366),
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration({
    required String hint,
    required IconData icon,
    required bool isDark,
  }) {
    return InputDecoration(
      isDense: true,
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 12.5, color: Colors.grey),
      prefixIcon: Icon(icon, size: 18, color: const Color(0xFFF09A06)),
      filled: true,
      fillColor: isDark ? const Color(0xFF1E2B32) : const Color(0xFFF2F4F7),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );
  }
}
