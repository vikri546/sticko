import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sticker_flutter/services/app_update_notification_service.dart';
import 'package:sticker_flutter/services/app_update_service.dart';
import 'package:sticker_flutter/ui/widgets/app_notification.dart';

/// Screen displaying chronological APK version release history with an exclusive
/// accordion dropdown toggle on each version to show or hide features, bug fixes,
/// and release dates. Styled to match [CloudBackupScreen].
class UpdateHistoryScreen extends StatefulWidget {
  const UpdateHistoryScreen({super.key});

  /// Custom PageRoute with Zoom In (enter) and Zoom Out (exit) transition.
  static Route<void> route() {
    return PageRouteBuilder<void>(
      pageBuilder: (context, animation, secondaryAnimation) =>
          const UpdateHistoryScreen(),
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
  State<UpdateHistoryScreen> createState() => _UpdateHistoryScreenState();
}

class _UpdateHistoryScreenState extends State<UpdateHistoryScreen> {
  String _currentAppVersion = AppUpdateService.defaultCurrentVersion;
  bool _isCheckingUpdate = false;
  final List<AppVersionRelease> _releases =
      AppUpdateService.defaultVersionHistory;

  /// Tracks the single currently expanded version. Opening another version
  /// automatically hides the previously opened version.
  String? _expandedVersion;

  @override
  void initState() {
    super.initState();
    // Expand the latest version by default so the newest update info is immediately visible
    _expandedVersion = _releases.isNotEmpty ? _releases.first.version : null;
    AppUpdateService.getCurrentAppVersion().then((ver) {
      if (mounted && ver != _currentAppVersion) {
        setState(() => _currentAppVersion = ver);
      }
    });
  }

  void _toggleVersionDropdown(String version) {
    setState(() {
      if (_expandedVersion == version) {
        _expandedVersion = null;
      } else {
        _expandedVersion = version;
      }
    });
  }

  Future<void> _checkForUpdate() async {
    if (_isCheckingUpdate) return;
    setState(() => _isCheckingUpdate = true);
    await AppUpdateNotificationService().ensurePermissionGranted();
    final updateInfo = await AppUpdateService.checkRemoteUpdate(
      showStatusBarNotification: true,
    );

    if (!mounted) return;
    setState(() => _isCheckingUpdate = false);

    if (updateInfo != null && updateInfo.hasUpdate) {
      await AppUpdateService.showUpdateDialog(context, updateInfo);
    } else {
      AppNotification.show(
        context,
        message:
            'Sticko v$_currentAppVersion sudah menggunakan versi paling mutakhir.',
        isSuccess: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(
          'Riwayat Pembaruan',
          style: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.bold,
            fontSize: 18,
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
                // 1. Overall Status Banner (same style as CloudBackupScreen)
                _buildOverallStatusBanner(isDark),
                const SizedBox(height: 22),

                // 2. Quick Actions Card (same style as CloudBackupScreen's Aksi & Sinkronisasi)
                _buildSectionTitle('AKSI & PEMBARUAN'),
                const SizedBox(height: 6),
                _buildActionCards(isDark),
                const SizedBox(height: 22),

                // 3. Version Release History List (same style as CloudBackupScreen's Riwayat Cadangan Lokal)
                _buildSectionTitle('RIWAYAT RILIS VERSI APK'),
                const SizedBox(height: 6),
                _buildVersionHistoryCard(isDark),
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

  Widget _buildOverallStatusBanner(bool isDark) {
    return _LiquidGlassCard(
      borderRadius: 5,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFFF09A06).withAlpha(40),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.system_update_rounded,
              color: Color(0xFFF09A06),
              size: 28,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sticko v$_currentAppVersion',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Total ${_releases.length} versi rilis tercatat • Pilih tombol Lihat pada versi untuk membuka informasi fitur dan perbaikan bug.',
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
    );
  }

  Widget _buildActionCards(bool isDark) {
    return _LiquidGlassCard(
      borderRadius: 5,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Periksa Pembaruan APK',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Cek ketersediaan rilis APK terbaru dari server',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11.5,
                      color: isDark ? Colors.grey[300] : Colors.grey[700],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _buildCapsuleButton(
              label: _isCheckingUpdate ? 'Memeriksa...' : 'Cek Update',
              color: const Color(0xFF25D366),
              textColor: Colors.white,
              onTap: _isCheckingUpdate ? null : _checkForUpdate,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCapsuleButton({
    Key? buttonKey,
    required String label,
    required Color color,
    required Color textColor,
    required VoidCallback? onTap,
    IconData? trailingIcon,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: buttonKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(30),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: onTap == null ? Colors.grey.withAlpha(80) : color,
            borderRadius: BorderRadius.circular(30),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
              if (trailingIcon != null) ...[
                const SizedBox(width: 4),
                Icon(
                  trailingIcon,
                  size: 16,
                  color: textColor,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVersionHistoryCard(bool isDark) {
    return _LiquidGlassCard(
      borderRadius: 5,
      child: Column(
        children: [
          for (int i = 0; i < _releases.length; i++) ...[
            _buildVersionReleaseItem(
              release: _releases[i],
              isExpanded: _expandedVersion == _releases[i].version,
              isDark: isDark,
            ),
            if (i < _releases.length - 1)
              Divider(
                height: 1,
                indent: 16,
                endIndent: 16,
                color:
                    isDark ? const Color(0x24FFFFFF) : const Color(0x1F000000),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildVersionReleaseItem({
    required AppVersionRelease release,
    required bool isExpanded,
    required bool isDark,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Row Header (matches CloudBackupScreen's _buildLocalBackupsCard item row)
        InkWell(
          key: ValueKey('version_dropdown_${release.version}'),
          onTap: () => _toggleVersionDropdown(release.version),
          borderRadius: BorderRadius.circular(5),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF09A06).withAlpha(30),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Icon(
                    release.isLatest
                        ? Icons.new_releases_outlined
                        : Icons.inventory_2_outlined,
                    color: const Color(0xFFF09A06),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            'Versi ${release.version}',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0x1AFFFFFF)
                                  : const Color(0x14FFFFFF),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              release.releaseTag,
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFFCFD8DC),
                              ),
                            ),
                          ),
                          if (release.isLatest)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1.5,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF25D366).withAlpha(35),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                'Terbaru',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF25D366),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Dirilis: ${release.releaseDate}',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 11.5,
                          color: isDark ? Colors.grey[300] : Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Capsule Dropdown Button (Hide / Show toggle)
                _buildCapsuleButton(
                  label: isExpanded ? 'Tutup' : 'Lihat',
                  color: isExpanded
                      ? const Color(0xFFF09A06)
                      : const Color(0xFF25D366),
                  textColor: isExpanded ? Colors.black : Colors.white,
                  trailingIcon: isExpanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  onTap: () => _toggleVersionDropdown(release.version),
                ),
              ],
            ),
          ),
        ),

        // Expandable Details Container (Features & Bug Fixes)
        if (isExpanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Container(
              key: ValueKey('version_details_${release.version}'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color:
                    isDark ? const Color(0x1AFFFFFF) : const Color(0x0A000000),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Features Section
                  if (release.features.isNotEmpty) ...[
                    Row(
                      children: [
                        const Icon(
                          Icons.auto_awesome_rounded,
                          size: 15,
                          color: Color(0xFF25D366),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Fitur Pembaruan',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF25D366),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    for (final feature in release.features)
                      _buildBulletPoint(feature, isDark),
                  ],

                  if (release.features.isNotEmpty &&
                      release.bugFixes.isNotEmpty)
                    const SizedBox(height: 10),

                  // Bug Fixes Section
                  if (release.bugFixes.isNotEmpty) ...[
                    Row(
                      children: [
                        const Icon(
                          Icons.bug_report_outlined,
                          size: 15,
                          color: Color(0xFFF09A06),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Perbaikan Bug & Sistem',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFFF09A06),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    for (final bug in release.bugFixes)
                      _buildBulletPoint(bug, isDark),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBulletPoint(String text, bool isDark) {
    final cleanText = text.trim().replaceFirst(RegExp(r'^[-•*]\s*'), '');
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '- ',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 12,
              height: 1.4,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          Expanded(
            child: Text(
              cleanText,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12,
                height: 1.4,
                color: isDark ? Colors.grey[300] : Colors.grey[700],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Liquid Glass Card Container identical to [CloudBackupScreen].
class _LiquidGlassCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;

  const _LiquidGlassCard({
    required this.child,
    this.borderRadius = 5,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(borderRadius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [
                      const Color(0x28FFFFFF),
                      const Color(0x751E2B32),
                      const Color(0xB0111B21),
                    ]
                  : [
                      const Color(0xD9FFFFFF),
                      const Color(0xB3FFFFFF),
                      const Color(0x80F4F6F8),
                    ],
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
