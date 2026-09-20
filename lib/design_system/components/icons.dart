import 'package:flutter/widgets.dart';

enum DomovoyIconKind {
  compose,
  chat,
  usage,
  providers,
  folder,
  plus,
  send,
  lock,
  chevron,
}

class DomovoyIcon extends StatelessWidget {
  const DomovoyIcon(this.kind, {this.size = 16, this.color, super.key});

  final DomovoyIconKind kind;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved =
        color ??
        DefaultTextStyle.of(context).style.color ??
        const Color(0xFF000000);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _StrokeIconPainter(kind: kind, color: resolved),
      ),
    );
  }
}

class _StrokeIconPainter extends CustomPainter {
  const _StrokeIconPainter({required this.kind, required this.color});

  final DomovoyIconKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * (1.5 / 24)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final s = size.width / 24;
    Offset o(double x, double y) => Offset(x * s, y * s);

    switch (kind) {
      case DomovoyIconKind.compose:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(5 * s, 4 * s, 19 * s, 21 * s),
            Radius.circular(2 * s),
          ),
          paint,
        );
        canvas.drawLine(o(14, 4), o(22, 4), paint);
        canvas.drawLine(o(19, 2), o(22, 5), paint);
        canvas.drawLine(o(9, 15), o(19, 5), paint);
        canvas.drawLine(o(9, 15), o(5, 16), paint);
      case DomovoyIconKind.chat:
        final path = Path()
          ..moveTo(5 * s, 4 * s)
          ..lineTo(19 * s, 4 * s)
          ..quadraticBezierTo(21 * s, 4 * s, 21 * s, 6 * s)
          ..lineTo(21 * s, 16 * s)
          ..quadraticBezierTo(21 * s, 18 * s, 19 * s, 18 * s)
          ..lineTo(8 * s, 18 * s)
          ..lineTo(3 * s, 21 * s)
          ..lineTo(3 * s, 6 * s)
          ..quadraticBezierTo(3 * s, 4 * s, 5 * s, 4 * s);
        canvas.drawPath(path, paint);
      case DomovoyIconKind.usage:
        canvas.drawLine(o(4, 19), o(4, 12), paint);
        canvas.drawLine(o(12, 19), o(12, 5), paint);
        canvas.drawLine(o(20, 19), o(20, 9), paint);
      case DomovoyIconKind.providers:
        canvas.drawLine(o(4, 7), o(20, 7), paint);
        canvas.drawLine(o(4, 17), o(20, 17), paint);
        canvas.drawCircle(o(9, 7), 2.5 * s, paint);
        canvas.drawCircle(o(15, 17), 2.5 * s, paint);
      case DomovoyIconKind.folder:
        final path = Path()
          ..moveTo(3 * s, 7 * s)
          ..lineTo(3 * s, 5 * s)
          ..lineTo(9 * s, 5 * s)
          ..lineTo(11 * s, 8 * s)
          ..lineTo(21 * s, 8 * s)
          ..lineTo(21 * s, 20 * s)
          ..lineTo(3 * s, 20 * s)
          ..close();
        canvas.drawPath(path, paint);
      case DomovoyIconKind.plus:
        canvas.drawLine(o(12, 6), o(12, 18), paint);
        canvas.drawLine(o(6, 12), o(18, 12), paint);
      case DomovoyIconKind.send:
        canvas.drawLine(o(12, 19), o(12, 5), paint);
        canvas.drawLine(o(7, 10), o(12, 5), paint);
        canvas.drawLine(o(17, 10), o(12, 5), paint);
      case DomovoyIconKind.lock:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(5 * s, 10 * s, 19 * s, 21 * s),
            Radius.circular(2 * s),
          ),
          paint,
        );
        canvas.drawArc(
          Rect.fromLTRB(8 * s, 3 * s, 16 * s, 11 * s),
          3.14,
          3.14,
          false,
          paint,
        );
      case DomovoyIconKind.chevron:
        canvas.drawLine(o(8, 14), o(12, 10), paint);
        canvas.drawLine(o(16, 14), o(12, 10), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StrokeIconPainter oldDelegate) =>
      oldDelegate.kind != kind || oldDelegate.color != color;
}
