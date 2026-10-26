import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/ids.dart';
import 'conversion_service.dart';

enum JobStatus { queued, running, done, failed, cancelled, interrupted }

class JobInput {
  final String path; // copy in the job folder
  final String name;
  final bool encrypted;
  const JobInput(this.path, this.name, {this.encrypted = false});
  Map<String, dynamic> toJson() => {'p': path, 'n': name, 'e': encrypted};
  factory JobInput.fromJson(Map<String, dynamic> j) => JobInput(j['p'] as String, j['n'] as String, encrypted: j['e'] as bool? ?? false);
}

class ConversionJob {
  final String id;
  final ConversionType type;
  final List<JobInput> inputs;
  final ConversionOptions options;
  final String outputName;
  final DateTime created;
  JobStatus status;
  double progress;
  String message;
  List<ConversionOutput> outputs;
  List<String> warnings;
  String? error;
  DateTime? finished;
  CancelToken? _cancel;
  // Passwords live in memory only; they are never written to disk.
  final Map<String, String> passwords = {};

  ConversionJob({
    required this.id,
    required this.type,
    required this.inputs,
    required this.options,
    required this.outputName,
    required this.created,
    this.status = JobStatus.queued,
    this.progress = 0,
    this.message = '',
    this.outputs = const [],
    this.warnings = const [],
    this.error,
    this.finished,
  });

  String get dir => p.dirname(p.dirname(inputs.isEmpty ? '' : inputs.first.path));
  bool get active => status == JobStatus.queued || status == JobStatus.running;
  bool get canRetry => status == JobStatus.failed || status == JobStatus.cancelled || status == JobStatus.interrupted;

  Map<String, dynamic> toJson() => {
        'id': id,
        't': type.name,
        'in': [for (final i in inputs) i.toJson()],
        'o': options.toJson(),
        'on': outputName,
        'c': created.toIso8601String(),
        's': status.name,
        'out': [for (final o in outputs) o.toJson()],
        'w': warnings,
        if (error != null) 'e': error,
        if (finished != null) 'f': finished!.toIso8601String(),
      };

  factory ConversionJob.fromJson(Map<String, dynamic> j) => ConversionJob(
        id: j['id'] as String,
        type: ConversionType.values.firstWhere((e) => e.name == j['t']),
        inputs: [for (final i in j['in'] as List) JobInput.fromJson(i as Map<String, dynamic>)],
        options: ConversionOptions.fromJson(j['o'] as Map<String, dynamic>),
        outputName: j['on'] as String,
        created: DateTime.parse(j['c'] as String),
        status: JobStatus.values.firstWhere((e) => e.name == j['s'], orElse: () => JobStatus.failed),
        outputs: [for (final o in (j['out'] as List?) ?? const []) ConversionOutput.fromJson(o as Map<String, dynamic>)],
        warnings: ((j['w'] as List?) ?? const []).cast<String>(),
        error: j['e'] as String?,
        finished: j['f'] == null ? null : DateTime.tryParse(j['f'] as String),
      );
}

typedef JobRunner = Future<ConversionResult> Function(ConversionJob job, String outDir, void Function(double, String) onProgress, CancelToken cancel);

/// Queue and history of conversion jobs. Jobs run one at a time in the
/// background (the heavy work happens off the UI isolate). The queue is
/// saved to disk, so after the app is closed or killed, unfinished jobs are
/// shown as "interrupted" and can be retried; their input copies are kept.
class ConversionJobManager extends ChangeNotifier {
  final String root; // absolute directory for job folders and the history
  final JobRunner runner;
  final int historyLimit;
  final List<ConversionJob> jobs = [];
  bool _running = false;

  ConversionJobManager({required this.root, required this.runner, this.historyLimit = 100});

  File get _file => File(p.join(root, 'jobs.json'));

  Future<void> load() async {
    jobs.clear();
    try {
      if (await _file.exists()) {
        final list = jsonDecode(await _file.readAsString()) as List;
        for (final j in list) {
          try {
            final job = ConversionJob.fromJson(j as Map<String, dynamic>);
            if (job.status == JobStatus.running || job.status == JobStatus.queued) {
              job.status = JobStatus.interrupted;
              job.error = 'The app was closed before this conversion finished.';
            }
            jobs.add(job);
          } catch (_) {}
        }
      }
    } catch (_) {
      // A damaged history file is ignored rather than blocking conversions.
    }
    notifyListeners();
    await _persist();
  }

  Future<void> _chain = Future.value();

  /// Writes the history. Writes are serialised so overlapping calls never
  /// race on the temporary file.
  Future<void> _persist() {
    final snapshot = jsonEncode([for (final j in jobs) j.toJson()]);
    return _chain = _chain.then((_) async {
      await Directory(root).create(recursive: true);
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(snapshot, flush: true);
      await tmp.rename(_file.path);
    }).catchError((Object _) {});
  }

  /// Copies the inputs into a job folder and queues the job.
  Future<ConversionJob> enqueue(ConversionType type, List<(String path, String name)> inputs, ConversionOptions options, String outputName,
      {Map<String, String> passwords = const {}, Set<String> encrypted = const {}}) async {
    if (inputs.isEmpty) throw const FormatException('Select at least one file.');
    final id = newId();
    final dir = p.join(root, id);
    final inDir = p.join(dir, 'in');
    await Directory(inDir).create(recursive: true);
    final copies = <JobInput>[];
    for (var i = 0; i < inputs.length; i++) {
      final (path, name) = inputs[i];
      final ext = p.extension(name).toLowerCase();
      if (!type.sources.contains(ext.replaceFirst('.', ''))) {
        await Directory(dir).delete(recursive: true);
        throw FormatException('$name is not a ${type.sources.map((e) => e.toUpperCase()).join('/')} file.');
      }
      final target = p.join(inDir, '${i.toString().padLeft(3, '0')}$ext');
      await File(path).copy(target);
      copies.add(JobInput(target, name, encrypted: encrypted.contains(name)));
    }
    final job = ConversionJob(id: id, type: type, inputs: copies, options: options, outputName: outputName, created: DateTime.now());
    job.passwords.addAll(passwords);
    jobs.insert(0, job);
    _trim();
    await _persist();
    notifyListeners();
    unawaited(_pump());
    return job;
  }

  void _trim() {
    while (jobs.length > historyLimit) {
      final old = jobs.lastWhere((j) => !j.active, orElse: () => jobs.last);
      if (old.active) break;
      jobs.remove(old);
      final d = Directory(old.dir);
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final next = jobs.reversed.where((j) => j.status == JobStatus.queued).firstOrNull;
        if (next == null) break;
        await _runJob(next);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _runJob(ConversionJob job) async {
    job.status = JobStatus.running;
    job.progress = 0;
    job.message = 'Starting…';
    job.error = null;
    job.warnings = [];
    job._cancel = CancelToken();
    await _persist();
    notifyListeners();
    final outDir = p.join(job.dir, 'out');
    final out = Directory(outDir);
    if (await out.exists()) await out.delete(recursive: true);
    try {
      final r = await runner(job, outDir, (v, m) {
        job.progress = v;
        job.message = m;
        notifyListeners();
      }, job._cancel!);
      if (r.outputs.isEmpty) throw const FormatException('No output was produced.');
      job.outputs = r.outputs;
      job.warnings = r.warnings;
      job.status = JobStatus.done;
      job.progress = 1;
      job.message = '${r.outputs.length} file(s) created and checked';
    } on ConversionCancelled {
      job.status = JobStatus.cancelled;
      job.message = 'Cancelled';
      if (await out.exists()) await out.delete(recursive: true);
    } catch (e) {
      job.status = JobStatus.failed;
      job.error = describeError(e);
      job.message = 'Failed';
      if (await out.exists()) await out.delete(recursive: true);
    } finally {
      job.finished = DateTime.now();
      job._cancel = null;
      await _persist();
      notifyListeners();
    }
  }

  void cancel(ConversionJob job) {
    if (job.status == JobStatus.queued) {
      job.status = JobStatus.cancelled;
      job.message = 'Cancelled';
      _persist();
      notifyListeners();
    } else {
      job._cancel?.cancelled = true;
    }
  }

  Future<void> retry(ConversionJob job, {Map<String, String> passwords = const {}}) async {
    if (!job.canRetry) return;
    for (final i in job.inputs) {
      if (!await File(i.path).exists()) {
        job.error = 'The input file ${i.name} is no longer available. Start a new conversion.';
        notifyListeners();
        return;
      }
    }
    job.passwords.addAll(passwords);
    job.status = JobStatus.queued;
    job.progress = 0;
    job.message = 'Queued';
    await _persist();
    notifyListeners();
    unawaited(_pump());
  }

  Future<void> remove(ConversionJob job) async {
    if (job.active) cancel(job);
    jobs.remove(job);
    final d = Directory(job.dir);
    if (await d.exists()) await d.delete(recursive: true);
    await _persist();
    notifyListeners();
  }

  Future<void> clearFinished() async {
    for (final j in [...jobs]) {
      if (!j.active) await remove(j);
    }
  }

  /// Overall progress of queued and running jobs (0..1), or null when idle.
  double? get overallProgress {
    final act = jobs.where((j) => j.active).toList();
    if (act.isEmpty) return null;
    return act.fold<double>(0, (a, j) => a + j.progress) / act.length;
  }

  /// Waits until no job is queued or running (for tests and batch screens).
  Future<void> idle() async {
    while (jobs.any((j) => j.active)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

/// A short, user-facing error message (never includes document content).
String describeError(Object e) {
  final s = e.toString();
  if (s.contains('No space left') || s.contains('Not enough storage') || s.contains('errno = 28')) return 'Not enough storage space.';
  if (e is FormatException) return e.message;
  if (s.contains('password') || s.contains('Password')) return 'The file is password protected; enter its password to retry.';
  if (e is FileSystemException) return 'A file could not be read or written (${e.message}).';
  final cleaned = s.replaceFirst(RegExp(r'^(Exception|PdfEditException|StateError|Bad state): '), '');
  return cleaned.length > 300 ? '${cleaned.substring(0, 300)}…' : cleaned;
}
