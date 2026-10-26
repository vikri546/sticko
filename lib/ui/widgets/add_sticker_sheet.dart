import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sticker_flutter/services/app_permission_service.dart';
import 'package:sticker_flutter/services/sticker_image_processor.dart';
import 'package:sticker_flutter/services/sticker_pack_manager.dart';
import 'package:sticker_flutter/ui/widgets/app_notification.dart';

enum _CropMode {
  fit,    // Kotak 1:1, seluruh gambar masuk kanvas
  fill,   // Kotak 1:1, gambar memenuhi seluruh kanvas
  circle, // Masking bulat/lingkaran
}

/// Modal bottom sheet to pick single or multiple images, preview, tag with emojis, and add to pack.
class AddStickerSheet extends StatefulWidget {
  final String packIdentifier;
  final Uint8List? initialImageBytes;

  const AddStickerSheet({
    super.key,
    required this.packIdentifier,
    this.initialImageBytes,
  });

  @override
  State<AddStickerSheet> createState() => _AddStickerSheetState();
}

class _AddStickerSheetState extends State<AddStickerSheet> {
  final _permissionService = AppPermissionService();

  // Single-selection mode & Edit state
  static const double _canvasSize = 240.0;
  final GlobalKey _previewKey = GlobalKey();
  final TransformationController _transformationController = TransformationController();
  final TextEditingController _topTextController = TextEditingController();
  final TextEditingController _bottomTextController = TextEditingController();

  _CropMode _cropMode = _CropMode.fit;
  int _quarterTurns = 0;
  bool _isFlipped = false;
  double _currentScale = 1.0;
  bool _showTextEditor = false;
  bool _hasBlackStroke = true;

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

  @override
  void initState() {
    super.initState();
    _transformationController.addListener(_onTransformationChanged);
    if (widget.initialImageBytes != null) {
      _selectedImageBytes = widget.initialImageBytes;
    }
  }

  @override
  void dispose() {
    _transformationController.removeListener(_onTransformationChanged);
    _transformationController.dispose();
    _topTextController.dispose();
    _bottomTextController.dispose();
    super.dispose();
  }

  void _onTransformationChanged() {
    final scale = _transformationController.value.getMaxScaleOnAxis();
    if ((scale - _currentScale).abs() > 0.05) {
      setState(() {
        _currentScale = scale.clamp(0.5, 3.5);
      });
    }
  }

  void _onSliderZoomChanged(double newScale) {
    setState(() {
      _currentScale = newScale;
      _transformationController.value = Matrix4.diagonal3Values(newScale, newScale, 1.0);
    });
  }

  void _resetTransform() {
    setState(() {
      _currentScale = 1.0;
      _quarterTurns = 0;
      _isFlipped = false;
      _cropMode = _CropMode.fit;
      _transformationController.value = Matrix4.identity();
    });
  }

  void _resetEditState() {
    _cropMode = _CropMode.fit;
    _quarterTurns = 0;
    _isFlipped = false;
    _currentScale = 1.0;
    _transformationController.value = Matrix4.identity();
    _topTextController.clear();
    _bottomTextController.clear();
    _showTextEditor = false;
    _hasBlackStroke = true;
  }

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
          _resetEditState();
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
            _resetEditState();
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
          _resetEditState();
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

  Future<Uint8List?> _renderEditedStickerBytes() async {
    if (_selectedImageBytes == null) return null;
    if (_isAnimatedSticker) return _selectedImageBytes;

    try {
      final boundary = _previewKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return _selectedImageBytes;

      final pixelRatio = 512.0 / _canvasSize;
      final uiImage = await boundary.toImage(pixelRatio: pixelRatio);
      final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return _selectedImageBytes;

      return byteData.buffer.asUint8List();
    } catch (e) {
      debugPrint('Error rendering edited sticker: $e');
      return _selectedImageBytes;
    }
  }

  Future<void> _saveSingleSticker() async {
    if (_selectedImageBytes == null) return;

    setState(() => _isProcessing = true);
    try {
      final imageBytesToSave = await _renderEditedStickerBytes() ?? _selectedImageBytes!;
      await StickerPackManager().addStickerToPack(
        packIdentifier: widget.packIdentifier,
        imageBytes: imageBytesToSave,
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
            // 2. Single Image Preview State with Interactive Edit, Crop & Meme Text
            else if (_selectedImageBytes != null) ...[
              Center(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Outer Canvas with Checkerboard Background
                    Container(
                      width: _canvasSize,
                      height: _canvasSize,
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(_cropMode == _CropMode.circle ? _canvasSize / 2 : 18),
                        border: Border.all(
                          color: _isAnimatedSticker ? const Color(0xFF00A884) : const Color(0xFF25D366),
                          width: 2.2,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // 1. Checkerboard Pattern (outside RepaintBoundary so transparent areas are visible)
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _CheckerboardPainter(
                                color1: isDark ? const Color(0x22FFFFFF) : const Color(0x18000000),
                                color2: isDark ? const Color(0x0DFFFFFF) : const Color(0x06000000),
                              ),
                            ),
                          ),

                          // 2. RepaintBoundary captures EXACT 512x512 rendered result with transparent background
                          RepaintBoundary(
                            key: _previewKey,
                            child: Container(
                              width: _canvasSize,
                              height: _canvasSize,
                              clipBehavior: Clip.antiAlias,
                              decoration: BoxDecoration(
                                color: Colors.transparent,
                                shape: _cropMode == _CropMode.circle ? BoxShape.circle : BoxShape.rectangle,
                              ),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  if (_isAnimatedSticker)
                                    Image.memory(
                                      _selectedImageBytes!,
                                      fit: BoxFit.contain,
                                    )
                                  else
                                    InteractiveViewer(
                                      transformationController: _transformationController,
                                      minScale: 0.5,
                                      maxScale: 4.0,
                                      boundaryMargin: const EdgeInsets.all(120.0),
                                      clipBehavior: Clip.none,
                                      child: RotatedBox(
                                        quarterTurns: _quarterTurns,
                                        child: Transform.scale(
                                          scaleX: _isFlipped ? -1 : 1,
                                          child: Image.memory(
                                            _selectedImageBytes!,
                                            fit: _cropMode == _CropMode.fill ? BoxFit.cover : BoxFit.contain,
                                          ),
                                        ),
                                      ),
                                    ),

                                  // Top Text Overlay (Roboto Bold, Uppercase, White, Black Stroke)
                                  if (!_isAnimatedSticker && _topTextController.text.trim().isNotEmpty)
                                    Positioned(
                                      top: 10,
                                      left: 10,
                                      right: 10,
                                      child: _buildStickerText(_topTextController.text.trim()),
                                    ),

                                  // Bottom Text Overlay (Roboto Bold, Uppercase, White, Black Stroke)
                                  if (!_isAnimatedSticker && _bottomTextController.text.trim().isNotEmpty)
                                    Positioned(
                                      bottom: 10,
                                      left: 10,
                                      right: 10,
                                      child: _buildStickerText(_bottomTextController.text.trim()),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Badges & Action Buttons (OUTSIDE RepaintBoundary so they are not captured in sticker)
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
                            _resetEditState();
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

              // Editing Tools for Static Stickers
              if (!_isAnimatedSticker) ...[
                const SizedBox(height: 12),

                // Quick Tool Action Bar (Fit, Putar, Mirror, Teks, Reset)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1F2C34) : const Color(0xFFF0F2F5),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      // Fit Mode Button (Fit Kotak, Fill Penuh, Bulat)
                      _ToolIconButton(
                        icon: _cropMode == _CropMode.fit
                            ? Icons.fit_screen_rounded
                            : (_cropMode == _CropMode.fill ? Icons.crop_free_rounded : Icons.circle_outlined),
                        label: _cropMode == _CropMode.fit
                            ? 'Fit'
                            : (_cropMode == _CropMode.fill ? 'Penuh' : 'Bulat'),
                        isActive: true,
                        onTap: () {
                          setState(() {
                            if (_cropMode == _CropMode.fit) {
                              _cropMode = _CropMode.fill;
                            } else if (_cropMode == _CropMode.fill) {
                              _cropMode = _CropMode.circle;
                            } else {
                              _cropMode = _CropMode.fit;
                            }
                          });
                        },
                      ),
                      // Rotate Button (0° -> 90° -> 180° -> 270°)
                      _ToolIconButton(
                        icon: Icons.rotate_right_rounded,
                        label: 'Putar ${_quarterTurns * 90}°',
                        isActive: _quarterTurns > 0,
                        onTap: () {
                          setState(() {
                            _quarterTurns = (_quarterTurns + 1) % 4;
                          });
                        },
                      ),
                      // Mirror Button (Flip Horizontal)
                      _ToolIconButton(
                        icon: Icons.flip_rounded,
                        label: 'Mirror',
                        isActive: _isFlipped,
                        onTap: () {
                          setState(() {
                            _isFlipped = !_isFlipped;
                          });
                        },
                      ),
                      // Text Editor Toggle Button
                      _ToolIconButton(
                        icon: Icons.text_fields_rounded,
                        label: 'Teks',
                        isActive: _showTextEditor || _topTextController.text.isNotEmpty || _bottomTextController.text.isNotEmpty,
                        onTap: () {
                          setState(() {
                            _showTextEditor = !_showTextEditor;
                          });
                        },
                      ),
                      // Reset Transform Button
                      _ToolIconButton(
                        icon: Icons.restart_alt_rounded,
                        label: 'Reset',
                        isActive: false,
                        onTap: _resetTransform,
                      ),
                    ],
                  ),
                ),

                // Zoom Slider Row
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.zoom_out_rounded, size: 18, color: Colors.grey),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          ),
                          child: Slider(
                            value: _currentScale,
                            min: 0.5,
                            max: 3.5,
                            activeColor: const Color(0xFF25D366),
                            onChanged: _onSliderZoomChanged,
                          ),
                        ),
                      ),
                      const Icon(Icons.zoom_in_rounded, size: 18, color: Colors.grey),
                      const SizedBox(width: 6),
                      Text(
                        '${(_currentScale * 100).toInt()}%',
                        style: const TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),

                // Expandable Meme Text Editor Card
                if (_showTextEditor) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1F2C34) : const Color(0xFFF8F9FA),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFF25D366).withAlpha(80),
                        width: 1.2,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.title_rounded, size: 18, color: Color(0xFF25D366)),
                                SizedBox(width: 6),
                                Text(
                                  'Teks Stiker (Roboto Bold)',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                              ],
                            ),
                            // Black stroke toggle
                            InkWell(
                              borderRadius: BorderRadius.circular(20),
                              onTap: () => setState(() => _hasBlackStroke = !_hasBlackStroke),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                child: Row(
                                  children: [
                                    Text(
                                      'Stroke Hitam',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                        color: _hasBlackStroke ? const Color(0xFF25D366) : Colors.grey,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(
                                      _hasBlackStroke ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                                      size: 18,
                                      color: _hasBlackStroke ? const Color(0xFF25D366) : Colors.grey,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),

                        // Quick Position Helpers
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              _QuickTextChip(
                                label: 'Atas & Bawah',
                                onTap: () {},
                              ),
                              const SizedBox(width: 6),
                              _QuickTextChip(
                                label: 'Hanya Atas',
                                onTap: () {
                                  _bottomTextController.clear();
                                  setState(() {});
                                },
                              ),
                              const SizedBox(width: 6),
                              _QuickTextChip(
                                label: 'Hanya Bawah',
                                onTap: () {
                                  _topTextController.clear();
                                  setState(() {});
                                },
                              ),
                              const SizedBox(width: 6),
                              _QuickTextChip(
                                label: 'Hapus Teks',
                                onTap: () {
                                  _topTextController.clear();
                                  _bottomTextController.clear();
                                  setState(() {});
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),

                        // Input Teks Atas
                        TextField(
                          controller: _topTextController,
                          textCapitalization: TextCapitalization.characters,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'Teks Atas (Opsional)...',
                            hintStyle: const TextStyle(fontSize: 12),
                            prefixIcon: const Icon(Icons.vertical_align_top_rounded, size: 18),
                            suffixIcon: _topTextController.text.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear, size: 16),
                                    onPressed: () {
                                      _topTextController.clear();
                                      setState(() {});
                                    },
                                  )
                                : null,
                            filled: true,
                            fillColor: isDark ? const Color(0xFF2A3942) : Colors.white,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),

                        // Input Teks Bawah
                        TextField(
                          controller: _bottomTextController,
                          textCapitalization: TextCapitalization.characters,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'Teks Bawah (Opsional)...',
                            hintStyle: const TextStyle(fontSize: 12),
                            prefixIcon: const Icon(Icons.vertical_align_bottom_rounded, size: 18),
                            suffixIcon: _bottomTextController.text.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear, size: 16),
                                    onPressed: () {
                                      _bottomTextController.clear();
                                      setState(() {});
                                    },
                                  )
                                : null,
                            filled: true,
                            fillColor: isDark ? const Color(0xFF2A3942) : Colors.white,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
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

  Widget _buildStickerText(String text) {
    final upperText = text.toUpperCase();
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (_hasBlackStroke)
            Text(
              upperText,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: GoogleFonts.roboto(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 4.5
                  ..strokeCap = StrokeCap.round
                  ..strokeJoin = StrokeJoin.round
                  ..color = Colors.black,
              ),
            ),
          Text(
            upperText,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: GoogleFonts.roboto(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              shadows: _hasBlackStroke
                  ? null
                  : const [
                      Shadow(
                        blurRadius: 4.0,
                        color: Colors.black54,
                        offset: Offset(1.0, 1.0),
                      ),
                    ],
            ),
          ),
        ],
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

class _ToolIconButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _ToolIconButton({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeColor = const Color(0xFF25D366);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isActive ? activeColor.withAlpha(35) : (isDark ? Colors.white10 : Colors.black.withAlpha(12)),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 20,
                color: isActive ? activeColor : (isDark ? Colors.white70 : Colors.black87),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                color: isActive ? activeColor : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickTextChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _QuickTextChip({
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2A3942) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Colors.grey.withAlpha(50),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _CheckerboardPainter extends CustomPainter {
  final Color color1;
  final Color color2;
  static const double cellSize = 12.0;

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

