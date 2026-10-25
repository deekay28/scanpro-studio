import 'dart:convert';

import 'package:sqflite/sqflite.dart';

/// An ID/passport photo specification. All presets are editable; values
/// are common published sizes but official requirements change and vary
/// by issuing office, so the UI always labels them "verify before use".
class PhotoPreset {
  final String id;
  final String name;
  final String category; // passport | visa | id | job | student | custom
  final double widthMm;
  final double heightMm;
  final int dpi;
  final int backgroundArgb;

  /// Head height (chin to crown) as a fraction of photo height.
  final double headMin;
  final double headMax;

  /// Distance from the photo top to the crown, fraction of photo height.
  final double topMargin;
  final String notes;
  final bool builtIn;

  const PhotoPreset({
    required this.id,
    required this.name,
    required this.category,
    required this.widthMm,
    required this.heightMm,
    this.dpi = 600,
    this.backgroundArgb = 0xFFFFFFFF,
    this.headMin = 0.62,
    this.headMax = 0.78,
    this.topMargin = 0.08,
    this.notes = '',
    this.builtIn = false,
  });

  double get aspect => heightMm / widthMm;
  int get pixelWidth => (widthMm / 25.4 * dpi).round();
  int get pixelHeight => (heightMm / 25.4 * dpi).round();
  String get sizeLabel => '${_f(widthMm)} × ${_f(heightMm)} mm';
  static String _f(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  PhotoPreset copyWith({
    String? id,
    String? name,
    String? category,
    double? widthMm,
    double? heightMm,
    int? dpi,
    int? backgroundArgb,
    double? headMin,
    double? headMax,
    double? topMargin,
    String? notes,
    bool? builtIn,
  }) =>
      PhotoPreset(
        id: id ?? this.id,
        name: name ?? this.name,
        category: category ?? this.category,
        widthMm: widthMm ?? this.widthMm,
        heightMm: heightMm ?? this.heightMm,
        dpi: dpi ?? this.dpi,
        backgroundArgb: backgroundArgb ?? this.backgroundArgb,
        headMin: headMin ?? this.headMin,
        headMax: headMax ?? this.headMax,
        topMargin: topMargin ?? this.topMargin,
        notes: notes ?? this.notes,
        builtIn: builtIn ?? this.builtIn,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'category': category,
        'w': widthMm,
        'h': heightMm,
        'dpi': dpi,
        'bg': backgroundArgb,
        'headMin': headMin,
        'headMax': headMax,
        'top': topMargin,
        'notes': notes,
        'builtIn': builtIn,
      };

  factory PhotoPreset.fromJson(Map<String, dynamic> j) => PhotoPreset(
        id: j['id'] as String,
        name: j['name'] as String,
        category: j['category'] as String? ?? 'custom',
        widthMm: (j['w'] as num).toDouble(),
        heightMm: (j['h'] as num).toDouble(),
        dpi: (j['dpi'] as num?)?.toInt() ?? 600,
        backgroundArgb: (j['bg'] as num?)?.toInt() ?? 0xFFFFFFFF,
        headMin: (j['headMin'] as num?)?.toDouble() ?? 0.62,
        headMax: (j['headMax'] as num?)?.toDouble() ?? 0.78,
        topMargin: (j['top'] as num?)?.toDouble() ?? 0.08,
        notes: j['notes'] as String? ?? '',
        builtIn: j['builtIn'] as bool? ?? false,
      );

  /// Validation messages (empty when valid).
  List<String> validate() {
    final e = <String>[];
    if (name.trim().isEmpty) e.add('Name is required');
    if (widthMm < 10 || widthMm > 200) e.add('Width must be 10-200 mm');
    if (heightMm < 10 || heightMm > 250) e.add('Height must be 10-250 mm');
    if (dpi < 150 || dpi > 1200) e.add('DPI must be 150-1200');
    if (headMin <= 0 || headMax > 1 || headMin > headMax) e.add('Head height range is invalid');
    if (topMargin < 0 || topMargin > 0.4) e.add('Top margin must be 0-40%');
    return e;
  }
}

/// Built-in starting points. Sizes reflect commonly published requirements
/// at the time of writing and MUST be verified against the current official
/// guidance of the issuing authority.
const builtInPresets = <PhotoPreset>[
  PhotoPreset(
    id: 'in_passport',
    name: 'India passport (35×45)',
    category: 'passport',
    widthMm: 35,
    heightMm: 45,
    headMin: 0.62,
    headMax: 0.80,
    topMargin: 0.08,
    notes: 'Commonly used for Indian passport applications. Plain white/light background, face centred, no shadows. Verify current Passport Seva guidance.',
    builtIn: true,
  ),
  PhotoPreset(
    id: 'in_2x2',
    name: 'India passport/OCI (2×2 in)',
    category: 'passport',
    widthMm: 50.8,
    heightMm: 50.8,
    headMin: 0.50,
    headMax: 0.69,
    topMargin: 0.12,
    notes: 'Some Indian missions abroad and OCI services ask for 2×2 inch photos. Verify the exact requirement for your application.',
    builtIn: true,
  ),
  PhotoPreset(
    id: 'us_visa',
    name: 'US passport / visa (2×2 in)',
    category: 'visa',
    widthMm: 50.8,
    heightMm: 50.8,
    headMin: 0.50,
    headMax: 0.69,
    topMargin: 0.10,
    notes: 'Head 1–1⅜ in (25–35 mm) chin to crown, white background. Verify at travel.state.gov.',
    builtIn: true,
  ),
  PhotoPreset(
    id: 'schengen',
    name: 'Schengen / UK visa (35×45)',
    category: 'visa',
    widthMm: 35,
    heightMm: 45,
    backgroundArgb: 0xFFEDEDED,
    headMin: 0.70,
    headMax: 0.80,
    topMargin: 0.07,
    notes: 'Face 32–36 mm (70–80%). Light grey or white background depending on country. Verify with the consulate.',
    builtIn: true,
  ),
  PhotoPreset(
    id: 'canada',
    name: 'Canada passport (50×70)',
    category: 'passport',
    widthMm: 50,
    heightMm: 70,
    headMin: 0.44,
    headMax: 0.51,
    topMargin: 0.12,
    notes: 'Face 31–36 mm chin to crown. Verify current IRCC guidance.',
    builtIn: true,
  ),
  PhotoPreset(
    id: 'china_visa',
    name: 'China visa (33×48)',
    category: 'visa',
    widthMm: 33,
    heightMm: 48,
    headMin: 0.58,
    headMax: 0.71,
    topMargin: 0.07,
    notes: 'Head 28–33 mm. Verify with the visa centre.',
    builtIn: true,
  ),
  PhotoPreset(
    id: 'stamp',
    name: 'Stamp size (20×25)',
    category: 'id',
    widthMm: 20,
    heightMm: 25,
    headMin: 0.55,
    headMax: 0.80,
    topMargin: 0.08,
    notes: 'Used on some Indian forms and certificates.',
    builtIn: true,
  ),
  PhotoPreset(
    id: 'id_card',
    name: 'ID card (25×30)',
    category: 'id',
    widthMm: 25,
    heightMm: 30,
    headMin: 0.55,
    headMax: 0.75,
    notes: 'Typical employee/ID card photo. Check your organisation\'s template.',
    builtIn: true,
  ),
  PhotoPreset(
    id: 'student',
    name: 'Student ID (30×35)',
    category: 'student',
    widthMm: 30,
    heightMm: 35,
    backgroundArgb: 0xFFDCEBFA,
    headMin: 0.55,
    headMax: 0.75,
    notes: 'Common school/college ID size. Check your institution.',
    builtIn: true,
  ),
  PhotoPreset(
    id: 'job',
    name: 'Job application (35×45)',
    category: 'job',
    widthMm: 35,
    heightMm: 45,
    headMin: 0.55,
    headMax: 0.72,
    notes: 'Professional portrait for CVs and forms.',
    builtIn: true,
  ),
];

/// Persistence of user presets (built-ins can be overridden by editing).
class PresetStore {
  PresetStore(this.db);
  final Database db;

  Future<List<PhotoPreset>> load() async {
    final rows = await db.query('photo_presets', orderBy: 'position ASC');
    final custom = <String, PhotoPreset>{};
    for (final r in rows) {
      try {
        final p = PhotoPreset.fromJson(jsonDecode(r['data'] as String) as Map<String, dynamic>);
        custom[p.id] = p;
      } catch (_) {}
    }
    final out = <PhotoPreset>[];
    for (final b in builtInPresets) {
      out.add(custom.remove(b.id) ?? b);
    }
    out.addAll(custom.values);
    return out;
  }

  Future<void> save(PhotoPreset p, {int position = 999}) async {
    await db.insert('photo_presets', {'id': p.id, 'data': jsonEncode(p.toJson()), 'position': position},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> delete(String id) async {
    await db.delete('photo_presets', where: 'id = ?', whereArgs: [id]);
  }
}

/// Background colour choices.
const backgroundChoices = <(String, int)>[
  ('White', 0xFFFFFFFF),
  ('Off-white', 0xFFF6F6F2),
  ('Light grey', 0xFFE6E6E6),
  ('Light blue', 0xFFD6E6F5),
  ('Sky blue', 0xFFA9CCEB),
  ('Red', 0xFFD32F2F),
];
