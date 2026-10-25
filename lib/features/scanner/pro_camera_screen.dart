import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/import_service.dart';
import '../../core/models.dart';
import '../../core/ocr_models.dart';
import '../../core/providers.dart';
import '../../imaging/edge_detect.dart';
import '../../imaging/image_ops.dart';
import '../../imaging/perspective.dart';
import '../../imaging/quality.dart';
import '../../shared/widgets.dart';
import 'scan_flow.dart';

/// Built-in document camera.
///
/// * Live preview with document-edge overlay (detection runs on a
///   downsampled luminance frame ~3 times per second).
/// * Auto-capture when a document is detected, stable and sharp.
/// * Manual shutter, torch/flash, tap-to-focus/expose, exposure slider.
/// * Every capture is written into the persistent scan session at once.
class ProCameraScreen extends ConsumerStatefulWidget {
  final ScanSessionData session;
  final bool bookMode;
  const ProCameraScreen({super.key, required this.session, this.bookMode = false});

  @override
  ConsumerState<ProCameraScreen> createState() => _ProCameraScreenState();
}

class _ProCameraScreenState extends ConsumerState<ProCameraScreen> with WidgetsBindingObserver {
  CameraController? _ctl;
  String? _error;
  bool _initializing = true;
  late ScanSessionData _session = widget.session;

  FlashMode _flash = FlashMode.off;
  double _minExp = 0, _maxExp = 0, _exp = 0;
  Offset? _focusPoint;

  // Live detection state.
  List<Pt>? _quad;
  List<Pt>? _prevQuad;
  int _stableFrames = 0;
  bool _sharp = false;
  DateTime _lastAnalysis = DateTime.fromMillisecondsSinceEpoch(0);
  bool _analyzing = false;
  bool _streaming = false;
  bool _capturing = false;
  bool _armed = true; // requires the document to change before next auto shot
  bool _autoCapture = true;
  String _hint = 'Point the camera at a document';
  int _processing = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _autoCapture = ref.read(settingsProvider).autoCapture && !widget.bookMode;
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _disposeController();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _ctl;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      if (c != null) {
        _ctl = null;
        _streaming = false;
        if (mounted) setState(() {});
        c.dispose();
      }
    } else if (state == AppLifecycleState.resumed && _ctl == null) {
      _init();
    }
  }

  Future<void> _disposeController() async {
    final c = _ctl;
    _ctl = null;
    _streaming = false;
    try {
      if (c != null && c.value.isStreamingImages) await c.stopImageStream();
    } catch (_) {}
    await c?.dispose();
  }

  Future<void> _init() async {
    setState(() {
      _initializing = true;
      _error = null;
    });
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw CameraException('NoCamera', 'No camera found on this device.');
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      final c = CameraController(back, ResolutionPreset.veryHigh, enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
      await c.initialize();
      try {
        _minExp = await c.getMinExposureOffset();
        _maxExp = await c.getMaxExposureOffset();
      } catch (_) {}
      try {
        await c.setFlashMode(FlashMode.off);
      } catch (_) {}
      if (!mounted) {
        await c.dispose();
        return;
      }
      _ctl = c;
      await _startStream();
      setState(() => _initializing = false);
    } on CameraException catch (e) {
      setState(() {
        _initializing = false;
        _error = switch (e.code) {
          'CameraAccessDenied' || 'CameraAccessDeniedWithoutPrompt' || 'CameraAccessRestricted' =>
            'Camera permission was denied. Allow camera access in Android Settings › Apps › ScanPro Studio › Permissions, or import photos instead.',
          _ => e.description ?? e.code,
        };
      });
    } catch (e) {
      setState(() {
        _initializing = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _startStream() async {
    final c = _ctl;
    if (c == null || _streaming) return;
    try {
      await c.startImageStream(_onFrame);
      _streaming = true;
    } catch (_) {
      _streaming = false; // live detection unavailable; manual capture still works
    }
  }

  Future<void> _stopStream() async {
    final c = _ctl;
    if (c == null || !_streaming) return;
    try {
      await c.stopImageStream();
    } catch (_) {}
    _streaming = false;
  }

  void _onFrame(CameraImage frame) {
    final now = DateTime.now();
    if (_analyzing || _capturing || now.difference(_lastAnalysis).inMilliseconds < 300) return;
    _analyzing = true;
    _lastAnalysis = now;
    try {
      final sensor = _ctl?.description.sensorOrientation ?? 90;
      final plane = frame.planes.first;
      final (gray, w, h) = _downsample(plane.bytes, frame.width, frame.height, plane.bytesPerRow, sensor);
      final det = detectDocumentQuad(gray, w, h);
      final sharpness = laplacianVariance(boxBlurU8(gray, w, h, 1), w, h);
      _sharp = sharpness > 18;
      _updateDetection(det);
    } catch (_) {
      // Ignore a bad frame.
    } finally {
      _analyzing = false;
    }
  }

  /// Builds a ~180 px wide gray image rotated to portrait.
  (Uint8List, int, int) _downsample(Uint8List y, int fw, int fh, int stride, int sensor) {
    final rotated = sensor == 90 || sensor == 270;
    final pw = rotated ? fh : fw, ph = rotated ? fw : fh;
    final step = math.max(1, pw ~/ 180);
    final sw = pw ~/ step, sh = ph ~/ step;
    final out = Uint8List(sw * sh);
    for (var py = 0; py < sh; py++) {
      for (var px = 0; px < sw; px++) {
        final ax = px * step, ay = py * step;
        int sx, sy;
        switch (sensor) {
          case 90:
            sx = ay;
            sy = fh - 1 - ax;
          case 270:
            sx = fw - 1 - ay;
            sy = ax;
          case 180:
            sx = fw - 1 - ax;
            sy = fh - 1 - ay;
          default:
            sx = ax;
            sy = ay;
        }
        final idx = sy * stride + sx;
        out[py * sw + px] = idx >= 0 && idx < y.length ? y[idx] : 0;
      }
    }
    return (out, sw, sh);
  }

  void _updateDetection(QuadDetection? det) {
    if (!mounted) return;
    final q = det?.quad;
    if (q == null) {
      _stableFrames = 0;
      _armed = true;
      setState(() {
        _quad = null;
        _hint = widget.bookMode ? 'Fit both pages inside the frame' : 'No document detected — move closer or use manual capture';
      });
      return;
    }
    final prev = _prevQuad;
    final moved = prev == null ? 1.0 : List.generate(4, (i) => q[i].dist(prev[i])).reduce(math.max);
    _prevQuad = q;
    if (moved < 0.025) {
      _stableFrames++;
    } else {
      _stableFrames = 0;
      if (moved > 0.08) _armed = true;
    }
    String hint;
    if (det!.touchesBorder) {
      hint = 'Edges cut off — move back a little';
    } else if (!_sharp) {
      hint = 'Hold steady — focusing';
    } else if (_stableFrames < 3) {
      hint = 'Hold steady…';
    } else {
      hint = _autoCapture && _armed ? 'Capturing…' : 'Ready — tap the shutter';
    }
    setState(() {
      _quad = q;
      _hint = hint;
    });
    if (_autoCapture && _armed && !det.touchesBorder && _sharp && _stableFrames >= 3 && det.score >= 0.6) {
      _armed = false;
      _capture(auto: true);
    }
  }

  Future<void> _capture({bool auto = false}) async {
    final c = _ctl;
    if (c == null || _capturing || !c.value.isInitialized) return;
    setState(() => _capturing = true);
    try {
      await _stopStream();
      final file = await c.takePicture();
      HapticFeedback.mediumImpact();
      _addCapture(file.path);
    } catch (e) {
      if (mounted) showSnack(context, 'Capture failed: $e');
    } finally {
      if (mounted) setState(() => _capturing = false);
      await _startStream();
    }
  }

  Future<void> _addCapture(String path) async {
    final repo = ref.read(repositoryProvider);
    setState(() => _processing++);
    try {
      final item = await ScanFlow.makeItem(repo, _session, path,
          detectCorners: !widget.bookMode, documentExpected: !widget.bookMode, existing: _session.items);
      _session = _session.copyWith(items: [..._session.items, item]);
      await repo.saveSession(_session);
      try {
        await File(path).delete();
      } catch (_) {}
      if (mounted && item.flags.isNotEmpty && ref.read(settingsProvider).qualityWarnings) {
        showSnack(context, 'Page ${_session.items.length}: ${item.flags.map(QualityFlag.label).join(', ')}');
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Could not save the photo: $e');
    } finally {
      if (mounted) setState(() => _processing--);
    }
  }

  Future<void> _importFromGallery() async {
    final picked = await ImportService.pickImages();
    for (final pth in picked) {
      final norm = await ImportService.normalize(pth);
      await _addCapture(norm.path);
    }
  }

  Future<void> _setFlash() async {
    final next = switch (_flash) { FlashMode.off => FlashMode.torch, FlashMode.torch => FlashMode.auto, _ => FlashMode.off };
    try {
      await _ctl?.setFlashMode(next);
      setState(() => _flash = next);
    } catch (_) {
      if (mounted) showSnack(context, 'Flash is not available on this camera');
    }
  }

  Future<void> _tapFocus(TapUpDetails d, BoxConstraints box) async {
    final c = _ctl;
    if (c == null) return;
    final p = Offset(d.localPosition.dx / box.maxWidth, d.localPosition.dy / box.maxHeight);
    setState(() => _focusPoint = d.localPosition);
    try {
      await c.setFocusPoint(p);
      await c.setExposurePoint(p);
    } catch (_) {}
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) setState(() => _focusPoint = null);
    });
  }

  void _finish() => Navigator.of(context).pop(_session);

  @override
  Widget build(BuildContext context) {
    final c = _ctl;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(children: [
            _topBar(),
            Expanded(
              child: _error != null
                  ? _errorView()
                  : (c == null || _initializing || !c.value.isInitialized)
                      ? const Center(child: CircularProgressIndicator())
                      : Center(
                          child: AspectRatio(
                            aspectRatio: 1 / c.value.aspectRatio,
                            child: LayoutBuilder(
                              builder: (ctx, box) => GestureDetector(
                                onTapUp: (d) => _tapFocus(d, box),
                                child: Stack(fit: StackFit.expand, children: [
                                  CameraPreview(c),
                                  CustomPaint(painter: _OverlayPainter(_quad, widget.bookMode, _stableFrames >= 3 && _sharp)),
                                  if (_focusPoint != null)
                                    Positioned(
                                      left: _focusPoint!.dx - 30,
                                      top: _focusPoint!.dy - 30,
                                      child: Container(
                                        width: 60,
                                        height: 60,
                                        decoration: BoxDecoration(border: Border.all(color: Colors.amber, width: 2), shape: BoxShape.circle),
                                      ),
                                    ),
                                  Positioned(
                                    left: 12,
                                    right: 12,
                                    top: 12,
                                    child: Center(
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                                        child: Text(_hint, style: const TextStyle(color: Colors.white)),
                                      ),
                                    ),
                                  ),
                                  if (_maxExp > _minExp)
                                    Positioned(
                                      right: 0,
                                      top: 60,
                                      bottom: 60,
                                      child: RotatedBox(
                                        quarterTurns: 3,
                                        child: Slider(
                                          value: _exp.clamp(_minExp, _maxExp).toDouble(),
                                          min: _minExp,
                                          max: _maxExp,
                                          onChanged: (v) async {
                                            setState(() => _exp = v);
                                            try {
                                              await _ctl?.setExposureOffset(v);
                                            } catch (_) {}
                                          },
                                        ),
                                      ),
                                    ),
                                ]),
                              ),
                            ),
                          ),
                        ),
            ),
            _bottomBar(),
          ]),
        ),
      ),
    );
  }

  Widget _topBar() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(children: [
          IconButton(onPressed: _finish, icon: const Icon(Icons.close, color: Colors.white), tooltip: 'Close'),
          const Spacer(),
          if (!widget.bookMode)
            TextButton.icon(
              onPressed: () => setState(() {
                _autoCapture = !_autoCapture;
                _armed = true;
              }),
              icon: Icon(_autoCapture ? Icons.motion_photos_auto : Icons.motion_photos_off, color: Colors.white),
              label: Text(_autoCapture ? 'Auto' : 'Manual', style: const TextStyle(color: Colors.white)),
            ),
          IconButton(
            onPressed: _setFlash,
            tooltip: 'Flash',
            icon: Icon(
              switch (_flash) { FlashMode.torch => Icons.flashlight_on, FlashMode.auto => Icons.flash_auto, _ => Icons.flash_off },
              color: Colors.white,
            ),
          ),
        ]),
      );

  Widget _bottomBar() {
    final n = _session.items.length;
    final last = n > 0 ? _session.items.last.path : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Row(children: [
        SizedBox(
          width: 64,
          height: 64,
          child: last == null
              ? IconButton(
                  onPressed: _importFromGallery,
                  icon: const Icon(Icons.photo_library_outlined, color: Colors.white),
                  tooltip: 'Import from gallery',
                )
              : Stack(children: [
                  Positioned.fill(
                    child: ClipRRect(borderRadius: BorderRadius.circular(8), child: StoredImage(last, cacheWidth: 160)),
                  ),
                  Positioned(
                    right: 2,
                    top: 2,
                    child: CircleAvatar(radius: 11, child: Text('$n', style: const TextStyle(fontSize: 11))),
                  ),
                ]),
        ),
        const Spacer(),
        Semantics(
          button: true,
          label: 'Capture page',
          child: GestureDetector(
            onTap: _capturing ? null : () => _capture(),
            child: Container(
              width: 78,
              height: 78,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
              padding: const EdgeInsets.all(5),
              child: Container(
                decoration: BoxDecoration(shape: BoxShape.circle, color: _capturing ? Colors.grey : Colors.white),
              ),
            ),
          ),
        ),
        const Spacer(),
        SizedBox(
          width: 64,
          child: FilledButton(
            onPressed: n == 0 && _processing == 0 ? null : (_processing > 0 ? null : _finish),
            style: FilledButton.styleFrom(padding: EdgeInsets.zero),
            child: _processing > 0
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Done'),
          ),
        ),
      ]),
    );
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.no_photography_outlined, color: Colors.white70, size: 56),
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: _init, child: const Text('Try again')),
            const SizedBox(height: 8),
            OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
              onPressed: _importFromGallery,
              child: const Text('Import photos instead'),
            ),
          ]),
        ),
      );
}

class _OverlayPainter extends CustomPainter {
  final List<Pt>? quad;
  final bool book;
  final bool ready;
  _OverlayPainter(this.quad, this.book, this.ready);

  @override
  void paint(Canvas canvas, Size size) {
    final guide = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final inset = size.width * 0.06;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(inset, inset * 2, size.width - inset, size.height - inset * 2), const Radius.circular(12)), guide);
    if (book) {
      canvas.drawLine(Offset(size.width / 2, inset * 2), Offset(size.width / 2, size.height - inset * 2), guide);
    }
    final q = quad;
    if (q == null) return;
    final color = ready ? Colors.greenAccent : Colors.lightBlueAccent;
    final path = Path()..moveTo(q[0].x * size.width, q[0].y * size.height);
    for (var i = 1; i < 4; i++) {
      path.lineTo(q[i].x * size.width, q[i].y * size.height);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.18));
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);
    for (final p in q) {
      canvas.drawCircle(Offset(p.x * size.width, p.y * size.height), 6, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) => old.quad != quad || old.ready != ready;
}
