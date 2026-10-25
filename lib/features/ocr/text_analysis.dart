import '../../core/ids.dart';
import '../../core/ocr_models.dart';

/// Pattern-based extraction from OCR text. Everything here is heuristic:
/// results are suggestions shown for the user to confirm, never facts.
class ExtractedEntities {
  final List<String> dates;
  final List<String> amounts;
  final String? total;
  final List<String> phones;
  final List<String> emails;
  final List<String> urls;
  final List<String> gstins;
  const ExtractedEntities({
    this.dates = const [],
    this.amounts = const [],
    this.total,
    this.phones = const [],
    this.emails = const [],
    this.urls = const [],
    this.gstins = const [],
  });

  bool get isEmpty =>
      dates.isEmpty && amounts.isEmpty && total == null && phones.isEmpty && emails.isEmpty && urls.isEmpty && gstins.isEmpty;
}

class TextAnalysis {
  static const _months = 'jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec|january|february|march|april|june|july|august|september|october|november|december';

  static final _datePatterns = [
    RegExp(r'\b(\d{1,2})[./-](\d{1,2})[./-](\d{4}|\d{2})\b'),
    RegExp(r'\b(\d{4})[./-](\d{1,2})[./-](\d{1,2})\b'),
    RegExp('\\b(\\d{1,2})(?:st|nd|rd|th)?[\\s-]+($_months)[a-z]*[\\s,.-]+(\\d{4})\\b', caseSensitive: false),
    RegExp('\\b($_months)[a-z]*[\\s.-]+(\\d{1,2})(?:st|nd|rd|th)?,?\\s+(\\d{4})\\b', caseSensitive: false),
  ];

  static final _amount = RegExp(
    r'(?:₹|rs\.?|inr|\$|usd|€|eur|£|gbp)\s*([0-9]{1,3}(?:[,\s][0-9]{2,3})*(?:\.[0-9]{1,2})?|[0-9]+(?:\.[0-9]{1,2})?)',
    caseSensitive: false,
  );
  static final _plainAmount = RegExp(r'\b([0-9]{1,3}(?:,[0-9]{2,3})+(?:\.[0-9]{2})|[0-9]+\.[0-9]{2})\b');
  static final _totalLine = RegExp(r'(grand\s*total|total\s*amount|amount\s*due|net\s*payable|balance\s*due|total|कुल)', caseSensitive: false);
  static final _phone = RegExp(r'(?<![\d])(?:\+?\d{1,3}[\s-]?)?(?:\(?\d{2,5}\)?[\s-]?)?\d{3,5}[\s-]?\d{4,5}(?![\d])');
  static final _email = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');
  static final _url = RegExp(r'\b(?:https?://|www\.)[^\s]+', caseSensitive: false);
  static final _gstin = RegExp(r'\b\d{2}[A-Z]{5}\d{4}[A-Z][1-9A-Z]Z[0-9A-Z]\b');

  static ExtractedEntities extract(String text) {
    final dates = <String>{};
    for (final r in _datePatterns) {
      for (final m in r.allMatches(text)) {
        final s = m.group(0)!.trim();
        if (_plausibleDate(s)) dates.add(s);
      }
    }
    final amounts = <String>{};
    for (final m in _amount.allMatches(text)) {
      amounts.add(m.group(0)!.trim());
    }
    String? total;
    double best = -1;
    for (final line in text.split('\n')) {
      if (!_totalLine.hasMatch(line)) continue;
      for (final m in [..._amount.allMatches(line), ..._plainAmount.allMatches(line)]) {
        final v = parseAmount(m.group(m.groupCount >= 1 ? 1 : 0) ?? '');
        if (v != null && v > best) {
          best = v;
          total = m.group(0)!.trim();
        }
      }
    }
    final phones = <String>{};
    for (final m in _phone.allMatches(text)) {
      final s = m.group(0)!.trim();
      final digits = s.replaceAll(RegExp(r'\D'), '');
      if (digits.length >= 10 && digits.length <= 13 && !dates.any((d) => d.replaceAll(RegExp(r'\D'), '') == digits)) {
        phones.add(s);
      }
    }
    return ExtractedEntities(
      dates: dates.toList(),
      amounts: amounts.toList(),
      total: total,
      phones: phones.toList(),
      emails: _email.allMatches(text).map((m) => m.group(0)!).toSet().toList(),
      urls: _url.allMatches(text).map((m) => m.group(0)!).toSet().toList(),
      gstins: _gstin.allMatches(text).map((m) => m.group(0)!).toSet().toList(),
    );
  }

  static bool _plausibleDate(String s) {
    final nums = RegExp(r'\d+').allMatches(s).map((m) => int.parse(m.group(0)!)).toList();
    if (nums.length == 3) {
      final hasYear4 = nums.any((n) => n >= 1900 && n <= 2100);
      final first = nums[0], second = nums[1];
      if (nums[0] >= 1900) return second >= 1 && second <= 12 && nums[2] >= 1 && nums[2] <= 31;
      final dayMonthOk = (first >= 1 && first <= 31 && second >= 1 && second <= 12) || (first >= 1 && first <= 12 && second >= 1 && second <= 31);
      return dayMonthOk && (hasYear4 || nums[2] < 100);
    }
    return nums.length == 2; // textual month forms
  }

  static double? parseAmount(String s) {
    final cleaned = s.replaceAll(RegExp(r'[^0-9.]'), '');
    return double.tryParse(cleaned);
  }

  /// Simple keyword classifier for common document types.
  static String? classify(String text) {
    final t = text.toLowerCase();
    int score(List<String> words) => words.where((w) => t.contains(w)).length;
    final scores = <String, int>{
      'Invoice': score(['invoice', 'tax invoice', 'gstin', 'bill to', 'invoice no', 'hsn', 'due date']),
      'Receipt': score(['receipt', 'cash', 'change', 'thank you', 'paid', 'txn', 'transaction', 'upi']),
      'Certificate': score(['certificate', 'certify', 'certified', 'awarded', 'has successfully', 'completion']),
      'Bank statement': score(['statement', 'account number', 'opening balance', 'closing balance', 'ifsc', 'withdrawal', 'deposit']),
      'Letter': score(['dear', 'sincerely', 'regards', 'subject:', 'yours faithfully', 'to whom it may concern']),
      'Form': score(['application form', 'signature of', 'please fill', 'name of applicant', 'date of birth', 'form no']),
      'ID document': score(['government of india', 'date of birth', 'dob', 'identity', 'card no', 'republic of india', 'income tax department']),
      'Resume': score(['curriculum vitae', 'resume', 'experience', 'education', 'skills', 'objective']),
      'Prescription': score(['rx', 'prescription', 'dr.', 'tablet', 'mg', 'twice daily']),
      'Contract': score(['agreement', 'party', 'parties', 'hereinafter', 'terms and conditions', 'witness']),
    };
    final best = scores.entries.reduce((a, b) => b.value > a.value ? b : a);
    return best.value >= 2 ? best.key : null;
  }

  /// Suggests document titles from OCR text. Always includes a date-based
  /// default. The user reviews and edits before saving.
  static List<String> suggestNames(String text, {DateTime? now}) {
    final d = now ?? DateTime.now();
    final out = <String>[];
    final type = classify(text);
    final entities = extract(text);
    final date = entities.dates.isNotEmpty ? entities.dates.first.replaceAll('/', '-') : formatDate(d);
    final heading = _heading(text);
    if (type != null && heading != null) out.add('$type - $heading - $date');
    if (type != null) out.add('$type $date');
    if (heading != null) out.add(heading);
    out.add('Scan ${formatDate(d)}');
    return out.toSet().toList();
  }

  /// First meaningful line (likely a title, vendor or heading).
  static String? _heading(String text) {
    for (final raw in text.split('\n').take(8)) {
      final l = raw.trim();
      if (l.length < 4 || l.length > 48) continue;
      final letters = RegExp(r'\p{L}', unicode: true).allMatches(l).length;
      if (letters < l.length * 0.6) continue;
      return l.replaceAll(RegExp(r'\s+'), ' ');
    }
    return null;
  }

  /// Heuristic review flag for a recognised line. Used when the engine does
  /// not expose a confidence value (or in addition to it).
  static bool needsReview(String line, {double? confidence}) {
    if (confidence != null && confidence < 0.6) return true;
    final s = line.trim();
    if (s.isEmpty) return false;
    if (s.contains('�')) return true;
    final symbols = RegExp(r'[^\p{L}\p{N}\p{M}\s.,:;()\-/₹$%&@#+]', unicode: true).allMatches(s).length;
    if (symbols / s.length > 0.25) return true;
    // Mixed letters and digits inside one word ("0rder", "l0an", "5ection").
    final words = s.split(RegExp(r'\s+'));
    var weird = 0;
    for (final w in words) {
      if (w.length >= 3 && RegExp(r'[A-Za-z]').hasMatch(w) && RegExp(r'\d').hasMatch(w) && !RegExp(r'^\d+[A-Za-z]{1,3}$').hasMatch(w)) {
        if (!RegExp(r'^[A-Z0-9-]+$').hasMatch(w)) weird++;
      }
    }
    if (words.isNotEmpty && weird / words.length > 0.3) return true;
    // Latin and Devanagari letters mixed inside the same word.
    for (final w in words) {
      if (RegExp(r'[A-Za-z]').hasMatch(w) && RegExp(r'[ऀ-ॿ]').hasMatch(w)) return true;
    }
    return false;
  }

  /// Best-effort table reconstruction from line boxes. Lines are grouped
  /// into rows by vertical overlap, and columns are inferred from the x
  /// positions of cell starts. Returns rows of cells.
  static List<List<String>> extractTable(List<OcrLine> lines) {
    if (lines.isEmpty) return const [];
    final sorted = [...lines]..sort((a, b) => a.centerY.compareTo(b.centerY));
    final rows = <List<OcrLine>>[];
    for (final l in sorted) {
      if (rows.isNotEmpty) {
        final last = rows.last;
        final refTop = last.map((e) => e.top).reduce((a, b) => a < b ? a : b);
        final refBot = last.map((e) => e.bottom).reduce((a, b) => a > b ? a : b);
        final overlap = (l.bottom < refBot ? l.bottom : refBot) - (l.top > refTop ? l.top : refTop);
        if (overlap > 0.5 * l.height) {
          last.add(l);
          continue;
        }
      }
      rows.add([l]);
    }
    for (final r in rows) {
      r.sort((a, b) => a.left.compareTo(b.left));
    }
    // Column anchors from cell left edges.
    final lefts = [for (final r in rows) for (final c in r) c.left]..sort();
    final heights = [for (final l in lines) l.height]..sort();
    final tol = heights[heights.length ~/ 2] * 1.5;
    final anchors = <double>[];
    for (final x in lefts) {
      if (anchors.isEmpty || x - anchors.last > tol) anchors.add(x);
    }
    final table = <List<String>>[];
    for (final r in rows) {
      final cells = List<String>.filled(anchors.length, '');
      for (final c in r) {
        var idx = 0;
        var bestD = double.infinity;
        for (var i = 0; i < anchors.length; i++) {
          final d = (c.left - anchors[i]).abs();
          if (d < bestD) {
            bestD = d;
            idx = i;
          }
        }
        cells[idx] = cells[idx].isEmpty ? c.text : '${cells[idx]} ${c.text}';
      }
      table.add(cells);
    }
    // Drop columns that are always empty.
    final keep = <int>[];
    for (var i = 0; i < anchors.length; i++) {
      if (table.any((r) => r[i].isNotEmpty)) keep.add(i);
    }
    return [for (final r in table) [for (final i in keep) r[i]]];
  }

  static String toCsv(List<List<String>> rows) {
    String esc(String s) {
      final needs = s.contains(',') || s.contains('"') || s.contains('\n');
      final v = s.replaceAll('"', '""');
      return needs ? '"$v"' : v;
    }

    return rows.map((r) => r.map(esc).join(',')).join('\r\n');
  }
}
