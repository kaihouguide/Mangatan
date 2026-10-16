import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/l10n/generated/app_localizations_en.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/sync_preference.dart';
import 'package:mangayomi/services/sync_server.dart';

void main() {
  late Directory directory;
  late ProviderContainer container;
  final l10n = AppLocalizationsEn();

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    try {
      await Isar.initializeIsarCore(download: true);
    } finally {
      HttpOverrides.global = overrides;
    }
  });

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('sync_server_scheduled');
    isar = await Isar.open(
      [SyncPreferenceSchema],
      directory: directory.path,
      name: 'sync_server_scheduled_${directory.path.hashCode}',
    );
    // Logged in with sync on, but automatic sync off. The server address is
    // unreachable, so any attempted native sync fails its version check.
    isar.writeTxnSync(
      () => isar.syncPreferences.putSync(
        SyncPreference(
          syncId: 1,
          server: 'http://127.0.0.1:9',
          authToken: 'token',
          syncOn: true,
        ),
      ),
    );
    container = ProviderContainer();
  });

  tearDown(() async {
    container.dispose();
    await isar.close(deleteFromDisk: true);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('a scheduled sync skips while automatic sync is off', () async {
    final result = await container
        .read(syncServerProvider(syncId: 1).notifier)
        .startSync(l10n, true, scheduled: true);

    expect(result, isTrue);
  });

  test(
    'a silent post-restore upload still runs with automatic sync off',
    () async {
      final result = await container
          .read(syncServerProvider(syncId: 1).notifier)
          .startSync(l10n, true, upload: true, bypassRestoreGuard: true);

      // False means the sync was attempted (and failed against the dead
      // address) instead of being skipped and reported as a success.
      expect(result, isFalse);
    },
  );
}
