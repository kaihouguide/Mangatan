import 'dart:convert';

import 'package:flutter_qjs/quickjs/ffi.dart';
import 'package:mangayomi/eval/model/m_bridge.dart';
import 'package:mangayomi/repositories/category_repository.dart';
import 'package:mangayomi/repositories/chapter_repository.dart';
import 'package:mangayomi/repositories/history_repository.dart';
import 'package:mangayomi/repositories/manga_repository.dart';
import 'package:mangayomi/repositories/settings_repository.dart';
import 'package:mangayomi/repositories/track_repository.dart';
import 'package:mangayomi/repositories/update_repository.dart';
import 'package:mangayomi/models/category.dart';
import 'package:mangayomi/models/changed.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/download.dart';
import 'package:mangayomi/models/history.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/models/sync_preference.dart';
import 'package:mangayomi/models/track.dart';
import 'package:mangayomi/models/update.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/restore.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/blend_level_state_provider.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/animation_duration_scale_provider.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/flex_scheme_color_state_provider.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/pure_black_dark_mode_state_provider.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/theme_mode_state_provider.dart';
import 'package:mangayomi/modules/more/settings/browse/providers/browse_state_provider.dart';
import 'package:mangayomi/modules/more/settings/sync/providers/sync_providers.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/services/http/m_client.dart';
import 'package:mangayomi/services/sync/chimahon_deferred_payload_store.dart';
import 'package:mangayomi/services/sync/chimahon_local_sync_projection_service.dart';
import 'package:mangayomi/services/sync/chimahon_media_sync_selection.dart';
import 'package:mangayomi/services/sync/chimahon_download_plan.dart';
import 'package:mangayomi/services/sync/chimahon_local_revision.dart';
import 'package:mangayomi/services/sync/chimahon_pre_upload_safety_gate.dart';
import 'package:mangayomi/services/sync/chimahon_preference_three_way_merger.dart';
import 'package:mangayomi/services/sync/chimahon_queued_sync_gate.dart';
import 'package:mangayomi/services/sync/chimahon_remote_recovery_store.dart';
import 'package:mangayomi/services/sync/chimahon_restore_sync_coordinator.dart';
import 'package:mangayomi/services/sync/chimahon_sync_codec.dart';
import 'package:mangayomi/services/sync/cross_device_sync_engine.dart';
import 'package:mangayomi/services/sync/cross_device_sync_storage.dart';
import 'package:mangayomi/services/sync/google_drive_oauth.dart';
import 'package:mangayomi/services/sync/google_drive_refresh_token_store.dart';
import 'package:mangayomi/services/sync/google_drive_sync_storage.dart';
import 'package:mangayomi/services/sync/mangatan_epub_blob_storage.dart';
import 'package:mangayomi/services/sync/mangatan_epub_sync_service.dart';
import 'package:mangayomi/services/sync/sync_user_message.dart';
import 'package:mangayomi/services/sync/webdav_credential_store.dart';
import 'package:mangayomi/services/sync/webdav_sync_storage.dart';
import 'package:mangayomi/utils/log/logger.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:mangayomi/l10n/generated/app_localizations.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
part 'sync_server.g.dart';

class _ChimahonDownloadCancelled implements Exception {
  const _ChimahonDownloadCancelled();
}

String _syncMilliseconds(Duration duration) =>
    (duration.inMicroseconds / Duration.microsecondsPerMillisecond)
        .toStringAsFixed(2);

@riverpod
class SyncServer extends _$SyncServer {
  static final Set<int> _syncsInProgress = <int>{};

  final http = MClient.init(reqcopyWith: {'useDartHttpClient': true});
  final String _loginUrl = '/login';
  final String _syncMangaUrl = '/sync/manga';
  final String _syncHistoryUrl = '/sync/histories';
  final String _syncUpdateUrl = '/sync/updates';
  final String _syncSettingsUrl = '/sync/settings';

  @override
  void build({required int syncId}) {
    ref.keepAlive();
  }

  Future<(bool, String)> login(
    AppLocalizations l10n,
    String server,
    String username,
    String password,
  ) async {
    server = server.isNotEmpty && server[server.length - 1] == '/'
        ? server.substring(0, server.length - 1)
        : server;
    try {
      var response = await http.post(
        Uri.parse('$server$_loginUrl'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': username, 'password': password}),
      );
      var cookieHeader = response.headers["set-cookie"];
      var startIdx = cookieHeader?.indexOf("id=") ?? -1;
      var endIdx = cookieHeader?.indexOf(";", startIdx) ?? -1;
      if (startIdx == -1 || endIdx == -1) {
        return (false, "Auth failed");
      }
      final authToken = cookieHeader!.substring(startIdx + 3, endIdx);
      ref
          .read(synchingProvider(syncId: syncId).notifier)
          .login(server, username, authToken);
      botToast(l10n.sync_logged);
      return (true, "");
    } catch (error) {
      return (
        false,
        safeSyncUserMessage(error, context: SyncUserMessageContext.signIn),
      );
    }
  }

  /// Returns false only when a sync was attempted and failed.
  ///
  /// Manual callers intentionally receive a result instead of an exception so
  /// their existing toast-only behavior is preserved. A disabled automatic
  /// sync or an already-running sync is a benign skip and returns true.
  Future<bool> startSync(
    AppLocalizations l10n,
    bool silent, {
    bool upload = false,
    bool download = false,
    bool bypassRestoreGuard = false,
    Future<bool> Function(ChimahonDownloadPlan plan)? confirmChimahonDownload,
  }) async {
    // A restore in progress owns the sync server state until its own
    // post-restore upload runs (that call passes bypassRestoreGuard: true).
    // Anything else — the periodic timer or a manual trigger — must wait,
    // otherwise it could race the restore and pull stale data back down.
    if (!bypassRestoreGuard && ref.read(restoreSyncGuardProvider)) {
      if (!silent) {
        botToast(l10n.sync_restore_in_progress, second: 3);
      }
      return false;
    }
    if (!_syncsInProgress.add(syncId)) {
      if (!silent) {
        botToast('A sync is already in progress', second: 2);
      }
      return true;
    }
    try {
      final syncPreference = ref.read(synchingProvider(syncId: syncId));
      if (silent &&
          (!syncPreference.syncOn || syncPreference.autoSyncFrequency == 0)) {
        return true;
      }
      if (!silent && syncPreference.syncMode != SyncMode.chimahon) {
        botToast(l10n.sync_starting, second: 500);
      }
      if (syncPreference.syncMode == SyncMode.chimahon) {
        final ran = await _startChimahonSync(
          silent: silent,
          onStarting: silent
              ? null
              : () => botToast(l10n.sync_starting, second: 500),
          upload: upload,
          download: download,
          confirmDownload: confirmChimahonDownload,
        );
        if (!ran) return true;
        ref.invalidate(synchingProvider(syncId: syncId));
        if (!silent) {
          botToast(l10n.sync_finished, second: 2);
        }
        return true;
      }

      final syncNotifier = ref.read(synchingProvider(syncId: syncId).notifier);
      final resultManga = await _syncManga(
        l10n,
        syncNotifier,
        download: download,
        upload: upload,
      );
      if (!resultManga) {
        if (!silent) botToast(l10n.sync_failed, second: 5);
        return false;
      }
      if (syncPreference.syncHistories) {
        final resultHistory = await _syncHistory(
          l10n,
          syncNotifier,
          download: download,
          upload: upload,
        );
        if (!resultHistory) {
          if (!silent) botToast(l10n.sync_failed, second: 5);
          return false;
        }
      }
      if (syncPreference.syncUpdates) {
        final resultUpdate = await _syncUpdate(
          l10n,
          syncNotifier,
          download: download,
          upload: upload,
        );
        if (!resultUpdate) {
          if (!silent) botToast(l10n.sync_failed, second: 5);
          return false;
        }
      }
      if (syncPreference.syncSettings) {
        final resultSettings = await _syncSettings(
          l10n,
          download: download,
          upload: upload,
        );
        if (!resultSettings) {
          if (!silent) botToast(l10n.sync_failed, second: 5);
          return false;
        }
      }

      ref.invalidate(synchingProvider(syncId: syncId));
      if (!silent) {
        botToast(l10n.sync_finished, second: 2);
      }
      return true;
    } on _ChimahonDownloadCancelled {
      return true;
    } catch (error, stackTrace) {
      AppLogger.log(
        'Synchronization failed (${error.runtimeType}): $error\n$stackTrace',
        logLevel: LogLevel.error,
      );
      if (!silent) botToast(safeSyncUserMessage(error), second: 5);
      return false;
    } finally {
      _syncsInProgress.remove(syncId);
    }
  }

  Future<bool> _startChimahonSync({
    required bool silent,
    required void Function()? onStarting,
    bool upload = false,
    bool download = false,
    Future<bool> Function(ChimahonDownloadPlan plan)? confirmDownload,
  }) => runQueuedChimahonSync(
    coordinator: ChimahonRestoreSyncCoordinator.shared,
    readCurrentPreference: () => ref.read(synchingProvider(syncId: syncId)),
    silent: silent,
    synchronize: (currentPreference) {
      onStarting?.call();
      return _startChimahonSyncExclusive(
        currentPreference,
        silent: silent,
        upload: upload,
        download: download,
        confirmDownload: confirmDownload,
      );
    },
  );

  Future<void> _startChimahonSyncExclusive(
    SyncPreference syncPreference, {
    required bool silent,
    bool upload = false,
    bool download = false,
    Future<bool> Function(ChimahonDownloadPlan plan)? confirmDownload,
  }) async {
    final fullSyncWatch = Stopwatch()..start();
    final pendingRestoreWatch = Stopwatch()..start();
    final pendingManualRestoreStore =
        await defaultChimahonPendingManualRestoreStore();
    await pendingManualRestoreStore.ensureReadyForSync();
    pendingRestoreWatch.stop();
    final providerWatch = Stopwatch()..start();
    final CrossDeviceSyncStorage storage;
    late final String deferredPayloadScope;
    final legacyDeferredPayloadScopes = <String>{};
    String? rotatedGoogleRefreshToken;
    switch (syncPreference.chimahonSyncProvider) {
      case ChimahonSyncProvider.syncYomi:
        final server = _normalizeServer(syncPreference.syncYomiServer);
        final token = syncPreference.syncYomiApiToken ?? '';
        if (server.isEmpty || token.isEmpty) {
          throw const SyncStorageException(
            'SyncYomi server and API token required',
          );
        }
        storage = SyncYomiStorage(baseUrl: Uri.parse(server), apiToken: token);
        deferredPayloadScope = 'syncyomi|$server|$token';
        break;
      case ChimahonSyncProvider.googleDrive:
        const tokenStore = SecureGoogleDriveRefreshTokenStore();
        final refreshToken = await tokenStore.readRefreshToken();
        if (refreshToken == null) {
          _currentSyncNotifier.setGoogleDriveConnected(false);
          throw const SyncCredentialAccessException(
            SyncCredentialAccessFailureReason.missing,
          );
        }
        final deviceId = _currentSyncNotifier.ensureChimahonDeviceId();
        final oauth = GoogleDriveOAuthClient();
        final googleOAuthClientId = oauth.config.clientId;
        late final GoogleDriveOAuthTokens tokens;
        try {
          tokens = await oauth.refresh(refreshToken);
        } on GoogleDriveOAuthException catch (error) {
          if (error.requiresReauthentication) {
            await tokenStore.clearRefreshToken();
            _currentSyncNotifier.setGoogleDriveConnected(false);
            throw const SyncStorageException(
              'Google Drive authorization expired; reconnect Google Drive',
            );
          }
          rethrow;
        } finally {
          oauth.close();
        }
        if (tokens.refreshToken != refreshToken) {
          rotatedGoogleRefreshToken = tokens.refreshToken;
        }
        final driveStorage = GoogleDriveSyncStorage(
          accessToken: tokens.accessToken,
          deviceId: deviceId,
        );
        storage = driveStorage;
        late final String permissionId;
        try {
          permissionId = await driveStorage.currentUserPermissionId();
        } catch (_) {
          driveStorage.close();
          rethrow;
        }
        // Drive's permission ID is a stable opaque account identity available
        // through the existing app-data scope. Include the OAuth client so a
        // build configured for another Google project cannot reuse Chimahon's
        // account baseline. The store hashes this complete key before using
        // it as a directory name.
        deferredPayloadScope =
            'google-drive|$googleOAuthClientId|$permissionId';
        // Migrate sidecars made by early builds that incorrectly keyed them
        // to a refresh token. Both values are known during token rotation.
        legacyDeferredPayloadScopes
          ..add('google-drive|$refreshToken')
          ..add('google-drive|${tokens.refreshToken}');
        _currentSyncNotifier.setGoogleDriveConnected(true);
        break;
      case ChimahonSyncProvider.webDav:
        final server = _normalizeServer(syncPreference.server);
        if (server.isEmpty) {
          throw const SyncStorageException('WebDAV server URL required');
        }
        final credentials = await const SecureWebDavCredentialStore()
            .readCredentials();
        if (credentials == null) {
          _currentSyncNotifier.setGoogleDriveConnected(false);
          throw const SyncStorageException('WebDAV credentials are not saved');
        }
        final webDavStorage = WebDavSyncStorage(
          collectionUrl: Uri.parse(server),
          credentials: credentials,
        );
        storage = webDavStorage;
        final scopeHash = crypto.sha256
            .convert(
              utf8.encode(
                'webdav|${Uri.parse(server).normalizePath()}|${credentials.username}',
              ),
            )
            .toString();
        deferredPayloadScope = 'webdav|$scopeHash';
        _currentSyncNotifier.setGoogleDriveConnected(true);
        break;
    }
    providerWatch.stop();
    final setupWatch = Stopwatch()..start();
    var epubDuration = Duration.zero;
    late final Stopwatch coreWatch;
    try {
      final activeMediaSelectionScopeToken = chimahonMediaSelectionScopeToken(
        deferredPayloadScope,
      );
      final codec = const ChimahonSyncCodec();
      final localProjectionService = ChimahonLocalSyncProjectionService(
        database: isar,
        activeMediaSelectionScopeToken: activeMediaSelectionScopeToken,
        mediaSelectionStateProvider: () =>
            ChimahonMediaSyncSelectionState.fromPreference(
              isar.syncPreferences.getSync(syncId) ?? syncPreference,
            ),
      );
      final accountDeferredStore = await defaultChimahonDeferredPayloadStore(
        scopeKey: deferredPayloadScope,
      );
      final authoritativeDownloadStage =
          await defaultChimahonAuthoritativeDownloadStageStore(
            scopeKey: deferredPayloadScope,
          );
      await _migrateLegacyChimahonSidecars(
        target: accountDeferredStore,
        legacyScopeKeys: legacyDeferredPayloadScopes.where(
          (scope) => scope != deferredPayloadScope,
        ),
      );
      if (rotatedGoogleRefreshToken != null) {
        await const SecureGoogleDriveRefreshTokenStore().writeRefreshToken(
          rotatedGoogleRefreshToken,
        );
      }
      final uploadDeferredStore = LayeredChimahonDeferredPayloadStore(
        primary: accountDeferredStore,
        pendingManualRestore: pendingManualRestoreStore,
      );
      final remoteRecoveryStore = await defaultChimahonRemoteRecoveryStore(
        scopeKey: deferredPayloadScope,
      );
      final preUploadSafetyGate = ChimahonPreUploadSafetyGate(
        recoveryStore: remoteRecoveryStore,
      );
      setupWatch.stop();
      coreWatch = Stopwatch()..start();
      if (download) {
        final downloadWatch = Stopwatch()..start();
        final downloadPhaseMicroseconds = <String, int>{};
        Future<T> measureDownloadPhase<T>(
          String phase,
          Future<T> Function() action,
        ) async {
          final watch = Stopwatch()..start();
          try {
            return await action();
          } finally {
            watch.stop();
            downloadPhaseMicroseconds.update(
              phase,
              (value) => value + watch.elapsedMicroseconds,
              ifAbsent: () => watch.elapsedMicroseconds,
            );
          }
        }

        T measureDownloadPhaseSync<T>(String phase, T Function() action) {
          final watch = Stopwatch()..start();
          try {
            return action();
          } finally {
            watch.stop();
            downloadPhaseMicroseconds.update(
              phase,
              (value) => value + watch.elapsedMicroseconds,
              ifAbsent: () => watch.elapsedMicroseconds,
            );
          }
        }

        var localProjection = await measureDownloadPhase(
          'initialProjection',
          localProjectionService.createSnapshot,
        );
        final localBeforeDownload = localProjection.backup;
        final mediaSelectionBeforeDownload = localProjection.mediaSelection;
        final mediaSelectionInitializedBeforeDownload =
            localProjection.mediaSelectionInitialized;
        final mediaSelectionStateBeforeDownload =
            localProjection.persistedMediaSelectionState;
        final remote = await measureDownloadPhase('download', storage.download);
        if (remote == null) {
          throw const SyncStorageException(
            'No remote Chimahon sync data found',
          );
        }
        final backup = measureDownloadPhaseSync(
          'decode',
          () => codec.decode(remote.bytes).backup,
        );
        final downloadedSelection = chimahonMediaSelectionForExplicitRestore(
          preferences: backup.backupPreferences,
          current: mediaSelectionBeforeDownload,
        );
        final downloadedSelectionMalformed =
            ChimahonMediaSyncSelection.hasMalformedPreference(
              backup.backupPreferences,
            );
        if (downloadedSelectionMalformed) {
          throw const SyncStorageException(
            'Remote Chimahon media selection is malformed; local data was not changed',
          );
        }
        final downloadedSelectionCanInitialize = !downloadedSelectionMalformed;
        localProjection = await measureDownloadPhase(
          'previewProjection',
          localProjectionService.createSnapshot,
        );
        if (!_sameChimahonBackup(localBeforeDownload, localProjection.backup) ||
            localProjection.persistedMediaSelectionState !=
                mediaSelectionStateBeforeDownload) {
          throw const SyncStorageException(
            'Local data changed while Chimahon data was downloading; '
            'download again to avoid overwriting the newer local state',
          );
        }
        var localRevision = await measureDownloadPhase(
          'previewRevision',
          () => ChimahonLocalRevision.capture(isar, localProjection.backup),
        );
        final downloadPlan = measureDownloadPhaseSync(
          'buildPreview',
          () => ChimahonDownloadPlan(
            backup: backup,
            selection: downloadedSelection,
            localProjection: localProjection.backup,
            localMangas: isar.mangas.where().findAllSync(),
            localChapters: isar.chapters.where().findAllSync(),
            localSources: isar.sources.where().findAllSync(),
            downloadedChapterIds: isar.downloads
                .where()
                .findAllSync()
                .map((download) => download.id)
                .nonNulls
                .toSet(),
            localRevision: localRevision,
          ),
        );
        if (confirmDownload != null) {
          final confirmed = await measureDownloadPhase(
            'confirmation',
            () => confirmDownload(downloadPlan),
          );
          if (!confirmed) throw const _ChimahonDownloadCancelled();
        }
        localProjection = await measureDownloadPhase(
          'preImportProjection',
          localProjectionService.createSnapshot,
        );
        localRevision = await measureDownloadPhase(
          'preImportRevision',
          () => ChimahonLocalRevision.capture(isar, localProjection.backup),
        );
        if (!downloadPlan.matchesLocalRevision(localRevision) ||
            localProjection.persistedMediaSelectionState !=
                mediaSelectionStateBeforeDownload) {
          throw const SyncStorageException(
            'Local data changed after the Chimahon download preview; '
            'download again to review the new plan',
          );
        }
        await measureDownloadPhase(
          'staging',
          () => authoritativeDownloadStage.begin(downloadPlan.backup),
        );
        localProjection = await measureDownloadPhase(
          'stagingProjection',
          localProjectionService.createSnapshot,
        );
        localRevision = await measureDownloadPhase(
          'stagingRevision',
          () => ChimahonLocalRevision.capture(isar, localProjection.backup),
        );
        if (!downloadPlan.matchesLocalRevision(localRevision) ||
            localProjection.persistedMediaSelectionState !=
                mediaSelectionStateBeforeDownload) {
          throw const SyncStorageException(
            'Local data changed while staging the Chimahon download; '
            'download again to review the new plan',
          );
        }
        final importResult = await measureDownloadPhase(
          'import',
          () => restoreChimahonSyncData(
            ref,
            downloadPlan.backup,
            authoritativeSelection: downloadedSelection,
          ),
        );
        final downloadResult = downloadPlan.complete(importResult);
        if (!silent) {
          botToast(downloadResult.summary, second: 5);
        }
        if (storage case MangatanEpubBlobStorage epubStorage) {
          final epubWatch = Stopwatch()..start();
          final epubResult = await MangatanEpubSyncService(
            database: isar,
            storage: epubStorage,
            deviceId: _currentSyncNotifier.ensureChimahonDeviceId(),
          ).materializeRemoteOnly();
          if (!silent && epubResult.placeholdersMaterialized > 0) {
            botToast(
              'Downloaded ${epubResult.placeholdersMaterialized} EPUB file(s)',
              second: 5,
            );
          }
          _reportEpubDownloadFailures(epubResult, silent: silent);
          epubWatch.stop();
          epubDuration += epubWatch.elapsed;
        }
        // A download is not evidence that a pending manual restore reached the
        // remote backend; only the account cache staged above was updated.
        final postImportWatch = Stopwatch()..start();
        localProjection = await ChimahonLocalSyncProjectionService(
          database: isar,
          mediaSelection: downloadedSelection,
          mediaSelectionInitialized: downloadedSelectionCanInitialize
              ? true
              : mediaSelectionInitializedBeforeDownload,
          mediaSelectionUserSelected: downloadedSelectionCanInitialize
              ? false
              : mediaSelectionStateBeforeDownload.userSelected,
          mediaSelectionGeneration:
              mediaSelectionStateBeforeDownload.generation,
          mediaSelectionScopeToken: downloadedSelectionCanInitialize
              ? activeMediaSelectionScopeToken
              : mediaSelectionStateBeforeDownload.scopeToken,
        ).createSnapshot();
        final localAfterImport = localProjection.backup;
        await accountDeferredStore.saveLocalPreferenceBaseline(
          const ChimahonPreferenceThreeWayMerger().baselineForProjection(
            local: localAfterImport.backupPreferences,
            raw: downloadPlan.backup.backupPreferences,
            locallyUnrepresentableKeys:
                localProjection.unrepresentablePreferenceKeys,
          ),
        );
        await accountDeferredStore.saveLocalSourcePreferenceBaseline(
          localAfterImport.backupSourcePreferences,
        );
        if (downloadedSelectionCanInitialize) {
          _currentSyncNotifier.setChimahonMediaSelectionIfUnchanged(
            expected: mediaSelectionStateBeforeDownload,
            updated: downloadedSelection,
            updatedScopeToken: activeMediaSelectionScopeToken,
          );
        }
        // Activate the exact remote envelope only after media, settings, and
        // companion baselines have all succeeded. The stage blocks uploads if
        // the process exits anywhere before this point.
        await accountDeferredStore.save(downloadPlan.backup);
        await authoritativeDownloadStage.clear();
        postImportWatch.stop();
        downloadPhaseMicroseconds['postImport'] =
            postImportWatch.elapsedMicroseconds;
        downloadWatch.stop();
        final confirmationMicroseconds =
            downloadPhaseMicroseconds['confirmation'] ?? 0;
        AppLogger.log(
          'Chimahon download performance: '
          'total=${_syncMilliseconds(downloadWatch.elapsed)}ms '
          'processing=${_syncMilliseconds(Duration(microseconds: downloadWatch.elapsedMicroseconds - confirmationMicroseconds))}ms '
          '${downloadPhaseMicroseconds.entries.map((entry) => '${entry.key}=${_syncMilliseconds(Duration(microseconds: entry.value))}ms').join(' ')}',
          logLevel: LogLevel.debug,
        );
      } else {
        await authoritativeDownloadStage.ensureNoIncompleteDownload();
        // Rebuild the engine and tombstone snapshot if a local edit lands
        // during network I/O. This lets one automatic retry include a tracker
        // deletion or chapter update that the first snapshot could not see.
        for (var localAttempt = 0; ; localAttempt++) {
          final initialProjectionWatch = Stopwatch()..start();
          final initialProjection = await localProjectionService
              .createSnapshot();
          initialProjectionWatch.stop();
          var currentProjection = initialProjection;
          var initialProjectionPending = true;
          Future<BackupMihon> exportLocal() async {
            if (initialProjectionPending) {
              initialProjectionPending = false;
            } else {
              currentProjection = await localProjectionService.createSnapshot();
            }
            return currentProjection.backup;
          }

          final engine = CrossDeviceSyncEngine(
            storage: storage,
            exportLocal: exportLocal,
            importMerged: upload
                ? (_) async {}
                : (backup) => restoreChimahonSyncData(ref, backup),
            deferredPayloadStore: uploadDeferredStore,
            localTrackingDeletions: initialProjection.trackingDeletionKeys,
            localMediaSelection: initialProjection.mediaSelection,
            localMediaSelectionInitialized:
                initialProjection.mediaSelectionInitialized,
            localMediaSelectionUserSelected:
                initialProjection.mediaSelectionUserSelected,
            localMediaSelectionGeneration:
                initialProjection.mediaSelectionGeneration,
            localMediaSelectionState:
                initialProjection.persistedMediaSelectionState,
            localMediaSelectionProvider: () => currentProjection.mediaSelection,
            localMediaSelectionInitializedProvider: () =>
                currentProjection.mediaSelectionInitialized,
            localMediaSelectionUserSelectedProvider: () =>
                currentProjection.mediaSelectionUserSelected,
            localMediaSelectionGenerationProvider: () =>
                currentProjection.mediaSelectionGeneration,
            localMediaSelectionStateProvider: () =>
                currentProjection.persistedMediaSelectionState,
            localUnrepresentablePreferenceKeys: () =>
                currentProjection.unrepresentablePreferenceKeys,
            preUpload: preUploadSafetyGate.check,
            initialExportDuration: initialProjectionWatch.elapsed,
            onMetrics: (metrics) => AppLogger.log(
              'Chimahon sync performance: $metrics',
              logLevel: LogLevel.debug,
            ),
          );
          final result = upload
              ? await engine.uploadPreservingRemote()
              : await engine.synchronize();
          final shouldStampExplicitScope =
              result.initialMediaSelectionState.userSelected &&
              result.initialMediaSelectionState.scopeToken !=
                  activeMediaSelectionScopeToken;
          if (result.mediaSelectionNeedsPersistence ||
              shouldStampExplicitScope) {
            final retainExplicitSelection =
                result.initialMediaSelectionState.userSelected &&
                result.mediaSelection ==
                    result.initialMediaSelectionState.selection;
            _currentSyncNotifier.setChimahonMediaSelectionIfUnchanged(
              expected: result.initialMediaSelectionState,
              updated: result.mediaSelection,
              updatedUserSelected: retainExplicitSelection,
              updatedScopeToken: activeMediaSelectionScopeToken,
            );
          }
          final uploadedChangedPartIds = <int>{
            for (final deletion in result.localTrackingDeletions)
              ...?initialProjection
                  .changedPartIdsByTrackingDeletionKey[deletion],
          };
          if (uploadedChangedPartIds.isNotEmpty) {
            await isar.writeTxn(
              () =>
                  isar.changedParts.deleteAll(uploadedChangedPartIds.toList()),
            );
          }
          if (!result.requiresRetry) break;
          if (localAttempt >= 1) {
            throw const SyncStorageException(
              'Local data kept changing while Chimahon sync was uploading; '
              'sync again to finish uploading the newest state',
            );
          }
        }
        if (storage case MangatanEpubBlobStorage epubStorage) {
          final epubWatch = Stopwatch()..start();
          final epubResult = await MangatanEpubSyncService(
            database: isar,
            storage: epubStorage,
            deviceId: _currentSyncNotifier.ensureChimahonDeviceId(),
          ).synchronize();
          if (!silent && epubResult.changedAnything) {
            botToast(
              'EPUB transfer: ${epubResult.blobsUploaded} uploaded, '
              '${epubResult.placeholdersMaterialized} downloaded',
              second: 5,
            );
          }
          _reportEpubDownloadFailures(epubResult, silent: silent);
          epubWatch.stop();
          epubDuration += epubWatch.elapsed;
        }
      }
      coreWatch.stop();
    } finally {
      if (storage case ClosableSyncStorage closable) {
        closable.close();
      }
    }

    fullSyncWatch.stop();
    AppLogger.log(
      'Chimahon full sync performance: '
      'total=${(fullSyncWatch.elapsedMicroseconds / Duration.microsecondsPerMillisecond).toStringAsFixed(2)}ms '
      'pendingRestore=${(pendingRestoreWatch.elapsedMicroseconds / Duration.microsecondsPerMillisecond).toStringAsFixed(2)}ms '
      'providerSetup=${(providerWatch.elapsedMicroseconds / Duration.microsecondsPerMillisecond).toStringAsFixed(2)}ms '
      'localSetup=${(setupWatch.elapsedMicroseconds / Duration.microsecondsPerMillisecond).toStringAsFixed(2)}ms '
      'core=${(coreWatch.elapsedMicroseconds / Duration.microsecondsPerMillisecond).toStringAsFixed(2)}ms '
      'epub=${(epubDuration.inMicroseconds / Duration.microsecondsPerMillisecond).toStringAsFixed(2)}ms '
      'provider=${syncPreference.chimahonSyncProvider.name} '
      'mode=${download
          ? 'download'
          : upload
          ? 'upload'
          : 'twoWay'}',
      logLevel: LogLevel.debug,
    );
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _currentSyncNotifier.setLastSyncManga(timestamp);
    _currentSyncNotifier.setLastSyncHistory(timestamp);
    _currentSyncNotifier.setLastSyncUpdate(timestamp);
  }

  void _reportEpubDownloadFailures(
    MangatanEpubSyncResult result, {
    required bool silent,
  }) {
    if (silent || result.placeholdersFailed == 0) return;
    botToast(
      '${result.placeholdersFailed} synced EPUB file(s) could not be '
      'downloaded. They will be retried on the next sync.',
      second: 5,
    );
  }

  Synching get _currentSyncNotifier =>
      ref.read(synchingProvider(syncId: syncId).notifier);

  Future<void> _migrateLegacyChimahonSidecars({
    required FileChimahonDeferredPayloadStore target,
    required Iterable<String> legacyScopeKeys,
  }) async {
    var hasPayload = await target.load() != null;
    var hasPreferenceBaseline =
        await target.loadLocalPreferenceBaseline() != null;
    var hasSourcePreferenceBaseline =
        await target.loadLocalSourcePreferenceBaseline() != null;
    if (hasPayload && hasPreferenceBaseline && hasSourcePreferenceBaseline) {
      return;
    }

    for (final scopeKey in legacyScopeKeys.toSet()) {
      final legacy = await defaultChimahonDeferredPayloadStore(
        scopeKey: scopeKey,
      );
      if (!hasPayload) {
        final payload = await legacy.load();
        if (payload != null) {
          await target.save(payload);
          hasPayload = true;
        }
      }
      if (!hasPreferenceBaseline) {
        final baseline = await legacy.loadLocalPreferenceBaseline();
        if (baseline != null) {
          await target.saveLocalPreferenceBaseline(baseline);
          hasPreferenceBaseline = true;
        }
      }
      if (!hasSourcePreferenceBaseline) {
        final baseline = await legacy.loadLocalSourcePreferenceBaseline();
        if (baseline != null) {
          await target.saveLocalSourcePreferenceBaseline(baseline);
          hasSourcePreferenceBaseline = true;
        }
      }
      if (hasPayload && hasPreferenceBaseline && hasSourcePreferenceBaseline) {
        return;
      }
    }
  }

  bool _sameChimahonBackup(BackupMihon first, BackupMihon second) {
    final firstBytes = first.writeToBuffer();
    final secondBytes = second.writeToBuffer();
    if (firstBytes.length != secondBytes.length) return false;
    for (var index = 0; index < firstBytes.length; index++) {
      if (firstBytes[index] != secondBytes[index]) return false;
    }
    return true;
  }

  String _normalizeServer(String? server) {
    final value = (server ?? '').trim();
    if (value.endsWith('/')) return value.substring(0, value.length - 1);
    return value;
  }

  Future<bool> _syncManga(
    AppLocalizations l10n,
    Synching syncNotifier, {
    bool upload = false,
    bool download = false,
  }) async {
    final mangaData = _getMangaData(upload: upload, download: download);
    final accessToken = _getAccessToken();
    var response = await http.post(
      Uri.parse('${_getServer()}$_syncMangaUrl'),
      headers: {
        'Content-Type': 'application/json',
        'Cookie': 'id=$accessToken',
      },
      body: mangaData,
    );
    if (response.statusCode != 200) {
      botToast(l10n.sync_failed, second: 5);
      return false;
    }

    if (!upload) {
      final jsonData = jsonDecode(response.body) as Map<String, dynamic>;
      await _upsertCategories(jsonData, syncNotifier);
      await _upsertManga(jsonData, syncNotifier);
      await _upsertChapters(jsonData, syncNotifier);
      await _upsertTracks(jsonData, syncNotifier);
    } else {
      await syncNotifier.clearChangedParts([
        ActionType.removeCategory,
        ActionType.removeItem,
        ActionType.removeChapter,
        ActionType.removeTrack,
      ], true);
    }

    syncNotifier.setLastSyncManga(DateTime.now().millisecondsSinceEpoch);

    return true;
  }

  Future<bool> _syncHistory(
    AppLocalizations l10n,
    Synching syncNotifier, {
    bool upload = false,
    bool download = false,
  }) async {
    final historyData = _getHistoryData(upload: upload, download: download);
    final accessToken = _getAccessToken();
    var response = await http.post(
      Uri.parse('${_getServer()}$_syncHistoryUrl'),
      headers: {
        'Content-Type': 'application/json',
        'Cookie': 'id=$accessToken',
      },
      body: historyData,
    );
    if (response.statusCode != 200) {
      botToast(l10n.sync_failed, second: 5);
      return false;
    }

    if (!upload) {
      final jsonData = jsonDecode(response.body) as Map<String, dynamic>;
      await _upsertHistories(jsonData, syncNotifier);
    } else {
      await syncNotifier.clearChangedParts([ActionType.removeHistory], true);
    }

    syncNotifier.setLastSyncHistory(DateTime.now().millisecondsSinceEpoch);

    return true;
  }

  Future<bool> _syncUpdate(
    AppLocalizations l10n,
    Synching syncNotifier, {
    bool upload = false,
    bool download = false,
  }) async {
    final updateData = _getUpdateData(upload: upload, download: download);
    final accessToken = _getAccessToken();
    var response = await http.post(
      Uri.parse('${_getServer()}$_syncUpdateUrl'),
      headers: {
        'Content-Type': 'application/json',
        'Cookie': 'id=$accessToken',
      },
      body: updateData,
    );
    if (response.statusCode != 200) {
      botToast(l10n.sync_failed, second: 5);
      return false;
    }

    if (!upload) {
      final jsonData = jsonDecode(response.body) as Map<String, dynamic>;
      await _upsertUpdates(jsonData, syncNotifier);
    } else {
      await syncNotifier.clearChangedParts([ActionType.removeUpdate], true);
    }

    syncNotifier.setLastSyncUpdate(DateTime.now().millisecondsSinceEpoch);

    return true;
  }

  Future<bool> _syncSettings(
    AppLocalizations l10n, {
    bool upload = false,
    bool download = false,
  }) async {
    final settingsData = _getSettingsData(download: download);
    final accessToken = _getAccessToken();
    var response = await http.post(
      Uri.parse('${_getServer()}$_syncSettingsUrl'),
      headers: {
        'Content-Type': 'application/json',
        'Cookie': 'id=$accessToken',
      },
      body: settingsData,
    );
    if (response.statusCode != 200) {
      botToast(l10n.sync_failed, second: 5);
      return false;
    }

    if (!upload) {
      final jsonData = jsonDecode(response.body) as Map<String, dynamic>;
      await _upsertSettings(jsonData);
    }

    return true;
  }

  Future<void> _upsertCategories(
    Map<String, dynamic> jsonData,
    Synching syncNotifier,
  ) async {
    final categories =
        (jsonData["categories"] as List?)
            ?.map((e) => Category.fromJson(e))
            .toList() ??
        [];
    await categoryRepository.writeTransactionAsync(() async {
      for (var category in await categoryRepository.getAllAsync()) {
        final temp = categories.firstWhereOrNull((e) => e.id == category.id);
        if (temp != null) {
          if ((category.updatedAt ?? 0) < (temp.updatedAt ?? 1)) {
            await categoryRepository.putAsync(temp);
          }
          categories.remove(temp);
        } else {
          await categoryRepository.deleteAsync(category.id!);
        }
      }
      for (var category in categories) {
        await categoryRepository.putAsync(category);
      }
      await syncNotifier.clearChangedParts([ActionType.removeCategory], false);
    });
  }

  Future<void> _upsertManga(
    Map<String, dynamic> jsonData,
    Synching syncNotifier,
  ) async {
    final mangas =
        (jsonData["manga"] as List?)?.map((e) => Manga.fromJson(e)).toList() ??
        [];
    await mangaRepository.writeTransactionAsync(() async {
      for (var manga in await mangaRepository.getAllAsync()) {
        final temp = mangas.firstWhereOrNull((e) => e.id == manga.id);
        if (temp != null) {
          if ((manga.updatedAt ?? 0) < (temp.updatedAt ?? 1)) {
            await mangaRepository.putAsync(temp);
          }
          mangas.remove(temp);
        } else {
          await mangaRepository.deleteAsync(manga.id!);
        }
      }
      for (var manga in mangas) {
        await mangaRepository.putAsync(manga);
      }
      await syncNotifier.clearChangedParts([ActionType.removeItem], false);
    });
  }

  Future<void> _upsertChapters(
    Map<String, dynamic> jsonData,
    Synching syncNotifier,
  ) async {
    final chapters =
        (jsonData["chapters"] as List?)
            ?.map((e) => Chapter.fromJson(e))
            .toList() ??
        [];
    await chapterRepository.writeTransactionAsync(() async {
      for (var chapter in await chapterRepository.getAllAsync()) {
        final temp = chapters.firstWhereOrNull((e) => e.id == chapter.id);
        if (temp != null) {
          final manga = await mangaRepository.findByIdAsync(temp.mangaId!);
          if (manga != null &&
              (chapter.updatedAt ?? 0) < (temp.updatedAt ?? 1)) {
            await chapterRepository.putAsync(temp..manga.value = manga);
            await temp.manga.save();
          }
          chapters.remove(temp);
        } else {
          await chapterRepository.deleteAsync(chapter.id!);
        }
      }
      for (var chapter in chapters) {
        final manga = await mangaRepository.findByIdAsync(chapter.mangaId!);
        if (manga != null) {
          await chapterRepository.putAsync(chapter..manga.value = manga);
          await chapter.manga.save();
        }
      }
      await syncNotifier.clearChangedParts([ActionType.removeChapter], false);
    });
  }

  Future<void> _upsertTracks(
    Map<String, dynamic> jsonData,
    Synching syncNotifier,
  ) async {
    final tracks =
        (jsonData["tracks"] as List?)?.map((e) => Track.fromJson(e)).toList() ??
        [];
    await trackRepository.writeTransactionAsync(() async {
      for (var track in await trackRepository.getAllAsync()) {
        final temp = tracks.firstWhereOrNull((e) => e.id == track.id);
        if (temp != null) {
          if ((track.updatedAt ?? 0) < (temp.updatedAt ?? 1)) {
            await trackRepository.putAsync(temp);
          }
          tracks.remove(temp);
        } else {
          await trackRepository.deleteAsync(track.id!);
        }
      }
      for (var track in tracks) {
        await trackRepository.putAsync(track);
      }
      await syncNotifier.clearChangedParts([ActionType.removeTrack], false);
    });
  }

  Future<void> _upsertHistories(
    Map<String, dynamic> jsonData,
    Synching syncNotifier,
  ) async {
    final histories =
        (jsonData["histories"] as List?)
            ?.map((e) => History.fromJson(e))
            .toList() ??
        [];
    await historyRepository.writeTransactionAsync(() async {
      for (var history in await historyRepository.getAllAsync()) {
        final temp = histories.firstWhereOrNull((e) => e.id == history.id);
        if (temp != null) {
          final chapter = await chapterRepository.findById(temp.chapterId!);
          if (chapter != null &&
              (history.updatedAt ?? 0) < (temp.updatedAt ?? 1)) {
            await historyRepository.putAsync(temp..chapter.value = chapter);
            await temp.chapter.save();
          }
          histories.remove(temp);
        } else {
          await historyRepository.deleteAsync(history.id!);
        }
      }
      for (var history in histories) {
        final chapter = await chapterRepository.findById(history.chapterId!);
        if (chapter != null) {
          await historyRepository.putAsync(history..chapter.value = chapter);
          await history.chapter.save();
        }
      }
      await syncNotifier.clearChangedParts([ActionType.removeHistory], false);
    });
  }

  Future<void> _upsertUpdates(
    Map<String, dynamic> jsonData,
    Synching syncNotifier,
  ) async {
    final updates =
        (jsonData["updates"] as List?)
            ?.map((e) => Update.fromJson(e))
            .toList() ??
        [];
    await updateRepository.writeTransactionAsync(() async {
      for (var update in await updateRepository.getAllAsync()) {
        final temp = updates.firstWhereOrNull((e) => e.id == update.id);
        if (temp != null) {
          final chapter = await chapterRepository.findByMangaIdAndNameAsync(
            temp.mangaId,
            temp.chapterName,
          );
          if (chapter != null &&
              (update.updatedAt ?? 0) < (temp.updatedAt ?? 1)) {
            await updateRepository.putAsync(temp..chapter.value = chapter);
            await temp.chapter.save();
          }
          updates.remove(temp);
        } else {
          await updateRepository.deleteAsync(update.id!);
        }
      }
      for (var update in updates) {
        final chapter = await chapterRepository.findByMangaIdAndNameAsync(
          update.mangaId,
          update.chapterName,
        );
        if (chapter != null) {
          await updateRepository.putAsync(update..chapter.value = chapter);
          await update.chapter.save();
        }
      }
      await syncNotifier.clearChangedParts([ActionType.removeUpdate], false);
    });
  }

  Future<void> _upsertSettings(Map<String, dynamic> jsonData) async {
    final oldSettings = settingsRepository.current;
    final settings = Settings.fromJson(jsonData["settings"]);
    await settingsRepository.writeTransactionAsync(
      () => settingsRepository.putAsync(
        preserveDeviceLocalSettings(settings, oldSettings)
          ..cookiesList = oldSettings.cookiesList,
      ),
    );
    ref.invalidate(followSystemThemeStateProvider);
    ref.invalidate(themeModeStateProvider);
    ref.invalidate(animationDurationScaleProvider);
    ref.invalidate(blendLevelStateProvider);
    ref.invalidate(flexSchemeColorStateProvider);
    ref.invalidate(pureBlackDarkModeStateProvider);
    ref.invalidate(l10nLocaleStateProvider);
    ref.invalidate(extensionsRepoStateProvider(ItemType.manga));
    ref.invalidate(extensionsRepoStateProvider(ItemType.anime));
    ref.invalidate(extensionsRepoStateProvider(ItemType.novel));
  }

  String _getMangaData({bool upload = false, bool download = false}) {
    Map<String, dynamic> data = {};
    data["categories"] = download ? [] : _getCategories();
    data["deleted_categories"] = download
        ? []
        : _getDeletedObjects(ActionType.removeCategory);
    data["manga"] = download ? [] : _getManga();
    data["deleted_manga"] = download
        ? []
        : _getDeletedObjects(ActionType.removeItem);
    data["chapters"] = download ? [] : _getChapters();
    data["deleted_chapters"] = download
        ? []
        : _getDeletedObjects(ActionType.removeChapter);
    data["tracks"] = download ? [] : _getTracks();
    data["deleted_tracks"] = download
        ? []
        : _getDeletedObjects(ActionType.removeTrack);
    if (upload) {
      data["resetAll"] = true;
    }
    return jsonEncode(data);
  }

  String _getHistoryData({bool upload = false, bool download = false}) {
    Map<String, dynamic> data = {};
    data["histories"] = download ? [] : _getHistories();
    data["deleted_histories"] = download
        ? []
        : _getDeletedObjects(ActionType.removeHistory);
    if (upload) {
      data["resetAll"] = true;
    }
    return jsonEncode(data);
  }

  String _getUpdateData({bool upload = false, bool download = false}) {
    Map<String, dynamic> data = {};
    data["updates"] = download ? [] : _getUpdates();
    data["deleted_updates"] = download
        ? []
        : _getDeletedObjects(ActionType.removeUpdate);
    if (upload) {
      data["resetAll"] = true;
    }
    return jsonEncode(data);
  }

  String _getSettingsData({bool download = false}) {
    Map<String, dynamic> data = {};
    if (!download) {
      data["settings"] = isar.settings.getSync(227)!
        ..updatedAt ??= DateTime.now().millisecondsSinceEpoch
        ..cookiesList = [];
    }
    return jsonEncode(data);
  }

  List<int> _getDeletedObjects(ActionType actionType) {
    return ref
        .read(synchingProvider(syncId: syncId).notifier)
        .getChangedParts([actionType])
        .map((e) => e.isarId)
        .nonNulls
        .toList();
  }

  List<Map<String, dynamic>> _getManga() {
    return isar.mangas
        .filter()
        .idIsNotNull()
        .findAllSync()
        .map((e) => (e..customCoverImage = null).toJson())
        .toList();
  }

  List<Map<String, dynamic>> _getCategories() {
    return isar.categorys
        .filter()
        .idIsNotNull()
        .findAllSync()
        .map((e) => e.toJson())
        .toList();
  }

  List<Map<String, dynamic>> _getChapters() {
    return isar.chapters
        .filter()
        .idIsNotNull()
        .findAllSync()
        .map((e) => e.toJson())
        .toList();
  }

  List<Map<String, dynamic>> _getTracks() {
    return isar.tracks
        .filter()
        .idIsNotNull()
        .findAllSync()
        .map((e) => e.toJson())
        .toList();
  }

  List<Map<String, dynamic>> _getHistories() {
    return isar.historys
        .filter()
        .idIsNotNull()
        .findAllSync()
        .map((e) => e.toJson())
        .toList();
  }

  List<Map<String, dynamic>> _getUpdates() {
    return isar.updates
        .filter()
        .idIsNotNull()
        .findAllSync()
        .map((e) => e.toJson())
        .toList();
  }

  String _getAccessToken() {
    final syncPrefs = ref.watch(synchingProvider(syncId: syncId));
    return syncPrefs.authToken ?? "";
  }

  String _getServer() {
    final syncPrefs = ref.watch(synchingProvider(syncId: syncId));
    return syncPrefs.server ?? "";
  }
}
