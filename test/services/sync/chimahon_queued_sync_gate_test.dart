import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/models/sync_preference.dart';
import 'package:mangayomi/services/sync/chimahon_queued_sync_gate.dart';
import 'package:mangayomi/services/sync/chimahon_restore_sync_coordinator.dart';

void main() {
  test(
    'queued sync uses the current provider and SyncYomi credentials',
    () async {
      final coordinator = ChimahonRestoreSyncCoordinator();
      final blockerStarted = Completer<void>();
      final releaseBlocker = Completer<void>();
      var current = _enabledPreference(
        provider: ChimahonSyncProvider.googleDrive,
      );
      SyncPreference? synchronizedPreference;

      final blocker = coordinator.duringManualRestore(() async {
        blockerStarted.complete();
        await releaseBlocker.future;
      });
      await blockerStarted.future;

      final queued = runQueuedChimahonSync(
        coordinator: coordinator,
        readCurrentPreference: () => current,
        scheduled: false,
        synchronize: (preference) async {
          synchronizedPreference = preference;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(synchronizedPreference, isNull);

      current = _enabledPreference(
        provider: ChimahonSyncProvider.syncYomi,
        server: 'https://new-sync.example',
        token: 'new-token',
      );
      releaseBlocker.complete();

      expect(await queued, isTrue);
      await blocker;
      expect(synchronizedPreference, same(current));
      expect(
        synchronizedPreference?.chimahonSyncProvider,
        ChimahonSyncProvider.syncYomi,
      );
      expect(
        synchronizedPreference?.syncYomiServer,
        'https://new-sync.example',
      );
      expect(synchronizedPreference?.syncYomiApiToken, 'new-token');
    },
  );

  for (final disabledState in <({bool syncOn, int frequency})>[
    (syncOn: false, frequency: 300),
    (syncOn: true, frequency: 0),
  ]) {
    test('queued scheduled sync skips when current state is '
        '${disabledState.syncOn ? 'Off' : 'disabled'}', () async {
      final coordinator = ChimahonRestoreSyncCoordinator();
      final blockerStarted = Completer<void>();
      final releaseBlocker = Completer<void>();
      var current = _enabledPreference();
      var backendCalls = 0;

      final blocker = coordinator.duringManualRestore(() async {
        blockerStarted.complete();
        await releaseBlocker.future;
      });
      await blockerStarted.future;

      final queued = runQueuedChimahonSync(
        coordinator: coordinator,
        readCurrentPreference: () => current,
        scheduled: true,
        synchronize: (_) async {
          backendCalls++;
        },
      );
      current = _enabledPreference(
        syncOn: disabledState.syncOn,
        frequency: disabledState.frequency,
      );
      releaseBlocker.complete();

      expect(await queued, isFalse);
      await blocker;
      expect(backendCalls, 0);
    });
  }

  test(
    'queued sync skips when the current mode is no longer Chimahon',
    () async {
      final coordinator = ChimahonRestoreSyncCoordinator();
      final blockerStarted = Completer<void>();
      final releaseBlocker = Completer<void>();
      var current = _enabledPreference();
      var backendCalls = 0;

      final blocker = coordinator.duringManualRestore(() async {
        blockerStarted.complete();
        await releaseBlocker.future;
      });
      await blockerStarted.future;

      final queued = runQueuedChimahonSync(
        coordinator: coordinator,
        readCurrentPreference: () => current,
        scheduled: false,
        synchronize: (_) async {
          backendCalls++;
        },
      );
      current = SyncPreference(syncMode: SyncMode.native);
      releaseBlocker.complete();

      expect(await queued, isFalse);
      await blocker;
      expect(backendCalls, 0);
    },
  );

  test('manual sync remains allowed while automatic sync is Off', () async {
    var backendCalls = 0;

    final ran = await runQueuedChimahonSync(
      coordinator: ChimahonRestoreSyncCoordinator(),
      readCurrentPreference: () => _enabledPreference(frequency: 0),
      scheduled: false,
      synchronize: (_) async {
        backendCalls++;
      },
    );

    expect(ran, isTrue);
    expect(backendCalls, 1);
  });
}

SyncPreference _enabledPreference({
  ChimahonSyncProvider provider = ChimahonSyncProvider.syncYomi,
  String server = 'https://old-sync.example',
  String token = 'old-token',
  bool syncOn = true,
  int frequency = 300,
}) => SyncPreference(
  syncMode: SyncMode.chimahon,
  chimahonSyncProvider: provider,
  syncYomiServer: server,
  syncYomiApiToken: token,
  syncOn: syncOn,
  autoSyncFrequency: frequency,
);
