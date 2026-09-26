import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// A simple, high-contrast vector bottle used when there is no medication yet.
/// The cap, bottle shoulder and label make it read as medicine storage rather
/// than a pill, minus icon or disabled control.
class MedicineBottleIllustration extends StatelessWidget {
  final double size;

  const MedicineBottleIllustration({super.key, this.size = 88});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      image: true,
      label: 'Medicine bottle illustration',
      child: SizedBox(
        width: size,
        height: size * 1.12,
        child: CustomPaint(painter: _MedicineBottlePainter(isDark: isDark)),
      ),
    );
  }
}

class _MedicineBottlePainter extends CustomPainter {
  final bool isDark;

  const _MedicineBottlePainter({required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 88;
    canvas.save();
    canvas.scale(scale, scale);

    final outline = isDark ? AppTheme.darkTextPrimary : AppTheme.inkText;
    final bottle = isDark ? AppTheme.darkCardSurface : Colors.white;
    final paper = isDark ? AppTheme.darkSurface : AppTheme.paper;
    final cap = isDark ? AppTheme.darkFoil : AppTheme.foil;
    final label = isDark ? AppTheme.darkAccentGreen : AppTheme.ink;

    final shadow = Paint()
      ..color = cap.withValues(alpha: 0.18)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawOval(Rect.fromLTWH(12, 101, 64, 10), shadow);

    final bottlePaint = Paint()..color = bottle;
    final bottlePath = Path()
      ..moveTo(20, 34)
      ..lineTo(68, 34)
      ..lineTo(68, 43)
      ..cubicTo(68, 48, 75, 51, 75, 59)
      ..lineTo(75, 99)
      ..quadraticBezierTo(75, 104, 70, 104)
      ..lineTo(18, 104)
      ..quadraticBezierTo(13, 104, 13, 99)
      ..lineTo(13, 59)
      ..cubicTo(13, 51, 20, 48, 20, 43)
      ..close();
    canvas.drawPath(bottlePath, bottlePaint);
    canvas.drawPath(
      bottlePath,
      Paint()
        ..color = outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    final capRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(18, 14, 52, 25),
      const Radius.circular(7),
    );
    canvas.drawRRect(capRect, Paint()..color = cap);
    canvas.drawRRect(
      capRect,
      Paint()
        ..color = outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    final capLine = Paint()
      ..color = outline.withValues(alpha: 0.36)
      ..strokeWidth = 1.5;
    for (var x = 27.0; x <= 61; x += 8) {
      canvas.drawLine(Offset(x, 19), Offset(x, 34), capLine);
    }

    final labelRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(20, 53, 48, 36),
      const Radius.circular(5),
    );
    canvas.drawRRect(labelRect, Paint()..color = paper);
    canvas.drawRRect(
      labelRect,
      Paint()
        ..color = cap
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    final cross = Paint()
      ..color = label
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(31, 64), const Offset(43, 64), cross);
    canvas.drawLine(const Offset(37, 58), const Offset(37, 70), cross);

    final line = Paint()
      ..color = outline.withValues(alpha: 0.64)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(48, 60), const Offset(61, 60), line);
    canvas.drawLine(const Offset(48, 66), const Offset(61, 66), line);
    canvas.drawLine(const Offset(29, 78), const Offset(59, 78), line);
    canvas.drawLine(const Offset(29, 83), const Offset(52, 83), line);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MedicineBottlePainter oldDelegate) {
    return oldDelegate.isDark != isDark;
  }
}
