import 'dart:io';

import 'package:flutter/material.dart';

import 'print_layout.dart';

/// Scaled preview of a print sheet. Drawing is derived from the same
/// millimetre layout used for export, with dimension labels.
class SheetPreview extends StatelessWidget {
  final SheetLayout layout;
  final SheetSpec spec;
  final String? photoPath;
  const SheetPreview({super.key, required this.layout, required this.spec, this.photoPath});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) {
      final aspect = layout.pageWmm / layout.pageHmm;
      var w = box.maxWidth, h = w / aspect;
      if (h > box.maxHeight) {
        h = box.maxHeight;
        w = h * aspect;
      }
      final k = w / layout.pageWmm; // px per mm on screen
      final img = photoPath == null ? null : FileImage(File(photoPath!));
      return Center(
        child: Container(
          width: w,
          height: h,
          decoration: BoxDecoration(color: Colors.white, boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black26)]),
          child: Stack(children: [
            for (final c in layout.cells)
              Positioned(
                left: (c.x + spec.borderMm) * k,
                top: (c.y + spec.borderMm) * k,
                width: (c.w - 2 * spec.borderMm) * k,
                height: (c.h - 2 * spec.borderMm) * k,
                child: img == null ? Container(color: Colors.grey.shade300) : Image(image: img, fit: BoxFit.fill, gaplessPlayback: true),
              ),
            Positioned.fill(child: CustomPaint(painter: _SheetOverlay(layout, spec, k))),
          ]),
        ),
      );
    });
  }
}

class _SheetOverlay extends CustomPainter {
  final SheetLayout l;
  final SheetSpec s;
  final double k;
  _SheetOverlay(this.l, this.s, this.k);

  @override
  void paint(Canvas canvas, Size size) {
    // Safe-margin outline.
    final m = s.marginMm * k;
    canvas.drawRect(
      Rect.fromLTRB(m, m, size.width - m, size.height - m),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.blue.withValues(alpha: 0.35)
        ..strokeWidth = 1,
    );
    if (s.cutLines) {
      final p = Paint()
        ..color = Colors.grey
        ..strokeWidth = 0.6;
      for (final c in l.cells) {
        canvas.drawRect(Rect.fromLTWH(c.x * k, c.y * k, c.w * k, c.h * k), p..style = PaintingStyle.stroke);
      }
    }
    if (l.cells.isNotEmpty) {
      final c = l.cells.first;
      final tp = TextPainter(
        text: TextSpan(
          text: '${_f(c.w)} × ${_f(c.h)} mm',
          style: const TextStyle(color: Colors.white, fontSize: 9, backgroundColor: Colors.black54),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(c.x * k + 2, c.y * k + 2));
    }
    final paper = TextPainter(
      text: TextSpan(text: '${_f(l.pageWmm)} × ${_f(l.pageHmm)} mm', style: const TextStyle(color: Colors.black54, fontSize: 9)),
      textDirection: TextDirection.ltr,
    )..layout();
    paper.paint(canvas, Offset(size.width - paper.width - 4, size.height - paper.height - 2));
  }

  static String _f(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  @override
  bool shouldRepaint(covariant _SheetOverlay old) => true;
}
