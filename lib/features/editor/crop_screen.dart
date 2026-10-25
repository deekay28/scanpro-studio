import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/storage.dart';
import '../../imaging/edge_detect.dart';
import '../../imaging/perspective.dart';
import '../../imaging/processor.dart';
import '../../shared/widgets.dart';
import 'crop_editor.dart';

class CropResult {
  final List<double>? corners;
  final int rotation;
  const CropResult(this.corners, this.rotation);
}

/// Manual four-corner crop with automatic detection, full-frame fallback,
/// 90° rotation and a live preview of the corrected result.
class CropScreen extends StatefulWidget {
  final String imagePath; // absolute path of the original
  final List<double>? initialCorners;
  final int rotation;
  const CropScreen({super.key, required this.imagePath, this.initialCorners, this.rotation = 0});

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  String? _preview;
  double _aspect = 0.75;
  late List<double> _corners = widget.initialCorners ?? quadToList(defaultQuad());
  late int _rotation = widget.rotation;
  bool _showResult = false;
  Uint8List? _result;
  String? _error;
  bool _detecting = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final out = AppStorage.instance.tempPath('crop_preview.jpg');
      final (w, h) = await makePreviewSource(widget.imagePath, out, maxDim: 1600);
      if (!mounted) return;
      setState(() {
        _preview = out;
        _aspect = w / h;
      });
    } catch (e) {
      setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _autoDetect() async {
    setState(() => _detecting = true);
    try {
      final a = await analyzeImage(widget.imagePath);
      if (!mounted) return;
      if (a.corners != null) {
        setState(() => _corners = a.corners!);
        showSnack(context, 'Document edges detected (${(a.detectionScore * 100).round()}% confidence)');
      } else {
        showSnack(context, 'No clear document edges found. Drag the corners manually.');
      }
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  Future<void> _renderResult() async {
    final src = _preview;
    if (src == null) return;
    setState(() => _result = null);
    try {
      final bytes = await renderPreview(src, PageEdit(corners: _corners, rotation: _rotation).toJson(), maxDim: 1200);
      if (mounted) setState(() => _result = bytes);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e));
    }
  }

  bool get _valid {
    final q = listToQuad(_corners);
    return isConvexQuad(orderQuad(q)) && polygonArea(q) > 0.01;
  }

  void _done() {
    if (!_valid) {
      showSnack(context, 'The selected area is not a valid quadrilateral.');
      return;
    }
    final ordered = quadToList(orderQuad(listToQuad(_corners)));
    final full = ordered.asMap().entries.every((e) => (e.value - quadToList(defaultQuad())[e.key]).abs() < 0.002);
    Navigator.pop(context, CropResult(full ? null : ordered, _rotation));
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Crop & rotate'),
        actions: [TextButton(onPressed: preview == null ? null : _done, child: const Text('Done'))],
      ),
      body: _error != null
          ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white)))
          : preview == null
              ? const Center(child: CircularProgressIndicator())
              : _showResult
                  ? Center(
                      child: _result == null
                          ? const CircularProgressIndicator()
                          : Padding(padding: const EdgeInsets.all(16), child: Image.memory(_result!, gaplessPlayback: true)),
                    )
                  : CornerCropEditor(
                      image: FileImage(File(preview)),
                      imageAspect: _aspect,
                      corners: _corners,
                      onChanged: (c) => setState(() => _corners = c),
                    ),
      bottomNavigationBar: SafeArea(
        child: Container(
          color: Theme.of(context).colorScheme.surface,
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              _tool(Icons.auto_fix_high, _detecting ? 'Detecting…' : 'Auto detect', _detecting ? null : _autoDetect),
              _tool(Icons.crop_free, 'Full page', () => setState(() => _corners = quadToList(defaultQuad()))),
              _tool(Icons.rotate_left, 'Left', () => setState(() => _rotation = (_rotation + 270) % 360)),
              _tool(Icons.rotate_right, 'Right', () => setState(() => _rotation = (_rotation + 90) % 360)),
              _tool(_showResult ? Icons.crop : Icons.visibility_outlined, _showResult ? 'Edit corners' : 'Preview', () {
                setState(() => _showResult = !_showResult);
                if (_showResult) _renderResult();
              }),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _tool(IconData icon, String label, VoidCallback? onTap) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: TextButton(
          onPressed: onTap,
          child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon), const SizedBox(height: 2), Text(label, style: const TextStyle(fontSize: 12))]),
        ),
      );
}
