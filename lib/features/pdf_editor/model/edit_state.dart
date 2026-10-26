import 'dart:ui';

/// The editing model of the PDF editor.
///
/// Edits are *recipes* applied to the untouched original PDF when a page is
/// previewed or the document is exported. Nothing here references a PDF
/// engine, so the engine can be swapped behind [PdfEditEngine].
///
/// Coordinates are "display points": PDF points (1/72 in) measured from the
/// top-left corner of the page as it is displayed (page rotation applied).

/// Font families the editor can write with. `original` reuses the font of
/// the text being edited when it has every glyph needed.
enum FontChoice { original, helvetica, times, courier, unicodeSans }

extension FontChoiceLabel on FontChoice {
  String get label => switch (this) {
        FontChoice.original => 'Original font',
        FontChoice.helvetica => 'Sans (Helvetica)',
        FontChoice.times => 'Serif (Times)',
        FontChoice.courier => 'Mono (Courier)',
        FontChoice.unicodeSans => 'Unicode Sans (FreeSans)',
      };
}

enum TextAlign2 { left, center, right, justify }

class TextStyleSpec {
  final FontChoice font;
  final double size; // points
  final int color; // ARGB
  final bool bold;
  final bool italic;
  final TextAlign2 align;
  final double lineSpacing; // multiple of font size (baseline to baseline)

  const TextStyleSpec({
    this.font = FontChoice.helvetica,
    this.size = 12,
    this.color = 0xFF000000,
    this.bold = false,
    this.italic = false,
    this.align = TextAlign2.left,
    this.lineSpacing = 1.2,
  });

  TextStyleSpec copyWith({FontChoice? font, double? size, int? color, bool? bold, bool? italic, TextAlign2? align, double? lineSpacing}) =>
      TextStyleSpec(
        font: font ?? this.font,
        size: size ?? this.size,
        color: color ?? this.color,
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        align: align ?? this.align,
        lineSpacing: lineSpacing ?? this.lineSpacing,
      );

  Map<String, dynamic> toJson() => {
        'f': font.name,
        's': size,
        'c': color,
        'b': bold,
        'i': italic,
        'a': align.name,
        'l': lineSpacing,
      };

  factory TextStyleSpec.fromJson(Map<String, dynamic> j) => TextStyleSpec(
        font: FontChoice.values.firstWhere((e) => e.name == j['f'], orElse: () => FontChoice.helvetica),
        size: (j['s'] as num?)?.toDouble() ?? 12,
        color: (j['c'] as num?)?.toInt() ?? 0xFF000000,
        bold: j['b'] as bool? ?? false,
        italic: j['i'] as bool? ?? false,
        align: TextAlign2.values.firstWhere((e) => e.name == j['a'], orElse: () => TextAlign2.left),
        lineSpacing: (j['l'] as num?)?.toDouble() ?? 1.2,
      );

  @override
  bool operator ==(Object other) =>
      other is TextStyleSpec &&
      other.font == font &&
      other.size == size &&
      other.color == color &&
      other.bold == bold &&
      other.italic == italic &&
      other.align == align &&
      other.lineSpacing == lineSpacing;

  @override
  int get hashCode => Object.hash(font, size, color, bold, italic, align, lineSpacing);
}

Map<String, dynamic> _rect(Rect r) => {'l': r.left, 't': r.top, 'w': r.width, 'h': r.height};
Rect _rectOf(dynamic j) {
  final m = j as Map<String, dynamic>;
  return Rect.fromLTWH((m['l'] as num).toDouble(), (m['t'] as num).toDouble(), (m['w'] as num).toDouble(), (m['h'] as num).toDouble());
}

/// One page of the output document: an original page or an inserted blank.
class PageSlot {
  final String id;
  final int? source; // page index in the original; null for a blank page
  final int rotation; // extra clockwise rotation, multiple of 90
  final Size blankSize; // only for blank pages

  const PageSlot({required this.id, this.source, this.rotation = 0, this.blankSize = const Size(595.28, 841.89)});

  bool get isBlank => source == null;
  PageSlot rotated(int d) => PageSlot(id: id, source: source, rotation: (rotation + d) % 360, blankSize: blankSize);

  Map<String, dynamic> toJson() => {'id': id, 's': source, 'r': rotation, 'bw': blankSize.width, 'bh': blankSize.height};
  factory PageSlot.fromJson(Map<String, dynamic> j) => PageSlot(
        id: j['id'] as String,
        source: (j['s'] as num?)?.toInt(),
        rotation: (j['r'] as num?)?.toInt() ?? 0,
        blankSize: Size((j['bw'] as num?)?.toDouble() ?? 595.28, (j['bh'] as num?)?.toDouble() ?? 841.89),
      );
}

/// An edit of existing text: a block of one or more original text objects.
class TextBlockEdit {
  final int page; // original page index
  final List<int> objects; // original page-object indices in the block
  final bool deleted;
  final String? text; // replacement text (null = unchanged)
  final TextStyleSpec? style; // null = keep original formatting
  final Rect? box; // new box (display points); null = original position
  final bool shrinkToFit; // keep within the original box height

  const TextBlockEdit({required this.page, required this.objects, this.deleted = false, this.text, this.style, this.box, this.shrinkToFit = false});

  String get key => blockKey(page, objects);
  static String blockKey(int page, List<int> objects) => '$page:${objects.join(',')}';

  TextBlockEdit copyWith({bool? deleted, String? text, TextStyleSpec? style, Rect? box, bool? shrinkToFit}) => TextBlockEdit(
        page: page,
        objects: objects,
        deleted: deleted ?? this.deleted,
        text: text ?? this.text,
        style: style ?? this.style,
        box: box ?? this.box,
        shrinkToFit: shrinkToFit ?? this.shrinkToFit,
      );

  Map<String, dynamic> toJson() => {
        'p': page,
        'o': objects,
        if (deleted) 'd': true,
        if (text != null) 'x': text,
        if (style != null) 's': style!.toJson(),
        if (box != null) 'b': _rect(box!),
        if (shrinkToFit) 'f': true,
      };

  factory TextBlockEdit.fromJson(Map<String, dynamic> j) => TextBlockEdit(
        page: (j['p'] as num).toInt(),
        objects: (j['o'] as List).map((e) => (e as num).toInt()).toList(),
        deleted: j['d'] as bool? ?? false,
        text: j['x'] as String?,
        style: j['s'] == null ? null : TextStyleSpec.fromJson(j['s'] as Map<String, dynamic>),
        box: j['b'] == null ? null : _rectOf(j['b']),
        shrinkToFit: j['f'] as bool? ?? false,
      );
}

/// An edit of an existing image object.
class ImageObjEdit {
  final int page;
  final int object;
  final bool deleted;
  final Rect? box; // new position/size (display points)
  final String? replacement; // asset path relative to the draft directory
  final double opacity; // applies to a replacement image

  const ImageObjEdit({required this.page, required this.object, this.deleted = false, this.box, this.replacement, this.opacity = 1});

  String get key => '$page:$object';

  ImageObjEdit copyWith({bool? deleted, Rect? box, String? replacement, double? opacity}) => ImageObjEdit(
        page: page,
        object: object,
        deleted: deleted ?? this.deleted,
        box: box ?? this.box,
        replacement: replacement ?? this.replacement,
        opacity: opacity ?? this.opacity,
      );

  Map<String, dynamic> toJson() => {
        'p': page,
        'o': object,
        if (deleted) 'd': true,
        if (box != null) 'b': _rect(box!),
        if (replacement != null) 'r': replacement,
        'a': opacity,
      };

  factory ImageObjEdit.fromJson(Map<String, dynamic> j) => ImageObjEdit(
        page: (j['p'] as num).toInt(),
        object: (j['o'] as num).toInt(),
        deleted: j['d'] as bool? ?? false,
        box: j['b'] == null ? null : _rectOf(j['b']),
        replacement: j['r'] as String?,
        opacity: (j['a'] as num?)?.toDouble() ?? 1,
      );
}

/// Kinds of items the user adds. Text, images, cover rectangles and hidden
/// OCR text become page content; the rest become PDF annotations, which
/// stay editable in other PDF apps until flattened.
enum ItemKind { text, image, cover, ocrText, highlight, underline, strikeout, ink, note, rect, ellipse, line, arrow, stamp }

extension ItemKindInfo on ItemKind {
  bool get isAnnotation => switch (this) {
        ItemKind.text || ItemKind.image || ItemKind.cover || ItemKind.ocrText => false,
        _ => true,
      };
  String get label => switch (this) {
        ItemKind.text => 'Text',
        ItemKind.image => 'Image',
        ItemKind.cover => 'Cover',
        ItemKind.ocrText => 'OCR text layer',
        ItemKind.highlight => 'Highlight',
        ItemKind.underline => 'Underline',
        ItemKind.strikeout => 'Strikethrough',
        ItemKind.ink => 'Drawing',
        ItemKind.note => 'Note',
        ItemKind.rect => 'Rectangle',
        ItemKind.ellipse => 'Ellipse',
        ItemKind.line => 'Line',
        ItemKind.arrow => 'Arrow',
        ItemKind.stamp => 'Stamp',
      };
}

/// What an inserted image is, for labels and defaults.
enum ImageRole { picture, signature, photo, stamp }

/// An item added in the editor.
class EditItem {
  final String id;
  final String slot; // PageSlot.id
  final ItemKind kind;
  final Rect box; // display points
  final double rotation; // degrees clockwise (text and images)
  final String text; // text, note contents, stamp label, OCR text
  final TextStyleSpec style;
  final String? asset; // image file relative to the draft directory
  final ImageRole role;
  final double opacity;
  final int color; // annotation / cover colour (ARGB)
  final double strokeWidth;
  final List<List<Offset>> strokes; // ink; line/arrow use one 2-point stroke
  final List<Rect> rects; // highlight/underline/strikeout areas

  const EditItem({
    required this.id,
    required this.slot,
    required this.kind,
    required this.box,
    this.rotation = 0,
    this.text = '',
    this.style = const TextStyleSpec(),
    this.asset,
    this.role = ImageRole.picture,
    this.opacity = 1,
    this.color = 0xFF1E3A8A,
    this.strokeWidth = 2,
    this.strokes = const [],
    this.rects = const [],
  });

  EditItem copyWith({
    String? id,
    String? slot,
    Rect? box,
    double? rotation,
    String? text,
    TextStyleSpec? style,
    String? asset,
    double? opacity,
    int? color,
    double? strokeWidth,
    List<List<Offset>>? strokes,
    List<Rect>? rects,
  }) =>
      EditItem(
        id: id ?? this.id,
        slot: slot ?? this.slot,
        kind: kind,
        box: box ?? this.box,
        rotation: rotation ?? this.rotation,
        text: text ?? this.text,
        style: style ?? this.style,
        asset: asset ?? this.asset,
        role: role,
        opacity: opacity ?? this.opacity,
        color: color ?? this.color,
        strokeWidth: strokeWidth ?? this.strokeWidth,
        strokes: strokes ?? this.strokes,
        rects: rects ?? this.rects,
      );

  /// Moves the item (and its geometry) by [d].
  EditItem translated(Offset d) => copyWith(
        box: box.shift(d),
        strokes: [for (final s in strokes) [for (final p in s) p + d]],
        rects: [for (final r in rects) r.shift(d)],
      );

  /// Scales stroke/rect geometry along with a box resize.
  EditItem resized(Rect to) {
    if (box.width <= 0 || box.height <= 0) return copyWith(box: to);
    final sx = to.width / box.width, sy = to.height / box.height;
    Offset map(Offset p) => Offset(to.left + (p.dx - box.left) * sx, to.top + (p.dy - box.top) * sy);
    return copyWith(
      box: to,
      strokes: [for (final s in strokes) [for (final p in s) map(p)]],
      rects: [for (final r in rects) Rect.fromPoints(map(r.topLeft), map(r.bottomRight))],
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'sl': slot,
        'k': kind.name,
        'b': _rect(box),
        if (rotation != 0) 'r': rotation,
        if (text.isNotEmpty) 'x': text,
        'st': style.toJson(),
        if (asset != null) 'as': asset,
        'ro': role.name,
        'op': opacity,
        'c': color,
        'sw': strokeWidth,
        if (strokes.isNotEmpty) 'sk': [for (final s in strokes) [for (final p in s) ...[p.dx, p.dy]]],
        if (rects.isNotEmpty) 'rc': [for (final r in rects) _rect(r)],
      };

  factory EditItem.fromJson(Map<String, dynamic> j) => EditItem(
        id: j['id'] as String,
        slot: j['sl'] as String,
        kind: ItemKind.values.firstWhere((e) => e.name == j['k']),
        box: _rectOf(j['b']),
        rotation: (j['r'] as num?)?.toDouble() ?? 0,
        text: j['x'] as String? ?? '',
        style: j['st'] == null ? const TextStyleSpec() : TextStyleSpec.fromJson(j['st'] as Map<String, dynamic>),
        asset: j['as'] as String?,
        role: ImageRole.values.firstWhere((e) => e.name == j['ro'], orElse: () => ImageRole.picture),
        opacity: (j['op'] as num?)?.toDouble() ?? 1,
        color: (j['c'] as num?)?.toInt() ?? 0xFF1E3A8A,
        strokeWidth: (j['sw'] as num?)?.toDouble() ?? 2,
        strokes: [
          for (final s in (j['sk'] as List?) ?? const [])
            [
              for (var i = 0; i + 1 < (s as List).length; i += 2) Offset((s[i] as num).toDouble(), (s[i + 1] as num).toDouble()),
            ]
        ],
        rects: [for (final r in (j['rc'] as List?) ?? const []) _rectOf(r)],
      );
}

/// Document-wide additions applied to every output page after reordering.
class Decorations {
  final String watermark;
  final double watermarkOpacity;
  final int watermarkColor;
  final String header;
  final String footer;
  final bool pageNumbers;
  final String pageNumberFormat; // {n} = page number, {total} = page count
  final double fontSize;

  const Decorations({
    this.watermark = '',
    this.watermarkOpacity = 0.15,
    this.watermarkColor = 0xFFB71C1C,
    this.header = '',
    this.footer = '',
    this.pageNumbers = false,
    this.pageNumberFormat = 'Page {n} of {total}',
    this.fontSize = 9,
  });

  bool get isEmpty => watermark.trim().isEmpty && header.trim().isEmpty && footer.trim().isEmpty && !pageNumbers;

  Map<String, dynamic> toJson() => {
        'w': watermark,
        'wo': watermarkOpacity,
        'wc': watermarkColor,
        'h': header,
        'f': footer,
        'n': pageNumbers,
        'nf': pageNumberFormat,
        's': fontSize,
      };

  factory Decorations.fromJson(Map<String, dynamic> j) => Decorations(
        watermark: j['w'] as String? ?? '',
        watermarkOpacity: (j['wo'] as num?)?.toDouble() ?? 0.15,
        watermarkColor: (j['wc'] as num?)?.toInt() ?? 0xFFB71C1C,
        header: j['h'] as String? ?? '',
        footer: j['f'] as String? ?? '',
        pageNumbers: j['n'] as bool? ?? false,
        pageNumberFormat: j['nf'] as String? ?? 'Page {n} of {total}',
        fontSize: (j['s'] as num?)?.toDouble() ?? 9,
      );
}

/// The whole editing state. Immutable: every change creates a new state, so
/// undo/redo is a stack of states.
class EditState {
  final List<PageSlot> slots;
  final Map<String, TextBlockEdit> textEdits; // by TextBlockEdit.key
  final Map<String, ImageObjEdit> imageEdits; // by ImageObjEdit.key
  final List<EditItem> items;
  final Decorations decorations;

  const EditState({required this.slots, this.textEdits = const {}, this.imageEdits = const {}, this.items = const [], this.decorations = const Decorations()});

  factory EditState.initial(int pageCount) => EditState(slots: [for (var i = 0; i < pageCount; i++) PageSlot(id: 'p$i', source: i)]);

  bool get isPristine {
    if (textEdits.isNotEmpty || imageEdits.isNotEmpty || items.isNotEmpty || !decorations.isEmpty) return false;
    for (var i = 0; i < slots.length; i++) {
      final s = slots[i];
      if (s.source != i || s.rotation != 0) return false;
    }
    return true;
  }

  PageSlot? slot(String id) {
    for (final s in slots) {
      if (s.id == id) return s;
    }
    return null;
  }

  List<EditItem> itemsOn(String slotId) => [for (final i in items) if (i.slot == slotId) i];
  List<TextBlockEdit> textEditsOn(int page) => [for (final e in textEdits.values) if (e.page == page) e];
  List<ImageObjEdit> imageEditsOn(int page) => [for (final e in imageEdits.values) if (e.page == page) e];

  /// True when the slot's page has any content edits (used to skip pages).
  bool slotHasContentEdits(PageSlot s) =>
      items.any((i) => i.slot == s.id) || (s.source != null && (textEdits.values.any((e) => e.page == s.source) || imageEdits.values.any((e) => e.page == s.source)));

  EditState copyWith({List<PageSlot>? slots, Map<String, TextBlockEdit>? textEdits, Map<String, ImageObjEdit>? imageEdits, List<EditItem>? items, Decorations? decorations}) =>
      EditState(
        slots: slots ?? this.slots,
        textEdits: textEdits ?? this.textEdits,
        imageEdits: imageEdits ?? this.imageEdits,
        items: items ?? this.items,
        decorations: decorations ?? this.decorations,
      );

  EditState withTextEdit(TextBlockEdit e) => copyWith(textEdits: {...textEdits, e.key: e});
  EditState withoutTextEdit(String key) => copyWith(textEdits: {...textEdits}..remove(key));
  EditState withImageEdit(ImageObjEdit e) => copyWith(imageEdits: {...imageEdits, e.key: e});
  EditState withoutImageEdit(String key) => copyWith(imageEdits: {...imageEdits}..remove(key));

  EditState withItem(EditItem item) {
    final idx = items.indexWhere((i) => i.id == item.id);
    final list = [...items];
    if (idx < 0) {
      list.add(item);
    } else {
      list[idx] = item;
    }
    return copyWith(items: list);
  }

  EditState withoutItem(String id) => copyWith(items: [for (final i in items) if (i.id != id) i]);

  /// Removes a page slot together with the items placed on it.
  EditState withoutSlot(String id) => copyWith(slots: [for (final s in slots) if (s.id != id) s], items: [for (final i in items) if (i.slot != id) i]);

  Map<String, dynamic> toJson() => {
        'v': 1,
        'slots': [for (final s in slots) s.toJson()],
        'text': [for (final e in textEdits.values) e.toJson()],
        'img': [for (final e in imageEdits.values) e.toJson()],
        'items': [for (final i in items) i.toJson()],
        'dec': decorations.toJson(),
      };

  factory EditState.fromJson(Map<String, dynamic> j) {
    final text = [for (final e in (j['text'] as List?) ?? const []) TextBlockEdit.fromJson(e as Map<String, dynamic>)];
    final img = [for (final e in (j['img'] as List?) ?? const []) ImageObjEdit.fromJson(e as Map<String, dynamic>)];
    return EditState(
      slots: [for (final s in j['slots'] as List) PageSlot.fromJson(s as Map<String, dynamic>)],
      textEdits: {for (final e in text) e.key: e},
      imageEdits: {for (final e in img) e.key: e},
      items: [for (final i in (j['items'] as List?) ?? const []) EditItem.fromJson(i as Map<String, dynamic>)],
      decorations: j['dec'] == null ? const Decorations() : Decorations.fromJson(j['dec'] as Map<String, dynamic>),
    );
  }
}

/// Undo/redo history of [EditState]s.
class EditHistory {
  final List<EditState> _undo = [];
  final List<EditState> _redo = [];
  EditState _current;
  final int limit;

  EditHistory(this._current, {this.limit = 200});

  EditState get current => _current;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void push(EditState next) {
    if (identical(next, _current)) return;
    _undo.add(_current);
    if (_undo.length > limit) _undo.removeAt(0);
    _redo.clear();
    _current = next;
  }

  /// Replaces the current state without a history entry (e.g. while dragging).
  void replace(EditState next) => _current = next;

  EditState undo() {
    if (_undo.isEmpty) return _current;
    _redo.add(_current);
    _current = _undo.removeLast();
    return _current;
  }

  EditState redo() {
    if (_redo.isEmpty) return _current;
    _undo.add(_current);
    _current = _redo.removeLast();
    return _current;
  }
}
