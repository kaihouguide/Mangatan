// Riverpod-facing orchestration for the sync-server's `/api/sync/v1`
// protocol. The wire transport lives in SyncApiClient, applying a pulled
// response to local storage lives in SyncEntityApplier, and collecting local
// changes to upload lives in ChangedRows (services/sync/*) - this class only
// sequences those three pieces and turns their results into UI-facing state
// (toasts, progress, invalidated providers).
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:crypto/crypto.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/eval/model/m_bridge.dart';
import 'package:mangayomi/l10n/generated/app_localizations.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/changed.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/download.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/models/sync_preference.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/restore.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/animation_duration_scale_provider.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/blend_level_state_provider.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/flex_scheme_color_state_provider.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/pure_black_dark_mode_state_provider.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/theme_mode_state_provider.dart';
import 'package:mangayomi/modules/more/settings/browse/providers/browse_state_provider.dart';
import 'package:mangayomi/modules/more/settings/sync/providers/sync_progress_provider.dart';
import 'package:mangayomi/modules/more/settings/sync/providers/sync_providers.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/services/http/m_client.dart';
import 'package:mangayomi/services/sync/chimahon_deferred_payload_store.dart';
import 'package:mangayomi/services/sync/chimahon_download_plan.dart';
import 'package:mangayomi/services/sync/chimahon_local_revision.dart';
import 'package:mangayomi/services/sync/chimahon_local_sync_projection_service.dart';
import 'package:mangayomi/services/sync/chimahon_media_sync_selection.dart';
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
import 'package:mangayomi/services/sync/sync_api_client.dart';
import 'package:mangayomi/services/sync/sync_change_collector.dart';
import 'package:mangayomi/services/sync/sync_entity_applier.dart';
import 'package:mangayomi/services/sync/sync_user_message.dart';
import 'package:mangayomi/services/sync/webdav_credential_store.dart';
import 'package:mangayomi/services/sync/webdav_sync_storage.dart';
import 'package:mangayomi/utils/client_id.dart';
import 'package:mangayomi/utils/log/logger.dart';
import 'package:mangayomi/utils/platform_utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:mangayomi/services/sync/sync_bytes.dart';
import 'package:mangayomi/repositories/db_write_queue.dart';
import 'package:mangayomi/modules/more/settings/sync/widgets/sync_error_details_dialog.dart';
part 'sync_server.g.dart';

/// Matches the server's SYNC.maxRowsPerEntity. A changed-row batch larger
/// than this for one entity is split across more than one request rather
/// than sent in one oversized body.
const _maxRowsPerEntity = 5000;

// Loopback port for the desktop OAuth callback. Only the protocol+hostname of
// a redirect_uri are checked server-side (see isAllowedRedirectUri in the
// sync-server repo), not the port, so this can be anything not already in use.
const _desktopOAuthCallbackPort = 48765;

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
  final _entityApplier = const SyncEntityApplier();
  late final _apiClient = SyncApiClient(http);

  @override
  void build({required int syncId}) {
    ref.keepAlive();
  }

  // ------------------------------------------------------------------
  // Login. OAuth (PKCE) only - the server's own authorize/token endpoints,
  // opened in the system browser. There is no password form: this app talks
  // to exactly one server it's paired with, not a third-party OAuth
  // provider, so the browser round trip is purely local - it's whichever
  // session is already logged into that server's website.
  // ------------------------------------------------------------------

  Future<(bool, String)> login(AppLocalizations l10n, String server) async {
    server = _normalizeServer(server);
    try {
      final verifier = _generatePkceVerifier();
      final challenge = _codeChallengeFromVerifier(verifier);
      final state = _generatePkceVerifier();
      final redirectUri = isDesktop
          ? 'http://localhost:$_desktopOAuthCallbackPort/callback'
          : 'mangayomi://oauth-callback';
      final callbackUrlScheme = isDesktop
          ? 'http://localhost:$_desktopOAuthCallbackPort'
          : 'mangayomi';

      final authorizeUrl = Uri.parse('$server/api/oauth/authorize').replace(
        queryParameters: {
          'redirect_uri': redirectUri,
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
          'state': state,
        },
      );

      final resultUrl = await FlutterWebAuth2.authenticate(
        url: authorizeUrl.toString(),
        callbackUrlScheme: callbackUrlScheme,
      );
      final resultParams = Uri.parse(resultUrl).queryParameters;
      final code = resultParams['code'];
      // Confirms this callback answers the authorize call this same login()
      // just made, not a stray/replayed one.
      if (code == null || resultParams['state'] != state) {
        return (false, "Auth failed");
      }

      final tokenResponse = await http.post(
        Uri.parse('$server/api/oauth/token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'code': code,
          'codeVerifier': verifier,
          'redirectUri': redirectUri,
        }),
      );
      if (tokenResponse.statusCode != 200) {
        return (false, "Auth failed");
      }
      final body = jsonDecode(tokenResponse.body) as Map<String, dynamic>;
      final accessToken = body['access_token'] as String?;
      final username = body['username'] as String?;
      if (accessToken == null || username == null) {
        return (false, "Auth failed");
      }

      await ref
          .read(synchingProvider(syncId: syncId).notifier)
          .login(server, username, accessToken);
      botToast(l10n.sync_logged);
      return (true, "");
    } catch (e) {
      return (false, e.toString());
    }
  }

  String _normalizePkceSegment(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  String _generatePkceVerifier() {
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    return _normalizePkceSegment(bytes);
  }

  // Must match the server's challengeFromVerifier (lib/auth/oauth.ts):
  // SHA-256 of the verifier, base64url, unpadded.
  String _codeChallengeFromVerifier(String verifier) =>
      _normalizePkceSegment(sha256.convert(utf8.encode(verifier)).bytes);

  // ------------------------------------------------------------------
  // Public entry point
  // ------------------------------------------------------------------

  /// Returns false only when a sync was attempted and failed.
  ///
  /// Manual callers intentionally receive a result instead of an exception so
  /// their existing toast-only behavior is preserved. An already-running sync,
  /// or a [scheduled] one that finds automatic sync turned off, is a benign
  /// skip and returns true.
  Future<bool> startSync(
    AppLocalizations l10n,
    bool silent, {
    bool upload = false,
    bool download = false,
    bool bypassRestoreGuard = false,
    bool scheduled = false,
    Future<bool> Function(ChimahonDownloadPlan plan)? confirmChimahonDownload,
  }) async {
    if (!ref.mounted) return false;
    // A restore in progress owns the sync server state until its own
    // post-restore upload runs (that call passes bypassRestoreGuard: true).
    // Anything else - the periodic timer or a manual trigger - must wait,
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
      if (scheduled &&
          (!syncPreference.syncOn || syncPreference.autoSyncFrequency == 0)) {
        return true;
      }
      if (syncPreference.syncMode == SyncMode.chimahon) {
        final ran = await _startChimahonSync(
          silent: silent,
          scheduled: scheduled,
          onStarting: silent
              ? null
              : () => botToast(l10n.sync_starting, second: 500),
          upload: upload,
          download: download,
          confirmDownload: confirmChimahonDownload,
        );
        if (!ran) return true;
        if (ref.mounted) ref.invalidate(synchingProvider(syncId: syncId));
        if (!silent) {
          botToast(l10n.sync_finished, second: 2);
        }
        return true;
      }
      return await _startNativeSync(
        l10n,
        silent,
        upload: upload,
        download: download,
      );
    } on _ChimahonDownloadCancelled {
      return true;
    } catch (error, stackTrace) {
      AppLogger.log(
        'Synchronization failed (${error.runtimeType}): $error\n$stackTrace',
        logLevel: LogLevel.error,
      );
      if (!silent) {
        showSyncFailureToast(safeSyncUserMessage(error), error, stackTrace);
      }
      return false;
    } finally {
      _syncsInProgress.remove(syncId);
    }
  }

  Future<bool> _startNativeSync(
    AppLocalizations l10n,
    bool silent, {
    required bool upload,
    required bool download,
  }) async {
    if (!silent) {
      botToast(l10n.sync_starting, second: 500);
    }
    final progress = ref.read(syncProgressProvider(syncId: syncId).notifier);
    progress.begin();
    try {
      if (!await _apiClient.checkVersion(_getServer())) {
        if (!silent) {
          botToast(l10n.sync_failed, second: 5);
        }
        return false;
      }
      if (!ref.mounted) return false;
      // Cheap safety net: covers a row created earlier in this same running
      // session, which the once-at-launch sweep in main.dart couldn't have
      // seen yet. See lib/utils/client_id.dart.
      await backfillMissingClientIds();
      if (!ref.mounted) return false;

      final notifier = ref.read(synchingProvider(syncId: syncId).notifier);
      final ok = upload
          ? await _forceUpload(notifier)
          : download
          ? await _fullDownload(notifier)
          : await _incrementalSync(notifier);

      if (!ok) {
        if (!silent) {
          botToast(l10n.sync_failed, second: 5);
        }
        return false;
      }
      if (ref.mounted) {
        ref.invalidate(synchingProvider(syncId: syncId));
      }
      if (!silent) {
        botToast(l10n.sync_finished, second: 2);
      }
      return true;
    } finally {
      progress.finish();
    }
  }

  /// Names only the local areas that changed, never their contents, so the
  /// log can be shared when a download-only is rejected.
  void _logChangedSinceDownloadPreview(
    String phase,
    List<String> changedSections, {
    required bool mediaSelectionChanged,
  }) {
    final changes = [
      ...changedSections,
      if (mediaSelectionChanged) 'mediaSelection',
    ];
    AppLogger.log(
      'Chimahon download-only rejected at $phase; local changes since the '
      'preview: ${changes.isEmpty ? 'unknown' : changes.join(', ')}',
      logLevel: LogLevel.warning,
    );
  }

  Future<bool> _startChimahonSync({
    required bool silent,
    required bool scheduled,
    required void Function()? onStarting,
    bool upload = false,
    bool download = false,
    Future<bool> Function(ChimahonDownloadPlan plan)? confirmDownload,
  }) => runQueuedChimahonSync(
    coordinator: ChimahonRestoreSyncCoordinator.shared,
    readCurrentPreference: () => ref.read(synchingProvider(syncId: syncId)),
    scheduled: scheduled,
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
          await _currentSyncNotifier.setGoogleDriveConnected(false);
          throw const SyncCredentialAccessException(
            SyncCredentialAccessFailureReason.missing,
          );
        }
        final deviceId = await _currentSyncNotifier.ensureChimahonDeviceId();
        final oauth = GoogleDriveOAuthClient();
        final googleOAuthClientId = oauth.config.clientId;
        late final GoogleDriveOAuthTokens tokens;
        try {
          tokens = await oauth.refresh(refreshToken);
        } on GoogleDriveOAuthException catch (error) {
          if (error.requiresReauthentication) {
            await tokenStore.clearRefreshToken();
            await _currentSyncNotifier.setGoogleDriveConnected(false);
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
        await _currentSyncNotifier.setGoogleDriveConnected(true);
        break;
      case ChimahonSyncProvider.webDav:
        final server = _normalizeServer(syncPreference.server);
        if (server.isEmpty) {
          throw const SyncStorageException('WebDAV server URL required');
        }
        final credentials = await const SecureWebDavCredentialStore()
            .readCredentials();
        if (credentials == null) {
          await _currentSyncNotifier.setGoogleDriveConnected(false);
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
        await _currentSyncNotifier.setGoogleDriveConnected(true);
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
        if (!sameMessageBytes(localBeforeDownload, localProjection.backup) ||
            localProjection.persistedMediaSelectionState !=
                mediaSelectionStateBeforeDownload) {
          throw const SyncLocalDataChangedException(
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
          _logChangedSinceDownloadPreview(
            'preview',
            downloadPlan.localRevision.changedSections(localRevision),
            mediaSelectionChanged:
                localProjection.persistedMediaSelectionState !=
                mediaSelectionStateBeforeDownload,
          );
          throw const SyncLocalDataChangedException(
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
          _logChangedSinceDownloadPreview(
            'staging',
            downloadPlan.localRevision.changedSections(localRevision),
            mediaSelectionChanged:
                localProjection.persistedMediaSelectionState !=
                mediaSelectionStateBeforeDownload,
          );
          throw const SyncLocalDataChangedException(
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
            deviceId: await _currentSyncNotifier.ensureChimahonDeviceId(),
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
          await _currentSyncNotifier.setChimahonMediaSelectionIfUnchanged(
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
            await _currentSyncNotifier.setChimahonMediaSelectionIfUnchanged(
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
            await dbWriteQueue.run(
              () => isar.writeTxn(
                () => isar.changedParts.deleteAll(
                  uploadedChangedPartIds.toList(),
                ),
              ),
            );
          }
          if (!result.requiresRetry) break;
          if (localAttempt >= 1) {
            throw const SyncLocalDataChangedException(
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
            deviceId: await _currentSyncNotifier.ensureChimahonDeviceId(),
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
      'total=${_syncMilliseconds(fullSyncWatch.elapsed)}ms '
      'pendingRestore=${_syncMilliseconds(pendingRestoreWatch.elapsed)}ms '
      'providerSetup=${_syncMilliseconds(providerWatch.elapsed)}ms '
      'localSetup=${_syncMilliseconds(setupWatch.elapsed)}ms '
      'core=${_syncMilliseconds(coreWatch.elapsed)}ms '
      'epub=${_syncMilliseconds(epubDuration)}ms '
      'provider=${syncPreference.chimahonSyncProvider.name} '
      'mode=${download
          ? 'download'
          : upload
          ? 'upload'
          : 'twoWay'}',
      logLevel: LogLevel.debug,
    );
    await _currentSyncNotifier.setLastSync(
      DateTime.now().millisecondsSinceEpoch,
    );
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

  String _normalizeServer(String? server) {
    final value = (server ?? '').trim();
    if (value.endsWith('/')) return value.substring(0, value.length - 1);
    return value;
  }

  // ------------------------------------------------------------------
  // Incremental sync: the normal path. One request handles every entity at
  // once; a request pages on its own (via cursors/sessionToken/hasMore)
  // until every entity has fully caught up, then saves the new `since`.
  // ------------------------------------------------------------------

  Future<bool> _incrementalSync(Synching notifier) async {
    final prefs = ref.read(synchingProvider(syncId: syncId));
    final since = prefs.since ?? 0;
    final changed = ChangedRows.collect(prefs, notifier);
    final chunks = changed.chunked(_maxRowsPerEntity);
    final progress = ref.read(syncProgressProvider(syncId: syncId).notifier);
    progress.addTotal(chunks.length);

    Map<String, String?>? cursors;
    String? sessionToken;
    var chunkIndex = 0;

    while (true) {
      if (!ref.mounted) return false;
      final hasChunk = chunkIndex < chunks.length;
      final body = <String, dynamic>{
        'since': since,
        'sessionToken': ?sessionToken,
        'cursors': ?cursors,
        if (hasChunk) ...chunks[chunkIndex],
      };
      if (hasChunk) chunkIndex += 1;

      final response = await _postSync(body);
      if (response == null) return false;
      if (hasChunk) progress.addDone(1);
      _trackDownloadProgress(progress, response);

      await _applyPulledEntities(response);
      sessionToken = response['sessionToken'] as String?;
      cursors = _apiClient.decodeCursors(response['cursors']);
      final hasMore = response['hasMore'] == true;

      if (chunkIndex >= chunks.length && !hasMore) {
        final syncedAt = response['syncedAt'] as int?;
        if (syncedAt != null) {
          await notifier.setSince(syncedAt);
          await notifier.setLastSync(DateTime.now().millisecondsSinceEpoch);
          await changed.clearUploaded(notifier);
        }
        return true;
      }
    }
  }

  // Adds this response's contribution to the progress bar using docs/sync_api.md's totalCounts and per-page row counts.
  void _trackDownloadProgress(
    SyncProgress progress,
    Map<String, dynamic> response,
  ) {
    final totalCounts = response['totalCounts'] as Map?;
    if (totalCounts != null) {
      final sum = totalCounts.values.fold<int>(0, (a, b) => a + (b as int));
      progress.addTotal(sum);
    }
    const pagedKeys = [
      'categories',
      'manga',
      'chapters',
      'tracks',
      'histories',
      'updates',
    ];
    final pageRows = pagedKeys.fold<int>(
      0,
      (a, key) => a + ((response[key] as List?)?.length ?? 0),
    );
    progress.addDone(pageRows);
  }

  // ------------------------------------------------------------------
  // "Upload only": local data should win. Every local row is sent, with its
  // wire `updatedAt` forced to now so it beats whatever the server holds,
  // batched like a normal upload. Deliberately does NOT delete anything on
  // the server that only exists there - diffing local against remote and
  // auto-deleting the difference would turn a client-side bug (or a fresh,
  // still-empty install) into a silent wipe of another device's data. This
  // narrows what the button promises versus the old server's full replace,
  // traded for not being a one-click way to destroy real data by accident.
  // ------------------------------------------------------------------

  Future<bool> _forceUpload(Synching notifier) async {
    final prefs = ref.read(synchingProvider(syncId: syncId));
    final since = prefs.since ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final changed = ChangedRows.collectAll(forcedUpdatedAt: now);
    final chunks = changed.chunked(_maxRowsPerEntity);
    final progress = ref.read(syncProgressProvider(syncId: syncId).notifier);
    progress.addTotal(chunks.length);

    Map<String, String?>? cursors;
    String? sessionToken;
    var chunkIndex = 0;

    while (true) {
      if (!ref.mounted) return false;
      final hasChunk = chunkIndex < chunks.length;
      final body = <String, dynamic>{
        'since': since,
        'sessionToken': ?sessionToken,
        'cursors': ?cursors,
        if (hasChunk) ...chunks[chunkIndex],
      };
      if (hasChunk) chunkIndex += 1;

      final response = await _postSync(body);
      if (response == null) return false;
      if (hasChunk) progress.addDone(1);
      _trackDownloadProgress(progress, response);

      await _applyPulledEntities(response);
      sessionToken = response['sessionToken'] as String?;
      cursors = _apiClient.decodeCursors(response['cursors']);
      final hasMore = response['hasMore'] == true;

      if (chunkIndex >= chunks.length && !hasMore) {
        final syncedAt = response['syncedAt'] as int?;
        if (syncedAt != null) {
          await notifier.setSince(syncedAt);
          await notifier.setLastSync(DateTime.now().millisecondsSinceEpoch);
          await changed.clearUploaded(notifier);
        }
        return true;
      }
    }
  }

  // ------------------------------------------------------------------
  // "Download only": pull everything the server has, merged in via the
  // normal newest-wins upsert rule (purely additive, never deletes). Same
  // reasoning as _forceUpload for why this isn't a literal mirror: wiping
  // local rows the server doesn't happen to know about is a real way to
  // lose data over one dropped page or a server-side gap, for no upside
  // over just leaving them alone.
  // ------------------------------------------------------------------

  Future<bool> _fullDownload(Synching notifier) async {
    const since = 0;
    Map<String, String?>? cursors;
    String? sessionToken;
    final progress = ref.read(syncProgressProvider(syncId: syncId).notifier);

    while (true) {
      if (!ref.mounted) return false;
      final body = <String, dynamic>{
        'since': since,
        'sessionToken': ?sessionToken,
        'cursors': ?cursors,
      };
      final response = await _postSync(body);
      if (response == null) return false;
      _trackDownloadProgress(progress, response);

      await _applyPulledEntities(response);
      sessionToken = response['sessionToken'] as String?;
      cursors = _apiClient.decodeCursors(response['cursors']);
      final hasMore = response['hasMore'] == true;

      if (!hasMore) {
        final syncedAt = response['syncedAt'] as int?;
        if (syncedAt != null) {
          await notifier.setSince(syncedAt);
          await notifier.setLastSync(DateTime.now().millisecondsSinceEpoch);
        }
        return true;
      }
    }
  }

  // ------------------------------------------------------------------
  // Wire transport
  // ------------------------------------------------------------------

  Future<Map<String, dynamic>?> _postSync(Map<String, dynamic> body) =>
      _apiClient.postSync(_getServer(), _getAccessToken(), body);

  String _getAccessToken() {
    if (!ref.mounted) return "";
    final syncPrefs = ref.read(synchingProvider(syncId: syncId));
    return syncPrefs.authToken ?? "";
  }

  String _getServer() {
    if (!ref.mounted) return "";
    final syncPrefs = ref.read(synchingProvider(syncId: syncId));
    return syncPrefs.server ?? "";
  }

  // ------------------------------------------------------------------
  // Applying a response's pulled entities to local storage, then
  // invalidating whatever app state depends on settings if they changed.
  // ------------------------------------------------------------------

  Future<void> _applyPulledEntities(Map<String, dynamic> response) async {
    final settingsChanged = await _entityApplier.apply(response);
    if (settingsChanged) _invalidateSettingsDerivedProviders();
  }

  void _invalidateSettingsDerivedProviders() {
    if (!ref.mounted) return;
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
}
