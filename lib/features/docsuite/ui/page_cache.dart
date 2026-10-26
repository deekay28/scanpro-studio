import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../pdf_editor/engine/engine_worker.dart';

/// Renders pages of an open PDF on demand and keeps the most recent ones in
/// memory. Width buckets avoid re-rendering for small size changes.
class PageRenderCache {
  final HostSession session;
  final List<Size> sizes; // display points
  final int capacity;
  final _cache = <(int, int), ui.Image>{};
  final _pending = <(int, int), Future<ui.Image>>{};

  PageRenderCache(this.session, this.sizes, {this.capacity = 14});

  static Future<PageRenderCache> open(HostSession s) async {
    final sizes = <Size>[];
    for (var i = 0; i < s.pageCount; i++) {
      sizes.add(await s.call<Size>('pageSize', [i]));
    }
    return PageRenderCache(s, sizes);
  }

  int get pageCount => sizes.length;

  ui.Image? peek(int page, int pixelWidth) => _cache[(page, _bucket(pixelWidth))];

  static int _bucket(int w) => (math.max(64, math.min(2400, w)) / 128).ceil() * 128;

  Future<ui.Image> get(int page, int pixelWidth) {
    final key = (page, _bucket(pixelWidth));
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit;
      return Future.value(hit);
    }
    return _pending[key] ??= () async {
      try {
        final scale = key.$2 / sizes[page].width;
        final r = await session.call<RenderedPage>('renderOriginal', [page, scale]);
        final c = Completer<ui.Image>();
        ui.decodeImageFromPixels(r.rgba, r.width, r.height, ui.PixelFormat.rgba8888, c.complete);
        final im = await c.future;
        _cache[key] = im;
        while (_cache.length > capacity) {
          _cache.remove(_cache.keys.first)?.dispose();
        }
        return im;
      } finally {
        _pending.remove(key);
      }
    }();
  }

  void dispose() {
    for (final i in _cache.values) {
      i.dispose();
    }
    _cache.clear();
  }
}

/// One rendered page at the given width, with optional highlight rects (in
/// page points) painted over it.
class RenderedPageView extends StatelessWidget {
  final PageRenderCache cache;
  final int page;
  final double width;
  final List<Rect> highlights;
  final Color highlightColor;
  final ColorFilter? filter;
  const RenderedPageView({
    super.key,
    required this.cache,
    required this.page,
    required this.width,
    this.highlights = const [],
    this.highlightColor = const Color(0x66FFEB3B),
    this.filter,
  });

  @override
  Widget build(BuildContext context) {
    final size = cache.sizes[page];
    final height = width * size.height / size.width;
    final px = (width * MediaQuery.devicePixelRatioOf(context)).round();
    final ready = cache.peek(page, px);
    Widget image(ui.Image im) {
      Widget w = RawImage(image: im, width: width, height: height, fit: BoxFit.fill);
      if (filter != null) w = ColorFiltered(colorFilter: filter!, child: w);
      return w;
    }

    return SizedBox(
      width: width,
      height: height,
      child: Stack(fit: StackFit.expand, children: [
        Container(color: Colors.white),
        if (ready != null)
          image(ready)
        else
          FutureBuilder<ui.Image>(
            future: cache.get(page, px),
            builder: (ctx, snap) => snap.hasData
                ? image(snap.data!)
                : snap.hasError
                    ? Center(child: Text('Page ${page + 1} could not be shown', style: const TextStyle(color: Colors.black54)))
                    : const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
          ),
        if (highlights.isNotEmpty) CustomPaint(painter: _RectPainter(highlights, width / size.width, highlightColor)),
      ]),
    );
  }
}

class _RectPainter extends CustomPainter {
  final List<Rect> rects;
  final double k;
  final Color color;
  _RectPainter(this.rects, this.k, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    for (final r in rects) {
      canvas.drawRect(Rect.fromLTRB(r.left * k, r.top * k, r.right * k, r.bottom * k).inflate(1), p);
    }
  }

  @override
  bool shouldRepaint(_RectPainter old) => old.rects != rects || old.k != k || old.color != color;
}
