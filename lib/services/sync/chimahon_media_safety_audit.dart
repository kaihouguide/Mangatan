import 'dart:convert';

import 'package:mangayomi/services/sync/chimahon_anime_seasons.dart';
import 'package:fixnum/fixnum.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupAnime.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupCategory.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupChapter.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupEpisode.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupHistory.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupManga.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupTracking.pb.dart';
import 'package:mangayomi/services/sync/chimahon_child_identity.dart';
import 'package:mangayomi/services/sync/chimahon_media_child_projection_proof.dart';
import 'package:mangayomi/services/sync/chimahon_media_parent_projection_proof.dart';
import 'package:mangayomi/services/sync/chimahon_media_identity.dart';
import 'package:mangayomi/services/sync/chimahon_sync_merger.dart';
import 'package:mangayomi/services/sync/chimahon_unknown_field_safety.dart';
import 'package:protobuf/protobuf.dart';
import 'package:mangayomi/services/sync/sync_bytes.dart';

/// Symmetric, wire-level preservation checks for Chimahon's manga and anime.
///
/// The caller supplies the effective local intent, not merely a fresh database
/// export. Every remote and effective-local identity must therefore survive in
/// the proposed payload. Conflicting favorite states remain clock-resolved,
/// and category membership is compared by normalized category name because
/// Chimahon uses mutable category orders as its membership references.
class ChimahonMediaSafetyAudit {
  const ChimahonMediaSafetyAudit();

  void audit({
    required BackupMihon remote,
    required BackupMihon local,
    required BackupMihon proposed,
    Set<ChimahonTrackingDeletionKey> localTrackingDeletions = const {},
    bool remoteWinsTies = false,
    required void Function(String, Iterable<String>) fail,
    required void Function(String, Iterable<String>) observe,
  }) {
    final namespace = ChimahonSeasonNamespace(
      local.backupAnime,
      remote.backupAnime,
    );
    local = local.deepCopy()
      ..backupAnime.clear()
      ..backupAnime.addAll(namespace.local);
    remote = remote.deepCopy()
      ..backupAnime.clear()
      ..backupAnime.addAll(namespace.remote);
    _auditDuplicateIdentities(
      label: 'remote',
      backup: remote,
      allowCanonicalChildRepair: true,
      fail: fail,
      observe: observe,
    );
    _auditDuplicateIdentities(
      label: 'local',
      backup: local,
      allowCanonicalChildRepair: false,
      fail: fail,
      observe: observe,
    );
    _auditDuplicateIdentities(
      label: 'proposed',
      backup: proposed,
      allowCanonicalChildRepair: false,
      fail: fail,
      observe: observe,
    );
    _auditLocalTombstoneClocks(remote: remote, local: local, fail: fail);
    _auditExpectedMediaIdentityUnion(
      local: local,
      remote: remote,
      proposed: proposed,
      fail: fail,
    );
    _auditOrderedCategoryPayload(
      media: 'manga',
      local: local.backupCategories,
      remote: remote.backupCategories,
      proposed: proposed.backupCategories,
      fail: fail,
    );
    _auditOrderedCategoryPayload(
      media: 'anime',
      local: local.backupAnimeCategories,
      remote: remote.backupAnimeCategories,
      proposed: proposed.backupAnimeCategories,
      fail: fail,
    );
    _auditMangaTransition(
      label: 'remote',
      baseline: remote,
      competing: local,
      proposed: proposed,
      allowLegacyLocalRebase: false,
      remoteWinsTies: remoteWinsTies,
      projectionTrackingDeletions: localTrackingDeletions,
      fail: fail,
    );
    _auditMangaTransition(
      label: 'local',
      baseline: local,
      competing: remote,
      proposed: proposed,
      allowLegacyLocalRebase: true,
      remoteWinsTies: remoteWinsTies,
      projectionTrackingDeletions: localTrackingDeletions,
      fail: fail,
    );
    _auditAnimeTransition(
      label: 'remote',
      baseline: remote,
      competing: local,
      proposed: proposed,
      allowLegacyLocalRebase: false,
      remoteWinsTies: remoteWinsTies,
      projectionTrackingDeletions: localTrackingDeletions,
      fail: fail,
    );
    _auditAnimeTransition(
      label: 'local',
      baseline: local,
      competing: remote,
      proposed: proposed,
      allowLegacyLocalRebase: true,
      remoteWinsTies: remoteWinsTies,
      projectionTrackingDeletions: localTrackingDeletions,
      fail: fail,
    );
  }

  /// A clockless tombstone is tolerated only as an unchanged legacy row that
  /// already exists remotely. Newly-created local deletions need an explicit
  /// favorite-state clock so another device can order them safely.
  void _auditLocalTombstoneClocks({
    required BackupMihon remote,
    required BackupMihon local,
    required void Function(String, Iterable<String>) fail,
  }) {
    final remoteLegacyMangaBytes = {
      for (final manga in remote.backupManga)
        if (_isLegacyMangaTombstone(manga)) base64Encode(manga.writeToBuffer()),
    };
    fail(
      'local_manga_tombstone_deletion_clock_missing',
      local.backupManga
          .where(_isLegacyMangaTombstone)
          .where(
            (manga) => !remoteLegacyMangaBytes.contains(
              base64Encode(manga.writeToBuffer()),
            ),
          )
          .map(mangaIdentity),
    );

    final localSeasonParents = chimahonSeasonParents(local.backupAnime);
    final remoteLegacyAnimeBytes = {
      for (final anime in remote.backupAnime)
        if (_isLegacyAnimeTombstone(anime)) base64Encode(anime.writeToBuffer()),
    };
    fail(
      'local_anime_tombstone_deletion_clock_missing',
      local.backupAnime
          .where(_isLegacyAnimeTombstone)
          .where((anime) => !localSeasonParents.containsKey(anime))
          .where(
            (anime) => !remoteLegacyAnimeBytes.contains(
              base64Encode(anime.writeToBuffer()),
            ),
          )
          .map(animeIdentity),
    );
  }

  bool _isLegacyMangaTombstone(BackupManga manga) =>
      manga.hasFavorite() &&
      !manga.favorite &&
      (!manga.hasFavoriteModifiedAt() ||
          manga.favoriteModifiedAt <= Int64.ZERO);

  bool _isLegacyAnimeTombstone(BackupAnime anime) =>
      anime.hasFavorite() &&
      !anime.favorite &&
      (!anime.hasFavoriteModifiedAt() ||
          anime.favoriteModifiedAt <= Int64.ZERO);

  /// Parent, history, and tracking duplicates remain ambiguous and are always
  /// rejected. Existing remote chapter/episode duplicates can be normalized
  /// by the deterministic child canonicalizer; the transition audits below
  /// still require the resulting clock, portable state, and unknown fields to
  /// preserve that complete canonical projection. Local and proposed
  /// duplicates remain hard failures so Mangatan never creates or uploads new
  /// ambiguity.
  void _auditDuplicateIdentities({
    required String label,
    required BackupMihon backup,
    required bool allowCanonicalChildRepair,
    required void Function(String, Iterable<String>) fail,
    required void Function(String, Iterable<String>) observe,
  }) {
    fail(
      '${label}_manga_duplicate_identity',
      _duplicateSurplus(backup.backupManga.map(mangaIdentity)),
    );
    final duplicateChapters = <String>[];
    final duplicateMangaHistory = <String>[];
    final duplicateMangaTracking = <String>[];
    for (final manga in backup.backupManga) {
      final parentKey = mangaIdentity(manga);
      duplicateChapters.addAll(
        _duplicateSurplus(manga.chapters.map(_rawChapterIdentity))
            .map((key) => _join([parentKey, key])),
      );
      duplicateMangaHistory.addAll(
        _duplicateSurplus(manga.history.map((history) => history.url))
            .map((key) => _join([parentKey, key])),
      );
      duplicateMangaTracking.addAll(
        _duplicateSurplus(
          manga.tracking.map((tracking) => tracking.syncId.toString()),
        ).map((key) => _join([parentKey, key])),
      );
    }
    final reportChildDuplicate = allowCanonicalChildRepair ? observe : fail;
    reportChildDuplicate(
      '${label}_manga_chapter_duplicate_identity',
      duplicateChapters,
    );
    fail('${label}_manga_history_duplicate_identity', duplicateMangaHistory);
    fail('${label}_manga_tracking_duplicate_identity', duplicateMangaTracking);

    fail(
      '${label}_anime_duplicate_identity',
      _duplicateSurplus(backup.backupAnime.map(animeIdentity)),
    );
    final duplicateEpisodes = <String>[];
    final duplicateAnimeHistory = <String>[];
    final duplicateAnimeTracking = <String>[];
    for (final anime in backup.backupAnime) {
      final parentKey = animeIdentity(anime);
      duplicateEpisodes.addAll(
        _duplicateSurplus(anime.episodes.map(_rawEpisodeIdentity))
            .map((key) => _join([parentKey, key])),
      );
      duplicateAnimeHistory.addAll(
        _duplicateSurplus(anime.history.map((history) => history.url))
            .map((key) => _join([parentKey, key])),
      );
      duplicateAnimeTracking.addAll(
        _duplicateSurplus(
          anime.tracking.map((tracking) => tracking.syncId.toString()),
        ).map((key) => _join([parentKey, key])),
      );
    }
    reportChildDuplicate(
      '${label}_anime_episode_duplicate_identity',
      duplicateEpisodes,
    );
    fail('${label}_anime_history_duplicate_identity', duplicateAnimeHistory);
    fail('${label}_anime_tracking_duplicate_identity', duplicateAnimeTracking);
  }

  /// Rejects rows that cannot be derived from either input. The merger may
  /// rebase a lossy local projection onto a unique remote identity, but a
  /// proposed row never participates in that proof.
  void _auditExpectedMediaIdentityUnion({
    required BackupMihon local,
    required BackupMihon remote,
    required BackupMihon proposed,
    required void Function(String, Iterable<String>) fail,
  }) {
    final mangaBuckets = _mangaIdentityBuckets(
      local: local.backupManga,
      remote: remote.backupManga,
    );
    final proposedMangaByKey = _lastByKey(proposed.backupManga, mangaIdentity);
    final expectedMangaKeys = mangaBuckets.keys.toSet();
    fail(
      'manga_extra_in_proposed',
      proposedMangaByKey.keys.where((key) => !expectedMangaKeys.contains(key)),
    );
    final extraChapters = <String>[];
    final extraMangaHistory = <String>[];
    for (final entry in mangaBuckets.entries) {
      final proposedManga = proposedMangaByKey[entry.key];
      if (proposedManga == null) continue;
      final bucket = entry.value;
      final expectedChapterKeys = _expectedChapterIdentityUnion(
        local: bucket.localOriginal?.chapters ?? const [],
        remote: bucket.remote?.chapters ?? const [],
      );
      for (final key in proposedManga.chapters.map(chapterIdentity)) {
        if (!expectedChapterKeys.contains(key)) {
          extraChapters.add(_join([entry.key, key]));
        }
      }
      final expectedHistoryUrls = {
        ...?bucket.localOriginal?.history.map((history) => history.url),
        ...?bucket.remote?.history.map((history) => history.url),
      };
      for (final history in proposedManga.history) {
        if (!expectedHistoryUrls.contains(history.url)) {
          extraMangaHistory.add(_join([entry.key, history.url]));
        }
      }
    }
    fail('manga_chapter_extra_in_proposed', extraChapters);
    fail('manga_history_extra_in_proposed', extraMangaHistory);

    final animeBuckets = _animeIdentityBuckets(
      local: local.backupAnime,
      remote: remote.backupAnime,
    );
    final proposedAnimeByKey = _lastByKey(proposed.backupAnime, animeIdentity);
    final expectedAnimeKeys = animeBuckets.keys.toSet();
    fail(
      'anime_extra_in_proposed',
      proposedAnimeByKey.keys.where((key) => !expectedAnimeKeys.contains(key)),
    );
    final extraEpisodes = <String>[];
    final extraAnimeHistory = <String>[];
    for (final entry in animeBuckets.entries) {
      final proposedAnime = proposedAnimeByKey[entry.key];
      if (proposedAnime == null) continue;
      final bucket = entry.value;
      final expectedEpisodeKeys = _expectedEpisodeIdentityUnion(
        local: bucket.localOriginal?.episodes ?? const [],
        remote: bucket.remote?.episodes ?? const [],
      );
      for (final key in proposedAnime.episodes.map(episodeIdentity)) {
        if (!expectedEpisodeKeys.contains(key)) {
          extraEpisodes.add(_join([entry.key, key]));
        }
      }
      final expectedHistoryUrls = {
        ...?bucket.localOriginal?.history.map((history) => history.url),
        ...?bucket.remote?.history.map((history) => history.url),
      };
      for (final history in proposedAnime.history) {
        if (!expectedHistoryUrls.contains(history.url)) {
          extraAnimeHistory.add(_join([entry.key, history.url]));
        }
      }
    }
    fail('anime_episode_extra_in_proposed', extraEpisodes);
    fail('anime_history_extra_in_proposed', extraAnimeHistory);
  }

  Map<String, _MangaIdentityBucket> _mangaIdentityBuckets({
    required Iterable<BackupManga> local,
    required Iterable<BackupManga> remote,
  }) {
    final localList = local.toList(growable: false);
    final remoteList = remote.toList(growable: false);
    final localBySourceUrl = _groupByKey(localList, mangaSourceUrlIdentity);
    final remoteBySourceUrl = _groupByKey(remoteList, mangaSourceUrlIdentity);
    final result = <String, _MangaIdentityBucket>{
      for (final value in remoteList)
        mangaIdentity(value): _MangaIdentityBucket(remote: value),
    };
    for (final value in localList) {
      final exactKey = mangaIdentity(value);
      final exact = result[exactKey];
      if (exact != null) {
        result[exactKey] = exact.withLocal(value, value);
        continue;
      }
      final sourceUrlKey = mangaSourceUrlIdentity(value);
      final remoteMatches = remoteBySourceUrl[sourceUrlKey];
      if (localBySourceUrl[sourceUrlKey]?.length == 1 &&
          remoteMatches?.length == 1) {
        final remoteValue = remoteMatches!.single;
        final canonical =
            ChimahonMediaParentProjectionProof.tryRebaseLocalMangaIdentity(
              localProjection: value,
              remote: remoteValue,
              localSourceUrlIsUnique: true,
              remoteSourceUrlIsUnique: true,
            );
        if (canonical != null &&
            mangaIdentity(canonical) == mangaIdentity(remoteValue)) {
          final canonicalKey = mangaIdentity(remoteValue);
          result[canonicalKey] = result[canonicalKey]!.withLocal(
            value,
            canonical,
          );
          continue;
        }
      }
      result[exactKey] = _MangaIdentityBucket(
        localOriginal: value,
        localCanonical: value,
      );
    }
    return result;
  }

  Map<String, _AnimeIdentityBucket> _animeIdentityBuckets({
    required Iterable<BackupAnime> local,
    required Iterable<BackupAnime> remote,
  }) {
    final localList = local.toList(growable: false);
    final remoteList = remote.toList(growable: false);
    final localBySourceUrl = _groupByKey(localList, animeSourceUrlIdentity);
    final remoteBySourceUrl = _groupByKey(remoteList, animeSourceUrlIdentity);
    final result = <String, _AnimeIdentityBucket>{
      for (final value in remoteList)
        animeIdentity(value): _AnimeIdentityBucket(remote: value),
    };
    for (final value in localList) {
      final exactKey = animeIdentity(value);
      final exact = result[exactKey];
      if (exact != null) {
        result[exactKey] = exact.withLocal(value, value);
        continue;
      }
      final sourceUrlKey = animeSourceUrlIdentity(value);
      final remoteMatches = remoteBySourceUrl[sourceUrlKey];
      if (localBySourceUrl[sourceUrlKey]?.length == 1 &&
          remoteMatches?.length == 1) {
        final remoteValue = remoteMatches!.single;
        final canonical =
            ChimahonMediaParentProjectionProof.tryRebaseLocalAnimeIdentity(
              localProjection: value,
              remote: remoteValue,
              localSourceUrlIsUnique: true,
              remoteSourceUrlIsUnique: true,
            );
        if (canonical != null &&
            animeIdentity(canonical) == animeIdentity(remoteValue)) {
          final canonicalKey = animeIdentity(remoteValue);
          result[canonicalKey] = result[canonicalKey]!.withLocal(
            value,
            canonical,
          );
          continue;
        }
      }
      result[exactKey] = _AnimeIdentityBucket(
        localOriginal: value,
        localCanonical: value,
      );
    }
    return result;
  }

  Set<String> _expectedChapterIdentityUnion({
    required Iterable<BackupChapter> local,
    required Iterable<BackupChapter> remote,
  }) {
    final localList = canonicalizeChimahonChapters(local);
    final remoteList = canonicalizeChimahonChapters(remote);
    final remoteKeys = remoteList.map(chapterIdentity).toSet();
    final localByUrl = _groupByKey(localList, (chapter) => chapter.url);
    final remoteByUrl = _groupByKey(remoteList, (chapter) => chapter.url);
    final result = {...remoteKeys};
    for (final value in localList) {
      final exactKey = chapterIdentity(value);
      if (remoteKeys.contains(exactKey)) continue;
      final remoteMatches = remoteByUrl[value.url];
      if (value.url.isNotEmpty &&
          localByUrl[value.url]?.length == 1 &&
          remoteMatches?.length == 1) {
        final remoteValue = remoteMatches!.single;
        final canonical =
            ChimahonMediaChildProjectionProof.rebaseLocalChapterIdentity(
              localProjection: value,
              remote: remoteValue,
            );
        if (chapterIdentity(canonical) == chapterIdentity(remoteValue)) {
          continue;
        }
      }
      result.add(exactKey);
    }
    return result;
  }

  Set<String> _expectedEpisodeIdentityUnion({
    required Iterable<BackupEpisode> local,
    required Iterable<BackupEpisode> remote,
  }) {
    final localList = canonicalizeChimahonEpisodes(local);
    final remoteList = canonicalizeChimahonEpisodes(remote);
    final remoteKeys = remoteList.map(episodeIdentity).toSet();
    final localByUrl = _groupByKey(localList, (episode) => episode.url);
    final remoteByUrl = _groupByKey(remoteList, (episode) => episode.url);
    final result = {...remoteKeys};
    for (final value in localList) {
      final exactKey = episodeIdentity(value);
      if (remoteKeys.contains(exactKey)) continue;
      final remoteMatches = remoteByUrl[value.url];
      if (value.url.isNotEmpty &&
          localByUrl[value.url]?.length == 1 &&
          remoteMatches?.length == 1) {
        final remoteValue = remoteMatches!.single;
        final canonical =
            ChimahonMediaChildProjectionProof.rebaseLocalEpisodeIdentity(
              localProjection: value,
              remote: remoteValue,
            );
        if (episodeIdentity(canonical) == episodeIdentity(remoteValue)) {
          continue;
        }
      }
      result.add(exactKey);
    }
    return result;
  }

  void _auditMangaTransition({
    required String label,
    required BackupMihon baseline,
    required BackupMihon competing,
    required BackupMihon proposed,
    required bool allowLegacyLocalRebase,
    required bool remoteWinsTies,
    required Set<ChimahonTrackingDeletionKey> projectionTrackingDeletions,
    required void Function(String, Iterable<String>) fail,
  }) {
    final proposedByKey = _lastByKey(proposed.backupManga, mangaIdentity);
    final competingByKey = _lastByKey(competing.backupManga, mangaIdentity);
    final baselineBySourceUrl = _groupByKey(
      baseline.backupManga,
      mangaSourceUrlIdentity,
    );
    final competingBySourceUrl = _groupByKey(
      competing.backupManga,
      mangaSourceUrlIdentity,
    );
    final baselineCategoryList = baseline.backupCategories.toList(
      growable: false,
    );
    final competingCategoryList = competing.backupCategories.toList(
      growable: false,
    );
    final localCategoryList = allowLegacyLocalRebase
        ? baselineCategoryList
        : competingCategoryList;
    final remoteCategoryList = allowLegacyLocalRebase
        ? competingCategoryList
        : baselineCategoryList;
    final expectedMergedCategories = _expectedOrderedCategories(
      local: localCategoryList,
      remote: remoteCategoryList,
    );

    final missingParents = <String>[];
    final regressedParentClocks = <String>[];
    final changedParentValues = <String>[];
    final changedParentUnknownFields = <String>[];
    final missingChapters = <String>[];
    final regressedChapterClocks = <String>[];
    final changedChapterValues = <String>[];
    final changedChapterUnknownFields = <String>[];
    final missingHistory = <String>[];
    final regressedHistoryClocks = <String>[];
    final changedHistoryValues = <String>[];
    final changedHistoryUnknownFields = <String>[];
    final missingTracking = <String>[];
    final changedTrackingValues = <String>[];
    final changedTrackingUnknownFields = <String>[];
    final missingMemberships = <String>[];
    final lostCustomTitles = <String>[];
    final favoriteFailures = <_FavoriteFailure, List<String>>{};

    for (final baselineManga in baseline.backupManga) {
      final key = mangaIdentity(baselineManga);
      final pair = _pairManga(
        baseline: baselineManga,
        baselineIsLocal: allowLegacyLocalRebase,
        competingByKey: competingByKey,
        baselineBySourceUrl: baselineBySourceUrl,
        competingBySourceUrl: competingBySourceUrl,
      );
      final competingManga = pair.competingForBaseline;
      final merged = proposedByKey[mangaIdentity(pair.canonicalBaseline)];
      if (merged == null) {
        missingParents.add(key);
        continue;
      }
      final allowedParentWinners = _allowedMangaWinners(
        pair: pair,
        remoteWinsTies: remoteWinsTies,
        localTrackingDeletions: projectionTrackingDeletions,
        localCategories: localCategoryList,
        remoteCategories: remoteCategoryList,
        mergedCategories: expectedMergedCategories,
      );
      final expectedParentProjection = _expectedParentProjection(
        local: pair.localOriginal == null
            ? null
            : _FavoriteSnapshot.manga(pair.localOriginal!),
        remote: pair.remote == null
            ? null
            : _FavoriteSnapshot.manga(pair.remote!),
        parentWinner: allowedParentWinners.single,
      );
      if (expectedParentProjection == null ||
          !_recordClockMatches(
            expected: expectedParentProjection,
            proposed: _FavoriteSnapshot.manga(merged),
          )) {
        regressedParentClocks.add(key);
      }
      if (!_matchesAnyMangaPortableProjection(
        proposed: merged,
        pair: pair,
        allowedWinners: allowedParentWinners,
      )) {
        changedParentValues.add(key);
      }
      if (!_matchesAllowedUnknownEnvelope(
        proposed: merged,
        local: pair.localOriginal,
        remote: pair.remote,
        allowedWinners: allowedParentWinners,
      )) {
        changedParentUnknownFields.add(key);
      }

      final favoriteFindings = _favoriteTransitionFailures(
        baseline: _FavoriteSnapshot.manga(baselineManga),
        expected: expectedParentProjection?.favorite,
        proposed: _FavoriteSnapshot.manga(merged),
      );
      for (final finding in favoriteFindings) {
        favoriteFailures.putIfAbsent(finding, () => []).add(key);
      }

      if (baselineManga.hasCustomTitle()) {
        final exactBaselineValue =
            merged.hasCustomTitle() &&
            merged.customTitle == baselineManga.customTitle;
        final validCompetingValue =
            competingManga != null &&
            competingManga.hasCustomTitle() &&
            merged.hasCustomTitle() &&
            merged.customTitle == competingManga.customTitle &&
            _recordStrictlyNewer(competingManga, baselineManga);
        if (!exactBaselineValue && !validCompetingValue) {
          lostCustomTitles.add(key);
        }
      }

      _auditChapters(
        parentKey: key,
        baseline: baselineManga.chapters,
        competing: competingManga?.chapters ?? const [],
        proposed: merged.chapters,
        allowUnversionedUrlRebase: allowLegacyLocalRebase,
        remoteWinsTies: remoteWinsTies,
        missing: missingChapters,
        clockRegressed: regressedChapterClocks,
        valuesChanged: changedChapterValues,
        unknownFieldsChanged: changedChapterUnknownFields,
      );
      _auditHistory(
        parentKey: key,
        baseline: baselineManga.history,
        competing: competingManga?.history ?? const [],
        proposed: merged.history,
        baselineIsLocal: label == 'local',
        remoteWinsTies: remoteWinsTies,
        missing: missingHistory,
        clockRegressed: regressedHistoryClocks,
        valuesChanged: changedHistoryValues,
        unknownFieldsChanged: changedHistoryUnknownFields,
      );
      _auditTracking(
        parentKey: key,
        source: baselineManga.source.toInt(),
        url: baselineManga.url,
        local: pair.localOriginal?.tracking ?? const [],
        remote: pair.remote?.tracking ?? const [],
        proposed: merged.tracking,
        localTrackingDeletions: projectionTrackingDeletions,
        parentWinner: allowedParentWinners.single,
        missing: missingTracking,
        valuesChanged: changedTrackingValues,
        unknownFieldsChanged: changedTrackingUnknownFields,
      );
      final parentWinner = allowedParentWinners.single;
      final membershipSource = parentWinner == _MediaWinner.local
          ? pair.localOriginal!
          : pair.remote!;
      _auditMembership(
        parentKey: key,
        sourceOrders: membershipSource.categories,
        sourceCategories: parentWinner == _MediaWinner.local
            ? localCategoryList
            : remoteCategoryList,
        mergedCategories: expectedMergedCategories,
        proposedOrders: merged.categories,
        changed: missingMemberships,
      );
    }

    fail('${label}_manga_missing_from_proposed', missingParents);
    fail('${label}_manga_record_clock_regressed', regressedParentClocks);
    fail('${label}_manga_portable_values_changed', changedParentValues);
    fail(
      '${label}_manga_unknown_fields_not_retained',
      changedParentUnknownFields,
    );
    fail('${label}_manga_chapter_missing_from_proposed', missingChapters);
    fail('${label}_manga_chapter_clock_regressed', regressedChapterClocks);
    fail(
      '${label}_manga_chapter_portable_values_changed',
      changedChapterValues,
    );
    fail(
      '${label}_manga_chapter_unknown_fields_not_retained',
      changedChapterUnknownFields,
    );
    fail('${label}_manga_history_missing_from_proposed', missingHistory);
    fail('${label}_manga_history_clock_regressed', regressedHistoryClocks);
    fail(
      '${label}_manga_history_portable_values_changed',
      changedHistoryValues,
    );
    fail(
      '${label}_manga_history_unknown_fields_not_retained',
      changedHistoryUnknownFields,
    );
    fail('${label}_manga_tracking_missing_from_proposed', missingTracking);
    fail(
      '${label}_manga_tracking_portable_values_changed',
      changedTrackingValues,
    );
    fail(
      '${label}_manga_tracking_unknown_fields_not_retained',
      changedTrackingUnknownFields,
    );
    fail(
      '${label}_manga_category_membership_missing_from_proposed',
      missingMemberships,
    );
    fail('${label}_custom_title_not_retained', lostCustomTitles);
    _emitFavoriteFailures(
      label: label,
      media: 'manga',
      failures: favoriteFailures,
      fail: fail,
    );
  }

  void _auditAnimeTransition({
    required String label,
    required BackupMihon baseline,
    required BackupMihon competing,
    required BackupMihon proposed,
    required bool allowLegacyLocalRebase,
    required bool remoteWinsTies,
    required Set<ChimahonTrackingDeletionKey> projectionTrackingDeletions,
    required void Function(String, Iterable<String>) fail,
  }) {
    final proposedByKey = _lastByKey(proposed.backupAnime, animeIdentity);
    final competingByKey = _lastByKey(competing.backupAnime, animeIdentity);
    final baselineBySourceUrl = _groupByKey(
      baseline.backupAnime,
      animeSourceUrlIdentity,
    );
    final competingBySourceUrl = _groupByKey(
      competing.backupAnime,
      animeSourceUrlIdentity,
    );
    final baselineCategoryList = baseline.backupAnimeCategories.toList(
      growable: false,
    );
    final competingCategoryList = competing.backupAnimeCategories.toList(
      growable: false,
    );
    final localCategoryList = allowLegacyLocalRebase
        ? baselineCategoryList
        : competingCategoryList;
    final remoteCategoryList = allowLegacyLocalRebase
        ? competingCategoryList
        : baselineCategoryList;
    final expectedMergedCategories = _expectedOrderedCategories(
      local: localCategoryList,
      remote: remoteCategoryList,
    );

    final missingParents = <String>[];
    final regressedParentClocks = <String>[];
    final changedParentValues = <String>[];
    final changedParentUnknownFields = <String>[];
    final missingEpisodes = <String>[];
    final regressedEpisodeClocks = <String>[];
    final changedEpisodeValues = <String>[];
    final changedEpisodeUnknownFields = <String>[];
    final missingHistory = <String>[];
    final regressedHistoryClocks = <String>[];
    final changedHistoryValues = <String>[];
    final changedHistoryUnknownFields = <String>[];
    final missingTracking = <String>[];
    final changedTrackingValues = <String>[];
    final changedTrackingUnknownFields = <String>[];
    final missingMemberships = <String>[];
    final favoriteFailures = <_FavoriteFailure, List<String>>{};

    for (final baselineAnime in baseline.backupAnime) {
      final key = animeIdentity(baselineAnime);
      final pair = _pairAnime(
        baseline: baselineAnime,
        baselineIsLocal: allowLegacyLocalRebase,
        competingByKey: competingByKey,
        baselineBySourceUrl: baselineBySourceUrl,
        competingBySourceUrl: competingBySourceUrl,
      );
      final competingAnime = pair.competingForBaseline;
      final merged = proposedByKey[animeIdentity(pair.canonicalBaseline)];
      if (merged == null) {
        missingParents.add(key);
        continue;
      }
      final allowedParentWinners = _allowedAnimeWinners(
        pair: pair,
        remoteWinsTies: remoteWinsTies,
        localTrackingDeletions: projectionTrackingDeletions,
        localCategories: localCategoryList,
        remoteCategories: remoteCategoryList,
        mergedCategories: expectedMergedCategories,
      );
      final expectedParentProjection = _expectedParentProjection(
        local: pair.localOriginal == null
            ? null
            : _FavoriteSnapshot.anime(pair.localOriginal!),
        remote: pair.remote == null
            ? null
            : _FavoriteSnapshot.anime(pair.remote!),
        parentWinner: allowedParentWinners.single,
      );
      if (expectedParentProjection == null ||
          !_recordClockMatches(
            expected: expectedParentProjection,
            proposed: _FavoriteSnapshot.anime(merged),
          )) {
        regressedParentClocks.add(key);
      }
      if (!_matchesAnyAnimePortableProjection(
        proposed: merged,
        pair: pair,
        allowedWinners: allowedParentWinners,
      )) {
        changedParentValues.add(key);
      }
      if (!_matchesAllowedUnknownEnvelope(
        proposed: merged,
        local: pair.localOriginal,
        remote: pair.remote,
        allowedWinners: allowedParentWinners,
      )) {
        changedParentUnknownFields.add(key);
      }

      final favoriteFindings = _favoriteTransitionFailures(
        baseline: _FavoriteSnapshot.anime(baselineAnime),
        expected: expectedParentProjection?.favorite,
        proposed: _FavoriteSnapshot.anime(merged),
      );
      for (final finding in favoriteFindings) {
        favoriteFailures.putIfAbsent(finding, () => []).add(key);
      }

      _auditEpisodes(
        parentKey: key,
        baseline: baselineAnime.episodes,
        competing: competingAnime?.episodes ?? const [],
        proposed: merged.episodes,
        allowUnversionedUrlRebase: label == 'local',
        remoteWinsTies: remoteWinsTies,
        missing: missingEpisodes,
        clockRegressed: regressedEpisodeClocks,
        valuesChanged: changedEpisodeValues,
        unknownFieldsChanged: changedEpisodeUnknownFields,
      );
      _auditHistory(
        parentKey: key,
        baseline: baselineAnime.history,
        competing: competingAnime?.history ?? const [],
        proposed: merged.history,
        baselineIsLocal: label == 'local',
        remoteWinsTies: remoteWinsTies,
        missing: missingHistory,
        clockRegressed: regressedHistoryClocks,
        valuesChanged: changedHistoryValues,
        unknownFieldsChanged: changedHistoryUnknownFields,
      );
      _auditTracking(
        parentKey: key,
        source: baselineAnime.source.toInt(),
        url: baselineAnime.url,
        local: pair.localOriginal?.tracking ?? const [],
        remote: pair.remote?.tracking ?? const [],
        proposed: merged.tracking,
        localTrackingDeletions: projectionTrackingDeletions,
        parentWinner: allowedParentWinners.single,
        missing: missingTracking,
        valuesChanged: changedTrackingValues,
        unknownFieldsChanged: changedTrackingUnknownFields,
      );
      final parentWinner = allowedParentWinners.single;
      final membershipSource = parentWinner == _MediaWinner.local
          ? pair.localOriginal!
          : pair.remote!;
      _auditMembership(
        parentKey: key,
        sourceOrders: membershipSource.categories,
        sourceCategories: parentWinner == _MediaWinner.local
            ? localCategoryList
            : remoteCategoryList,
        mergedCategories: expectedMergedCategories,
        proposedOrders: merged.categories,
        changed: missingMemberships,
      );
    }

    fail('${label}_anime_missing_from_proposed', missingParents);
    fail('${label}_anime_record_clock_regressed', regressedParentClocks);
    fail('${label}_anime_portable_values_changed', changedParentValues);
    fail(
      '${label}_anime_unknown_fields_not_retained',
      changedParentUnknownFields,
    );
    fail('${label}_anime_episode_missing_from_proposed', missingEpisodes);
    fail('${label}_anime_episode_clock_regressed', regressedEpisodeClocks);
    fail(
      '${label}_anime_episode_portable_values_changed',
      changedEpisodeValues,
    );
    fail(
      '${label}_anime_episode_unknown_fields_not_retained',
      changedEpisodeUnknownFields,
    );
    fail('${label}_anime_history_missing_from_proposed', missingHistory);
    fail('${label}_anime_history_clock_regressed', regressedHistoryClocks);
    fail(
      '${label}_anime_history_portable_values_changed',
      changedHistoryValues,
    );
    fail(
      '${label}_anime_history_unknown_fields_not_retained',
      changedHistoryUnknownFields,
    );
    fail('${label}_anime_tracking_missing_from_proposed', missingTracking);
    fail(
      '${label}_anime_tracking_portable_values_changed',
      changedTrackingValues,
    );
    fail(
      '${label}_anime_tracking_unknown_fields_not_retained',
      changedTrackingUnknownFields,
    );
    fail(
      '${label}_anime_category_membership_missing_from_proposed',
      missingMemberships,
    );
    _emitFavoriteFailures(
      label: label,
      media: 'anime',
      failures: favoriteFailures,
      fail: fail,
    );
  }

  void _auditChapters({
    required String parentKey,
    required Iterable<BackupChapter> baseline,
    required Iterable<BackupChapter> competing,
    required Iterable<BackupChapter> proposed,
    required bool allowUnversionedUrlRebase,
    required bool remoteWinsTies,
    required List<String> missing,
    required List<String> clockRegressed,
    required List<String> valuesChanged,
    required List<String> unknownFieldsChanged,
  }) {
    final baselineList = canonicalizeChimahonChapters(baseline);
    final baselineByUrl = _groupByKey(baselineList, (chapter) => chapter.url);
    final proposedList = canonicalizeChimahonChapters(proposed);
    final proposedByKey = _lastByKey(proposedList, chapterIdentity);
    final competingList = canonicalizeChimahonChapters(competing);
    final competingByKey = _groupByKey(competingList, chapterIdentity);
    final competingByUrl = _groupByKey(competingList, (chapter) => chapter.url);
    for (final chapter in baselineList) {
      final originalKey = chapterIdentity(chapter);
      final pair = _pairChapter(
        baseline: chapter,
        baselineIsLocal: allowUnversionedUrlRebase,
        competingByKey: competingByKey,
        baselineByUrl: baselineByUrl,
        competingByUrl: competingByUrl,
      );
      final key = chapterIdentity(pair.canonicalBaseline);
      final merged = proposedByKey[key];
      final qualified = _join([parentKey, originalKey]);
      if (merged == null) {
        missing.add(qualified);
        continue;
      }

      final allowedWinners = _allowedChapterWinners(
        pair: pair,
        remoteWinsTies: remoteWinsTies,
      );
      final portableValuesMatch = _matchesAnyChapterPortableProjection(
        proposed: merged,
        pair: pair,
        allowedWinners: allowedWinners,
      );
      if (!portableValuesMatch) valuesChanged.add(qualified);
      if (!_matchesAllowedUnknownEnvelope(
        proposed: merged,
        local: pair.localOriginal,
        remote: pair.remote,
        allowedWinners: allowedWinners,
      )) {
        unknownFieldsChanged.add(qualified);
      }

      final expectedClock = _expectedChapterClock(
        pair: pair,
        winner: allowedWinners.single,
      );
      if (expectedClock == null ||
          !_chapterClockMatches(expectedClock, merged)) {
        clockRegressed.add(qualified);
      }
    }
  }

  void _auditEpisodes({
    required String parentKey,
    required Iterable<BackupEpisode> baseline,
    required Iterable<BackupEpisode> competing,
    required Iterable<BackupEpisode> proposed,
    required bool allowUnversionedUrlRebase,
    required bool remoteWinsTies,
    required List<String> missing,
    required List<String> clockRegressed,
    required List<String> valuesChanged,
    required List<String> unknownFieldsChanged,
  }) {
    final baselineList = canonicalizeChimahonEpisodes(baseline);
    final baselineByUrl = _groupByKey(baselineList, (episode) => episode.url);
    final proposedList = canonicalizeChimahonEpisodes(proposed);
    final proposedByKey = _lastByKey(proposedList, episodeIdentity);
    final competingList = canonicalizeChimahonEpisodes(competing);
    final competingByKey = _groupByKey(competingList, episodeIdentity);
    final competingByUrl = _groupByKey(competingList, (episode) => episode.url);
    for (final episode in baselineList) {
      final originalKey = episodeIdentity(episode);
      final pair = _pairEpisode(
        baseline: episode,
        baselineIsLocal: allowUnversionedUrlRebase,
        competingByKey: competingByKey,
        baselineByUrl: baselineByUrl,
        competingByUrl: competingByUrl,
      );
      final key = episodeIdentity(pair.canonicalBaseline);
      final merged = proposedByKey[key];
      final qualified = _join([parentKey, originalKey]);
      if (merged == null) {
        missing.add(qualified);
        continue;
      }

      final allowedWinners = _allowedEpisodeWinners(
        pair: pair,
        remoteWinsTies: remoteWinsTies,
      );
      final portableValuesMatch = _matchesAnyEpisodePortableProjection(
        proposed: merged,
        pair: pair,
        allowedWinners: allowedWinners,
      );
      if (!portableValuesMatch) valuesChanged.add(qualified);
      if (!_matchesAllowedUnknownEnvelope(
        proposed: merged,
        local: pair.localOriginal,
        remote: pair.remote,
        allowedWinners: allowedWinners,
      )) {
        unknownFieldsChanged.add(qualified);
      }

      final expectedClock = _expectedEpisodeClock(
        pair: pair,
        winner: allowedWinners.single,
      );
      if (expectedClock == null ||
          !_episodeClockMatches(expectedClock, merged)) {
        clockRegressed.add(qualified);
      }
    }
  }

  _ExpectedRecordClock? _expectedChapterClock({
    required _ChapterPair pair,
    required _MediaWinner winner,
  }) {
    final local = pair.localOriginal;
    final remote = pair.remote;
    if (local == null) {
      return _ExpectedRecordClock(
        hasVersion: remote!.hasVersion(),
        version: remote.version.toInt(),
        hasLastModifiedAt: remote.hasLastModifiedAt(),
        lastModifiedAt: remote.lastModifiedAt.toInt(),
      );
    }
    if (remote == null) {
      return _ExpectedRecordClock(
        hasVersion: local.hasVersion(),
        version: local.version.toInt(),
        hasLastModifiedAt: local.hasLastModifiedAt(),
        lastModifiedAt: local.lastModifiedAt.toInt(),
      );
    }
    final selected = winner == _MediaWinner.local ? local : remote;
    var hasVersion = selected.hasVersion();
    var version = selected.version.toInt();
    if (winner == _MediaWinner.local &&
        local.version == Int64.ZERO &&
        local.lastModifiedAt > remote.lastModifiedAt) {
      final promoted = _checkedNextVersion(
        local.version.toInt(),
        remote.version.toInt(),
      );
      if (promoted == null) return null;
      hasVersion = true;
      version = promoted;
    }
    return _ExpectedRecordClock(
      hasVersion: hasVersion,
      version: version,
      hasLastModifiedAt: selected.hasLastModifiedAt(),
      lastModifiedAt: selected.lastModifiedAt.toInt(),
    );
  }

  _ExpectedRecordClock? _expectedEpisodeClock({
    required _EpisodePair pair,
    required _MediaWinner winner,
  }) {
    final local = pair.localOriginal;
    final remote = pair.remote;
    if (local == null) {
      return _ExpectedRecordClock(
        hasVersion: remote!.hasVersion(),
        version: remote.version.toInt(),
        hasLastModifiedAt: remote.hasLastModifiedAt(),
        lastModifiedAt: remote.lastModifiedAt.toInt(),
      );
    }
    if (remote == null) {
      return _ExpectedRecordClock(
        hasVersion: local.hasVersion(),
        version: local.version.toInt(),
        hasLastModifiedAt: local.hasLastModifiedAt(),
        lastModifiedAt: local.lastModifiedAt.toInt(),
      );
    }
    final selected = winner == _MediaWinner.local ? local : remote;
    var hasVersion = selected.hasVersion();
    var version = selected.version.toInt();
    if (winner == _MediaWinner.local &&
        local.version == Int64.ZERO &&
        local.lastModifiedAt > remote.lastModifiedAt) {
      final promoted = _checkedNextVersion(
        local.version.toInt(),
        remote.version.toInt(),
      );
      if (promoted == null) return null;
      hasVersion = true;
      version = promoted;
    }
    return _ExpectedRecordClock(
      hasVersion: hasVersion,
      version: version,
      hasLastModifiedAt: selected.hasLastModifiedAt(),
      lastModifiedAt: selected.lastModifiedAt.toInt(),
    );
  }

  bool _chapterClockMatches(
    _ExpectedRecordClock expected,
    BackupChapter proposed,
  ) =>
      proposed.hasVersion() == expected.hasVersion &&
      proposed.version.toInt() == expected.version &&
      proposed.hasLastModifiedAt() == expected.hasLastModifiedAt &&
      proposed.lastModifiedAt.toInt() == expected.lastModifiedAt;

  bool _episodeClockMatches(
    _ExpectedRecordClock expected,
    BackupEpisode proposed,
  ) =>
      proposed.hasVersion() == expected.hasVersion &&
      proposed.version.toInt() == expected.version &&
      proposed.hasLastModifiedAt() == expected.hasLastModifiedAt &&
      proposed.lastModifiedAt.toInt() == expected.lastModifiedAt;

  void _auditHistory({
    required String parentKey,
    required Iterable<BackupHistory> baseline,
    required Iterable<BackupHistory> competing,
    required Iterable<BackupHistory> proposed,
    required bool baselineIsLocal,
    required bool remoteWinsTies,
    required List<String> missing,
    required List<String> clockRegressed,
    required List<String> valuesChanged,
    required List<String> unknownFieldsChanged,
  }) {
    final competingByUrl = _lastByKey(competing, (history) => history.url);
    final proposedByUrl = {
      for (final history in proposed) history.url: history,
    };
    for (final history in baseline) {
      final qualified = _join([parentKey, history.url]);
      final merged = proposedByUrl[history.url];
      if (merged == null) {
        missing.add(qualified);
        continue;
      }
      if (merged.lastRead < history.lastRead) {
        clockRegressed.add(qualified);
      }

      final competingHistory = competingByUrl[history.url];
      final localHistory = baselineIsLocal ? history : competingHistory;
      final remoteHistory = baselineIsLocal ? competingHistory : history;
      final winner = _historyWinner(
        local: localHistory,
        remote: remoteHistory,
        remoteWinsTies: remoteWinsTies,
      );
      final expected = _expectedHistoryProjection(
        winner: winner,
        local: localHistory,
        remote: remoteHistory,
      );
      if (!_sameKnownMessage(expected, merged, _clearHistoryUnknownFields)) {
        valuesChanged.add(qualified);
      }
      if (!_matchesAllowedUnknownEnvelope(
        proposed: merged,
        local: localHistory,
        remote: remoteHistory,
        allowedWinners: {winner},
      )) {
        unknownFieldsChanged.add(qualified);
      }
    }
  }

  void _auditTracking({
    required String parentKey,
    required int source,
    required String url,
    required Iterable<BackupTracking> local,
    required Iterable<BackupTracking> remote,
    required Iterable<BackupTracking> proposed,
    required Set<ChimahonTrackingDeletionKey> localTrackingDeletions,
    required _MediaWinner parentWinner,
    required List<String> missing,
    required List<String> valuesChanged,
    required List<String> unknownFieldsChanged,
  }) {
    final localBySyncId = _lastByKey(local, (row) => row.syncId);
    final remoteBySyncId = _lastByKey(remote, (row) => row.syncId);
    final proposedBySyncId = _lastByKey(proposed, (row) => row.syncId);
    final allSyncIds = {...localBySyncId.keys, ...remoteBySyncId.keys};
    final expectedBySyncId = <int, BackupTracking>{};
    for (final syncId in allSyncIds) {
      final expected = _expectedTrackingProjection(
        syncId: syncId,
        localBySyncId: localBySyncId,
        remoteBySyncId: remoteBySyncId,
        parentWinner: parentWinner,
        source: source,
        url: url,
        localTrackingDeletions: localTrackingDeletions,
      );
      if (expected != null) expectedBySyncId[syncId] = expected;
    }

    for (final syncId in {...allSyncIds, ...proposedBySyncId.keys}) {
      final qualified = _join([parentKey, syncId.toString()]);
      final expected = expectedBySyncId[syncId];
      final merged = proposedBySyncId[syncId];
      if (expected == null) {
        if (merged != null) valuesChanged.add(qualified);
        continue;
      }
      if (merged == null) {
        missing.add(qualified);
        continue;
      }
      if (!_sameKnownMessage(expected, merged, _clearTrackingUnknownFields)) {
        valuesChanged.add(qualified);
      }
      if (!sameBytes(
        _unknownEnvelopeBytes(expected),
        _unknownEnvelopeBytes(merged),
      )) {
        unknownFieldsChanged.add(qualified);
      }
    }
  }

  BackupTracking? _expectedTrackingProjection({
    required int syncId,
    required Map<int, BackupTracking> localBySyncId,
    required Map<int, BackupTracking> remoteBySyncId,
    required _MediaWinner parentWinner,
    required int source,
    required String url,
    required Set<ChimahonTrackingDeletionKey> localTrackingDeletions,
  }) {
    final explicitlyDeleted =
        _isPortableTrackingService(syncId) &&
        !localBySyncId.containsKey(syncId) &&
        localTrackingDeletions.contains((
          source: source,
          url: url,
          syncId: syncId,
        ));
    if (explicitlyDeleted) return null;

    final winnerBySyncId = parentWinner == _MediaWinner.local
        ? localBySyncId
        : remoteBySyncId;
    final loserBySyncId = parentWinner == _MediaWinner.local
        ? remoteBySyncId
        : localBySyncId;
    final selected = winnerBySyncId[syncId];
    final fallback = loserBySyncId[syncId];
    if (selected == null) {
      if (_isPortableTrackingService(syncId) &&
          parentWinner != _MediaWinner.local) {
        return null;
      }
      return fallback?.deepCopy();
    }
    if (fallback == null) return selected.deepCopy();

    final merged = selected.deepCopy()..unknownFields.clear();
    merged
      ..mergeUnknownFields(fallback.unknownFields)
      ..mergeUnknownFields(selected.unknownFields);
    if (parentWinner != _MediaWinner.local) return merged;

    if (!selected.hasLibraryId() && fallback.hasLibraryId()) {
      merged.libraryId = fallback.libraryId;
    }
    if (!selected.hasMediaIdInt() && fallback.hasMediaIdInt()) {
      merged.mediaIdInt = fallback.mediaIdInt;
    }
    if (!selected.hasTrackingUrl() && fallback.hasTrackingUrl()) {
      merged.trackingUrl = fallback.trackingUrl;
    }
    if (!selected.hasTitle() && fallback.hasTitle()) {
      merged.title = fallback.title;
    }
    if (!selected.hasLastChapterRead() && fallback.hasLastChapterRead()) {
      merged.lastChapterRead = fallback.lastChapterRead;
    } else if (selected.hasLastChapterRead() &&
        fallback.hasLastChapterRead() &&
        _isTruncatedProjection(
          selected.lastChapterRead,
          fallback.lastChapterRead,
        )) {
      merged.lastChapterRead = fallback.lastChapterRead;
    }
    if (!selected.hasTotalChapters() && fallback.hasTotalChapters()) {
      merged.totalChapters = fallback.totalChapters;
    }
    if (!selected.hasScore() && fallback.hasScore()) {
      merged.score = fallback.score;
    } else if (selected.hasScore() &&
        fallback.hasScore() &&
        _isTruncatedProjection(selected.score, fallback.score)) {
      merged.score = fallback.score;
    }
    if (!selected.hasStatus() && fallback.hasStatus()) {
      merged.status = fallback.status;
    }
    if (!selected.hasStartedReadingDate() && fallback.hasStartedReadingDate()) {
      merged.startedReadingDate = fallback.startedReadingDate;
    }
    if (!selected.hasFinishedReadingDate() &&
        fallback.hasFinishedReadingDate()) {
      merged.finishedReadingDate = fallback.finishedReadingDate;
    }
    if (!selected.hasPrivate() && fallback.hasPrivate()) {
      merged.private = fallback.private;
    }
    if (!selected.hasMediaId() && fallback.hasMediaId()) {
      merged.mediaId = fallback.mediaId;
    }
    return merged;
  }

  BackupTracking _clearTrackingUnknownFields(BackupTracking value) =>
      value.deepCopy()..unknownFields.clear();

  _MangaPair _pairManga({
    required BackupManga baseline,
    required bool baselineIsLocal,
    required Map<String, BackupManga> competingByKey,
    required Map<String, List<BackupManga>> baselineBySourceUrl,
    required Map<String, List<BackupManga>> competingBySourceUrl,
  }) {
    final exact = competingByKey[mangaIdentity(baseline)];
    if (exact != null) {
      return baselineIsLocal
          ? _MangaPair(
              baselineIsLocal: true,
              localOriginal: baseline,
              localCanonical: baseline,
              remote: exact,
            )
          : _MangaPair(
              baselineIsLocal: false,
              localOriginal: exact,
              localCanonical: exact,
              remote: baseline,
            );
    }

    final sourceUrlKey = mangaSourceUrlIdentity(baseline);
    final baselineCandidates = baselineBySourceUrl[sourceUrlKey];
    final competingCandidates = competingBySourceUrl[sourceUrlKey];
    if (baselineCandidates?.length == 1 && competingCandidates?.length == 1) {
      final candidate = competingCandidates!.single;
      final local = baselineIsLocal ? baseline : candidate;
      final remote = baselineIsLocal ? candidate : baseline;
      final rebased =
          ChimahonMediaParentProjectionProof.tryRebaseLocalMangaIdentity(
            localProjection: local,
            remote: remote,
            localSourceUrlIsUnique: true,
            remoteSourceUrlIsUnique: true,
          );
      if (rebased != null && mangaIdentity(rebased) == mangaIdentity(remote)) {
        return _MangaPair(
          baselineIsLocal: baselineIsLocal,
          localOriginal: local,
          localCanonical: rebased,
          remote: remote,
        );
      }
    }

    return baselineIsLocal
        ? _MangaPair(
            baselineIsLocal: true,
            localOriginal: baseline,
            localCanonical: baseline,
          )
        : _MangaPair(baselineIsLocal: false, remote: baseline);
  }

  _AnimePair _pairAnime({
    required BackupAnime baseline,
    required bool baselineIsLocal,
    required Map<String, BackupAnime> competingByKey,
    required Map<String, List<BackupAnime>> baselineBySourceUrl,
    required Map<String, List<BackupAnime>> competingBySourceUrl,
  }) {
    final exact = competingByKey[animeIdentity(baseline)];
    if (exact != null) {
      return baselineIsLocal
          ? _AnimePair(
              baselineIsLocal: true,
              localOriginal: baseline,
              localCanonical: baseline,
              remote: exact,
            )
          : _AnimePair(
              baselineIsLocal: false,
              localOriginal: exact,
              localCanonical: exact,
              remote: baseline,
            );
    }

    final sourceUrlKey = animeSourceUrlIdentity(baseline);
    final baselineCandidates = baselineBySourceUrl[sourceUrlKey];
    final competingCandidates = competingBySourceUrl[sourceUrlKey];
    if (baselineCandidates?.length == 1 && competingCandidates?.length == 1) {
      final candidate = competingCandidates!.single;
      final local = baselineIsLocal ? baseline : candidate;
      final remote = baselineIsLocal ? candidate : baseline;
      final rebased =
          ChimahonMediaParentProjectionProof.tryRebaseLocalAnimeIdentity(
            localProjection: local,
            remote: remote,
            localSourceUrlIsUnique: true,
            remoteSourceUrlIsUnique: true,
          );
      if (rebased != null && animeIdentity(rebased) == animeIdentity(remote)) {
        return _AnimePair(
          baselineIsLocal: baselineIsLocal,
          localOriginal: local,
          localCanonical: rebased,
          remote: remote,
        );
      }
    }

    return baselineIsLocal
        ? _AnimePair(
            baselineIsLocal: true,
            localOriginal: baseline,
            localCanonical: baseline,
          )
        : _AnimePair(baselineIsLocal: false, remote: baseline);
  }

  _ChapterPair _pairChapter({
    required BackupChapter baseline,
    required bool baselineIsLocal,
    required Map<String, List<BackupChapter>> competingByKey,
    required Map<String, List<BackupChapter>> baselineByUrl,
    required Map<String, List<BackupChapter>> competingByUrl,
  }) {
    final exactMatches = competingByKey[chapterIdentity(baseline)];
    if (exactMatches?.length == 1) {
      final exact = exactMatches!.single;
      return baselineIsLocal
          ? _ChapterPair(
              baselineIsLocal: true,
              localOriginal: baseline,
              localCanonical: baseline,
              remote: exact,
            )
          : _ChapterPair(
              baselineIsLocal: false,
              localOriginal: exact,
              localCanonical: exact,
              remote: baseline,
            );
    }

    if (baseline.url.isNotEmpty &&
        baselineByUrl[baseline.url]?.length == 1 &&
        competingByUrl[baseline.url]?.length == 1) {
      final candidate = competingByUrl[baseline.url]!.single;
      final local = baselineIsLocal ? baseline : candidate;
      final remote = baselineIsLocal ? candidate : baseline;
      final rebased =
          ChimahonMediaChildProjectionProof.rebaseLocalChapterIdentity(
            localProjection: local,
            remote: remote,
          );
      if (chapterIdentity(rebased) == chapterIdentity(remote)) {
        return _ChapterPair(
          baselineIsLocal: baselineIsLocal,
          localOriginal: local,
          localCanonical: rebased,
          remote: remote,
        );
      }
    }

    return baselineIsLocal
        ? _ChapterPair(
            baselineIsLocal: true,
            localOriginal: baseline,
            localCanonical: baseline,
          )
        : _ChapterPair(baselineIsLocal: false, remote: baseline);
  }

  _EpisodePair _pairEpisode({
    required BackupEpisode baseline,
    required bool baselineIsLocal,
    required Map<String, List<BackupEpisode>> competingByKey,
    required Map<String, List<BackupEpisode>> baselineByUrl,
    required Map<String, List<BackupEpisode>> competingByUrl,
  }) {
    final exactMatches = competingByKey[episodeIdentity(baseline)];
    if (exactMatches?.length == 1) {
      final exact = exactMatches!.single;
      return baselineIsLocal
          ? _EpisodePair(
              baselineIsLocal: true,
              localOriginal: baseline,
              localCanonical: baseline,
              remote: exact,
            )
          : _EpisodePair(
              baselineIsLocal: false,
              localOriginal: exact,
              localCanonical: exact,
              remote: baseline,
            );
    }

    if (baseline.url.isNotEmpty &&
        baselineByUrl[baseline.url]?.length == 1 &&
        competingByUrl[baseline.url]?.length == 1) {
      final candidate = competingByUrl[baseline.url]!.single;
      final local = baselineIsLocal ? baseline : candidate;
      final remote = baselineIsLocal ? candidate : baseline;
      final rebased =
          ChimahonMediaChildProjectionProof.rebaseLocalEpisodeIdentity(
            localProjection: local,
            remote: remote,
          );
      if (episodeIdentity(rebased) == episodeIdentity(remote)) {
        return _EpisodePair(
          baselineIsLocal: baselineIsLocal,
          localOriginal: local,
          localCanonical: rebased,
          remote: remote,
        );
      }
    }

    return baselineIsLocal
        ? _EpisodePair(
            baselineIsLocal: true,
            localOriginal: baseline,
            localCanonical: baseline,
          )
        : _EpisodePair(baselineIsLocal: false, remote: baseline);
  }

  Set<_MediaWinner> _allowedMangaWinners({
    required _MangaPair pair,
    required bool remoteWinsTies,
    required Set<ChimahonTrackingDeletionKey> localTrackingDeletions,
    required Iterable<BackupCategory> localCategories,
    required Iterable<BackupCategory> remoteCategories,
    required Iterable<BackupCategory> mergedCategories,
  }) {
    final winner = _recordWinner(
      localVersion: pair.localOriginal?.version.toInt(),
      localModifiedAt: pair.localOriginal?.lastModifiedAt.toInt(),
      remoteVersion: pair.remote?.version.toInt(),
      remoteModifiedAt: pair.remote?.lastModifiedAt.toInt(),
      remoteWinsTies: remoteWinsTies,
    );
    if (winner == _MediaWinner.local &&
        pair.remote != null &&
        remoteWinsTies &&
        pair.localOriginal!.version.toInt() == 0 &&
        pair.localOriginal!.lastModifiedAt > pair.remote!.lastModifiedAt &&
        !_hasPortableTrackingDeletion(
          localTrackingDeletions,
          source: pair.localOriginal!.source.toInt(),
          url: pair.localOriginal!.url,
        ) &&
        _mangaProjectionEquivalent(
          pair.localCanonical!,
          pair.remote!,
          localCategories: localCategories,
          remoteCategories: remoteCategories,
          mergedCategories: mergedCategories,
        )) {
      return const {_MediaWinner.remote};
    }
    return {winner};
  }

  Set<_MediaWinner> _allowedAnimeWinners({
    required _AnimePair pair,
    required bool remoteWinsTies,
    required Set<ChimahonTrackingDeletionKey> localTrackingDeletions,
    required Iterable<BackupCategory> localCategories,
    required Iterable<BackupCategory> remoteCategories,
    required Iterable<BackupCategory> mergedCategories,
  }) {
    final winner = _recordWinner(
      localVersion: pair.localOriginal?.version.toInt(),
      localModifiedAt: pair.localOriginal?.lastModifiedAt.toInt(),
      remoteVersion: pair.remote?.version.toInt(),
      remoteModifiedAt: pair.remote?.lastModifiedAt.toInt(),
      remoteWinsTies: remoteWinsTies,
    );
    if (winner == _MediaWinner.local &&
        pair.remote != null &&
        remoteWinsTies &&
        pair.localOriginal!.version.toInt() == 0 &&
        pair.localOriginal!.lastModifiedAt > pair.remote!.lastModifiedAt &&
        !_hasPortableTrackingDeletion(
          localTrackingDeletions,
          source: pair.localOriginal!.source.toInt(),
          url: pair.localOriginal!.url,
        ) &&
        _animeProjectionEquivalent(
          pair.localCanonical!,
          pair.remote!,
          localCategories: localCategories,
          remoteCategories: remoteCategories,
          mergedCategories: mergedCategories,
        )) {
      return const {_MediaWinner.remote};
    }
    return {winner};
  }

  Set<_MediaWinner> _allowedChapterWinners({
    required _ChapterPair pair,
    required bool remoteWinsTies,
  }) {
    final winner = _recordWinner(
      localVersion: pair.localOriginal?.version.toInt(),
      localModifiedAt: pair.localOriginal?.lastModifiedAt.toInt(),
      remoteVersion: pair.remote?.version.toInt(),
      remoteModifiedAt: pair.remote?.lastModifiedAt.toInt(),
      remoteWinsTies: remoteWinsTies,
    );
    if (winner == _MediaWinner.local &&
        pair.remote != null &&
        remoteWinsTies &&
        pair.localOriginal!.version.toInt() == 0 &&
        pair.localOriginal!.lastModifiedAt > pair.remote!.lastModifiedAt &&
        ChimahonMediaChildProjectionProof.chapterPortableValuesEqual(
          pair.localCanonical!,
          pair.remote!,
        )) {
      return const {_MediaWinner.remote};
    }
    return {winner};
  }

  Set<_MediaWinner> _allowedEpisodeWinners({
    required _EpisodePair pair,
    required bool remoteWinsTies,
  }) {
    final winner = _recordWinner(
      localVersion: pair.localOriginal?.version.toInt(),
      localModifiedAt: pair.localOriginal?.lastModifiedAt.toInt(),
      remoteVersion: pair.remote?.version.toInt(),
      remoteModifiedAt: pair.remote?.lastModifiedAt.toInt(),
      remoteWinsTies: remoteWinsTies,
    );
    if (winner == _MediaWinner.local &&
        pair.remote != null &&
        remoteWinsTies &&
        pair.localOriginal!.version.toInt() == 0 &&
        pair.localOriginal!.lastModifiedAt > pair.remote!.lastModifiedAt &&
        ChimahonMediaChildProjectionProof.episodePortableValuesEqual(
          pair.localCanonical!,
          pair.remote!,
        )) {
      return const {_MediaWinner.remote};
    }
    return {winner};
  }

  _MediaWinner _recordWinner({
    required int? localVersion,
    required int? localModifiedAt,
    required int? remoteVersion,
    required int? remoteModifiedAt,
    required bool remoteWinsTies,
  }) {
    if (localVersion == null) return _MediaWinner.remote;
    if (remoteVersion == null) return _MediaWinner.local;
    final localWins = _recordValuesWin(
      candidateVersion: localVersion,
      candidateModifiedAt: localModifiedAt!,
      baselineVersion: remoteVersion,
      baselineModifiedAt: remoteModifiedAt!,
      candidateWinsTie: !remoteWinsTies,
    );
    return localWins ? _MediaWinner.local : _MediaWinner.remote;
  }

  bool _matchesAnyMangaPortableProjection({
    required BackupManga proposed,
    required _MangaPair pair,
    required Set<_MediaWinner> allowedWinners,
  }) {
    final actual = _mangaPortableProjection(proposed).writeToBuffer();
    for (final winner in allowedWinners) {
      final expected = _expectedMangaProjection(pair, winner).writeToBuffer();
      if (sameBytes(actual, expected)) return true;
    }
    return false;
  }

  BackupManga _expectedMangaProjection(_MangaPair pair, _MediaWinner winner) {
    final selected = winner == _MediaWinner.local
        ? pair.localCanonical!
        : pair.remote!;
    final expected = selected.deepCopy();
    if (!expected.hasCustomTitle()) {
      if (pair.localCanonical?.hasCustomTitle() ?? false) {
        expected.customTitle = pair.localCanonical!.customTitle;
      } else if (pair.remote?.hasCustomTitle() ?? false) {
        expected.customTitle = pair.remote!.customTitle;
      }
    }
    final remote = pair.remote;
    if (remote != null && pair.localCanonical != null) {
      expected.excludedScanlators
        ..clear()
        ..addAll(remote.excludedScanlators);
      _copyOptionalInt(
        remote.hasViewer(),
        remote.viewer,
        (value) => expected.viewer = value,
        expected.clearViewer,
      );
      _copyOptionalInt(
        remote.hasChapterFlags(),
        remote.chapterFlags,
        (value) => expected.chapterFlags = value,
        expected.clearChapterFlags,
      );
      _copyOptionalInt(
        remote.hasUpdateStrategy(),
        remote.updateStrategy,
        (value) => expected.updateStrategy = value,
        expected.clearUpdateStrategy,
      );
      _copyOptionalString(
        remote.hasNotes(),
        remote.notes,
        (value) => expected.notes = value,
        expected.clearNotes,
      );
      _copyOptionalInt(
        remote.hasViewerFlags(),
        remote.viewerFlags,
        (value) => expected.viewerFlags = value,
        expected.clearViewerFlags,
      );
      _copyOptionalBool(
        remote.hasInitialized(),
        remote.initialized,
        (value) => expected.initialized = value,
        expected.clearInitialized,
      );
      _copyOptionalBytes(
        remote.hasMemo(),
        remote.memo,
        (value) => expected.memo = value,
        expected.clearMemo,
      );
    }
    return _mangaPortableProjection(expected);
  }

  BackupManga _mangaPortableProjection(BackupManga value) {
    final result = value.deepCopy()
      ..chapters.clear()
      ..categories.clear()
      ..tracking.clear()
      ..history.clear()
      ..clearFavorite()
      ..clearFavoriteModifiedAt()
      ..clearLastModifiedAt()
      ..clearVersion()
      ..unknownFields.clear();
    return result;
  }

  bool _matchesAnyAnimePortableProjection({
    required BackupAnime proposed,
    required _AnimePair pair,
    required Set<_MediaWinner> allowedWinners,
  }) {
    final actual = _animePortableProjection(proposed).writeToBuffer();
    for (final winner in allowedWinners) {
      final expected = _expectedAnimeProjection(pair, winner).writeToBuffer();
      if (sameBytes(actual, expected)) return true;
    }
    return false;
  }

  BackupAnime _expectedAnimeProjection(_AnimePair pair, _MediaWinner winner) {
    final selected = winner == _MediaWinner.local
        ? pair.localCanonical!
        : pair.remote!;
    final expected = selected.deepCopy();
    final remote = pair.remote;
    if (remote != null && pair.localCanonical != null) {
      expected.excludedScanlators
        ..clear()
        ..addAll(remote.excludedScanlators);
      _copyOptionalInt(
        remote.hasEpisodeFlags(),
        remote.episodeFlags,
        (value) => expected.episodeFlags = value,
        expected.clearEpisodeFlags,
      );
      _copyOptionalInt(
        remote.hasUpdateStrategy(),
        remote.updateStrategy,
        (value) => expected.updateStrategy = value,
        expected.clearUpdateStrategy,
      );
      if (!hasChimahonSeasonMetadata(pair.localCanonical!)) {
        _copyOptionalInt64(
          remote.hasSeasonFlags(),
          remote.seasonFlags,
          (value) => expected.seasonFlags = value,
          expected.clearSeasonFlags,
        );
        _copyOptionalDouble(
          remote.hasSeasonNumber(),
          remote.seasonNumber,
          (value) => expected.seasonNumber = value,
          expected.clearSeasonNumber,
        );
        _copyOptionalInt64(
          remote.hasSeasonSourceOrder(),
          remote.seasonSourceOrder,
          (value) => expected.seasonSourceOrder = value,
          expected.clearSeasonSourceOrder,
        );
        _copyOptionalInt(
          remote.hasFetchType(),
          remote.fetchType,
          (value) => expected.fetchType = value,
          expected.clearFetchType,
        );
      }
      _copyOptionalInt(
        remote.hasViewerFlags(),
        remote.viewerFlags,
        (value) => expected.viewerFlags = value,
        expected.clearViewerFlags,
      );
      if (!hasChimahonSeasonMetadata(pair.localCanonical!)) {
        _copyOptionalString(
          remote.hasBackgroundUrl(),
          remote.backgroundUrl,
          (value) => expected.backgroundUrl = value,
          expected.clearBackgroundUrl,
        );
        _copyOptionalInt64(
          remote.hasParentId(),
          remote.parentId,
          (value) => expected.parentId = value,
          expected.clearParentId,
        );
        _copyOptionalInt64(
          remote.hasId(),
          remote.id,
          (value) => expected.id = value,
          expected.clearId,
        );
      }
    }
    if (remote != null && pair.localCanonical != null) {
      retainAnimeSeasonProjectionGaps(expected, pair.localCanonical!, remote);
    }
    return _animePortableProjection(expected);
  }

  BackupAnime _animePortableProjection(BackupAnime value) {
    final result = value.deepCopy()
      ..episodes.clear()
      ..categories.clear()
      ..tracking.clear()
      ..history.clear()
      ..clearFavorite()
      ..clearFavoriteModifiedAt()
      ..clearLastModifiedAt()
      ..clearVersion()
      ..unknownFields.clear();
    return result;
  }

  bool _matchesAnyChapterPortableProjection({
    required BackupChapter proposed,
    required _ChapterPair pair,
    required Set<_MediaWinner> allowedWinners,
  }) {
    final actual = _chapterPortableProjection(proposed).writeToBuffer();
    for (final winner in allowedWinners) {
      final expected = _expectedChapterProjection(pair, winner).writeToBuffer();
      if (sameBytes(actual, expected)) return true;
    }
    return false;
  }

  BackupChapter _expectedChapterProjection(
    _ChapterPair pair,
    _MediaWinner winner,
  ) {
    final selected = winner == _MediaWinner.local
        ? pair.localCanonical!
        : pair.remote!;
    final expected = selected.deepCopy();
    if (winner == _MediaWinner.local && pair.remote != null) {
      final remote = pair.remote!;
      _copyOptionalInt64(
        remote.hasDateFetch(),
        remote.dateFetch,
        (value) => expected.dateFetch = value,
        expected.clearDateFetch,
      );
      _copyOptionalInt64(
        remote.hasSourceOrder(),
        remote.sourceOrder,
        (value) => expected.sourceOrder = value,
        expected.clearSourceOrder,
      );
      _copyOptionalBytes(
        remote.hasMemo(),
        remote.memo,
        (value) => expected.memo = value,
        expected.clearMemo,
      );
    }
    return _chapterPortableProjection(expected);
  }

  BackupChapter _chapterPortableProjection(BackupChapter value) =>
      value.deepCopy()
        ..clearLastModifiedAt()
        ..clearVersion()
        ..unknownFields.clear();

  bool _matchesAnyEpisodePortableProjection({
    required BackupEpisode proposed,
    required _EpisodePair pair,
    required Set<_MediaWinner> allowedWinners,
  }) {
    final actual = _episodePortableProjection(proposed).writeToBuffer();
    for (final winner in allowedWinners) {
      final expected = _expectedEpisodeProjection(pair, winner).writeToBuffer();
      if (sameBytes(actual, expected)) return true;
    }
    return false;
  }

  BackupEpisode _expectedEpisodeProjection(
    _EpisodePair pair,
    _MediaWinner winner,
  ) {
    final selected = winner == _MediaWinner.local
        ? pair.localCanonical!
        : pair.remote!;
    final expected = selected.deepCopy();
    if (winner == _MediaWinner.local && pair.remote != null) {
      final remote = pair.remote!;
      _copyOptionalInt64(
        remote.hasDateFetch(),
        remote.dateFetch,
        (value) => expected.dateFetch = value,
        expected.clearDateFetch,
      );
      _copyOptionalInt64(
        remote.hasSourceOrder(),
        remote.sourceOrder,
        (value) => expected.sourceOrder = value,
        expected.clearSourceOrder,
      );
      if (expected.totalSeconds.toInt() == 0) {
        _copyOptionalInt64(
          remote.hasTotalSeconds(),
          remote.totalSeconds,
          (value) => expected.totalSeconds = value,
          expected.clearTotalSeconds,
        );
      }
    }
    return _episodePortableProjection(expected);
  }

  BackupEpisode _episodePortableProjection(BackupEpisode value) =>
      value.deepCopy()
        ..clearLastModifiedAt()
        ..clearVersion()
        ..unknownFields.clear();

  bool _mangaProjectionEquivalent(
    BackupManga local,
    BackupManga remote, {
    required Iterable<BackupCategory> localCategories,
    required Iterable<BackupCategory> remoteCategories,
    required Iterable<BackupCategory> mergedCategories,
  }) =>
      local.source == remote.source &&
      local.url == remote.url &&
      local.title == remote.title &&
      local.artist == remote.artist &&
      local.author == remote.author &&
      local.description == remote.description &&
      _sameSet(local.genre, remote.genre) &&
      local.status == remote.status &&
      local.thumbnailUrl == remote.thumbnailUrl &&
      local.dateAdded == remote.dateAdded &&
      local.customTitle == remote.customTitle &&
      _sameSet(
        _expectedOrderedMemberships(
          memberships: local.categories,
          sourceCategories: localCategories,
          mergedCategories: mergedCategories,
        ),
        _expectedOrderedMemberships(
          memberships: remote.categories,
          sourceCategories: remoteCategories,
          mergedCategories: mergedCategories,
        ),
      ) &&
      _trackingProjectionEquals(local.tracking, remote.tracking);

  bool _animeProjectionEquivalent(
    BackupAnime local,
    BackupAnime remote, {
    required Iterable<BackupCategory> localCategories,
    required Iterable<BackupCategory> remoteCategories,
    required Iterable<BackupCategory> mergedCategories,
  }) =>
      animeSeasonProjectionEquals(local, remote) &&
      local.source == remote.source &&
      local.url == remote.url &&
      local.title == remote.title &&
      local.artist == remote.artist &&
      local.author == remote.author &&
      local.description == remote.description &&
      _sameSet(local.genre, remote.genre) &&
      local.status == remote.status &&
      local.thumbnailUrl == remote.thumbnailUrl &&
      local.dateAdded == remote.dateAdded &&
      _sameSet(
        _expectedOrderedMemberships(
          memberships: local.categories,
          sourceCategories: localCategories,
          mergedCategories: mergedCategories,
        ),
        _expectedOrderedMemberships(
          memberships: remote.categories,
          sourceCategories: remoteCategories,
          mergedCategories: mergedCategories,
        ),
      ) &&
      _trackingProjectionEquals(local.tracking, remote.tracking);

  bool _trackingProjectionEquals(
    Iterable<BackupTracking> local,
    Iterable<BackupTracking> remote,
  ) {
    final localBySyncId = _lastByKey(
      local.where((row) => _isPortableTrackingService(row.syncId)),
      (row) => row.syncId,
    );
    final remoteBySyncId = _lastByKey(
      remote.where((row) => _isPortableTrackingService(row.syncId)),
      (row) => row.syncId,
    );
    for (final entry in localBySyncId.entries) {
      final remoteRow = remoteBySyncId[entry.key];
      if (remoteRow == null ||
          !_trackingRowProjectionEquals(entry.value, remoteRow)) {
        return false;
      }
    }
    return true;
  }

  bool _trackingRowProjectionEquals(
    BackupTracking local,
    BackupTracking remote,
  ) =>
      local.status == remote.status &&
      _projectedInt64Equals(
        local.hasLibraryId(),
        local.libraryId,
        remote.hasLibraryId(),
        remote.libraryId,
      ) &&
      _projectedMediaIdEquals(local, remote) &&
      _projectedStringEquals(
        local.hasTrackingUrl(),
        local.trackingUrl,
        remote.hasTrackingUrl(),
        remote.trackingUrl,
      ) &&
      _projectedStringEquals(
        local.hasTitle(),
        local.title,
        remote.hasTitle(),
        remote.title,
      ) &&
      _projectedDoubleEquals(
        local.hasLastChapterRead(),
        local.lastChapterRead,
        remote.hasLastChapterRead(),
        remote.lastChapterRead,
        allowTruncatedRemote: true,
      ) &&
      _projectedIntEquals(
        local.hasTotalChapters(),
        local.totalChapters,
        remote.hasTotalChapters(),
        remote.totalChapters,
      ) &&
      _projectedDoubleEquals(
        local.hasScore(),
        local.score,
        remote.hasScore(),
        remote.score,
        allowTruncatedRemote: true,
      ) &&
      _projectedInt64Equals(
        local.hasStartedReadingDate(),
        local.startedReadingDate,
        remote.hasStartedReadingDate(),
        remote.startedReadingDate,
      ) &&
      _projectedInt64Equals(
        local.hasFinishedReadingDate(),
        local.finishedReadingDate,
        remote.hasFinishedReadingDate(),
        remote.finishedReadingDate,
      );

  bool _projectedMediaIdEquals(BackupTracking local, BackupTracking remote) {
    if (!local.hasMediaId()) return true;
    final remoteValue = remote.hasMediaId()
        ? remote.mediaId
        : remote.hasMediaIdInt() && remote.mediaIdInt != 0
        ? Int64(remote.mediaIdInt)
        : null;
    return remoteValue != null && local.mediaId == remoteValue;
  }

  bool _projectedStringEquals(
    bool localHasValue,
    String localValue,
    bool remoteHasValue,
    String remoteValue,
  ) => !localHasValue || (remoteHasValue && localValue == remoteValue);

  bool _projectedIntEquals(
    bool localHasValue,
    int localValue,
    bool remoteHasValue,
    int remoteValue,
  ) => !localHasValue || (remoteHasValue && localValue == remoteValue);

  bool _projectedInt64Equals(
    bool localHasValue,
    Int64 localValue,
    bool remoteHasValue,
    Int64 remoteValue,
  ) => !localHasValue || (remoteHasValue && localValue == remoteValue);

  bool _projectedDoubleEquals(
    bool localHasValue,
    double localValue,
    bool remoteHasValue,
    double remoteValue, {
    required bool allowTruncatedRemote,
  }) =>
      !localHasValue ||
      (remoteHasValue &&
          (localValue == remoteValue ||
              allowTruncatedRemote &&
                  _isTruncatedProjection(localValue, remoteValue)));

  bool _isTruncatedProjection(double projected, double exact) =>
      exact != exact.truncateToDouble() &&
      projected == exact.truncateToDouble();

  bool _hasPortableTrackingDeletion(
    Set<ChimahonTrackingDeletionKey> deletions, {
    required int source,
    required String url,
  }) => deletions.any(
    (deletion) =>
        deletion.source == source &&
        deletion.url == url &&
        _isPortableTrackingService(deletion.syncId),
  );

  _MediaWinner _historyWinner({
    required BackupHistory? local,
    required BackupHistory? remote,
    required bool remoteWinsTies,
  }) {
    if (local == null) return _MediaWinner.remote;
    if (remote == null) return _MediaWinner.local;
    if (local.lastRead != remote.lastRead) {
      return local.lastRead > remote.lastRead
          ? _MediaWinner.local
          : _MediaWinner.remote;
    }
    return remoteWinsTies ? _MediaWinner.remote : _MediaWinner.local;
  }

  BackupHistory _expectedHistoryProjection({
    required _MediaWinner winner,
    required BackupHistory? local,
    required BackupHistory? remote,
  }) {
    final expected = (winner == _MediaWinner.local ? local! : remote!)
        .deepCopy();
    if (winner == _MediaWinner.local &&
        remote != null &&
        local!.lastRead == remote.lastRead &&
        _isTruncatedMillisecondProjection(
          local.readDuration,
          remote.readDuration,
        )) {
      expected.readDuration = remote.readDuration;
    }
    return _clearHistoryUnknownFields(expected);
  }

  BackupHistory _clearHistoryUnknownFields(BackupHistory value) =>
      value.deepCopy()..unknownFields.clear();

  bool _isTruncatedMillisecondProjection(Int64 projected, Int64 exact) {
    final exactValue = exact.toInt();
    if (exactValue % 1000 == 0) return false;
    return projected.toInt() == (exactValue ~/ 1000) * 1000;
  }

  bool _matchesAllowedUnknownEnvelope({
    required GeneratedMessage proposed,
    required GeneratedMessage? local,
    required GeneratedMessage? remote,
    required Set<_MediaWinner> allowedWinners,
  }) {
    for (final winner in allowedWinners) {
      final winning = winner == _MediaWinner.local ? local : remote;
      final losing = winner == _MediaWinner.local ? remote : local;
      if (winning == null) continue;
      if (_unknownEnvelopeMatches(
        proposed: proposed,
        winner: winning,
        loser: losing,
      )) {
        return true;
      }
    }
    return false;
  }

  bool _unknownEnvelopeMatches({
    required GeneratedMessage proposed,
    required GeneratedMessage winner,
    required GeneratedMessage? loser,
  }) {
    if (ChimahonUnknownFieldSafety.missingOrReorderedTags(
      baseline: winner,
      target: proposed,
    ).isNotEmpty) {
      return false;
    }
    if (loser != null &&
        ChimahonUnknownFieldSafety.missingOrReorderedTags(
          baseline: loser,
          target: proposed,
        ).isNotEmpty) {
      return false;
    }
    final expected = winner.createEmptyInstance();
    if (loser != null) expected.mergeUnknownFields(loser.unknownFields);
    expected.mergeUnknownFields(winner.unknownFields);
    return sameBytes(
      _unknownEnvelopeBytes(expected),
      _unknownEnvelopeBytes(proposed),
    );
  }

  List<int> _unknownEnvelopeBytes(GeneratedMessage value) {
    final envelope = value.createEmptyInstance()
      ..mergeUnknownFields(value.unknownFields);
    return envelope.writeToBuffer();
  }

  bool _sameKnownMessage<T extends GeneratedMessage>(
    T expected,
    T actual,
    T Function(T) withoutUnknownFields,
  ) => sameBytes(
    withoutUnknownFields(expected).writeToBuffer(),
    withoutUnknownFields(actual).writeToBuffer(),
  );

  bool _sameList<T>(List<T> left, List<T> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  bool _sameSet<T>(Iterable<T> left, Iterable<T> right) {
    final leftSet = left.toSet();
    final rightSet = right.toSet();
    return leftSet.length == rightSet.length && leftSet.containsAll(rightSet);
  }

  void _copyOptionalInt(
    bool present,
    int value,
    void Function(int) set,
    void Function() clear,
  ) => present ? set(value) : clear();

  void _copyOptionalInt64(
    bool present,
    Int64 value,
    void Function(Int64) set,
    void Function() clear,
  ) => present ? set(value) : clear();

  void _copyOptionalDouble(
    bool present,
    double value,
    void Function(double) set,
    void Function() clear,
  ) => present ? set(value) : clear();

  void _copyOptionalString(
    bool present,
    String value,
    void Function(String) set,
    void Function() clear,
  ) => present ? set(value) : clear();

  void _copyOptionalBool(
    bool present,
    bool value,
    void Function(bool) set,
    void Function() clear,
  ) => present ? set(value) : clear();

  void _copyOptionalBytes(
    bool present,
    List<int> value,
    void Function(List<int>) set,
    void Function() clear,
  ) => present ? set(List<int>.of(value)) : clear();

  void _auditMembership({
    required String parentKey,
    required Iterable<Int64> sourceOrders,
    required Iterable<BackupCategory> sourceCategories,
    required Iterable<BackupCategory> mergedCategories,
    required Iterable<Int64> proposedOrders,
    required List<String> changed,
  }) {
    final expected = _expectedOrderedMemberships(
      memberships: sourceOrders,
      sourceCategories: sourceCategories,
      mergedCategories: mergedCategories,
    );
    final actual = proposedOrders.toList(growable: false);
    if (!_sameList(expected, actual)) {
      changed.add(parentKey);
    }
  }

  List<Int64> _expectedOrderedMemberships({
    required Iterable<Int64> memberships,
    required Iterable<BackupCategory> sourceCategories,
    required Iterable<BackupCategory> mergedCategories,
  }) {
    final sourceList = sourceCategories.toList(growable: false);
    final mergedList = mergedCategories.toList(growable: false);
    final sourceByOrder = {
      for (final category in sourceList) category.order.toInt(): category,
    };
    final sourceCountByNormalizedName = <String, int>{};
    for (final category in sourceList) {
      final key = _normalized(category.name);
      sourceCountByNormalizedName[key] =
          (sourceCountByNormalizedName[key] ?? 0) + 1;
    }
    final mergedByExactName = {
      for (final category in mergedList) category.name: category,
    };
    final mergedByNormalizedName = <String, List<BackupCategory>>{};
    for (final category in mergedList) {
      mergedByNormalizedName
          .putIfAbsent(_normalized(category.name), () => <BackupCategory>[])
          .add(category);
    }

    final result = <Int64>[];
    final seen = <Int64>{};
    for (final membership in memberships) {
      final source = sourceByOrder[membership.toInt()];
      if (source == null) continue;
      final normalizedName = _normalized(source.name);
      final normalizedMatches =
          mergedByNormalizedName[normalizedName] ?? const <BackupCategory>[];
      final sourceIsAmbiguousProjection =
          sourceCountByNormalizedName[normalizedName] == 1 &&
          normalizedMatches.length > 1;
      final targets = sourceIsAmbiguousProjection
          ? normalizedMatches
          : [mergedByExactName[source.name]].nonNulls;
      for (final target in targets) {
        if (seen.add(target.order)) result.add(target.order);
      }
    }
    return result;
  }

  void _auditOrderedCategoryPayload({
    required String media,
    required Iterable<BackupCategory> local,
    required Iterable<BackupCategory> remote,
    required Iterable<BackupCategory> proposed,
    required void Function(String, Iterable<String>) fail,
  }) {
    final localList = local.toList(growable: false);
    final remoteList = remote.toList(growable: false);
    final proposedList = proposed.toList(growable: false);
    fail(
      'local_${media}_category_duplicate_exact_name',
      _duplicateSurplus(localList.map((category) => category.name)),
    );
    fail(
      'remote_${media}_category_duplicate_exact_name',
      _duplicateSurplus(remoteList.map((category) => category.name)),
    );
    fail(
      'proposed_${media}_category_duplicate_exact_name',
      _duplicateSurplus(proposedList.map((category) => category.name)),
    );

    final expected = _expectedOrderedCategories(
      local: localList,
      remote: remoteList,
    );
    final expectedByName = _lastByKey(expected, (category) => category.name);
    final proposedByName = _lastByKey(
      proposedList,
      (category) => category.name,
    );
    fail(
      '${media}_category_missing_from_proposed',
      expectedByName.keys.where((name) => !proposedByName.containsKey(name)),
    );
    fail(
      '${media}_category_extra_in_proposed',
      proposedByName.keys.where((name) => !expectedByName.containsKey(name)),
    );

    final expectedNames = expected.map((category) => category.name).toList();
    final proposedNames = proposedList
        .map((category) => category.name)
        .toList();
    if (!_sameList(expectedNames, proposedNames)) {
      fail('${media}_category_wire_order_changed', [
        ...expectedNames,
        ...proposedNames,
      ]);
    }

    final changedValues = <String>[];
    final changedUnknownFields = <String>[];
    for (final entry in expectedByName.entries) {
      final candidate = proposedByName[entry.key];
      if (candidate == null) continue;
      if (!_sameKnownMessage(
        entry.value,
        candidate,
        _clearCategoryUnknownFields,
      )) {
        changedValues.add(entry.key);
      }
      if (!sameBytes(
        _unknownEnvelopeBytes(entry.value),
        _unknownEnvelopeBytes(candidate),
      )) {
        changedUnknownFields.add(entry.key);
      }
    }
    fail('${media}_category_portable_values_changed', changedValues);
    fail('${media}_category_unknown_fields_not_retained', changedUnknownFields);
  }

  List<BackupCategory> _expectedOrderedCategories({
    required List<BackupCategory> local,
    required List<BackupCategory> remote,
  }) {
    final remoteExactNamesByNormalizedName = <String, Set<String>>{};
    for (final category in remote) {
      remoteExactNamesByNormalizedName
          .putIfAbsent(_normalized(category.name), () => <String>{})
          .add(category.name);
    }
    final categoriesByName = <String, BackupCategory>{};
    final localNames = <String>[];
    final remoteNames = <String>[];

    void add(BackupCategory category, {required bool isRemote}) {
      final name = category.name;
      if (!isRemote &&
          (remoteExactNamesByNormalizedName[_normalized(name)]?.length ?? 0) >
              1) {
        return;
      }
      final names = isRemote ? remoteNames : localNames;
      if (!names.contains(name)) names.add(name);
      final existing = categoriesByName[name];
      if (existing == null) {
        categoriesByName[name] = category.deepCopy();
        return;
      }

      final categoryWins = category.order >= existing.order;
      final winner = categoryWins ? category : existing;
      final loser = categoryWins ? existing : category;
      final merged = winner.deepCopy()..unknownFields.clear();
      merged
        ..mergeUnknownFields(loser.unknownFields)
        ..mergeUnknownFields(winner.unknownFields);
      if (category.hasId()) merged.id = category.id;
      if (category.hasFlags()) merged.flags = category.flags;
      categoriesByName[name] = merged;
    }

    for (final category in local) {
      add(category, isRemote: false);
    }
    for (final category in remote) {
      add(category, isRemote: true);
    }

    final orderedNames = <String>[];
    for (final name in [...remoteNames, ...localNames]) {
      if (!orderedNames.contains(name)) orderedNames.add(name);
    }
    final remoteNameSet = remoteNames.toSet();
    final usedOrders = <Int64>{
      for (final name in orderedNames)
        if (remoteNameSet.contains(name)) categoriesByName[name]!.order,
    };
    var nextFreeOrder = Int64.ZERO;
    final result = <BackupCategory>[];
    for (final name in orderedNames) {
      final category = categoriesByName[name]!;
      if (remoteNameSet.contains(name) || usedOrders.add(category.order)) {
        result.add(category);
        continue;
      }
      while (usedOrders.contains(nextFreeOrder)) {
        nextFreeOrder += 1;
      }
      final reallocated = category.deepCopy()..order = nextFreeOrder;
      usedOrders.add(nextFreeOrder);
      result.add(reallocated);
    }
    return result;
  }

  BackupCategory _clearCategoryUnknownFields(BackupCategory value) =>
      value.deepCopy()..unknownFields.clear();

  Set<_FavoriteFailure> _favoriteTransitionFailures({
    required _FavoriteSnapshot baseline,
    required _FavoriteSnapshot? expected,
    required _FavoriteSnapshot proposed,
  }) {
    final failures = <_FavoriteFailure>{};
    if (baseline.isTombstone && !baseline.hasPositiveClock) {
      final preservedLegacyTombstone =
          proposed.hasFavoriteField == baseline.hasFavoriteField &&
          proposed.favorite == baseline.favorite &&
          proposed.modifiedAt == baseline.modifiedAt;
      if (!preservedLegacyTombstone) {
        failures
          ..add(_FavoriteFailure.tombstoneClockMissing)
          ..add(_FavoriteFailure.tombstoneNotPreserved);
        if (proposed.semanticFavorite) {
          failures.add(_FavoriteFailure.invalidTombstoneResurrection);
        }
      }
    }
    if (expected == null) {
      failures.add(_FavoriteFailure.favoriteClockRegressed);
      return failures;
    }

    final stateOrSpellingChanged =
        proposed.hasFavoriteField != expected.hasFavoriteField ||
        proposed.favorite != expected.favorite;
    final clockChanged = proposed.modifiedAt != expected.modifiedAt;
    if (baseline.isTombstone &&
        proposed.semanticFavorite &&
        (stateOrSpellingChanged || clockChanged)) {
      failures.add(_FavoriteFailure.invalidTombstoneResurrection);
    }
    if (stateOrSpellingChanged) {
      if (expected.isAbsent) {
        failures.add(_FavoriteFailure.favoriteAbsenceNotPreserved);
      } else if (expected.isTombstone && proposed.semanticFavorite) {
        failures.add(_FavoriteFailure.invalidTombstoneResurrection);
      } else {
        failures.add(_FavoriteFailure.favoriteStateNotPreserved);
      }
    }
    if (clockChanged) {
      failures.add(
        expected.isTombstone
            ? _FavoriteFailure.tombstoneNotPreserved
            : _FavoriteFailure.favoriteClockRegressed,
      );
    }
    return failures;
  }

  _ExpectedParentProjection? _expectedParentProjection({
    required _FavoriteSnapshot? local,
    required _FavoriteSnapshot? remote,
    required _MediaWinner parentWinner,
  }) {
    if (local == null) {
      return _ExpectedParentProjection.fromSnapshot(remote!);
    }
    if (remote == null) {
      return _ExpectedParentProjection.fromSnapshot(local);
    }

    final selected = parentWinner == _MediaWinner.local ? local : remote;
    var hasVersion = selected.hasVersion;
    var version = selected.version;
    var hasLastModifiedAt = selected.hasLastModifiedAt;
    var lastModifiedAt = selected.lastModifiedAt;
    if (parentWinner == _MediaWinner.local &&
        local.version == 0 &&
        local.lastModifiedAt > remote.lastModifiedAt) {
      final promoted = _checkedNextVersion(local.version, remote.version);
      if (promoted == null) return null;
      hasVersion = true;
      version = promoted;
    }

    final favoriteWinner = _favoriteWinner(
      local: local,
      remote: remote,
      parentWinner: parentWinner,
    );
    if (favoriteWinner == null) {
      final favorite = !remote.hasFavoriteField
          ? _FavoriteSnapshot.favoriteOnly(
              hasFavoriteField: false,
              favorite: true,
              modifiedAt: null,
            )
          : _FavoriteSnapshot.favoriteOnly(
              hasFavoriteField: selected.hasFavoriteField,
              favorite: selected.favorite,
              modifiedAt: null,
            );
      return _ExpectedParentProjection(
        favorite: favorite,
        hasVersion: hasVersion,
        version: version,
        hasLastModifiedAt: hasLastModifiedAt,
        lastModifiedAt: lastModifiedAt,
      );
    }

    final favoriteSide = favoriteWinner == _MediaWinner.local ? local : remote;
    final favoriteOverridesRecord =
        favoriteWinner != parentWinner &&
        (favoriteSide.semanticFavorite != selected.semanticFavorite ||
            selected.modifiedAt == null ||
            favoriteSide.modifiedAt != selected.modifiedAt);
    if (favoriteOverridesRecord) {
      final promoted = _checkedNextVersion(local.version, remote.version);
      if (promoted == null) return null;
      hasVersion = true;
      version = promoted;
    }
    if (lastModifiedAt < favoriteSide.modifiedAt!) {
      hasLastModifiedAt = true;
      lastModifiedAt = favoriteSide.modifiedAt!;
    }
    final semanticFavorite = favoriteSide.semanticFavorite;
    final favorite = _FavoriteSnapshot.favoriteOnly(
      hasFavoriteField: !(semanticFavorite && !remote.hasFavoriteField),
      favorite: semanticFavorite,
      modifiedAt: favoriteSide.modifiedAt,
    );
    return _ExpectedParentProjection(
      favorite: favorite,
      hasVersion: hasVersion,
      version: version,
      hasLastModifiedAt: hasLastModifiedAt,
      lastModifiedAt: lastModifiedAt,
    );
  }

  _MediaWinner? _favoriteWinner({
    required _FavoriteSnapshot local,
    required _FavoriteSnapshot remote,
    required _MediaWinner parentWinner,
  }) {
    if (local.modifiedAt == null && remote.modifiedAt == null) return null;
    if (local.modifiedAt != null && remote.modifiedAt == null) {
      return _MediaWinner.local;
    }
    if (local.modifiedAt == null) return _MediaWinner.remote;
    if (local.modifiedAt != remote.modifiedAt) {
      return local.modifiedAt! > remote.modifiedAt!
          ? _MediaWinner.local
          : _MediaWinner.remote;
    }
    return parentWinner;
  }

  bool _recordClockMatches({
    required _ExpectedParentProjection expected,
    required _FavoriteSnapshot proposed,
  }) =>
      proposed.hasVersion == expected.hasVersion &&
      proposed.version == expected.version &&
      proposed.hasLastModifiedAt == expected.hasLastModifiedAt &&
      proposed.lastModifiedAt == expected.lastModifiedAt;

  int? _checkedNextVersion(int left, int right) {
    final latest = left >= right ? left : right;
    if (latest == Int64.MAX_VALUE.toInt()) return null;
    return latest + 1;
  }

  void _emitFavoriteFailures({
    required String label,
    required String media,
    required Map<_FavoriteFailure, List<String>> failures,
    required void Function(String, Iterable<String>) fail,
  }) {
    for (final entry in failures.entries) {
      final code = label == 'remote' && media == 'manga'
          ? switch (entry.key) {
              _FavoriteFailure.tombstoneClockMissing =>
                'remote_tombstone_deletion_clock_missing',
              _FavoriteFailure.tombstoneNotPreserved =>
                'remote_tombstone_not_preserved',
              _FavoriteFailure.favoriteAbsenceNotPreserved =>
                'remote_favorite_absence_not_preserved',
              _FavoriteFailure.invalidTombstoneResurrection =>
                'invalid_tombstone_resurrection',
              _FavoriteFailure.favoriteClockRegressed =>
                'remote_manga_favorite_clock_regressed',
              _FavoriteFailure.favoriteStateNotPreserved =>
                'remote_manga_favorite_state_not_preserved',
            }
          : switch (entry.key) {
              _FavoriteFailure.tombstoneClockMissing =>
                '${label}_${media}_tombstone_deletion_clock_missing',
              _FavoriteFailure.tombstoneNotPreserved =>
                '${label}_${media}_tombstone_not_preserved',
              _FavoriteFailure.favoriteAbsenceNotPreserved =>
                '${label}_${media}_favorite_absence_not_preserved',
              _FavoriteFailure.invalidTombstoneResurrection =>
                '${label}_${media}_invalid_tombstone_resurrection',
              _FavoriteFailure.favoriteClockRegressed =>
                '${label}_${media}_favorite_clock_regressed',
              _FavoriteFailure.favoriteStateNotPreserved =>
                '${label}_${media}_favorite_state_not_preserved',
            };
      fail(code, entry.value);
    }
  }

  static bool _recordStrictlyNewer(
    BackupManga candidate,
    BackupManga baseline,
  ) => _recordValuesStrictlyNewer(
    candidateVersion: candidate.version.toInt(),
    candidateModifiedAt: candidate.lastModifiedAt.toInt(),
    baselineVersion: baseline.version.toInt(),
    baselineModifiedAt: baseline.lastModifiedAt.toInt(),
  );

  static bool _recordValuesStrictlyNewer({
    required int candidateVersion,
    required int candidateModifiedAt,
    required int baselineVersion,
    required int baselineModifiedAt,
  }) => _recordValuesWin(
    candidateVersion: candidateVersion,
    candidateModifiedAt: candidateModifiedAt,
    baselineVersion: baselineVersion,
    baselineModifiedAt: baselineModifiedAt,
    candidateWinsTie: false,
  );

  /// Mirrors the merger's record winner rule. The caller supplies the exact
  /// tie authority used for this merge attempt.
  static bool _recordValuesWin({
    required int candidateVersion,
    required int candidateModifiedAt,
    required int baselineVersion,
    required int baselineModifiedAt,
    required bool candidateWinsTie,
  }) {
    final candidateIsVersioned = candidateVersion != 0;
    final baselineIsVersioned = baselineVersion != 0;
    if (candidateIsVersioned && baselineIsVersioned) {
      if (candidateVersion != baselineVersion) {
        return candidateVersion > baselineVersion;
      }
      return candidateWinsTie;
    }
    if (candidateModifiedAt != baselineModifiedAt) {
      return candidateModifiedAt > baselineModifiedAt;
    }
    if (candidateIsVersioned != baselineIsVersioned) {
      return candidateIsVersioned;
    }
    return candidateWinsTie;
  }

  static bool _isPortableTrackingService(int syncId) =>
      syncId == 1 || syncId == 2 || syncId == 3;

  static Map<K, T> _lastByKey<T, K>(Iterable<T> values, K Function(T) keyOf) =>
      {for (final value in values) keyOf(value): value};

  static Map<K, List<T>> _groupByKey<T, K>(
    Iterable<T> values,
    K Function(T) keyOf,
  ) {
    final result = <K, List<T>>{};
    for (final value in values) {
      result.putIfAbsent(keyOf(value), () => []).add(value);
    }
    return result;
  }

  static List<String> _duplicateSurplus(Iterable<String> values) {
    final seen = <String>{};
    final duplicates = <String>[];
    for (final value in values) {
      if (!seen.add(value)) duplicates.add(value);
    }
    return duplicates;
  }

  static String mangaIdentity(BackupManga manga) =>
      chimahonMangaIdentity(manga);

  static String mangaSourceUrlIdentity(BackupManga manga) => _join([
    manga.hasSource() ? manga.source.toString() : 'source-absent',
    manga.url,
  ]);

  static String animeIdentity(BackupAnime anime) =>
      chimahonAnimeIdentity(anime);

  static String animeSourceUrlIdentity(BackupAnime anime) => _join([
    anime.hasSource() ? anime.source.toString() : 'source-absent',
    anime.url,
  ]);

  static String chapterIdentity(BackupChapter chapter) =>
      chimahonChapterIdentity(chapter);

  static String episodeIdentity(BackupEpisode episode) =>
      chimahonEpisodeIdentity(episode);

  static String _rawChapterIdentity(BackupChapter chapter) =>
      _join([chapter.url, chapter.name, chapter.chapterNumber.toString()]);

  static String _rawEpisodeIdentity(BackupEpisode episode) =>
      _join([episode.url, episode.name, episode.episodeNumber.toString()]);

  static String _normalized(String value) => value.trim().toLowerCase();

  static String _join(Iterable<String> values) =>
      values.map((value) => '${utf8.encode(value).length}:$value').join();
}

enum _MediaWinner { local, remote }

class _MangaPair {
  const _MangaPair({
    required this.baselineIsLocal,
    this.localOriginal,
    this.localCanonical,
    this.remote,
  });

  final bool baselineIsLocal;
  final BackupManga? localOriginal;
  final BackupManga? localCanonical;
  final BackupManga? remote;

  BackupManga get canonicalBaseline =>
      baselineIsLocal ? localCanonical! : remote!;

  BackupManga? get competingForBaseline =>
      baselineIsLocal ? remote : localOriginal;
}

class _AnimePair {
  const _AnimePair({
    required this.baselineIsLocal,
    this.localOriginal,
    this.localCanonical,
    this.remote,
  });

  final bool baselineIsLocal;
  final BackupAnime? localOriginal;
  final BackupAnime? localCanonical;
  final BackupAnime? remote;

  BackupAnime get canonicalBaseline =>
      baselineIsLocal ? localCanonical! : remote!;

  BackupAnime? get competingForBaseline =>
      baselineIsLocal ? remote : localOriginal;
}

class _ChapterPair {
  const _ChapterPair({
    required this.baselineIsLocal,
    this.localOriginal,
    this.localCanonical,
    this.remote,
  });

  final bool baselineIsLocal;
  final BackupChapter? localOriginal;
  final BackupChapter? localCanonical;
  final BackupChapter? remote;

  BackupChapter get canonicalBaseline =>
      baselineIsLocal ? localCanonical! : remote!;
}

class _EpisodePair {
  const _EpisodePair({
    required this.baselineIsLocal,
    this.localOriginal,
    this.localCanonical,
    this.remote,
  });

  final bool baselineIsLocal;
  final BackupEpisode? localOriginal;
  final BackupEpisode? localCanonical;
  final BackupEpisode? remote;

  BackupEpisode get canonicalBaseline =>
      baselineIsLocal ? localCanonical! : remote!;
}

class _MangaIdentityBucket {
  const _MangaIdentityBucket({
    this.localOriginal,
    this.localCanonical,
    this.remote,
  });

  final BackupManga? localOriginal;
  final BackupManga? localCanonical;
  final BackupManga? remote;

  _MangaIdentityBucket withLocal(BackupManga original, BackupManga canonical) =>
      _MangaIdentityBucket(
        localOriginal: original,
        localCanonical: canonical,
        remote: remote,
      );
}

class _AnimeIdentityBucket {
  const _AnimeIdentityBucket({
    this.localOriginal,
    this.localCanonical,
    this.remote,
  });

  final BackupAnime? localOriginal;
  final BackupAnime? localCanonical;
  final BackupAnime? remote;

  _AnimeIdentityBucket withLocal(BackupAnime original, BackupAnime canonical) =>
      _AnimeIdentityBucket(
        localOriginal: original,
        localCanonical: canonical,
        remote: remote,
      );
}

enum _FavoriteFailure {
  tombstoneClockMissing,
  tombstoneNotPreserved,
  favoriteAbsenceNotPreserved,
  invalidTombstoneResurrection,
  favoriteClockRegressed,
  favoriteStateNotPreserved,
}

class _FavoriteSnapshot {
  const _FavoriteSnapshot({
    required this.hasFavoriteField,
    required this.favorite,
    required this.modifiedAt,
    required this.hasVersion,
    required this.version,
    required this.hasLastModifiedAt,
    required this.lastModifiedAt,
  });

  const _FavoriteSnapshot.favoriteOnly({
    required this.hasFavoriteField,
    required this.favorite,
    required this.modifiedAt,
  }) : hasVersion = false,
       version = 0,
       hasLastModifiedAt = false,
       lastModifiedAt = 0;

  factory _FavoriteSnapshot.manga(BackupManga manga) => _FavoriteSnapshot(
    hasFavoriteField: manga.hasFavorite(),
    favorite: manga.hasFavorite() ? manga.favorite : true,
    modifiedAt: manga.hasFavoriteModifiedAt()
        ? manga.favoriteModifiedAt.toInt()
        : null,
    hasVersion: manga.hasVersion(),
    version: manga.version.toInt(),
    hasLastModifiedAt: manga.hasLastModifiedAt(),
    lastModifiedAt: manga.lastModifiedAt.toInt(),
  );

  factory _FavoriteSnapshot.anime(BackupAnime anime) => _FavoriteSnapshot(
    hasFavoriteField: anime.hasFavorite(),
    favorite: anime.hasFavorite() ? anime.favorite : true,
    modifiedAt: anime.hasFavoriteModifiedAt()
        ? anime.favoriteModifiedAt.toInt()
        : null,
    hasVersion: anime.hasVersion(),
    version: anime.version.toInt(),
    hasLastModifiedAt: anime.hasLastModifiedAt(),
    lastModifiedAt: anime.lastModifiedAt.toInt(),
  );

  final bool hasFavoriteField;
  final bool favorite;
  final int? modifiedAt;
  final bool hasVersion;
  final int version;
  final bool hasLastModifiedAt;
  final int lastModifiedAt;

  bool get semanticFavorite => !hasFavoriteField || favorite;
  bool get isAbsent => !hasFavoriteField;
  bool get isTombstone => hasFavoriteField && !favorite;
  bool get hasPositiveClock => modifiedAt != null && modifiedAt! > 0;
}

class _ExpectedParentProjection {
  const _ExpectedParentProjection({
    required this.favorite,
    required this.hasVersion,
    required this.version,
    required this.hasLastModifiedAt,
    required this.lastModifiedAt,
  });

  factory _ExpectedParentProjection.fromSnapshot(_FavoriteSnapshot value) =>
      _ExpectedParentProjection(
        favorite: _FavoriteSnapshot.favoriteOnly(
          hasFavoriteField: value.hasFavoriteField,
          favorite: value.favorite,
          modifiedAt: value.modifiedAt,
        ),
        hasVersion: value.hasVersion,
        version: value.version,
        hasLastModifiedAt: value.hasLastModifiedAt,
        lastModifiedAt: value.lastModifiedAt,
      );

  final _FavoriteSnapshot favorite;
  final bool hasVersion;
  final int version;
  final bool hasLastModifiedAt;
  final int lastModifiedAt;
}

class _ExpectedRecordClock {
  const _ExpectedRecordClock({
    required this.hasVersion,
    required this.version,
    required this.hasLastModifiedAt,
    required this.lastModifiedAt,
  });

  final bool hasVersion;
  final int version;
  final bool hasLastModifiedAt;
  final int lastModifiedAt;
}
