import 'package:flutter/material.dart';
import 'package:sticker_flutter/services/app_update_service.dart';

/// Modal dialog strictly enforcing an application update.
/// Displays an iOS-style alert popup and switches to a clean progress bar during APK download.
class ForceUpdateDialog extends StatefulWidget {
  final String title;
  final String message;
  final String updateUrl;
  final String targetVersion;
  final List<String> changelog;
  final VoidCallback? onUpdatePressed;

  const ForceUpdateDialog({
    super.key,
    this.title = 'New version available',
    this.message = 'There are new features available,\nplease update your app',
    this.updateUrl = AppUpdateService.defaultStoreUrl,
    this.targetVersion = AppUpdateService.defaultCurrentVersion,
    this.changelog = const [],
    this.onUpdatePressed,
  });

  @override
  State<ForceUpdateDialog> createState() => _ForceUpdateDialogState();
}

class _ForceUpdateDialogState extends State<ForceUpdateDialog> {
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String? _errorMessage;

  Future<void> _startDownloadAndInstall() async {
    if (widget.onUpdatePressed != null) {
      widget.onUpdatePressed!();
      return;
    }

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
      _errorMessage = null;
    });

    try {
      await AppUpdateService.downloadAndInstallApk(
        apkUrl: widget.updateUrl,
        targetVersion: widget.targetVersion,
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _downloadProgress = progress;
            });
          }
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _errorMessage = 'Gagal mengunduh pembaruan. Silakan coba lagi.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // PopScope prevents back button or swipe-to-dismiss
    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40),
        elevation: 0,
        child: Container(
          width: 270,
          decoration: BoxDecoration(
            color: const Color(0xFFF2F2F2),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(40),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header & Text Content
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1C1C1E),
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      widget.message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF3C3C43),
                        height: 1.35,
                        letterSpacing: -0.2,
                      ),
                    ),
                    if (widget.changelog.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withAlpha(12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: Colors.black.withAlpha(22),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: widget.changelog.map((item) {
                            final clean = item
                                .trim()
                                .replaceFirst(RegExp(r'^[-•*]\s*'), '');
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 3),
                              child: Text(
                                '- $clean',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: Color(0xFF3C3C43),
                                  height: 1.35,
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _errorMessage!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.redAccent,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // Thin Divider
              const Divider(
                height: 1,
                thickness: 0.8,
                color: Color(0xFFD1D1D6),
              ),

              // Action Area: switches between "Update" button and clean Progress Bar
              if (_isDownloading)
                Container(
                  height: 46,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _downloadProgress > 0 ? _downloadProgress : null,
                      minHeight: 6,
                      backgroundColor: const Color(0xFFE5E5EA),
                      valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF007AFF)),
                    ),
                  ),
                )
              else
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _startDownloadAndInstall,
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(16),
                      bottomRight: Radius.circular(16),
                    ),
                    child: Container(
                      height: 46,
                      alignment: Alignment.center,
                      child: Text(
                        _errorMessage != null ? 'Coba Lagi' : 'Update',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF007AFF),
                          letterSpacing: -0.4,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
