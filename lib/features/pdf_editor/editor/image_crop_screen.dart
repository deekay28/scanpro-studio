import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Rectangular crop. Returns the crop as a normalised rectangle (0..1).
class ImageCropScreen extends StatefulWidget {
  final Uint8List bytes;
  final double aspect; // image width / height
  const ImageCropScreen({super.key, required this.bytes, required this.aspect});

  @override
  State<ImageCropScreen> createState() => _ImageCropScreenState();
}

class _ImageCropScreenState extends State<ImageCropScreen> {
  Rect _r = const Rect.fromLTRB(0, 0, 1, 1);
  int? _corner; // 0 tl, 1 tr, 2 br, 3 bl, 4 move

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Crop image'), actions: [
        TextButton(onPressed: () => setState(() => _r = const Rect.fromLTRB(0, 0, 1, 1)), child: const Text('Reset')),
      ]),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: AspectRatio(
            aspectRatio: widget.aspect,
            child: LayoutBuilder(builder: (context, box) {
              final w = box.maxWidth, h = box.maxHeight;
              Offset px(Offset n) => Offset(n.dx * w, n.dy * h);
              final corners = [_r.topLeft, _r.topRight, _r.bottomRight, _r.bottomLeft];
              return GestureDetector(
                onPanStart: (d) {
                  final p = d.localPosition;
                  _corner = null;
                  for (var i = 0; i < 4; i++) {
                    if ((px(corners[i]) - p).distance < 32) _corner = i;
                  }
                  _corner ??= Rect.fromLTRB(_r.left * w, _r.top * h, _r.right * w, _r.bottom * h).contains(p) ? 4 : null;
                },
                onPanUpdate: (d) {
                  final c = _corner;
                  if (c == null) return;
                  final dx = d.delta.dx / w, dy = d.delta.dy / h;
                  setState(() {
                    var l = _r.left, t = _r.top, r = _r.right, b = _r.bottom;
                    switch (c) {
                      case 0:
                        l += dx;
                        t += dy;
                      case 1:
                        r += dx;
                        t += dy;
                      case 2:
                        r += dx;
                        b += dy;
                      case 3:
                        l += dx;
                        b += dy;
                      default:
                        final mx = dx.clamp(-l, 1 - r), my = dy.clamp(-t, 1 - b);
                        l += mx;
                        r += mx;
                        t += my;
                        b += my;
                    }
                    l = l.clamp(0.0, r - 0.05);
                    t = t.clamp(0.0, b - 0.05);
                    r = r.clamp(l + 0.05, 1.0);
                    b = b.clamp(t + 0.05, 1.0);
                    _r = Rect.fromLTRB(l, t, r, b);
                  });
                },
                child: Stack(fit: StackFit.expand, children: [
                  Image.memory(widget.bytes, fit: BoxFit.fill),
                  CustomPaint(painter: _CropPainter(_r)),
                ]),
              );
            }),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(onPressed: () => Navigator.pop(context, _r), child: const Text('Apply crop')),
        ),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  final Rect r;
  _CropPainter(this.r);

  @override
  void paint(Canvas canvas, Size size) {
    final rr = Rect.fromLTRB(r.left * size.width, r.top * size.height, r.right * size.width, r.bottom * size.height);
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(rr);
    canvas.drawPath(shade, Paint()..color = Colors.black54);
    canvas.drawRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white);
    for (final c in [rr.topLeft, rr.topRight, rr.bottomRight, rr.bottomLeft]) {
      canvas.drawCircle(c, 9, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) => old.r != r;
}
