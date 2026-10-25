import 'dart:convert';

/// A recognised text line with its bounding box in the coordinates of the
/// image that was recognised (the processed page).
class OcrLine {
  final String text;
  final double left, top, right, bottom;
  final double? confidence; // engine confidence when available (0..1)
  final bool flagged; // needs human review
  final int block;

  const OcrLine({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    this.confidence,
    this.flagged = false,
    this.block = 0,
  });

  double get width => right - left;
  double get height => bottom - top;
  double get centerY => (top + bottom) / 2;

  OcrLine copyWith({String? text, bool? flagged}) => OcrLine(
        text: text ?? this.text,
        left: left,
        top: top,
        right: right,
        bottom: bottom,
        confidence: confidence,
        flagged: flagged ?? this.flagged,
        block: block,
      );

  Map<String, dynamic> toJson() => {
        't': text,
        'b': [left, top, right, bottom],
        if (confidence != null) 'c': confidence,
        if (flagged) 'f': true,
        'k': block,
      };

  factory OcrLine.fromJson(Map<String, dynamic> j) {
    final b = (j['b'] as List).map((e) => (e as num).toDouble()).toList();
    return OcrLine(
      text: j['t'] as String? ?? '',
      left: b[0],
      top: b[1],
      right: b[2],
      bottom: b[3],
      confidence: (j['c'] as num?)?.toDouble(),
      flagged: j['f'] as bool? ?? false,
      block: (j['k'] as num?)?.toInt() ?? 0,
    );
  }
}

class OcrPageResult {
  final String script; // latin | devanagari
  final int imageWidth;
  final int imageHeight;
  final List<OcrLine> lines;
  final DateTime createdAt;
  final bool edited;

  const OcrPageResult({
    required this.script,
    required this.imageWidth,
    required this.imageHeight,
    required this.lines,
    required this.createdAt,
    this.edited = false,
  });

  /// Plain text with blocks separated by blank lines.
  String get text {
    final sb = StringBuffer();
    int? lastBlock;
    for (final l in lines) {
      if (lastBlock != null) sb.write(l.block != lastBlock ? '\n\n' : '\n');
      sb.write(l.text);
      lastBlock = l.block;
    }
    return sb.toString();
  }

  int get flaggedCount => lines.where((l) => l.flagged).length;

  OcrPageResult copyWith({List<OcrLine>? lines, bool? edited}) => OcrPageResult(
        script: script,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        lines: lines ?? this.lines,
        createdAt: createdAt,
        edited: edited ?? this.edited,
      );

  Map<String, dynamic> toJson() => {
        'script': script,
        'w': imageWidth,
        'h': imageHeight,
        'lines': lines.map((l) => l.toJson()).toList(),
        'created': createdAt.millisecondsSinceEpoch,
        'edited': edited,
      };

  factory OcrPageResult.fromJson(Map<String, dynamic> j) => OcrPageResult(
        script: j['script'] as String? ?? 'latin',
        imageWidth: (j['w'] as num?)?.toInt() ?? 0,
        imageHeight: (j['h'] as num?)?.toInt() ?? 0,
        lines: ((j['lines'] as List?) ?? const []).map((e) => OcrLine.fromJson(e as Map<String, dynamic>)).toList(),
        createdAt: DateTime.fromMillisecondsSinceEpoch((j['created'] as num?)?.toInt() ?? 0),
        edited: j['edited'] as bool? ?? false,
      );

  String encode() => jsonEncode(toJson());
  static OcrPageResult? decode(String s) {
    try {
      return OcrPageResult.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

/// Persistent, resumable scan session (survives app kills).
class ScanSessionData {
  final String id;
  final String mode; // scan | book | import
  final String? targetDocId; // append to existing document
  final List<SessionItem> items;
  final DateTime updatedAt;

  const ScanSessionData({required this.id, required this.mode, this.targetDocId, required this.items, required this.updatedAt});

  ScanSessionData copyWith({List<SessionItem>? items, String? targetDocId}) => ScanSessionData(
        id: id,
        mode: mode,
        targetDocId: targetDocId ?? this.targetDocId,
        items: items ?? this.items,
        updatedAt: DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'target': targetDocId,
        'items': items.map((e) => e.toJson()).toList(),
      };

  static ScanSessionData fromRow(Map<String, Object?> r) {
    final j = jsonDecode(r['data'] as String) as Map<String, dynamic>;
    return ScanSessionData(
      id: r['id'] as String,
      mode: r['mode'] as String,
      targetDocId: j['target'] as String?,
      items: ((j['items'] as List?) ?? const []).map((e) => SessionItem.fromJson(e as Map<String, dynamic>)).toList(),
      updatedAt: DateTime.fromMillisecondsSinceEpoch((r['updated_at'] as num).toInt()),
    );
  }
}

class SessionItem {
  final String path; // relative to app root
  final List<double>? corners;
  final List<String> flags;
  final String? hash;
  final double? spine; // book mode
  final int rotation;

  const SessionItem({required this.path, this.corners, this.flags = const [], this.hash, this.spine, this.rotation = 0});

  SessionItem copyWith({List<double>? corners, List<String>? flags, double? spine, int? rotation}) => SessionItem(
        path: path,
        corners: corners ?? this.corners,
        flags: flags ?? this.flags,
        hash: hash,
        spine: spine ?? this.spine,
        rotation: rotation ?? this.rotation,
      );

  Map<String, dynamic> toJson() => {
        'p': path,
        if (corners != null) 'c': corners,
        'f': flags,
        if (hash != null) 'h': hash,
        if (spine != null) 's': spine,
        'r': rotation,
      };

  factory SessionItem.fromJson(Map<String, dynamic> j) => SessionItem(
        path: j['p'] as String,
        corners: (j['c'] as List?)?.map((e) => (e as num).toDouble()).toList(),
        flags: ((j['f'] as List?) ?? const []).map((e) => e.toString()).toList(),
        hash: j['h'] as String?,
        spine: (j['s'] as num?)?.toDouble(),
        rotation: (j['r'] as num?)?.toInt() ?? 0,
      );
}
