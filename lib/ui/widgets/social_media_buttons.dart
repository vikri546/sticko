import 'package:flutter/material.dart';

/// Row of circular icon buttons for social media profiles:
/// Instagram, Facebook, TikTok, Twitter/X, and LinkedIn.
class SocialMediaButtonsRow extends StatelessWidget {
  final VoidCallback onTapInstagram;
  final VoidCallback onTapFacebook;
  final VoidCallback onTapTikTok;
  final VoidCallback onTapTwitter;
  final VoidCallback onTapLinkedIn;
  final bool isDark;

  const SocialMediaButtonsRow({
    super.key,
    required this.onTapInstagram,
    required this.onTapFacebook,
    required this.onTapTikTok,
    required this.onTapTwitter,
    required this.onTapLinkedIn,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildCircleButton(
          tooltip: 'Instagram',
          onTap: onTapInstagram,
          icon: const _InstagramIcon(),
        ),
        const SizedBox(width: 14),
        _buildCircleButton(
          tooltip: 'Facebook',
          onTap: onTapFacebook,
          icon: const Icon(
            Icons.facebook,
            size: 22,
            color: Color(0xFF1877F2),
          ),
        ),
        const SizedBox(width: 14),
        _buildCircleButton(
          tooltip: 'TikTok',
          onTap: onTapTikTok,
          icon: _TikTokIcon(isDark: isDark),
        ),
        const SizedBox(width: 14),
        _buildCircleButton(
          tooltip: 'Twitter / X',
          onTap: onTapTwitter,
          icon: _TwitterXIcon(isDark: isDark),
        ),
        const SizedBox(width: 14),
        _buildCircleButton(
          tooltip: 'LinkedIn',
          onTap: onTapLinkedIn,
          icon: const _LinkedInIcon(),
        ),
      ],
    );
  }

  Widget _buildCircleButton({
    required String tooltip,
    required VoidCallback onTap,
    required Widget icon,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          splashColor: const Color(0x33128C7E),
          highlightColor: const Color(0x1F128C7E),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDark ? const Color(0x1AFFFFFF) : const Color(0x0C000000),
              border: Border.all(
                color: isDark ? const Color(0x28FFFFFF) : const Color(0x18000000),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(isDark ? 30 : 12),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: icon,
          ),
        ),
      ),
    );
  }
}

/// Custom painted Instagram camera icon with modern gradient
class _InstagramIcon extends StatelessWidget {
  const _InstagramIcon();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 20,
      child: CustomPaint(
        painter: _InstagramPainter(),
      ),
    );
  }
}

class _InstagramPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const gradient = RadialGradient(
      center: Alignment(-0.8, 0.8),
      radius: 1.4,
      colors: [
        Color(0xFFFFDC80),
        Color(0xFFF77737),
        Color(0xFFF56040),
        Color(0xFFFD1D1D),
        Color(0xFFE1306C),
        Color(0xFFC13584),
        Color(0xFF833AB4),
        Color(0xFF5851DB),
      ],
    );

    final rect = Offset.zero & size;
    final strokePaint = Paint()
      ..shader = gradient.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..isAntiAlias = true;

    final fillPaint = Paint()
      ..shader = gradient.createShader(rect)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    // Outer rounded square
    final outerRRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(1, 1, size.width - 2, size.height - 2),
      const Radius.circular(5.5),
    );
    canvas.drawRRect(outerRRect, strokePaint);

    // Center lens circle
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      4.3,
      strokePaint,
    );

    // Top-right flash dot
    canvas.drawCircle(
      Offset(size.width - 4.8, 4.8),
      1.1,
      fillPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Custom painted TikTok icon
class _TikTokIcon extends StatelessWidget {
  final bool isDark;
  const _TikTokIcon({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 19,
      height: 19,
      child: CustomPaint(
        painter: _TikTokPainter(
          color: isDark ? Colors.white : const Color(0xFF111111),
        ),
      ),
    );
  }
}

class _TikTokPainter extends CustomPainter {
  final Color color;
  const _TikTokPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    canvas.save();
    canvas.scale(size.width / 24.0, size.height / 24.0);

    final path = Path();
    path.moveTo(19.59, 6.69);
    path.cubicTo(18.25, 6.64, 16.99, 5.86, 16.32, 4.68);
    path.cubicTo(15.96, 4.04, 15.82, 3.14, 15.82, 2.0);
    path.lineTo(12.37, 2.0);
    path.lineTo(12.37, 15.67);
    path.cubicTo(12.37, 17.27, 11.07, 18.56, 9.47, 18.56);
    path.cubicTo(7.87, 18.56, 6.58, 17.27, 6.58, 15.67);
    path.cubicTo(6.58, 14.07, 7.87, 12.78, 9.47, 12.78);
    path.cubicTo(9.8, 12.78, 10.12, 12.84, 10.42, 12.94);
    path.lineTo(10.42, 9.46);
    path.cubicTo(10.11, 9.41, 9.79, 9.38, 9.47, 9.38);
    path.cubicTo(6.0, 9.38, 3.14, 12.2, 3.14, 15.68);
    path.cubicTo(3.14, 19.16, 6.0, 22.0, 9.47, 22.0);
    path.cubicTo(12.94, 22.0, 15.82, 19.16, 15.82, 15.68);
    path.lineTo(15.82, 9.18);
    path.cubicTo(17.27, 10.22, 19.03, 10.74, 20.86, 10.74);
    path.lineTo(20.86, 7.28);
    path.cubicTo(20.43, 7.28, 20.01, 7.07, 19.59, 6.69);
    path.close();

    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Custom painted Twitter / X icon
class _TwitterXIcon extends StatelessWidget {
  final bool isDark;
  const _TwitterXIcon({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 17,
      height: 17,
      child: CustomPaint(
        painter: _TwitterXPainter(
          color: isDark ? Colors.white : const Color(0xFF0F1419),
        ),
      ),
    );
  }
}

class _TwitterXPainter extends CustomPainter {
  final Color color;
  const _TwitterXPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    canvas.save();
    canvas.scale(size.width / 24.0, size.height / 24.0);

    final path = Path()..fillType = PathFillType.evenOdd;
    path.moveTo(18.244, 2.25);
    path.lineTo(21.552, 2.25);
    path.lineTo(14.325, 10.51);
    path.lineTo(22.827, 21.75);
    path.lineTo(16.17, 21.75);
    path.lineTo(10.956, 14.933);
    path.lineTo(4.99, 21.75);
    path.lineTo(1.68, 21.75);
    path.lineTo(9.41, 12.915);
    path.lineTo(1.254, 2.25);
    path.lineTo(8.08, 2.25);
    path.lineTo(12.793, 8.481);
    path.close();

    // Inner cutout
    path.moveTo(17.083, 19.77);
    path.lineTo(18.916, 19.77);
    path.lineTo(7.084, 4.126);
    path.lineTo(5.117, 4.126);
    path.close();

    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Custom painted LinkedIn icon
class _LinkedInIcon extends StatelessWidget {
  const _LinkedInIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: const Color(0xFF0A66C2),
        borderRadius: BorderRadius.circular(3.5),
      ),
      alignment: Alignment.center,
      child: const Text(
        'in',
        style: TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.bold,
          height: 1.0,
          letterSpacing: -0.5,
        ),
      ),
    );
  }
}
