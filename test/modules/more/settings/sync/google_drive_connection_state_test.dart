import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/modules/more/settings/sync/providers/sync_providers.dart';
import 'package:mangayomi/modules/more/settings/sync/sync.dart';
import 'package:mangayomi/services/sync/chimahon_restore_sync_coordinator.dart';
import 'package:mangayomi/services/sync/google_drive_connection_intent.dart';
import 'package:mangayomi/services/sync/google_drive_refresh_token_store.dart';

void main() {
  test('failed Drive connection can restore the exact paused interval', () {
    final generation = AutoSyncPauseGeneration(1);
    final token = generation.beginPause(10800);

    expect(generation.canRestore(token, currentFrequency: 0), isTrue);
    generation.recordRestore(token);
    expect(generation.canRestore(token, currentFrequency: 0), isFalse);
  });

  test('an explicit Off edit while OAuth is open wins over rollback', () {
    final generation = AutoSyncPauseGeneration(1);
    final token = generation.beginPause(10800);

    generation.recordUserEdit();

    expect(generation.canRestore(token, currentFrequency: 0), isFalse);
  });

  test('a concurrent nonzero auto-sync edit wins over rollback', () {
    final generation = AutoSyncPauseGeneration(1);
    final token = generation.beginPause(10800);

    expect(generation.canRestore(token, currentFrequency: 600), isFalse);
  });

  test('a newer pause invalidates an older rollback token', () {
    final generation = AutoSyncPauseGeneration(1);
    final older = generation.beginPause(10800);
    final newer = generation.beginPause(600);

    expect(generation.canRestore(older, currentFrequency: 0), isFalse);
    expect(generation.canRestore(newer, currentFrequency: 0), isTrue);
  });

  test('an already disabled interval does not need rollback', () {
    final generation = AutoSyncPauseGeneration(1);
    final token = generation.beginPause(0);

    expect(token.changedSchedule, isFalse);
    expect(generation.canRestore(token, currentFrequency: 0), isFalse);
  });

  test('concurrent Connect clicks share one account flow', () async {
    final singleFlight = GoogleDriveConnectionSingleFlight();
    final release = Completer<void>();
    var starts = 0;

    final first = singleFlight.run(() {
      starts++;
      return release.future;
    });
    expect(starts, 1, reason: 'pause/setup must happen synchronously');

    final second = singleFlight.run(() async {
      starts++;
    });

    expect(identical(first, second), isTrue);
    expect(starts, 1);

    release.complete();
    await Future.wait([first, second]);

    await singleFlight.run(() async {
      starts++;
    });
    expect(starts, 2);
  });

  test('Connect pauses before waiting for an in-flight sync', () async {
    final coordinator = ChimahonRestoreSyncCoordinator();
    final singleFlight = GoogleDriveConnectionSingleFlight();
    final oldSyncStarted = Completer<void>();
    final releaseOldSync = Completer<void>();
    final events = <String>[];

    final oldSync = coordinator.duringSync(() async {
      events.add('sync-start');
      oldSyncStarted.complete();
      await releaseOldSync.future;
      events.add('sync-end');
    });
    await oldSyncStarted.future;

    final connect = singleFlight.run(() {
      events.add('pause');
      return coordinator.duringSync(() async {
        events.add('connect');
      });
    });
    expect(events, ['sync-start', 'pause']);
    await Future<void>.delayed(Duration.zero);
    expect(events, ['sync-start', 'pause']);

    releaseOldSync.complete();
    await Future.wait([oldSync, connect]);
    expect(events, ['sync-start', 'pause', 'sync-end', 'connect']);
  });

  test('failed connection row restores the previous secure token', () async {
    final store = _TokenStore('old-account-token');
    var disconnected = false;

    await expectLater(
      persistGoogleDriveConnectionWithTokenRollback(
        tokenStore: store,
        newRefreshToken: 'new-account-token',
        persistConnection: () => throw StateError('database failed'),
        markDisconnected: () => disconnected = true,
      ),
      throwsStateError,
    );

    expect(store.refreshToken, 'old-account-token');
    expect(store.writes, ['new-account-token', 'old-account-token']);
    expect(store.clearCount, 0);
    expect(disconnected, isFalse);
  });

  test('an asynchronously failed connection row still rolls back', () async {
    final store = _TokenStore(null);
    var disconnected = false;

    // Preference writes are queued, so a failure arrives after a gap.
    await expectLater(
      persistGoogleDriveConnectionWithTokenRollback(
        tokenStore: store,
        newRefreshToken: 'new-account-token',
        persistConnection: () async {
          await Future<void>.delayed(Duration.zero);
          throw StateError('database failed');
        },
        markDisconnected: () async {
          await Future<void>.delayed(Duration.zero);
          disconnected = true;
        },
      ),
      throwsStateError,
    );

    expect(store.refreshToken, isNull);
    expect(store.clearCount, 1);
    expect(disconnected, isTrue);
  });

  test('failed first connection clears token and marks disconnected', () async {
    final store = _TokenStore(null);
    var disconnected = false;

    await expectLater(
      persistGoogleDriveConnectionWithTokenRollback(
        tokenStore: store,
        newRefreshToken: 'new-account-token',
        persistConnection: () => throw StateError('database failed'),
        markDisconnected: () => disconnected = true,
      ),
      throwsStateError,
    );

    expect(store.refreshToken, isNull);
    expect(store.clearCount, 1);
    expect(disconnected, isTrue);
  });

  test('provider away-and-back invalidates the OAuth connection intent', () {
    final generation = GoogleDriveConnectionIntentGeneration(1);
    final intent = generation.capture();

    generation.recordConfigurationChange();
    generation.recordConfigurationChange();

    expect(generation.isCurrent(intent), isFalse);
    expect(
      () => generation.requireCurrent(intent),
      throwsA(isA<GoogleDriveConnectionIntentChangedException>()),
    );
  });

  test('stale OAuth intent restores the previous secure token', () async {
    final store = _TokenStore('old-account-token');
    final generation = GoogleDriveConnectionIntentGeneration(1);
    final intent = generation.capture();
    var disconnected = false;

    // Simulate changing away from Drive and then back to the same final value.
    generation.recordConfigurationChange();
    generation.recordConfigurationChange();

    await expectLater(
      persistGoogleDriveConnectionWithTokenRollback(
        tokenStore: store,
        newRefreshToken: 'new-account-token',
        persistConnection: () => generation.requireCurrent(intent),
        markDisconnected: () => disconnected = true,
      ),
      throwsA(isA<GoogleDriveConnectionIntentChangedException>()),
    );

    expect(store.refreshToken, 'old-account-token');
    expect(store.writes, ['new-account-token', 'old-account-token']);
    expect(disconnected, isFalse);
  });

  test(
    'secure-store disconnect failure is fixed-text and keeps state',
    () async {
      const secret = 'keychain-secret at /Users/private/credential';
      var disconnected = false;

      final message = await disconnectGoogleDriveCredentialSafely(
        tokenStore: const _ThrowingTokenStore(secret),
        markDisconnected: () => disconnected = true,
      );

      expect(disconnected, isFalse);
      expect(
        message,
        'Could not disconnect Google Drive. The saved connection was kept.',
      );
      expect(message, isNot(contains(secret)));
      expect(message, isNot(contains('/Users/private/credential')));
    },
  );
}

class _TokenStore implements GoogleDriveRefreshTokenStore {
  _TokenStore(this.refreshToken);

  String? refreshToken;
  final List<String> writes = [];
  int clearCount = 0;

  @override
  Future<String?> readRefreshToken() async => refreshToken;

  @override
  Future<void> writeRefreshToken(String refreshToken) async {
    writes.add(refreshToken);
    this.refreshToken = refreshToken;
  }

  @override
  Future<void> clearRefreshToken() async {
    clearCount++;
    refreshToken = null;
  }
}

class _ThrowingTokenStore implements GoogleDriveRefreshTokenStore {
  const _ThrowingTokenStore(this.message);

  final String message;

  @override
  Future<void> clearRefreshToken() => throw StateError(message);

  @override
  Future<String?> readRefreshToken() async => null;

  @override
  Future<void> writeRefreshToken(String refreshToken) async {}
}
