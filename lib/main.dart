import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/database.dart';
import 'core/providers.dart';
import 'core/repository.dart';
import 'core/settings.dart';
import 'core/storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Object? startupError;
  AppStorage? storage;
  AppDatabase? db;
  SettingsController? settings;
  DocumentRepository? repo;
  try {
    storage = await AppStorage.init();
    db = await AppDatabase.open();
    settings = SettingsController(db.db);
    await settings.load();
    repo = DocumentRepository(db, storage, settings);
    unawaited(repo.purgeExpiredTrash().catchError((_) => 0));
    unawaited(storage.clearCache());
  } catch (e) {
    startupError = e;
  }

  if (startupError != null || repo == null) {
    runApp(StartupErrorApp(error: startupError ?? 'Unknown error'));
    return;
  }

  runApp(ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db!),
      storageProvider.overrideWithValue(storage!),
      settingsProvider.overrideWith((ref) => settings!),
      repositoryProvider.overrideWith((ref) => repo!),
    ],
    child: const ScanProApp(),
  ));
}

class StartupErrorApp extends StatelessWidget {
  final Object error;
  const StartupErrorApp({super.key, required this.error});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.error_outline, size: 56),
                const SizedBox(height: 16),
                const Text('ScanPro Studio could not start', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(friendlyError(error), textAlign: TextAlign.center),
                const SizedBox(height: 8),
                const Text('Free some storage space and restart the app. Your documents are not deleted.', textAlign: TextAlign.center),
              ]),
            ),
          ),
        ),
      );
}
