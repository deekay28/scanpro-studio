import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'photo_presets.dart';
import 'portrait_render.dart';

/// Interactive portrait framing: pinch to zoom, drag to position, with
/// head-size guides from the preset. The frame has the exact photo aspect.
class FrameEditor extends StatefulWidget {
  final String imagePath;
  final int imageWidth;
  final int imageHeight;
  final PhotoPreset preset;
  final PortraitCrop crop;
  final ValueChanged<PortraitCrop> onChanged;
  final int backgroundArgb;
  const FrameEditor({
    super.key,
    required this.imagePath,
    required this.imageWidth,
    required this.imageHeight,
    required this.preset,
    required this.crop,
    required this.onChanged,
    this.backgroundArgb = 0xFFFFFFFF,
  });

  @override
  State<FrameEditor> createState() => _FrameEditorState();
}

class _FrameEditorState extends State<FrameEditor> {
  PortraitCrop? _start;
  Offset? _startFocal;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) {
      final aspect = widget.preset.widthMm / widget.preset.heightMm;
      var fh = box.maxHeight - 16, fw = fh * aspect;
      if (fw > box.maxWidth - 16) {
        fw = box.maxWidth - 16;
        fh = fw / aspect;
      }
      final c = widget.crop;
      final s = fh / c.cropH;
      final a = c.angle * math.pi / 180;
      final m = Matrix4.identity()
        ..translate(fw / 2, fh / 2)
        ..rotateZ(-a)
        ..scale(s, s)
        ..translate(-c.cx, -c.cy);
      return Center(
        child: GestureDetector(
          onScaleStart: (d) {
            _start = widget.crop;
            _startFocal = d.localFocalPoint;
          },
          onScaleUpdate: (d) {
            final st = _start, sf = _startFocal;
            if (st == null || sf == null) return;
            final scale = fh / st.cropH;
            final delta = d.localFocalPoint - sf;
            // Screen delta -> source delta (rotate by +angle, divide by scale).
            final ca = math.cos(st.angle * math.pi / 180), sa = math.sin(st.angle * math.pi / 180);
            final dx = (ca * delta.dx - sa * delta.dy) / scale;
            final dy = (sa * delta.dx + ca * delta.dy) / scale;
            final newH = (st.cropH / d.scale).clamp(40.0, math.max(widget.imageWidth, widget.imageHeight) * 2.0).toDouble();
            widget.onChanged(st.copyWith(cx: st.cx - dx, cy: st.cy - dy, cropH: newH));
          },
          child: Container(
            width: fw,
            height: fh,
            decoration: BoxDecoration(border: Border.all(color: Theme.of(ctx).colorScheme.primary, width: 2)),
            child: ClipRect(
              child: Stack(children: [
                Positioned.fill(child: ColoredBox(color: Color(widget.backgroundArgb))),
                OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: 0,
                  minHeight: 0,
                  maxWidth: double.infinity,
                  maxHeight: double.infinity,
                  child: Transform(
                    transform: m,
                    child: SizedBox(
                      width: widget.imageWidth.toDouble(),
                      height: widget.imageHeight.toDouble(),
                      child: Image.file(File(widget.imagePath), fit: BoxFit.fill, cacheWidth: math.min(widget.imageWidth, 1800), gaplessPlayback: true),
                    ),
                  ),
                ),
                Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: GuidePainter(widget.preset)))),
              ]),
            ),
          ),
        ),
      );
    });
  }
}

/// Head-position guides: crown line, chin range, centre line and oval.
class GuidePainter extends CustomPainter {
  final PhotoPreset preset;
  GuidePainter(this.preset);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final line = Paint()
      ..color = Colors.cyanAccent.withValues(alpha: 0.9)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final dashed = Paint()
      ..color = Colors.orangeAccent.withValues(alpha: 0.9)
      ..strokeWidth = 1.2;
    final crown = preset.topMargin * h;
    final chinMin = (preset.topMargin + preset.headMin) * h;
    final chinMax = (preset.topMargin + preset.headMax) * h;
    canvas.drawLine(Offset(0, crown), Offset(w, crown), line);
    for (final y in [chinMin, chinMax]) {
      for (var x = 0.0; x < w; x += 8) {
        canvas.drawLine(Offset(x, y), Offset(math.min(w, x + 4), y), dashed);
      }
    }
    canvas.drawRect(Rect.fromLTRB(0, chinMin, w, chinMax), Paint()..color = Colors.orangeAccent.withValues(alpha: 0.08));
    for (var y = 0.0; y < h; y += 8) {
      canvas.drawLine(Offset(w / 2, y), Offset(w / 2, math.min(h, y + 4)), Paint()
        ..color = Colors.white54
        ..strokeWidth = 1);
    }
    final headH = (preset.headMin + preset.headMax) / 2 * h;
    final ovalW = headH * 0.74;
    canvas.drawOval(Rect.fromCenter(center: Offset(w / 2, crown + headH / 2), width: ovalW, height: headH), line);
    final tp = TextPainter(
      text: const TextSpan(text: 'crown', style: TextStyle(color: Colors.cyanAccent, fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(4, crown - tp.height - 1));
    final tp2 = TextPainter(
      text: const TextSpan(text: 'chin range', style: TextStyle(color: Colors.orangeAccent, fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp2.paint(canvas, Offset(4, chinMax + 1));
  }

  @override
  bool shouldRepaint(covariant GuidePainter old) => old.preset != preset;
}
