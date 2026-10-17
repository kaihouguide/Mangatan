import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/sync_preference.dart';
import 'package:mangayomi/repositories/db_write_queue.dart';

class SyncPreferenceRepository {
  SyncPreference? getById(int id) => isar.syncPreferences.getSync(id);

  Stream<List<SyncPreference>> watchAllWithSyncId() => isar.syncPreferences
      .filter()
      .syncIdIsNotNull()
      .watch(fireImmediately: true);

  // No updatedAt stamping - SyncPreference is local-only (never synced
  // itself), so it has no such field.
  Future<void> save(SyncPreference preference) => dbWriteQueue.run(
    () => isar.writeTxnSync(() => isar.syncPreferences.putSync(preference)),
  );

  // Queued read-modify-write: [body] reads the current row and writes it back
  // inside one synchronous transaction, so compare-and-set checks stay atomic.
  Future<T> writeTransaction<T>(T Function() body) =>
      dbWriteQueue.run(() => isar.writeTxnSync(body));
}

final syncPreferenceRepository = SyncPreferenceRepository();
