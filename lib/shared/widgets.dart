import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/storage.dart';

/// Progress reporter for long operations.
class BusyController {
  final ValueNotifier<String> message;
  final ValueNotifier<double?> progress = ValueNotifier(null);
  bool cancelled = false;
  BusyController(String m) : message = ValueNotifier(m);
  void update(String m, [double? p]) {
    message.value = m;
    progress.value = p;
  }
}

/// Runs [task] while showing a modal progress dialog. Errors are shown as a
/// snackbar and null is returned. Set [cancellable] to show a Cancel button
/// (the task must check `ctl.cancelled`).
Future<T?> runBusy<T>(
  BuildContext context,
  String message,
  Future<T> Function(BusyController ctl) task, {
  bool cancellable = false,
}) async {
  final ctl = BusyController(message);
  final nav = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.maybeOf(context);
  var open = true;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          ValueListenableBuilder<double?>(
            valueListenable: ctl.progress,
            builder: (_, p, __) => SizedBox(width: 36, height: 36, child: CircularProgressIndicator(value: p)),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: ValueListenableBuilder<String>(
              valueListenable: ctl.message,
              builder: (_, m, __) => Text(m),
            ),
          ),
        ]),
        actions: cancellable
            ? [
                TextButton(
                  onPressed: () {
                    ctl.cancelled = true;
                    ctl.update('Cancelling…');
                  },
                  child: const Text('Cancel'),
                )
              ]
            : null,
      ),
    ),
  ).whenComplete(() => open = false));
  try {
    final r = await task(ctl);
    return r;
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(friendlyError(e)), duration: const Duration(seconds: 5)));
    return null;
  } finally {
    if (open) nav.pop();
  }
}

class OperationCancelled implements Exception {
  @override
  String toString() => 'Cancelled';
}

void showSnack(BuildContext context, String text, {SnackBarAction? action}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), action: action));
}

Future<bool> confirm(BuildContext context, String title, String body, {String ok = 'OK', bool destructive = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

Future<String?> promptText(
  BuildContext context,
  String title, {
  String initial = '',
  String? hint,
  String ok = 'Save',
  bool obscure = false,
  List<String> suggestions = const [],
  TextInputType? keyboard,
}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: c,
              autofocus: true,
              obscureText: obscure,
              keyboardType: keyboard,
              decoration: InputDecoration(hintText: hint),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
            if (suggestions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Suggestions', style: Theme.of(ctx).textTheme.labelMedium),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final s in suggestions)
                    ActionChip(
                      label: Text(s, overflow: TextOverflow.ellipsis),
                      onPressed: () => setState(() => c.text = s),
                    ),
                ],
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(ok)),
        ],
      ),
    ),
  );
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 64, color: t.colorScheme.primary.withValues(alpha: 0.6)),
          const SizedBox(height: 16),
          Text(title, style: t.textTheme.titleMedium, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: 8),
            Text(message!, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
          ],
          if (action != null) ...[const SizedBox(height: 20), action!],
        ]),
      ),
    );
  }
}

/// Image from a path relative to app storage (or absolute).
class StoredImage extends StatelessWidget {
  final String? path;
  final BoxFit fit;
  final int? cacheWidth;
  final double? width;
  final double? height;
  const StoredImage(this.path, {super.key, this.fit = BoxFit.cover, this.cacheWidth, this.width, this.height});

  @override
  Widget build(BuildContext context) {
    final p = path;
    final scheme = Theme.of(context).colorScheme;
    if (p == null || p.isEmpty) {
      return Container(
        width: width,
        height: height,
        color: scheme.surfaceContainerHighest,
        child: Icon(Icons.description_outlined, color: scheme.onSurfaceVariant),
      );
    }
    return Image.file(
      File(AppStorage.instance.abs(p)),
      fit: fit,
      width: width,
      height: height,
      cacheWidth: cacheWidth,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => Container(
        width: width,
        height: height,
        color: scheme.surfaceContainerHighest,
        child: Icon(Icons.broken_image_outlined, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

class FlagChips extends StatelessWidget {
  final List<String> flags;
  final bool dense;
  const FlagChips(this.flags, {super.key, this.dense = false});

  @override
  Widget build(BuildContext context) {
    if (flags.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final f in flags)
          Container(
            padding: EdgeInsets.symmetric(horizontal: dense ? 4 : 8, vertical: dense ? 1 : 3),
            decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(6)),
            child: Text(QualityFlag.label(f),
                style: TextStyle(fontSize: dense ? 9 : 11, color: scheme.onErrorContainer, fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const SectionHeader(this.title, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 8, 8),
        child: Row(children: [
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
          if (trailing != null) trailing!,
        ]),
      );
}

/// Labelled slider used by editors.
class LabeledSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final String Function(double)? format;
  const LabeledSlider({
    super.key,
    required this.label,
    required this.value,
    this.min = -1,
    this.max = 1,
    required this.onChanged,
    this.onChangeEnd,
    this.format,
  });

  @override
  Widget build(BuildContext context) {
    final f = format ?? (v) => (v * 100).round().toString();
    return Row(children: [
      SizedBox(width: 96, child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
      Expanded(
        child: Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
          semanticFormatterCallback: (v) => '$label ${f(v)}',
        ),
      ),
      SizedBox(width: 40, child: Text(f(value), textAlign: TextAlign.end, style: Theme.of(context).textTheme.bodySmall)),
    ]);
  }
}
