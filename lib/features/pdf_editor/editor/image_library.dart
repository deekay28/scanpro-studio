import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../../core/ids.dart';
import '../../../core/storage.dart';

/// Reusable images kept privately in app storage: saved signatures and
/// images other parts of the app hand to the PDF editor (passport photos,
/// seals, logos). Nothing here leaves the device.
class ImageLibrary {
  final String folder;
  const ImageLibrary._(this.folder);

  static const signatures = ImageLibrary._('signatures_img');
  static const images = ImageLibrary._('editor_images');

  Directory get dir => Directory(AppStorage.instance.abs(folder));

  Future<List<File>> list() async {
    if (!await dir.exists()) return const [];
    final files = (await dir.list().toList()).whereType<File>().where((f) => f.path.endsWith('.png') || f.path.endsWith('.jpg')).toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return files;
  }

  Future<File> save(Uint8List bytes, {String ext = 'png', String? label}) async {
    await dir.create(recursive: true);
    final name = '${newId()}${label == null ? '' : '_${label.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')}'}.$ext';
    final f = File(p.join(dir.path, name));
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  Future<void> delete(File f) async {
    if (await f.exists()) await f.delete();
  }

  /// Signatures drawn with the older annotation tool are stored as stroke
  /// lists; they are converted once so they can be reused here.
  static Future<void> migrateStrokeSignatures() async {
    final old = Directory(AppStorage.instance.abs('signatures'));
    if (!await old.exists()) return;
    for (final f in (await old.list().toList()).whereType<File>().where((f) => f.path.endsWith('.json'))) {
      final marker = File('${f.path}.migrated');
      if (await marker.exists()) continue;
      try {
        final pts = (jsonDecode(await f.readAsString()) as List).map((e) => e == null ? double.nan : (e as num).toDouble()).toList();
        final strokes = <List<ui.Offset>>[];
        var cur = <ui.Offset>[];
        for (var i = 0; i + 1 < pts.length; i += 2) {
          if (pts[i].isNaN) {
            if (cur.isNotEmpty) strokes.add(cur);
            cur = [];
            continue;
          }
          cur.add(ui.Offset(pts[i] * 1000, pts[i + 1] * 400));
        }
        if (cur.isNotEmpty) strokes.add(cur);
        final png = await renderStrokesPng(strokes, color: const ui.Color(0xFF0D1B6E), width: 6);
        if (png != null) await signatures.save(png, label: 'signature');
        await marker.writeAsString('');
      } catch (_) {}
    }
  }
}

/// Renders pen strokes to a tightly cropped PNG with a transparent
/// background.
Future<Uint8List?> renderStrokesPng(List<List<ui.Offset>> strokes, {required ui.Color color, double width = 5, double scale = 2}) async {
  final pts = [for (final s in strokes) ...s];
  if (pts.isEmpty) return null;
  var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
  for (final o in pts) {
    minX = math.min(minX, o.dx);
    minY = math.min(minY, o.dy);
    maxX = math.max(maxX, o.dx);
    maxY = math.max(maxY, o.dy);
  }
  final pad = width * 2;
  final w = ((maxX - minX + 2 * pad) * scale).ceil().clamp(1, 4000);
  final h = ((maxY - minY + 2 * pad) * scale).ceil().clamp(1, 4000);
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  c.scale(scale);
  c.translate(pad - minX, pad - minY);
  final paint = ui.Paint()
    ..color = color
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = ui.StrokeCap.round
    ..strokeJoin = ui.StrokeJoin.round;
  for (final s in strokes) {
    if (s.length == 1) {
      c.drawCircle(s.first, width / 2, paint..style = ui.PaintingStyle.fill);
      paint.style = ui.PaintingStyle.stroke;
      continue;
    }
    final path = ui.Path()..moveTo(s.first.dx, s.first.dy);
    for (var i = 1; i < s.length; i++) {
      final a = s[i - 1], b = s[i];
      final mid = (a + b) / 2;
      path.quadraticBezierTo(a.dx, a.dy, mid.dx, mid.dy);
    }
    path.lineTo(s.last.dx, s.last.dy);
    c.drawPath(path, paint);
  }
  final image = await rec.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data?.buffer.asUint8List();
}

/// Cleans an imported signature/stamp photo: pixels close to the paper
/// colour become transparent, ink is kept, and the result is cropped to the
/// ink. [threshold] is 0..1 (higher removes more).
Future<Uint8List> cleanSignatureImage(Uint8List bytes, {double threshold = 0.25, bool recolor = false}) =>
    compute(_clean, (bytes, threshold, recolor));

Uint8List _clean((Uint8List, double, bool) args) {
  final (bytes, threshold, recolor) = args;
  var src = img.decodeImage(bytes);
  if (src == null) throw const FormatException('Unsupported image.');
  if (math.max(src.width, src.height) > 2000) {
    src = src.width >= src.height ? img.copyResize(src, width: 2000) : img.copyResize(src, height: 2000);
  }
  final im = src.convert(numChannels: 4);
  // Paper brightness = 90th percentile luminance.
  final hist = List<int>.filled(256, 0);
  for (final px in im) {
    hist[img.getLuminanceRgb(px.r, px.g, px.b).toInt().clamp(0, 255)]++;
  }
  var acc = 0, paper = 255;
  final total = im.width * im.height;
  for (var v = 0; v < 256; v++) {
    acc += hist[v];
    if (acc >= total * 0.9) {
      paper = v;
      break;
    }
  }
  final cut = paper * (1 - threshold);
  var minX = im.width, minY = im.height, maxX = -1, maxY = -1;
  for (final px in im) {
    final l = img.getLuminanceRgb(px.r, px.g, px.b).toDouble();
    if (px.a < 10 || l >= cut) {
      px.a = 0;
      continue;
    }
    // Soft edge: fade alpha near the cut-off.
    final a = ((cut - l) / math.max(1, cut * 0.35)).clamp(0.0, 1.0);
    px.a = (255 * a).round();
    if (recolor) {
      px
        ..r = 13
        ..g = 27
        ..b = 110;
    }
    minX = math.min(minX, px.x);
    minY = math.min(minY, px.y);
    maxX = math.max(maxX, px.x);
    maxY = math.max(maxY, px.y);
  }
  if (maxX < 0) throw const FormatException('No ink found. Try a lower clean-up level.');
  final crop = img.copyCrop(im, x: math.max(0, minX - 4), y: math.max(0, minY - 4), width: math.min(im.width, maxX - minX + 9), height: math.min(im.height, maxY - minY + 9));
  return Uint8List.fromList(img.encodePng(crop));
}

/// Crops an encoded image to [rect] (normalised 0..1) and re-encodes it
/// (PNG keeps transparency; JPEG stays JPEG).
Future<(Uint8List, String)> cropImageBytes(Uint8List bytes, ui.Rect rect) => compute(_crop, (bytes, rect.left, rect.top, rect.width, rect.height));

(Uint8List, String) _crop((Uint8List, double, double, double, double) a) {
  final (bytes, l, t, w, h) = a;
  final src = img.decodeImage(bytes);
  if (src == null) throw const FormatException('Unsupported image.');
  final x = (l * src.width).round().clamp(0, src.width - 1);
  final y = (t * src.height).round().clamp(0, src.height - 1);
  final cw = (w * src.width).round().clamp(1, src.width - x);
  final ch = (h * src.height).round().clamp(1, src.height - y);
  final out = img.copyCrop(src, x: x, y: y, width: cw, height: ch);
  final jpeg = bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
  return jpeg ? (Uint8List.fromList(img.encodeJpg(out, quality: 92)), 'jpg') : (Uint8List.fromList(img.encodePng(out)), 'png');
}

/// Pixel size of an encoded image (header only where possible).
(int, int)? imageSizeOf(Uint8List bytes) {
  try {
    final d = img.findDecoderForData(bytes);
    final info = d?.startDecode(bytes);
    if (info != null) return (info.width, info.height);
  } catch (_) {}
  return null;
}
