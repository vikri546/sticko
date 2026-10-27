import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sticker_flutter/services/duplicate_stickers_service.dart';
import 'package:sticker_flutter/services/sticker_image_processor.dart';
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/ui/widgets/app_notification.dart';

enum _DuplicateViewMode {
  byFormat, // Grouped by identical image format
  oneByOne, // Individual duplicate sticker items
}

/// Screen dedicated to scanning, reviewing, and managing duplicate stickers across packs.
class DuplicateStickersScreen extends StatefulWidget {
  const DuplicateStickersScreen({super.key});

  /// Custom PageRoute with Zoom In (enter) and Zoom Out (exit) transition,
  /// matching PermissionsPreferencesScreen.
  static Route<void> route() {
    return PageRouteBuilder<void>(
      pageBuilder: (context, animation, secondaryAnimation) =>
          const DuplicateStickersScreen(),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curvedAnimation = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return ScaleTransition(
          scale: Tween<double>(begin: 0.82, end: 1.0).animate(curvedAnimation),
          child: FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOut,
              reverseCurve: Curves.easeIn,
            ),
            child: child,
          ),
        );
      },
      transitionDuration: const Duration(milliseconds: 300),
      reverseTransitionDuration: const Duration(milliseconds: 250),
    );
  }

  @override
  State<DuplicateStickersScreen> createState() =>
      _DuplicateStickersScreenState();
}

class _DuplicateStickersScreenState extends State<DuplicateStickersScreen> {
  final DuplicateStickersService _duplicateService = DuplicateStickersService();
  final StickerPackManager _packManager = StickerPackManager();

  _DuplicateViewMode _viewMode = _DuplicateViewMode.byFormat;
  bool _isActionInProgress = false;

  @override
  void initState() {
    super.initState();
    _packManager.addListener(_onPacksChanged);
    _scan();
  }

  @override
  void dispose() {
    _packManager.removeListener(_onPacksChanged);
    super.dispose();
  }

  void _onPacksChanged() {
    if (mounted && !_isActionInProgress) {
      _scan();
    }
  }

  Future<void> _scan() async {
    await _duplicateService.scanDuplicates(packManager: _packManager);
    if (mounted) setState(() {});
  }

  Future<void> _handleDelete(DuplicateStickerOccurrence occurrence) async {
    final pack = _packManager.getPack(occurrence.packIdentifier);
    final isAtRiskOfMinLimit = pack != null && pack.stickers.length <= 3;

    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1E2B32) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
          title: Text(
            'Hapus Stiker Duplikat?',
            style: GoogleFonts.plusJakartaSans(
              fontWeight: FontWeight.bold,
              fontSize: 17,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Stiker ini akan dihapus dari paket "${occurrence.packName}". Stiker asli di paket lain akan tetap tersimpan.',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 13.5,
                  color: isDark ? Colors.grey[300] : Colors.grey[800],
                  height: 1.4,
                ),
              ),
              if (isAtRiskOfMinLimit) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.amber.withAlpha(25),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded,
                          color: Colors.amber, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Paket ini memiliki ${pack.stickers.length} stiker. Menghapus stiker ini akan membuatnya kurang dari syarat minimal 3 stiker WhatsApp. Disarankan memilih opsi "Ganti Stiker".',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12,
                            color: isDark ? Colors.amber[200] : Colors.amber[900],
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          actions: [
            TextButton(
              style: TextButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                foregroundColor: isDark ? Colors.grey[400] : Colors.grey[700],
              ),
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(
                'Batal',
                style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(5),
                ),
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(
                'Hapus',
                style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );

    if (shouldDelete != true || !mounted) return;

    setState(() => _isActionInProgress = true);
    final success = await _duplicateService.deleteDuplicate(
      occurrence,
      packManager: _packManager,
    );
    if (mounted) {
      setState(() => _isActionInProgress = false);
      AppNotification.show(
        context,
        message: success
            ? 'Stiker duplikat berhasil dihapus dari paket ${occurrence.packName}.'
            : 'Gagal menghapus stiker duplikat.',
        isSuccess: success,
      );
    }
  }

  Future<void> _handleReplace(DuplicateStickerOccurrence occurrence) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E2B32) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(5)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ganti Stiker Duplikat',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : const Color(0xFF1E2B32),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Pilih gambar pengganti untuk menggantikan stiker di paket "${occurrence.packName}":',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 13,
                    color: isDark ? Colors.grey[300] : Colors.grey[700],
                  ),
                ),
                const SizedBox(height: 16),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF25D366).withAlpha(30),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: const Icon(Icons.photo_library_rounded,
                        color: Color(0xFF25D366)),
                  ),
                  title: Text(
                    'Pilih dari Galeri Foto',
                    style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : const Color(0xFF1E2B32),
                    ),
                  ),
                  subtitle: Text(
                    'Pilih gambar foto atau grafis baru',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 12,
                      color: isDark ? Colors.grey[400] : Colors.grey[600],
                    ),
                  ),
                  onTap: () => Navigator.of(ctx).pop(ImageSource.gallery),
                ),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF09A06).withAlpha(30),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: const Icon(Icons.camera_alt_rounded,
                        color: Color(0xFFF09A06)),
                  ),
                  title: Text(
                    'Ambil Foto dari Kamera',
                    style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : const Color(0xFF1E2B32),
                    ),
                  ),
                  subtitle: Text(
                    'Ambil foto langsung untuk stiker baru',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 12,
                      color: isDark ? Colors.grey[400] : Colors.grey[600],
                    ),
                  ),
                  onTap: () => Navigator.of(ctx).pop(ImageSource.camera),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (source == null || !mounted) return;

    final picked = await StickerImageProcessor.pickImage(source: source);
    if (picked == null || !mounted) return;

    setState(() => _isActionInProgress = true);
    final bytes = await picked.readAsBytes();

    final updated = await _duplicateService.replaceDuplicate(
      occurrence,
      bytes,
      packManager: _packManager,
    );

    if (mounted) {
      setState(() => _isActionInProgress = false);
      AppNotification.show(
        context,
        message: updated != null
            ? 'Stiker berhasil diganti dengan gambar baru!'
            : 'Gagal mengganti stiker.',
        isSuccess: updated != null,
      );
    }
  }

  Future<void> _handleAutoClean() async {
    final duplicateCount = _duplicateService.totalDuplicateCount;
    if (duplicateCount == 0) return;

    final shouldClean = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1E2B32) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
          title: Text(
            'Bersihkan Semua Duplikat?',
            style: GoogleFonts.plusJakartaSans(
              fontWeight: FontWeight.bold,
              fontSize: 17,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
          content: Text(
            'Sistem akan menyisakan 1 stiker asli di setiap grup dan menghapus stiker kembar di paket lain secara otomatis. Paket yang memiliki 3 stiker akan tetap dipertahankan agar mematuhi syarat WhatsApp.',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 13.5,
              color: isDark ? Colors.grey[300] : Colors.grey[800],
              height: 1.45,
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          actions: [
            TextButton(
              style: TextButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                foregroundColor: isDark ? Colors.grey[400] : Colors.grey[700],
              ),
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(
                'Batal',
                style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF09A06),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(5),
                ),
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(
                'Bersihkan Sekarang',
                style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );

    if (shouldClean != true || !mounted) return;

    setState(() => _isActionInProgress = true);
    final count = await _duplicateService.autoCleanDuplicates(
      preserveThreeStickersRule: true,
      packManager: _packManager,
    );

    if (mounted) {
      setState(() => _isActionInProgress = false);
      AppNotification.show(
        context,
        message: '$count stiker duplikat berhasil dibersihkan!',
        isSuccess: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final groups = _duplicateService.duplicateGroups;
    final isScanning = _duplicateService.isScanning || _isActionInProgress;
    final totalDuplicates = _duplicateService.totalDuplicateCount;
    final totalSavings = _duplicateService.totalPotentialSavedBytes;

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(
          'Pindai Stiker "Duplikat"',
          style: GoogleFonts.plusJakartaSans(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: Colors.white,
            size: 20,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Constant background image matching PermissionsPreferencesScreen
          Image.asset(
            'lib/images/accountscreen.png',
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
          SafeArea(
            top: true,
            bottom: false,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
              children: [
                if (groups.isNotEmpty) ...[
                  // SECTION: RINGKASAN & PEMINDAIAN (Tampil ketika ada duplikat terdeteksi)
                  _buildSectionTitle('RINGKASAN & PEMINDAIAN'),
                  const SizedBox(height: 6),
                  _buildHeroScanCard(
                    isDark: isDark,
                    isScanning: isScanning,
                    groupsCount: groups.length,
                    totalDuplicates: totalDuplicates,
                    totalSavings: totalSavings,
                  ),
                  const SizedBox(height: 20),

                  // SECTION: STIKER DUPLIKAT (Hanya tampil jika ada duplikat terdeteksi)
                  _buildSectionTitle('DAFTAR STIKER TERDETEKSI'),
                  const SizedBox(height: 6),
                  _buildViewModeSelector(isDark: isDark),
                  const SizedBox(height: 14),
                  if (_viewMode == _DuplicateViewMode.byFormat)
                    ...groups.map((group) => _buildGroupCard(isDark, group))
                  else
                    ..._buildIndividualDuplicateCards(isDark, groups),
                  const SizedBox(height: 20),
                ] else
                  // KETIKA TIDAK ADA DUPLIKAT (Tanpa background liquid glass, tanpa background icon)
                  _buildEmptyState(isDark: isDark, isScanning: isScanning),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Text(
        title,
        style: GoogleFonts.plusJakartaSans(
          fontSize: 11.5,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.9,
          color: const Color(0xFFCFD8DC),
        ),
      ),
    );
  }

  /// Hero card with scan button and duplicate statistics
  Widget _buildHeroScanCard({
    required bool isDark,
    required bool isScanning,
    required int groupsCount,
    required int totalDuplicates,
    required int totalSavings,
  }) {
    return _LiquidGlassCard(
      borderRadius: 5,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (totalDuplicates > 0
                          ? const Color(0xFFF09A06)
                          : const Color(0xFF25D366))
                      .withAlpha(35),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Icon(
                  totalDuplicates > 0
                      ? Icons.copy_all_rounded
                      : Icons.verified_rounded,
                  color: totalDuplicates > 0
                      ? const Color(0xFFF09A06)
                      : const Color(0xFF25D366),
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      totalDuplicates > 0
                          ? '$totalDuplicates Stiker Duplikat Ditemukan'
                          : 'Semua Stiker Berformat Unik',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 15.5,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      totalDuplicates > 0
                          ? 'Terdapat stiker dengan format gambar yang sama di berbagai paket.'
                          : 'Pemindaian otomatis & real-time: tidak ada file stiker kembar.',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 12,
                        color: isDark ? Colors.grey[300] : Colors.grey[700],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (totalDuplicates > 0) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0x33FFFFFF),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildStatItem(
                    label: 'Format Gambar',
                    value: '$groupsCount Grup',
                  ),
                  Container(
                    width: 1,
                    height: 28,
                    color: const Color(0x24FFFFFF),
                  ),
                  _buildStatItem(
                    label: 'Stiker Kembar',
                    value: '$totalDuplicates File',
                  ),
                  Container(
                    width: 1,
                    height: 28,
                    color: const Color(0x24FFFFFF),
                  ),
                  _buildStatItem(
                    label: 'Dapat Dihemat',
                    value: DuplicateStickersService.formatBytes(totalSavings),
                    highlight: true,
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          // Hero Action Buttons
          if (totalDuplicates > 0)
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF25D366),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5),
                      ),
                      elevation: 0,
                    ),
                    onPressed: isScanning ? null : _scan,
                    icon: isScanning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation(Colors.white),
                            ),
                          )
                        : const Icon(Icons.refresh_rounded, size: 20),
                    label: Text(
                      isScanning ? 'Memeriksa...' : 'Pindai Lagi',
                      style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.bold,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF09A06),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5),
                      ),
                      elevation: 0,
                    ),
                    onPressed: isScanning ? null : _handleAutoClean,
                    icon: const Icon(Icons.auto_delete_outlined,
                        size: 18, color: Colors.white),
                    label: Text(
                      'Bersihkan Semua',
                      style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ],
            )
          else
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF25D366),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(5),
                  ),
                  elevation: 0,
                ),
                onPressed: isScanning ? null : _scan,
                icon: isScanning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation(Colors.white),
                        ),
                      )
                    : const Icon(Icons.radar_rounded, size: 20),
                label: Text(
                  isScanning
                      ? 'Memeriksa...'
                      : 'Pindai Stiker "Duplikat"',
                  style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.bold,
                    fontSize: 13.5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatItem({
    required String label,
    required String value,
    bool highlight = false,
  }) {
    return Column(
      children: [
        Text(
          value,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: highlight ? const Color(0xFF25D366) : Colors.white,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 11,
            color: const Color(0xFFCFD8DC),
          ),
        ),
      ],
    );
  }

  /// Segmented view switcher: Grouped by format vs One-by-one list
  Widget _buildViewModeSelector({required bool isDark}) {
    return _LiquidGlassCard(
      borderRadius: 5,
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          Expanded(
            child: _buildSelectorTab(
              title: 'Per Format Gambar',
              icon: Icons.grid_view_rounded,
              isSelected: _viewMode == _DuplicateViewMode.byFormat,
              onTap: () =>
                  setState(() => _viewMode = _DuplicateViewMode.byFormat),
            ),
          ),
          Expanded(
            child: _buildSelectorTab(
              title: 'Satu per Satu',
              icon: Icons.view_agenda_rounded,
              isSelected: _viewMode == _DuplicateViewMode.oneByOne,
              onTap: () =>
                  setState(() => _viewMode = _DuplicateViewMode.oneByOne),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectorTab({
    required String title,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF25D366) : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: const Color(0xFF25D366).withAlpha(60),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? Colors.white : Colors.white60,
            ),
            const SizedBox(width: 6),
            Text(
              title,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12.5,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? Colors.white : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Card displaying a group of duplicate stickers with identical format
  Widget _buildGroupCard(bool isDark, DuplicateGroup group) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: _LiquidGlassCard(
        borderRadius: 5,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with thumbnail & summary info
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildStickerThumbnail(group.previewBytes, isDark: isDark),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF09A06).withAlpha(40),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              '${group.occurrences.length} Kembaran',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFFF09A06),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            group.formattedSize,
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 12,
                              color: const Color(0xFFCFD8DC),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'Format Gambar Sama',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        'Ditemukan di ${group.occurrences.length} paket stiker.',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 12,
                          color: isDark ? Colors.grey[300] : Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Divider(
              height: 1,
              color: isDark ? const Color(0x24FFFFFF) : const Color(0x1F000000),
            ),
            const SizedBox(height: 10),
            // List of pack occurrences
            Text(
              'Lokasi di Paket Stiker:',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: const Color(0xFFCFD8DC),
              ),
            ),
            const SizedBox(height: 6),
            ...group.occurrences.map((item) => _buildOccurrenceRow(isDark, item)),
          ],
        ),
      ),
    );
  }

  /// Occurrence row inside a group
  Widget _buildOccurrenceRow(bool isDark, DuplicateStickerOccurrence item) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0x33000000) : const Color(0x1F000000),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        children: [
          Icon(
            item.isOriginal
                ? Icons.check_circle_rounded
                : Icons.content_copy_rounded,
            size: 16,
            color: item.isOriginal
                ? const Color(0xFF25D366)
                : const Color(0xFFCFD8DC),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.packName,
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (item.isOriginal)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: const Color(0xFF25D366).withAlpha(40),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          'Asli',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF25D366),
                          ),
                        ),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF09A06).withAlpha(40),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          'Duplikat',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFFF09A06),
                          ),
                        ),
                      ),
                  ],
                ),
                Text(
                  item.sticker.imageFileName,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 11,
                    color: const Color(0xFFB0BEC5),
                  ),
                ),
              ],
            ),
          ),
          // Action Buttons: Ganti & Hapus
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Ganti dengan stiker lain',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.find_replace_rounded, size: 20),
                color: const Color(0xFF25D366),
                onPressed: () => _handleReplace(item),
              ),
              IconButton(
                tooltip: 'Hapus duplikat dari paket ini',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                color: Colors.redAccent,
                onPressed: () => _handleDelete(item),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Individual duplicate cards (one by one view)
  List<Widget> _buildIndividualDuplicateCards(
      bool isDark, List<DuplicateGroup> groups) {
    final widgets = <Widget>[];

    for (final group in groups) {
      // Show each occurrence
      for (final item in group.occurrences) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _LiquidGlassCard(
              borderRadius: 5,
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  _buildStickerThumbnail(group.previewBytes, isDark: isDark),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: item.isOriginal
                                    ? const Color(0xFF25D366).withAlpha(40)
                                    : const Color(0xFFF09A06).withAlpha(40),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                item.isOriginal ? 'Stiker Asli' : 'Stiker Duplikat',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.bold,
                                  color: item.isOriginal
                                      ? const Color(0xFF25D366)
                                      : const Color(0xFFF09A06),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              group.formattedSize,
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 11,
                                color: const Color(0xFFCFD8DC),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.packName,
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          item.sticker.imageFileName,
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 11,
                            color: const Color(0xFFB0BEC5),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Actions
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          visualDensity: VisualDensity.compact,
                          foregroundColor: const Color(0xFF25D366),
                        ),
                        onPressed: () => _handleReplace(item),
                        icon: const Icon(Icons.find_replace_rounded, size: 16),
                        label: Text(
                          'Ganti',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          visualDensity: VisualDensity.compact,
                          foregroundColor: Colors.redAccent,
                        ),
                        onPressed: () => _handleDelete(item),
                        icon: const Icon(Icons.delete_outline_rounded, size: 16),
                        label: Text(
                          'Hapus',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      }
    }

    return widgets;
  }

  /// Transparent checkerboard sticker preview container (no border, radius 5)
  Widget _buildStickerThumbnail(Uint8List? bytes, {required bool isDark}) {
    const size = 64.0;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Soft checkerboard background for clean transparency
            CustomPaint(
              painter: _CheckerboardPainter(
                color1: isDark
                    ? const Color(0xFF1F2C34)
                    : const Color(0xFFEEEEEE),
                color2: isDark
                    ? const Color(0xFF121B22)
                    : const Color(0xFFF7F8FA),
              ),
            ),
            if (bytes != null && bytes.isNotEmpty)
              Image.memory(
                bytes,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                errorBuilder: (context, error, stackTrace) => const Center(
                  child: Icon(Icons.broken_image_rounded, size: 24),
                ),
              )
            else
              const Center(
                child: Icon(Icons.image_outlined, size: 24, color: Colors.grey),
              ),
          ],
        ),
      ),
    );
  }

  /// Empty state when no duplicates are detected (No background, no icon background)
  Widget _buildEmptyState({required bool isDark, required bool isScanning}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.check_circle_rounded,
            size: 64,
            color: Color(0xFF25D366),
          ),
          const SizedBox(height: 18),
          Text(
            'Tidak Ada Stiker Duplikat!',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 17.5,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Text(
            'Semua stiker di setiap paket Anda unik dan tidak memiliki format kembar. Penyimpanan dan paket stiker Anda bersih optimal.',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 13,
              color: isDark ? Colors.grey[300] : Colors.grey[700],
              height: 1.45,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF25D366),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(5),
              ),
              elevation: 0,
            ),
            onPressed: isScanning ? null : _scan,
            icon: isScanning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                : const Icon(Icons.refresh_rounded, size: 18),
            label: Text(
              isScanning ? 'Memeriksa...' : 'Pindai Ulang',
              style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Liquid Glass card with real-time backdrop blur, reflection gradient,
/// and soft ambient drop shadow without borders, matching PermissionsPreferencesScreen.
class _LiquidGlassCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;

  const _LiquidGlassCard({
    required this.child,
    this.borderRadius = 5.0,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(borderRadius);

    return Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(isDark ? 80 : 25),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
          BoxShadow(
            color: const Color(0xFFF09A06).withAlpha(isDark ? 10 : 6),
            blurRadius: 16,
            offset: const Offset(0, 0),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? const [
                        Color(0x28FFFFFF),
                        Color(0x751E2B32),
                        Color(0xB0111B21),
                      ]
                    : const [
                        Color(0xD9FFFFFF),
                        Color(0xB3FFFFFF),
                        Color(0x80F4F6F8),
                      ],
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _CheckerboardPainter extends CustomPainter {
  final Color color1;
  final Color color2;
  static const double cellSize = 8.0;

  _CheckerboardPainter({
    required this.color1,
    required this.color2,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint1 = Paint()..color = color1;
    final paint2 = Paint()..color = color2;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint2);

    for (double y = 0; y < size.height; y += cellSize) {
      for (double x = 0; x < size.width; x += cellSize) {
        if (((x / cellSize).floor() + (y / cellSize).floor()) % 2 == 0) {
          canvas.drawRect(Rect.fromLTWH(x, y, cellSize, cellSize), paint1);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
