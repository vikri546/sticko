import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sticker_flutter/services/whatsapp_stickers_service.dart';

/// Widget displaying an individual sticker card inside a grid.
class StickerGridTile extends StatelessWidget {
  final StickerItem sticker;
  final String? filePath;
  final VoidCallback onDelete;

  const StickerGridTile({
    super.key,
    required this.sticker,
    required this.filePath,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final file = filePath != null ? File(filePath!) : null;
    final fileExists = file != null && file.existsSync();
    final fileBytes = fileExists ? file.lengthSync() : 0;
    final fileKb = (fileBytes / 1024).toStringAsFixed(0);

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).dividerColor.withAlpha(40),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(10),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [

          // Sticker Image
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(10.0),
              child: fileExists
                  ? Image.file(
                      file,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, _, _) => const Center(
                        child: Icon(Icons.broken_image_rounded, color: Colors.grey),
                      ),
                    )
                  : const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
            ),
          ),

          // Size Badge (top left)
          if (fileExists)
            Positioned(
              top: 5,
              left: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: fileBytes > (100 * 1024)
                      ? Colors.orange.shade900.withAlpha(220)
                      : Colors.black.withAlpha(130),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '$fileKb KB',
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),

          // Delete Button (top right)
          Positioned(
            top: 4,
            right: 4,
            child: Material(
              color: Colors.black.withAlpha(120),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _confirmDelete(context),
                child: const Padding(
                  padding: EdgeInsets.all(5.0),
                  child: Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),

          // Emoji Badge (bottom left)
          if (sticker.emojis.isNotEmpty)
            Positioned(
              bottom: 6,
              left: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(140),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  sticker.emojis.join(' '),
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Hapus Stiker Ini?'),
        content: const Text(
          'Stiker ini akan dihapus dari koleksi paket lokal.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Batal'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              Navigator.of(ctx).pop();
              onDelete();
            },
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
  }
}

