/// Builds a safe FTS4 MATCH expression from free text typed by the user.
///
/// * Words are ANDed.
/// * Text in double quotes is searched as a phrase.
/// * The last bare word gets a prefix wildcard so results appear while typing.
/// * FTS operators and punctuation are stripped to avoid syntax errors.
String? buildFtsQuery(String input) {
  final s = input.trim();
  if (s.isEmpty) return null;
  final parts = <String>[];
  final phrase = RegExp(r'"([^"]+)"');
  var rest = s;
  for (final m in phrase.allMatches(s)) {
    final words = _tokens(m.group(1)!);
    if (words.isNotEmpty) parts.add('"${words.join(' ')}"');
  }
  rest = s.replaceAll(phrase, ' ');
  final words = _tokens(rest);
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    final isLast = i == words.length - 1;
    parts.add(isLast && w.length >= 2 ? '$w*' : w);
  }
  if (parts.isEmpty) return null;
  return parts.join(' ');
}

const _ftsKeywords = {'and', 'or', 'not', 'near'};

List<String> _tokens(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}\p{M}]+', unicode: true), ' ')
    .split(' ')
    .where((w) => w.isNotEmpty && !_ftsKeywords.contains(w))
    .toList();

/// Words for LIKE-based fallback search.
List<String> likeTerms(String input) => _tokens(input);

/// Extracts a short snippet around the first occurrence of any term.
String makeSnippet(String text, List<String> terms, {int radius = 48}) {
  final lower = text.toLowerCase();
  var idx = -1;
  for (final t in terms) {
    idx = lower.indexOf(t.toLowerCase());
    if (idx >= 0) break;
  }
  if (idx < 0) return text.length > radius * 2 ? '${text.substring(0, radius * 2)}…' : text;
  final start = (idx - radius) < 0 ? 0 : idx - radius;
  final end = (idx + radius) > text.length ? text.length : idx + radius;
  final pre = start > 0 ? '…' : '';
  final post = end < text.length ? '…' : '';
  return '$pre${text.substring(start, end).replaceAll('\n', ' ')}$post';
}
