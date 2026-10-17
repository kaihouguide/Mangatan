import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/eval/mihon/bridge_protocol.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupPreference.pb.dart';
import 'package:mangayomi/services/fetch_sources_list.dart';
import 'package:mangayomi/services/http/m_client.dart';
import 'package:mangayomi/services/m_extension_server.dart';
import 'package:mangayomi/services/mihon_source_preferences.dart';
import 'package:mangayomi/services/sync/chimahon_source_preferences_adapter.dart';
import 'package:mangayomi/utils/log/logger.dart';
import 'package:mangayomi/repositories/db_write_queue.dart';

final refreshInstalledMihonFactorySourcesProvider =
    FutureProvider<MihonFactoryRefreshResult>(
      refreshInstalledMihonFactorySources,
    );

final _successfullyRefreshedFactoryGroups = Expando<Set<String>>();

class MihonFactoryReconcileResult {
  const MihonFactoryReconcileResult({
    this.sourcesByNativeId = const {},
    this.created = 0,
    this.updated = 0,
    this.unavailable = 0,
    this.rebound = 0,
    this.detached = 0,
  });

  final Map<String, Source> sourcesByNativeId;
  final int created;
  final int updated;
  final int unavailable;
  final int rebound;
  final int detached;

  MihonFactoryReconcileResult operator +(MihonFactoryReconcileResult other) =>
      MihonFactoryReconcileResult(
        sourcesByNativeId: {...sourcesByNativeId, ...other.sourcesByNativeId},
        created: created + other.created,
        updated: updated + other.updated,
        unavailable: unavailable + other.unavailable,
        rebound: rebound + other.rebound,
        detached: detached + other.detached,
      );
}

class MihonFactoryRefreshResult {
  const MihonFactoryRefreshResult({
    this.groupsReconciled = 0,
    this.reconciliation = const MihonFactoryReconcileResult(),
    this.unresolvedGroups = 0,
  });

  final int groupsReconciled;
  final MihonFactoryReconcileResult reconciliation;
  final int unresolvedGroups;
}

/// Refreshes the children exposed by installed Mihon source factories.
///
/// Factory extensions can derive their children from preferences. Jellyfin,
/// for example, exposes one source per configured server/library. A Chimahon
/// restore updates those preferences without visiting the extension screen,
/// so discovery must also run as part of restore before native source IDs can
/// be rebound to local [Source] rows.
Future<MihonFactoryRefreshResult> refreshInstalledMihonFactorySources(
  Ref ref, {
  Iterable<BackupSourcePreferences> remoteSourcePreferences = const [],
  bool replacePresentPreferences = false,
  Set<String>? requiredNativeSourceIds,
  Set<int> changedPreferenceSourceIds = const {},
}) async {
  final totalWatch = Stopwatch()..start();
  final candidates = isar.sources
      .where()
      .findAllSync()
      .where(
        (source) =>
            source.sourceCodeLanguage == SourceCodeLanguage.mihon &&
            source.isAdded == true &&
            source.sourceCode?.isNotEmpty == true &&
            mihonSourceMetadata(source) != null,
      )
      .toList(growable: false);
  final groups = <String, List<Source>>{};
  for (final source in candidates) {
    groups.putIfAbsent(mihonExtensionGroupKey(source), () => []).add(source);
  }
  final refreshedGroups = _successfullyRefreshedFactoryGroups[isar] ??=
      <String>{};
  var requiredIds = const <String>{};
  var knownRequiredIds = const <String>{};
  if (requiredNativeSourceIds != null) {
    requiredIds = {
      ...requiredNativeSourceIds,
      for (final preferences in remoteSourcePreferences)
        if (preferences.sourceKey.startsWith('source_'))
          preferences.sourceKey.substring('source_'.length),
    };
    knownRequiredIds = <String>{};
    final changedPreferenceGroups = <String>{};
    for (final source in candidates) {
      final nativeId = mihonSourceMetadata(source)?.sourceId;
      if (nativeId != null && requiredIds.contains(nativeId)) {
        knownRequiredIds.add(nativeId);
      }
      if (source.id case final localId?
          when changedPreferenceSourceIds.contains(localId)) {
        changedPreferenceGroups.add(mihonExtensionGroupKey(source));
      }
    }
    final hasUnknownRequiredIds = knownRequiredIds.length != requiredIds.length;
    // Changed values need their owning factory refreshed so the JVM receives
    // them and preference-derived children are reconciled. An unknown native
    // ID can belong to any installed factory, but a group already queried for
    // the current installed source code cannot reveal it on every later sync.
    groups.removeWhere(
      (key, sources) =>
          !changedPreferenceGroups.contains(key) &&
          (!hasUnknownRequiredIds ||
              refreshedGroups.contains(_factoryRefreshFingerprint(sources))),
    );
  }

  final client = MClient.init(reqcopyWith: {'useDartHttpClient': true});
  var reconciledGroups = 0;
  var unresolvedGroups = 0;
  var aggregate = const MihonFactoryReconcileResult();
  var passes = 0;
  var bridgeMicroseconds = 0;
  var preferenceMicroseconds = 0;
  var descriptorMicroseconds = 0;
  var reconciliationMicroseconds = 0;
  const sourcePreferencesAdapter = ChimahonSourcePreferencesAdapter();

  Future<void> refreshGroup(List<Source> sources) async {
    sources.sort((left, right) {
      final active =
          (right.isActive == true ? 1 : 0) - (left.isActive == true ? 1 : 0);
      if (active != 0) return active;
      return (left.id ?? 0).compareTo(right.id ?? 0);
    });
    var template = sources.first;
    var groupReconciled = false;
    var groupFailed = false;
    try {
      final bridgeWatch = Stopwatch()..start();
      final proxyServer = await prepareMihonBridge(ref, template);
      bridgeWatch.stop();
      bridgeMicroseconds += bridgeWatch.elapsedMicroseconds;
      for (var pass = 0; pass < 3; pass++) {
        passes++;
        final currentGroup =
            (await isar.sources
                    .filter()
                    .sourceCodeUrlEqualTo(template.sourceCodeUrl)
                    .findAll())
                .where(
                  (source) => belongsToSameMihonExtension(template, source),
                )
                .toList();
        if (currentGroup.isEmpty) break;
        template = currentGroup.firstWhere(
          (source) => source.id == template.id,
          orElse: () => currentGroup.first,
        );

        // New factory children have no local schema yet. Query it first so a
        // deferred Chimahon store can be decoded and persisted for that child.
        final preferenceWatch = Stopwatch()..start();
        for (final source in currentGroup) {
          final persisted = loadPersistedMihonSourcePreferences(isar, source);
          final fresh = await fetchPreferencesDalvik(
            client,
            source,
            proxyServer,
            preferences: persisted,
            preferenceApplyMode: replacePresentPreferences
                ? MihonPreferenceApplyMode.replacePresent
                : MihonPreferenceApplyMode.bootstrap,
          );
          if (fresh == null) continue;
          final merged = mergeMihonPreferenceValues(fresh, persisted);
          source.preferenceList = jsonEncode(
            merged.map((preference) => preference.toJson()).toList(),
          );
          await dbWriteQueue.run(
            () => isar.writeTxn(() => isar.sources.put(source)),
          );
        }
        if (remoteSourcePreferences.isNotEmpty) {
          await sourcePreferencesAdapter.importIntoAsync(
            database: isar,
            sourcePreferences: remoteSourcePreferences,
            candidateSources: currentGroup,
          );
        }
        preferenceWatch.stop();
        preferenceMicroseconds += preferenceWatch.elapsedMicroseconds;

        List<MihonSourceDescriptor>? descriptors;
        final descriptorWatch = Stopwatch()..start();
        for (final source in currentGroup) {
          final refreshed = await fetchMihonSourceDescriptors(
            client,
            source,
            proxyServer,
            preferences: loadPersistedMihonSourcePreferences(isar, source),
            preferenceApplyMode: replacePresentPreferences
                ? MihonPreferenceApplyMode.replacePresent
                : MihonPreferenceApplyMode.bootstrap,
          );
          if (refreshed != null && refreshed.isNotEmpty) {
            descriptors = refreshed;
          }
        }
        descriptorWatch.stop();
        descriptorMicroseconds += descriptorWatch.elapsedMicroseconds;
        if (descriptors == null || descriptors.isEmpty) break;
        final descriptorIds = descriptors.map((item) => item.id).toSet();
        final currentDescriptorIds = {
          for (final source in currentGroup)
            if (mihonSourceMetadata(source) case final metadata?
                when metadata.factoryAvailable)
              metadata.sourceId,
        };
        final reconciliationWatch = Stopwatch()..start();
        aggregate += await reconcileMihonFactorySources(template, descriptors);
        reconciliationWatch.stop();
        reconciliationMicroseconds += reconciliationWatch.elapsedMicroseconds;
        groupReconciled = true;
        if (currentDescriptorIds.length == descriptorIds.length &&
            currentDescriptorIds.containsAll(descriptorIds)) {
          break;
        }
      }
    } on Object catch (error) {
      groupFailed = true;
      AppLogger.log(
        'Mihon factory refresh failed for '
        '${mihonExtensionGroupKey(template)}: $error',
        logLevel: LogLevel.warning,
      );
    }
    if (groupReconciled) {
      reconciledGroups++;
    } else {
      unresolvedGroups++;
    }
    if (groupFailed && groupReconciled) unresolvedGroups++;
    if (!groupFailed && groupReconciled) {
      refreshedGroups.add(_factoryRefreshFingerprint(sources));
    }
  }

  await _forEachConcurrent(
    groups.values.toList(growable: false),
    concurrency: 8,
    action: refreshGroup,
  );
  totalWatch.stop();
  AppLogger.log(
    'Mihon factory refresh performance: '
    'total=${_milliseconds(totalWatch.elapsedMicroseconds)}ms '
    'groups=${groups.length} passes=$passes concurrency=8 '
    'requiredIds=${requiredIds.length} '
    'knownRequiredIds=${knownRequiredIds.length} '
    'changedPreferenceSources=${changedPreferenceSourceIds.length} '
    'bridgeWork=${_milliseconds(bridgeMicroseconds)}ms '
    'preferenceWork=${_milliseconds(preferenceMicroseconds)}ms '
    'descriptorWork=${_milliseconds(descriptorMicroseconds)}ms '
    'reconciliationWork=${_milliseconds(reconciliationMicroseconds)}ms',
    logLevel: LogLevel.debug,
  );
  return MihonFactoryRefreshResult(
    groupsReconciled: reconciledGroups,
    reconciliation: aggregate,
    unresolvedGroups: unresolvedGroups,
  );
}

Future<void> _forEachConcurrent<T>(
  List<T> values, {
  required int concurrency,
  required Future<void> Function(T value) action,
}) async {
  var next = 0;
  Future<void> worker() async {
    while (next < values.length) {
      final index = next++;
      await action(values[index]);
    }
  }

  await Future.wait([
    for (
      var workerIndex = 0;
      workerIndex < concurrency && workerIndex < values.length;
      workerIndex++
    )
      worker(),
  ]);
}

String _milliseconds(int microseconds) =>
    (microseconds / Duration.microsecondsPerMillisecond).toStringAsFixed(2);

String _factoryRefreshFingerprint(List<Source> sources) {
  final template = sources.first;
  final sourceCode = template.sourceCode ?? '';
  return '${mihonExtensionGroupKey(template)}\u0000'
      '${sourceCode.length}\u0000${sourceCode.hashCode}';
}

Future<MihonFactoryReconcileResult> reconcileMihonFactorySources(
  Source template,
  List<MihonSourceDescriptor> descriptors, {
  Future<void> Function()? beforeReconciliationWrite,
}) async {
  if (template.sourceCodeLanguage != SourceCodeLanguage.mihon ||
      descriptors.isEmpty) {
    return const MihonFactoryReconcileResult();
  }

  final packageName = mihonSourceMetadata(template)?.packageName ?? '';
  final extensionName = mihonSourceMetadata(template)?.extensionName;
  final packageLang = mihonSourceMetadata(template)?.packageLang;
  final group = await isar.sources
      .filter()
      .sourceCodeUrlEqualTo(template.sourceCodeUrl)
      .findAll();
  final groupSources = group
      .where((source) => belongsToSameMihonExtension(template, source))
      .toList();
  final groupSourcesById = <int, Source>{
    for (final source in groupSources)
      if (source.id != null) source.id!: source,
  };
  final groupSourceIds = groupSourcesById.keys.toSet();
  final byNativeId = <String, Source>{};
  for (final source in groupSources) {
    final metadata = mihonSourceMetadata(source);
    if (metadata != null) byNativeId[metadata.sourceId] = source;
  }
  final descriptorIds = descriptors.map((descriptor) => descriptor.id).toSet();
  final now = DateTime.now().millisecondsSinceEpoch;
  final updates = <Source>[];
  var created = 0;
  var updated = 0;
  var unavailable = 0;

  for (final descriptor in descriptors) {
    final existing = byNativeId[descriptor.id];
    if (existing != null) {
      final metadata = mihonSourceMetadata(existing);
      existing
        ..name = descriptor.name
        ..lang = descriptor.lang
        ..baseUrl = descriptor.baseUrl
        ..isActive = metadata?.factoryAvailable == false
            ? true
            : existing.isActive
        ..additionalParams = encodeMihonSourceMetadata(
          sourceId: descriptor.id,
          packageName: packageName,
          extensionName: extensionName,
          packageLang: packageLang,
        )
        ..isObsolete = false
        ..updatedAt = now;
      updates.add(existing);
      updated++;
      continue;
    }

    updates.add(
      Source()
        ..id = mihonLocalSourceId(descriptor.id)
        ..name = descriptor.name
        ..baseUrl = descriptor.baseUrl
        ..lang = descriptor.lang
        ..isActive = true
        ..isAdded = true
        ..isPinned = false
        ..isNsfw = template.isNsfw
        ..sourceCode = template.sourceCode
        ..sourceCodeUrl = template.sourceCodeUrl
        ..typeSource = template.typeSource
        ..iconUrl = template.iconUrl
        ..isFullData = template.isFullData
        ..hasCloudflare = template.hasCloudflare
        ..lastUsed = false
        ..dateFormat = template.dateFormat
        ..dateFormatLocale = template.dateFormatLocale
        ..apiUrl = template.apiUrl
        ..version = template.version
        ..versionLast = template.versionLast
        ..headers = template.headers
        ..supportLatest = template.supportLatest
        ..filterList = template.filterList
        ..preferenceList = null
        ..itemType = template.itemType
        ..appMinVerReq = template.appMinVerReq
        ..additionalParams = encodeMihonSourceMetadata(
          sourceId: descriptor.id,
          packageName: packageName,
          extensionName: extensionName,
          packageLang: packageLang,
        )
        ..isLocal = false
        ..isObsolete = false
        ..sourceCodeLanguage = SourceCodeLanguage.mihon
        ..notes = template.notes
        ..repo = template.repo
        ..updatedAt = now,
    );
    created++;
  }

  for (final source in groupSources) {
    final nativeId = mihonSourceMetadata(source)?.sourceId;
    if (nativeId != null && !descriptorIds.contains(nativeId)) {
      final metadata = mihonSourceMetadata(source);
      updates.add(
        source
          ..isActive = false
          ..additionalParams = encodeMihonSourceMetadata(
            sourceId: nativeId,
            packageName: metadata?.packageName ?? packageName,
            factoryAvailable: false,
            extensionName: metadata?.extensionName ?? extensionName,
            packageLang: metadata?.packageLang ?? packageLang,
          )
          ..updatedAt = now,
      );
      unavailable++;
    }
  }

  final reconciledByNativeId = <String, Source>{
    for (final source in updates)
      if (mihonSourceMetadata(source) case final metadata?
          when metadata.factoryAvailable)
        metadata.sourceId: source,
  };
  final mangaUpdates =
      <
        ({
          int id,
          int? sourceId,
          String? source,
          String? lang,
          String? mihonSourceId,
        })
      >[];
  for (final manga in await isar.mangas.where().findAll()) {
    final mangaId = manga.id;
    if (mangaId == null) continue;
    var nativeId = manga.mihonSourceId;
    var sourceId = manga.sourceId;
    var source = manga.source;
    var lang = manga.lang;
    var changed = false;
    if (nativeId == null && sourceId != null) {
      final priorSource = groupSourcesById[sourceId];
      nativeId = priorSource == null
          ? null
          : mihonSourceMetadata(priorSource)?.sourceId;
      changed = nativeId != null;
    }
    final target = nativeId == null ? null : reconciledByNativeId[nativeId];
    final priorSourceBelongsToGroup = groupSourceIds.contains(sourceId);
    if (target == null || manga.itemType != target.itemType) {
      if (nativeId != null && priorSourceBelongsToGroup && sourceId != null) {
        sourceId = null;
        changed = true;
      }
    } else {
      changed =
          changed ||
          sourceId != target.id ||
          source != target.name ||
          lang != target.lang;
      sourceId = target.id;
      source = target.name;
      lang = target.lang;
    }
    if (changed) {
      mangaUpdates.add((
        id: mangaId,
        sourceId: sourceId,
        source: source,
        lang: lang,
        mihonSourceId: nativeId,
      ));
    }
  }

  await beforeReconciliationWrite?.call();
  await dbWriteQueue.run(
    () => isar.writeTxn(() async {
      await isar.sources.putAll(updates);
      if (mangaUpdates.isEmpty) return;
      final currentMangas = await isar.mangas.getAll(
        mangaUpdates.map((update) => update.id).toList(growable: false),
      );
      final rebinding = <Manga>[];
      for (var index = 0; index < mangaUpdates.length; index++) {
        final manga = currentMangas[index];
        if (manga == null) continue;
        final update = mangaUpdates[index];
        manga
          ..sourceId = update.sourceId
          ..source = update.source
          ..lang = update.lang
          ..mihonSourceId = update.mihonSourceId;
        rebinding.add(manga);
      }
      if (rebinding.isNotEmpty) await isar.mangas.putAll(rebinding);
    }),
  );
  final detached = mangaUpdates
      .where(
        (update) => update.sourceId == null && update.mihonSourceId != null,
      )
      .length;
  final rebound = mangaUpdates.length - detached;
  return MihonFactoryReconcileResult(
    sourcesByNativeId: Map.unmodifiable(reconciledByNativeId),
    created: created,
    updated: updated,
    unavailable: unavailable,
    rebound: rebound,
    detached: detached,
  );
}
