import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sticker_flutter/services/creator_profile_service.dart';
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';
import 'package:sticker_flutter/ui/widgets/app_notification.dart';

/// Modern Bottom Sheet Modal to create a new sticker pack.
class CreatePackDialog extends StatefulWidget {
  const CreatePackDialog({super.key});

  /// Displays the create pack modal as a smooth, modern bottom sheet.
  static Future<StickerPack?> show(BuildContext context) {
    return showModalBottomSheet<StickerPack>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withAlpha(150),
      builder: (context) => const CreatePackDialog(),
    );
  }

  @override
  State<CreatePackDialog> createState() => _CreatePackDialogState();
}

class _CreatePackDialogState extends State<CreatePackDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _publisherController;
  bool _isCreating = false;
  bool _animatedStickerPack = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    final creatorName = CreatorProfileService().name.trim();
    _publisherController = TextEditingController(
      text: creatorName.isNotEmpty ? creatorName : 'Sticker Maker',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _publisherController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      AppNotification.show(
        context,
        message: 'Nama paket stiker tidak boleh kosong',
        isSuccess: false,
      );
      return;
    }

    setState(() => _isCreating = true);
    try {
      final newPack = await StickerPackManager().createPack(
        name: name,
        publisher: _publisherController.text.trim().isEmpty
            ? 'Sticker Maker'
            : _publisherController.text.trim(),
        animatedStickerPack: _animatedStickerPack,
      );
      if (mounted) {
        Navigator.of(context).pop<StickerPack>(newPack);
      }
    } catch (e) {
      if (mounted) {
        AppNotification.show(
          context,
          message: 'Gagal membuat paket: $e',
          isSuccess: false,
        );
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Material(
        color: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF182229) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(isDark ? 90 : 40),
                blurRadius: 30,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                color: isDark
                    ? const Color(0xFF131E24).withAlpha(240)
                    : Colors.white.withAlpha(245),
                child: SafeArea(
                  top: false,
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Drag Handle Pill Indicator
                        Center(
                          child: Container(
                            width: 44,
                            height: 4.5,
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.white.withAlpha(50)
                                  : Colors.black.withAlpha(40),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),

                        // Header: Title and Description only (No Icon, No Close Button)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Buat Paket Stiker',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Beri nama paket untuk mengelompokkan stiker Anda.',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 12.5,
                                color: isDark ? Colors.grey[400] : Colors.grey[600],
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 20),

                        // 1. Field: Nama Paket Stiker
                        _buildFieldLabel(
                          label: 'NAMA PAKET STIKER',
                          isRequired: true,
                          isDark: isDark,
                        ),
                        const SizedBox(height: 6),
                        _buildLiquidInputContainer(
                          isDark: isDark,
                          child: TextField(
                            controller: _nameController,
                            autofocus: true,
                            maxLength: 30,
                            textCapitalization: TextCapitalization.words,
                            style: GoogleFonts.plusJakartaSans(
                              color: isDark ? Colors.white : Colors.black87,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              hintText: 'Nama paket stiker',
                              hintStyle: GoogleFonts.plusJakartaSans(
                                color: isDark ? Colors.white38 : Colors.black38,
                                fontSize: 13.5,
                              ),
                              counterStyle: GoogleFonts.plusJakartaSans(
                                color: isDark ? Colors.grey[400] : Colors.grey[600],
                                fontSize: 11,
                              ),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),

                        const SizedBox(height: 18),

                        // 2. Field: Nama Pembuat / Author
                        _buildFieldLabel(
                          label: 'NAMA PEMBUAT / AUTHOR',
                          isRequired: false,
                          isDark: isDark,
                        ),
                        const SizedBox(height: 6),
                        _buildLiquidInputContainer(
                          isDark: isDark,
                          child: TextField(
                            controller: _publisherController,
                            maxLength: 25,
                            style: GoogleFonts.plusJakartaSans(
                              color: isDark ? Colors.white : Colors.black87,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w500,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              hintText: 'Nama Anda atau Studio',
                              hintStyle: GoogleFonts.plusJakartaSans(
                                color: isDark ? Colors.white38 : Colors.black38,
                                fontSize: 13.5,
                              ),
                              counterStyle: GoogleFonts.plusJakartaSans(
                                color: isDark ? Colors.grey[400] : Colors.grey[600],
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 18),

                        // 3. Field: Tipe Paket Stiker (Statis 100KB vs Animasi 500KB)
                        _buildFieldLabel(
                          label: 'TIPE PAKET STIKER (BATAS UKURAN)',
                          isRequired: false,
                          isDark: isDark,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: InkWell(
                                onTap: () => setState(() => _animatedStickerPack = false),
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                                  decoration: BoxDecoration(
                                    color: !_animatedStickerPack
                                        ? const Color(0xFF25D366).withAlpha(isDark ? 50 : 25)
                                        : (isDark ? Colors.white.withAlpha(10) : Colors.black.withAlpha(5)),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: !_animatedStickerPack
                                          ? const Color(0xFF25D366)
                                          : (isDark ? Colors.white12 : Colors.black12),
                                      width: 1.5,
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.image_outlined,
                                            size: 16,
                                            color: !_animatedStickerPack
                                                ? const Color(0xFF25D366)
                                                : (isDark ? Colors.grey[400] : Colors.grey[600]),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            'Statis',
                                            style: GoogleFonts.plusJakartaSans(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 13,
                                              color: !_animatedStickerPack
                                                  ? const Color(0xFF25D366)
                                                  : (isDark ? Colors.white : Colors.black87),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Standar WA (< 100 KB)',
                                        style: GoogleFonts.plusJakartaSans(
                                          fontSize: 11,
                                          color: isDark ? Colors.grey[400] : Colors.grey[600],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: InkWell(
                                onTap: () => setState(() => _animatedStickerPack = true),
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                                  decoration: BoxDecoration(
                                    color: _animatedStickerPack
                                        ? const Color(0xFF25D366).withAlpha(isDark ? 50 : 25)
                                        : (isDark ? Colors.white.withAlpha(10) : Colors.black.withAlpha(5)),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: _animatedStickerPack
                                          ? const Color(0xFF25D366)
                                          : (isDark ? Colors.white12 : Colors.black12),
                                      width: 1.5,
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.motion_photos_on_outlined,
                                            size: 16,
                                            color: _animatedStickerPack
                                                ? const Color(0xFF25D366)
                                                : (isDark ? Colors.grey[400] : Colors.grey[600]),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            'Animasi',
                                            style: GoogleFonts.plusJakartaSans(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 13,
                                              color: _animatedStickerPack
                                                  ? const Color(0xFF25D366)
                                                  : (isDark ? Colors.white : Colors.black87),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Batas Luas (< 500 KB)',
                                        style: GoogleFonts.plusJakartaSans(
                                          fontSize: 11,
                                          color: isDark ? Colors.grey[400] : Colors.grey[600],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 28),

                        // Actions Row: Batal & Buat Paket
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: TextButton(
                                onPressed: _isCreating
                                    ? null
                                    : () => Navigator.of(context).pop(),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                ),
                                child: Text(
                                  'Batal',
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w600,
                                    color: isDark ? Colors.grey[400] : Colors.grey[600],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              flex: 3,
                              child: InkWell(
                                onTap: _isCreating ? null : _submit,
                                borderRadius: BorderRadius.circular(24),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(24),
                                    gradient: const LinearGradient(
                                      colors: [Color(0xFF25D366), Color(0xFF128C7E)],
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF25D366).withAlpha(80),
                                        blurRadius: 14,
                                        offset: const Offset(0, 4),
                                      ),
                                    ],
                                  ),
                                  child: Center(
                                    child: _isCreating
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : Text(
                                            'Buat Paket',
                                            style: GoogleFonts.plusJakartaSans(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 14.5,
                                              color: Colors.white,
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFieldLabel({
    required String label,
    required bool isRequired,
    required bool isDark,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Row(
        children: [
          Text(
            label,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
              color: isDark ? const Color(0xFFCFD8DC) : Colors.black87,
            ),
          ),
          if (isRequired) ...[
            const SizedBox(width: 4),
            const Text(
              '*',
              style: TextStyle(
                color: Color(0xFFF09A06),
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLiquidInputContainer({
    required bool isDark,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withAlpha(15) : Colors.black.withAlpha(8),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? Colors.white.withAlpha(22) : Colors.black.withAlpha(14),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: child,
    );
  }
}
