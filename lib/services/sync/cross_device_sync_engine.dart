import 'dart:typed_data';

import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupPreference.pb.dart';
import 'package:mangayomi/services/sync/chimahon_deferred_payload_store.dart';
import 'package:mangayomi/services/sync/chimahon_media_sync_selection.dart';
import 'package:mangayomi/services/sync/chimahon_pending_preference_intent.dart';
import 'package:mangayomi/services/sync/chimahon_pending_restore_authority.dart';
import 'package:mangayomi/services/sync/chimahon_preference_safety_policy.dart';
import 'package:mangayomi/services/sync/chimahon_preference_three_way_merger.dart';
import 'package:mangayomi/services/sync/chimahon_source_preference_three_way_merger.dart';
import 'package:mangayomi/services/sync/chimahon_sync_codec.dart';
import 'package:mangayomi/services/sync/chimahon_sync_merger.dart';
import 'package:mangayomi/services/sync/cross_device_sync_storage.dart';
import 'package:mangayomi/services/sync/cross_device_sync_metrics.dart';
import 'package:protobuf/protobuf.dart';
import 'package:mangayomi/services/sync/sync_bytes.dart';

typedef SyncBackupExporter = Future<BackupMihon> Function();
typedef SyncBackupImporter = Future<void> Function(BackupMihon backup);
typedef SyncUnrepresentablePreferenceKeysProvider = Set<String> Function();
typedef SyncMediaSelectionProvider = ChimahonMediaSyncSelection Function();
typedef SyncMediaSelectionInitializedProvider = bool Function();
typedef SyncMediaSelectionUserSelectedProvider = bool Function();
typedef SyncMediaSelectionGenerationProvider = int Function();
typedef SyncMediaSelectionStateProvider =
    ChimahonMediaSyncSelectionState Function();
typedef SyncPreUploadHook = Future<void> Function(
  CrossDeviceSyncPreview preview,
);

Set<String> _noUnrepresentableKeys() => const {};

class CrossDeviceSyncResult {
  const CrossDeviceSyncResult({
    required this.hadRemoteData,
    required this.remoteRevision,
    this.requiresRetry = false,
    this.mediaSelection = const ChimahonMediaSyncSelection(),
    this.mediaSelectionInitializationCompleted = false,
    this.mediaSelectionNeedsPersistence = false,
    this.initialMediaSelection = const ChimahonMediaSyncSelection(),
    this.initialMediaSelectionInitialized = false,
    this.initialMediaSelectionGeneration = 0,
    this.initialMediaSelectionState = const ChimahonMediaSyncSelectionState(),
    this.localTrackingDeletions = const {},
    this.metrics,
  });

  final bool hadRemoteData;
  final String? remoteRevision;

  /// The remote projection was committed (or confirmed already current), but
  /// the local projection changed while network I/O was in flight. No stale
  /// payload was imported; another sync is needed for the newer local state.
  final bool requiresRetry;

  /// The selection used for the successfully committed remote projection.
  final ChimahonMediaSyncSelection mediaSelection;

  /// True when this successful commit completed first-contact initialization
  /// and the caller should persist [mediaSelection].
  final bool mediaSelectionInitializationCompleted;

  /// Whether the caller should mirror [mediaSelection] into persisted UI state
  /// after confirming no concurrent raw export change occurred.
  final bool mediaSelectionNeedsPersistence;
  final ChimahonMediaSyncSelection initialMediaSelection;
  final bool initialMediaSelectionInitialized;
  final int initialMediaSelectionGeneration;
  final ChimahonMediaSyncSelectionState initialMediaSelectionState;

  /// Tracker deletion evidence that was included after media filtering.
  final Set<ChimahonTrackingDeletionKey> localTrackingDeletions;

  /// Performance measurements for engine-produced results.
  final CrossDeviceSyncMetrics? metrics;

  CrossDeviceSyncResult _withMetrics(CrossDeviceSyncMetrics metrics) =>
      CrossDeviceSyncResult(
        hadRemoteData: hadRemoteData,
        remoteRevision: remoteRevision,
        requiresRetry: requiresRetry,
        mediaSelection: mediaSelection,
        mediaSelectionInitializationCompleted:
            mediaSelectionInitializationCompleted,
        mediaSelectionNeedsPersistence: mediaSelectionNeedsPersistence,
        initialMediaSelection: initialMediaSelection,
        initialMediaSelectionInitialized: initialMediaSelectionInitialized,
        initialMediaSelectionGeneration: initialMediaSelectionGeneration,
        initialMediaSelectionState: initialMediaSelectionState,
        localTrackingDeletions: localTrackingDeletions,
        metrics: metrics,
      );
}

/// A defensive, read-only view of the exact payload a sync would propose.
///
/// Protobuf messages and byte buffers are mutable, so message and byte getters
/// return copies. Mutating a returned value cannot alter this preview or a
/// later value returned by another getter.
class CrossDeviceSyncPreview {
  CrossDeviceSyncPreview._({
    required BackupMihon exportedLocal,
    required BackupMihon effectiveLocalIntent,
    required Iterable<ChimahonTrackingDeletionKey> localTrackingDeletions,
    required RemoteSyncSnapshot? remoteSnapshot,
    required BackupMihon? decodedRemote,
    required BackupMihon proposedMerged,
    required BackupMihon? ordinaryMerged,
    required Uint8List proposedBytes,
    required this.preferenceSafetyPolicy,
    required Set<String> unrepresentablePreferenceKeys,
    required this.pendingManualRestorePresent,
    required this.mediaSelection,
    required this.mediaSelectionResolvedFromRemote,
  }) : _exportedLocal = exportedLocal.deepCopy(),
       _effectiveLocalIntent = effectiveLocalIntent.deepCopy(),
       localTrackingDeletions = Set.unmodifiable(localTrackingDeletions),
       _remoteBytes = remoteSnapshot == null
           ? null
           : Uint8List.fromList(remoteSnapshot.bytes),
       _remoteRevision = remoteSnapshot?.revision,
       _remoteIsCompleteRecovery = remoteSnapshot?.isCompleteRecovery ?? false,
       _remoteUploadRetainsAllRemoteByteBlobs =
           remoteSnapshot?.uploadRetainsAllRemoteByteBlobs ?? false,
       _decodedRemote = decodedRemote?.deepCopy(),
       _proposedMerged = proposedMerged.deepCopy(),
       _ordinaryMerged = ordinaryMerged?.deepCopy(),
       _proposedBytes = Uint8List.fromList(proposedBytes),
       unrepresentablePreferenceKeys = Set<String>.unmodifiable(
         unrepresentablePreferenceKeys,
       );

  final BackupMihon _exportedLocal;
  final BackupMihon _effectiveLocalIntent;
  final Uint8List? _remoteBytes;
  final String? _remoteRevision;
  final bool _remoteIsCompleteRecovery;
  final bool _remoteUploadRetainsAllRemoteByteBlobs;
  final BackupMihon? _decodedRemote;
  final BackupMihon _proposedMerged;
  final BackupMihon? _ordinaryMerged;
  final Uint8List _proposedBytes;

  /// Key-origin evidence for preference value checks. It contains no values.
  final ChimahonPreferenceSafetyPolicy preferenceSafetyPolicy;

  /// Explicit local tracker removals applied while producing this payload.
  ///
  /// Without this immutable evidence, a safety audit cannot distinguish a
  /// deliberate removal from an accidental loss of a remote tracking row.
  final Set<ChimahonTrackingDeletionKey> localTrackingDeletions;

  BackupMihon get exportedLocal => _exportedLocal.deepCopy();

  /// The exact local side presented to the merger.
  ///
  /// Unlike [exportedLocal], this includes a pending manual-restore payload and
  /// the current local settings/source-settings intent overlaid on that
  /// payload. Safety checks must use this value so selected restore data is not
  /// mistaken for remote-only state and can be proven present in the proposed
  /// upload. The returned protobuf is a defensive copy.
  BackupMihon get effectiveLocalIntent => _effectiveLocalIntent.deepCopy();

  RemoteSyncSnapshot? get remoteSnapshot => _remoteBytes == null
      ? null
      : RemoteSyncSnapshot(
          bytes: Uint8List.fromList(_remoteBytes),
          revision: _remoteRevision,
          isCompleteRecovery: _remoteIsCompleteRecovery,
          uploadRetainsAllRemoteByteBlobs:
              _remoteUploadRetainsAllRemoteByteBlobs,
        );

  BackupMihon? get decodedRemote => _decodedRemote?.deepCopy();

  BackupMihon get proposedMerged => _proposedMerged.deepCopy();

  /// Present only for an explicit restore. The ordinary conflict transition
  /// is audited separately from the restore, whose selected and untouched
  /// records have already been proven against the decoded upload bytes.
  BackupMihon? get ordinaryMerged => _ordinaryMerged?.deepCopy();

  Uint8List get proposedBytes => Uint8List.fromList(_proposedBytes);

  final Set<String> unrepresentablePreferenceKeys;
  final bool pendingManualRestorePresent;
  final ChimahonMediaSyncSelection mediaSelection;
  final bool mediaSelectionResolvedFromRemote;
}

/// Provider-neutral orchestration. UI scheduling and authentication are kept
/// outside this class so the same backend works for Google Drive, SyncYomi,
/// WebDAV, or a filesystem-backed provider.
class CrossDeviceSyncEngine {
  CrossDeviceSyncEngine({
    required this.storage,
    required this.exportLocal,
    required this.importMerged,
    this.localUnrepresentablePreferenceKeys = _noUnrepresentableKeys,
    this.deferredPayloadStore,
    Iterable<ChimahonTrackingDeletionKey> localTrackingDeletions = const {},
    this.codec = const ChimahonSyncCodec(),
    this.merger = const ChimahonSyncMerger(),
    this.preferenceMerger = const ChimahonPreferenceThreeWayMerger(),
    this.sourcePreferenceMerger =
        const ChimahonSourcePreferenceThreeWayMerger(),
    this.pendingRestoreAuthority = const ChimahonPendingRestoreAuthority(),
    this.localMediaSelection = const ChimahonMediaSyncSelection(),
    this.localMediaSelectionInitialized = false,
    this.localMediaSelectionUserSelected = false,
    this.localMediaSelectionGeneration = 0,
    this.localMediaSelectionState,
    this.localMediaSelectionProvider,
    this.localMediaSelectionInitializedProvider,
    this.localMediaSelectionUserSelectedProvider,
    this.localMediaSelectionGenerationProvider,
    this.localMediaSelectionStateProvider,
    this.preUpload,
    this.onMetrics,
    this.initialExportDuration = Duration.zero,
  }) : localTrackingDeletions = Set.unmodifiable(localTrackingDeletions);

  final CrossDeviceSyncStorage storage;
  final SyncBackupExporter exportLocal;
  final SyncBackupImporter importMerged;

  /// Called immediately after [exportLocal] and must describe that same local
  /// settings projection. These omissions are projection gaps, not deletions.
  final SyncUnrepresentablePreferenceKeysProvider
  localUnrepresentablePreferenceKeys;
  final ChimahonDeferredPayloadStore? deferredPayloadStore;
  final Set<ChimahonTrackingDeletionKey> localTrackingDeletions;
  final ChimahonSyncCodec codec;
  final ChimahonSyncMerger merger;
  final ChimahonPreferenceThreeWayMerger preferenceMerger;
  final ChimahonSourcePreferenceThreeWayMerger sourcePreferenceMerger;
  final ChimahonPendingRestoreAuthority pendingRestoreAuthority;
  final ChimahonMediaSyncSelection localMediaSelection;
  final bool localMediaSelectionInitialized;
  final bool localMediaSelectionUserSelected;
  final int localMediaSelectionGeneration;
  final ChimahonMediaSyncSelectionState? localMediaSelectionState;
  final SyncMediaSelectionProvider? localMediaSelectionProvider;
  final SyncMediaSelectionInitializedProvider?
  localMediaSelectionInitializedProvider;
  final SyncMediaSelectionUserSelectedProvider?
  localMediaSelectionUserSelectedProvider;
  final SyncMediaSelectionGenerationProvider?
  localMediaSelectionGenerationProvider;
  final SyncMediaSelectionStateProvider? localMediaSelectionStateProvider;

  /// An optional fail-closed check over the exact prepared upload attempt.
  ///
  /// The hook runs after all reads and encoding, but before [storage.upload],
  /// for every conflict retry that needs a write. It is skipped when a complete
  /// remote snapshot already contains the exact proposed protobuf payload.
  /// Throwing prevents the upload, import, and all deferred/pending/baseline
  /// sidecar writes for that attempt.
  final SyncPreUploadHook? preUpload;

  /// Receives the completed measurements after a synchronization succeeds or
  /// terminates with an error. Reporter failures cannot affect sync behavior.
  final CrossDeviceSyncMetricsReporter? onMetrics;

  /// Time already spent producing a cached first export supplied by
  /// [exportLocal]. Production constructs that snapshot before the engine so
  /// its metadata can configure reconciliation; including it here keeps the
  /// reported export and total durations complete.
  final Duration initialExportDuration;

  Future<CrossDeviceSyncResult> synchronize({int maxConflictRetries = 2}) =>
      _runWithConflictRetries(
        importAfterCommit: true,
        maxConflictRetries: maxConflictRetries,
      );

  /// Uploads the local projection without discarding records that only exist
  /// in Chimahon's remote payload.
  ///
  /// This is intentionally still a read/merge/write operation. A blind upload
  /// is unsafe because Mangatan cannot export data for sources that are not
  /// installed locally, while the remote Chimahon backup can contain it.
  Future<CrossDeviceSyncResult> uploadPreservingRemote({
    int maxConflictRetries = 2,
  }) => _runWithConflictRetries(
    importAfterCommit: false,
    maxConflictRetries: maxConflictRetries,
  );

  /// Prepares the exact payload [synchronize] or [uploadPreservingRemote]
  /// would attempt to upload, without changing local or remote state.
  ///
  /// This performs one remote download and read-only sidecar loads. It never
  /// uploads, imports, or advances any deferred/pending/baseline sidecar.
  Future<CrossDeviceSyncPreview> preview() async {
    final prepared = await _prepareSyncPayload(null);
    return _previewFor(prepared);
  }

  CrossDeviceSyncPreview _previewFor(_PreparedSyncPayload prepared) {
    return CrossDeviceSyncPreview._(
      exportedLocal: prepared.exported,
      effectiveLocalIntent: prepared.effectiveLocalIntent,
      localTrackingDeletions: prepared.localTrackingDeletions,
      remoteSnapshot: prepared.remoteSnapshot,
      decodedRemote: prepared.remote,
      proposedMerged: prepared.merged,
      ordinaryMerged: prepared.ordinaryMerged,
      proposedBytes: prepared.bytes,
      preferenceSafetyPolicy: prepared.preferenceSafetyPolicy,
      unrepresentablePreferenceKeys: prepared.unrepresentablePreferenceKeys,
      pendingManualRestorePresent: prepared.pendingLocal != null,
      mediaSelection: prepared.mediaSelection,
      mediaSelectionResolvedFromRemote:
          prepared.mediaSelectionResolvedFromRemote,
    );
  }

  Future<CrossDeviceSyncResult> _runWithConflictRetries({
    required bool importAfterCommit,
    required int maxConflictRetries,
  }) async {
    final metrics = _SyncMetricsRecorder(initialExportDuration);
    try {
      for (var attempt = 0; ; attempt++) {
        metrics.attempts++;
        try {
          final result = await _mergeAndCommitOnce(
            importAfterCommit: importAfterCommit,
            metrics: metrics,
          );
          final snapshot = metrics.snapshot();
          _reportMetrics(snapshot);
          return result._withMetrics(snapshot);
        } on SyncConflictException {
          metrics.conflicts++;
          if (attempt >= maxConflictRetries) rethrow;
        }
      }
    } catch (_) {
      _reportMetrics(metrics.snapshot());
      rethrow;
    }
  }

  void _reportMetrics(CrossDeviceSyncMetrics metrics) {
    try {
      onMetrics?.call(metrics);
    } catch (_) {
      // Performance reporting must never affect synchronization behavior.
    }
  }

  Future<CrossDeviceSyncResult> _mergeAndCommitOnce({
    required bool importAfterCommit,
    required _SyncMetricsRecorder metrics,
  }) async {
    final prepared = await _prepareSyncPayload(metrics);
    if (_canSkipUpload(prepared)) {
      metrics.skippedUpload = true;
      final revision = await metrics.measureAsync(
        CrossDeviceSyncPhase.confirmNoOp,
        () => _confirmNoOpRemote(prepared),
      );
      return _finalizeSuccessfulCommit(
        prepared: prepared,
        revision: revision,
        importAfterCommit: importAfterCommit,
        metrics: metrics,
      );
    }

    if (preUpload != null) {
      await metrics.measureAsync(
        CrossDeviceSyncPhase.preUpload,
        () => preUpload!.call(_previewFor(prepared)),
      );
    }
    final revision = await metrics.measureAsync(
      CrossDeviceSyncPhase.upload,
      () => storage.upload(
        prepared.bytes,
        expectedRevision: prepared.remoteSnapshot?.revision,
        expectedAbsent: prepared.remoteSnapshot == null,
      ),
    );
    metrics.uploaded = true;
    return _finalizeSuccessfulCommit(
      prepared: prepared,
      revision: revision,
      importAfterCommit: importAfterCommit,
      metrics: metrics,
    );
  }

  bool _canSkipUpload(_PreparedSyncPayload prepared) {
    final remoteProtobufBytes = prepared.remoteProtobufBytes;
    final remoteSnapshot = prepared.remoteSnapshot;
    // Skipping [storage.upload] also skips its conditional-write proof. Only a
    // complete snapshot with an opaque generation token can use the equivalent
    // verification read in [_confirmNoOpRemote].
    return remoteSnapshot?.isCompleteRecovery == true &&
        remoteSnapshot!.revision?.isNotEmpty == true &&
        remoteProtobufBytes != null &&
        sameBytes(remoteProtobufBytes, prepared.proposedProtobufBytes);
  }

  Future<String?> _confirmNoOpRemote(_PreparedSyncPayload prepared) async {
    final expected = prepared.remoteSnapshot!;
    final current = await storage.download();
    if (current == null ||
        !current.isCompleteRecovery ||
        current.revision != expected.revision) {
      throw const SyncConflictException();
    }

    try {
      if (sameBytes(current.bytes, prepared.bytes)) return current.revision;
      final currentProtobufBytes = codec.decode(current.bytes).protobufBytes;
      if (!sameBytes(currentProtobufBytes, prepared.proposedProtobufBytes)) {
        throw const SyncConflictException();
      }
    } on ChimahonSyncFormatException {
      // Re-prepare against the changed snapshot. If it remains invalid, the
      // normal preparation path reports the format failure on the next attempt.
      throw const SyncConflictException();
    }
    return current.revision;
  }

  Future<CrossDeviceSyncResult> _finalizeSuccessfulCommit({
    required _PreparedSyncPayload prepared,
    required String? revision,
    required bool importAfterCommit,
    required _SyncMetricsRecorder metrics,
  }) async {
    // Re-read before importing. Remote I/O can be slow enough for a reader
    // action or settings edit to land after the first export. Importing [merged]
    // in that case would overwrite the newer local value with a stale projection.
    var localAfterCommit = await metrics.measureAsync(
      CrossDeviceSyncPhase.recheckLocal,
      exportLocal,
    );
    final mediaSelectionGenerationAfterCommit =
        localMediaSelectionGenerationProvider?.call() ??
        localMediaSelectionGeneration;
    var unrepresentablePreferenceKeysAfterCommit = Set<String>.unmodifiable(
      localUnrepresentablePreferenceKeys(),
    );
    final requiresRetry = metrics.measureSync(
      CrossDeviceSyncPhase.compareLocal,
      () =>
          !_sameBackup(prepared.exported, localAfterCommit) ||
          mediaSelectionGenerationAfterCommit !=
              prepared.initialMediaSelectionGeneration,
    );
    if (importAfterCommit && !requiresRetry) {
      await metrics.measureAsync(
        CrossDeviceSyncPhase.importMerged,
        () => importMerged(prepared.merged),
      );
      metrics.imported = true;
      localAfterCommit = await metrics.measureAsync(
        CrossDeviceSyncPhase.recheckLocal,
        exportLocal,
      );
      unrepresentablePreferenceKeysAfterCommit = Set<String>.unmodifiable(
        localUnrepresentablePreferenceKeys(),
      );
    }
    final projectedLocalAfterCommit = prepared.mediaSelection.projectLocal(
      localAfterCommit,
    );
    final persistStarted = metrics.elapsedMicroseconds;
    // If local state changed in flight, [merged] is now the real remote
    // baseline but the newer local settings have not reached it yet. Keep the
    // pre-commit projection as the local comparison baseline so the retry
    // recognizes those values as local edits. Advancing the baseline to
    // [localAfterCommit] here would make the stale remote look authoritative
    // and could undo the edit on the next synchronize pass.
    final projectedAppPreferenceBaseline = requiresRetry
        ? prepared.projectedExported.backupPreferences
        : projectedLocalAfterCommit.backupPreferences;
    final appPreferenceBaselineAfterCommit = preferenceMerger
        .baselineForProjection(
          local: projectedAppPreferenceBaseline,
          raw: prepared.merged.backupPreferences,
          locallyUnrepresentableKeys: requiresRetry
              ? prepared.unrepresentablePreferenceKeys
              : unrepresentablePreferenceKeysAfterCommit,
        );
    final sourcePreferenceBaselineAfterCommit = requiresRetry
        ? prepared.projectedExported.backupSourcePreferences
        : projectedLocalAfterCommit.backupSourcePreferences;
    await prepared.localPreferenceStore?.saveLocalPreferenceBaseline(
      appPreferenceBaselineAfterCommit,
    );
    await prepared.localSourcePreferenceStore
        ?.saveLocalSourcePreferenceBaseline(
          sourcePreferenceBaselineAfterCommit,
        );
    // Publish the remote baseline last. A layered store consumes the pending
    // restore here, so clearing it before either projection baseline succeeds
    // would lose the retry evidence after a local disk failure. The pending
    // store's own baselines remain intact until this final acknowledgement.
    await deferredPayloadStore?.save(prepared.merged);
    metrics.addElapsed(CrossDeviceSyncPhase.persistSidecars, persistStarted);
    return CrossDeviceSyncResult(
      hadRemoteData: prepared.remoteSnapshot != null,
      remoteRevision: revision,
      requiresRetry: requiresRetry,
      mediaSelection: prepared.mediaSelection,
      mediaSelectionInitializationCompleted:
          !prepared.initialMediaSelectionInitialized &&
          prepared.mediaSelectionInitializationCanComplete,
      mediaSelectionNeedsPersistence:
          prepared.mediaSelectionInitializationCanComplete &&
          (!prepared.initialMediaSelectionInitialized ||
              prepared.mediaSelection != prepared.initialMediaSelection),
      initialMediaSelection: prepared.initialMediaSelection,
      initialMediaSelectionInitialized:
          prepared.initialMediaSelectionInitialized,
      initialMediaSelectionGeneration: prepared.initialMediaSelectionGeneration,
      initialMediaSelectionState: prepared.initialMediaSelectionState,
      localTrackingDeletions: prepared.localTrackingDeletions,
    );
  }

  Future<_PreparedSyncPayload> _prepareSyncPayload(
    _SyncMetricsRecorder? metrics,
  ) async {
    final exported = metrics == null
        ? await exportLocal()
        : await metrics.measureAsync(
            CrossDeviceSyncPhase.exportLocal,
            exportLocal,
          );
    final providedLocalMediaSelection =
        localMediaSelectionProvider?.call() ?? localMediaSelection;
    final currentLocalMediaSelection =
        ChimahonMediaSyncSelection.fromPreferences(
          exported.backupPreferences,
          fallback: providedLocalMediaSelection,
        );
    final currentLocalMediaSelectionInitialized =
        localMediaSelectionInitializedProvider?.call() ??
        localMediaSelectionInitialized;
    final currentLocalMediaSelectionUserSelected =
        localMediaSelectionUserSelectedProvider?.call() ??
        localMediaSelectionUserSelected;
    final currentLocalMediaSelectionGeneration =
        localMediaSelectionGenerationProvider?.call() ??
        localMediaSelectionGeneration;
    final currentLocalMediaSelectionState =
        localMediaSelectionStateProvider?.call() ??
        localMediaSelectionState ??
        ChimahonMediaSyncSelectionState(
          selection: currentLocalMediaSelection,
          initialized: currentLocalMediaSelectionInitialized,
          userSelected: currentLocalMediaSelectionUserSelected,
          generation: currentLocalMediaSelectionGeneration,
        );
    final unrepresentablePreferenceKeys = Set<String>.unmodifiable(
      localUnrepresentablePreferenceKeys(),
    );
    final pendingLocalStore =
        deferredPayloadStore is ChimahonPendingLocalPayloadStore
        ? deferredPayloadStore as ChimahonPendingLocalPayloadStore
        : null;
    final pendingProjectionBaselineStore =
        deferredPayloadStore is ChimahonPendingLocalProjectionBaselineStore
        ? deferredPayloadStore as ChimahonPendingLocalProjectionBaselineStore
        : null;
    final localPreferenceStore =
        deferredPayloadStore is ChimahonLocalPreferenceBaselineStore
        ? deferredPayloadStore as ChimahonLocalPreferenceBaselineStore
        : null;
    final localSourcePreferenceStore =
        deferredPayloadStore is ChimahonLocalSourcePreferenceBaselineStore
        ? deferredPayloadStore as ChimahonLocalSourcePreferenceBaselineStore
        : null;
    Future<
      (
        BackupMihon?,
        BackupMihon?,
        List<BackupPreference>?,
        List<BackupSourcePreferences>?,
        List<BackupPreference>?,
        List<BackupSourcePreferences>?,
      )
    >
    readSidecars() => (
      deferredPayloadStore?.load() ?? Future<BackupMihon?>.value(),
      pendingLocalStore?.loadPendingLocalPayload() ??
          Future<BackupMihon?>.value(),
      pendingProjectionBaselineStore?.loadPendingLocalPreferenceBaseline() ??
          Future<List<BackupPreference>?>.value(),
      pendingProjectionBaselineStore
              ?.loadPendingLocalSourcePreferenceBaseline() ??
          Future<List<BackupSourcePreferences>?>.value(),
      localPreferenceStore?.loadLocalPreferenceBaseline() ??
          Future<List<BackupPreference>?>.value(),
      localSourcePreferenceStore?.loadLocalSourcePreferenceBaseline() ??
          Future<List<BackupSourcePreferences>?>.value(),
    ).wait;

    final sidecarsFuture = metrics == null
        ? readSidecars()
        : metrics.measureAsync(CrossDeviceSyncPhase.readSidecars, readSidecars);
    final remoteFuture = metrics == null
        ? storage.download()
        : metrics.measureAsync(CrossDeviceSyncPhase.download, storage.download);
    final (sidecars, remoteSnapshot) = await (
      sidecarsFuture,
      remoteFuture,
    ).wait;
    final (
      deferred,
      pendingLocal,
      pendingLocalPreferenceBaseline,
      pendingLocalSourcePreferenceBaseline,
      localPreferenceBaseline,
      localSourcePreferenceBaseline,
    ) = sidecars;
    metrics?.remoteBytes = remoteSnapshot?.bytes.length ?? 0;
    final decodedRemote = remoteSnapshot == null
        ? null
        : metrics == null
        ? codec.decode(remoteSnapshot.bytes)
        : metrics.measureSync(
            CrossDeviceSyncPhase.decode,
            () => codec.decode(remoteSnapshot.bytes),
          );
    final remote = decodedRemote?.backup;

    final reconcileStarted = metrics?.elapsedMicroseconds;
    final bootstrapAppPreferences =
        localPreferenceStore != null && localPreferenceBaseline == null;
    final rawLocalPreferenceIntent = pendingLocal == null
        ? exported.backupPreferences.toList(growable: false)
        : const ChimahonPendingPreferenceIntent().mergeApp(
            pending: pendingLocal.backupPreferences,
            projectedBaseline: pendingLocalPreferenceBaseline,
            current: exported.backupPreferences,
          );
    List<BackupPreference> resolvedAppPreferences;
    Map<String, ChimahonPreferenceSelectionOrigin> appPreferenceSelections;
    var mediaSelectionInitializationCanComplete = true;

    // Reconcile app preferences before filtering media. The final selector
    // rows and their safety origins are decided exactly once here.
    if (remote != null) {
      final preferenceResult = preferenceMerger.mergeWithSafetyPolicy(
        baseline: bootstrapAppPreferences
            ? remote.backupPreferences
            : deferred?.backupPreferences ?? const [],
        localBaseline: bootstrapAppPreferences
            ? rawLocalPreferenceIntent
            : localPreferenceBaseline,
        local: rawLocalPreferenceIntent,
        remote: remote.backupPreferences,
        locallyUnrepresentableKeys: unrepresentablePreferenceKeys,
      );
      resolvedAppPreferences = preferenceResult.preferences;
      appPreferenceSelections = {...preferenceResult.selections};
      if (currentLocalMediaSelectionUserSelected &&
          localPreferenceBaseline == null &&
          pendingLocal == null) {
        // A user choice made before this account's first sync is not a
        // constructor default. Give only these three controls local authority.
        resolvedAppPreferences = currentLocalMediaSelection
            .withBackedPreferences(
              BackupMihon(backupPreferences: resolvedAppPreferences),
            )
            .backupPreferences
            .toList(growable: false);
        for (final key in ChimahonMediaSyncSelection.preferenceKeys) {
          appPreferenceSelections[key] =
              ChimahonPreferenceSelectionOrigin.local;
        }
      }
      if (!currentLocalMediaSelectionUserSelected && pendingLocal == null) {
        resolvedAppPreferences = _forceRemoteSelectorRows(
          reconciled: resolvedAppPreferences,
          remote: remote.backupPreferences,
        );
        final remoteKeys = {
          for (final preference in remote.backupPreferences)
            if (ChimahonMediaSyncSelection.preferenceKeys.contains(
              preference.key,
            ))
              preference.key,
        };
        for (final key in ChimahonMediaSyncSelection.preferenceKeys) {
          appPreferenceSelections[key] = remoteKeys.contains(key)
              ? ChimahonPreferenceSelectionOrigin.remote
              : ChimahonPreferenceSelectionOrigin.deleted;
        }
      }
      if (pendingLocal != null) {
        final localByKey = {
          for (final preference in rawLocalPreferenceIntent)
            preference.key: preference,
        };
        for (final preference in pendingLocal.backupPreferences) {
          appPreferenceSelections[preference.key] =
              localByKey.containsKey(preference.key)
              ? ChimahonPreferenceSelectionOrigin.local
              : ChimahonPreferenceSelectionOrigin.deleted;
        }
        resolvedAppPreferences = _overlayPendingPreferenceIntent(
          reconciled: resolvedAppPreferences,
          localIntent: rawLocalPreferenceIntent,
          pending: pendingLocal.backupPreferences,
        );
      }
      mediaSelectionInitializationCanComplete =
          !ChimahonMediaSyncSelection.hasMalformedPreference(
            remote.backupPreferences,
          );
    } else {
      resolvedAppPreferences = [
        for (final preference in rawLocalPreferenceIntent)
          preference.deepCopy(),
      ];
      appPreferenceSelections = {
        for (final preference in resolvedAppPreferences)
          preference.key: ChimahonPreferenceSelectionOrigin.local,
      };
    }

    // Missing controls use Chimahon's true default. Present malformed controls
    // are ignored by Chimahon and retain the current local value for semantic
    // filtering. Their exact absence/bytes/order remain untouched.
    final mediaSelection = ChimahonMediaSyncSelection.forFiltering(
      resolvedAppPreferences,
      malformedFallback: currentLocalMediaSelection,
    );
    if (ChimahonMediaSyncSelection.hasMalformedPreference(
      resolvedAppPreferences,
    )) {
      mediaSelectionInitializationCanComplete = false;
    }
    final mediaSelectionResolvedFromRemote = ChimahonMediaSyncSelection
        .preferenceKeys
        .any(
          (key) =>
              appPreferenceSelections[key] ==
              ChimahonPreferenceSelectionOrigin.remote,
        );
    final projectedExported = mediaSelection.projectLocal(exported);
    final effectiveLocalTrackingDeletions = _filterTrackingDeletions(
      mediaSelection: mediaSelection,
      projectedLocal: projectedExported,
    );
    // [deferred] is the last successfully uploaded raw remote baseline, not
    // current local intent. Merging it into [exported] would resurrect records
    // which another client deleted. A pending manual restore is explicit local
    // intent and is the only cached payload allowed onto the local side.
    final local = pendingLocal == null
        ? projectedExported.toBuilder() as BackupMihon
        : merger.merge(
            local: projectedExported,
            remote: pendingLocal,
            localTrackingDeletions: effectiveLocalTrackingDeletions,
          );
    final localPreferenceIntent = resolvedAppPreferences;
    final localSourcePreferenceIntent = pendingLocal == null
        ? projectedExported.backupSourcePreferences.toList(growable: false)
        : const ChimahonPendingPreferenceIntent().mergeSource(
            pending: pendingLocal.backupSourcePreferences,
            projectedBaseline: pendingLocalSourcePreferenceBaseline,
            current: projectedExported.backupSourcePreferences,
          );
    local.backupPreferences
      ..clear()
      ..addAll(localPreferenceIntent);
    if (pendingLocal != null) {
      // The database projection is newer than the restore payload for settings
      // Mangatan understands, while pending-only keys still need to survive.
      local.backupSourcePreferences
        ..clear()
        ..addAll(localSourcePreferenceIntent);
    }
    var merged = remote == null
        ? local
        : merger.merge(
            local: local,
            remote: remote,
            localTrackingDeletions: effectiveLocalTrackingDeletions,
            // With no explicit restore pending, the local side is a lossy
            // database projection. Equal clocks mean no local edit, so retain
            // the exact remote representation. A selected manual restore keeps
            // local tie authority and is validated again below.
            remoteWinsProjectionTies: pendingLocal == null,
          );
    var preferenceSafetyPolicy = ChimahonPreferenceSafetyPolicy();
    if (remote != null) {
      merged.backupPreferences
        ..clear()
        ..addAll(resolvedAppPreferences);

      final bootstrapSourcePreferences =
          localSourcePreferenceStore != null &&
          localSourcePreferenceBaseline == null;
      final sourcePreferenceResult = sourcePreferenceMerger
          .mergeWithSafetyPolicy(
            baseline: bootstrapSourcePreferences
                ? remote.backupSourcePreferences
                : deferred?.backupSourcePreferences ?? const [],
            localBaseline: bootstrapSourcePreferences
                ? localSourcePreferenceIntent
                : localSourcePreferenceBaseline,
            local: localSourcePreferenceIntent,
            remote: remote.backupSourcePreferences,
          );
      final reconciledSourcePreferences = sourcePreferenceResult.preferences;
      final sourcePreferenceSelections = {...sourcePreferenceResult.selections};
      final sourceGroupEnvelopeSelections = {
        ...sourcePreferenceResult.sourceGroupEnvelopeSelections,
      };
      if (pendingLocal != null) {
        final localBySource = {
          for (final group in localSourcePreferenceIntent)
            group.sourceKey: group,
        };
        for (final pendingGroup in pendingLocal.backupSourcePreferences) {
          final localGroup = localBySource[pendingGroup.sourceKey];
          final localByKey = {
            for (final preference
                in localGroup?.prefs ?? const <BackupPreference>[])
              preference.key: preference,
          };
          for (final preference in pendingGroup.prefs) {
            final key = (
              sourceKey: pendingGroup.sourceKey,
              preferenceKey: preference.key,
            );
            sourcePreferenceSelections[key] =
                localByKey.containsKey(preference.key)
                ? ChimahonPreferenceSelectionOrigin.local
                : ChimahonPreferenceSelectionOrigin.deleted;
          }
          if (localGroup?.unknownFields.isNotEmpty == true) {
            sourceGroupEnvelopeSelections[pendingGroup.sourceKey] =
                ChimahonPreferenceSelectionOrigin.local;
          }
        }
      }
      merged.backupSourcePreferences
        ..clear()
        ..addAll(
          pendingLocal == null
              ? reconciledSourcePreferences
              : _overlayPendingSourcePreferenceIntent(
                  reconciled: reconciledSourcePreferences,
                  localIntent: localSourcePreferenceIntent,
                  pending: pendingLocal.backupSourcePreferences,
                ),
        );
      preferenceSafetyPolicy = ChimahonPreferenceSafetyPolicy(
        appSelections: appPreferenceSelections,
        sourceSelections: sourcePreferenceSelections,
        sourceGroupEnvelopeSelections: sourceGroupEnvelopeSelections,
      );
    } else {
      preferenceSafetyPolicy = ChimahonPreferenceSafetyPolicy(
        appSelections: appPreferenceSelections,
        sourceSelections: {
          for (final group in local.backupSourcePreferences)
            for (final preference in group.prefs)
              (sourceKey: group.sourceKey, preferenceKey: preference.key):
                  ChimahonPreferenceSelectionOrigin.local,
        },
        sourceGroupEnvelopeSelections: {
          for (final group in local.backupSourcePreferences)
            if (group.unknownFields.isNotEmpty)
              group.sourceKey: ChimahonPreferenceSelectionOrigin.local,
        },
      );
    }
    final ordinaryMerged = pendingLocal == null ? null : merged.deepCopy();
    if (pendingLocal != null) {
      merged = pendingRestoreAuthority.apply(
        pending: pendingLocal,
        localIntent: local,
        remote: remote,
        merged: merged,
        localTrackingDeletions: effectiveLocalTrackingDeletions,
      );
    }
    if (reconcileStarted != null) {
      metrics!.addElapsed(CrossDeviceSyncPhase.reconcile, reconcileStarted);
    }
    final proposedProtobufBytes = metrics == null
        ? merged.writeToBuffer()
        : metrics.measureSync(
            CrossDeviceSyncPhase.serialize,
            merged.writeToBuffer,
          );
    final canReuseCompleteRemoteBytes =
        metrics != null &&
        remoteSnapshot?.isCompleteRecovery == true &&
        remoteSnapshot!.revision?.isNotEmpty == true &&
        decodedRemote != null &&
        sameBytes(proposedProtobufBytes, decodedRemote.protobufBytes);
    final bytes = canReuseCompleteRemoteBytes
        ? remoteSnapshot.bytes
        : metrics == null
        ? codec.encodeProtobufBytes(
            proposedProtobufBytes,
            format: storage.wireFormat,
          )
        : metrics.measureSync(
            CrossDeviceSyncPhase.encode,
            () => codec.encodeProtobufBytes(
              proposedProtobufBytes,
              format: storage.wireFormat,
            ),
          );
    metrics
      ?..protobufBytes = proposedProtobufBytes.length
      ..uploadBytes = bytes.length;
    if (pendingLocal != null) {
      final uploaded = codec.decode(bytes).backup;
      if (!pendingRestoreAuthority.containsSelectedIntent(
        uploaded: uploaded,
        pending: pendingLocal,
        localIntent: local,
      )) {
        // Do not upload, and especially do not clear the pending restore, if a
        // future schema/merger change accidentally drops selected restore data.
        final failure =
            pendingRestoreAuthority.selectedIntentFailure(
              uploaded: uploaded,
              pending: pendingLocal,
              localIntent: local,
            ) ??
            'restore_selected_intent_mismatch';
        throw StateError(
          'The encoded Chimahon sync payload does not contain the selected '
          'manual restore intent ($failure).',
        );
      }
      final failure = pendingRestoreAuthority.transitionFailure(
        uploaded: uploaded,
        pending: pendingLocal,
        localIntent: local,
        ordinaryMerged: ordinaryMerged!,
        remote: remote,
        localTrackingDeletions: effectiveLocalTrackingDeletions,
      );
      if (failure != null) {
        throw StateError('Chimahon restore validation failed: $failure.');
      }
    }
    return _PreparedSyncPayload(
      exported: exported,
      projectedExported: projectedExported,
      effectiveLocalIntent: local,
      localTrackingDeletions: effectiveLocalTrackingDeletions,
      mediaSelection: mediaSelection,
      mediaSelectionResolvedFromRemote: mediaSelectionResolvedFromRemote,
      initialMediaSelection: currentLocalMediaSelection,
      initialMediaSelectionInitialized: currentLocalMediaSelectionInitialized,
      initialMediaSelectionGeneration: currentLocalMediaSelectionGeneration,
      initialMediaSelectionState: currentLocalMediaSelectionState,
      mediaSelectionInitializationCanComplete:
          mediaSelectionInitializationCanComplete,
      preferenceSafetyPolicy: preferenceSafetyPolicy,
      unrepresentablePreferenceKeys: unrepresentablePreferenceKeys,
      pendingLocal: pendingLocal,
      localPreferenceStore: localPreferenceStore,
      localSourcePreferenceStore: localSourcePreferenceStore,
      remoteSnapshot: remoteSnapshot,
      remoteProtobufBytes: decodedRemote?.protobufBytes,
      remote: remote,
      merged: merged,
      proposedProtobufBytes: proposedProtobufBytes,
      ordinaryMerged: ordinaryMerged,
      bytes: bytes,
    );
  }

  Set<ChimahonTrackingDeletionKey> _filterTrackingDeletions({
    required ChimahonMediaSyncSelection mediaSelection,
    required BackupMihon projectedLocal,
  }) {
    if (mediaSelection.manga && mediaSelection.anime) {
      return localTrackingDeletions;
    }
    final retainedParents = <({int source, String url})>{
      for (final manga in projectedLocal.backupManga)
        (source: manga.source.toInt(), url: manga.url),
      for (final anime in projectedLocal.backupAnime)
        (source: anime.source.toInt(), url: anime.url),
    };
    return Set.unmodifiable(
      localTrackingDeletions.where(
        (deletion) => retainedParents.contains((
          source: deletion.source,
          url: deletion.url,
        )),
      ),
    );
  }

  List<BackupPreference> _overlayPendingPreferenceIntent({
    required Iterable<BackupPreference> reconciled,
    required Iterable<BackupPreference> localIntent,
    required Iterable<BackupPreference> pending,
  }) {
    final reconciledOrder = [
      for (final preference in reconciled) preference.key,
    ];
    final resultByKey = {
      for (final preference in reconciled)
        preference.key: preference.deepCopy(),
    };
    final localByKey = {
      for (final preference in localIntent) preference.key: preference,
    };
    for (final pendingPreference in pending) {
      final selected = localByKey[pendingPreference.key];
      if (selected == null) {
        resultByKey.remove(pendingPreference.key);
        continue;
      }
      final fallback = resultByKey[pendingPreference.key];
      resultByKey[pendingPreference.key] = fallback == null
          ? selected.deepCopy()
          : _selectedOverFallback(selected, fallback);
    }
    final keys = _anchoredKeys(reconciledOrder, resultByKey.keys);
    return [for (final key in keys) resultByKey[key]!];
  }

  List<BackupPreference> _forceRemoteSelectorRows({
    required Iterable<BackupPreference> reconciled,
    required Iterable<BackupPreference> remote,
  }) {
    final reconciledNonSelectorsByKey = <String, List<BackupPreference>>{};
    for (final preference in reconciled) {
      if (ChimahonMediaSyncSelection.preferenceKeys.contains(preference.key)) {
        continue;
      }
      reconciledNonSelectorsByKey
          .putIfAbsent(preference.key, () => [])
          .add(preference);
    }
    final emittedNonSelectorKeys = <String>{};
    final result = <BackupPreference>[];
    for (final remotePreference in remote) {
      if (ChimahonMediaSyncSelection.preferenceKeys.contains(
        remotePreference.key,
      )) {
        result.add(remotePreference.deepCopy());
        continue;
      }
      if (!emittedNonSelectorKeys.add(remotePreference.key)) continue;
      final reconciledRows =
          reconciledNonSelectorsByKey[remotePreference.key] ??
          const <BackupPreference>[];
      result.addAll([
        for (final preference in reconciledRows) preference.deepCopy(),
      ]);
    }
    for (final preference in reconciled) {
      if (ChimahonMediaSyncSelection.preferenceKeys.contains(preference.key) ||
          !emittedNonSelectorKeys.add(preference.key)) {
        continue;
      }
      result.addAll([
        for (final reconciledRow
            in reconciledNonSelectorsByKey[preference.key]!)
          reconciledRow.deepCopy(),
      ]);
    }
    return result;
  }

  List<BackupSourcePreferences> _overlayPendingSourcePreferenceIntent({
    required Iterable<BackupSourcePreferences> reconciled,
    required Iterable<BackupSourcePreferences> localIntent,
    required Iterable<BackupSourcePreferences> pending,
  }) {
    final reconciledOrder = [for (final group in reconciled) group.sourceKey];
    final resultBySource = {
      for (final group in reconciled) group.sourceKey: group.deepCopy(),
    };
    final localBySource = {
      for (final group in localIntent) group.sourceKey: group,
    };
    for (final pendingGroup in pending) {
      final localGroup = localBySource[pendingGroup.sourceKey];
      final existing = resultBySource[pendingGroup.sourceKey];
      if (localGroup == null) {
        if (existing == null) continue;
        final pendingKeys = {
          for (final preference in pendingGroup.prefs) preference.key,
        };
        existing.prefs.removeWhere(
          (preference) => pendingKeys.contains(preference.key),
        );
        if (existing.prefs.isEmpty && existing.unknownFields.isEmpty) {
          resultBySource.remove(pendingGroup.sourceKey);
        }
        continue;
      }
      if (existing == null) {
        final localCopy = localGroup.deepCopy();
        localCopy.prefs.sort((left, right) => left.key.compareTo(right.key));
        resultBySource[pendingGroup.sourceKey] = localCopy;
        continue;
      }
      final existingPreferenceOrder = [
        for (final preference in existing.prefs) preference.key,
      ];
      final localByKey = {
        for (final preference in localGroup.prefs) preference.key: preference,
      };
      final preferencesByKey = {
        for (final preference in existing.prefs)
          preference.key: preference.deepCopy(),
      };
      for (final pendingPreference in pendingGroup.prefs) {
        final selected = localByKey[pendingPreference.key];
        if (selected == null) {
          preferencesByKey.remove(pendingPreference.key);
          continue;
        }
        final fallback = preferencesByKey[pendingPreference.key];
        preferencesByKey[pendingPreference.key] = fallback == null
            ? selected.deepCopy()
            : _selectedOverFallback(selected, fallback);
      }
      final preferenceKeys = _anchoredKeys(
        existingPreferenceOrder,
        preferencesByKey.keys,
      );
      existing.prefs
        ..clear()
        ..addAll([for (final key in preferenceKeys) preferencesByKey[key]!]);
      existing.unknownFields.mergeFromUnknownFieldSet(localGroup.unknownFields);
      if (existing.prefs.isEmpty && existing.unknownFields.isEmpty) {
        resultBySource.remove(pendingGroup.sourceKey);
      }
    }
    final sourceKeys = _anchoredKeys(reconciledOrder, resultBySource.keys);
    return [for (final key in sourceKeys) resultBySource[key]!];
  }

  List<String> _anchoredKeys(
    Iterable<String> anchor,
    Iterable<String> retained,
  ) {
    final retainedSet = retained.toSet();
    final seen = <String>{};
    final result = <String>[];
    for (final key in anchor) {
      if (retainedSet.contains(key) && seen.add(key)) result.add(key);
    }
    final additions = retainedSet.where((key) => !seen.contains(key)).toList()
      ..sort();
    return [...result, ...additions];
  }

  T _selectedOverFallback<T extends GeneratedMessage>(T selected, T fallback) {
    final result = selected.deepCopy()..unknownFields.clear();
    result
      ..mergeUnknownFields(fallback.unknownFields)
      ..mergeUnknownFields(selected.unknownFields);
    if (result is BackupPreference &&
        selected is BackupPreference &&
        fallback is BackupPreference &&
        selected.hasValue() &&
        fallback.hasValue()) {
      result.value = _selectedOverFallback(selected.value, fallback.value);
    }
    return result;
  }

  bool _sameBackup(BackupMihon left, BackupMihon right) {
    return left == right;
  }
}

class _PreparedSyncPayload {
  const _PreparedSyncPayload({
    required this.exported,
    required this.projectedExported,
    required this.effectiveLocalIntent,
    required this.localTrackingDeletions,
    required this.mediaSelection,
    required this.mediaSelectionResolvedFromRemote,
    required this.initialMediaSelection,
    required this.initialMediaSelectionInitialized,
    required this.initialMediaSelectionGeneration,
    required this.initialMediaSelectionState,
    required this.mediaSelectionInitializationCanComplete,
    required this.preferenceSafetyPolicy,
    required this.unrepresentablePreferenceKeys,
    required this.pendingLocal,
    required this.localPreferenceStore,
    required this.localSourcePreferenceStore,
    required this.remoteSnapshot,
    required this.remoteProtobufBytes,
    required this.remote,
    required this.merged,
    required this.ordinaryMerged,
    required this.proposedProtobufBytes,
    required this.bytes,
  });

  final BackupMihon exported;
  final BackupMihon projectedExported;
  final BackupMihon effectiveLocalIntent;
  final Set<ChimahonTrackingDeletionKey> localTrackingDeletions;
  final ChimahonMediaSyncSelection mediaSelection;
  final bool mediaSelectionResolvedFromRemote;
  final ChimahonMediaSyncSelection initialMediaSelection;
  final bool initialMediaSelectionInitialized;
  final int initialMediaSelectionGeneration;
  final ChimahonMediaSyncSelectionState initialMediaSelectionState;
  final bool mediaSelectionInitializationCanComplete;
  final ChimahonPreferenceSafetyPolicy preferenceSafetyPolicy;
  final Set<String> unrepresentablePreferenceKeys;
  final BackupMihon? pendingLocal;
  final ChimahonLocalPreferenceBaselineStore? localPreferenceStore;
  final ChimahonLocalSourcePreferenceBaselineStore? localSourcePreferenceStore;
  final RemoteSyncSnapshot? remoteSnapshot;
  final Uint8List? remoteProtobufBytes;
  final BackupMihon? remote;
  final BackupMihon merged;
  final BackupMihon? ordinaryMerged;
  final Uint8List proposedProtobufBytes;
  final Uint8List bytes;
}

class _SyncMetricsRecorder {
  _SyncMetricsRecorder(Duration initialExportDuration)
    : _initialMicroseconds = initialExportDuration.inMicroseconds {
    if (_initialMicroseconds > 0) {
      _phaseMicroseconds[CrossDeviceSyncPhase.exportLocal] =
          _initialMicroseconds;
    }
    _clock.start();
  }

  final Stopwatch _clock = Stopwatch();
  final Map<CrossDeviceSyncPhase, int> _phaseMicroseconds = {};
  final int _initialMicroseconds;
  int attempts = 0;
  int conflicts = 0;
  int remoteBytes = 0;
  int protobufBytes = 0;
  int uploadBytes = 0;
  bool uploaded = false;
  bool skippedUpload = false;
  bool imported = false;

  int get elapsedMicroseconds => _clock.elapsedMicroseconds;

  T measureSync<T>(CrossDeviceSyncPhase phase, T Function() action) {
    final started = elapsedMicroseconds;
    try {
      return action();
    } finally {
      addElapsed(phase, started);
    }
  }

  Future<T> measureAsync<T>(
    CrossDeviceSyncPhase phase,
    Future<T> Function() action,
  ) async {
    final started = elapsedMicroseconds;
    try {
      return await action();
    } finally {
      addElapsed(phase, started);
    }
  }

  void addElapsed(CrossDeviceSyncPhase phase, int startedMicroseconds) {
    _phaseMicroseconds.update(
      phase,
      (value) => value + elapsedMicroseconds - startedMicroseconds,
      ifAbsent: () => elapsedMicroseconds - startedMicroseconds,
    );
  }

  CrossDeviceSyncMetrics snapshot() => CrossDeviceSyncMetrics(
    total: Duration(microseconds: _initialMicroseconds + elapsedMicroseconds),
    phases: {
      for (final entry in _phaseMicroseconds.entries)
        entry.key: Duration(microseconds: entry.value),
    },
    attempts: attempts,
    conflicts: conflicts,
    remoteBytes: remoteBytes,
    protobufBytes: protobufBytes,
    uploadBytes: uploadBytes,
    uploaded: uploaded,
    skippedUpload: skippedUpload,
    imported: imported,
  );
}
