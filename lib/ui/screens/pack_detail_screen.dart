import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sticker_flutter/config/developer_sticker_packs.dart';
import 'package:sticker_flutter/services/audio_sticker_bot_service.dart';
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';
import 'package:sticker_flutter/ui/widgets/add_sticker_sheet.dart';
import 'package:sticker_flutter/ui/widgets/app_notification.dart';
import 'package:sticker_flutter/ui/widgets/audio_bot_bridge_sheet.dart';
import 'package:sticker_flutter/ui/widgets/sticker_grid_tile.dart';

/// Screen displaying the details of a sticker pack, its grid of stickers, and the WhatsApp export button.
class PackDetailScreen extends StatefulWidget {
  final String packIdentifier;

  /// Hold duration required (1.5 seconds) to activate sticker drag-and-drop reordering.
  static const Duration stickerDragHoldDuration = Duration(milliseconds: 1500);

  const PackDetailScreen({
    super.key,
    required this.packIdentifier,
  });

  @override
  State<PackDetailScreen> createState() => _PackDetailScreenState();
}

class _PackDetailScreenState extends State<PackDetailScreen> {
  final _manager = StickerPackManager();
  final ScrollController _gridScrollController = ScrollController();
  final GlobalKey _gridViewKey = GlobalKey();
  bool _isExporting = false;
  bool _isSendingViaBot = false;

  @override
  void dispose() {
    WhatsAppStickersService.stopStickerAudio();
    _gridScrollController.dispose();
    super.dispose();
  }

  void _handleDragAutoScroll(DragUpdateDetails details) {
    if (!_gridScrollController.hasClients) return;
    final renderBox = _gridViewKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final localPos = renderBox.globalToLocal(details.globalPosition);
    const edgeThreshold = 64.0;
    const scrollStep = 8.0;
    final pos = _gridScrollController.position;

    if (localPos.dy < edgeThreshold && pos.pixels > pos.minScrollExtent) {
      _gridScrollController.jumpTo(
        (pos.pixels - scrollStep).clamp(pos.minScrollExtent, pos.maxScrollExtent),
      );
    } else if (localPos.dy > renderBox.size.height - edgeThreshold &&
        pos.pixels < pos.maxScrollExtent) {
      _gridScrollController.jumpTo(
        (pos.pixels + scrollStep).clamp(pos.minScrollExtent, pos.maxScrollExtent),
      );
    }
  }

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

  void _openEditStickerSheet(
    StickerPack pack,
    StickerItem sticker,
    String? filePath,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddStickerSheet(
        packIdentifier: pack.identifier,
        editingSticker: sticker,
        editingStickerFilePath: filePath,
      ),
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
    if (DeveloperStickerPacks.isProtectedPack(pack)) {
      AppNotification.show(
        context,
        message: 'Paket bawaan developer tidak dapat dihapus.',
        isSuccess: false,
      );
      return;
    }

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
        final isDeveloperPack = DeveloperStickerPacks.isProtectedPack(pack);

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
              if (!isDeveloperPack)
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
                  key: _gridViewKey,
                  controller: _gridScrollController,
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

                    final stickerIndex = index - 1;
                    final sticker = pack.stickers[stickerIndex];
                    final filePath = _manager.getStickerFilePath(
                      pack.identifier,
                      sticker.imageFileName,
                    );

                    return _buildReorderableStickerTile(
                      pack: pack,
                      sticker: sticker,
                      stickerIndex: stickerIndex,
                      filePath: filePath,
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

  Widget _buildReorderableStickerTile({
    required StickerPack pack,
    required StickerItem sticker,
    required int stickerIndex,
    required String? filePath,
  }) {
    final audioPath = _manager.getAudioFilePath(
      pack.identifier,
      sticker.audioFileName,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final tileSize = constraints.biggest;

        return DragTarget<int>(
          key: ValueKey('sticker_drag_target_${sticker.imageFileName}'),
          onWillAcceptWithDetails: (details) => details.data != stickerIndex,
          onAcceptWithDetails: (details) async {
            await _manager.reorderStickerInPack(
              packIdentifier: pack.identifier,
              oldIndex: details.data,
              newIndex: stickerIndex,
            );
          },
          builder: (context, candidateData, rejectedData) {
            final isTargetHovered = candidateData.isNotEmpty;

            return LongPressDraggable<int>(
              key: ValueKey('sticker_draggable_${sticker.imageFileName}'),
              data: stickerIndex,
              delay: PackDetailScreen.stickerDragHoldDuration,
              hapticFeedbackOnStart: true,
              onDragStarted: () {
                HapticFeedback.mediumImpact();
              },
              onDragUpdate: _handleDragAutoScroll,
              feedback: Material(
                color: Colors.transparent,
                elevation: 12,
                borderRadius: BorderRadius.circular(16),
                child: Transform.scale(
                  scale: 1.06,
                  child: SizedBox(
                    width: tileSize.width,
                    height: tileSize.height,
                    child: StickerGridTile(
                      sticker: sticker,
                      filePath: filePath,
                      audioFilePath: audioPath,
                      isDragTargetHighlighted: true,
                      showDeleteButton: false,
                      onDelete: () {},
                    ),
                  ),
                ),
              ),
              childWhenDragging: Opacity(
                opacity: 0.35,
                child: StickerGridTile(
                  sticker: sticker,
                  filePath: filePath,
                  audioFilePath: audioPath,
                  showDeleteButton: false,
                  onDelete: () {},
                ),
              ),
              child: AnimatedScale(
                scale: isTargetHovered ? 0.94 : 1.0,
                duration: const Duration(milliseconds: 160),
                child: StickerGridTile(
                  sticker: sticker,
                  filePath: filePath,
                  audioFilePath: audioPath,
                  isDragTargetHighlighted: isTargetHovered,
                  showDeleteButton: !DeveloperStickerPacks.isProtectedPack(pack),
                  onTap: () => _openEditStickerSheet(pack, sticker, filePath),
                  onDelete: () => _manager.removeStickerFromPack(
                    packIdentifier: pack.identifier,
                    fileName: sticker.imageFileName,
                  ),
                ),
              ),
            );
          },
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
                  pack.videoAudioStickerPack
                      ? 'Video Audio (≤10s)'
                      : (pack.animatedStickerPack ? 'Animasi (≤500KB)' : 'Statis (≤100KB)'),
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

  List<AudioStickerBridgeItem> _collectAudioBridgeItems(StickerPack pack) {
    final items = <AudioStickerBridgeItem>[];
    for (final sticker in pack.stickers) {
      if (!sticker.hasAudio) continue;
      final webpPath =
          _manager.getStickerFilePath(pack.identifier, sticker.imageFileName);
      final audioPath =
          _manager.getAudioFilePath(pack.identifier, sticker.audioFileName);
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
    return items;
  }

  Future<void> _sendPackViaAudioBot(StickerPack pack, {bool forceConfigSheet = false}) async {
    await WhatsAppStickersService.stopStickerAudio();
    final items = _collectAudioBridgeItems(pack);

    if (forceConfigSheet) {
      if (!mounted) return;
      await AudioBotBridgeSheet.show(
        context,
        title: 'Pengaturan Chatbot Stiker Audio WA',
        itemsToSend: items.isNotEmpty ? items : null,
      );
      return;
    }

    if (items.isEmpty) {
      if (!mounted) return;
      AppNotification.show(
        context,
        message: 'Tambahkan minimal 1 stiker video bersuara terlebih dahulu.',
        isSuccess: false,
      );
      return;
    }

    final botService = AudioStickerBotService();
    await botService.loadConfig();
    if (!botService.isConfigured) {
      if (!mounted) return;
      await AudioBotBridgeSheet.show(
        context,
        title: 'Kirim "${pack.name}" via Chatbot WA',
        itemsToSend: items,
      );
      return;
    }

    setState(() => _isSendingViaBot = true);
    final res = await botService.sendItemsViaBridge(items: items);
    if (!mounted) return;
    setState(() => _isSendingViaBot = false);

    AppNotification.show(
      context,
      message: res.message,
      isSuccess: res.success,
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pack.videoAudioStickerPack) ...[
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: ElevatedButton.icon(
                        key: const Key('send_pack_via_audio_bot_button'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFF09A06),
                          foregroundColor: Colors.black,
                          elevation: 1,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: (_isSendingViaBot || _isExporting)
                            ? null
                            : () => _sendPackViaAudioBot(pack),
                        icon: _isSendingViaBot
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                  color: Colors.black,
                                ),
                              )
                            : const Icon(Icons.smart_toy_rounded, size: 20),
                        label: Text(
                          _isSendingViaBot
                              ? 'Mengirim ke Bot WA...'
                              : 'Kirim Stiker Bersuara via Bot WA',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: OutlinedButton(
                      key: const Key('config_audio_bot_button'),
                      onPressed: (_isSendingViaBot || _isExporting)
                          ? null
                          : () => _sendPackViaAudioBot(pack, forceConfigSheet: true),
                      style: OutlinedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        foregroundColor: const Color(0xFFF09A06),
                        side: const BorderSide(color: Color(0xFFF09A06), width: 1.4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Icon(Icons.tune_rounded, size: 20),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
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
          ],
        ),
      ),
    );
  }
}
