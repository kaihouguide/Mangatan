import 'package:mangayomi/models/sync_preference.dart';
import 'package:mangayomi/services/sync/chimahon_restore_sync_coordinator.dart';

/// Runs a queued Chimahon sync only after re-reading its current preference.
///
/// A restore or Drive credential operation can hold the coordinator while the
/// user changes backend, credentials, or automatic-sync settings. Reading the
/// preference inside the exclusive closure prevents the queued operation from
/// contacting a backend selected by the stale pre-queue snapshot. A
/// [scheduled] run is also skipped once automatic sync has been turned off.
Future<bool> runQueuedChimahonSync({
  required ChimahonRestoreSyncCoordinator coordinator,
  required SyncPreference Function() readCurrentPreference,
  required bool scheduled,
  required Future<void> Function(SyncPreference preference) synchronize,
}) => coordinator.duringSync(() async {
  final preference = readCurrentPreference();
  if (preference.syncMode != SyncMode.chimahon ||
      scheduled && (!preference.syncOn || preference.autoSyncFrequency == 0)) {
    return false;
  }
  await synchronize(preference);
  return true;
});
