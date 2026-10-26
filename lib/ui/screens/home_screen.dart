import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';
import 'package:sticker_flutter/ui/screens/account_screen.dart';
import 'package:sticker_flutter/ui/screens/pack_detail_screen.dart';
import 'package:sticker_flutter/ui/widgets/create_pack_dialog.dart';
import 'package:sticker_flutter/ui/widgets/floating_pill_nav_bar.dart';

/// Main Home Screen displaying the list of sticker packs.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _manager = StickerPackManager();
  late final PageController _pageController;
  int _currentTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _currentTabIndex);
    _manager.initialize();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _manager,
      builder: (context, _) {
        final packs = _manager.packs;

        return Scaffold(
          extendBody: true,
          extendBodyBehindAppBar: true,
          backgroundColor: Colors.transparent,
          body: PageView(
            controller: _pageController,
            physics: const ClampingScrollPhysics(),
            onPageChanged: (index) {
              setState(() {
                _currentTabIndex = index;
              });
            },
            children: [
              Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(
                    'lib/images/homescreen.png',
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                  SafeArea(
                    top: true,
                    bottom: false,
                    child: Column(
                      children: [
                        AppBar(
                          elevation: 0,
                          backgroundColor: Colors.transparent,
                          surfaceTintColor: Colors.transparent,
                          centerTitle: true,
                          title: Text(
                            'Sticko',
                            style: GoogleFonts.alexBrush(
                              fontSize: 42,
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFFF09A06),
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        Expanded(
                          child: _manager.isLoading
                              ? const Center(child: CircularProgressIndicator())
                              : packs.isEmpty
                                  ? _buildEmptyState()
                                  : _buildPacksList(packs),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const AccountScreen(showAppBar: true),
            ],
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FloatingPillNavBar(
                    selectedIndex: _currentTabIndex,
                    onTabSelected: (index) {
                      if (_currentTabIndex != index) {
                        setState(() {
                          _currentTabIndex = index;
                        });
                        _pageController.animateToPage(
                          index,
                          duration: const Duration(milliseconds: 320),
                          curve: Curves.easeInOutCubic,
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
          floatingActionButton: _currentTabIndex == 0
              ? FloatingActionButton(
                  key: const Key('add_pack_fab'),
                  onPressed: _openCreatePackDialog,
                  backgroundColor: const Color(0xFFF09A06),
                  foregroundColor: Colors.black,
                  elevation: 4,
                  shape: const CircleBorder(),
                  tooltip: 'Buat Paket Stiker',
                  child: const Icon(Icons.add_rounded, size: 30, color: Colors.black),
                )
              : null,
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: const Color(0xFFF09A06).withAlpha(25),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.add_photo_alternate_rounded,
                size: 72,
                color: Color(0xFFF09A06),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Belum Ada Paket Stiker',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Buat stiker pertama Anda dari galeri foto pribadi, beri nama, dan kirimkan langsung ke keyboard WhatsApp Anda.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white70,
                fontSize: 14,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 28),
            TextButton.icon(
              onPressed: _openCreatePackDialog,
              style: TextButton.styleFrom(
                backgroundColor: Colors.transparent,
                foregroundColor: const Color(0xFFF09A06),
                elevation: 0,
                shadowColor: Colors.transparent,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.zero,
                ),
              ),
              icon: const Icon(Icons.add_rounded, color: Color(0xFFF09A06)),
              label: const Text(
                'Buat Paket Stiker Sekarang',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFF09A06),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPacksList(List<StickerPack> packs) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 160),
      itemCount: packs.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final pack = packs[index];
        final isInstalled = _manager.isPackInstalled(pack.identifier);
        final canAdd = pack.canAddToWhatsApp;
        final totalStickers = pack.stickers.length;

        // Try getting the tray icon or first sticker file
        final trayPath = _manager.getTrayFilePath(pack.identifier, pack.trayImageFile);
        final trayFile = trayPath != null ? File(trayPath) : null;
        final hasTray = trayFile != null && trayFile.existsSync();

        return _LiquidGlassCard(
          borderRadius: 5.0,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(5.0),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PackDetailScreen(packIdentifier: pack.identifier),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(14.0),
                child: Row(
                  children: [
                    // Tray Icon / Thumbnail
                    Container(
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        color: const Color(0xFF25D366).withAlpha(isDark ? 30 : 20),
                        borderRadius: BorderRadius.circular(5.0),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: hasTray
                          ? Image.file(trayFile, fit: BoxFit.cover)
                          : const Icon(
                              Icons.collections_rounded,
                              color: Color(0xFF25D366),
                              size: 28,
                            ),
                    ),
                    const SizedBox(width: 14),

                    // Pack Details
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            pack.name,
                            style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: isDark ? Colors.white : const Color(0xFF111B21),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${pack.stickers.length}/30 Stiker • Oleh ${pack.publisher}',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 12,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                          ),
                          const SizedBox(height: 6),

                          // Status Badge (no background, only icon & text color change)
                          if (isInstalled)
                            _buildStatusChip(
                              icon: Icons.check_circle_rounded,
                              text: 'Terpasang di WhatsApp',
                              color: const Color(0xFF25D366),
                            )
                          else if (canAdd)
                            _buildStatusChip(
                              icon: Icons.verified_rounded,
                              text: 'Siap Ditambahkan',
                              color: const Color(0xFF25D366),
                            )
                          else
                            _buildStatusChip(
                              icon: Icons.info_outline_rounded,
                              text: 'Kurang ${3 - totalStickers} stiker lagi',
                              color: const Color(0xFFF09A06),
                            ),
                        ],
                      ),
                    ),

                    Icon(
                      Icons.chevron_right_rounded,
                      color: isDark ? Colors.white54 : Colors.black45,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatusChip({
    required IconData icon,
    required String text,
    required Color color,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 5),
        Text(
          text,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }
}

/// Liquid Glass card with real-time backdrop blur, reflection gradient,
/// and soft ambient drop shadow without borders.
class _LiquidGlassCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;

  const _LiquidGlassCard({
    required this.child,
    this.borderRadius = 5.0,
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
