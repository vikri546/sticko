import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';
import 'package:sticker_flutter/ui/screens/pack_detail_screen.dart';
import 'package:sticker_flutter/ui/widgets/create_pack_dialog.dart';

/// Screen displaying Creator Content split into 3 tabs:
/// 1. Paket (Sticker Packs with 3-image stacked preview and modal layer)
/// 2. Stiker (All individual stickers created)
/// 3. Di WA (Packs synced to WhatsApp, WhatsApp Business, and Clones)
/// Includes directional slide animation, active tab highlight marker,
/// unique empty state information per tab, and floating plus button.
class CreatorCollectionScreen extends StatefulWidget {
  final int initialTabIndex;

  const CreatorCollectionScreen({
    super.key,
    this.initialTabIndex = 0,
  });

  /// Custom PageRoute with Zoom In (enter) and Zoom Out (exit) transition.
  static Route<void> route({int initialTabIndex = 0}) {
    return PageRouteBuilder<void>(
      pageBuilder: (context, animation, secondaryAnimation) =>
          CreatorCollectionScreen(initialTabIndex: initialTabIndex),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curvedAnimation = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return ScaleTransition(
          scale: Tween<double>(begin: 0.84, end: 1.0).animate(curvedAnimation),
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
  State<CreatorCollectionScreen> createState() =>
      _CreatorCollectionScreenState();
}

class _CreatorCollectionScreenState extends State<CreatorCollectionScreen>
    with SingleTickerProviderStateMixin {
  final _manager = StickerPackManager();
  late final TabController _tabController;
  late final PageController _pageController;
  int _currentTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _currentTabIndex = widget.initialTabIndex.clamp(0, 2);
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: _currentTabIndex,
    );
    _pageController = PageController(initialPage: _currentTabIndex);
    _manager.initialize();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onTabTapped(int index) {
    if (index == _currentTabIndex) return;

    setState(() {
      _currentTabIndex = index;
    });
    _tabController.animateTo(index);

    // Directional slide animation using PageController
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeInOutCubic,
    );
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentTabIndex = index;
    });
    _tabController.animateTo(index);
  }

  void _openCreatePackDialog() async {
    final newPack = await CreatePackDialog.show(context);

    if (newPack != null && mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PackDetailScreen(packIdentifier: newPack.identifier),
        ),
      );
    }
  }

  void _showPackStickersModal(StickerPack pack) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.72,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF141E24) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: const [
              BoxShadow(
                color: Colors.black45,
                blurRadius: 20,
                offset: Offset(0, -4),
              ),
            ],
          ),
          child: Column(
            children: [
              const SizedBox(height: 12),
              // Drag Handle
              Container(
                width: 42,
                height: 4.5,
                decoration: BoxDecoration(
                  color: isDark ? Colors.grey[700] : Colors.grey[300],
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(height: 14),

              // Header Info
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            pack.name,
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 19,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${pack.stickers.length} Stiker • Kreator: ${pack.publisher}',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 12.5,
                              color: isDark ? Colors.grey[400] : Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 20),

              // Stickers Grid
              Expanded(
                child: pack.stickers.isEmpty
                    ? Center(
                        child: Text(
                          'Belum ada stiker di paket ini',
                          style: GoogleFonts.plusJakartaSans(
                            color: isDark ? Colors.grey[400] : Colors.grey[600],
                          ),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                          childAspectRatio: 1.0,
                        ),
                        itemCount: pack.stickers.length,
                        itemBuilder: (context, idx) {
                          final sticker = pack.stickers[idx];
                          final filePath = _manager.getStickerFilePath(
                            pack.identifier,
                            sticker.imageFileName,
                          );
                          final file = filePath != null ? File(filePath) : null;

                          return Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () {
                                _showStickerPreviewModal(
                                  sticker: sticker,
                                  pack: pack,
                                  filePath: filePath,
                                );
                              },
                              child: Stack(
                                children: [
                                  Center(
                                    child: Padding(
                                      padding: const EdgeInsets.all(4),
                                      child: file != null && file.existsSync()
                                          ? Image.file(
                                              file,
                                              fit: BoxFit.contain,
                                              errorBuilder: (_, _, _) => const Icon(
                                                Icons.broken_image_rounded,
                                                color: Colors.grey,
                                                size: 24,
                                              ),
                                            )
                                          : const Icon(
                                              Icons.image_outlined,
                                              color: Colors.grey,
                                              size: 24,
                                            ),
                                    ),
                                  ),
                                  if (sticker.emojis.isNotEmpty)
                                    Positioned(
                                      bottom: 3,
                                      right: 4,
                                      child: Text(
                                        sticker.emojis.first,
                                        style: const TextStyle(fontSize: 10),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),

              // Open Detail Action
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 20),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF09A06),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              PackDetailScreen(packIdentifier: pack.identifier),
                        ),
                      );
                    },
                    icon: const Icon(Icons.edit_note_rounded, size: 20),
                    label: Text(
                      'Buka & Kelola Paket',
                      style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showStickerPreviewModal({
    required StickerItem sticker,
    required StickerPack pack,
    required String? filePath,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final file = filePath != null ? File(filePath) : null;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF141E24) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? Colors.grey[700] : Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: 140,
                height: 140,
                child: Center(
                  child: file != null && file.existsSync()
                      ? Image.file(
                          file,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.broken_image_rounded,
                            color: Colors.grey,
                            size: 40,
                          ),
                        )
                      : const Icon(
                          Icons.image_outlined,
                          color: Colors.grey,
                          size: 40,
                        ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Paket: ${pack.name}',
                style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Emoji: ${sticker.emojis.join(' ')}',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 13,
                  color: isDark ? Colors.grey[400] : Colors.grey[600],
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFF09A06),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            PackDetailScreen(packIdentifier: pack.identifier),
                      ),
                    );
                  },
                  child: Text(
                    'Lihat di Paket',
                    style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ListenableBuilder(
      listenable: _manager,
      builder: (context, _) {
        final packs = _manager.packs;
        final totalPacks = packs.length;
        final allStickersCount =
            packs.fold<int>(0, (sum, p) => sum + p.stickers.length);
        final installedCount =
            packs.where((p) => _manager.isPackInstalled(p.identifier)).length;

        return Scaffold(
          extendBodyBehindAppBar: true,
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            elevation: 0,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            centerTitle: true,
            title: Text(
              'Koleksi Kreator',
              style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: Colors.white,
              ),
            ),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          body: Stack(
            fit: StackFit.expand,
            children: [
              Image.asset(
                'lib/images/accountscreen.png',
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
              SafeArea(
                top: true,
                bottom: false,
                child: Column(
                  children: [
                    const SizedBox(height: 8),

                    // TAB BAR SELECTOR WITH ACTIVE MARKER
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _buildTabBarSelector(
                        isDark: isDark,
                        totalPacks: totalPacks,
                        totalStickers: allStickersCount,
                        installedCount: installedCount,
                      ),
                    ),
                    const SizedBox(height: 14),

                    // PAGE VIEW WITH DIRECTIONAL HORIZONTAL SLIDE TRANSITION
                    Expanded(
                      child: PageView(
                        controller: _pageController,
                        physics: const ClampingScrollPhysics(),
                        onPageChanged: _onPageChanged,
                        children: [
                          // TAB 1: PAKET
                          _buildPacksTab(packs, isDark),

                          // TAB 2: STIKER
                          _buildStickersTab(packs, isDark),

                          // TAB 3: DI WA
                          _buildInWaTab(packs, isDark),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
          floatingActionButton: FloatingActionButton(
            key: const Key('creator_collection_fab'),
            onPressed: _openCreatePackDialog,
            backgroundColor: const Color(0xFFF09A06),
            foregroundColor: Colors.black,
            elevation: 5,
            shape: const CircleBorder(),
            tooltip: 'Buat Paket Stiker',
            child: const Icon(Icons.add_rounded, size: 30, color: Colors.black),
          ),
        );
      },
    );
  }

  /// Custom tab bar with liquid glass background and sliding active highlight marker
  Widget _buildTabBarSelector({
    required bool isDark,
    required int totalPacks,
    required int totalStickers,
    required int installedCount,
  }) {
    return _LiquidGlassCard(
      borderRadius: 14,
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          Expanded(
            child: _buildTabPillItem(
              title: 'Paket',
              count: totalPacks,
              index: 0,
              isActive: _currentTabIndex == 0,
            ),
          ),
          Expanded(
            child: _buildTabPillItem(
              title: 'Stiker',
              count: totalStickers,
              index: 1,
              isActive: _currentTabIndex == 1,
            ),
          ),
          Expanded(
            child: _buildTabPillItem(
              title: 'Di WA',
              count: installedCount,
              index: 2,
              isActive: _currentTabIndex == 2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabPillItem({
    required String title,
    required int count,
    required int index,
    required bool isActive,
  }) {
    return InkWell(
      onTap: () => _onTabTapped(index),
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: isActive ? const Color(0xFFF09A06) : Colors.transparent,
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: const Color(0xFFF09A06).withAlpha(100),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              title,
              style: GoogleFonts.plusJakartaSans(
                fontWeight: isActive ? FontWeight.bold : FontWeight.w600,
                fontSize: 13,
                color: isActive ? Colors.black : Colors.white70,
              ),
            ),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: isActive ? Colors.black.withAlpha(30) : Colors.white.withAlpha(25),
              ),
              child: Text(
                '$count',
                style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.bold,
                  fontSize: 10.5,
                  color: isActive ? Colors.black87 : Colors.white70,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // TAB 1: PAKET (Stacked 3-Image Preview)
  // ==========================================
  Widget _buildPacksTab(List<StickerPack> packs, bool isDark) {
    if (packs.isEmpty) {
      return _buildEmptyState(
        icon: Icons.folder_open_rounded,
        title: 'Belum Ada Paket Stiker',
        description:
            'Kamu belum membuat paket stiker. Ketuk tombol \'+\' di bawah untuk mulai membuat paket stiker pertamamu!',
      );
    }

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
      itemCount: packs.length,
      itemBuilder: (context, index) {
        final pack = packs[index];
        final isInstalled = _manager.isPackInstalled(pack.identifier);

        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _LiquidGlassCard(
            borderRadius: 12,
            padding: const EdgeInsets.all(14),
            child: InkWell(
              onTap: () => _showPackStickersModal(pack),
              borderRadius: BorderRadius.circular(12),
              child: Row(
                children: [
                  // STACKED 3-IMAGE PREVIEW FROM LEFT TO RIGHT
                  _buildStacked3ImagesPreview(pack),
                  const SizedBox(width: 14),

                  // Pack Name and Details
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          pack.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.bold,
                            fontSize: 15.5,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${pack.stickers.length} Stiker • ${pack.publisher}',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12,
                            color: isDark ? Colors.grey[300] : Colors.grey[700],
                          ),
                        ),
                        const SizedBox(height: 6),
                        // Status badge
                        if (isInstalled)
                          _buildMiniBadge(
                            icon: Icons.check_circle_rounded,
                            text: 'Di WhatsApp',
                            color: const Color(0xFF25D366),
                          )
                        else if (pack.canAddToWhatsApp)
                          _buildMiniBadge(
                            icon: Icons.verified_rounded,
                            text: 'Siap Ditambah',
                            color: const Color(0xFFF09A06),
                          )
                        else
                          _buildMiniBadge(
                            icon: Icons.info_outline_rounded,
                            text: 'Kurang ${pack.remainingStickersNeeded} lagi',
                            color: Colors.orangeAccent,
                          ),
                      ],
                    ),
                  ),

                  const Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: 14,
                    color: Colors.white54,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Stacked 3 sticker images preview from left to right
  Widget _buildStacked3ImagesPreview(StickerPack pack) {
    final stickers = pack.stickers;

    return SizedBox(
      width: 82,
      height: 54,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          // 3rd Sticker (Right / Back layer)
          if (stickers.length > 2)
            Positioned(
              left: 36,
              child: _buildStackedStickerItem(
                pack: pack,
                sticker: stickers[2],
                size: 42,
              ),
            ),

          // 2nd Sticker (Middle layer)
          if (stickers.length > 1)
            Positioned(
              left: 18,
              child: _buildStackedStickerItem(
                pack: pack,
                sticker: stickers[1],
                size: 46,
              ),
            ),

          // 1st Sticker (Left / Front layer)
          if (stickers.isNotEmpty)
            Positioned(
              left: 0,
              child: _buildStackedStickerItem(
                pack: pack,
                sticker: stickers[0],
                size: 50,
              ),
            )
          else
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(20),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white24),
              ),
              child: const Icon(Icons.image_outlined, color: Colors.white60, size: 24),
            ),
        ],
      ),
    );
  }

  Widget _buildStackedStickerItem({
    required StickerPack pack,
    required StickerItem sticker,
    required double size,
  }) {
    final filePath = _manager.getStickerFilePath(pack.identifier, sticker.imageFileName);
    final file = filePath != null ? File(filePath) : null;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF1E2B32),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withAlpha(60), width: 1.5),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: file != null && file.existsSync()
            ? Image.file(
                file,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.broken_image_rounded,
                  color: Colors.grey,
                  size: 20,
                ),
              )
            : const Icon(
                Icons.image_outlined,
                color: Colors.grey,
                size: 20,
              ),
      ),
    );
  }

  // ==========================================
  // TAB 2: STIKER (All individual stickers)
  // ==========================================
  Widget _buildStickersTab(List<StickerPack> packs, bool isDark) {
    final List<Map<String, dynamic>> allStickers = [];
    for (final pack in packs) {
      for (final sticker in pack.stickers) {
        allStickers.add({
          'sticker': sticker,
          'pack': pack,
          'filePath': _manager.getStickerFilePath(
            pack.identifier,
            sticker.imageFileName,
          ),
        });
      }
    }

    if (allStickers.isEmpty) {
      return _buildEmptyState(
        icon: Icons.auto_awesome_motion_rounded,
        title: 'Koleksi Stiker Masih Kosong',
        description:
            'Belum ada stiker yang ditambahkan. Buat paket baru dan tambahkan stiker foto untuk mengisi galerimu!',
      );
    }

    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 0.95,
      ),
      itemCount: allStickers.length,
      itemBuilder: (context, index) {
        final item = allStickers[index];
        final sticker = item['sticker'] as StickerItem;
        final pack = item['pack'] as StickerPack;
        final filePath = item['filePath'] as String?;
        final file = filePath != null ? File(filePath) : null;

        return _LiquidGlassCard(
          borderRadius: 12,
          padding: const EdgeInsets.all(6),
          child: InkWell(
            onTap: () => _showStickerPreviewModal(
              sticker: sticker,
              pack: pack,
              filePath: filePath,
            ),
            borderRadius: BorderRadius.circular(12),
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Center(
                        child: file != null && file.existsSync()
                            ? Image.file(
                                file,
                                fit: BoxFit.contain,
                                errorBuilder: (_, _, _) => const Icon(
                                  Icons.broken_image_rounded,
                                  color: Colors.grey,
                                  size: 28,
                                ),
                              )
                            : const Icon(
                                Icons.image_outlined,
                                color: Colors.grey,
                                size: 28,
                              ),
                      ),
                      if (sticker.emojis.isNotEmpty)
                        Positioned(
                          top: 2,
                          right: 2,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              sticker.emojis.first,
                              style: const TextStyle(fontSize: 10),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  pack.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ==========================================
  // TAB 3: DI WA (WhatsApp Sync Status)
  // ==========================================
  Widget _buildInWaTab(List<StickerPack> packs, bool isDark) {
    final installedPacks =
        packs.where((p) => _manager.isPackInstalled(p.identifier)).toList();

    if (installedPacks.isEmpty) {
      return _buildEmptyState(
        icon: Icons.mark_chat_read_rounded,
        title: 'Belum Ada Stiker di WhatsApp',
        description:
            'Paket stiker kamu belum diekspor ke WhatsApp. Pastikan paket memiliki minimal 3 stiker lalu ketuk \'Tambah ke WhatsApp\' untuk memunculkannya di chat!',
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
      children: [
        // Section: WhatsApp Messenger (Original)
        _buildSectionHeader('WHATSAPP MESSENGER (ORIGINAL)'),
        const SizedBox(height: 6),
        _LiquidGlassCard(
          borderRadius: 12,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF25D366).withAlpha(40),
                    ),
                    child: const Icon(
                      Icons.chat_bubble_rounded,
                      color: Color(0xFF25D366),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'WhatsApp Messenger',
                          style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.bold,
                            fontSize: 14.5,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          '${installedPacks.length} Paket aktif terpasang',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 11.5,
                            color: const Color(0xFF25D366),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Divider(height: 20),

              // List of packs in format: "Paket Name: 19+"
              ...installedPacks.map((pack) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0xFF25D366),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${pack.name}: ${pack.stickers.length}+',
                          style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      InkWell(
                        onTap: () => _showPackStickersModal(pack),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: const Color(0xFF25D366).withAlpha(30),
                          ),
                          child: Text(
                            'Lihat Stiker',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFF25D366),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
        const SizedBox(height: 18),

        // Section: WhatsApp Business
        _buildSectionHeader('WHATSAPP BUSINESS'),
        const SizedBox(height: 6),
        _LiquidGlassCard(
          borderRadius: 12,
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withAlpha(20),
                ),
                child: const Icon(
                  Icons.business_center_rounded,
                  color: Colors.white70,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'WhatsApp Business',
                      style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Dukungan sinkronisasi otomatis untuk akun bisnis',
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
        ),
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 2),
      child: Text(
        title,
        style: GoogleFonts.plusJakartaSans(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.9,
          color: const Color(0xFFCFD8DC),
        ),
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFFF09A06).withAlpha(30),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 54,
                color: const Color(0xFFF09A06),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12.5,
                color: Colors.grey[300],
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniBadge({
    required IconData icon,
    required String text,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 10.5,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Liquid Glass card with real-time backdrop blur, reflection gradient,
/// and frosted border styling.
class _LiquidGlassCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;

  const _LiquidGlassCard({
    required this.child,
    this.borderRadius = 16,
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
