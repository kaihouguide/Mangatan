import 'dart:async';
import 'dart:math';

import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/changed.dart';
import 'package:mangayomi/models/sync_preference.dart';
import 'package:mangayomi/services/sync/chimahon_media_sync_selection.dart';
import 'package:mangayomi/services/sync/google_drive_connection_intent.dart';
import 'package:mangayomi/services/sync_server.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:mangayomi/repositories/changed_part_repository.dart';
import 'package:mangayomi/repositories/sync_preference_repository.dart';
part 'sync_providers.g.dart';

/// Process-local compare-and-set token for a temporary automatic-sync pause.
///
/// The generation changes even when the user explicitly selects the already
/// visible `Off` value. This closes the zero-value ABA where a failed OAuth
/// attempt could otherwise restore an interval over that user choice.
class AutoSyncPauseToken {
  const AutoSyncPauseToken({
    required this.syncId,
    required this.previousFrequency,
    required this.generation,
  });

  final int syncId;
  final int previousFrequency;
  final int generation;

  bool get changedSchedule => previousFrequency > 0;
}

class AutoSyncPauseGeneration {
  AutoSyncPauseGeneration(this.syncId);

  final int syncId;
  int _generation = 0;

  AutoSyncPauseToken beginPause(int previousFrequency) => AutoSyncPauseToken(
    syncId: syncId,
    previousFrequency: previousFrequency,
    generation: ++_generation,
  );

  void recordUserEdit() => _generation++;

  bool canRestore(AutoSyncPauseToken token, {required int currentFrequency}) =>
      token.syncId == syncId &&
      token.previousFrequency > 0 &&
      token.generation == _generation &&
      currentFrequency == 0;

  void recordRestore(AutoSyncPauseToken token) {
    if (token.syncId == syncId && token.generation == _generation) {
      _generation++;
    }
  }
}

@riverpod
class Synching extends _$Synching {
  static final Map<int, AutoSyncPauseGeneration> _autoSyncPauseGenerations = {};
  static final Map<int, GoogleDriveConnectionIntentGeneration>
  _googleDriveConnectionIntentGenerations = {};

  @override
  SyncPreference build({required int? syncId}) {
    ref.keepAlive();
    final preference =
        isar.syncPreferences.getSync(syncId!) ?? SyncPreference(syncId: 1);
    if (preference.migrateLegacySyncYomiCredentials(_newChimahonDeviceId())) {
      // build() cannot await; the queue still runs this before any later write.
      unawaited(syncPreferenceRepository.save(preference));
    }
    return preference;
  }

  Future<void> login(String server, String email, String authToken) async {
    await _updateCurrentPreference((current) {
      current
        ..server = server
        ..email = email
        ..authToken = authToken;
    });
    ref.invalidateSelf();
    ref.invalidate(syncServerProvider(syncId: syncId!));
  }

  Future<void> logout() async {
    await _updateCurrentPreference((current) => current.authToken = null);
    ref.invalidateSelf();
    ref.invalidate(syncServerProvider(syncId: syncId!));
  }

  Future<void> setGoogleDriveConnected(bool connected) =>
      _setGoogleDriveConnection(connected: connected);

  GoogleDriveConnectionIntentToken captureGoogleDriveConnectionIntent() =>
      _googleDriveConnectionIntentGeneration.capture();

  void invalidateGoogleDriveConnectionIntent() =>
      _googleDriveConnectionIntentGeneration.recordConfigurationChange();

  Future<void> persistGoogleDriveConnectionIfIntentCurrent({
    required GoogleDriveConnectionIntentToken intent,
    required ChimahonMediaSyncSelection? mediaSelection,
    bool mediaSelectionInitialized = true,
    bool mediaSelectionUserSelected = false,
    String? mediaSelectionScopeToken,
    ChimahonMediaSyncSelectionState? expectedMediaSelectionState,
  }) => _setGoogleDriveConnection(
    connected: true,
    expectedConnectionIntent: intent,
    mediaSelection: mediaSelection,
    mediaSelectionInitialized: mediaSelectionInitialized,
    mediaSelectionUserSelected: mediaSelectionUserSelected,
    mediaSelectionScopeToken: mediaSelectionScopeToken,
    expectedMediaSelectionState: expectedMediaSelectionState,
  );

  Future<void> _setGoogleDriveConnection({
    required bool connected,
    GoogleDriveConnectionIntentToken? expectedConnectionIntent,
    ChimahonMediaSyncSelection? mediaSelection,
    bool mediaSelectionInitialized = true,
    bool mediaSelectionUserSelected = false,
    String? mediaSelectionScopeToken,
    ChimahonMediaSyncSelectionState? expectedMediaSelectionState,
  }) async {
    await syncPreferenceRepository.writeTransaction(() {
      final current = isar.syncPreferences.getSync(syncId!) ?? state;
      if (expectedConnectionIntent != null) {
        _googleDriveConnectionIntentGeneration.requireCurrent(
          expectedConnectionIntent,
        );
        if (current.syncMode != SyncMode.chimahon ||
            current.chimahonSyncProvider != ChimahonSyncProvider.googleDrive) {
          throw const GoogleDriveConnectionIntentChangedException();
        }
      }
      final canApplySelection =
          mediaSelection != null &&
          (expectedMediaSelectionState == null ||
              matchesChimahonMediaSelectionState(
                current,
                expectedMediaSelectionState,
              ));
      current
        ..googleDriveConnected = connected
        ..chimahonDeviceId ??= _newChimahonDeviceId();
      if (canApplySelection) {
        if (expectedMediaSelectionState == null) {
          final nextGeneration = current.chimahonMediaSelectionGeneration + 1;
          current
            ..chimahonSyncManga = mediaSelection.manga
            ..chimahonSyncAnime = mediaSelection.anime
            ..chimahonSyncNovels = mediaSelection.novels
            ..chimahonMediaSelectionInitialized = mediaSelectionInitialized
            ..chimahonMediaSelectionUserSelected = mediaSelectionUserSelected
            ..chimahonMediaSelectionScopeToken = mediaSelectionScopeToken
            ..chimahonMediaSelectionGeneration = nextGeneration;
        } else {
          applyChimahonMediaSelectionIfUnchanged(
            preference: current,
            expected: expectedMediaSelectionState,
            updated: mediaSelection,
            updatedInitialized: mediaSelectionInitialized,
            updatedUserSelected: mediaSelectionUserSelected,
            updatedScopeToken: mediaSelectionScopeToken,
          );
        }
      }
      isar.syncPreferences.putSync(current);
    });
    ref.invalidateSelf();
  }

  Future<void> setChimahonMediaSelection(
    ChimahonMediaSyncSelection selection, {
    bool initialized = true,
  }) async {
    await syncPreferenceRepository.writeTransaction(() {
      final current = isar.syncPreferences.getSync(syncId!) ?? state;
      final nextGeneration = current.chimahonMediaSelectionGeneration + 1;
      isar.syncPreferences.putSync(
        current
          ..chimahonSyncManga = selection.manga
          ..chimahonSyncAnime = selection.anime
          ..chimahonSyncNovels = selection.novels
          ..chimahonMediaSelectionInitialized = initialized
          ..chimahonMediaSelectionUserSelected = true
          ..chimahonMediaSelectionGeneration = nextGeneration,
      );
    });
    ref.invalidateSelf();
  }

  Future<bool> setChimahonMediaSelectionIfUnchanged({
    required ChimahonMediaSyncSelectionState expected,
    required ChimahonMediaSyncSelection updated,
    bool updatedInitialized = true,
    bool updatedUserSelected = false,
    required String? updatedScopeToken,
  }) async {
    final applied = await syncPreferenceRepository.writeTransaction(() {
      final current = isar.syncPreferences.getSync(syncId!);
      if (current == null ||
          !applyChimahonMediaSelectionIfUnchanged(
            preference: current,
            expected: expected,
            updated: updated,
            updatedInitialized: updatedInitialized,
            updatedUserSelected: updatedUserSelected,
            updatedScopeToken: updatedScopeToken,
          )) {
        return false;
      }
      isar.syncPreferences.putSync(current);
      return true;
    });
    if (applied) ref.invalidateSelf();
    return applied;
  }

  Future<void> setChimahonSyncManga(bool value) =>
      _setChimahonMediaField(manga: value);

  Future<void> setChimahonSyncAnime(bool value) =>
      _setChimahonMediaField(anime: value);

  Future<void> setChimahonSyncNovels(bool value) =>
      _setChimahonMediaField(novels: value);

  Future<void> _setChimahonMediaField({
    bool? manga,
    bool? anime,
    bool? novels,
  }) async {
    await syncPreferenceRepository.writeTransaction(() {
      final current = isar.syncPreferences.getSync(syncId!) ?? state;
      applyChimahonMediaSelectionUserEdit(
        current,
        manga: manga,
        anime: anime,
        novels: novels,
      );
      isar.syncPreferences.putSync(current);
    });
    ref.invalidateSelf();
  }

  Future<void> saveSyncYomiCredentials({
    required String server,
    required String apiToken,
  }) async {
    await _updateCurrentPreference((current) {
      current
        ..syncYomiServer = server
        ..syncYomiApiToken = apiToken
        ..chimahonDeviceId ??= _newChimahonDeviceId();
    });
    ref.invalidateSelf();
  }

  Future<void> disconnectSyncYomi() async {
    await _updateCurrentPreference((current) {
      current
        ..syncYomiServer = null
        ..syncYomiApiToken = null;
    });
    ref.invalidateSelf();
  }

  Future<void> saveWebDavConnection({required String server}) async {
    await _updateCurrentPreference((current) {
      current
        ..server = server
        ..googleDriveConnected = true
        ..chimahonDeviceId ??= _newChimahonDeviceId();
    });
    ref.invalidateSelf();
  }

  Future<void> disconnectWebDav() async {
    await _updateCurrentPreference((current) {
      current
        ..server = null
        ..googleDriveConnected = false;
    });
    ref.invalidateSelf();
  }

  Future<String> ensureChimahonDeviceId() =>
      syncPreferenceRepository.writeTransaction(() {
        final current = isar.syncPreferences.getSync(syncId!) ?? state;
        final existing = current.chimahonDeviceId;
        if (existing != null && existing.isNotEmpty) return existing;
        final value = _newChimahonDeviceId();
        isar.syncPreferences.putSync(current..chimahonDeviceId = value);
        return value;
      });

  Future<void> setSince(int timestamp) async {
    await _updateCurrentPreference((current) => current.since = timestamp);
    ref.invalidateSelf();
  }

  Future<void> setLastSync(int timestamp) async {
    await _updateCurrentPreference((current) => current.lastSync = timestamp);
    ref.invalidateSelf();
  }

  Future<void> setServer(String? server) =>
      _updateCurrentPreference((current) => current.server = server);

  Future<void> setSyncOn(bool value) async {
    await _updateCurrentPreference((current) => current.syncOn = value);
    // MainScreen listens to this provider to cancel or resume its timer.
    ref.invalidateSelf();
  }

  Future<void> setAutoSyncFrequency(int value) async {
    // Recorded before queuing, so a restore already waiting in the queue
    // cannot overwrite this edit.
    _autoSyncPauseGeneration.recordUserEdit();
    await _updateCurrentPreference(
      (current) => current.autoSyncFrequency = value,
    );
    ref.invalidateSelf();
  }

  /// Immediately pauses the persisted automatic-sync interval and returns the
  /// process-local CAS token required to restore it after a failed operation.
  Future<AutoSyncPauseToken> pauseAutoSyncForExternalOperation() async {
    final id = syncId!;
    late final AutoSyncPauseToken token;
    var changed = false;
    await syncPreferenceRepository.writeTransaction(() {
      final current = isar.syncPreferences.getSync(id) ?? state;
      token = _autoSyncPauseGeneration.beginPause(current.autoSyncFrequency);
      if (current.autoSyncFrequency > 0) {
        current.autoSyncFrequency = 0;
        isar.syncPreferences.putSync(current);
        changed = true;
      }
    });
    if (changed) ref.invalidateSelf();
    return token;
  }

  /// Restores a failed operation's pause only if no user frequency edit (even
  /// an explicit zero-to-zero edit) or newer pause occurred in the meantime.
  Future<bool> restoreAutoSyncAfterFailedExternalOperation(
    AutoSyncPauseToken token,
  ) async {
    final id = syncId!;
    if (token.syncId != id) return false;
    var restored = false;
    await syncPreferenceRepository.writeTransaction(() {
      final current = isar.syncPreferences.getSync(id) ?? state;
      if (!_autoSyncPauseGeneration.canRestore(
        token,
        currentFrequency: current.autoSyncFrequency,
      )) {
        return;
      }
      current.autoSyncFrequency = token.previousFrequency;
      isar.syncPreferences.putSync(current);
      _autoSyncPauseGeneration.recordRestore(token);
      restored = true;
    });
    if (restored) ref.invalidateSelf();
    return restored;
  }

  Future<void> setSyncMode(SyncMode value) async {
    // Recorded before queuing, so a pending Google Drive connection is
    // rejected even if its write is already waiting in the queue.
    _googleDriveConnectionIntentGeneration.recordConfigurationChange();
    await _updateCurrentPreference((current) {
      current
        ..syncMode = value
        ..chimahonDeviceId = value == SyncMode.chimahon
            ? current.chimahonDeviceId ?? _newChimahonDeviceId()
            : current.chimahonDeviceId;
    });
    ref.invalidateSelf();
  }

  Future<void> setChimahonSyncProvider(ChimahonSyncProvider value) async {
    _googleDriveConnectionIntentGeneration.recordConfigurationChange();
    await _updateCurrentPreference(
      (current) => current.chimahonSyncProvider = value,
    );
    ref.invalidateSelf();
  }

  // Queued so a settings or sync write never opens a synchronous transaction
  // while a queued async write (such as reading progress) is still open.
  Future<void> _updateCurrentPreference(void Function(SyncPreference) update) =>
      syncPreferenceRepository.writeTransaction(() {
        mutateCurrentSyncPreference(
          readCurrent: () => isar.syncPreferences.getSync(syncId!) ?? state,
          mutate: update,
          writeCurrent: isar.syncPreferences.putSync,
        );
      });

  AutoSyncPauseGeneration get _autoSyncPauseGeneration =>
      _autoSyncPauseGenerations.putIfAbsent(
        syncId!,
        () => AutoSyncPauseGeneration(syncId!),
      );

  GoogleDriveConnectionIntentGeneration
  get _googleDriveConnectionIntentGeneration =>
      _googleDriveConnectionIntentGenerations.putIfAbsent(
        syncId!,
        () => GoogleDriveConnectionIntentGeneration(syncId!),
      );

  List<ChangedPart> getAllChangedParts() {
    return isar.changedParts.filter().idIsNotNull().findAllSync();
  }

  List<ChangedPart> getChangedParts(List<ActionType> actionTypes) =>
      changedPartRepository.getByActions(actionTypes);

  void addChangedPart(
    ActionType action,
    int? isarId,
    Object data,
    bool writeTxn, {
    int? clientId,
  }) {
    if (!state.syncOn) return;
    changedPartRepository.add(
      action,
      isarId,
      data,
      writeTxn,
      clientId: clientId,
    );
  }

  Future<void> addChangedPartAsync(
    ActionType action,
    int? isarId,
    Object data,
    bool writeTxn, {
    int? clientId,
  }) async {
    if (!state.syncOn) return;
    await changedPartRepository.addAsync(
      action,
      isarId,
      data,
      writeTxn,
      clientId: clientId,
    );
  }

  Future<void> clearChangedParts(List<ActionType> actions, bool txn) =>
      changedPartRepository.clear(actions, txn);

  void clearAllChangedParts(bool txn) => changedPartRepository.clearAll(txn);
}

/// True while a restore (and its post-restore upload) is in progress.
/// main_screen.dart pauses the auto-sync timer while this is true, and
/// syncServerProvider itself checks it too, so a manual sync trigger or an
/// already-running periodic timer can't race with an in-progress restore.
@riverpod
class RestoreSyncGuard extends _$RestoreSyncGuard {
  @override
  bool build() {
    ref.keepAlive();
    return false;
  }

  void start() => state = true;
  void finish() => state = false;
}

String _newChimahonDeviceId() {
  final random = Random.secure();
  final values = List<int>.generate(16, (_) => random.nextInt(256));
  values[6] = (values[6] & 0x0f) | 0x40;
  values[8] = (values[8] & 0x3f) | 0x80;
  String hex(int value) => value.toRadixString(16).padLeft(2, '0');
  final encoded = values.map(hex).join();
  return '${encoded.substring(0, 8)}-'
      '${encoded.substring(8, 12)}-'
      '${encoded.substring(12, 16)}-'
      '${encoded.substring(16, 20)}-'
      '${encoded.substring(20)}';
}
