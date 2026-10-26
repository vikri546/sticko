import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sticker_flutter/services/app_permission_service.dart';
import 'package:sticker_flutter/services/sticker_image_processor.dart';
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/ui/widgets/app_notification.dart';

/// Modal bottom sheet to pick single or multiple images, preview, tag with emojis, and add to pack.
class AddStickerSheet extends StatefulWidget {
  final String packIdentifier;

  const AddStickerSheet({
    super.key,
    required this.packIdentifier,
  });

  @override
  State<AddStickerSheet> createState() => _AddStickerSheetState();
}

class _AddStickerSheetState extends State<AddStickerSheet> {
  final _permissionService = AppPermissionService();

  // Single-selection mode
  Uint8List? _selectedImageBytes;
  bool _isAnimatedSticker = false;
  String? _processingMessage;

  // Multi-selection (group) mode
  final List<Uint8List> _multiSelectedBytes = [];
  int _processingCurrent = 0;
  int _processingTotal = 0;

  final List<String> _selectedEmojis = ['😀'];
  bool _isProcessing = false;

  final List<String> _commonEmojis = [
    '😀', '😂', '🔥', '❤️', '🎉', '👍', '😎', '🥳', '🙏', '😍', '🤩', '✨'
  ];

  int get _remainingSlots {
    final pack = StickerPackManager().getPack(widget.packIdentifier);
    return 30 - (pack?.stickers.length ?? 0);
  }

  bool get _isPackAnimated {
    final pack = StickerPackManager().getPack(widget.packIdentifier);
    return pack?.animatedStickerPack ?? false;
  }

  Future<void> _pickFromGallery() async {
    final hasPermission = await _permissionService.requestGalleryPermission(context);
    if (!hasPermission || !mounted) return;

    final availableSlots = _remainingSlots;
    if (availableSlots <= 0) {
      AppNotification.show(
        context,
        message: 'Paket stiker sudah mencapai batas maksimal 30 stiker.',
        isSuccess: false,
      );
      return;
    }

    if (_isPackAnimated) {
      await _pickAnimatedMedia();
      return;
    }

    try {
      final files = await StickerImageProcessor.pickMultiImage(limit: availableSlots);
      if (files.isEmpty || !mounted) return;

      if (files.length == 1) {
        final bytes = await files.first.readAsBytes();
        if (!mounted) return;
        setState(() {
          _selectedImageBytes = bytes;
          _isAnimatedSticker = false;
          _multiSelectedBytes.clear();
        });
      } else {
        // Multi-image selection
        setState(() {
          _isProcessing = true;
          _processingMessage = 'Memproses ${files.length} foto...';
        });
        final newBytesList = <Uint8List>[];
        for (final file in files) {
          newBytesList.add(await file.readAsBytes());
        }
        if (!mounted) return;
        setState(() {
          _multiSelectedBytes.clear();
          _multiSelectedBytes.addAll(newBytesList);
          _selectedImageBytes = null;
          _isAnimatedSticker = false;
        });
      }
    } catch (e) {
      if (mounted) {
        AppNotification.show(
          context,
          message: 'Gagal memilih foto dari galeri: $e',
          isSuccess: false,
        );
      }
    } finally {
      if (mounted && _isProcessing) {
        setState(() {
          _isProcessing = false;
          _processingMessage = null;
        });
      }
    }
  }

  /// Pick animated media from gallery where both Videos AND GIFs appear in the system gallery.
  Future<void> _pickAnimatedMedia() async {
    final hasPermission = await _permissionService.requestGalleryPermission(context);
    if (!hasPermission || !mounted) return;

    final availableSlots = _remainingSlots;
    if (availableSlots <= 0) {
      AppNotification.show(
        context,
        message: 'Paket stiker sudah mencapai batas maksimal 30 stiker.',
        isSuccess: false,
      );
      return;
    }

    try {
      // Buka galeri yang menampilkan KEDUA media: Video dan GIF (menggunakan pickMultipleAnimatedMedia)
      final files = await StickerImageProcessor.pickMultipleAnimatedMedia(limit: availableSlots);
      if (files.isEmpty || !mounted) return;

      if (files.length == 1) {
        final file = files.first;
        final isVideo = StickerImageProcessor.isVideoFile(file.path);

        if (isVideo) {
          setState(() {
            _isProcessing = true;
            _processingMessage = 'Mengekstrak frame video animasi (maks 10 detik)...';
          });

          final processed = await StickerImageProcessor.processVideoToStickerWebp(
            videoPath: file.path,
            maxDurationMs: 10000,
          );

          if (!mounted) return;
          setState(() {
            _selectedImageBytes = processed.webpBytes;
            _isAnimatedSticker = true;
            _multiSelectedBytes.clear();
          });
        } else {
          // Berkas GIF atau gambar animasi
          final bytes = await file.readAsBytes();
          final isAnim = StickerImageProcessor.isAnimatedMedia(bytes);

          if (!isAnim) {
            if (!mounted) return;
            AppNotification.show(
              context,
              message: 'Berkas yang dipilih bukan animasi. Silakan pilih GIF animasi atau video.',
              isSuccess: false,
            );
            return;
          }

          if (!mounted) return;
          setState(() {
            _isProcessing = true;
            _processingMessage = 'Memproses animasi GIF (maks 10 detik)...';
          });

          final processed = await StickerImageProcessor.processAnimatedToStickerWebp(
            bytes: bytes,
            maxDurationMs: 10000,
          );

          if (!mounted) return;
          setState(() {
            _selectedImageBytes = processed.webpBytes;
            _isAnimatedSticker = true;
            _multiSelectedBytes.clear();
          });
        }
      } else {
        // Multi-image selection for animated stickers
        setState(() {
          _isProcessing = true;
          _processingMessage = 'Memproses ${files.length} berkas animasi...';
        });

        final newBytesList = <Uint8List>[];
        for (final file in files) {
          final isVideo = StickerImageProcessor.isVideoFile(file.path);
          if (isVideo) {
            final processed = await StickerImageProcessor.processVideoToStickerWebp(
              videoPath: file.path,
              maxDurationMs: 10000,
            );
            newBytesList.add(processed.webpBytes);
          } else {
            final bytes = await file.readAsBytes();
            final isAnim = StickerImageProcessor.isAnimatedMedia(bytes);
            if (isAnim) {
              final processed = await StickerImageProcessor.processAnimatedToStickerWebp(
                bytes: bytes,
                maxDurationMs: 10000,
              );
              newBytesList.add(processed.webpBytes);
            }
          }
        }

        if (newBytesList.isEmpty) {
          if (!mounted) return;
          AppNotification.show(
            context,
            message: 'Tidak ada animasi valid (GIF atau video) yang dipilih.',
            isSuccess: false,
          );
          return;
        }

        if (!mounted) return;
        setState(() {
          _multiSelectedBytes.clear();
          _multiSelectedBytes.addAll(newBytesList);
          _selectedImageBytes = null;
          _isAnimatedSticker = true;
        });
      }
    } catch (e) {
      if (mounted) {
        AppNotification.show(
          context,
          message: 'Gagal memproses media animasi: $e',
          isSuccess: false,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _processingMessage = null;
        });
      }
    }
  }

  Future<void> _pickMoreFromGallery() async {
    final hasPermission = await _permissionService.requestGalleryPermission(context);
    if (!hasPermission || !mounted) return;

    final availableSlots = _remainingSlots - _multiSelectedBytes.length;
    if (availableSlots <= 0) {
      AppNotification.show(
        context,
        message: 'Paket stiker sudah mencapai batas maksimal 30 stiker.',
        isSuccess: false,
      );
      return;
    }

    try {
      final files = _isPackAnimated
          ? await StickerImageProcessor.pickMultipleAnimatedMedia(limit: availableSlots)
          : await StickerImageProcessor.pickMultiImage(limit: availableSlots);
      if (files.isEmpty || !mounted) return;

      setState(() {
        _isProcessing = true;
        _processingMessage = 'Memproses berkas media tambahan...';
      });

      final newBytesList = <Uint8List>[];
      for (final file in files) {
        final isVideo = StickerImageProcessor.isVideoFile(file.path);
        if (isVideo) {
          final processed = await StickerImageProcessor.processVideoToStickerWebp(
            videoPath: file.path,
            maxDurationMs: 10000,
          );
          newBytesList.add(processed.webpBytes);
        } else {
          final bytes = await file.readAsBytes();
          final isAnim = StickerImageProcessor.isAnimatedMedia(bytes);
          if (isAnim) {
            final processed = await StickerImageProcessor.processAnimatedToStickerWebp(
              bytes: bytes,
              maxDurationMs: 10000,
            );
            newBytesList.add(processed.webpBytes);
          } else {
            newBytesList.add(bytes);
          }
        }
      }
      if (!mounted) return;

      setState(() {
        _multiSelectedBytes.addAll(newBytesList);
      });
    } catch (e) {
      if (mounted) {
        AppNotification.show(
          context,
          message: 'Gagal menambah media dari galeri: $e',
          isSuccess: false,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _processingMessage = null;
        });
      }
    }
  }

  Future<void> _pickFromCamera() async {
    final hasPermission = await _permissionService.requestCameraPermission(context);
    if (!hasPermission || !mounted) return;

    try {
      final xFile = await StickerImageProcessor.pickImage(source: ImageSource.camera);
      if (xFile != null && mounted) {
        final bytes = await xFile.readAsBytes();
        setState(() {
          _selectedImageBytes = bytes;
          _isAnimatedSticker = false;
          _multiSelectedBytes.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        AppNotification.show(
          context,
          message: 'Tidak dapat mengambil foto kamera: $e',
          isSuccess: false,
        );
      }
    }
  }

  void _removeMultiImageAt(int index) {
    if (index >= 0 && index < _multiSelectedBytes.length) {
      setState(() {
        _multiSelectedBytes.removeAt(index);
      });
    }
  }

  void _toggleEmoji(String emoji) {
    setState(() {
      if (_selectedEmojis.contains(emoji)) {
        if (_selectedEmojis.length > 1) {
          _selectedEmojis.remove(emoji);
        }
      } else {
        if (_selectedEmojis.length < 3) {
          _selectedEmojis.add(emoji);
        } else {
          _selectedEmojis[0] = emoji;
        }
      }
    });
  }

  Future<void> _saveSingleSticker() async {
    if (_selectedImageBytes == null) return;

    setState(() => _isProcessing = true);
    try {
      await StickerPackManager().addStickerToPack(
        packIdentifier: widget.packIdentifier,
        imageBytes: _selectedImageBytes!,
        emojis: _selectedEmojis,
      );

      if (mounted) {
        Navigator.of(context).pop(true);
        AppNotification.show(
          context,
          message: 'Stiker berhasil dibuat dan ditambahkan ke paket!',
          isSuccess: true,
        );
      }
    } catch (e) {
      if (mounted) {
        AppNotification.show(
          context,
          message: 'Gagal membuat stiker: $e',
          isSuccess: false,
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _saveMultipleStickers() async {
    if (_multiSelectedBytes.isEmpty) return;

    final total = _multiSelectedBytes.length;
    setState(() {
      _isProcessing = true;
      _processingCurrent = 0;
      _processingTotal = total;
    });

    try {
      await StickerPackManager().addMultipleStickersToPack(
        packIdentifier: widget.packIdentifier,
        imagesBytesList: _multiSelectedBytes,
        defaultEmojis: _selectedEmojis,
        onProgress: (current, totalCount) {
          if (mounted) {
            setState(() {
              _processingCurrent = current;
              _processingTotal = totalCount;
            });
          }
        },
      );

      if (mounted) {
        Navigator.of(context).pop(true);
        AppNotification.show(
          context,
          message: '$total stiker berhasil ditambahkan ke paket!',
          isSuccess: true,
        );
      }
    } catch (e) {
      if (mounted) {
        AppNotification.show(
          context,
          message: 'Gagal menyimpan stiker grup: $e',
          isSuccess: false,
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final remaining = _remainingSlots;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.withAlpha(80),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Sheet Title
            Text(
              _multiSelectedBytes.isNotEmpty
                  ? 'Grup Stiker (${_multiSelectedBytes.length} ${_isPackAnimated ? "Animasi" : "Foto"})'
                  : (_selectedImageBytes != null
                      ? (_isAnimatedSticker ? 'Pratinjau Stiker Animasi' : 'Pratinjau Stiker')
                      : (_isPackAnimated ? 'Tambah Stiker Animasi (Maks 10s)' : 'Tambah Stiker Baru')),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              _multiSelectedBytes.isNotEmpty
                  ? (_isPackAnimated
                      ? 'Animasi ini akan diproses otomatis ke format WebP sesuai standar WhatsApp (< 500 KB).'
                      : 'Foto-foto ini akan diproses otomatis ke format WebP sesuai standar WhatsApp (< 100 KB).')
                  : (_selectedImageBytes != null
                      ? (_isAnimatedSticker
                          ? 'Stiker animasi WebP bergerak otomatis (maks 10 detik, < 500 KB). Pilih emoji lalu simpan.'
                          : 'Sesuaikan emoji untuk stiker ini sebelum disimpan ke koleksi.')
                      : (_isPackAnimated
                          ? 'Pilih berkas GIF animasi atau video (maks 10 detik) untuk dijadikan stiker bergerak WhatsApp.'
                          : 'Pilih foto dari galeri atau ambil foto baru dengan kamera untuk dijadikan stiker WhatsApp.')),
              style: const TextStyle(color: Colors.grey, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),

            // Processing Indicator
            if (_isProcessing && _processingMessage != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 36.0, horizontal: 16.0),
                child: Column(
                  children: [
                    const SizedBox(
                      width: 44,
                      height: 44,
                      child: CircularProgressIndicator(
                        color: Color(0xFF25D366),
                        strokeWidth: 3,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _processingMessage!,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isPackAnimated
                          ? 'Sedang mengoptimalkan stiker agar memenuhi standar WhatsApp (durasi maks 10s, WebP 512x512, ukuran < 500 KB).'
                          : 'Sedang mengoptimalkan stiker agar memenuhi standar WhatsApp (WebP 512x512, ukuran < 100 KB).',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ]
            // 1. Initial State: Picker Options
            else if (_selectedImageBytes == null && _multiSelectedBytes.isEmpty) ...[
              if (_isPackAnimated) ...[
                // Panel Stiker Animasi: HANYA 1 BUTTON
                _PickerOptionCard(
                  icon: Icons.motion_photos_on_rounded,
                  label: 'Galeri Animasi (GIF / Video)',
                  subtitle: 'Pilih animasi GIF atau video (maks 10 detik)',
                  color: const Color(0xFF00A884),
                  isHorizontal: true,
                  onTap: _pickAnimatedMedia,
                ),
              ] else ...[
                // Panel Stiker Statis Biasa: HANYA 2 BUTTON (Galeri Foto dan Kamera)
                Row(
                  children: [
                    Expanded(
                      child: _PickerOptionCard(
                        icon: Icons.photo_library_rounded,
                        label: 'Galeri Foto',
                        subtitle: 'Bisa pilih banyak',
                        color: const Color(0xFF25D366),
                        onTap: _pickFromGallery,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _PickerOptionCard(
                        icon: Icons.camera_alt_rounded,
                        label: 'Kamera',
                        subtitle: 'Ambil foto',
                        color: const Color(0xFF128C7E),
                        onTap: _pickFromCamera,
                      ),
                    ),
                  ],
                ),
              ],
            ]
            // 2. Single Image Preview State
            else if (_selectedImageBytes != null) ...[
              Center(
                child: Stack(
                  children: [
                    Container(
                      width: 220,
                      height: 220,
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: _isAnimatedSticker ? const Color(0xFF00A884) : const Color(0xFF25D366),
                          width: 2.2,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Image.memory(
                        _selectedImageBytes!,
                        fit: BoxFit.contain,
                      ),
                    ),
                    if (_isAnimatedSticker)
                      Positioned(
                        top: 8,
                        left: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00A884).withAlpha(220),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.motion_photos_on_rounded, size: 12, color: Colors.white),
                              SizedBox(width: 4),
                              Text(
                                'Animasi ≤10s',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    Positioned(
                      bottom: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withAlpha(160),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${(_selectedImageBytes!.lengthInBytes / 1024).toStringAsFixed(0)} KB',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Material(
                        color: Colors.black.withAlpha(160),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => setState(() {
                            _selectedImageBytes = null;
                            _isAnimatedSticker = false;
                          }),
                          child: const Padding(
                            padding: EdgeInsets.all(6.0),
                            child: Icon(Icons.refresh_rounded, color: Colors.white, size: 18),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              // Emoji Selection Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Pilih Emoji Stiker (Maksimal 3)',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  Text(
                    'Terpilih: ${_selectedEmojis.join(" ")}',
                    style: const TextStyle(fontSize: 14),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Emoji Chips
              _buildEmojiChips(),
              const SizedBox(height: 22),

              // Save Single Button
              FilledButton.icon(
                onPressed: _isProcessing ? null : _saveSingleSticker,
                style: FilledButton.styleFrom(
                  backgroundColor: _isAnimatedSticker ? const Color(0xFF00A884) : const Color(0xFF25D366),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: _isProcessing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(_isAnimatedSticker ? Icons.motion_photos_on_rounded : Icons.check_circle_rounded),
                label: Text(
                  _isProcessing
                      ? 'Menyimpan...'
                      : (_isAnimatedSticker ? 'Simpan Stiker Animasi ke Paket' : 'Simpan ke Koleksi Stiker'),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
            ]
            // 3. Multi-Image (Group) Selection Preview State
            else if (_multiSelectedBytes.isNotEmpty) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Pratinjau (${_multiSelectedBytes.length} stiker)',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  Row(
                    children: [
                      if (_multiSelectedBytes.length < remaining)
                        TextButton.icon(
                          onPressed: _isProcessing ? null : _pickMoreFromGallery,
                          icon: const Icon(Icons.add_photo_alternate_rounded, size: 16),
                          label: const Text('+ Tambah'),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF25D366),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                        ),
                      TextButton(
                        onPressed: _isProcessing
                            ? null
                            : () => setState(() => _multiSelectedBytes.clear()),
                        child: const Text('Reset', style: TextStyle(color: Colors.redAccent)),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Thumbnails Grid
              Container(
                constraints: const BoxConstraints(maxHeight: 220),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white.withAlpha(10) : Colors.black.withAlpha(8),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Theme.of(context).dividerColor.withAlpha(30),
                  ),
                ),
                child: GridView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(10),
                  physics: const BouncingScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 1.0,
                  ),
                  itemCount: _multiSelectedBytes.length,
                  itemBuilder: (context, index) {
                    final bytes = _multiSelectedBytes[index];
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.memory(
                              bytes,
                              fit: BoxFit.contain,
                              cacheWidth: 150,
                              cacheHeight: 150,
                            ),
                          ),
                        ),
                        // Number badge
                        Positioned(
                          bottom: 3,
                          left: 3,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.black.withAlpha(160),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '#${index + 1}',
                              style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                        // Remove button
                        Positioned(
                          top: 2,
                          right: 2,
                          child: Material(
                            color: Colors.black.withAlpha(170),
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: _isProcessing ? null : () => _removeMultiImageAt(index),
                              child: const Padding(
                                padding: EdgeInsets.all(3.0),
                                child: Icon(Icons.close_rounded, size: 13, color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),

              // Emoji Selection Header for Group
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Pilih Emoji Grup (Maksimal 3)',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                  ),
                  Text(
                    'Terpilih: ${_selectedEmojis.join(" ")}',
                    style: const TextStyle(fontSize: 13.5),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Emoji Chips
              _buildEmojiChips(),
              const SizedBox(height: 16),

              // Processing indicator if running
              if (_isProcessing) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _processingTotal > 0 ? (_processingCurrent / _processingTotal) : null,
                    minHeight: 6,
                    backgroundColor: Colors.black12,
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF25D366)),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Mengompres & memproses stiker $_processingCurrent dari $_processingTotal (< 100 KB)...',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 14),
              ],

              // Save Batch Button
              FilledButton.icon(
                onPressed: _isProcessing ? null : _saveMultipleStickers,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF25D366),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: _isProcessing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.done_all_rounded),
                label: Text(
                  _isProcessing
                      ? 'Memproses $_processingCurrent/$_processingTotal Stiker...'
                      : 'Simpan ${_multiSelectedBytes.length} Stiker ke Paket',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEmojiChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _commonEmojis.map((emoji) {
        final isSelected = _selectedEmojis.contains(emoji);
        return ChoiceChip(
          label: Text(emoji, style: const TextStyle(fontSize: 18)),
          selected: isSelected,
          onSelected: (_) => _toggleEmoji(emoji),
          selectedColor: const Color(0xFF25D366).withAlpha(50),
          side: BorderSide(
            color: isSelected
                ? const Color(0xFF25D366)
                : Colors.grey.withAlpha(60),
          ),
        );
      }).toList(),
    );
  }
}

class _PickerOptionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final Color color;
  final VoidCallback onTap;
  final bool isHorizontal;

  const _PickerOptionCard({
    required this.icon,
    required this.label,
    this.subtitle,
    required this.color,
    required this.onTap,
    this.isHorizontal = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withAlpha(25),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: isHorizontal
              ? const EdgeInsets.symmetric(vertical: 20, horizontal: 20)
              : const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
          child: isHorizontal
              ? Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon, color: Colors.white, size: 28),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            label,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: color,
                            ),
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              subtitle!,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Icon(
                      Icons.arrow_forward_ios_rounded,
                      size: 16,
                      color: color.withAlpha(150),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon, color: Colors.white, size: 24),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12.5,
                        color: color,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

