import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import '../../core/ids.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/repository.dart';
import '../../shared/widgets.dart';
import '../backup/backup_service.dart';
import 'app_lock.dart';

class VaultEntry {
  final String id;
  final String title;
  final int pages;
  final DateTime added;
  final int size;
  const VaultEntry(this.id, this.title, this.pages, this.added, this.size);
  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'pages': pages, 'added': added.millisecondsSinceEpoch, 'size': size};
  factory VaultEntry.fromJson(Map<String, dynamic> j) => VaultEntry(
        j['id'] as String,
        j['title'] as String,
        (j['pages'] as num).toInt(),
        DateTime.fromMillisecondsSinceEpoch((j['added'] as num).toInt()),
        (j['size'] as num?)?.toInt() ?? 0,
      );
}

/// Private vault: documents are packed and encrypted with AES-256-GCM.
/// The key is generated on the device and kept in Android Keystore-backed
/// secure storage; it never leaves the device. Opening the vault requires
/// device authentication. Note: uninstalling the app or clearing its data
/// destroys the key, making vault contents unrecoverable.
class VaultService {
  static const _keyName = 'scanpro_vault_key_v1';
  static const _storage = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  static final _algo = AesGcm.with256bits();

  static Future<SecretKey> _key() async {
    var b64 = await _storage.read(key: _keyName);
    if (b64 == null) {
      final rnd = Random.secure();
      final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
      b64 = base64Encode(bytes);
      await _storage.write(key: _keyName, value: b64);
    }
    return SecretKey(base64Decode(b64));
  }

  static Directory _dir(DocumentRepository repo) => Directory(repo.storage.abs('vault'));

  static Future<Uint8List> _encrypt(List<int> clear) async {
    final box = await _algo.encrypt(clear, secretKey: await _key(), nonce: _algo.newNonce());
    return Uint8List.fromList(box.concatenation());
  }

  static Future<List<int>> _decrypt(List<int> data) async {
    final box = SecretBox.fromConcatenation(data, nonceLength: 12, macLength: 16);
    return _algo.decrypt(box, secretKey: await _key());
  }

  static Future<List<VaultEntry>> list(DocumentRepository repo) async {
    final f = File(p.join(_dir(repo).path, 'index.enc'));
    if (!await f.exists()) return [];
    final clear = await _decrypt(await f.readAsBytes());
    return (jsonDecode(utf8.decode(clear)) as List).map((e) => VaultEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<void> _saveIndex(DocumentRepository repo, List<VaultEntry> entries) async {
    await _dir(repo).create(recursive: true);
    final f = File(p.join(_dir(repo).path, 'index.enc'));
    await f.writeAsBytes(await _encrypt(utf8.encode(jsonEncode(entries.map((e) => e.toJson()).toList()))), flush: true);
  }

  /// Encrypts a document into the vault and removes the plain copy.
  static Future<void> add(DocumentRepository repo, ScanDocument doc) async {
    final zip = await BackupService.exportDocuments(repo, [doc.id], fileName: 'vault_${newId()}.zip');
    final bytes = await File(zip).readAsBytes();
    final enc = await _encrypt(bytes);
    final id = newId();
    await _dir(repo).create(recursive: true);
    await File(p.join(_dir(repo).path, '$id.vlt')).writeAsBytes(enc, flush: true);
    await File(zip).delete();
    final entries = await list(repo);
    entries.add(VaultEntry(id, doc.title, doc.pageCount, DateTime.now(), enc.length));
    await _saveIndex(repo, entries);
    await repo.purge(doc.id);
  }

  /// Decrypts a vault item back into the normal library.
  static Future<void> restore(DocumentRepository repo, VaultEntry e) async {
    final f = File(p.join(_dir(repo).path, '${e.id}.vlt'));
    final clear = await _decrypt(await f.readAsBytes());
    final tmp = repo.storage.tempPath('vault_restore.zip');
    await File(tmp).writeAsBytes(clear, flush: true);
    try {
      await BackupService.importArchive(repo, tmp);
    } finally {
      await File(tmp).delete();
    }
    await f.delete();
    final entries = (await list(repo)).where((x) => x.id != e.id).toList();
    await _saveIndex(repo, entries);
  }

  static Future<void> delete(DocumentRepository repo, VaultEntry e) async {
    final f = File(p.join(_dir(repo).path, '${e.id}.vlt'));
    if (await f.exists()) await f.delete();
    final entries = (await list(repo)).where((x) => x.id != e.id).toList();
    await _saveIndex(repo, entries);
  }
}

class VaultUi {
  static Future<void> moveToVault(BuildContext context, WidgetRef ref, ScanDocument doc) async {
    final ok = await confirm(
      context,
      'Move to private vault?',
      '"${doc.title}" will be encrypted (AES-256) and hidden from the library and search. '
          'You need your fingerprint or screen lock to open the vault.\n\n'
          'If the app is uninstalled or its data cleared, vault items cannot be recovered.',
      ok: 'Move to vault',
    );
    if (!ok || !context.mounted) return;
    if (!await DeviceAuth.isAvailable()) {
      if (context.mounted) showSnack(context, 'Set up a screen lock on this device to use the vault.');
      return;
    }
    final repo = ref.read(repositoryProvider);
    final r = await runBusy(context, 'Encrypting…', (_) async {
      await VaultService.add(repo, doc);
      return true;
    });
    if (r == true && context.mounted) showSnack(context, 'Moved to vault');
  }
}

class VaultScreen extends ConsumerStatefulWidget {
  const VaultScreen({super.key});

  @override
  ConsumerState<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends ConsumerState<VaultScreen> {
  bool _unlocked = false;
  String? _error;
  List<VaultEntry>? _entries;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  Future<void> _unlock() async {
    final ok = await DeviceAuth.authenticate('Open private vault', onError: (m) => _error = m);
    if (!mounted) return;
    setState(() => _unlocked = ok);
    if (ok) await _load();
  }

  Future<void> _load() async {
    try {
      final e = await VaultService.list(ref.read(repositoryProvider));
      if (mounted) setState(() => _entries = e);
    } catch (e) {
      if (mounted) setState(() => _error = 'The vault could not be decrypted: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(repositoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Private vault')),
      body: !_unlocked
          ? EmptyState(
              icon: Icons.lock_outline,
              title: 'Vault locked',
              message: _error ?? 'Authenticate to view encrypted documents.',
              action: FilledButton.icon(onPressed: _unlock, icon: const Icon(Icons.fingerprint), label: const Text('Unlock')),
            )
          : _entries == null
              ? Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator())
              : _entries!.isEmpty
                  ? const EmptyState(
                      icon: Icons.enhanced_encryption_outlined,
                      title: 'Vault is empty',
                      message: 'Open a document and choose "Move to private vault" from its menu.',
                    )
                  : ListView(children: [
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'Vault items are encrypted with AES-256-GCM using a key stored in Android Keystore-backed storage. '
                          'Move an item back to the library to view or edit it.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      for (final e in _entries!)
                        ListTile(
                          leading: const Icon(Icons.enhanced_encryption_outlined),
                          title: Text(e.title),
                          subtitle: Text('${e.pages} pages · ${formatBytes(e.size)} · added ${formatDate(e.added)}'),
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) async {
                              if (v == 'restore') {
                                await runBusy(context, 'Decrypting…', (_) => VaultService.restore(repo, e));
                              } else if (v == 'delete') {
                                if (await confirm(context, 'Delete from vault?', '"${e.title}" will be permanently deleted.', ok: 'Delete', destructive: true)) {
                                  await VaultService.delete(repo, e);
                                }
                              }
                              await _load();
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'restore', child: Text('Move back to library')),
                              PopupMenuItem(value: 'delete', child: Text('Delete permanently')),
                            ],
                          ),
                        ),
                    ]),
    );
  }
}
