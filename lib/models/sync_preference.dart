import 'package:isar_community/isar.dart';
part 'sync_preference.g.dart';

enum SyncMode { native, chimahon }

enum ChimahonSyncProvider { syncYomi, googleDrive, webDav }

@collection
@Name("Sync Preference")
class SyncPreference {
  Id? syncId;

  String? email;

  String? authToken;

  int? since;

  String? sessionToken;

  bool googleDriveConnected = false;

  String? chimahonDeviceId;

  String? syncYomiServer;

  String? syncYomiApiToken;

  bool chimahonSyncManga = true;

  bool chimahonSyncAnime = true;

  bool chimahonSyncNovels = true;

  /// Whether the media switches are an explicit local choice or have been
  /// bootstrapped from the current Chimahon account's backed preferences.
  bool chimahonMediaSelectionInitialized = false;

  /// True only when the user directly changed a media switch. Remote
  /// bootstrap values are account-scoped and must not gain local authority on
  /// a different account.
  bool chimahonMediaSelectionUserSelected = false;

  /// SHA-256 token of the provider/account scope that supplied the current
  /// bootstrapped values. Raw account IDs, servers, and tokens are never
  /// persisted here.
  String? chimahonMediaSelectionScopeToken;

  /// Monotonic revision for selector state. It closes value-only ABA races
  /// when a switch changes away and back during network I/O.
  int chimahonMediaSelectionGeneration = 0;

  String? server;

  bool syncOn = false;

  int autoSyncFrequency = 0;

  int? lastSync;

  @enumerated
  SyncMode syncMode = SyncMode.native;

  @enumerated
  ChimahonSyncProvider chimahonSyncProvider = ChimahonSyncProvider.syncYomi;

  SyncPreference({
    this.syncId,
    this.email,
    this.authToken,
    this.since,
    this.sessionToken,
    this.googleDriveConnected = false,
    this.chimahonDeviceId,
    this.syncYomiServer,
    this.syncYomiApiToken,
    this.chimahonSyncManga = true,
    this.chimahonSyncAnime = true,
    this.chimahonSyncNovels = true,
    this.chimahonMediaSelectionInitialized = false,
    this.chimahonMediaSelectionUserSelected = false,
    this.chimahonMediaSelectionScopeToken,
    this.chimahonMediaSelectionGeneration = 0,
    this.server,
    this.syncOn = false,
    this.autoSyncFrequency = 0,
    this.lastSync,
    this.syncMode = SyncMode.native,
    this.chimahonSyncProvider = ChimahonSyncProvider.syncYomi,
  });

  SyncPreference.fromJson(Map<String, dynamic> json) {
    syncId = json['syncId'];
    email = json['email'];
    authToken = json['authToken'];
    since = json['since'];
    sessionToken = json['sessionToken'];
    googleDriveConnected = json['googleDriveConnected'] ?? false;
    chimahonDeviceId = json['chimahonDeviceId'];
    syncYomiServer = json['syncYomiServer'];
    syncYomiApiToken = json['syncYomiApiToken'];
    chimahonSyncManga = json['chimahonSyncManga'] ?? true;
    chimahonSyncAnime = json['chimahonSyncAnime'] ?? true;
    chimahonSyncNovels = json['chimahonSyncNovels'] ?? true;
    chimahonMediaSelectionInitialized =
        json['chimahonMediaSelectionInitialized'] ?? false;
    chimahonMediaSelectionUserSelected =
        json['chimahonMediaSelectionUserSelected'] ?? false;
    chimahonMediaSelectionScopeToken = json['chimahonMediaSelectionScopeToken'];
    chimahonMediaSelectionGeneration =
        json['chimahonMediaSelectionGeneration'] ?? 0;
    server = json['server'];
    syncOn = json['syncOn'] ?? false;
    autoSyncFrequency = json['autoSyncFrequency'] ?? 0;
    lastSync = json['lastSync'];
    syncMode = SyncMode.values[json['syncMode'] ?? SyncMode.native.index];
    chimahonSyncProvider =
        ChimahonSyncProvider.values[json['chimahonSyncProvider'] ??
            ChimahonSyncProvider.syncYomi.index];
  }

  Map<String, dynamic> toJson() => {
    'syncId': syncId,
    'email': email,
    'authToken': authToken,
    'since': since,
    'sessionToken': sessionToken,
    'googleDriveConnected': googleDriveConnected,
    'chimahonDeviceId': chimahonDeviceId,
    'syncYomiServer': syncYomiServer,
    'syncYomiApiToken': syncYomiApiToken,
    'chimahonSyncManga': chimahonSyncManga,
    'chimahonSyncAnime': chimahonSyncAnime,
    'chimahonSyncNovels': chimahonSyncNovels,
    'chimahonMediaSelectionInitialized': chimahonMediaSelectionInitialized,
    'chimahonMediaSelectionUserSelected': chimahonMediaSelectionUserSelected,
    'chimahonMediaSelectionScopeToken': chimahonMediaSelectionScopeToken,
    'chimahonMediaSelectionGeneration': chimahonMediaSelectionGeneration,
    'server': server,
    'syncOn': syncOn,
    'autoSyncFrequency': autoSyncFrequency,
    'lastSync': lastSync,
    'syncMode': syncMode.index,
    'chimahonSyncProvider': chimahonSyncProvider.index,
  };

  /// Migrates the pre-separation SyncYomi fields exactly once. A device ID is
  /// written whenever a user newly selects Chimahon mode, so a Chimahon row
  /// without one can only be a persisted legacy configuration.
  bool migrateLegacySyncYomiCredentials(String newDeviceId) {
    if (syncMode != SyncMode.chimahon ||
        chimahonDeviceId != null ||
        syncYomiServer != null ||
        syncYomiApiToken != null) {
      return false;
    }
    final legacyServer = server?.trim() ?? '';
    final legacyToken = authToken?.trim() ?? '';
    if (legacyServer.isEmpty && legacyToken.isEmpty) return false;
    syncYomiServer = legacyServer.isEmpty ? null : legacyServer;
    syncYomiApiToken = legacyToken.isEmpty ? null : legacyToken;
    server = null;
    authToken = null;
    chimahonDeviceId = newDeviceId;
    return true;
  }
}

/// Mutates the row loaded at write time instead of a notifier's cached value.
///
/// The caller supplies transaction-bound read/write callbacks. Keeping this
/// tiny operation testable prevents post-network timestamp writes from
/// replacing selector edits that landed while the request was in flight.
SyncPreference mutateCurrentSyncPreference({
  required SyncPreference Function() readCurrent,
  required void Function(SyncPreference) mutate,
  required void Function(SyncPreference) writeCurrent,
}) {
  final current = readCurrent();
  mutate(current);
  writeCurrent(current);
  return current;
}
