import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database.dart';
import 'repository.dart';
import 'settings.dart';
import 'storage.dart';

/// Root dependencies are created in main() and injected with overrides.
final databaseProvider = Provider<AppDatabase>((ref) => throw UnimplementedError('override in main'));
final storageProvider = Provider<AppStorage>((ref) => throw UnimplementedError('override in main'));

final settingsProvider = ChangeNotifierProvider<SettingsController>((ref) => throw UnimplementedError('override in main'));

final repositoryProvider = ChangeNotifierProvider<DocumentRepository>((ref) => throw UnimplementedError('override in main'));
