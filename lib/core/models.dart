import 'dart:convert';

/// Image processing presets. The original file is never modified; a preset is
/// a recipe applied to produce the processed page.
enum FilterPreset {
  original,
  smartAuto,
  documentColor,
  vividColor,
  grayscale,
  blackWhite,
  highContrastText,
  fadedRecovery,
  receipt,
  photo,
  officialPreserve,
}

extension FilterPresetInfo on FilterPreset {
  String get label => switch (this) {
        FilterPreset.original => 'Original',
        FilterPreset.smartAuto => 'Smart Auto',
        FilterPreset.documentColor => 'Document Colour',
        FilterPreset.vividColor => 'Vivid Colour',
        FilterPreset.grayscale => 'Grayscale',
        FilterPreset.blackWhite => 'Pure B&W',
        FilterPreset.highContrastText => 'High-Contrast Text',
        FilterPreset.fadedRecovery => 'Faded Recovery',
        FilterPreset.receipt => 'Receipt',
        FilterPreset.photo => 'Photo Enhance',
        FilterPreset.officialPreserve => 'Official (Preserve)',
      };

  String get description => switch (this) {
        FilterPreset.original => 'No changes. Exactly what the camera captured.',
        FilterPreset.smartAuto => 'Auto levels, gentle colour and sharpening.',
        FilterPreset.documentColor => 'Whitens paper and removes shadows while keeping colour stamps and ink.',
        FilterPreset.vividColor => 'Clean paper with boosted colours for charts and diagrams.',
        FilterPreset.grayscale => 'Neutral grayscale with balanced contrast.',
        FilterPreset.blackWhite => 'Adaptive black & white for crisp text. Smallest files.',
        FilterPreset.highContrastText => 'Darker text, white paper, keeps grey tones of signatures.',
        FilterPreset.fadedRecovery => 'Boosts local contrast of faded or old documents.',
        FilterPreset.receipt => 'Strengthens faint thermal-printer text.',
        FilterPreset.photo => 'White balance, levels and vibrance for photographs.',
        FilterPreset.officialPreserve =>
          'For certificates and signed forms: only gentle lighting correction. Stamps, seals, signatures and colours are preserved. No thresholding.',
      };

  bool get usesThreshold => this == FilterPreset.blackWhite;
}

/// Non-destructive edit recipe for a page.
class PageEdit {
  /// Eight normalised values [x0,y0,x1,y1,x2,y2,x3,y3] (TL, TR, BR, BL)
  /// relative to the EXIF-corrected original image. Null = whole image.
  final List<double>? corners;
  final int rotation; // 0, 90, 180, 270 (clockwise), applied after warp
  final double fineAngle; // degrees, deskew, applied after rotation
  final FilterPreset preset;
  final double brightness; // -1..1
  final double contrast; // -1..1
  final double saturation; // -1..1
  final double highlights; // -1..1
  final double shadows; // -1..1
  final double sharpness; // 0..1
  final double threshold; // -1..1 (B&W offset)
  final bool adaptiveBw;
  final bool flatten; // approximate curved-page correction

  const PageEdit({
    this.corners,
    this.rotation = 0,
    this.fineAngle = 0,
    this.preset = FilterPreset.original,
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.highlights = 0,
    this.shadows = 0,
    this.sharpness = 0,
    this.threshold = 0,
    this.adaptiveBw = true,
    this.flatten = false,
  });

  bool get hasManualAdjustments =>
      brightness != 0 || contrast != 0 || saturation != 0 || highlights != 0 || shadows != 0 || sharpness != 0 || threshold != 0;

  bool get isIdentity =>
      corners == null && rotation == 0 && fineAngle == 0 && preset == FilterPreset.original && !hasManualAdjustments && !flatten;

  PageEdit copyWith({
    List<double>? corners,
    bool clearCorners = false,
    int? rotation,
    double? fineAngle,
    FilterPreset? preset,
    double? brightness,
    double? contrast,
    double? saturation,
    double? highlights,
    double? shadows,
    double? sharpness,
    double? threshold,
    bool? adaptiveBw,
    bool? flatten,
  }) =>
      PageEdit(
        corners: clearCorners ? null : (corners ?? this.corners),
        rotation: rotation ?? this.rotation,
        fineAngle: fineAngle ?? this.fineAngle,
        preset: preset ?? this.preset,
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
        highlights: highlights ?? this.highlights,
        shadows: shadows ?? this.shadows,
        sharpness: sharpness ?? this.sharpness,
        threshold: threshold ?? this.threshold,
        adaptiveBw: adaptiveBw ?? this.adaptiveBw,
        flatten: flatten ?? this.flatten,
      );

  PageEdit resetAdjustments() => PageEdit(corners: corners, rotation: rotation, fineAngle: fineAngle, preset: preset, flatten: flatten);

  Map<String, dynamic> toJson() => {
        if (corners != null) 'corners': corners,
        'rotation': rotation,
        'fineAngle': fineAngle,
        'preset': preset.name,
        'brightness': brightness,
        'contrast': contrast,
        'saturation': saturation,
        'highlights': highlights,
        'shadows': shadows,
        'sharpness': sharpness,
        'threshold': threshold,
        'adaptiveBw': adaptiveBw,
        'flatten': flatten,
      };

  factory PageEdit.fromJson(Map<String, dynamic> j) {
    double d(String k) => (j[k] as num?)?.toDouble() ?? 0;
    final c = j['corners'];
    return PageEdit(
      corners: c is List ? c.map((e) => (e as num).toDouble()).toList() : null,
      rotation: ((j['rotation'] as num?)?.toInt() ?? 0) % 360,
      fineAngle: d('fineAngle'),
      preset: FilterPreset.values.firstWhere((p) => p.name == j['preset'], orElse: () => FilterPreset.original),
      brightness: d('brightness'),
      contrast: d('contrast'),
      saturation: d('saturation'),
      highlights: d('highlights'),
      shadows: d('shadows'),
      sharpness: d('sharpness'),
      threshold: d('threshold'),
      adaptiveBw: j['adaptiveBw'] as bool? ?? true,
      flatten: j['flatten'] as bool? ?? false,
    );
  }

  String encode() => jsonEncode(toJson());
  static PageEdit decode(String? s) {
    if (s == null || s.isEmpty) return const PageEdit();
    try {
      return PageEdit.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return const PageEdit();
    }
  }
}

enum DocKind { scan, images, pdf, book, photoSheet }

DocKind docKindFrom(String? s) => DocKind.values.firstWhere((k) => k.name == s, orElse: () => DocKind.scan);

class ScanDocument {
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? openedAt;
  final String? folderId;
  final bool favourite;
  final DateTime? deletedAt;
  final DocKind kind;
  final String? pdfPath; // relative; for imported/derived PDFs
  final int pageCount;
  final String? docType;
  final String? parentId;
  final String? coverThumb; // relative path of first page thumb
  final List<String> tags;

  const ScanDocument({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.openedAt,
    this.folderId,
    this.favourite = false,
    this.deletedAt,
    this.kind = DocKind.scan,
    this.pdfPath,
    this.pageCount = 0,
    this.docType,
    this.parentId,
    this.coverThumb,
    this.tags = const [],
  });

  bool get isPdf => kind == DocKind.pdf || pdfPath != null;
  bool get isDeleted => deletedAt != null;

  ScanDocument copyWith({
    String? title,
    DateTime? updatedAt,
    String? folderId,
    bool clearFolder = false,
    bool? favourite,
    int? pageCount,
    String? docType,
    List<String>? tags,
    String? coverThumb,
  }) =>
      ScanDocument(
        id: id,
        title: title ?? this.title,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        openedAt: openedAt,
        folderId: clearFolder ? null : (folderId ?? this.folderId),
        favourite: favourite ?? this.favourite,
        deletedAt: deletedAt,
        kind: kind,
        pdfPath: pdfPath,
        pageCount: pageCount ?? this.pageCount,
        docType: docType ?? this.docType,
        parentId: parentId,
        coverThumb: coverThumb ?? this.coverThumb,
        tags: tags ?? this.tags,
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'title': title,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
        'opened_at': openedAt?.millisecondsSinceEpoch,
        'folder_id': folderId,
        'favourite': favourite ? 1 : 0,
        'deleted_at': deletedAt?.millisecondsSinceEpoch,
        'kind': kind.name,
        'pdf_path': pdfPath,
        'page_count': pageCount,
        'doc_type': docType,
        'parent_id': parentId,
      };

  factory ScanDocument.fromRow(Map<String, Object?> r, {List<String> tags = const [], String? coverThumb}) {
    DateTime? dt(Object? v) => v == null ? null : DateTime.fromMillisecondsSinceEpoch((v as num).toInt());
    return ScanDocument(
      id: r['id'] as String,
      title: r['title'] as String? ?? 'Untitled',
      createdAt: dt(r['created_at']) ?? DateTime.now(),
      updatedAt: dt(r['updated_at']) ?? DateTime.now(),
      openedAt: dt(r['opened_at']),
      folderId: r['folder_id'] as String?,
      favourite: (r['favourite'] as num?)?.toInt() == 1,
      deletedAt: dt(r['deleted_at']),
      kind: docKindFrom(r['kind'] as String?),
      pdfPath: r['pdf_path'] as String?,
      pageCount: (r['page_count'] as num?)?.toInt() ?? 0,
      docType: r['doc_type'] as String?,
      parentId: r['parent_id'] as String?,
      coverThumb: coverThumb ?? r['cover_thumb'] as String?,
      tags: tags,
    );
  }
}

class DocPage {
  final String id;
  final String docId;
  final int position;
  final String originalPath; // relative to app root
  final String? processedPath;
  final String? thumbPath;
  final PageEdit edit;
  final String? ocrText;
  final String? ocrLang;
  final String? ocrPath;
  final int width;
  final int height;
  final List<String> flags;
  final String? hash;
  final String? annotPath;
  final String? overlayPath;
  final DateTime createdAt;

  const DocPage({
    required this.id,
    required this.docId,
    required this.position,
    required this.originalPath,
    this.processedPath,
    this.thumbPath,
    this.edit = const PageEdit(),
    this.ocrText,
    this.ocrLang,
    this.ocrPath,
    this.width = 0,
    this.height = 0,
    this.flags = const [],
    this.hash,
    this.annotPath,
    this.overlayPath,
    required this.createdAt,
  });

  bool get hasOcr => ocrPath != null;

  /// Path of the image that represents the page (processed if available).
  String get displayPath => processedPath ?? originalPath;

  Map<String, Object?> toRow() => {
        'id': id,
        'doc_id': docId,
        'position': position,
        'original_path': originalPath,
        'processed_path': processedPath,
        'thumb_path': thumbPath,
        'edit_json': edit.encode(),
        'ocr_text': ocrText,
        'ocr_lang': ocrLang,
        'ocr_path': ocrPath,
        'width': width,
        'height': height,
        'flags': flags.join(','),
        'hash': hash,
        'annot_path': annotPath,
        'overlay_path': overlayPath,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory DocPage.fromRow(Map<String, Object?> r) => DocPage(
        id: r['id'] as String,
        docId: r['doc_id'] as String,
        position: (r['position'] as num?)?.toInt() ?? 0,
        originalPath: r['original_path'] as String,
        processedPath: r['processed_path'] as String?,
        thumbPath: r['thumb_path'] as String?,
        edit: PageEdit.decode(r['edit_json'] as String?),
        ocrText: r['ocr_text'] as String?,
        ocrLang: r['ocr_lang'] as String?,
        ocrPath: r['ocr_path'] as String?,
        width: (r['width'] as num?)?.toInt() ?? 0,
        height: (r['height'] as num?)?.toInt() ?? 0,
        flags: ((r['flags'] as String?) ?? '').split(',').where((e) => e.isNotEmpty).toList(),
        hash: r['hash'] as String?,
        annotPath: r['annot_path'] as String?,
        overlayPath: r['overlay_path'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch((r['created_at'] as num?)?.toInt() ?? 0),
      );
}

class Folder {
  final String id;
  final String name;
  final DateTime createdAt;
  const Folder(this.id, this.name, this.createdAt);
}

class SearchHit {
  final ScanDocument document;
  final String? pageId;
  final int? pageIndex;
  final String? snippet;
  final bool titleMatch;
  const SearchHit(this.document, {this.pageId, this.pageIndex, this.snippet, this.titleMatch = false});
}

/// Quality flags detected on capture/import.
class QualityFlag {
  static const blurry = 'blurry';
  static const dark = 'dark';
  static const overexposed = 'overexposed';
  static const incomplete = 'incomplete';
  static const duplicate = 'duplicate';
  static const lowRes = 'lowres';
  static const downscaled = 'downscaled';

  static String label(String f) => switch (f) {
        blurry => 'Blurry',
        dark => 'Too dark',
        overexposed => 'Overexposed',
        incomplete => 'Edges cut off',
        duplicate => 'Possible duplicate',
        lowRes => 'Low resolution',
        downscaled => 'Downscaled on import',
        _ => f,
      };
}
