import 'dart:math';

final Random _rng = Random.secure();

/// Short, sortable, collision-resistant identifier.
String newId() {
  final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final r = List.generate(6, (_) => _rng.nextInt(36).toRadixString(36)).join();
  return '$t$r';
}

String two(int v) => v.toString().padLeft(2, '0');

String formatDate(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';

String formatDateTime(DateTime d) => '${formatDate(d)} ${two(d.hour)}:${two(d.minute)}';

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String relativeTime(DateTime d) {
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  if (diff.inDays < 7) return '${diff.inDays} d ago';
  return formatDate(d);
}
