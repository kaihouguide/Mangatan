import 'dart:convert';
import 'dart:math' as math;

import 'package:mangayomi/services/sync/chimahon_anime_seasons.dart';
import 'package:crypto/crypto.dart';
import 'package:fixnum/fixnum.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupAnime.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupCategory.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupChapter.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupEpisode.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupExtensionRepos.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupExtensionStore.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupFeed.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupHistory.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupManga.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupNovel.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupPreference.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupSavedSearch.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupSearchHistory.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupSource.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupTracking.pb.dart';
import 'package:mangayomi/services/sync/chimahon_anime_repo_identity.dart';
import 'package:mangayomi/services/sync/chimahon_category_payload_adapter.dart';
import 'package:mangayomi/services/sync/chimahon_child_identity.dart';
import 'package:mangayomi/services/sync/chimahon_feed_identity.dart';
import 'package:mangayomi/services/sync/chimahon_media_child_projection_proof.dart';
import 'package:mangayomi/services/sync/chimahon_media_parent_projection_proof.dart';
import 'package:mangayomi/services/sync/chimahon_media_identity.dart';
import 'package:mangayomi/services/sync/chimahon_stats_row_merge.dart';
import 'package:protobuf/protobuf.dart';

typedef ChimahonTrackingDeletionKey = ({int source, String url, int syncId});

/// Conflict resolution compatible with Komikku's version-based sync, with
/// lossless handling for Chimahon's novel, statistics, and preference fields.
class ChimahonSyncMerger {
  const ChimahonSyncMerger({
    this.categoryPayloadAdapter = const ChimahonCategoryPayloadAdapter(),
  });

  /// Dedicated lossless boundary for the three media category payloads.
  final ChimahonCategoryPayloadAdapter categoryPayloadAdapter;

  static const _uncategorizedNovelCategoryId = 'default';

  BackupMihon merge({
    required BackupMihon local,
    required BackupMihon remote,
    Set<ChimahonTrackingDeletionKey> localTrackingDeletions = const {},
    bool remoteWinsRecordTies = false,
    bool remoteWinsProjectionTies = false,
  }) {
    // Routine sync compares a lossy database projection with the exact bytes
    // already in Drive. An equal clock is therefore evidence of no local edit,
    // and retaining the remote spelling avoids manufacturing field presence,
    // version increments, or a second normalization upload. Explicit pending
    // restore intent deliberately leaves [remoteWinsProjectionTies] disabled.
    final remoteWinsTie = remoteWinsRecordTies || remoteWinsProjectionTies;
    final leftWinsTie = !remoteWinsTie;
    final localProjectionRules = !remoteWinsRecordTies;
    final categoryPayload = categoryPayloadAdapter.merge(
      local: local,
      remote: remote,
    );
    final categories = categoryPayload.manga;
    final animeCategories = categoryPayload.anime;
    final novelCategories = categoryPayload.novel;

    final merged = BackupMihon(
      backupManga: _mergeManga(
        local.backupManga,
        remote.backupManga,
        local.backupCategories,
        remote.backupCategories,
        categories,
        localTrackingDeletions,
        leftWinsTie,
        localProjectionRules,
      ),
      backupCategories: categories,
      backupSources: _mergeByKey<BackupSource, int>(
        local.backupSources,
        remote.backupSources,
        (source) => source.sourceId.toInt(),
        remoteWins: remoteWinsTie,
      ),
      // Remote wins preference conflicts. This prevents a fresh target device's
      // defaults from erasing Chimahon's filled dictionary/Anki fields.
      backupPreferences: _mergePreferences(
        local.backupPreferences,
        remote.backupPreferences,
      ),
      backupSourcePreferences: _mergeSourcePreferences(
        local.backupSourcePreferences,
        remote.backupSourcePreferences,
      ),
      backupExtensionStores: _mergeByKey<BackupExtensionStore, String>(
        local.backupExtensionStores,
        remote.backupExtensionStores,
        (store) => store.indexUrl,
        remoteWins: remoteWinsTie,
      ),
      backupAnime: _mergeAnime(
        local.backupAnime,
        remote.backupAnime,
        local.backupAnimeCategories,
        remote.backupAnimeCategories,
        animeCategories,
        localTrackingDeletions,
        leftWinsTie,
        localProjectionRules,
      ),
      backupAnimeCategories: animeCategories,
      backupAnimeSources: _mergeByKey<BackupSource, int>(
        local.backupAnimeSources,
        remote.backupAnimeSources,
        (source) => source.sourceId.toInt(),
        remoteWins: remoteWinsTie,
      ),
      backupAnimeExtensionRepo: _mergeByKey<BackupExtensionRepos, String>(
        local.backupAnimeExtensionRepo,
        remote.backupAnimeExtensionRepo,
        chimahonAnimeRepositoryIdentity,
        remoteWins: remoteWinsTie,
      ),
      backupSavedSearches: _mergeByKey<BackupSavedSearch, String>(
        local.backupSavedSearches,
        remote.backupSavedSearches,
        (search) => '${search.source}|${_normalized(search.name)}',
        remoteWins: remoteWinsTie,
      ),
      backupFeeds: _mergeByKey<BackupFeed, String>(
        local.backupFeeds,
        remote.backupFeeds,
        ChimahonFeedIdentity.key,
        remoteWins: remoteWinsTie,
        mergeDuplicate: _mergeFeed,
      ),
      backupSearchHistory: _mergeByKey<BackupSearchHistory, String>(
        local.backupSearchHistory,
        remote.backupSearchHistory,
        (entry) => '${entry.scope}\u0000${entry.query}',
        remoteWins: remoteWinsTie,
      ),
      backupNovels: _mergeNovels(
        local.backupNovels,
        remote.backupNovels,
        local.backupNovelCategories,
        remote.backupNovelCategories,
        novelCategories,
        leftWinsTie,
      ),
      backupNovelCategories: novelCategories,
      backupMangaStats: ChimahonStatsRowMerge.mangaStats(
        local.backupMangaStats,
        remote.backupMangaStats,
      ),
      backupAnkiStats: ChimahonStatsRowMerge.ankiStats(
        local.backupAnkiStats,
        remote.backupAnkiStats,
      ),
    );

    // A newer fork can add fields without Mangatan having to understand them.
    // Prefer the remote representation for shared unknown tags, while retaining
    // local-only tags.
    merged.mergeUnknownFields(remote.unknownFields);
    for (final entry in local.unknownFields.asMap().entries) {
      if (!remote.unknownFields.hasField(entry.key)) {
        merged.unknownFields.mergeField(entry.key, entry.value);
      }
    }
    return merged;
  }

  List<BackupManga> _mergeManga(
    Iterable<BackupManga> local,
    Iterable<BackupManga> remote,
    Iterable<BackupCategory> localCategories,
    Iterable<BackupCategory> remoteCategories,
    Iterable<BackupCategory> mergedCategories,
    Set<ChimahonTrackingDeletionKey> localTrackingDeletions,
    bool leftWinsTie,
    bool localProjectionRules,
  ) {
    final remoteManga = remote.toList(growable: false);
    final localManga = localProjectionRules
        ? _rebaseLegacyLocalMangaIdentity(local, remoteManga)
        : local;
    final localCategoryMapper = _OrderedCategoryMembershipMapper(
      localCategories,
      mergedCategories,
    );
    final remoteCategoryMapper = _OrderedCategoryMembershipMapper(
      remoteCategories,
      mergedCategories,
    );
    final localByKey = _lastByKey<BackupManga, String>(
      localManga.map(
        (manga) => _remapMangaCategories(manga, localCategoryMapper),
      ),
      _mangaKey,
    );
    final remoteByKey = _lastByKey<BackupManga, String>(
      remoteManga.map(
        (manga) => _remapMangaCategories(manga, remoteCategoryMapper),
      ),
      _mangaKey,
    );
    // Keep existing remote identities in their current wire order. Newly
    // created local identities are appended. This makes an import followed by
    // an unchanged projection byte-stable instead of reordering the payload as
    // more remote records become locally representable.
    return _orderedKeys(remoteByKey, localByKey).map((key) {
      final left = localByKey[key];
      final right = remoteByKey[key];
      if (left == null) return right!.deepCopy();
      if (right == null) return left.deepCopy();
      if (_canCopyExactManga(left, right)) return right.deepCopy();
      var leftWins = _recordLeftWins(
        left.version,
        left.lastModifiedAt,
        right.version,
        right.lastModifiedAt,
        leftWinsTie: leftWinsTie,
      );
      if (_shouldRetainExactRemoteProjection(
        localVersion: left.version,
        localModified: left.lastModifiedAt,
        remoteModified: right.lastModifiedAt,
        leftWinsTie: leftWinsTie,
        localProjectionRules: localProjectionRules,
        portableValuesAreEqual: () =>
            !_hasPortableTrackingDeletion(
              localTrackingDeletions,
              source: left.source.toInt(),
              url: left.url,
            ) &&
            _mangaProjectionEquals(left, right),
      )) {
        leftWins = false;
      }
      final latest = leftWins ? left : right;
      final fallback = leftWins ? right : left;
      final merged = _copyWithMergedUnknownFields(latest, fallback)
        ..chapters.clear()
        ..chapters.addAll(
          _mergeChapters(
            left.chapters,
            right.chapters,
            leftWinsTie: leftWinsTie,
            localProjectionRules: localProjectionRules,
          ),
        )
        ..history.clear()
        ..history.addAll(
          _mergeHistory(left.history, right.history, leftWinsTie: leftWinsTie),
        );
      merged.tracking
        ..clear()
        ..addAll(
          _copyWinnerTrackingWithUnknownFields(
            latest.tracking,
            fallback.tracking,
            localTracking: left.tracking,
            winnerIsLocal: localProjectionRules && leftWins,
            source: left.source.toInt(),
            url: left.url,
            localTrackingDeletions: localTrackingDeletions,
          ),
        );
      if (localProjectionRules &&
          leftWins &&
          left.version == Int64.ZERO &&
          left.lastModifiedAt > right.lastModifiedAt) {
        merged.version = _nextVersion(left.version, right.version);
      }
      if (localProjectionRules) {
        _repairLegacyLocalMangaTitle(
          merged: merged,
          local: left,
          remote: right,
          localWins: leftWins,
        );
        _preserveCustomMangaTitle(merged, left, right);
        _preserveRemoteOnlyMangaFields(merged, right);
      }
      _mergeMangaFavorite(
        merged: merged,
        left: left,
        right: right,
        latestWasLeft: leftWins,
      );
      return merged;
    }).toList();
  }

  /// Rebase an unversioned row by source+URL only when its relationship to the
  /// remote row is independently provable. This covers an imported unfavorite
  /// tombstone (whose metadata is intentionally not restored) and the old
  /// Mangatan title projection where field 3 exactly matches Chimahon's field
  /// 800. A general source metadata refresh is a new Chimahon wire identity and
  /// must not be collapsed merely because the URL is shared.
  Iterable<BackupManga> _rebaseLegacyLocalMangaIdentity(
    Iterable<BackupManga> local,
    Iterable<BackupManga> remote,
  ) sync* {
    final localManga = local.toList(growable: false);
    final remoteBySourceUrl = <String, List<BackupManga>>{};
    for (final manga in remote) {
      remoteBySourceUrl
          .putIfAbsent(_mangaSourceUrlKey(manga), () => <BackupManga>[])
          .add(manga);
    }
    final localBySourceUrl = <String, List<BackupManga>>{};
    for (final manga in localManga) {
      localBySourceUrl
          .putIfAbsent(_mangaSourceUrlKey(manga), () => <BackupManga>[])
          .add(manga);
    }
    for (final manga in localManga) {
      if (manga.version != Int64.ZERO) {
        yield manga;
        continue;
      }
      final sourceUrlKey = _mangaSourceUrlKey(manga);
      final matches = remoteBySourceUrl[sourceUrlKey];
      if (matches == null || matches.length != 1) {
        yield manga;
        continue;
      }
      final remoteManga = matches.single;
      if (_mangaKey(manga) == _mangaKey(remoteManga)) {
        yield manga;
        continue;
      }
      yield ChimahonMediaParentProjectionProof.tryRebaseLocalMangaIdentity(
            localProjection: manga,
            remote: remoteManga,
            localSourceUrlIsUnique: localBySourceUrl[sourceUrlKey]?.length == 1,
            remoteSourceUrlIsUnique: matches.length == 1,
          ) ??
          manga;
    }
  }

  void _mergeMangaFavorite({
    required BackupManga merged,
    required BackupManga left,
    required BackupManga right,
    required bool latestWasLeft,
  }) {
    final favoriteWinner = _favoriteWinner(
      leftHasTimestamp: left.hasFavoriteModifiedAt(),
      leftTimestamp: left.favoriteModifiedAt,
      rightHasTimestamp: right.hasFavoriteModifiedAt(),
      rightTimestamp: right.favoriteModifiedAt,
      leftWinsTie: latestWasLeft,
    );
    if (favoriteWinner == null) {
      // Chimahon's Kotlin model defaults `favorite` to true, so its canonical
      // protobuf representation of a favorite omits field 100. Do not turn a
      // remote absent=true value into an explicit true merely because the
      // Mangatan projection won an otherwise clockless record tie.
      if (!right.hasFavorite()) merged.clearFavorite();
      return;
    }
    final winner = favoriteWinner ? left : right;
    final latest = latestWasLeft ? left : right;
    final winnerFavorite = winner.hasFavorite() ? winner.favorite : true;
    final latestFavorite = latest.hasFavorite() ? latest.favorite : true;
    final favoriteOverridesLatest =
        favoriteWinner != latestWasLeft &&
        (winnerFavorite != latestFavorite ||
            !latest.hasFavoriteModifiedAt() ||
            winner.favoriteModifiedAt != latest.favoriteModifiedAt);
    if (winnerFavorite && !right.hasFavorite()) {
      // Absence is Chimahon's wire spelling of true. Preserve it even when a
      // newer local favorite clock wins; the timestamp still carries the real
      // local transition without manufacturing a different field presence.
      merged.clearFavorite();
    } else {
      merged.favorite = winnerFavorite;
    }
    merged.favoriteModifiedAt = winner.favoriteModifiedAt;
    if (favoriteOverridesLatest) {
      merged.version = _nextVersion(left.version, right.version);
    }
    if (merged.lastModifiedAt < winner.favoriteModifiedAt) {
      merged.lastModifiedAt = winner.favoriteModifiedAt;
    }
  }

  /// Repairs the same demonstrable legacy field-3 projection when normalized
  /// composite keys already matched without the source+URL rebaser.
  void _repairLegacyLocalMangaTitle({
    required BackupManga merged,
    required BackupManga local,
    required BackupManga remote,
    required bool localWins,
  }) {
    if (!localWins ||
        local.hasCustomTitle() ||
        !remote.hasCustomTitle() ||
        local.title != remote.customTitle ||
        _mangaAuthorKey(local) != _mangaAuthorKey(remote) ||
        remote.title.trim().isEmpty ||
        local.title == remote.title) {
      return;
    }
    merged.title = remote.title;
    merged.customTitle = remote.customTitle;
  }

  /// A Mangatan source refresh advances the parent metadata clock without
  /// changing its display title. On first contact that unversioned projection
  /// must not erase Chimahon's independent field-800 title override merely
  /// because the refresh happened later. Likewise, a remote metadata refresh
  /// must not erase a real Mangatan override.
  ///
  /// Chimahon itself has no title-specific deletion clock, and an absent
  /// field does not clear an existing CustomMangaInfo row during restore. Keep
  /// the fallback override whenever the general record winner has none.
  void _preserveCustomMangaTitle(
    BackupManga merged,
    BackupManga local,
    BackupManga remote,
  ) {
    if (merged.hasCustomTitle()) return;
    if (local.hasCustomTitle()) {
      merged.customTitle = local.customTitle;
    } else if (remote.hasCustomTitle()) {
      merged.customTitle = remote.customTitle;
    }
  }

  /// Mangatan has no local model for these Chimahon options. The remote copy
  /// is therefore authoritative even when locally represented metadata wins.
  void _preserveRemoteOnlyMangaFields(BackupManga merged, BackupManga remote) {
    merged.excludedScanlators
      ..clear()
      ..addAll(remote.excludedScanlators);
    if (remote.hasViewer()) {
      merged.viewer = remote.viewer;
    } else {
      merged.clearViewer();
    }
    if (remote.hasChapterFlags()) {
      merged.chapterFlags = remote.chapterFlags;
    } else {
      merged.clearChapterFlags();
    }
    if (remote.hasUpdateStrategy()) {
      merged.updateStrategy = remote.updateStrategy;
    } else {
      merged.clearUpdateStrategy();
    }
    if (remote.hasNotes()) {
      merged.notes = remote.notes;
    } else {
      merged.clearNotes();
    }
    if (remote.hasViewerFlags()) {
      merged.viewerFlags = remote.viewerFlags;
    } else {
      merged.clearViewerFlags();
    }
    if (remote.hasInitialized()) {
      merged.initialized = remote.initialized;
    } else {
      merged.clearInitialized();
    }
    if (remote.hasMemo()) {
      merged.memo = remote.memo;
    } else {
      merged.clearMemo();
    }
  }

  BackupManga _remapMangaCategories(
    BackupManga manga,
    _OrderedCategoryMembershipMapper mapper,
  ) {
    final remapped = mapper.map(manga.categories);
    if (_sameValues(manga.categories, remapped)) return manga;
    final result = manga.deepCopy()
      ..categories.clear()
      ..categories.addAll(remapped);
    return result;
  }

  List<BackupChapter> _mergeChapters(
    Iterable<BackupChapter> local,
    Iterable<BackupChapter> remote, {
    required bool leftWinsTie,
    required bool localProjectionRules,
  }) {
    final remoteList = canonicalizeChimahonChapters(
      remote,
      normalizeNumbers: false,
    );
    final canonicalLocal = canonicalizeChimahonChapters(local);
    final localList = localProjectionRules
        ? _rebaseLocalChapterIdentity(canonicalLocal, remoteList)
        : canonicalLocal;
    final localByKey = _lastByKey<BackupChapter, String>(
      localList,
      _chapterKey,
    );
    final remoteByKey = _lastByKey<BackupChapter, String>(
      remoteList,
      _chapterKey,
    );
    return _orderedKeys(remoteByKey, localByKey).map((key) {
      final left = localByKey[key];
      final right = remoteByKey[key];
      if (left == null) return right!.deepCopy();
      if (right == null) return left.deepCopy();
      var leftWins = _recordLeftWins(
        left.version,
        left.lastModifiedAt,
        right.version,
        right.lastModifiedAt,
        leftWinsTie: leftWinsTie,
      );
      if (_shouldRetainExactRemoteProjection(
        localVersion: left.version,
        localModified: left.lastModifiedAt,
        remoteModified: right.lastModifiedAt,
        leftWinsTie: leftWinsTie,
        localProjectionRules: localProjectionRules,
        portableValuesAreEqual: () =>
            ChimahonMediaChildProjectionProof.chapterPortableValuesEqual(
              left,
              right,
            ),
      )) {
        leftWins = false;
      }
      final latest = _copyWithMergedUnknownFields(
        leftWins ? left : right,
        leftWins ? right : left,
      );
      if (localProjectionRules &&
          leftWins &&
          left.version == Int64.ZERO &&
          left.lastModifiedAt > right.lastModifiedAt) {
        latest.version = _nextVersion(left.version, right.version);
      }
      if (localProjectionRules && leftWins) {
        // Neither value is represented by Mangatan's Chapter model.
        if (right.hasDateFetch()) {
          latest.dateFetch = right.dateFetch;
        } else {
          latest.clearDateFetch();
        }
        if (right.hasSourceOrder()) {
          latest.sourceOrder = right.sourceOrder;
        } else {
          latest.clearSourceOrder();
        }
        if (right.hasMemo()) {
          latest.memo = right.memo;
        } else {
          latest.clearMemo();
        }
        if (left.name == right.name &&
            left.chapterNumber != right.chapterNumber) {
          // Legacy Mangatan exports reparsed the final number in the name.
          if (right.hasChapterNumber()) {
            latest.chapterNumber = right.chapterNumber;
          } else {
            latest.clearChapterNumber();
          }
        }
      }
      return latest;
    }).toList();
  }

  List<BackupChapter> _rebaseLocalChapterIdentity(
    Iterable<BackupChapter> local,
    Iterable<BackupChapter> remote,
  ) {
    final localList = local.toList(growable: false);
    final localByUrl = <String, List<BackupChapter>>{};
    for (final chapter in localList) {
      if (chapter.url.isEmpty) continue;
      localByUrl.putIfAbsent(chapter.url, () => <BackupChapter>[]).add(chapter);
    }
    final remoteByUrl = <String, List<BackupChapter>>{};
    for (final chapter in remote) {
      if (chapter.url.isEmpty) continue;
      remoteByUrl
          .putIfAbsent(chapter.url, () => <BackupChapter>[])
          .add(chapter);
    }
    final result = <BackupChapter>[];
    for (final chapter in localList) {
      final matches = remoteByUrl[chapter.url];
      if (chapter.version != Int64.ZERO ||
          chapter.url.isEmpty ||
          localByUrl[chapter.url]?.length != 1 ||
          matches?.length != 1) {
        result.add(chapter);
        continue;
      }
      final remoteChapter = matches!.single;
      result.add(
        ChimahonMediaChildProjectionProof.rebaseLocalChapterIdentity(
          localProjection: chapter,
          remote: remoteChapter,
        ),
      );
    }
    return result;
  }

  List<BackupHistory> _mergeHistory(
    Iterable<BackupHistory> local,
    Iterable<BackupHistory> remote, {
    required bool leftWinsTie,
  }) {
    final localByUrl = _lastByKey<BackupHistory, String>(
      local,
      (item) => item.url,
    );
    final remoteByUrl = _lastByKey<BackupHistory, String>(
      remote,
      (item) => item.url,
    );
    return _orderedKeys(remoteByUrl, localByUrl).map((key) {
      final left = localByUrl[key];
      final right = remoteByUrl[key];
      if (left == null) return right!.deepCopy();
      if (right == null) return left.deepCopy();
      final leftWins =
          left.lastRead > right.lastRead ||
          (left.lastRead == right.lastRead && leftWinsTie);
      final merged = _copyWithMergedUnknownFields(
        leftWins ? left : right,
        leftWins ? right : left,
      );
      if (leftWins &&
          left.lastRead == right.lastRead &&
          _isTruncatedMillisecondProjection(
            left.readDuration,
            right.readDuration,
          )) {
        // Mangatan stores whole seconds. Keep Chimahon's exact millisecond
        // duration when the local value is demonstrably its lossy projection.
        merged.readDuration = right.readDuration;
      }
      return merged;
    }).toList();
  }

  List<BackupAnime> _mergeAnime(
    Iterable<BackupAnime> local,
    Iterable<BackupAnime> remote,
    Iterable<BackupCategory> localCategories,
    Iterable<BackupCategory> remoteCategories,
    Iterable<BackupCategory> mergedCategories,
    Set<ChimahonTrackingDeletionKey> localTrackingDeletions,
    bool leftWinsTie,
    bool localProjectionRules,
  ) {
    BackupAnime remap(
      BackupAnime anime,
      _OrderedCategoryMembershipMapper mapper,
    ) {
      final remapped = mapper.map(anime.categories);
      if (_sameValues(anime.categories, remapped)) return anime;
      final result = anime.deepCopy()
        ..categories.clear()
        ..categories.addAll(remapped);
      return result;
    }

    final remoteRows = remote.toList(growable: false);
    final localRows = localProjectionRules
        ? _rebaseLegacyLocalAnimeIdentity(local, remoteRows)
        : local;
    final namespace = ChimahonSeasonNamespace(localRows, remoteRows);
    final localAnime = namespace.local;
    final remoteAnime = namespace.remote;
    BackupAnime withRelationshipId(BackupAnime anime) {
      final result = anime.deepCopy();
      namespace.assignId(result);
      return result;
    }

    final localCategoryMapper = _OrderedCategoryMembershipMapper(
      localCategories,
      mergedCategories,
    );
    final remoteCategoryMapper = _OrderedCategoryMembershipMapper(
      remoteCategories,
      mergedCategories,
    );
    final localByKey = _lastByKey<BackupAnime, String>(
      localAnime.map((anime) => remap(anime, localCategoryMapper)),
      _animeKey,
    );
    final remoteByKey = _lastByKey<BackupAnime, String>(
      remoteAnime.map((anime) => remap(anime, remoteCategoryMapper)),
      _animeKey,
    );
    return _orderedKeys(remoteByKey, localByKey).map((key) {
      final left = localByKey[key];
      final right = remoteByKey[key];
      if (left == null) return right!.deepCopy();
      if (right == null) return left.deepCopy();
      if (_canCopyExactAnime(left, right)) return withRelationshipId(right);
      var leftWins = _recordLeftWins(
        left.version,
        left.lastModifiedAt,
        right.version,
        right.lastModifiedAt,
        leftWinsTie: leftWinsTie,
      );
      if (_shouldRetainExactRemoteProjection(
        localVersion: left.version,
        localModified: left.lastModifiedAt,
        remoteModified: right.lastModifiedAt,
        leftWinsTie: leftWinsTie,
        localProjectionRules: localProjectionRules,
        portableValuesAreEqual: () =>
            !_hasPortableTrackingDeletion(
              localTrackingDeletions,
              source: left.source.toInt(),
              url: left.url,
            ) &&
            _animeProjectionEquals(left, right),
      )) {
        leftWins = false;
      }
      final latest = leftWins ? left : right;
      final fallback = leftWins ? right : left;
      final merged = _copyWithMergedUnknownFields(latest, fallback)
        ..episodes.clear()
        ..episodes.addAll(
          _mergeEpisodes(
            left.episodes,
            right.episodes,
            leftWinsTie: leftWinsTie,
            localProjectionRules: localProjectionRules,
          ),
        )
        ..history.clear()
        ..history.addAll(
          _mergeHistory(left.history, right.history, leftWinsTie: leftWinsTie),
        );
      merged.tracking
        ..clear()
        ..addAll(
          _copyWinnerTrackingWithUnknownFields(
            latest.tracking,
            fallback.tracking,
            localTracking: left.tracking,
            winnerIsLocal: localProjectionRules && leftWins,
            source: left.source.toInt(),
            url: left.url,
            localTrackingDeletions: localTrackingDeletions,
          ),
        );
      if (localProjectionRules &&
          leftWins &&
          left.version == Int64.ZERO &&
          left.lastModifiedAt > right.lastModifiedAt) {
        merged.version = _nextVersion(left.version, right.version);
      }
      if (localProjectionRules) {
        _preserveRemoteOnlyAnimeFields(merged, right, left);
        retainAnimeSeasonProjectionGaps(merged, left, right);
      }
      _mergeAnimeFavorite(
        merged: merged,
        left: left,
        right: right,
        latestWasLeft: leftWins,
      );
      namespace.assignId(merged);
      return merged;
    }).toList();
  }

  /// The importer may match a cached anime tombstone by a unique source+URL
  /// even when stale title/author metadata differs. Rebase only when the two
  /// explicit nonfavorite rows carry the same favorite-state clock. A regular
  /// anime metadata refresh is a distinct Chimahon identity.
  Iterable<BackupAnime> _rebaseLegacyLocalAnimeIdentity(
    Iterable<BackupAnime> local,
    Iterable<BackupAnime> remote,
  ) sync* {
    final localAnime = local.toList(growable: false);
    final remoteBySourceUrl = <String, List<BackupAnime>>{};
    for (final anime in remote) {
      remoteBySourceUrl
          .putIfAbsent(_animeSourceUrlKey(anime), () => <BackupAnime>[])
          .add(anime);
    }
    final localBySourceUrl = <String, List<BackupAnime>>{};
    for (final anime in localAnime) {
      localBySourceUrl
          .putIfAbsent(_animeSourceUrlKey(anime), () => <BackupAnime>[])
          .add(anime);
    }
    for (final anime in localAnime) {
      if (anime.version != Int64.ZERO) {
        yield anime;
        continue;
      }
      final sourceUrlKey = _animeSourceUrlKey(anime);
      final matches = remoteBySourceUrl[sourceUrlKey];
      if (matches == null || matches.length != 1) {
        yield anime;
        continue;
      }
      final remoteAnime = matches.single;
      if (_animeKey(anime) == _animeKey(remoteAnime)) {
        yield anime;
        continue;
      }
      yield ChimahonMediaParentProjectionProof.tryRebaseLocalAnimeIdentity(
            localProjection: anime,
            remote: remoteAnime,
            localSourceUrlIsUnique: localBySourceUrl[sourceUrlKey]?.length == 1,
            remoteSourceUrlIsUnique: matches.length == 1,
          ) ??
          anime;
    }
  }

  List<BackupEpisode> _mergeEpisodes(
    Iterable<BackupEpisode> local,
    Iterable<BackupEpisode> remote, {
    required bool leftWinsTie,
    required bool localProjectionRules,
  }) {
    final remoteList = canonicalizeChimahonEpisodes(
      remote,
      normalizeNumbers: false,
    );
    final canonicalLocal = canonicalizeChimahonEpisodes(local);
    final localList = localProjectionRules
        ? _rebaseLocalEpisodeIdentity(canonicalLocal, remoteList)
        : canonicalLocal;
    final localByKey = _lastByKey<BackupEpisode, String>(
      localList,
      _episodeKey,
    );
    final remoteByKey = _lastByKey<BackupEpisode, String>(
      remoteList,
      _episodeKey,
    );
    return _orderedKeys(remoteByKey, localByKey).map((key) {
      final left = localByKey[key];
      final right = remoteByKey[key];
      if (left == null) return right!.deepCopy();
      if (right == null) return left.deepCopy();
      var leftWins = _recordLeftWins(
        left.version,
        left.lastModifiedAt,
        right.version,
        right.lastModifiedAt,
        leftWinsTie: leftWinsTie,
      );
      if (_shouldRetainExactRemoteProjection(
        localVersion: left.version,
        localModified: left.lastModifiedAt,
        remoteModified: right.lastModifiedAt,
        leftWinsTie: leftWinsTie,
        localProjectionRules: localProjectionRules,
        portableValuesAreEqual: () =>
            ChimahonMediaChildProjectionProof.episodePortableValuesEqual(
              left,
              right,
            ),
      )) {
        leftWins = false;
      }
      final merged = _copyWithMergedUnknownFields(
        leftWins ? left : right,
        leftWins ? right : left,
      );
      if (localProjectionRules &&
          leftWins &&
          left.version == Int64.ZERO &&
          left.lastModifiedAt > right.lastModifiedAt) {
        merged.version = _nextVersion(left.version, right.version);
      }
      if (localProjectionRules && leftWins) {
        // These values are not represented losslessly by Mangatan.
        if (right.hasDateFetch()) {
          merged.dateFetch = right.dateFetch;
        } else {
          merged.clearDateFetch();
        }
        if (right.hasSourceOrder()) {
          merged.sourceOrder = right.sourceOrder;
        } else {
          merged.clearSourceOrder();
        }
        if (left.name == right.name &&
            left.episodeNumber != right.episodeNumber) {
          if (right.hasEpisodeNumber()) {
            merged.episodeNumber = right.episodeNumber;
          } else {
            merged.clearEpisodeNumber();
          }
        }
        if (left.totalSeconds == Int64.ZERO) {
          if (right.hasTotalSeconds()) {
            merged.totalSeconds = right.totalSeconds;
          } else {
            merged.clearTotalSeconds();
          }
        }
      }
      return merged;
    }).toList();
  }

  List<BackupEpisode> _rebaseLocalEpisodeIdentity(
    Iterable<BackupEpisode> local,
    Iterable<BackupEpisode> remote,
  ) {
    final localList = local.toList(growable: false);
    final localByUrl = <String, List<BackupEpisode>>{};
    for (final episode in localList) {
      if (episode.url.isEmpty) continue;
      localByUrl.putIfAbsent(episode.url, () => <BackupEpisode>[]).add(episode);
    }
    final remoteByUrl = <String, List<BackupEpisode>>{};
    for (final episode in remote) {
      if (episode.url.isEmpty) continue;
      remoteByUrl
          .putIfAbsent(episode.url, () => <BackupEpisode>[])
          .add(episode);
    }
    final result = <BackupEpisode>[];
    for (final episode in localList) {
      final matches = remoteByUrl[episode.url];
      if (episode.version != Int64.ZERO ||
          episode.url.isEmpty ||
          localByUrl[episode.url]?.length != 1 ||
          matches?.length != 1) {
        result.add(episode);
        continue;
      }
      final remoteEpisode = matches!.single;
      result.add(
        ChimahonMediaChildProjectionProof.rebaseLocalEpisodeIdentity(
          localProjection: episode,
          remote: remoteEpisode,
        ),
      );
    }
    return result;
  }

  /// Preserve unsupported per-anime flags and hierarchy from legacy projections.
  void _preserveRemoteOnlyAnimeFields(
    BackupAnime merged,
    BackupAnime remote,
    BackupAnime local,
  ) {
    merged.excludedScanlators
      ..clear()
      ..addAll(remote.excludedScanlators);
    if (remote.hasEpisodeFlags()) {
      merged.episodeFlags = remote.episodeFlags;
    } else {
      merged.clearEpisodeFlags();
    }
    if (remote.hasUpdateStrategy()) {
      merged.updateStrategy = remote.updateStrategy;
    } else {
      merged.clearUpdateStrategy();
    }
    if (!hasChimahonSeasonMetadata(local)) {
      if (remote.hasSeasonFlags()) {
        merged.seasonFlags = remote.seasonFlags;
      } else {
        merged.clearSeasonFlags();
      }
      if (remote.hasSeasonNumber()) {
        merged.seasonNumber = remote.seasonNumber;
      } else {
        merged.clearSeasonNumber();
      }
      if (remote.hasSeasonSourceOrder()) {
        merged.seasonSourceOrder = remote.seasonSourceOrder;
      } else {
        merged.clearSeasonSourceOrder();
      }
      if (remote.hasFetchType()) {
        merged.fetchType = remote.fetchType;
      } else {
        merged.clearFetchType();
      }
    }
    if (remote.hasViewerFlags()) {
      merged.viewerFlags = remote.viewerFlags;
    } else {
      merged.clearViewerFlags();
    }
    if (!hasChimahonSeasonMetadata(local)) {
      if (remote.hasBackgroundUrl()) {
        merged.backgroundUrl = remote.backgroundUrl;
      } else {
        merged.clearBackgroundUrl();
      }
      if (remote.hasParentId()) {
        merged.parentId = remote.parentId;
      } else {
        merged.clearParentId();
      }
      if (remote.hasId()) {
        merged.id = remote.id;
      } else {
        merged.clearId();
      }
    }
  }

  void _mergeAnimeFavorite({
    required BackupAnime merged,
    required BackupAnime left,
    required BackupAnime right,
    required bool latestWasLeft,
  }) {
    final favoriteWinner = _favoriteWinner(
      leftHasTimestamp: left.hasFavoriteModifiedAt(),
      leftTimestamp: left.favoriteModifiedAt,
      rightHasTimestamp: right.hasFavoriteModifiedAt(),
      rightTimestamp: right.favoriteModifiedAt,
      leftWinsTie: latestWasLeft,
    );
    if (favoriteWinner == null) {
      // BackupAnime uses the same Chimahon absent=true wire convention as
      // BackupManga, including for otherwise clockless record ties.
      if (!right.hasFavorite()) merged.clearFavorite();
      return;
    }
    final winner = favoriteWinner ? left : right;
    final latest = latestWasLeft ? left : right;
    final winnerFavorite = winner.hasFavorite() ? winner.favorite : true;
    final latestFavorite = latest.hasFavorite() ? latest.favorite : true;
    final favoriteOverridesLatest =
        favoriteWinner != latestWasLeft &&
        (winnerFavorite != latestFavorite ||
            !latest.hasFavoriteModifiedAt() ||
            winner.favoriteModifiedAt != latest.favoriteModifiedAt);
    if (winnerFavorite && !right.hasFavorite()) {
      merged.clearFavorite();
    } else {
      merged.favorite = winnerFavorite;
    }
    merged.favoriteModifiedAt = winner.favoriteModifiedAt;
    if (favoriteOverridesLatest) {
      merged.version = _nextVersion(left.version, right.version);
    }
    if (merged.lastModifiedAt < winner.favoriteModifiedAt) {
      merged.lastModifiedAt = winner.favoriteModifiedAt;
    }
  }

  List<BackupSourcePreferences> _mergeSourcePreferences(
    Iterable<BackupSourcePreferences> local,
    Iterable<BackupSourcePreferences> remote,
  ) {
    final localByKey = _lastByKey<BackupSourcePreferences, String>(
      local,
      (item) => item.sourceKey,
    );
    final remoteByKey = _lastByKey<BackupSourcePreferences, String>(
      remote,
      (item) => item.sourceKey,
    );
    return _orderedKeys(remoteByKey, localByKey).map((key) {
      final left = localByKey[key];
      final right = remoteByKey[key];
      if (left == null) return right!.deepCopy();
      if (right == null) return left.deepCopy();
      return BackupSourcePreferences(
          sourceKey: key,
          prefs: _mergeByKey<BackupPreference, String>(
            left.prefs,
            right.prefs,
            (preference) => preference.key,
            remoteWins: true,
            mergeDuplicate: _mergePreference,
          ),
        )
        ..mergeUnknownFields(left.unknownFields)
        ..mergeUnknownFields(right.unknownFields);
    }).toList();
  }

  List<BackupNovel> _mergeNovels(
    Iterable<BackupNovel> local,
    Iterable<BackupNovel> remote,
    Iterable<BackupNovelCategory> localCategories,
    Iterable<BackupNovelCategory> remoteCategories,
    Iterable<BackupNovelCategory> mergedCategories,
    bool leftWinsTie,
  ) {
    final localByKey = _canonicalNovels(
      local,
      localCategories,
      mergedCategories,
    );
    final remoteByKey = _canonicalNovels(
      remote,
      remoteCategories,
      mergedCategories,
    );
    return _orderedKeys(remoteByKey, localByKey).map((key) {
      final left = localByKey[key];
      final right = remoteByKey[key];
      if (left == null) return right!.deepCopy();
      if (right == null) return left.deepCopy();
      final leftWins =
          left.lastModified > right.lastModified ||
          (left.lastModified == right.lastModified && leftWinsTie);
      final latest = leftWins ? left : right;
      final fallback = identical(latest, left) ? right : left;
      final merged = _copyWithMergedUnknownFields(latest, fallback);
      if (!merged.hasLang() && fallback.hasLang()) {
        merged.lang = fallback.lang;
      }
      // Chimahon keeps the newer record's chapter rows and history whole.
      // Mangatan's projection never carries them, so a newer Mangatan record
      // is a projection gap and must not erase Chimahon's lists.
      if (merged.chapters.isEmpty && fallback.chapters.isNotEmpty) {
        merged.chapters.addAll(fallback.chapters.map((row) => row.deepCopy()));
      }
      if (merged.history.isEmpty && fallback.history.isNotEmpty) {
        merged.history.addAll(fallback.history.map((row) => row.deepCopy()));
      }
      if (!merged.hasCover() && fallback.hasCover()) {
        merged.cover = fallback.cover;
      }
      if (right.hasCover()) merged.cover = right.cover;
      return merged
        ..id = key
        ..categoryIds.clear()
        ..categoryIds.addAll(
          _normalizeNovelCategoryIds([
            // Preserve the exact current Chimahon spelling, including an
            // absent category list. Mangatan's synthetic `default` category
            // is a projection gap, while non-default local memberships are
            // genuine additive intent.
            ...right.categoryIds,
            ...left.categoryIds.where(
              (id) => id != _uncategorizedNovelCategoryId,
            ),
          ]),
        )
        ..stats.clear()
        ..stats.addAll(
          _mergeNovelStats(left.stats, right.stats, leftWinsTie: leftWinsTie),
        );
    }).toList();
  }

  Map<String, BackupNovel> _canonicalNovels(
    Iterable<BackupNovel> novels,
    Iterable<BackupNovelCategory> sourceCategories,
    Iterable<BackupNovelCategory> mergedCategories,
  ) {
    final sourceById = {
      for (final category in sourceCategories) category.id: category,
    };
    final mergedById = {
      for (final category in mergedCategories) category.id: category,
    };
    final mergedByName = {
      for (final category in mergedCategories)
        _normalized(category.name): category,
    };
    final result = <String, BackupNovel>{};
    for (final novel in novels) {
      final stableId = _stableNovelId(novel);
      final remapped = novel.deepCopy()
        ..id = stableId
        ..categoryIds.clear();
      remapped.categoryIds.addAll(
        _normalizeNovelCategoryIds(
          novel.categoryIds.map((id) {
            if (id == _uncategorizedNovelCategoryId) return id;
            final source = sourceById[id];
            return source == null
                ? mergedById[id]?.id ?? id
                : mergedByName[_normalized(source.name)]?.id ??
                      mergedById[id]?.id ??
                      id;
          }).nonNulls,
        ),
      );
      final existing = result[stableId];
      result[stableId] = existing == null
          ? remapped
          : _mergeDuplicateNovel(existing, remapped);
    }
    return result;
  }

  BackupNovel _mergeDuplicateNovel(BackupNovel first, BackupNovel second) {
    final latest = first.lastModified >= second.lastModified ? first : second;
    final fallback = identical(latest, first) ? second : first;
    final merged = _copyWithMergedUnknownFields(latest, fallback);
    if (!merged.hasLang() && fallback.hasLang()) {
      merged.lang = fallback.lang;
    }
    if (!merged.hasCover() && fallback.hasCover()) {
      merged.cover = fallback.cover;
    }
    return merged
      ..categoryIds.clear()
      ..categoryIds.addAll(
        _normalizeNovelCategoryIds([
          ...first.categoryIds,
          ...second.categoryIds,
        ]),
      )
      ..stats.clear()
      ..stats.addAll(_mergeNovelStats(first.stats, second.stats));
  }

  List<BackupNovelStat> _mergeNovelStats(
    Iterable<BackupNovelStat> local,
    Iterable<BackupNovelStat> remote, {
    bool leftWinsTie = true,
  }) {
    final localByDate = _lastByKey<BackupNovelStat, String>(
      local,
      (item) => item.dateKey,
    );
    final remoteByDate = _lastByKey<BackupNovelStat, String>(
      remote,
      (item) => item.dateKey,
    );
    return _orderedKeys(remoteByDate, localByDate).map((date) {
      final left = localByDate[date];
      final right = remoteByDate[date];
      if (left == null) return right!.deepCopy();
      if (right == null) return left.deepCopy();
      final leftWins =
          left.lastStatisticModified > right.lastStatisticModified ||
          (left.lastStatisticModified == right.lastStatisticModified &&
              leftWinsTie);
      final merged = _copyWithMergedUnknownFields(
        leftWins ? left : right,
        leftWins ? right : left,
      );
      return _mergeNovelStatDay(merged, left, right);
    }).toList();
  }

  /// Mirrors Chimahon's `mergeNovelStatDay`. Database-backed Chimahon backups
  /// write `lastStatisticModified = 0`, so a timestamp cannot pick a winner;
  /// the counters only grow, so the larger value per field already contains
  /// the other side's reading.
  BackupNovelStat _mergeNovelStatDay(
    BackupNovelStat merged,
    BackupNovelStat left,
    BackupNovelStat right,
  ) {
    final newer =
        right.charactersRead > left.charactersRead ||
            (right.charactersRead == left.charactersRead &&
                right.readingTime > left.readingTime)
        ? right
        : left;
    int minNonZero(int first, int second) => first <= 0
        ? second
        : second <= 0
        ? first
        : math.min(first, second);
    return merged
      ..charactersRead = math.max(left.charactersRead, right.charactersRead)
      ..readingTime = math.max(left.readingTime, right.readingTime)
      ..minReadingSpeed = minNonZero(
        left.minReadingSpeed,
        right.minReadingSpeed,
      )
      ..altMinReadingSpeed = minNonZero(
        left.altMinReadingSpeed,
        right.altMinReadingSpeed,
      )
      ..lastReadingSpeed = newer.lastReadingSpeed
      ..maxReadingSpeed = math.max(left.maxReadingSpeed, right.maxReadingSpeed)
      ..lastStatisticModified =
          left.lastStatisticModified > right.lastStatisticModified
          ? left.lastStatisticModified
          : right.lastStatisticModified;
  }

  List<T> _mergeByKey<T extends GeneratedMessage, K>(
    Iterable<T> local,
    Iterable<T> remote,
    K Function(T value) keyOf, {
    bool remoteWins = false,
    T Function(T winner, T loser)? mergeDuplicate,
  }) {
    final values = <K, T>{};
    final localOrder = <K, bool>{};
    final remoteOrder = <K, bool>{};
    for (final value in local) {
      final key = keyOf(value);
      localOrder.putIfAbsent(key, () => true);
      final existing = values[key];
      values[key] = existing == null
          ? value.deepCopy()
          : mergeDuplicate?.call(value, existing) ??
                _copyWithMergedUnknownFields(value, existing);
    }
    for (final value in remote) {
      final key = keyOf(value);
      remoteOrder.putIfAbsent(key, () => true);
      final existing = values[key];
      if (existing == null) {
        values[key] = value.deepCopy();
      } else if (remoteWins) {
        values[key] =
            mergeDuplicate?.call(value, existing) ??
            _copyWithMergedUnknownFields(value, existing);
      } else {
        values[key] =
            mergeDuplicate?.call(existing, value) ??
            _copyWithMergedUnknownFields(existing, value);
      }
    }
    return [
      for (final key in _orderedKeys(remoteOrder, localOrder)) values[key]!,
    ];
  }

  Map<K, T> _lastByKey<T extends GeneratedMessage, K>(
    Iterable<T> values,
    K Function(T value) keyOf,
  ) {
    final result = <K, T>{};
    for (final value in values) {
      final key = keyOf(value);
      final existing = result[key];
      result[key] = existing == null
          ? value
          : _copyWithMergedUnknownFields(value, existing);
    }
    return result;
  }

  /// Serializes the selected winner's unknown values last. If a future client
  /// recognizes a currently unknown singular field, protobuf's last-value rule
  /// will therefore agree with the known-field conflict decision made here.
  T _copyWithMergedUnknownFields<T extends GeneratedMessage>(
    T winner,
    T loser,
  ) {
    final merged = winner.deepCopy()..unknownFields.clear();
    merged
      ..mergeUnknownFields(loser.unknownFields)
      ..mergeUnknownFields(winner.unknownFields);
    return merged;
  }

  BackupPreference _mergePreference(
    BackupPreference winner,
    BackupPreference loser,
  ) {
    final merged = _copyWithMergedUnknownFields(winner, loser);
    if (winner.hasValue() && loser.hasValue()) {
      merged.value = _copyWithMergedUnknownFields(winner.value, loser.value);
    }
    return merged;
  }

  BackupFeed _mergeFeed(BackupFeed winner, BackupFeed loser) {
    final merged = _copyWithMergedUnknownFields(winner, loser);
    if (winner.hasSavedSearch() && loser.hasSavedSearch()) {
      merged.savedSearch = _copyWithMergedUnknownFields(
        winner.savedSearch,
        loser.savedSearch,
      );
    }
    return merged;
  }

  List<BackupTracking> _copyWinnerTrackingWithUnknownFields(
    Iterable<BackupTracking> winner,
    Iterable<BackupTracking> loser, {
    required Iterable<BackupTracking> localTracking,
    required bool winnerIsLocal,
    required int source,
    required String url,
    required Set<ChimahonTrackingDeletionKey> localTrackingDeletions,
  }) {
    final winnerBySyncId = _lastByKey<BackupTracking, int>(
      winner,
      (tracking) => tracking.syncId,
    );
    final loserBySyncId = _lastByKey<BackupTracking, int>(
      loser,
      (tracking) => tracking.syncId,
    );
    // A marker remains durable across parent-version conflicts, but the local
    // projection is authoritative evidence that the tracker was re-added.
    final localSyncIds = localTracking
        .map((tracking) => tracking.syncId)
        .toSet();
    return _orderedKeys(winnerBySyncId, loserBySyncId)
        .map((syncId) {
          final explicitlyDeleted =
              _isPortableTrackingService(syncId) &&
              !localSyncIds.contains(syncId) &&
              localTrackingDeletions.contains((
                source: source,
                url: url,
                syncId: syncId,
              ));
          if (explicitlyDeleted) return null;

          final selected = winnerBySyncId[syncId];
          final fallback = loserBySyncId[syncId];
          if (selected == null) {
            if (_isPortableTrackingService(syncId)) {
              if (!winnerIsLocal) return null;
            }
            return fallback!.deepCopy();
          }
          return fallback == null
              ? selected.deepCopy()
              : _mergeTracking(
                  selected,
                  fallback,
                  fillProjectionGaps: winnerIsLocal,
                );
        })
        .nonNulls
        .toList();
  }

  bool _isPortableTrackingService(int syncId) =>
      syncId == 1 || syncId == 2 || syncId == 3;

  BackupTracking _mergeTracking(
    BackupTracking winner,
    BackupTracking fallback, {
    required bool fillProjectionGaps,
  }) {
    final merged = _copyWithMergedUnknownFields(winner, fallback);
    if (!fillProjectionGaps) return merged;
    // Mangatan intentionally omits nullable fields for which its local Track
    // row has no value, plus private and the deprecated mediaIdInt fields that
    // its model cannot represent. Fill only absent fields; an explicitly set
    // zero/false/empty value remains authoritative.
    if (!winner.hasLibraryId() && fallback.hasLibraryId()) {
      merged.libraryId = fallback.libraryId;
    }
    if (!winner.hasMediaIdInt() && fallback.hasMediaIdInt()) {
      merged.mediaIdInt = fallback.mediaIdInt;
    }
    if (!winner.hasTrackingUrl() && fallback.hasTrackingUrl()) {
      merged.trackingUrl = fallback.trackingUrl;
    }
    if (!winner.hasTitle() && fallback.hasTitle()) {
      merged.title = fallback.title;
    }
    if (!winner.hasLastChapterRead() && fallback.hasLastChapterRead()) {
      merged.lastChapterRead = fallback.lastChapterRead;
    } else if (winner.hasLastChapterRead() &&
        fallback.hasLastChapterRead() &&
        _isTruncatedProjection(
          winner.lastChapterRead,
          fallback.lastChapterRead,
        )) {
      merged.lastChapterRead = fallback.lastChapterRead;
    }
    if (!winner.hasTotalChapters() && fallback.hasTotalChapters()) {
      merged.totalChapters = fallback.totalChapters;
    }
    if (!winner.hasScore() && fallback.hasScore()) {
      merged.score = fallback.score;
    } else if (winner.hasScore() &&
        fallback.hasScore() &&
        _isTruncatedProjection(winner.score, fallback.score)) {
      merged.score = fallback.score;
    }
    if (!winner.hasStatus() && fallback.hasStatus()) {
      merged.status = fallback.status;
    }
    if (!winner.hasStartedReadingDate() && fallback.hasStartedReadingDate()) {
      merged.startedReadingDate = fallback.startedReadingDate;
    }
    if (!winner.hasFinishedReadingDate() && fallback.hasFinishedReadingDate()) {
      merged.finishedReadingDate = fallback.finishedReadingDate;
    }
    if (!winner.hasPrivate() && fallback.hasPrivate()) {
      merged.private = fallback.private;
    }
    if (!winner.hasMediaId() && fallback.hasMediaId()) {
      merged.mediaId = fallback.mediaId;
    }
    return merged;
  }

  bool _isTruncatedProjection(double projected, double exact) =>
      exact != exact.truncateToDouble() &&
      projected == exact.truncateToDouble();

  bool _isTruncatedMillisecondProjection(Int64 projected, Int64 exact) {
    final exactValue = exact.toInt();
    if (exactValue % 1000 == 0) return false;
    return projected.toInt() == (exactValue ~/ 1000) * 1000;
  }

  List<BackupPreference> _mergePreferences(
    Iterable<BackupPreference> local,
    Iterable<BackupPreference> remote,
  ) {
    final remotePreferences = remote.toList(growable: false);
    final merged = _mergeByKey<BackupPreference, String>(
      local,
      remotePreferences,
      (preference) => preference.key,
      remoteWins: true,
      mergeDuplicate: _mergePreference,
    );
    if (!remotePreferences.any(
      (preference) => preference.key == 'pref_anki_profiles',
    )) {
      return merged;
    }

    // Override preferences are a snapshot, not independent settings. Auto is
    // represented by deleting the key, so retaining a local-only key when the
    // remote profile snapshot omits it would resurrect a cleared override.
    final remoteOverrideKeys = <String>{
      for (final preference in remotePreferences)
        if (_isDictionaryProfileOverrideKey(preference.key)) preference.key,
    };
    return [
      for (final preference in merged)
        if (!_isDictionaryProfileOverrideKey(preference.key) ||
            remoteOverrideKeys.contains(preference.key))
          preference,
    ];
  }

  bool _isDictionaryProfileOverrideKey(String key) =>
      key.startsWith('pref_dict_profile_manga_') ||
      key.startsWith('pref_dict_profile_source_') ||
      key.startsWith('pref_dict_profile_novel_');

  Iterable<K> _orderedKeys<K, T>(Map<K, T> first, Map<K, T> second) sync* {
    final seen = <K>{};
    for (final key in first.keys) {
      if (seen.add(key)) yield key;
    }
    for (final key in second.keys) {
      if (seen.add(key)) yield key;
    }
  }

  bool _sameValues<T>(List<T> left, List<T> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  bool _canCopyExactManga(BackupManga left, BackupManga right) =>
      left == right &&
      left.unknownFields.isEmpty &&
      _hasUniqueKeysWithoutUnknownFields(left.chapters, _chapterKey) &&
      _hasUniqueKeysWithoutUnknownFields(
        left.history,
        (history) => history.url,
      ) &&
      _hasUniqueKeysWithoutUnknownFields(
        left.tracking,
        (tracking) => tracking.syncId,
      );

  bool _canCopyExactAnime(BackupAnime left, BackupAnime right) =>
      left == right &&
      left.unknownFields.isEmpty &&
      _hasUniqueKeysWithoutUnknownFields(left.episodes, _episodeKey) &&
      _hasUniqueKeysWithoutUnknownFields(
        left.history,
        (history) => history.url,
      ) &&
      _hasUniqueKeysWithoutUnknownFields(
        left.tracking,
        (tracking) => tracking.syncId,
      );

  bool _hasUniqueKeysWithoutUnknownFields<T extends GeneratedMessage, K>(
    Iterable<T> values,
    K Function(T value) keyOf,
  ) {
    final keys = <K>{};
    for (final value in values) {
      if (value.unknownFields.isNotEmpty || !keys.add(keyOf(value))) {
        return false;
      }
    }
    return true;
  }

  /// A source refresh advances Mangatan's wall clock on the parent and every
  /// existing child even when none of their portable values changed. During a
  /// routine sync, do not turn that bookkeeping-only clock into a Chimahon
  /// version increment. Retaining the remote message also keeps its exact
  /// sparse/default field spelling. Explicit restore authority keeps
  /// [leftWinsTie] enabled and deliberately bypasses this rule.
  bool _shouldRetainExactRemoteProjection({
    required Int64 localVersion,
    required Int64 localModified,
    required Int64 remoteModified,
    required bool leftWinsTie,
    required bool localProjectionRules,
    required bool Function() portableValuesAreEqual,
  }) {
    if (!localProjectionRules ||
        leftWinsTie ||
        localVersion != Int64.ZERO ||
        localModified <= remoteModified) {
      return false;
    }
    return portableValuesAreEqual();
  }

  bool _mangaProjectionEquals(BackupManga local, BackupManga remote) =>
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
      _sameSet(local.categories, remote.categories) &&
      _trackingProjectionEquals(local.tracking, remote.tracking);

  bool _animeProjectionEquals(BackupAnime local, BackupAnime remote) =>
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
      _sameSet(local.categories, remote.categories) &&
      _trackingProjectionEquals(local.tracking, remote.tracking);

  /// Missing local tracker fields are projection gaps and are filled from the
  /// remote row by [_mergeTracking]. A locally present field, however, is real
  /// portable state and must match before a newer parent clock can be ignored.
  bool _trackingProjectionEquals(
    Iterable<BackupTracking> local,
    Iterable<BackupTracking> remote,
  ) {
    final localBySyncId = _lastByKey<BackupTracking, int>(
      local.where((row) => _isPortableTrackingService(row.syncId)),
      (row) => row.syncId,
    );
    final remoteBySyncId = _lastByKey<BackupTracking, int>(
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
              (allowTruncatedRemote &&
                  _isTruncatedProjection(localValue, remoteValue))));

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

  bool _sameSet<T>(Iterable<T> left, Iterable<T> right) {
    final leftSet = left.toSet();
    final rightSet = right.toSet();
    return leftSet.length == rightSet.length && leftSet.containsAll(rightSet);
  }

  /// Chimahon compares its monotonic counters directly. Mangatan projections
  /// intentionally use version zero because their `updatedAt` values are wall
  /// clocks. If either side is unversioned, compare the seconds-based modified
  /// clocks instead, using a real counter to break an exact timestamp tie.
  bool _recordLeftWins(
    Int64 leftVersion,
    Int64 leftModified,
    Int64 rightVersion,
    Int64 rightModified, {
    bool leftWinsTie = true,
  }) {
    final leftIsVersioned = leftVersion != Int64.ZERO;
    final rightIsVersioned = rightVersion != Int64.ZERO;
    if (leftIsVersioned && rightIsVersioned) {
      if (leftVersion != rightVersion) return leftVersion > rightVersion;
      return leftWinsTie;
    }
    if (leftModified != rightModified) return leftModified > rightModified;
    if (leftIsVersioned != rightIsVersioned) return leftIsVersioned;
    return leftWinsTie;
  }

  /// Promotes a newer unversioned projection into Chimahon's counter domain.
  /// Fail closed at the signed wire limit instead of wrapping to a negative
  /// version that every existing Chimahon record would permanently outrank.
  Int64 _nextVersion(Int64 left, Int64 right) {
    final latest = left >= right ? left : right;
    if (latest == Int64.MAX_VALUE) {
      throw StateError(
        'Cannot promote Chimahon sync state above Int64.MAX_VALUE.',
      );
    }
    return latest + 1;
  }

  /// Returns true for left, false for right, and null when neither side has a
  /// favorite timestamp. On an exact seconds tie, the record-version winner
  /// decides; Chimahon can increment its version more than once in one second.
  bool? _favoriteWinner({
    required bool leftHasTimestamp,
    required Int64 leftTimestamp,
    required bool rightHasTimestamp,
    required Int64 rightTimestamp,
    required bool leftWinsTie,
  }) {
    if (!leftHasTimestamp && !rightHasTimestamp) return null;
    if (leftHasTimestamp && !rightHasTimestamp) return true;
    if (!leftHasTimestamp) return false;
    if (leftTimestamp != rightTimestamp) {
      return leftTimestamp > rightTimestamp;
    }
    return leftWinsTie;
  }

  String _mangaKey(BackupManga manga) => chimahonMangaIdentity(manga);

  String _mangaAuthorKey(BackupManga manga) =>
      manga.hasAuthor() ? _normalized(manga.author) : 'null';

  String _mangaSourceUrlKey(BackupManga manga) =>
      '${manga.source}|${manga.url}';

  String _animeKey(BackupAnime anime) => chimahonAnimeIdentity(anime);

  String _animeSourceUrlKey(BackupAnime anime) =>
      '${anime.source}|${anime.url}';

  String _chapterKey(BackupChapter chapter) => chimahonChapterIdentity(chapter);

  String _episodeKey(BackupEpisode episode) => chimahonEpisodeIdentity(episode);

  String _stableNovelId(BackupNovel novel) {
    final title = _normalized(novel.title);
    final author = _normalized(novel.author);
    if (title.isEmpty && author.isEmpty) return novel.id;
    return md5.convert(utf8.encode('$title|$author')).toString();
  }

  List<String> _normalizeNovelCategoryIds(Iterable<String> ids) {
    final values = ids.where((id) => id.trim().isNotEmpty).toSet().toList();
    if (values.any((id) => id != _uncategorizedNovelCategoryId)) {
      values.remove(_uncategorizedNovelCategoryId);
    }
    return values;
  }

  String _normalized(String value) => value.trim().toLowerCase();
}

class _OrderedCategoryMembershipMapper {
  _OrderedCategoryMembershipMapper(
    Iterable<BackupCategory> sourceCategories,
    Iterable<BackupCategory> mergedCategories,
  ) {
    for (final category in sourceCategories) {
      _sourceByOrder[category.order.toInt()] = category;
      final key = _normalized(category.name);
      _sourceCountByNormalizedName[key] =
          (_sourceCountByNormalizedName[key] ?? 0) + 1;
    }
    for (final category in mergedCategories) {
      _mergedByExactName[category.name] = category;
      _mergedByNormalizedName
          .putIfAbsent(_normalized(category.name), () => <BackupCategory>[])
          .add(category);
    }
  }

  final Map<int, BackupCategory> _sourceByOrder = {};
  final Map<String, int> _sourceCountByNormalizedName = {};
  final Map<String, BackupCategory> _mergedByExactName = {};
  final Map<String, List<BackupCategory>> _mergedByNormalizedName = {};

  List<Int64> map(Iterable<Int64> memberships) {
    final result = <Int64>[];
    final seen = <Int64>{};
    for (final membership in memberships) {
      final source = _sourceByOrder[membership.toInt()];
      if (source == null) continue;
      final normalizedName = _normalized(source.name);
      final normalizedMatches =
          _mergedByNormalizedName[normalizedName] ?? const <BackupCategory>[];
      if (_sourceCountByNormalizedName[normalizedName] == 1 &&
          normalizedMatches.length > 1) {
        for (final target in normalizedMatches) {
          if (seen.add(target.order)) result.add(target.order);
        }
        continue;
      }
      final target = _mergedByExactName[source.name];
      if (target != null && seen.add(target.order)) result.add(target.order);
    }
    return result;
  }

  static String _normalized(String value) => value.trim().toLowerCase();
}
