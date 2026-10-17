import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/models/sync_preference.dart';

void main() {
  test('post-network scalar write preserves a newer selector revision', () {
    final cachedBeforeNetwork = SyncPreference(
      chimahonSyncAnime: true,
      chimahonMediaSelectionGeneration: 3,
    );
    final storedAfterUserEdit = SyncPreference(
      chimahonSyncAnime: false,
      chimahonMediaSelectionInitialized: true,
      chimahonMediaSelectionUserSelected: true,
      chimahonMediaSelectionGeneration: 4,
    );
    SyncPreference? written;

    mutateCurrentSyncPreference(
      readCurrent: () => storedAfterUserEdit,
      mutate: (current) => current.lastSync = 123,
      writeCurrent: (current) => written = current,
    );

    expect(written, same(storedAfterUserEdit));
    expect(written, isNot(same(cachedBeforeNetwork)));
    expect(written?.lastSync, 123);
    expect(written?.chimahonSyncAnime, isFalse);
    expect(written?.chimahonMediaSelectionUserSelected, isTrue);
    expect(written?.chimahonMediaSelectionGeneration, 4);
  });

  test('legacy rows default all Chimahon media on and uninitialized', () {
    final preference = SyncPreference.fromJson(const {'syncId': 1});

    expect(preference.chimahonSyncManga, isTrue);
    expect(preference.chimahonSyncAnime, isTrue);
    expect(preference.chimahonSyncNovels, isTrue);
    expect(preference.chimahonMediaSelectionInitialized, isFalse);
    expect(preference.chimahonMediaSelectionUserSelected, isFalse);
    expect(preference.chimahonMediaSelectionScopeToken, isNull);
    expect(preference.chimahonMediaSelectionGeneration, 0);
  });

  test('migrates legacy SyncYomi credentials only from a legacy mode row', () {
    final legacy = SyncPreference(
      syncMode: SyncMode.chimahon,
      server: ' https://sync.example/ ',
      authToken: ' legacy-token ',
    );

    expect(legacy.migrateLegacySyncYomiCredentials('device-1'), isTrue);
    expect(legacy.syncYomiServer, 'https://sync.example/');
    expect(legacy.syncYomiApiToken, 'legacy-token');
    expect(legacy.server, isNull);
    expect(legacy.authToken, isNull);
    expect(legacy.chimahonDeviceId, 'device-1');
    expect(legacy.migrateLegacySyncYomiCredentials('device-2'), isFalse);
  });

  test('never repurposes native credentials as SyncYomi credentials', () {
    final native = SyncPreference(
      syncMode: SyncMode.native,
      server: 'https://native.example',
      authToken: 'native-token',
    );

    expect(native.migrateLegacySyncYomiCredentials('device'), isFalse);
    expect(native.syncYomiServer, isNull);
    expect(native.syncYomiApiToken, isNull);
    expect(native.server, 'https://native.example');
    expect(native.authToken, 'native-token');
  });

  test('WebDAV provider persists no password in JSON preferences', () {
    final preference = SyncPreference(
      syncMode: SyncMode.chimahon,
      chimahonSyncProvider: ChimahonSyncProvider.webDav,
      server: 'https://dav.example/mangatan/',
      googleDriveConnected: true,
    );

    final json = preference.toJson();

    expect(json['chimahonSyncProvider'], ChimahonSyncProvider.webDav.index);
    expect(json['server'], 'https://dav.example/mangatan/');
    expect(json.values.join('|'), isNot(contains('password')));
  });
}
