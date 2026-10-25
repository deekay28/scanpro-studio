import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../shared/widgets.dart';
import 'portrait_render.dart';

/// Manual correction of the automatic subject mask. Red tint marks what
/// will be replaced by the background colour.
class MaskRefineScreen extends StatefulWidget {
  final String imagePath;
  final int width;
  final int height;
  final Uint8List mask;
  final List<MaskStroke> strokes;
  const MaskRefineScreen({super.key, required this.imagePath, required this.width, required this.height, required this.mask, required this.strokes});

  @override
  State<MaskRefineScreen> createState() => _MaskRefineScreenState();
}

class _MaskRefineScreenState extends State<MaskRefineScreen> {
  late List<MaskStroke> _strokes = [...widget.strokes];
  List<double>? _current;
  bool _keep = true;
  double _radius = 0.03;
  Uint8List? _overlay;
  bool _rendering = false;

  @override
  void initState() {
    super.initState();
    _render();
  }

  Future<void> _render() async {
    if (_rendering) return;
    _rendering = true;
    try {
      final png = await maskOverlayPng(widget.mask, widget.width, widget.height, _strokes.map((e) => e.toJson()).toList());
      if (mounted) setState(() => _overlay = png);
    } finally {
      _rendering = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final aspect = widget.width / widget.height;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Refine edges'),
        actions: [
          IconButton(
            tooltip: 'Undo',
            onPressed: _strokes.isEmpty
                ? null
                : () {
                    setState(() => _strokes.removeLast());
                    _render();
                  },
            icon: const Icon(Icons.undo),
          ),
          TextButton(onPressed: () => Navigator.pop(context, _strokes), child: const Text('Done')),
        ],
      ),
      body: Column(children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('Paint "Keep" over hair, ears, glasses or clothing that was removed. Paint "Remove" over leftover background.',
              style: TextStyle(fontSize: 12)),
        ),
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: aspect,
              child: LayoutBuilder(builder: (ctx, box) {
                Offset n(Offset o) => Offset(o.dx / box.maxWidth, o.dy / box.maxHeight);
                return GestureDetector(
                  onPanStart: (d) {
                    final o = n(d.localPosition);
                    setState(() => _current = [o.dx, o.dy]);
                  },
                  onPanUpdate: (d) {
                    final o = n(d.localPosition);
                    setState(() => _current?.addAll([o.dx, o.dy]));
                  },
                  onPanEnd: (_) {
                    final c = _current;
                    if (c != null) {
                      setState(() {
                        _strokes.add(MaskStroke(c, _radius, _keep));
                        _current = null;
                      });
                      _render();
                    }
                  },
                  child: Stack(fit: StackFit.expand, children: [
                    Image.file(File(widget.imagePath), fit: BoxFit.fill),
                    if (_overlay != null) Image.memory(_overlay!, fit: BoxFit.fill, gaplessPlayback: true),
                    if (_current != null) CustomPaint(painter: _StrokePainter(_current!, _radius, _keep)),
                  ]),
                );
              }),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Keep'), icon: Icon(Icons.brush)),
                ButtonSegment(value: false, label: Text('Remove'), icon: Icon(Icons.auto_fix_off)),
              ],
              selected: {_keep},
              onSelectionChanged: (s) => setState(() => _keep = s.first),
            ),
            Expanded(
              child: LabeledSlider(
                label: 'Brush',
                value: _radius,
                min: 0.005,
                max: 0.1,
                format: (v) => '${(v * 100).round()}',
                onChanged: (v) => setState(() => _radius = v),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 12),
      ]),
    );
  }
}

class _StrokePainter extends CustomPainter {
  final List<double> pts;
  final double r;
  final bool keep;
  _StrokePainter(this.pts, this.r, this.keep);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = (keep ? Colors.green : Colors.red).withValues(alpha: 0.5)
      ..strokeWidth = r * 2 * size.width
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i + 1 < pts.length; i += 2) {
      final o = Offset(pts[i] * size.width, pts[i + 1] * size.height);
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _StrokePainter old) => true;
}
