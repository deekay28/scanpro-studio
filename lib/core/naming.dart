import 'ids.dart';

/// File-name helpers. Produces names that are safe on Android SAF, Windows
/// and common cloud drives.
class Naming {
  static final _illegal = RegExp(r'[\\/:*?"<>|\x00-\x1F]');
  static final _spaces = RegExp(r'\s+');

  static String sanitize(String input, {int maxLength = 80, String fallback = 'Document'}) {
    var s = input.replaceAll(_illegal, ' ').replaceAll(_spaces, ' ').trim();
    // Remove leading/trailing dots (hidden files / Windows issues).
    s = s.replaceAll(RegExp(r'^\.+|\.+$'), '').trim();
    if (s.isEmpty) s = fallback;
    if (s.length > maxLength) s = s.substring(0, maxLength).trim();
    return s;
  }

  static String withExtension(String title, String ext) {
    final e = ext.startsWith('.') ? ext.substring(1) : ext;
    final base = sanitize(title);
    if (base.toLowerCase().endsWith('.${e.toLowerCase()}')) return base;
    return '$base.$e';
  }

  static String defaultScanTitle([DateTime? now]) {
    final d = now ?? DateTime.now();
    return 'Scan ${formatDate(d)} ${two(d.hour)}.${two(d.minute)}';
  }

  /// Returns [name] or "name (2)", "name (3)"... so it does not collide with [existing].
  static String unique(String name, Iterable<String> existing) {
    final set = existing.map((e) => e.toLowerCase()).toSet();
    if (!set.contains(name.toLowerCase())) return name;
    var i = 2;
    while (set.contains('$name ($i)'.toLowerCase())) {
      i++;
    }
    return '$name ($i)';
  }
}
