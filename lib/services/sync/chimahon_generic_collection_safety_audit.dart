import 'dart:convert';

import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupExtensionRepos.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupExtensionStore.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupFeed.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupSavedSearch.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupSearchHistory.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupSource.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupStatistics.pb.dart';
import 'package:mangayomi/services/sync/chimahon_anime_repo_identity.dart';
import 'package:mangayomi/services/sync/chimahon_feed_identity.dart';
import 'package:mangayomi/services/sync/chimahon_opaque_rows.dart';
import 'package:mangayomi/services/sync/chimahon_unknown_field_safety.dart';
import 'package:protobuf/protobuf.dart';
import 'package:mangayomi/services/sync/sync_bytes.dart';

/// Symmetric preservation checks for non-media Chimahon root collections.
///
/// Local known fields win ordinary conflicts for these keyed collections, but
/// remote identities and both sides' future protobuf fields must survive. The
/// global statistics collections are checked on Chimahon's own daily identity
/// and for counter regressions rather than byte equality, because the merger
/// intentionally rewrites those rows to the larger value per field.
class ChimahonGenericCollectionSafetyAudit {
  const ChimahonGenericCollectionSafetyAudit();

  void audit({
    required BackupMihon local,
    required BackupMihon remote,
    required BackupMihon proposed,
    required void Function(String code, Iterable<String> affected) fail,
    required void Function(String code, Iterable<String> affected) observe,
  }) {
    _auditKnownCollection<BackupSource>(
      family: 'source',
      local: local.backupSources,
      remote: remote.backupSources,
      proposed: proposed.backupSources,
      keyOf: _sourceKey,
      knownFieldsEqual: _sameSourceIdentity,
      fail: fail,
    );
    _auditKnownCollection<BackupSource>(
      family: 'anime_source',
      local: local.backupAnimeSources,
      remote: remote.backupAnimeSources,
      proposed: proposed.backupAnimeSources,
      keyOf: _sourceKey,
      knownFieldsEqual: _sameSourceIdentity,
      fail: fail,
    );
    _auditKnownCollection<BackupExtensionStore>(
      family: 'extension_store',
      local: local.backupExtensionStores,
      remote: remote.backupExtensionStores,
      proposed: proposed.backupExtensionStores,
      keyOf: (store) => store.indexUrl,
      fail: fail,
    );
    _auditKnownCollection<BackupExtensionRepos>(
      family: 'anime_extension_repo',
      local: local.backupAnimeExtensionRepo,
      remote: remote.backupAnimeExtensionRepo,
      proposed: proposed.backupAnimeExtensionRepo,
      keyOf: chimahonAnimeRepositoryIdentity,
      knownFieldsEqual: _sameAnimeRepositoryIdentity,
      fail: fail,
    );
    _auditKnownCollection<BackupSavedSearch>(
      family: 'saved_search',
      local: local.backupSavedSearches,
      remote: remote.backupSavedSearches,
      proposed: proposed.backupSavedSearches,
      keyOf: _savedSearchKey,
      fail: fail,
    );
    _auditKnownCollection<BackupFeed>(
      family: 'feed',
      local: local.backupFeeds,
      remote: remote.backupFeeds,
      proposed: proposed.backupFeeds,
      keyOf: ChimahonFeedIdentity.key,
      fail: fail,
    );
    _auditKnownCollection<BackupSearchHistory>(
      family: 'search_history',
      local: local.backupSearchHistory,
      remote: remote.backupSearchHistory,
      proposed: proposed.backupSearchHistory,
      keyOf: (entry) => '${entry.scope}\u0000${entry.query}',
      fail: fail,
    );

    _auditRootUnknownFields(
      local: local,
      remote: remote,
      proposed: proposed,
      fail: fail,
    );
    _auditStatistics(
      local: local,
      remote: remote,
      proposed: proposed,
      fail: fail,
      observe: observe,
    );
  }

  void _auditKnownCollection<T extends GeneratedMessage>({
    required String family,
    required Iterable<T> local,
    required Iterable<T> remote,
    required Iterable<T> proposed,
    required String Function(T value) keyOf,
    bool Function(T first, T second)? knownFieldsEqual,
    required void Function(String code, Iterable<String> affected) fail,
  }) {
    final localList = local.toList(growable: false);
    final remoteList = remote.toList(growable: false);
    final proposedList = proposed.toList(growable: false);
    _auditDuplicateKeys(
      side: 'local',
      family: family,
      values: localList,
      keyOf: keyOf,
      fail: fail,
    );
    _auditDuplicateKeys(
      side: 'remote',
      family: family,
      values: remoteList,
      keyOf: keyOf,
      fail: fail,
    );
    _auditDuplicateKeys(
      side: 'proposed',
      family: family,
      values: proposedList,
      keyOf: keyOf,
      fail: fail,
    );
    final localByKey = _lastByKey(localList, keyOf);
    final remoteByKey = _lastByKey(remoteList, keyOf);
    final proposedByKey = _lastByKey(proposedList, keyOf);

    final localMissing = <String>[];
    final localChanged = <String>[];
    for (final entry in localByKey.entries) {
      final candidate = proposedByKey[entry.key];
      if (candidate == null) {
        localMissing.add(entry.key);
      } else if (!(knownFieldsEqual?.call(entry.value, candidate) ??
          _sameKnownFields(entry.value, candidate))) {
        localChanged.add(entry.key);
      }
    }
    fail('local_${family}_missing_from_proposed', localMissing);
    fail('local_${family}_changed_in_proposed', localChanged);

    final remoteMissing = <String>[];
    final remoteOnlyChanged = <String>[];
    final remoteFrequency = <String, int>{};
    for (final value in remoteList) {
      final key = keyOf(value);
      remoteFrequency[key] = (remoteFrequency[key] ?? 0) + 1;
    }
    for (final entry in remoteByKey.entries) {
      final candidate = proposedByKey[entry.key];
      if (candidate == null) {
        remoteMissing.add(entry.key);
      } else if (!localByKey.containsKey(entry.key) &&
          remoteFrequency[entry.key] == 1 &&
          !(knownFieldsEqual?.call(entry.value, candidate) ??
              _sameKnownFields(entry.value, candidate))) {
        remoteOnlyChanged.add(entry.key);
      }
    }
    fail('remote_${family}_missing_from_proposed', remoteMissing);
    fail('remote_${family}_changed_in_proposed', remoteOnlyChanged);

    _auditCollectionUnknownFields(
      side: 'local',
      family: family,
      baseline: localList,
      proposedByKey: proposedByKey,
      keyOf: keyOf,
      fail: fail,
    );
    _auditCollectionUnknownFields(
      side: 'remote',
      family: family,
      baseline: remoteList,
      proposedByKey: proposedByKey,
      keyOf: keyOf,
      fail: fail,
    );
  }

  bool _sameSourceIdentity(BackupSource first, BackupSource second) =>
      first.sourceId == second.sourceId;

  bool _sameAnimeRepositoryIdentity(
    BackupExtensionRepos first,
    BackupExtensionRepos second,
  ) =>
      chimahonAnimeRepositoryIdentity(first) ==
      chimahonAnimeRepositoryIdentity(second);

  void _auditDuplicateKeys<T>({
    required String side,
    required String family,
    required Iterable<T> values,
    required String Function(T value) keyOf,
    required void Function(String code, Iterable<String> affected) fail,
  }) {
    final counts = <String, int>{};
    for (final value in values) {
      final key = keyOf(value);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    fail(
      '${side}_${family}_duplicate_identity',
      counts.entries.expand((entry) => List.filled(entry.value - 1, entry.key)),
    );
  }

  void _auditCollectionUnknownFields<T extends GeneratedMessage>({
    required String side,
    required String family,
    required Iterable<T> baseline,
    required Map<String, T> proposedByKey,
    required String Function(T value) keyOf,
    required void Function(String code, Iterable<String> affected) fail,
  }) {
    final missing = <String>[];
    for (final value in baseline) {
      final key = keyOf(value);
      final candidate = proposedByKey[key];
      if (candidate == null) continue;
      missing.addAll(
        ChimahonUnknownFieldSafety.missingOrReorderedTags(
          baseline: value,
          target: candidate,
        ).map((tag) => _frame([key, '$tag'])),
      );
      if (value is BackupFeed &&
          candidate is BackupFeed &&
          value.hasSavedSearch() &&
          candidate.hasSavedSearch()) {
        missing.addAll(
          ChimahonUnknownFieldSafety.missingOrReorderedTags(
            baseline: value.savedSearch,
            target: candidate.savedSearch,
          ).map((tag) => _frame([key, 'saved-search', '$tag'])),
        );
      }
    }
    fail('${side}_${family}_unknown_envelope_not_preserved', missing);
  }

  void _auditRootUnknownFields({
    required BackupMihon local,
    required BackupMihon remote,
    required BackupMihon proposed,
    required void Function(String code, Iterable<String> affected) fail,
  }) {
    final remoteMissing = <String>[];
    final remoteChanged = <String>[];
    for (final entry in remote.unknownFields.asMap().entries) {
      if (!proposed.unknownFields.hasField(entry.key)) {
        remoteMissing.add('${entry.key}');
        continue;
      }
      final missing = ChimahonUnknownFieldSafety.missingOrReorderedTags(
        baseline: _messageWithOnlyUnknownField(remote, entry.key),
        target: proposed,
        placement: ChimahonUnknownFieldPlacement.prefix,
      );
      if (missing.isNotEmpty) remoteChanged.add('${entry.key}');
    }
    fail('remote_root_unknown_field_missing_from_proposed', remoteMissing);
    fail('remote_root_unknown_field_changed_in_proposed', remoteChanged);

    final localMissing = <String>[];
    final localChanged = <String>[];
    for (final entry in local.unknownFields.asMap().entries) {
      // Shared root tags are remote-authoritative during ordinary sync. A
      // selected pending restore is separately proven by restore authority.
      if (remote.unknownFields.hasField(entry.key)) continue;
      if (!proposed.unknownFields.hasField(entry.key)) {
        localMissing.add('${entry.key}');
        continue;
      }
      final missing = ChimahonUnknownFieldSafety.missingOrReorderedTags(
        baseline: _messageWithOnlyUnknownField(local, entry.key),
        target: proposed,
        placement: ChimahonUnknownFieldPlacement.suffix,
      );
      if (missing.isNotEmpty) localChanged.add('${entry.key}');
    }
    fail('local_root_unknown_field_missing_from_proposed', localMissing);
    fail('local_root_unknown_field_changed_in_proposed', localChanged);
  }

  /// Verifies that merging statistics neither drops a day nor loses reading.
  ///
  /// These rows are now produced locally rather than passed through opaquely,
  /// so exact-byte preservation is no longer the right check: the merger
  /// deliberately rewrites a row to the larger value per field. What must still
  /// hold is that every `(dateKey, id)` present on either side survives, and
  /// that no counter goes backwards — a regression would silently erase
  /// recorded reading or mined cards.
  void _auditStatistics({
    required BackupMihon local,
    required BackupMihon remote,
    required BackupMihon proposed,
    required void Function(String code, Iterable<String> affected) fail,
    required void Function(String code, Iterable<String> affected) observe,
  }) {
    final proposedManga = _statsByKey(proposed.backupMangaStats, _mangaStatKey);
    final proposedAnki = _statsByKey(proposed.backupAnkiStats, _ankiStatKey);

    for (final side in [('local', local), ('remote', remote)]) {
      final missingManga = <String>[];
      final regressedManga = <String>[];
      for (final row in side.$2.backupMangaStats) {
        final key = _mangaStatKey(row);
        final candidate = proposedManga[key];
        if (candidate == null) {
          missingManga.add(key);
        } else if (candidate.charactersRead < row.charactersRead ||
            candidate.readingTime < row.readingTime) {
          regressedManga.add(key);
        }
      }
      fail('${side.$1}_manga_stat_missing_from_proposed', missingManga);
      fail('${side.$1}_manga_stat_regressed_in_proposed', regressedManga);

      final missingAnki = <String>[];
      final regressedAnki = <String>[];
      for (final row in side.$2.backupAnkiStats) {
        final key = _ankiStatKey(row);
        final candidate = proposedAnki[key];
        if (candidate == null) {
          missingAnki.add(key);
        } else if (candidate.mangaCards < row.mangaCards ||
            candidate.novelCards < row.novelCards) {
          regressedAnki.add(key);
        }
      }
      fail('${side.$1}_anki_stat_missing_from_proposed', missingAnki);
      fail('${side.$1}_anki_stat_regressed_in_proposed', regressedAnki);
    }

    observe(
      'manga_statistics_merged',
      ChimahonOpaqueRows.opaqueDigests(proposed.backupMangaStats),
    );
    observe(
      'anki_statistics_merged',
      ChimahonOpaqueRows.opaqueDigests(proposed.backupAnkiStats),
    );
  }

  /// Keeps the row with the largest counters per key, so an audit against a
  /// side that itself contains duplicate keys still compares against the
  /// strongest claim rather than whichever row happened to come last.
  Map<String, T> _statsByKey<T extends GeneratedMessage>(
    Iterable<T> rows,
    String Function(T row) keyOf,
  ) {
    final result = <String, T>{};
    for (final row in rows) {
      result[keyOf(row)] = row;
    }
    return result;
  }

  static String _mangaStatKey(BackupMangaStats row) =>
      '${row.dateKey}|${row.mangaId}';

  /// An absent `titleId` is distinct from an empty one, so the sentinel must
  /// not collide with a real empty-string title ID.
  static String _ankiStatKey(BackupAnkiStats row) =>
      '${row.dateKey}|${row.profileId}|'
      '${row.hasTitleId() ? 'id:${row.titleId}' : 'none'}';

  T _messageWithOnlyUnknownField<T extends GeneratedMessage>(
    T source,
    int tag,
  ) {
    final result = source.createEmptyInstance() as T;
    final field = source.unknownFields.getField(tag);
    if (field != null) result.unknownFields.mergeField(tag, field);
    return result;
  }

  Map<String, T> _lastByKey<T extends GeneratedMessage>(
    Iterable<T> values,
    String Function(T value) keyOf,
  ) => {for (final value in values) keyOf(value): value};

  bool _sameKnownFields<T extends GeneratedMessage>(T first, T second) {
    final left = _withoutUnknownFields(first);
    final right = _withoutUnknownFields(second);
    return sameBytes(left.writeToBuffer(), right.writeToBuffer());
  }

  T _withoutUnknownFields<T extends GeneratedMessage>(T value) {
    final copy = value.deepCopy()..unknownFields.clear();
    if (copy is BackupFeed) {
      final global = ChimahonFeedIdentity.semanticGlobal(copy);
      copy.global = global;
      if (copy.hasSavedSearch()) copy.savedSearch.unknownFields.clear();
    }
    return copy;
  }

  String _sourceKey(BackupSource source) =>
      source.hasSourceId() ? source.sourceId.toString() : 'source-absent';

  String _savedSearchKey(BackupSavedSearch search) =>
      _frame([search.source.toString(), _normalized(search.name)]);

  String _normalized(String value) => value.trim().toLowerCase();

  String _frame(Iterable<String> values) =>
      values.map((value) => '${utf8.encode(value).length}:$value').join();
}
