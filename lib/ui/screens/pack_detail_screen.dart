import 'package:flutter/material.dart';
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';
import 'package:sticker_flutter/ui/widgets/add_sticker_sheet.dart';
import 'package:sticker_flutter/ui/widgets/app_notification.dart';
import 'package:sticker_flutter/ui/widgets/sticker_grid_tile.dart';

/// Screen displaying the details of a sticker pack, its grid of stickers, and the WhatsApp export button.
class PackDetailScreen extends StatefulWidget {
  final String packIdentifier;

  const PackDetailScreen({
    super.key,
    required this.packIdentifier,
  });

  @override
  State<PackDetailScreen> createState() => _PackDetailScreenState();
}

class _PackDetailScreenState extends State<PackDetailScreen> {
  final _manager = StickerPackManager();
  bool _isExporting = false;

  void _openAddStickerSheet() {
    final pack = _manager.getPack(widget.packIdentifier);
    if (pack == null) return;

    if (pack.stickers.length >= 30) {
      AppNotification.show(
        context,
        message: 'Paket ini sudah penuh (maksimal 30 stiker).',
        isSuccess: false,
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddStickerSheet(packIdentifier: widget.packIdentifier),
    );
  }

  Future<void> _exportToWhatsApp(StickerPack pack) async {
    setState(() => _isExporting = true);

    try {
      final result = await _manager.sendPackToWhatsApp(pack.identifier);
      final status = result['status'] as String?;
      final message = result['message'] as String? ?? '';

      if (!mounted) return;

      if (status == 'success') {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Row(
              children: [
                Icon(Icons.check_circle_rounded, color: Color(0xFF25D366), size: 28),
                SizedBox(width: 10),
                Text('Stiker Tersimpan!'),
              ],
            ),
            content: Text(
              'Paket stiker "${pack.name}" berhasil ditambahkan ke WhatsApp.\n\nBuka WhatsApp Anda sekarang, masuk ke chat, dan cek di tab keyboard stiker.',
              style: const TextStyle(fontSize: 14, height: 1.4),
            ),
            actions: [
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF25D366),
                ),
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Oke, Mengerti'),
              ),
            ],
          ),
        );
      } else if (status == 'cancelled') {
        AppNotification.show(
          context,
          message: 'Penambahan stiker dibatalkan oleh pengguna.',
          isSuccess: false,
        );
      } else {
        AppNotification.show(
          context,
          message: message.isNotEmpty ? message : 'Gagal menambahkan stiker ke WhatsApp',
          isSuccess: false,
        );
      }
    } catch (e) {
      if (mounted) {
        AppNotification.show(
          context,
          message: 'Terjadi kesalahan: $e',
          isSuccess: false,
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _manualOptimizePack(StickerPack pack) async {
    setState(() => _isExporting = true);
    try {
      final count = await _manager.autoOptimizePackStickers(pack.identifier);
      if (!mounted) return;
      if (count > 0) {
        AppNotification.show(
          context,
          message: '$count stiker berhasil dioptimalkan sesuai standar WhatsApp (< 100 KB)!',
          isSuccess: true,
        );
      } else {
        AppNotification.show(
          context,
          message: 'Semua stiker sudah optimal (< 100 KB) dan siap untuk WhatsApp.',
          isSuccess: true,
        );
      }
    } catch (e) {
      if (mounted) {
        AppNotification.show(
          context,
          message: 'Gagal mengoptimalkan stiker: $e',
          isSuccess: false,
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  void _confirmDeletePack(StickerPack pack) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Hapus Seluruh Paket?'),
        content: Text(
          'Paket "${pack.name}" dan semua ${pack.stickers.length} stiker di dalamnya akan dihapus secara permanen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Batal'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.of(ctx).pop();
              await _manager.deletePack(pack.identifier);
              if (mounted) {
                Navigator.of(context).pop();
              }
            },
            child: const Text('Hapus Paket'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _manager,
      builder: (context, _) {
        final pack = _manager.getPack(widget.packIdentifier);
        if (pack == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Detail Paket')),
            body: const Center(child: Text('Paket tidak ditemukan.')),
          );
        }

        final isInstalled = _manager.isPackInstalled(pack.identifier);
        final canAdd = pack.canAddToWhatsApp;
        final totalStickers = pack.stickers.length;

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pack.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
                ),
                Text(
                  'Oleh ${pack.publisher}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.auto_fix_high_rounded, color: Color(0xFF25D366)),
                tooltip: 'Optimalkan Ukuran Stiker',
                onPressed: () => _manualOptimizePack(pack),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                tooltip: 'Hapus Paket',
                onPressed: () => _confirmDeletePack(pack),
              ),
            ],
          ),
          body: Column(
            children: [
              // Info Banner Header
              _buildProgressHeader(pack, isInstalled),

              // Grid of stickers
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 1.0,
                  ),
                  itemCount: totalStickers + 1, // slot 0 is "+ Tambah" button
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return _buildAddStickerSlot(totalStickers);
                    }

                    final sticker = pack.stickers[index - 1];
                    final filePath = _manager.getStickerFilePath(
                      pack.identifier,
                      sticker.imageFileName,
                    );

                    return StickerGridTile(
                      sticker: sticker,
                      filePath: filePath,
                      onDelete: () => _manager.removeStickerFromPack(
                        packIdentifier: pack.identifier,
                        fileName: sticker.imageFileName,
                      ),
                    );
                  },
                ),
              ),

              // Bottom Export Button Bar
              _buildBottomActionBar(pack, canAdd, isInstalled),
            ],
          ),
        );
      },
    );
  }

  Widget _buildProgressHeader(StickerPack pack, bool isInstalled) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final total = pack.stickers.length;
    final progress = (total / 30.0).clamp(0.0, 1.0);

    Color bannerColor;
    Color iconColor;
    IconData iconData;
    String bannerText;

    if (total < 3) {
      bannerColor = Colors.amber.shade50;
      iconColor = Colors.orange.shade800;
      iconData = Icons.info_outline_rounded;
      bannerText =
          'WhatsApp mewajibkan minimal 3 stiker dalam 1 paket. Tambah ${pack.remainingStickersNeeded} stiker lagi agar tombol aktif.';
    } else if (isInstalled) {
      bannerColor = const Color(0xFFE8F8F5);
      iconColor = const Color(0xFF128C7E);
      iconData = Icons.check_circle_rounded;
      bannerText =
          'Paket ini sudah terpasang di WhatsApp. Anda bisa menambah stiker baru dan memperbaruinya kapan saja.';
    } else {
      bannerColor = const Color(0xFFE8F5E9);
      iconColor = const Color(0xFF25D366);
      iconData = Icons.verified_rounded;
      bannerText =
          'Syarat terpenuhi! Paket memiliki $total stiker dan siap ditambahkan ke WhatsApp.';
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bannerColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: iconColor.withAlpha(50)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(iconData, color: iconColor, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Koleksi: $total / 30 Stiker',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: iconColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              if (isInstalled)
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                  decoration: BoxDecoration(
                    color: const Color(0xFF25D366),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Aktif di WA',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white12 : Colors.black.withAlpha(20),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  pack.animatedStickerPack ? 'Animasi (≤500KB)' : 'Statis (≤100KB)',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: iconColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: Colors.black12,
              valueColor: AlwaysStoppedAnimation<Color>(iconColor),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            bannerText,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade800, height: 1.3),
          ),
        ],
      ),
    );
  }

  Widget _buildAddStickerSlot(int currentTotal) {
    final isFull = currentTotal >= 30;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isFull ? null : _openAddStickerSheet,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            color: isFull ? Colors.grey.shade200 : const Color(0xFF25D366).withAlpha(15),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isFull ? Colors.grey.shade400 : const Color(0xFF25D366),
              width: 1.5,
              strokeAlign: BorderSide.strokeAlignCenter,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isFull ? Colors.grey : const Color(0xFF25D366),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.add_rounded, color: Colors.white, size: 24),
              ),
              const SizedBox(height: 8),
              Text(
                isFull ? 'Paket Penuh' : '+ Tambah',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: isFull ? Colors.grey : const Color(0xFF128C7E),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomActionBar(StickerPack pack, bool canAdd, bool isInstalled) {
    Color buttonColor;
    String buttonText;
    IconData buttonIcon;

    if (!canAdd) {
      buttonColor = Colors.grey.shade400;
      buttonText = 'Butuh ${pack.remainingStickersNeeded} Stiker Lagi untuk Simpan ke WA';
      buttonIcon = Icons.lock_clock_rounded;
    } else if (isInstalled) {
      buttonColor = const Color(0xFF128C7E);
      buttonText = 'Perbarui Stiker di WhatsApp';
      buttonIcon = Icons.sync_rounded;
    } else {
      buttonColor = const Color(0xFF25D366);
      buttonText = 'Tambahkan ke WhatsApp';
      buttonIcon = Icons.chat_bubble_rounded;
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(12),
            blurRadius: 10,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: buttonColor,
              foregroundColor: Colors.white,
              elevation: canAdd ? 2 : 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: (!canAdd || _isExporting) ? null : () => _exportToWhatsApp(pack),
            icon: _isExporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.white,
                    ),
                  )
                : Icon(buttonIcon, size: 22),
            label: Text(
              _isExporting ? 'Menghubungkan ke WhatsApp...' : buttonText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ),
    );
  }
}
