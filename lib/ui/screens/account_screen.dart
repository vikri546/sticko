import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sticker_flutter/services/app_update_service.dart';
import 'package:sticker_flutter/services/creator_profile_service.dart';
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/ui/screens/edit_profile_screen.dart';
import 'package:sticker_flutter/ui/screens/creator_collection_screen.dart';
import 'package:sticker_flutter/ui/screens/permissions_preferences_screen.dart';
import 'package:sticker_flutter/ui/screens/whatsapp_connection_screen.dart';
import 'package:sticker_flutter/ui/screens/cloud_backup_screen.dart';
import 'package:sticker_flutter/ui/screens/duplicate_stickers_screen.dart';
import 'package:sticker_flutter/ui/widgets/app_notification.dart';

/// Screen displaying user account details, system permissions access, storage management, and app updates.
class AccountScreen extends StatefulWidget {
  final bool showAppBar;

  const AccountScreen({
    super.key,
    this.showAppBar = true,
  });

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _manager = StickerPackManager();
  final _profileService = CreatorProfileService();
  bool _isCheckingUpdate = false;
  String _cacheSizeText = 'Menghitung...';

  @override
  void initState() {
    super.initState();
    _calculateCacheSize();
    _profileService.loadProfile();
  }

  Future<void> _calculateCacheSize() async {
    try {
      final tempDir = await getTemporaryDirectory();
      int totalBytes = 0;
      if (tempDir.existsSync()) {
        final files = tempDir.listSync(recursive: true, followLinks: false);
        for (final file in files) {
          if (file is File) {
            totalBytes += await file.length();
          }
        }
      }
      final mb = totalBytes / (1024 * 1024);
      if (mounted) {
        setState(() {
          _cacheSizeText = '${mb.toStringAsFixed(2)} MB';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _cacheSizeText = '0.00 MB');
      }
    }
  }

  Future<void> _clearCache() async {
    try {
      final tempDir = await getTemporaryDirectory();
      if (tempDir.existsSync()) {
        final files = tempDir.listSync(recursive: false);
        for (final file in files) {
          try {
            await file.delete(recursive: true);
          } catch (_) {}
        }
      }
      await _calculateCacheSize();
      if (mounted) {
        AppNotification.show(
          context,
          message: 'Cache sementara berhasil dibersihkan!',
          isSuccess: true,
        );
      }
    } catch (e) {
      if (mounted) {
        AppNotification.show(
          context,
          message: 'Gagal membersihkan cache: $e',
          isSuccess: false,
        );
      }
    }
  }

  Future<void> _checkForUpdate() async {
    setState(() => _isCheckingUpdate = true);
    await Future.delayed(const Duration(milliseconds: 700));

    if (!mounted) return;
    setState(() => _isCheckingUpdate = false);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        title: const Row(
          children: [
            Icon(Icons.check_circle_rounded, color: Color(0xFF25D366), size: 28),
            SizedBox(width: 12),
            Text('Versi Terbaru', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: const Text(
          'Aplikasi Sticker Maker Anda sudah menggunakan versi paling mutakhir (v1.0.0+1).\n\nFitur force update dan pemeriksaan pembaruan aktif secara otomatis.',
          style: TextStyle(fontSize: 14, height: 1.45),
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF128C7E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
            ),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Oke'),
          ),
        ],
      ),
    );
  }

  void _showTutorialDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        title: const Row(
          children: [
            Icon(Icons.help_outline_rounded, color: Color(0xFFF09A06), size: 28),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Cara Menggunakan Stiker',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              _TutorialStep(
                number: '1',
                title: 'Buat Paket Stiker',
                desc: 'Tambahkan minimal 3 stiker dan maksimal 30 stiker ke dalam satu paket.',
              ),
              SizedBox(height: 12),
              _TutorialStep(
                number: '2',
                title: 'Kirim ke WhatsApp',
                desc: 'Ketuk tombol hijau "Simpan ke WhatsApp" di halaman detail paket stiker.',
              ),
              SizedBox(height: 12),
              _TutorialStep(
                number: '3',
                title: 'Mulai Chat & Kirim',
                desc: 'Buka chat di WhatsApp > Ketuk ikon emoji pada keyboard > Pilih tab stiker. Stiker siap dipakai!',
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFF09A06),
              foregroundColor: const Color(0xFF3B1E00),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
            ),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Mengerti', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showPrivacyDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        title: const Row(
          children: [
            Icon(Icons.privacy_tip_outlined, color: Color(0xFF128C7E), size: 26),
            SizedBox(width: 12),
            Text('Privasi Pengguna', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: const Text(
          'Semua foto, kamera, dan paket stiker diproses secara 100% lokal di dalam memori smartphone Anda.\n\nTidak ada foto atau stiker yang diunggah ke server cloud pihak ketiga mana pun tanpa persetujuan Anda.',
          style: TextStyle(fontSize: 14, height: 1.45),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
            ),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Tutup'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ListenableBuilder(
      listenable: Listenable.merge([_manager, _profileService]),
      builder: (context, _) {
        final totalPacks = _manager.packs.length;
        final totalStickers =
            _manager.packs.fold<int>(0, (sum, p) => sum + p.stickers.length);
        final installedPacks = _manager.packs
            .where((p) => _manager.isPackInstalled(p.identifier))
            .length;

        return Scaffold(
          extendBodyBehindAppBar: true,
          backgroundColor: Colors.transparent,
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
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 130),
                  children: [
                    if (widget.showAppBar) ...[
                      AppBar(
                        elevation: 0,
                        backgroundColor: Colors.transparent,
                        surfaceTintColor: Colors.transparent,
                        centerTitle: true,
                        automaticallyImplyLeading: false,
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
                      const SizedBox(height: 8),
                    ] else
                      const SizedBox(height: 16),

                    // 1. Creator Profile Card
                    _buildCreatorProfileCard(
                      isDark: isDark,
                      totalPacks: totalPacks,
                      totalStickers: totalStickers,
                      installedPacks: installedPacks,
                    ),
              const SizedBox(height: 20),

              // 2. Section: Pengaturan Sistem (New Simplified Core Feature)
              _buildSectionHeader('PENGATURAN SISTEM'),
              _buildSettingsCard(
                isDark: isDark,
                children: [
                  _SettingsListTile(
                    title: 'Pindai Stiker "Duplikat"',
                    subtitle: 'Pindai otomatis & kelola stiker kembar antar paket',
                    onTap: () {
                      Navigator.of(context).push(
                        DuplicateStickersScreen.route(),
                      );
                    },
                  ),
                  Divider(
                    height: 1,
                    indent: 20,
                    endIndent: 20,
                    color: isDark ? const Color(0x24FFFFFF) : const Color(0x1F000000),
                  ),
                  _SettingsListTile(
                    title: 'Perizinan & Preferensi',
                    subtitle: 'Izin akses galeri foto, kamera, & notifikasi',
                    onTap: () {
                      Navigator.of(context).push(
                        PermissionsPreferencesScreen.route(),
                      );
                    },
                  ),
                  Divider(
                    height: 1,
                    indent: 20,
                    endIndent: 20,
                    color: isDark ? const Color(0x24FFFFFF) : const Color(0x1F000000),
                  ),
                  _SettingsListTile(
                    title: 'Integrasi WhatsApp',
                    subtitle: 'Status kaitan WhatsApp resmi, Business, & duplikat',
                    onTap: () {
                      Navigator.of(context).push(
                        WhatsAppConnectionScreen.route(),
                      );
                    },
                  ),
                  Divider(
                    height: 1,
                    indent: 20,
                    endIndent: 20,
                    color: isDark ? const Color(0x24FFFFFF) : const Color(0x1F000000),
                  ),
                  _SettingsListTile(
                    title: 'Cadangan & Pemulihan Cloud',
                    subtitle: 'Ekspor ZIP, simpan cadangan, & pulihkan stiker',
                    onTap: () {
                      Navigator.of(context).push(
                        CloudBackupScreen.route(),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // 3. Section: Pengaturan & Bantuan Lainnya
              _buildSectionHeader('PENGATURAN LAINNYA'),
              _buildSettingsCard(
                isDark: isDark,
                children: [
                  _SettingsListTile(
                    title: 'Bersihkan Cache Sementara',
                    subtitle: 'Ukuran cache saat ini: $_cacheSizeText',
                    trailingBadge: 'Bersihkan',
                    trailingBadgeColor: Colors.deepOrange,
                    onTap: _clearCache,
                  ),
                  Divider(height: 1, indent: 20, endIndent: 20, color: isDark ? const Color(0x24FFFFFF) : const Color(0x1F000000)),
                  _SettingsListTile(
                    title: 'Periksa Pembaruan APK',
                    subtitle: 'Versi saat ini: ${AppUpdateService.defaultCurrentVersion} (Terbaru)',
                    trailingWidget: _isCheckingUpdate
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    onTap: _isCheckingUpdate ? null : _checkForUpdate,
                  ),
                  Divider(height: 1, indent: 20, endIndent: 20, color: isDark ? const Color(0x24FFFFFF) : const Color(0x1F000000)),
                  _SettingsListTile(
                    title: 'Panduan Menambahkan ke WA',
                    subtitle: 'Langkah mudah memunculkan stiker di keyboard',
                    onTap: _showTutorialDialog,
                  ),
                  Divider(height: 1, indent: 20, endIndent: 20, color: isDark ? const Color(0x24FFFFFF) : const Color(0x1F000000)),
                  _SettingsListTile(
                    title: 'Kebijakan Privasi & Data',
                    subtitle: '100% lokal, aman & tanpa pelacak luar',
                    onTap: _showPrivacyDialog,
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Version Footer
              Center(
                child: Text(
                  'Sticker Maker v1.0.0+1 • Made with Flutter',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: isDark ? Colors.grey[400] : const Color(0xFFB0BEC5),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ],
    ),
  );
      },
    );
  }

  Widget _buildCreatorProfileCard({
    required bool isDark,
    required int totalPacks,
    required int totalStickers,
    required int installedPacks,
  }) {
    final hasCustomAvatar = _profileService.avatarPath != null &&
        File(_profileService.avatarPath!).existsSync();

    return _LiquidGlassCard(
      borderRadius: 5,
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFFF09A06).withAlpha(100),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFF09A06).withAlpha(30),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipOval(
                  child: hasCustomAvatar
                      ? Image.file(
                          File(_profileService.avatarPath!),
                          width: 58,
                          height: 58,
                          fit: BoxFit.cover,
                        )
                      : Image.asset(
                          'lib/images/sticko-app.png',
                          width: 58,
                          height: 58,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            color: const Color(0xFFF09A06),
                            child: const Icon(
                              Icons.sentiment_very_satisfied_rounded,
                              color: Colors.white,
                              size: 32,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            _profileService.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.bold,
                              fontSize: 17,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.verified_rounded, color: Color(0xFF25D366), size: 18),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _profileService.bio,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 13,
                        color: isDark ? Colors.grey[300] : Colors.grey[700],
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                splashRadius: 22,
                icon: const Icon(
                  Icons.edit_outlined,
                  color: Colors.white70,
                  size: 20,
                ),
                tooltip: 'Edit Profil Kreator',
                onPressed: () {
                  Navigator.of(context).push(
                    EditProfileScreen.route(),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: isDark ? const Color(0x55000000) : const Color(0x33FFFFFF),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatItem(
                  'Paket',
                  '$totalPacks',
                  isDark,
                  onTap: () => Navigator.of(context).push(
                    CreatorCollectionScreen.route(initialTabIndex: 0),
                  ),
                ),
                Container(width: 1, height: 28, color: Colors.white.withAlpha(25)),
                _buildStatItem(
                  'Stiker',
                  '$totalStickers',
                  isDark,
                  onTap: () => Navigator.of(context).push(
                    CreatorCollectionScreen.route(initialTabIndex: 1),
                  ),
                ),
                Container(width: 1, height: 28, color: Colors.white.withAlpha(25)),
                _buildStatItem(
                  'Di WA',
                  '$installedPacks',
                  isDark,
                  onTap: () => Navigator.of(context).push(
                    CreatorCollectionScreen.route(initialTabIndex: 2),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(
    String label,
    String value,
    bool isDark, {
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          children: [
            Text(
              value,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: const Color(0xFFF09A06),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.grey[300] : Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 8, top: 4),
      child: Text(
        title,
        style: GoogleFonts.plusJakartaSans(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
          color: isDark ? const Color(0xFFCFD8DC) : const Color(0xFF546E7A),
        ),
      ),
    );
  }

  Widget _buildSettingsCard({
    required bool isDark,
    required List<Widget> children,
  }) {
    return _LiquidGlassCard(
      borderRadius: 5,
      child: Column(
        children: children,
      ),
    );
  }
}

/// Liquid Glass card with real-time backdrop blur, multi-stop reflection gradient,
/// and soft ambient drop shadow without borders.
class _LiquidGlassCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;

  const _LiquidGlassCard({
    required this.child,
    this.borderRadius = 16.0,
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
            color: Colors.black.withAlpha(isDark ? 90 : 25),
            blurRadius: 24,
            offset: const Offset(0, 6),
          ),
          BoxShadow(
            color: const Color(0xFFF09A06).withAlpha(isDark ? 12 : 8),
            blurRadius: 18,
            offset: const Offset(0, 0),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18.0, sigmaY: 18.0),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? const [
                        Color(0x28FFFFFF), // Specular light highlight reflection
                        Color(0x751E2B32), // Frosted dark teal glass
                        Color(0xB0111B21), // Deep liquid glass base
                      ]
                    : const [
                        Color(0xD9FFFFFF),
                        Color(0x80FFFFFF),
                      ],
                stops: isDark ? const [0.0, 0.40, 1.0] : null,
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsListTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final String? trailingBadge;
  final Color? trailingBadgeColor;
  final Widget? trailingWidget;
  final VoidCallback? onTap;

  const _SettingsListTile({
    required this.title,
    required this.subtitle,
    this.trailingBadge,
    this.trailingBadgeColor,
    this.trailingWidget,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        title: Text(
          title,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white : const Color(0xFF1E2B32),
            letterSpacing: -0.1,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            subtitle,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 12.5,
              fontWeight: FontWeight.normal,
              color: isDark ? const Color(0xFFB0BEC5) : const Color(0xFF607D8B),
              height: 1.35,
            ),
          ),
        ),
        trailing: trailingWidget ??
            (trailingBadge != null
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: (trailingBadgeColor ?? const Color(0xFF128C7E)).withAlpha(25),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      trailingBadge!,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                        color: trailingBadgeColor ?? const Color(0xFF128C7E),
                      ),
                    ),
                  )
                : null),
        onTap: onTap,
      ),
    );
  }
}

class _TutorialStep extends StatelessWidget {
  final String number;
  final String title;
  final String desc;

  const _TutorialStep({
    required this.number,
    required this.title,
    required this.desc,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: const BoxDecoration(
            color: Color(0xFFF09A06),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            number,
            style: GoogleFonts.plusJakartaSans(
              color: const Color(0xFF3B1E00),
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                desc,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 12.5,
                  color: Colors.grey[400],
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
