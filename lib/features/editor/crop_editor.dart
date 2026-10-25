import 'package:flutter/material.dart';

/// Four-corner crop editor. Corners are normalised (0..1) TL, TR, BR, BL in
/// the coordinate system of the displayed image.
class CornerCropEditor extends StatefulWidget {
  final ImageProvider image;
  final double imageAspect; // width / height
  final List<double> corners;
  final ValueChanged<List<double>> onChanged;
  const CornerCropEditor({super.key, required this.image, required this.imageAspect, required this.corners, required this.onChanged});

  @override
  State<CornerCropEditor> createState() => _CornerCropEditorState();
}

class _CornerCropEditorState extends State<CornerCropEditor> {
  int? _drag;
  Offset? _dragPos;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) {
      const pad = 24.0;
      final maxW = box.maxWidth - pad * 2, maxH = box.maxHeight - pad * 2;
      var w = maxW, h = maxW / widget.imageAspect;
      if (h > maxH) {
        h = maxH;
        w = maxH * widget.imageAspect;
      }
      final left = (box.maxWidth - w) / 2, top = (box.maxHeight - h) / 2;
      final rect = Rect.fromLTWH(left, top, w, h);
      final c = widget.corners;
      Offset pt(int i) => Offset(rect.left + c[i * 2] * w, rect.top + c[i * 2 + 1] * h);

      void update(int i, Offset global) {
        final nx = ((global.dx - rect.left) / w).clamp(0.0, 1.0).toDouble();
        final ny = ((global.dy - rect.top) / h).clamp(0.0, 1.0).toDouble();
        final next = [...c];
        next[i * 2] = nx;
        next[i * 2 + 1] = ny;
        widget.onChanged(next);
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) {
          // Pick the nearest handle within reach.
          var best = -1;
          var bestD = 48.0;
          for (var i = 0; i < 4; i++) {
            final dd = (pt(i) - d.localPosition).distance;
            if (dd < bestD) {
              bestD = dd;
              best = i;
            }
          }
          if (best >= 0) {
            setState(() {
              _drag = best;
              _dragPos = d.localPosition;
            });
          }
        },
        onPanUpdate: (d) {
          final i = _drag;
          if (i == null) return;
          setState(() => _dragPos = d.localPosition);
          update(i, d.localPosition);
        },
        onPanEnd: (_) => setState(() {
          _drag = null;
          _dragPos = null;
        }),
        child: Stack(children: [
          Positioned.fromRect(rect: rect, child: Image(image: widget.image, fit: BoxFit.fill, gaplessPlayback: true)),
          Positioned.fill(child: CustomPaint(painter: _CropPainter([for (var i = 0; i < 4; i++) pt(i)], rect, _drag))),
          if (_drag != null && _dragPos != null)
            Builder(builder: (_) {
              final magLeft = (_dragPos!.dx - 55).clamp(0.0, box.maxWidth - 110).toDouble();
              final magTop = (_dragPos!.dy - 150).clamp(0.0, box.maxHeight - 110).toDouble();
              return Positioned(
                left: magLeft,
                top: magTop,
                child: RawMagnifier(
                  size: const Size(110, 110),
                  magnificationScale: 2.2,
                  focalPointOffset: Offset(_dragPos!.dx - (magLeft + 55), _dragPos!.dy - (magTop + 55)),
                  decoration: const MagnifierDecoration(
                    shape: CircleBorder(side: BorderSide(color: Colors.white, width: 2)),
                  ),
                ),
              );
            }),
        ]),
      );
    });
  }
}

class _CropPainter extends CustomPainter {
  final List<Offset> pts;
  final Rect imageRect;
  final int? active;
  _CropPainter(this.pts, this.imageRect, this.active);

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addPolygon(pts, true);
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(imageRect)
      ..addPath(path, Offset.zero);
    canvas.drawPath(shade, Paint()..color = Colors.black.withValues(alpha: 0.45));
    canvas.drawPath(
        path,
        Paint()
          ..color = Colors.lightBlueAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);
    for (var i = 0; i < 4; i++) {
      canvas.drawCircle(pts[i], active == i ? 16 : 12, Paint()..color = Colors.white);
      canvas.drawCircle(
          pts[i],
          active == i ? 16 : 12,
          Paint()
            ..color = Colors.lightBlueAccent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3);
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) => true;
}
