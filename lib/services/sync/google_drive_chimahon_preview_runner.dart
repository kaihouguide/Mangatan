import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/models/sync_preference.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/services/hoshidicts/dictionary_storage.dart';
import 'package:mangayomi/services/sync/chimahon_backup_fingerprint.dart';
import 'package:mangayomi/services/sync/chimahon_backup_semantic_diff.dart';
import 'package:mangayomi/services/sync/chimahon_deferred_payload_store.dart';
import 'package:mangayomi/services/sync/chimahon_local_sync_projection_service.dart';
import 'package:mangayomi/services/sync/chimahon_media_sync_selection.dart';
import 'package:mangayomi/services/sync/chimahon_preference_safety_policy.dart';
import 'package:mangayomi/services/sync/chimahon_sync_codec.dart';
import 'package:mangayomi/services/sync/chimahon_sync_merger.dart';
import 'package:mangayomi/services/sync/chimahon_sync_safety_audit.dart';
import 'package:mangayomi/services/sync/cross_device_sync_engine.dart';
import 'package:mangayomi/services/sync/cross_device_sync_storage.dart';
import 'package:mangayomi/services/sync/google_drive_oauth.dart';
import 'package:mangayomi/services/sync/google_drive_refresh_token_store.dart';
import 'package:mangayomi/services/sync/google_drive_sync_storage.dart';
import 'package:mangayomi/services/sync/sync_bytes.dart';

typedef GoogleDriveChimahonLocalProjectionProvider =
    Future<GoogleDriveChimahonLocalProjection> Function();
typedef GoogleDriveChimahonPreviewSidecarFactory =
    Future<LayeredChimahonDeferredPayloadStore> Function(String scopeKey);
typedef GoogleDriveChimahonPreviewAudit = ChimahonSyncSafetyReport Function({
  BackupMihon? reference,
  required BackupMihon remote,
  required BackupMihon local,
  required BackupMihon proposed,
  BackupMihon? localProjection,
  required ChimahonPreferenceSafetyPolicy preferenceSafetyPolicy,
  required Set<ChimahonTrackingDeletionKey> localTrackingDeletions,
  required bool remoteWinsTies,
});
typedef GoogleDriveChimahonPreviewOAuthFactory =
    GoogleDriveChimahonPreviewOAuthSession Function();
typedef GoogleDriveChimahonPreviewCoreFactory =
    GoogleDriveChimahonPreviewCoreOperation Function({
      required String accessToken,
      required String oauthClientId,
    });

/// The local state needed by a read-only preview.
///
/// This testable value mirrors [ChimahonLocalSyncProjectionSnapshot] while
/// retaining defensive ownership of its protobuf and deletion-key sets.
class GoogleDriveChimahonLocalProjection {
  GoogleDriveChimahonLocalProjection({
    required BackupMihon backup,
    Iterable<String> unrepresentablePreferenceKeys = const {},
    Iterable<ChimahonTrackingDeletionKey> trackingDeletionKeys = const {},
    ChimahonMediaSyncSelection? mediaSelection,
    bool? mediaSelectionInitialized,
    ChimahonMediaSyncSelectionState? persistedMediaSelectionState,
  }) : _backup = backup.deepCopy()..freeze(),
       mediaSelection =
           mediaSelection ??
           persistedMediaSelectionState?.selection ??
           const ChimahonMediaSyncSelection(),
       mediaSelectionInitialized =
           mediaSelectionInitialized ??
           persistedMediaSelectionState?.initialized ??
           false,
       persistedMediaSelectionState =
           persistedMediaSelectionState ??
           ChimahonMediaSyncSelectionState(
             selection: mediaSelection ?? const ChimahonMediaSyncSelection(),
             initialized: mediaSelectionInitialized ?? false,
           ),
       unrepresentablePreferenceKeys = Set.unmodifiable(
         unrepresentablePreferenceKeys,
       ),
       trackingDeletionKeys = Set.unmodifiable(trackingDeletionKeys);

  factory GoogleDriveChimahonLocalProjection.fromSnapshot(
    ChimahonLocalSyncProjectionSnapshot snapshot,
  ) => GoogleDriveChimahonLocalProjection(
    backup: snapshot.backup,
    unrepresentablePreferenceKeys: snapshot.unrepresentablePreferenceKeys,
    trackingDeletionKeys: snapshot.trackingDeletionKeys,
    mediaSelection: snapshot.mediaSelection,
    mediaSelectionInitialized: snapshot.mediaSelectionInitialized,
    persistedMediaSelectionState: snapshot.persistedMediaSelectionState,
  );

  final BackupMihon _backup;
  final Set<String> unrepresentablePreferenceKeys;
  final Set<ChimahonTrackingDeletionKey> trackingDeletionKeys;
  final ChimahonMediaSyncSelection mediaSelection;
  final bool mediaSelectionInitialized;
  final ChimahonMediaSyncSelectionState persistedMediaSelectionState;

  BackupMihon get backup => _backup.deepCopy();

  GoogleDriveChimahonLocalProjection forScope(String activeScopeToken) {
    final selection = persistedMediaSelectionState.selectionForScope(
      activeScopeToken,
    );
    return GoogleDriveChimahonLocalProjection(
      backup: selection.withBackedPreferences(backup),
      unrepresentablePreferenceKeys: unrepresentablePreferenceKeys,
      trackingDeletionKeys: trackingDeletionKeys,
      mediaSelection: selection,
      mediaSelectionInitialized: persistedMediaSelectionState
          .isInitializedForScope(activeScopeToken),
      persistedMediaSelectionState: persistedMediaSelectionState,
    );
  }
}

/// Opens the same two sidecars as normal sync, but makes both fail closed on
/// every attempted mutation.
class GoogleDriveChimahonReadOnlySidecars {
  const GoogleDriveChimahonReadOnlySidecars._();

  static Future<LayeredChimahonDeferredPayloadStore> open({
    required String scopeKey,
    Directory? applicationSupportDirectory,
  }) async {
    final account = await defaultChimahonDeferredPayloadStore(
      scopeKey: scopeKey,
      applicationSupportDirectory: applicationSupportDirectory,
      readOnly: true,
    );
    final pendingManualRestore = await defaultChimahonPendingManualRestoreStore(
      applicationSupportDirectory: applicationSupportDirectory,
      readOnly: true,
    );
    return LayeredChimahonDeferredPayloadStore(
      primary: account,
      pendingManualRestore: pendingManualRestore,
    );
  }
}

/// Narrow OAuth session used by the preview runner.
///
/// Production wraps [GoogleDriveOAuthClient]. Tests can inject an in-memory
/// implementation and prove that credentials never leave the orchestration
/// boundary and that the session is always closed.
abstract interface class GoogleDriveChimahonPreviewOAuthSession {
  String get clientId;

  Future<String> refreshAccessToken(String refreshToken);

  void close();
}

/// A closeable preview operation created after an access token is refreshed.
abstract interface class GoogleDriveChimahonPreviewCoreOperation {
  Future<GoogleDriveChimahonPreviewReport> run({
    Uint8List? referenceBackupBytes,
  });

  void close();
}

/// App-owned credential and resource lifecycle for a Chimahon Drive preview.
///
/// The refresh token is read from the platform credential store and the access
/// token remains inside this process. The returned report has no credential,
/// account, Drive file, or Drive revision fields.
class GoogleDriveChimahonPreviewRunner {
  factory GoogleDriveChimahonPreviewRunner.withDependencies({
    required GoogleDriveRefreshTokenStore tokenStore,
    required GoogleDriveChimahonPreviewOAuthFactory oauthFactory,
    required GoogleDriveChimahonPreviewCoreFactory coreFactory,
  }) => GoogleDriveChimahonPreviewRunner._(
    tokenStore: tokenStore,
    oauthFactory: oauthFactory,
    coreFactory: coreFactory,
  );

  GoogleDriveChimahonPreviewRunner._({
    required this._tokenStore,
    required this._oauthFactory,
    required this._coreFactory,
  });

  /// Production factory. Merely constructing this object performs no platform
  /// credential-store, database, sidecar, or network access.
  factory GoogleDriveChimahonPreviewRunner.forDatabase(
    Isar database, {
    GoogleDriveRefreshTokenStore tokenStore =
        const SecureGoogleDriveRefreshTokenStore(),
    DictionaryStorage? dictionaryStorage,
    Directory? applicationSupportDirectory,
  }) => GoogleDriveChimahonPreviewRunner.withDependencies(
    tokenStore: tokenStore,
    oauthFactory: _DefaultGoogleDriveChimahonPreviewOAuthSession.new,
    coreFactory:
        ({required String accessToken, required String oauthClientId}) =>
            GoogleDriveChimahonReadOnlyPreviewCore.forDatabase(
              database,
              accessToken: accessToken,
              oauthClientId: oauthClientId,
              dictionaryStorage: dictionaryStorage,
              applicationSupportDirectory: applicationSupportDirectory,
            ),
  );

  final GoogleDriveRefreshTokenStore _tokenStore;
  final GoogleDriveChimahonPreviewOAuthFactory _oauthFactory;
  final GoogleDriveChimahonPreviewCoreFactory _coreFactory;

  Future<GoogleDriveChimahonPreviewReport> run({
    Uint8List? referenceBackupBytes,
  }) async {
    late final String? refreshToken;
    try {
      refreshToken = await _tokenStore.readRefreshToken();
    } catch (_) {
      throw const GoogleDriveChimahonPreviewException('credentialReadFailed');
    }
    if (refreshToken == null) {
      throw const GoogleDriveChimahonPreviewException('notConnected');
    }

    GoogleDriveChimahonPreviewOAuthSession? oauth;
    GoogleDriveChimahonPreviewCoreOperation? core;
    try {
      try {
        oauth = _oauthFactory();
        final accessToken = await oauth.refreshAccessToken(refreshToken);
        if (accessToken.trim().isEmpty || oauth.clientId.trim().isEmpty) {
          throw StateError('Google OAuth returned incomplete credentials.');
        }
        core = _coreFactory(
          accessToken: accessToken,
          oauthClientId: oauth.clientId,
        );
      } catch (_) {
        throw const GoogleDriveChimahonPreviewException('authorizationFailed');
      }

      try {
        return await core.run(referenceBackupBytes: referenceBackupBytes);
      } on GoogleDriveChimahonPreviewException {
        rethrow;
      } catch (_) {
        // Do not let a credential- or Drive-bearing exception reach a local
        // diagnostic callback. Callers receive a fixed safe code instead.
        throw const GoogleDriveChimahonPreviewException('previewFailed');
      }
    } finally {
      // Both production close methods are non-throwing. Guard injected
      // implementations as well so cleanup cannot replace a safe error code.
      try {
        core?.close();
      } catch (_) {}
      try {
        oauth?.close();
      } catch (_) {}
    }
  }
}

/// Read-only Drive/local orchestration after OAuth has completed.
class GoogleDriveChimahonReadOnlyPreviewCore
    implements GoogleDriveChimahonPreviewCoreOperation {
  factory GoogleDriveChimahonReadOnlyPreviewCore({
    required String oauthClientId,
    required CrossDeviceSyncStorage storage,
    required Future<String> Function() currentUserPermissionId,
    required GoogleDriveChimahonLocalProjectionProvider localProjection,
    required GoogleDriveChimahonPreviewSidecarFactory sidecars,
    void Function()? closeStorage,
    ChimahonSyncCodec codec = const ChimahonSyncCodec(),
    GoogleDriveChimahonPreviewAudit? audit,
  }) => GoogleDriveChimahonReadOnlyPreviewCore._(
    oauthClientId: oauthClientId,
    storage: storage,
    currentUserPermissionId: currentUserPermissionId,
    localProjection: localProjection,
    sidecars: sidecars,
    closeStorage: closeStorage ?? _noOp,
    codec: codec,
    audit: audit ?? const ChimahonSyncSafetyAudit().audit,
  );

  GoogleDriveChimahonReadOnlyPreviewCore._({
    required this.oauthClientId,
    required this._storage,
    required this._currentUserPermissionId,
    required this._localProjection,
    required this._sidecars,
    required this._closeStorage,
    required this._codec,
    required this._audit,
  });

  factory GoogleDriveChimahonReadOnlyPreviewCore.forDatabase(
    Isar database, {
    required String accessToken,
    required String oauthClientId,
    DictionaryStorage? dictionaryStorage,
    Directory? applicationSupportDirectory,
  }) {
    final storage = GoogleDriveSyncStorage(
      accessToken: accessToken,
      // This value is never sent by preview because uploads are disabled.
      deviceId: 'mangatan-read-only-preview',
    );
    final projectionService = ChimahonLocalSyncProjectionService(
      database: database,
      dictionaryStorage: dictionaryStorage,
      readOnly: true,
      mediaSelectionStateProvider: () =>
          ChimahonMediaSyncSelectionState.fromPreference(
            database.syncPreferences.getSync(1) ?? SyncPreference(syncId: 1),
          ),
    );
    return GoogleDriveChimahonReadOnlyPreviewCore(
      oauthClientId: oauthClientId,
      storage: storage,
      currentUserPermissionId: storage.currentUserPermissionId,
      localProjection: () async =>
          GoogleDriveChimahonLocalProjection.fromSnapshot(
            await projectionService.createSnapshot(),
          ),
      sidecars: (scopeKey) => GoogleDriveChimahonReadOnlySidecars.open(
        scopeKey: scopeKey,
        applicationSupportDirectory: applicationSupportDirectory,
      ),
      closeStorage: storage.close,
    );
  }

  final String oauthClientId;
  final CrossDeviceSyncStorage _storage;
  final Future<String> Function() _currentUserPermissionId;
  final GoogleDriveChimahonLocalProjectionProvider _localProjection;
  final GoogleDriveChimahonPreviewSidecarFactory _sidecars;
  final void Function() _closeStorage;
  final ChimahonSyncCodec _codec;
  final GoogleDriveChimahonPreviewAudit _audit;
  bool _closed = false;

  @override
  Future<GoogleDriveChimahonPreviewReport> run({
    Uint8List? referenceBackupBytes,
  }) async {
    if (_closed) throw StateError('The preview operation is closed.');

    BackupMihon? reference;
    ChimahonBackupFingerprint? referenceFingerprint;
    if (referenceBackupBytes != null) {
      try {
        final bytes = Uint8List.fromList(referenceBackupBytes);
        reference = _codec.decode(bytes).backup;
        referenceFingerprint = ChimahonBackupFingerprint.fromBytes(
          bytes,
          codec: _codec,
        );
      } on ChimahonSyncFormatException {
        throw const GoogleDriveChimahonPreviewException(
          'invalidReferenceBackup',
        );
      }
    }

    final permissionId = (await _currentUserPermissionId()).trim();
    final clientId = oauthClientId.trim();
    if (permissionId.isEmpty || clientId.isEmpty) {
      throw StateError('Google Drive did not establish an account scope.');
    }
    final deferredPayloadScope = 'google-drive|$clientId|$permissionId';
    final deferredStore = await _sidecars(deferredPayloadScope);

    final activeMediaSelectionScopeToken = chimahonMediaSelectionScopeToken(
      deferredPayloadScope,
    );
    final initialProjection = (await _localProjection()).forScope(
      activeMediaSelectionScopeToken,
    );
    final engine = CrossDeviceSyncEngine(
      storage: _ReadOnlyCrossDeviceSyncStorage(_storage),
      exportLocal: () async => initialProjection.backup,
      importMerged: (_) async {
        throw UnsupportedError('A read-only preview cannot import data.');
      },
      deferredPayloadStore: deferredStore,
      localTrackingDeletions: initialProjection.trackingDeletionKeys,
      localMediaSelection: initialProjection.mediaSelection,
      localMediaSelectionInitialized:
          initialProjection.mediaSelectionInitialized,
      localMediaSelectionUserSelected:
          initialProjection.persistedMediaSelectionState.userSelected,
      localMediaSelectionGeneration:
          initialProjection.persistedMediaSelectionState.generation,
      localMediaSelectionState: initialProjection.persistedMediaSelectionState,
      localUnrepresentablePreferenceKeys: () =>
          initialProjection.unrepresentablePreferenceKeys,
      codec: _codec,
    );
    final preview = await engine.preview();
    final finalProjection = (await _localProjection()).forScope(
      activeMediaSelectionScopeToken,
    );
    final localStability = GoogleDriveChimahonLocalStability.compare(
      initial: initialProjection,
      finalProjection: finalProjection,
      previewLocal: preview.exportedLocal,
    );

    final remote = preview.decodedRemote;
    final audit = remote == null
        ? null
        : _audit(
            reference: reference,
            remote: remote,
            local: preview.effectiveLocalIntent,
            proposed: preview.ordinaryMerged ?? preview.proposedMerged,
            localProjection: preview.exportedLocal,
            preferenceSafetyPolicy: preview.preferenceSafetyPolicy,
            localTrackingDeletions: preview.localTrackingDeletions,
            remoteWinsTies: !preview.pendingManualRestorePresent,
          );
    final remoteSnapshot = preview.remoteSnapshot;
    return GoogleDriveChimahonPreviewReport._(
      referencePresent: reference != null,
      remotePresent: remote != null,
      remoteRecoveryComplete: remoteSnapshot?.isCompleteRecovery ?? false,
      pendingManualRestorePresent: preview.pendingManualRestorePresent,
      localStability: localStability,
      referenceFingerprint: referenceFingerprint,
      remoteFingerprint: remoteSnapshot == null
          ? null
          : ChimahonBackupFingerprint.fromBytes(
              remoteSnapshot.bytes,
              codec: _codec,
            ),
      exportedLocalFingerprint: ChimahonBackupFingerprint.fromBytes(
        _codec.encode(
          preview.exportedLocal,
          format: ChimahonSyncWireFormat.gzipProtobuf,
        ),
        codec: _codec,
      ),
      localFingerprint: ChimahonBackupFingerprint.fromBytes(
        _codec.encode(
          preview.effectiveLocalIntent,
          format: ChimahonSyncWireFormat.gzipProtobuf,
        ),
        codec: _codec,
      ),
      proposedFingerprint: ChimahonBackupFingerprint.fromBytes(
        preview.proposedBytes,
        codec: _codec,
      ),
      remoteToProposedDiff: remote == null
          ? null
          : ChimahonBackupSemanticDiff.compare(
              remote: remote,
              proposed: preview.proposedMerged,
            ),
      audit: audit,
    );
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _closeStorage();
  }

  static void _noOp() {}
}

/// Exact before/after evidence for local projection stability.
class GoogleDriveChimahonLocalStability {
  GoogleDriveChimahonLocalStability._({
    required this.backupUnchanged,
    required this.unrepresentablePreferenceKeysUnchanged,
    required this.trackingDeletionKeysUnchanged,
    required this.previewUsedInitialBackup,
    required this.mediaSelectionUnchanged,
    required this.mediaSelectionInitializationUnchanged,
    required this.mediaSelectionUserSelectedUnchanged,
    required this.mediaSelectionScopeUnchanged,
    required this.mediaSelectionGenerationUnchanged,
    required Map<String, int> counts,
    required Map<String, String> hashes,
  }) : counts = Map.unmodifiable(counts),
       hashes = Map.unmodifiable(hashes);

  factory GoogleDriveChimahonLocalStability.compare({
    required GoogleDriveChimahonLocalProjection initial,
    required GoogleDriveChimahonLocalProjection finalProjection,
    required BackupMihon previewLocal,
  }) {
    final initialBytes = initial.backup.writeToBuffer();
    final finalBytes = finalProjection.backup.writeToBuffer();
    final previewBytes = previewLocal.writeToBuffer();
    final initialUnrepresentable = initial.unrepresentablePreferenceKeys;
    final finalUnrepresentable = finalProjection.unrepresentablePreferenceKeys;
    final initialTracking = initial.trackingDeletionKeys;
    final finalTracking = finalProjection.trackingDeletionKeys;
    return GoogleDriveChimahonLocalStability._(
      backupUnchanged: sameBytes(initialBytes, finalBytes),
      unrepresentablePreferenceKeysUnchanged: _sameSet(
        initialUnrepresentable,
        finalUnrepresentable,
      ),
      trackingDeletionKeysUnchanged: _sameSet(initialTracking, finalTracking),
      previewUsedInitialBackup: sameBytes(initialBytes, previewBytes),
      mediaSelectionUnchanged:
          initial.mediaSelection == finalProjection.mediaSelection,
      mediaSelectionInitializationUnchanged:
          initial.mediaSelectionInitialized ==
          finalProjection.mediaSelectionInitialized,
      mediaSelectionUserSelectedUnchanged:
          initial.persistedMediaSelectionState.userSelected ==
          finalProjection.persistedMediaSelectionState.userSelected,
      mediaSelectionScopeUnchanged:
          initial.persistedMediaSelectionState.scopeToken ==
          finalProjection.persistedMediaSelectionState.scopeToken,
      mediaSelectionGenerationUnchanged:
          initial.persistedMediaSelectionState.generation ==
          finalProjection.persistedMediaSelectionState.generation,
      counts: {
        'initialUnrepresentablePreferenceKeys': initialUnrepresentable.length,
        'finalUnrepresentablePreferenceKeys': finalUnrepresentable.length,
        'initialTrackingDeletionKeys': initialTracking.length,
        'finalTrackingDeletionKeys': finalTracking.length,
      },
      hashes: {
        'initialBackupSha256': sha256.convert(initialBytes).toString(),
        'finalBackupSha256': sha256.convert(finalBytes).toString(),
        'previewLocalBackupSha256': sha256.convert(previewBytes).toString(),
        'initialUnrepresentablePreferenceKeysSha256': _aggregateHash(
          'unrepresentable-preference-keys',
          initialUnrepresentable,
        ),
        'finalUnrepresentablePreferenceKeysSha256': _aggregateHash(
          'unrepresentable-preference-keys',
          finalUnrepresentable,
        ),
        'initialTrackingDeletionKeysSha256': _aggregateHash(
          'tracking-deletion-keys',
          initialTracking.map(_trackingDeletionKeyValue),
        ),
        'finalTrackingDeletionKeysSha256': _aggregateHash(
          'tracking-deletion-keys',
          finalTracking.map(_trackingDeletionKeyValue),
        ),
      },
    );
  }

  final bool backupUnchanged;
  final bool unrepresentablePreferenceKeysUnchanged;
  final bool trackingDeletionKeysUnchanged;
  final bool previewUsedInitialBackup;
  final bool mediaSelectionUnchanged;
  final bool mediaSelectionInitializationUnchanged;
  final bool mediaSelectionUserSelectedUnchanged;
  final bool mediaSelectionScopeUnchanged;
  final bool mediaSelectionGenerationUnchanged;
  final Map<String, int> counts;
  final Map<String, String> hashes;

  bool get stable =>
      backupUnchanged &&
      unrepresentablePreferenceKeysUnchanged &&
      trackingDeletionKeysUnchanged &&
      previewUsedInitialBackup &&
      mediaSelectionUnchanged &&
      mediaSelectionInitializationUnchanged &&
      mediaSelectionUserSelectedUnchanged &&
      mediaSelectionScopeUnchanged &&
      mediaSelectionGenerationUnchanged;

  Map<String, Object> toSafeJson() => {
    'stable': stable,
    'checks': {
      'backupUnchanged': backupUnchanged,
      'unrepresentablePreferenceKeysUnchanged':
          unrepresentablePreferenceKeysUnchanged,
      'trackingDeletionKeysUnchanged': trackingDeletionKeysUnchanged,
      'previewUsedInitialBackup': previewUsedInitialBackup,
      'mediaSelectionUnchanged': mediaSelectionUnchanged,
      'mediaSelectionInitializationUnchanged':
          mediaSelectionInitializationUnchanged,
      'mediaSelectionUserSelectedUnchanged':
          mediaSelectionUserSelectedUnchanged,
      'mediaSelectionScopeUnchanged': mediaSelectionScopeUnchanged,
      'mediaSelectionGenerationUnchanged': mediaSelectionGenerationUnchanged,
    },
    'counts': counts,
    'hashes': hashes,
  };
}

/// Aggregate-only result suitable for a local debug callback or log file.
class GoogleDriveChimahonPreviewReport {
  GoogleDriveChimahonPreviewReport._({
    required this.referencePresent,
    required this.remotePresent,
    required this.remoteRecoveryComplete,
    required this.pendingManualRestorePresent,
    required this.localStability,
    required this.referenceFingerprint,
    required this.remoteFingerprint,
    required this.exportedLocalFingerprint,
    required this.localFingerprint,
    required this.proposedFingerprint,
    required this.remoteToProposedDiff,
    required this.audit,
  });

  static const schemaVersion = 4;

  final bool referencePresent;
  final bool remotePresent;
  final bool remoteRecoveryComplete;
  final bool pendingManualRestorePresent;
  final GoogleDriveChimahonLocalStability localStability;
  final ChimahonBackupFingerprint? referenceFingerprint;
  final ChimahonBackupFingerprint? remoteFingerprint;

  /// The database projection before a pending manual-restore overlay.
  final ChimahonBackupFingerprint exportedLocalFingerprint;

  /// The effective local side audited and presented to the merger.
  final ChimahonBackupFingerprint localFingerprint;
  final ChimahonBackupFingerprint proposedFingerprint;
  final ChimahonBackupSemanticDiff? remoteToProposedDiff;
  final ChimahonSyncSafetyReport? audit;

  /// Intentionally conservative for the first live upload: an independently
  /// supplied reference, existing remote, stable local projection, and a
  /// complete zero-failure audit are all mandatory.
  bool get safeForFirstUpload =>
      referencePresent &&
      remotePresent &&
      remoteRecoveryComplete &&
      localStability.stable &&
      audit != null &&
      audit!.hardFailures.isEmpty;

  Map<String, Object?> toSafeJson() => {
    'schemaVersion': schemaVersion,
    'referencePresent': referencePresent,
    'remotePresent': remotePresent,
    'remoteRecoveryComplete': remoteRecoveryComplete,
    'pendingManualRestorePresent': pendingManualRestorePresent,
    'localProjectionStable': localStability.stable,
    'safeForFirstUpload': safeForFirstUpload,
    'fingerprints': {
      if (referenceFingerprint != null)
        'reference': referenceFingerprint!.toSafeJson(),
      if (remoteFingerprint != null) 'remote': remoteFingerprint!.toSafeJson(),
      'exportedLocal': exportedLocalFingerprint.toSafeJson(),
      'local': localFingerprint.toSafeJson(),
      'proposed': proposedFingerprint.toSafeJson(),
    },
    'remoteToProposedDiff': remoteToProposedDiff?.toSafeJson(),
    'localStability': localStability.toSafeJson(),
    'audit': audit?.toSafeJson(),
  };
}

/// Safe fixed-code failure. No underlying exception or server response is
/// retained, so callers cannot accidentally serialize credential-bearing
/// details.
class GoogleDriveChimahonPreviewException implements Exception {
  const GoogleDriveChimahonPreviewException(this.code);

  final String code;

  @override
  String toString() => 'Google Drive Chimahon preview failed ($code).';
}

class _DefaultGoogleDriveChimahonPreviewOAuthSession
    implements GoogleDriveChimahonPreviewOAuthSession {
  final GoogleDriveOAuthClient _client = GoogleDriveOAuthClient();

  @override
  String get clientId => _client.config.clientId;

  @override
  Future<String> refreshAccessToken(String refreshToken) async =>
      (await _client.refresh(refreshToken)).accessToken;

  @override
  void close() => _client.close();
}

/// Defense in depth: even if preview orchestration accidentally invokes the
/// write method in a future refactor, the request never reaches Drive.
class _ReadOnlyCrossDeviceSyncStorage implements CrossDeviceSyncStorage {
  const _ReadOnlyCrossDeviceSyncStorage(this.delegate);

  final CrossDeviceSyncStorage delegate;

  @override
  ChimahonSyncWireFormat get wireFormat => delegate.wireFormat;

  @override
  Future<RemoteSyncSnapshot?> download() => delegate.download();

  @override
  Future<String?> upload(
    Uint8List bytes, {
    String? expectedRevision,
    bool expectedAbsent = false,
  }) => Future.error(
    UnsupportedError('A read-only Chimahon preview cannot upload data.'),
  );
}

bool _sameSet<T>(Set<T> first, Set<T> second) =>
    first.length == second.length && first.containsAll(second);

String _trackingDeletionKeyValue(ChimahonTrackingDeletionKey key) =>
    _frame([key.source.toString(), key.url, key.syncId.toString()]);

String _aggregateHash(String domain, Iterable<String> values) {
  final sorted = values.toList()..sort();
  return sha256.convert(utf8.encode(_frame([domain, ...sorted]))).toString();
}

String _frame(Iterable<String> values) =>
    values.map((value) => '${utf8.encode(value).length}:$value').join();
