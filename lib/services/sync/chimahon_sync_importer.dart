import 'package:mangayomi/services/sync/chimahon_anime_seasons.dart';
import 'package:fixnum/fixnum.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/models/category.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/download.dart';
import 'package:mangayomi/models/epub_book_progress.dart';
import 'package:mangayomi/models/history.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/models/track.dart';
import 'package:mangayomi/models/update.dart';
import 'package:mangayomi/eval/mihon/bridge_protocol.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupAnime.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupCategory.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupChapter.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupEpisode.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupHistory.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupManga.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupNovel.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupTracking.pb.dart';
import 'package:mangayomi/services/sync/chimahon_child_identity.dart';
import 'package:mangayomi/services/sync/chimahon_local_chapter_policy.dart';
import 'package:mangayomi/services/sync/chimahon_portable_title_matcher.dart';
import 'package:mangayomi/services/sync/chimahon_manga_title_adapter.dart';
import 'package:mangayomi/services/sync/chimahon_media_sync_selection.dart';
import 'package:mangayomi/services/sync/chimahon_novel_category_adapter.dart';
import 'package:mangayomi/services/sync/chimahon_novel_materializer.dart';
import 'package:mangayomi/services/sync/chimahon_tracking_adapter.dart';
import 'package:mangayomi/services/sync/mihon_backup_source_resolver.dart';

/// Summary of changes made by [ChimahonSyncImporter].
class ChimahonSyncImportResult {
  const ChimahonSyncImportResult({
    required this.titlesCreated,
    required this.titlesUpdated,
    required this.chaptersCreated,
    required this.chaptersUpdated,
    required this.novelsUpdated,
    this.titlesRemoved = 0,
    this.duplicatesRepaired = 0,
    this.sourcesRebound = 0,
    this.sourcesUnavailable = 0,
    this.sourcesUnresolved = 0,
    this.ambiguousRowsRetained = 0,
  });

  final int titlesCreated;
  final int titlesUpdated;
  final int chaptersCreated;
  final int chaptersUpdated;
  final int novelsUpdated;
  final int titlesRemoved;
  final int duplicatesRepaired;
  final int sourcesRebound;
  final int sourcesUnavailable;
  final int sourcesUnresolved;
  final int ambiguousRowsRetained;

  ChimahonSyncImportResult withSourceReconciliation({
    required int rebound,
    required int unavailable,
    required int unresolved,
  }) => ChimahonSyncImportResult(
    titlesCreated: titlesCreated,
    titlesUpdated: titlesUpdated,
    chaptersCreated: chaptersCreated,
    chaptersUpdated: chaptersUpdated,
    novelsUpdated: novelsUpdated,
    titlesRemoved: titlesRemoved,
    duplicatesRepaired: duplicatesRepaired,
    sourcesRebound: sourcesRebound + rebound,
    sourcesUnavailable: sourcesUnavailable + unavailable,
    sourcesUnresolved: sourcesUnresolved + unresolved,
    ambiguousRowsRetained: ambiguousRowsRetained,
  );
}

/// Applies a merged Chimahon payload without treating it as a full restore.
///
/// Chimahon's own sync flow restores only changed library entries and toggles
/// matching non-favorites in place. Mirroring that behavior is important here:
/// a normal sync must not clear Mangatan's source cache, downloads, update feed,
/// tracker state, manually added chapters, or local archive/novel library data.
/// Remote manga and chapters are therefore upserted by portable source identity
/// and URL, while absence from the payload never means deletion.
class ChimahonSyncImporter {
  const ChimahonSyncImporter();

  static const _titleMatcher = ChimahonPortableTitleMatcher();

  /// Predicts user-visible library removals using the same source/title
  /// matcher as [apply]. Non-favorite source-cache rows are deliberately
  /// ignored because they are already absent from the library.
  int estimateAuthoritativeRemovals({
    required BackupMihon backup,
    required ChimahonMediaSyncSelection selection,
    required Iterable<Source> localSources,
    required Iterable<Manga> localMangas,
    required Iterable<Chapter> localChapters,
    required Set<int> downloadedChapterIds,
    required ItemType itemType,
  }) {
    final enabled = switch (itemType) {
      ItemType.manga => selection.manga,
      ItemType.anime => selection.anime,
      _ => false,
    };
    if (!enabled) return 0;

    final sources = localSources.toList(growable: false);
    final mangas = localMangas.toList(growable: false);
    final mangasByTypeAndUrl = _indexMangasByTypeAndUrl(mangas);
    final resolvedSources = <int, ResolvedMihonBackupSource>{};
    final matchedFavoriteIds = <int>{};
    if (itemType == ItemType.manga) {
      final urlCounts = _sourceUrlCounts(
        backup.backupManga.map(
          (manga) => (source: manga.source.toInt(), url: manga.url),
        ),
      );
      for (final remote in backup.backupManga.where(
        (manga) => !manga.hasFavorite() || manga.favorite,
      )) {
        final nativeId = remote.source.toInt();
        final resolvedSource = resolvedSources.putIfAbsent(
          nativeId,
          () => resolveMihonBackupSource(
            nativeId: nativeId,
            backupSources: backup.backupSources,
            localSources: sources,
          ),
        );
        final local = _titleMatcher.find(
          localMangas: _titleCandidates(
            all: mangas,
            indexed: mangasByTypeAndUrl,
            itemType: itemType,
            url: remote.url,
          ),
          itemType: itemType,
          source: resolvedSource,
          url: remote.url,
          sourceTitle: remote.title,
          author: remote.hasAuthor() ? remote.author : null,
          allowSourceUrlFallback:
              urlCounts[_sourceUrlKey(remote.source.toInt(), remote.url)] == 1,
        );
        if (local?.id case final id?) matchedFavoriteIds.add(id);
      }
    } else if (itemType == ItemType.anime) {
      final urlCounts = _sourceUrlCounts(
        backup.backupAnime.map(
          (anime) => (source: anime.source.toInt(), url: anime.url),
        ),
      );
      for (final remote in backup.backupAnime.where(
        (anime) => !anime.hasFavorite() || anime.favorite,
      )) {
        final nativeId = remote.source.toInt();
        final resolvedSource = resolvedSources.putIfAbsent(
          nativeId,
          () => resolveMihonBackupSource(
            nativeId: nativeId,
            backupSources: backup.backupAnimeSources,
            localSources: sources,
          ),
        );
        final local = _titleMatcher.find(
          localMangas: _titleCandidates(
            all: mangas,
            indexed: mangasByTypeAndUrl,
            itemType: itemType,
            url: remote.url,
          ),
          itemType: itemType,
          source: resolvedSource,
          url: remote.url,
          sourceTitle: remote.title,
          author: remote.hasAuthor() ? remote.author : null,
          allowSourceUrlFallback:
              urlCounts[_sourceUrlKey(remote.source.toInt(), remote.url)] == 1,
        );
        if (local?.id case final id?) matchedFavoriteIds.add(id);
      }
    }

    final localOverlayParentIds = localChapters
        .where(
          (chapter) => _isLocalOverlayChapter(chapter, downloadedChapterIds),
        )
        .map((chapter) => chapter.mangaId)
        .nonNulls
        .toSet();
    return mangas.where((manga) {
      if (manga.itemType != itemType || !(manga.favorite ?? false)) {
        return false;
      }
      if (manga.isLocalArchive == true ||
          localOverlayParentIds.contains(manga.id)) {
        return false;
      }
      return !matchedFavoriteIds.contains(manga.id);
    }).length;
  }

  ChimahonSyncImportResult apply({
    required Isar database,
    required BackupMihon backup,
    ChimahonMediaSyncSelection? authoritativeSelection,
  }) {
    final syncManga = authoritativeSelection?.manga ?? true;
    final syncAnime = authoritativeSelection?.anime ?? true;
    final seasonParents = chimahonSeasonParents(backup.backupAnime);
    final syncNovels = authoritativeSelection?.novels ?? true;
    final localSources = database.sources.where().findAllSync();
    final localMangas = database.mangas.where().findAllSync();
    final localChapters = database.chapters.where().findAllSync();
    final localHistories = database.historys.where().findAllSync();
    final localTracks = database.tracks.where().findAllSync();
    final localCategories = database.categorys.where().findAllSync();
    final localNovelProgress = database.epubBookProgress.where().findAllSync();
    final sourcesById = <int, Source>{
      for (final source in localSources)
        if (source.id != null) source.id!: source,
    };
    final chaptersByMangaId = _groupByMangaId(
      localChapters,
      (chapter) => chapter.mangaId,
    );
    final historiesByMangaId = _groupByMangaId(
      localHistories,
      (history) => history.mangaId,
    );
    final tracksByMangaId = _groupByMangaId(
      localTracks,
      (track) => track.mangaId,
    );
    final mangasByTypeAndUrl = _indexMangasByTypeAndUrl(localMangas);
    final mangasById = <int, Manga>{
      for (final manga in localMangas)
        if (manga.id != null) manga.id!: manga,
    };
    final resolvedMangaSources = <int, ResolvedMihonBackupSource>{};
    final resolvedAnimeSources = <int, ResolvedMihonBackupSource>{};
    final downloadedChapterIds = database.downloads
        .where()
        .findAllSync()
        .map((download) => download.id)
        .nonNulls
        .toSet();
    const novelMaterializer = ChimahonNovelMaterializer();
    final libraryNovels = chimahonEpubLibraryNovels(
      backup,
    ).toList(growable: false);
    final staleCloudNovelParentIds = !syncNovels
        ? <int>{}
        : novelMaterializer.staleCloudNovelParentIds(
            localMangas: localMangas,
            localProgress: localNovelProgress,
            localChapters: localChapters,
            remote: libraryNovels,
          );
    final activeLocalMangas = localMangas
        .where((manga) => !staleCloudNovelParentIds.contains(manga.id))
        .toList();
    final activeLocalNovelProgress = localNovelProgress
        .where(
          (progress) => !staleCloudNovelParentIds.contains(progress.mangaId),
        )
        .toList();
    final remoteMangaSourceUrlCounts = _sourceUrlCounts(
      backup.backupManga.map(
        (manga) => (source: manga.source.toInt(), url: manga.url),
      ),
    );
    final remoteAnimeSourceUrlCounts = _sourceUrlCounts(
      backup.backupAnime.map(
        (anime) => (source: anime.source.toInt(), url: anime.url),
      ),
    );
    final localArchiveParentIds = localMangas
        .where((manga) => manga.isLocalArchive == true)
        .map((manga) => manga.id)
        .nonNulls
        .toSet();
    final localOverlayParentIds = localChapters
        .where(
          (chapter) =>
              !localArchiveParentIds.contains(chapter.mangaId) &&
              _isLocalOverlayChapter(chapter, downloadedChapterIds),
        )
        .map((chapter) => chapter.mangaId)
        .nonNulls
        .toSet();
    final novelPlan = syncNovels
        ? novelMaterializer.plan(
            localMangas: activeLocalMangas,
            localProgress: activeLocalNovelProgress,
            localChapters: localChapters,
            remote: libraryNovels,
          )
        : const ChimahonNovelMaterializationPlan(
            updatedProgress: [],
            updatedCloudParents: [],
            cloudNovels: [],
            remoteCategoryIdsByMangaId: {},
            authoritativeCloudParentIds: {},
          );

    var titlesCreated = 0;
    var titlesUpdated = 0;
    var chaptersCreated = 0;
    var chaptersUpdated = 0;
    var titlesRemoved = 0;
    var duplicatesRepaired = 0;
    var sourcesRebound = 0;
    var ambiguousRowsRetained = 0;
    final matchedMangaIds = <int>{};
    final matchedAnimeIds = <int>{};

    database.writeTxnSync(() {
      for (final progress in localNovelProgress.where(
        (progress) =>
            staleCloudNovelParentIds.contains(progress.mangaId) &&
            novelMaterializer.isCloudOnlyProgress(progress),
      )) {
        if (progress.id != null) {
          database.epubBookProgress.deleteSync(progress.id!);
        }
      }
      for (final mangaId in staleCloudNovelParentIds) {
        database.mangas.deleteSync(mangaId);
        mangasById.remove(mangaId);
      }
      localMangas.removeWhere(
        (manga) => staleCloudNovelParentIds.contains(manga.id),
      );
      // Migrate and continuously reconcile the local-overlay visibility bit.
      // It is not part of the Chimahon wire model and therefore cannot turn a
      // remote unfavorite tombstone back into a portable favorite.
      for (final manga in localMangas) {
        final localSource = manga.sourceId == null
            ? null
            : sourcesById[manga.sourceId];
        final portableSourceId = localSource == null
            ? null
            : mihonSourceMetadata(localSource)?.sourceId;
        if (manga.mihonSourceId == null && portableSourceId != null) {
          manga.mihonSourceId = portableSourceId;
          database.mangas.putSync(manga);
        }
        final hasOverlay = localOverlayParentIds.contains(manga.id);
        if ((manga.hasLocalChapterOverlay ?? false) == hasOverlay) continue;
        manga.hasLocalChapterOverlay = hasOverlay;
        database.mangas.putSync(manga);
      }
      final mangaCategories = !syncManga
          ? <int, int>{}
          : _upsertCategories(
              database: database,
              localCategories: localCategories,
              remoteCategories: backup.backupCategories,
              itemType: ItemType.manga,
            );
      final animeCategories = !syncAnime
          ? <int, int>{}
          : _upsertCategories(
              database: database,
              localCategories: localCategories,
              remoteCategories: backup.backupAnimeCategories,
              itemType: ItemType.anime,
            );
      final novelCategories = !syncNovels
          ? <String, int>{}
          : _upsertNovelCategories(
              database: database,
              localCategories: localCategories,
              remoteCategories: backup.backupNovelCategories,
            );

      for (final cloudNovel in novelPlan.cloudNovels) {
        cloudNovel.parent.categories = cloudNovel.remote.categoryIds
            .map((id) => novelCategories[id])
            .nonNulls
            .toSet()
            .toList();
        database.mangas.putSync(cloudNovel.parent);
        localMangas.add(cloudNovel.parent);
        mangasById[cloudNovel.parent.id!] = cloudNovel.parent;
        cloudNovel.progress.mangaId = cloudNovel.parent.id!;
        database.epubBookProgress.putSync(cloudNovel.progress);
        titlesCreated++;
      }
      if (novelPlan.updatedCloudParents.isNotEmpty) {
        database.mangas.putAllSync(novelPlan.updatedCloudParents);
      }

      for (final remote
          in syncManga ? backup.backupManga : const <BackupManga>[]) {
        final nativeId = remote.source.toInt();
        final resolvedSource = resolvedMangaSources.putIfAbsent(
          nativeId,
          () => resolveMihonBackupSource(
            nativeId: nativeId,
            backupSources: backup.backupSources,
            localSources: localSources,
          ),
        );
        var local = _titleMatcher.find(
          localMangas: _titleCandidates(
            all: localMangas,
            indexed: mangasByTypeAndUrl,
            itemType: ItemType.manga,
            url: remote.url,
          ),
          itemType: ItemType.manga,
          source: resolvedSource,
          url: remote.url,
          sourceTitle: remote.title,
          author: remote.hasAuthor() ? remote.author : null,
          allowSourceUrlFallback:
              remoteMangaSourceUrlCounts[_sourceUrlKey(
                remote.source.toInt(),
                remote.url,
              )] ==
              1,
        );
        final isFavorite = remote.hasFavorite() ? remote.favorite : true;
        if (!isFavorite) {
          if (local != null) {
            final retainedOverlay = localOverlayParentIds.contains(local.id);
            // Chimahon applies a tombstone to an existing cache row in place.
            // It disappears from the favorite-only library, but remains
            // addressable through source search and history.
            matchedMangaIds.add(local.id!);
            local
              ..favorite = false
              ..categories = authoritativeSelection != null && retainedOverlay
                  ? <int>[]
                  : local.categories;
            _applyFavoriteVersion(local, remote);
            database.mangas.putSync(local);
            _upsertTracking(
              database: database,
              manga: local,
              remoteTracking: remote.tracking,
              parentModifiedAt: remote.lastModifiedAt,
              localTracks: tracksByMangaId.putIfAbsent(
                local.id!,
                () => <Track>[],
              ),
            );
            titlesUpdated++;
          }
          continue;
        }

        if (local == null) {
          local = _newManga(remote, resolvedSource, mangaCategories);
          database.mangas.putSync(local);
          localMangas.add(local);
          mangasById[local.id!] = local;
          mangasByTypeAndUrl
              .putIfAbsent((
                type: ItemType.manga,
                url: remote.url,
              ), () => <Manga>[])
              .add(local);
          matchedMangaIds.add(local.id!);
          titlesCreated++;
        } else {
          final previousSourceId = local.sourceId;
          _applyManga(
            local,
            remote,
            resolvedSource,
            mangaCategories,
            categoriesAreAuthoritative: backup.backupCategories.isNotEmpty,
            authoritativeDownload: authoritativeSelection != null,
          );
          matchedMangaIds.add(local.id!);
          if (previousSourceId != local.sourceId) sourcesRebound++;
          database.mangas.putSync(local);
          titlesUpdated++;
        }
        final chapterChanges = _upsertMangaChapters(
          database: database,
          manga: local,
          remoteChapters: remote.chapters,
          localChapters: localChapters,
          localChaptersForManga: chaptersByMangaId.putIfAbsent(
            local.id!,
            () => <Chapter>[],
          ),
        );
        chaptersCreated += chapterChanges.$1;
        chaptersUpdated += chapterChanges.$2;
        _upsertHistory(
          database: database,
          manga: local,
          remoteHistory: remote.history,
          localChapters: chaptersByMangaId[local.id] ?? const <Chapter>[],
          localHistories: historiesByMangaId.putIfAbsent(
            local.id!,
            () => <History>[],
          ),
        );
        _upsertTracking(
          database: database,
          manga: local,
          remoteTracking: remote.tracking,
          parentModifiedAt: remote.lastModifiedAt,
          localTracks: tracksByMangaId.putIfAbsent(local.id!, () => <Track>[]),
        );
      }

      for (final remote
          in syncAnime ? backup.backupAnime : const <BackupAnime>[]) {
        final nativeId = remote.source.toInt();
        final resolvedSource = resolvedAnimeSources.putIfAbsent(
          nativeId,
          () => resolveMihonBackupSource(
            nativeId: nativeId,
            backupSources: backup.backupAnimeSources,
            localSources: localSources,
          ),
        );
        var local = _titleMatcher.find(
          localMangas: _titleCandidates(
            all: localMangas,
            indexed: mangasByTypeAndUrl,
            itemType: ItemType.anime,
            url: remote.url,
          ),
          itemType: ItemType.anime,
          source: resolvedSource,
          url: remote.url,
          sourceTitle: remote.title,
          author: remote.hasAuthor() ? remote.author : null,
          allowSourceUrlFallback:
              remoteAnimeSourceUrlCounts[_sourceUrlKey(
                remote.source.toInt(),
                remote.url,
              )] ==
              1,
        );
        final isFavorite = remote.hasFavorite() ? remote.favorite : true;
        if (!isFavorite && !seasonParents.containsKey(remote)) {
          if (local != null) {
            final retainedOverlay = localOverlayParentIds.contains(local.id);
            matchedAnimeIds.add(local.id!);
            local
              ..favorite = false
              ..categories = authoritativeSelection != null && retainedOverlay
                  ? <int>[]
                  : local.categories;
            _applyAnimeFavoriteVersion(local, remote);
            // A season can remain in the source cache after leaving both its
            // parent and the library. The tombstone fast path must still apply
            // an explicit detach/default reset from a season-aware client.
            applyChimahonAnimeSeasons(local, remote, null);
            database.mangas.putSync(local);
            _upsertTracking(
              database: database,
              manga: local,
              remoteTracking: remote.tracking,
              parentModifiedAt: remote.lastModifiedAt,
              localTracks: tracksByMangaId.putIfAbsent(
                local.id!,
                () => <Track>[],
              ),
            );
            titlesUpdated++;
          }
          continue;
        }

        if (local == null) {
          local = _newAnime(remote, resolvedSource, animeCategories);
          database.mangas.putSync(local);
          localMangas.add(local);
          mangasById[local.id!] = local;
          mangasByTypeAndUrl
              .putIfAbsent((
                type: ItemType.anime,
                url: remote.url,
              ), () => <Manga>[])
              .add(local);
          matchedAnimeIds.add(local.id!);
          titlesCreated++;
        } else {
          final previousSourceId = local.sourceId;
          _applyAnime(
            local,
            remote,
            resolvedSource,
            animeCategories,
            categoriesAreAuthoritative: backup.backupAnimeCategories.isNotEmpty,
            authoritativeDownload: authoritativeSelection != null,
          );
          matchedAnimeIds.add(local.id!);
          if (previousSourceId != local.sourceId) sourcesRebound++;
          database.mangas.putSync(local);
          titlesUpdated++;
        }
        applyChimahonAnimeSeasons(local, remote, seasonParents[remote]);
        local.favorite = isFavorite;
        database.mangas.putSync(local);
        final chapterChanges = _upsertAnimeEpisodes(
          database: database,
          anime: local,
          remoteEpisodes: remote.episodes,
          localChapters: localChapters,
          localChaptersForAnime: chaptersByMangaId.putIfAbsent(
            local.id!,
            () => <Chapter>[],
          ),
        );
        chaptersCreated += chapterChanges.$1;
        chaptersUpdated += chapterChanges.$2;
        _upsertHistory(
          database: database,
          manga: local,
          remoteHistory: remote.history,
          localChapters: chaptersByMangaId[local.id] ?? const <Chapter>[],
          localHistories: historiesByMangaId.putIfAbsent(
            local.id!,
            () => <History>[],
          ),
        );
        _upsertTracking(
          database: database,
          manga: local,
          remoteTracking: remote.tracking,
          parentModifiedAt: remote.lastModifiedAt,
          localTracks: tracksByMangaId.putIfAbsent(local.id!, () => <Track>[]),
        );
      }

      for (final entry in novelPlan.remoteCategoryIdsByMangaId.entries) {
        final local = mangasById[entry.key];
        if (local == null || local.itemType != ItemType.novel) continue;
        final remoteCategoryIds = entry.value
            .map((id) => novelCategories[id])
            .nonNulls
            .toSet();
        // A still-empty synthetic parent is remote cache. Replace its
        // categories exactly so an earlier Drive account cannot bleed into
        // the current one. Real EPUB parents retain their local memberships.
        final isAuthoritativeCloudParent = novelPlan.authoritativeCloudParentIds
            .contains(entry.key);
        final categoriesAreAuthoritative =
            isAuthoritativeCloudParent || authoritativeSelection != null;
        if (!categoriesAreAuthoritative && remoteCategoryIds.isEmpty) continue;
        final mergedCategoryIds = categoriesAreAuthoritative
            ? remoteCategoryIds.toList()
            : _unionIds(local.categories, remoteCategoryIds);
        if (_sameIds(local.categories, mergedCategoryIds)) continue;
        local.categories = mergedCategoryIds;
        database.mangas.putSync(local);
      }

      if (novelPlan.updatedProgress.isNotEmpty) {
        database.epubBookProgress.putAllSync(novelPlan.updatedProgress);
      }

      if (authoritativeSelection != null) {
        final cleanup = _removeRemoteAbsentPortableTitles(
          database: database,
          localMangas: localMangas,
          localChapters: localChapters,
          chaptersByMangaId: chaptersByMangaId,
          downloadedChapterIds: downloadedChapterIds,
          matchedMangaIds: matchedMangaIds,
          matchedAnimeIds: matchedAnimeIds,
          syncManga: syncManga,
          syncAnime: syncAnime,
        );
        titlesRemoved += cleanup.removed;
        duplicatesRepaired += cleanup.duplicatesRepaired;
        ambiguousRowsRetained += cleanup.retained;
        final referencedCategoryIds = database.mangas
            .where()
            .findAllSync()
            .expand((manga) => manga.categories ?? const <int>[])
            .toSet();
        _removeUnreferencedCategories(
          database: database,
          itemType: ItemType.manga,
          enabled: syncManga,
          authoritativeIds: mangaCategories.values.toSet(),
          referencedIds: referencedCategoryIds,
        );
        _removeUnreferencedCategories(
          database: database,
          itemType: ItemType.anime,
          enabled: syncAnime,
          authoritativeIds: animeCategories.values.toSet(),
          referencedIds: referencedCategoryIds,
        );
        _removeUnreferencedCategories(
          database: database,
          itemType: ItemType.novel,
          enabled: syncNovels,
          authoritativeIds: backup.backupNovelCategories
              .map((category) => novelCategories[category.id])
              .nonNulls
              .toSet(),
          referencedIds: referencedCategoryIds,
        );
      }
    });

    return ChimahonSyncImportResult(
      titlesCreated: titlesCreated,
      titlesUpdated: titlesUpdated,
      chaptersCreated: chaptersCreated,
      chaptersUpdated: chaptersUpdated,
      novelsUpdated: novelPlan.novelsUpdated,
      titlesRemoved: titlesRemoved,
      duplicatesRepaired: duplicatesRepaired,
      sourcesRebound: sourcesRebound,
      ambiguousRowsRetained: ambiguousRowsRetained,
    );
  }

  Map<int, int> _upsertCategories({
    required Isar database,
    required List<Category> localCategories,
    required Iterable<BackupCategory> remoteCategories,
    required ItemType itemType,
  }) {
    final localByName = <String, Category>{
      for (final category in localCategories.where(
        (category) => category.forItemType == itemType,
      ))
        _normalized(category.name): category,
    };
    final result = <int, int>{};
    for (final remote in remoteCategories) {
      final order = remote.order.toInt();
      final key = _normalized(remote.name);
      var local = localByName[key];
      if (local == null) {
        local = Category(
          name: remote.name,
          forItemType: itemType,
          pos: order,
          hide: remote.hidden,
        );
        database.categorys.putSync(local);
        localCategories.add(local);
        localByName[key] = local;
      } else if (local.pos != order || local.hide != remote.hidden) {
        // Keep Mangatan-only state and the stable local ID. Order and hidden
        // are the two category fields shared with Chimahon.
        local
          ..pos = order
          ..hide = remote.hidden;
        database.categorys.putSync(local);
      }
      if (local.id != null) result[order] = local.id!;
    }
    return result;
  }

  Map<String, int> _upsertNovelCategories({
    required Isar database,
    required List<Category> localCategories,
    required Iterable<BackupNovelCategory> remoteCategories,
  }) {
    const adapter = ChimahonNovelCategoryAdapter();
    final localByName = <String, Category>{
      for (final category in localCategories.where(
        (category) => category.forItemType == ItemType.novel,
      ))
        adapter.normalizeName(category.name): category,
    };
    final result = <String, int>{};
    for (final local in localByName.values) {
      final localId = local.id;
      if (localId == null || adapter.normalizeName(local.name).isEmpty) {
        continue;
      }
      result[adapter.stableId(local.name)] = localId;
    }

    for (final remote in remoteCategories) {
      if (remote.id == ChimahonNovelCategoryAdapter.uncategorizedId) {
        continue;
      }
      final key = adapter.normalizeName(remote.name);
      if (key.isEmpty) continue;
      final order = remote.order.toInt();
      var local = localByName[key];
      if (local == null) {
        local = Category(
          name: remote.name,
          forItemType: ItemType.novel,
          pos: order,
        );
        database.categorys.putSync(local);
        localCategories.add(local);
        localByName[key] = local;
      } else if (local.pos != order) {
        // Chimahon's flags encode library-view state which has no safe
        // equivalent in Mangatan. Keep Mangatan-only category state and apply
        // only the shared ordering field.
        local.pos = order;
        database.categorys.putSync(local);
      }
      final localId = local.id;
      if (localId != null) {
        result[remote.id] = localId;
        result[adapter.stableId(remote.name)] = localId;
      }
    }
    return result;
  }

  ({int removed, int duplicatesRepaired, int retained})
  _removeRemoteAbsentPortableTitles({
    required Isar database,
    required List<Manga> localMangas,
    required List<Chapter> localChapters,
    required Map<int, List<Chapter>> chaptersByMangaId,
    required Set<int> downloadedChapterIds,
    required Set<int> matchedMangaIds,
    required Set<int> matchedAnimeIds,
    required bool syncManga,
    required bool syncAnime,
  }) {
    final matchedIds = {...matchedMangaIds, ...matchedAnimeIds};
    final matchedByIdentity = <String, Manga>{
      for (final manga in localMangas.where(
        (manga) => matchedIds.contains(manga.id),
      ))
        _titleMatcher.identityKey(manga): manga,
    };
    var removed = 0;
    var duplicatesRepaired = 0;
    var retained = 0;
    final removedIds = <int>{};

    for (final manga in localMangas.toList(growable: false)) {
      final mangaId = manga.id;
      if (mangaId == null ||
          matchedIds.contains(mangaId) ||
          manga.isLocalArchive == true ||
          (manga.itemType == ItemType.manga && !syncManga) ||
          (manga.itemType == ItemType.anime && !syncAnime) ||
          (manga.itemType != ItemType.manga &&
              manga.itemType != ItemType.anime)) {
        continue;
      }
      final chapters = chaptersByMangaId[mangaId] ?? const <Chapter>[];
      final hasLocalOverlayData = chapters.any(
        (chapter) => _isLocalOverlayChapter(chapter, downloadedChapterIds),
      );
      final hasDownloads = chapters.any(
        (chapter) => downloadedChapterIds.contains(chapter.id),
      );
      if (hasLocalOverlayData || hasDownloads) {
        manga
          ..favorite = false
          ..favoriteModifiedAt = null
          ..categories = <int>[]
          ..hasLocalChapterOverlay = hasLocalOverlayData;
        database.mangas.putSync(manga);
        retained++;
        continue;
      }

      final duplicateTarget =
          matchedByIdentity[_titleMatcher.identityKey(manga)];
      if (duplicateTarget != null) {
        _transferCompatibleDuplicateData(
          database: database,
          duplicate: manga,
          target: duplicateTarget,
          duplicateChapters: chapters,
          targetChapters:
              chaptersByMangaId[duplicateTarget.id] ?? const <Chapter>[],
        );
        duplicatesRepaired++;
      }
      _deletePortableTitle(
        database: database,
        manga: manga,
        chapters: chapters,
      );
      removedIds.add(mangaId);
      removed++;
    }
    if (removedIds.isNotEmpty) {
      localMangas.removeWhere((manga) => removedIds.contains(manga.id));
      localChapters.removeWhere(
        (chapter) => removedIds.contains(chapter.mangaId),
      );
    }
    return (
      removed: removed,
      duplicatesRepaired: duplicatesRepaired,
      retained: retained,
    );
  }

  static bool _isLocalOverlayChapter(
    Chapter chapter,
    Set<int> downloadedChapterIds,
  ) {
    if (const ChimahonLocalChapterPolicy().isDeviceLocal(chapter)) return true;
    return (chapter.archivePath?.trim().isNotEmpty ?? false) &&
        !downloadedChapterIds.contains(chapter.id);
  }

  void _transferCompatibleDuplicateData({
    required Isar database,
    required Manga duplicate,
    required Manga target,
    required List<Chapter> duplicateChapters,
    required List<Chapter> targetChapters,
  }) {
    final duplicateId = duplicate.id!;
    final targetId = target.id!;
    final targetChaptersByIdentity = <String, Chapter>{
      for (final chapter in targetChapters)
        _localChildIdentity(chapter, target.itemType): chapter,
    };
    final targetChapterIdByDuplicateId = <int, int>{};
    for (final chapter in duplicateChapters) {
      final duplicateChapterId = chapter.id;
      final targetChapter =
          targetChaptersByIdentity[_localChildIdentity(
            chapter,
            duplicate.itemType,
          )];
      if (duplicateChapterId != null && targetChapter?.id != null) {
        targetChapterIdByDuplicateId[duplicateChapterId] = targetChapter!.id!;
      }
    }

    final targetHistoryChapterIds = database.historys
        .filter()
        .mangaIdEqualTo(targetId)
        .findAllSync()
        .map((history) => history.chapterId)
        .nonNulls
        .toSet();
    for (final history
        in database.historys
            .filter()
            .mangaIdEqualTo(duplicateId)
            .findAllSync()) {
      final targetChapterId = targetChapterIdByDuplicateId[history.chapterId];
      if (targetChapterId == null ||
          targetHistoryChapterIds.contains(targetChapterId)) {
        continue;
      }
      history
        ..mangaId = targetId
        ..chapterId = targetChapterId
        ..chapter.value = database.chapters.getSync(targetChapterId);
      database.historys.putSync(history);
      history.chapter.saveSync();
      targetHistoryChapterIds.add(targetChapterId);
    }

    final targetTrackKeys = database.tracks
        .filter()
        .mangaIdEqualTo(targetId)
        .findAllSync()
        .map((track) => '${track.syncId}|${track.mediaId}')
        .toSet();
    for (final track
        in database.tracks.filter().mangaIdEqualTo(duplicateId).findAllSync()) {
      final key = '${track.syncId}|${track.mediaId}';
      if (targetTrackKeys.contains(key)) continue;
      track.mangaId = targetId;
      database.tracks.putSync(track);
      targetTrackKeys.add(key);
    }

    final targetUpdateChapterIds = database.updates
        .filter()
        .mangaIdEqualTo(targetId)
        .findAllSync()
        .map((update) {
          update.chapter.loadSync();
          return update.chapter.value?.id;
        })
        .nonNulls
        .toSet();
    for (final update
        in database.updates
            .filter()
            .mangaIdEqualTo(duplicateId)
            .findAllSync()) {
      update.chapter.loadSync();
      final duplicateChapterId = update.chapter.value?.id;
      final targetChapterId = duplicateChapterId == null
          ? null
          : targetChapterIdByDuplicateId[duplicateChapterId];
      if (targetChapterId == null ||
          targetUpdateChapterIds.contains(targetChapterId)) {
        continue;
      }
      update
        ..mangaId = targetId
        ..chapter.value = database.chapters.getSync(targetChapterId);
      database.updates.putSync(update);
      update.chapter.saveSync();
      targetUpdateChapterIds.add(targetChapterId);
    }
  }

  String _localChildIdentity(Chapter chapter, ItemType itemType) =>
      itemType == ItemType.anime
      ? chimahonEpisodeIdentityValues(
          url: chapter.url ?? '',
          name: chapter.name ?? '',
          episodeNumber: chapter.chapterNumber,
        )
      : chimahonChapterIdentityValues(
          url: chapter.url ?? '',
          name: chapter.name ?? '',
          chapterNumber: chapter.chapterNumber,
        );

  void _deletePortableTitle({
    required Isar database,
    required Manga manga,
    required List<Chapter> chapters,
  }) {
    final mangaId = manga.id!;
    for (final history
        in database.historys.filter().mangaIdEqualTo(mangaId).findAllSync()) {
      database.historys.deleteSync(history.id!);
    }
    for (final track
        in database.tracks.filter().mangaIdEqualTo(mangaId).findAllSync()) {
      database.tracks.deleteSync(track.id!);
    }
    for (final update
        in database.updates.filter().mangaIdEqualTo(mangaId).findAllSync()) {
      database.updates.deleteSync(update.id!);
    }
    for (final chapter in chapters) {
      final chapterId = chapter.id;
      if (chapterId == null) continue;
      database.downloads.deleteSync(chapterId);
      database.chapters.deleteSync(chapterId);
    }
    database.epubBookProgress.filter().mangaIdEqualTo(mangaId).deleteAllSync();
    database.mangas.deleteSync(mangaId);
  }

  void _removeUnreferencedCategories({
    required Isar database,
    required ItemType itemType,
    required bool enabled,
    required Set<int> authoritativeIds,
    required Set<int> referencedIds,
  }) {
    if (!enabled) return;
    for (final category
        in database.categorys
            .filter()
            .forItemTypeEqualTo(itemType)
            .findAllSync()) {
      final categoryId = category.id;
      if (categoryId == null ||
          authoritativeIds.contains(categoryId) ||
          referencedIds.contains(categoryId)) {
        continue;
      }
      database.categorys.deleteSync(categoryId);
    }
  }

  Manga _newManga(
    BackupManga remote,
    ResolvedMihonBackupSource source,
    Map<int, int> categories,
  ) {
    final titles = const ChimahonMangaTitleAdapter().fromBackup(remote);
    final manga = Manga(
      source: source.name,
      sourceId: source.localId,
      mihonSourceId: source.portableId,
      author: remote.hasAuthor() ? remote.author : null,
      artist: remote.hasArtist() ? remote.artist : null,
      genre: remote.genre.toList(),
      imageUrl: remote.hasThumbnailUrl() ? remote.thumbnailUrl : null,
      lang: source.language,
      link: remote.url,
      name: titles.displayTitle,
      sourceTitle: titles.sourceTitle,
      status: _status(remote.status),
      description: remote.hasDescription() ? remote.description : null,
      categories: _categoryIds(remote.categories, categories),
      itemType: ItemType.manga,
      favorite: true,
      dateAdded: normalizeMihonTimestamp(remote.dateAdded.toInt()),
      lastUpdate: normalizeMihonTimestamp(remote.lastModifiedAt.toInt()),
      updatedAt: normalizeMihonTimestamp(remote.lastModifiedAt.toInt()),
    );
    _applyFavoriteVersion(manga, remote);
    return manga;
  }

  void _applyManga(
    Manga local,
    BackupManga remote,
    ResolvedMihonBackupSource source,
    Map<int, int> categories, {
    required bool categoriesAreAuthoritative,
    bool authoritativeDownload = false,
  }) {
    final titles = const ChimahonMangaTitleAdapter().fromBackup(remote);
    final remoteCategoryIds = _categoryIds(remote.categories, categories);
    final localHasCustomTitle =
        local.name != null &&
        local.sourceTitle != null &&
        local.name != local.sourceTitle;
    final preserveLocalCategories =
        !authoritativeDownload &&
        (remoteCategoryIds.isEmpty ||
            !categoriesAreAuthoritative ||
            local.sourceId == null);
    local
      ..source = source.name
      ..sourceId = source.localId
      ..mihonSourceId = source.portableId
      ..lang = source.installed ? source.language : local.lang
      ..link = remote.url
      ..sourceTitle = titles.sourceTitle
      ..name = remote.hasCustomTitle() || !localHasCustomTitle
          ? titles.displayTitle
          : local.name
      ..genre = remote.genre.toList()
      ..status = _status(remote.status)
      ..categories = preserveLocalCategories
          ? _unionIds(local.categories, remoteCategoryIds)
          : remoteCategoryIds
      ..favorite = true;
    if (remote.hasAuthor()) local.author = remote.author;
    if (remote.hasArtist()) local.artist = remote.artist;
    if (remote.hasDescription()) local.description = remote.description;
    if (remote.hasThumbnailUrl()) local.imageUrl = remote.thumbnailUrl;
    if (remote.hasDateAdded()) {
      local.dateAdded = normalizeMihonTimestamp(remote.dateAdded.toInt());
    }
    if (remote.hasLastModifiedAt()) {
      final modified = normalizeMihonTimestamp(remote.lastModifiedAt.toInt());
      local
        ..lastUpdate = modified
        ..updatedAt = modified;
    }
    _applyFavoriteVersion(local, remote);
  }

  Manga _newAnime(
    BackupAnime remote,
    ResolvedMihonBackupSource source,
    Map<int, int> categories,
  ) {
    final anime = Manga(
      source: source.name,
      sourceId: source.localId,
      mihonSourceId: source.portableId,
      author: remote.hasAuthor() ? remote.author : null,
      artist: remote.hasArtist() ? remote.artist : null,
      genre: remote.genre.toList(),
      imageUrl: remote.hasThumbnailUrl() ? remote.thumbnailUrl : null,
      lang: source.language,
      link: remote.url,
      name: remote.title,
      sourceTitle: remote.title,
      status: _status(remote.status),
      description: remote.hasDescription() ? remote.description : null,
      categories: _categoryIds(remote.categories, categories),
      itemType: ItemType.anime,
      favorite: true,
      dateAdded: normalizeMihonTimestamp(remote.dateAdded.toInt()),
      lastUpdate: normalizeMihonTimestamp(remote.lastModifiedAt.toInt()),
      updatedAt: normalizeMihonTimestamp(remote.lastModifiedAt.toInt()),
    );
    _applyAnimeFavoriteVersion(anime, remote);
    return anime;
  }

  void _applyAnime(
    Manga local,
    BackupAnime remote,
    ResolvedMihonBackupSource source,
    Map<int, int> categories, {
    required bool categoriesAreAuthoritative,
    bool authoritativeDownload = false,
  }) {
    final remoteCategoryIds = _categoryIds(remote.categories, categories);
    final preserveLocalCategories =
        !authoritativeDownload &&
        (remoteCategoryIds.isEmpty ||
            !categoriesAreAuthoritative ||
            local.sourceId == null);
    local
      ..source = source.name
      ..sourceId = source.localId
      ..mihonSourceId = source.portableId
      ..lang = source.installed ? source.language : local.lang
      ..link = remote.url
      ..sourceTitle = remote.title
      ..name = remote.title
      ..genre = remote.genre.toList()
      ..status = _status(remote.status)
      ..categories = preserveLocalCategories
          ? _unionIds(local.categories, remoteCategoryIds)
          : remoteCategoryIds
      ..favorite = true;
    if (remote.hasAuthor()) local.author = remote.author;
    if (remote.hasArtist()) local.artist = remote.artist;
    if (remote.hasDescription()) local.description = remote.description;
    if (remote.hasThumbnailUrl()) local.imageUrl = remote.thumbnailUrl;
    if (remote.hasDateAdded()) {
      local.dateAdded = normalizeMihonTimestamp(remote.dateAdded.toInt());
    }
    if (remote.hasLastModifiedAt()) {
      final modified = normalizeMihonTimestamp(remote.lastModifiedAt.toInt());
      local
        ..lastUpdate = modified
        ..updatedAt = modified;
    }
    _applyAnimeFavoriteVersion(local, remote);
  }

  (int, int) _upsertMangaChapters({
    required Isar database,
    required Manga manga,
    required Iterable<BackupChapter> remoteChapters,
    required List<Chapter> localChapters,
    required List<Chapter> localChaptersForManga,
  }) {
    var created = 0;
    var updated = 0;
    final portableLocal = _repairLocalChildAliases(
      database: database,
      manga: manga,
      localChapters: localChapters,
      localChaptersForManga: localChaptersForManga,
    );
    final localByKey = <String, Chapter>{
      for (final chapter in portableLocal) _localChapterKey(chapter): chapter,
    };
    final localKeyById = <int, String>{
      for (final entry in localByKey.entries)
        if (entry.value.id != null) entry.value.id!: entry.key,
    };
    final localByUrl = <String, List<Chapter>>{};
    for (final chapter in portableLocal) {
      localByUrl.putIfAbsent(chapter.url!, () => <Chapter>[]).add(chapter);
    }
    final remoteList = canonicalizeChimahonChapters(remoteChapters);
    final remoteUrlCounts = <String, int>{};
    for (final remote in remoteList) {
      remoteUrlCounts[remote.url] = (remoteUrlCounts[remote.url] ?? 0) + 1;
    }
    for (final remote in remoteList) {
      // A machine-local path from another device is neither readable here nor
      // a safe Chimahon identity. Ignore malformed/nonportable rows instead of
      // overwriting (or duplicating) Mangatan's retained local overlay.
      if (!const ChimahonLocalChapterPolicy().hasPortableWireIdentity(
        url: remote.hasUrl() ? remote.url : null,
        name: remote.hasName() ? remote.name : null,
        chapterNumber: remote.chapterNumber,
      )) {
        continue;
      }
      final remoteKey = _remoteChapterKey(remote);
      var local = localByKey[remoteKey];
      final sameUrl = localByUrl[remote.url];
      if (local == null &&
          remoteUrlCounts[remote.url] == 1 &&
          sameUrl?.length == 1) {
        // Mangatan source refreshes can rename or renumber a portable chapter.
        // Fall back by URL only when both sides prove it is unambiguous.
        local = sameUrl!.single;
      }
      if (local == null) {
        local = Chapter(
          mangaId: manga.id,
          name: remote.name,
          url: remote.url,
          dateUpload: '${normalizeMihonTimestamp(remote.dateUpload.toInt())}',
          scanlator: remote.hasScanlator() ? remote.scanlator : '',
          chapterNumber: remote.chapterNumber,
          isBookmarked: remote.bookmark,
          isRead: remote.read,
          lastPageRead: _progressString(remote.lastPageRead.toInt()),
          updatedAt: normalizeMihonTimestamp(remote.lastModifiedAt.toInt()),
        )..manga.value = manga;
        database.chapters.putSync(local);
        local.manga.saveSync();
        localChapters.add(local);
        localChaptersForManga.add(local);
        localByUrl.putIfAbsent(remote.url, () => <Chapter>[]).add(local);
        created++;
      } else {
        // Preserve archive paths and Mangatan-only source metadata. Keeping the
        // same row ID also keeps Download and Update links intact.
        local
          ..name = remote.name
          ..dateUpload = '${normalizeMihonTimestamp(remote.dateUpload.toInt())}'
          ..scanlator = remote.hasScanlator()
              ? remote.scanlator
              : local.scanlator
          ..chapterNumber = remote.chapterNumber
          ..isBookmarked = remote.bookmark
          ..isRead = remote.read
          ..lastPageRead = _progressString(remote.lastPageRead.toInt())
          ..updatedAt = normalizeMihonTimestamp(remote.lastModifiedAt.toInt());
        database.chapters.putSync(local);
        updated++;
      }
      final localId = local.id;
      if (localId != null) {
        final previousKey = localKeyById[localId];
        if (previousKey != null && previousKey != remoteKey) {
          localByKey.remove(previousKey);
        }
        localKeyById[localId] = remoteKey;
      }
      localByKey[remoteKey] = local;
    }
    return (created, updated);
  }

  (int, int) _upsertAnimeEpisodes({
    required Isar database,
    required Manga anime,
    required Iterable<BackupEpisode> remoteEpisodes,
    required List<Chapter> localChapters,
    required List<Chapter> localChaptersForAnime,
  }) {
    var created = 0;
    var updated = 0;
    final portableLocal = _repairLocalChildAliases(
      database: database,
      manga: anime,
      localChapters: localChapters,
      localChaptersForManga: localChaptersForAnime,
      episodes: true,
    );
    final localByKey = <String, Chapter>{
      for (final episode in portableLocal) _localEpisodeKey(episode): episode,
    };
    final localKeyById = <int, String>{
      for (final entry in localByKey.entries)
        if (entry.value.id != null) entry.value.id!: entry.key,
    };
    final localByUrl = <String, List<Chapter>>{};
    for (final episode in portableLocal) {
      localByUrl.putIfAbsent(episode.url!, () => <Chapter>[]).add(episode);
    }
    final remoteList = canonicalizeChimahonEpisodes(remoteEpisodes);
    final remoteUrlCounts = <String, int>{};
    for (final remote in remoteList) {
      remoteUrlCounts[remote.url] = (remoteUrlCounts[remote.url] ?? 0) + 1;
    }
    for (final remote in remoteList) {
      if (!const ChimahonLocalChapterPolicy().hasPortableWireIdentity(
        url: remote.hasUrl() ? remote.url : null,
        name: remote.hasName() ? remote.name : null,
        chapterNumber: remote.episodeNumber,
      )) {
        continue;
      }
      final remoteKey = _remoteEpisodeKey(remote);
      var local = localByKey[remoteKey];
      final sameUrl = localByUrl[remote.url];
      if (local == null &&
          remoteUrlCounts[remote.url] == 1 &&
          sameUrl?.length == 1) {
        local = sameUrl!.single;
      }
      if (local == null) {
        local = Chapter(
          mangaId: anime.id,
          name: remote.name,
          url: remote.url,
          dateUpload: '${normalizeMihonTimestamp(remote.dateUpload.toInt())}',
          scanlator: remote.hasScanlator() ? remote.scanlator : '',
          chapterNumber: remote.episodeNumber,
          isBookmarked: remote.bookmark,
          isRead: remote.seen,
          lastPageRead: _progressString(remote.lastSecondSeen.toInt()),
          isFiller: remote.fillermark,
          thumbnailUrl: remote.hasPreviewUrl() ? remote.previewUrl : null,
          description: remote.hasSummary() ? remote.summary : null,
          duration: remote.totalSeconds == Int64.ZERO
              ? null
              : '${remote.totalSeconds}',
          updatedAt: normalizeMihonTimestamp(remote.lastModifiedAt.toInt()),
        )..manga.value = anime;
        database.chapters.putSync(local);
        local.manga.saveSync();
        localChapters.add(local);
        localChaptersForAnime.add(local);
        localByUrl.putIfAbsent(remote.url, () => <Chapter>[]).add(local);
        created++;
      } else {
        local
          ..name = remote.name
          ..dateUpload = '${normalizeMihonTimestamp(remote.dateUpload.toInt())}'
          ..scanlator = remote.hasScanlator()
              ? remote.scanlator
              : local.scanlator
          ..chapterNumber = remote.episodeNumber
          ..isBookmarked = remote.bookmark
          ..isRead = remote.seen
          ..lastPageRead = _progressString(remote.lastSecondSeen.toInt())
          ..isFiller = remote.fillermark
          ..updatedAt = normalizeMihonTimestamp(remote.lastModifiedAt.toInt());
        if (remote.hasPreviewUrl()) local.thumbnailUrl = remote.previewUrl;
        if (remote.hasSummary()) local.description = remote.summary;
        if (remote.totalSeconds != Int64.ZERO) {
          local.duration = '${remote.totalSeconds}';
        }
        database.chapters.putSync(local);
        updated++;
      }
      final localId = local.id;
      if (localId != null) {
        final previousKey = localKeyById[localId];
        if (previousKey != null && previousKey != remoteKey) {
          localByKey.remove(previousKey);
        }
        localKeyById[localId] = remoteKey;
      }
      localByKey[remoteKey] = local;
    }
    return (created, updated);
  }

  void _upsertHistory({
    required Isar database,
    required Manga manga,
    required Iterable<BackupHistory> remoteHistory,
    required List<Chapter> localChapters,
    required List<History> localHistories,
  }) {
    final chaptersByUrl = <String, Chapter>{
      for (final chapter in localChapters)
        if (const ChimahonLocalChapterPolicy().hasPortableIdentity(chapter))
          chapter.url!: chapter,
    };
    final historiesByChapter = <int, History>{
      for (final history in localHistories)
        if (history.chapterId != null) history.chapterId!: history,
    };
    var lastRead = manga.lastRead ?? 0;
    for (final remote in remoteHistory) {
      final chapter = chaptersByUrl[remote.url];
      if (chapter?.id == null) continue;
      final readAt = normalizeMihonTimestamp(remote.lastRead.toInt());
      final existing = historiesByChapter[chapter!.id!];
      if (existing != null &&
          (int.tryParse(existing.date ?? '') ?? 0) > readAt) {
        lastRead = _max(lastRead, int.tryParse(existing.date ?? '') ?? 0);
        continue;
      }
      final history =
          existing ??
          History(
            mangaId: manga.id,
            date: '$readAt',
            itemType: manga.itemType,
            chapterId: chapter.id,
          );
      history
        ..mangaId = manga.id
        ..chapterId = chapter.id
        ..itemType = manga.itemType
        ..date = '$readAt'
        ..updatedAt = readAt
        ..readingTimeSeconds = remote.readDuration.toInt() ~/ 1000
        ..chapter.value = chapter;
      database.historys.putSync(history);
      history.chapter.saveSync();
      if (existing == null) {
        localHistories.add(history);
        historiesByChapter[chapter.id!] = history;
      }
      lastRead = _max(lastRead, readAt);
    }
    if (lastRead > (manga.lastRead ?? 0)) {
      manga.lastRead = lastRead;
      database.mangas.putSync(manga);
    }
  }

  void _upsertTracking({
    required Isar database,
    required Manga manga,
    required Iterable<BackupTracking> remoteTracking,
    required Int64 parentModifiedAt,
    required List<Track> localTracks,
  }) {
    if (manga.id == null) return;
    const adapter = ChimahonTrackingAdapter();
    final remoteRows = remoteTracking.toList(growable: false);
    final localByTracker = <int, Track>{
      for (final track in localTracks.where(
        (track) => track.mangaId == manga.id,
      ))
        if (track.syncId != null) track.syncId!: track,
    };
    for (final remote in remoteRows) {
      if (!adapter.isSupportedTracker(remote.syncId)) continue;
      final existing = localByTracker[remote.syncId];
      final imported = adapter.fromBackup(
        remote,
        mangaId: manga.id!,
        itemType: manga.itemType,
        existing: existing,
      );
      if (imported == null) continue;
      final parentModified = normalizeMihonTimestamp(parentModifiedAt.toInt());
      if (parentModified > 0) imported.updatedAt = parentModified;
      database.tracks.putSync(imported);
      if (existing == null) localTracks.add(imported);
      localByTracker[remote.syncId] = imported;
    }
    // Chimahon restore treats tracking as an upsert-only collection. Absence
    // can mean the tracker was excluded by sync settings or came from a
    // projection which cannot represent it; it is not a deletion signal.
    // Explicit local deletion intent is handled by the merger before upload.
  }

  void _applyFavoriteVersion(Manga local, BackupManga remote) {
    local.favoriteModifiedAt = remote.hasFavoriteModifiedAt()
        ? remote.favoriteModifiedAt.toInt()
        : null;
  }

  void _applyAnimeFavoriteVersion(Manga local, BackupAnime remote) {
    local.favoriteModifiedAt = remote.hasFavoriteModifiedAt()
        ? remote.favoriteModifiedAt.toInt()
        : null;
  }

  List<int> _categoryIds(
    Iterable<Int64> remoteOrders,
    Map<int, int> categories,
  ) => remoteOrders
      .map((order) => order.toInt())
      .map((order) => categories[order])
      .nonNulls
      .toSet()
      .toList();

  List<int> _unionIds(Iterable<int>? local, Iterable<int> remote) =>
      {...?local, ...remote}.toList();

  bool _sameIds(Iterable<int>? first, Iterable<int> second) {
    final firstSet = first?.toSet() ?? const <int>{};
    final secondSet = second.toSet();
    return firstSet.length == secondSet.length &&
        firstSet.containsAll(secondSet);
  }

  Map<String, int> _sourceUrlCounts(
    Iterable<({int source, String url})> identities,
  ) {
    final result = <String, int>{};
    for (final identity in identities) {
      final key = _sourceUrlKey(identity.source, identity.url);
      result[key] = (result[key] ?? 0) + 1;
    }
    return result;
  }

  String _sourceUrlKey(int source, String url) => '$source|$url';

  List<Chapter> _repairLocalChildAliases({
    required Isar database,
    required Manga manga,
    required List<Chapter> localChapters,
    required List<Chapter> localChaptersForManga,
    bool episodes = false,
  }) {
    final portable = localChaptersForManga
        .where(const ChimahonLocalChapterPolicy().hasPortableIdentity)
        .toList();
    final byIdentity = <String, List<Chapter>>{};
    for (final chapter in portable) {
      final key = episodes
          ? _localEpisodeKey(chapter)
          : _localChapterKey(chapter);
      byIdentity.putIfAbsent(key, () => <Chapter>[]).add(chapter);
    }

    for (final aliases in byIdentity.values.where(
      (aliases) => aliases.length > 1,
    )) {
      aliases.sort((left, right) => left.id!.compareTo(right.id!));
      final survivor = aliases.first;
      final latest = aliases.reduce((left, right) {
        final leftUpdated = left.updatedAt ?? 0;
        final rightUpdated = right.updatedAt ?? 0;
        if (leftUpdated != rightUpdated) {
          return leftUpdated > rightUpdated ? left : right;
        }
        return left.id! > right.id! ? left : right;
      });
      final archivePath = aliases
          .map((chapter) => chapter.archivePath?.trim() ?? '')
          .firstWhere((path) => path.isNotEmpty, orElse: () => '');
      survivor
        ..name = latest.name
        ..url = latest.url
        ..dateUpload = latest.dateUpload
        ..scanlator = latest.scanlator
        ..chapterNumber = chimahonCanonicalChildNumber(
          name: latest.name ?? '',
          sourceNumber: latest.chapterNumber,
        )
        ..isBookmarked = aliases.any((chapter) => chapter.isBookmarked ?? false)
        ..isRead = aliases.any((chapter) => chapter.isRead ?? false)
        ..lastPageRead = _progressString(
          aliases
              .map((chapter) => int.tryParse(chapter.lastPageRead ?? '') ?? 0)
              .fold<int>(0, _max),
        )
        ..archivePath = archivePath
        ..isFiller = latest.isFiller
        ..thumbnailUrl = latest.thumbnailUrl
        ..description = latest.description
        ..downloadSize = latest.downloadSize
        ..duration = latest.duration
        ..updatedAt = aliases
            .map((chapter) => chapter.updatedAt ?? 0)
            .fold<int>(0, _max);
      database.chapters.putSync(survivor);

      for (final duplicate in aliases.skip(1)) {
        _moveChapterReferences(
          database: database,
          duplicate: duplicate,
          survivor: survivor,
        );
        database.chapters.deleteSync(duplicate.id!);
        localChapters.removeWhere((chapter) => chapter.id == duplicate.id);
        localChaptersForManga.removeWhere(
          (chapter) => chapter.id == duplicate.id,
        );
        portable.removeWhere((chapter) => chapter.id == duplicate.id);
      }
    }
    return portable;
  }

  void _moveChapterReferences({
    required Isar database,
    required Chapter duplicate,
    required Chapter survivor,
  }) {
    for (final history
        in database.historys
            .filter()
            .chapterIdEqualTo(duplicate.id)
            .findAllSync()) {
      history
        ..chapterId = survivor.id
        ..chapter.value = survivor;
      database.historys.putSync(history);
      history.chapter.saveSync();
    }
    for (final update
        in database.updates
            .filter()
            .chapter((chapter) => chapter.idEqualTo(duplicate.id))
            .findAllSync()) {
      update.chapter.value = survivor;
      database.updates.putSync(update);
      update.chapter.saveSync();
    }

    final survivorDownload = database.downloads.getSync(survivor.id!);
    final duplicateDownload = database.downloads.getSync(duplicate.id!);
    if (survivorDownload != null || duplicateDownload != null) {
      final mergedDownload = Download(
        id: survivor.id,
        succeeded: _max(
          survivorDownload?.succeeded ?? 0,
          duplicateDownload?.succeeded ?? 0,
        ),
        failed: _max(
          survivorDownload?.failed ?? 0,
          duplicateDownload?.failed ?? 0,
        ),
        total: _max(
          survivorDownload?.total ?? 0,
          duplicateDownload?.total ?? 0,
        ),
        isDownload:
            (survivorDownload?.isDownload ?? false) ||
            (duplicateDownload?.isDownload ?? false),
        isStartDownload:
            (survivorDownload?.isStartDownload ?? false) ||
            (duplicateDownload?.isStartDownload ?? false),
      )..chapter.value = survivor;
      database.downloads.putSync(mergedDownload);
      mergedDownload.chapter.saveSync();
    }
    database.downloads.deleteSync(duplicate.id!);
  }

  String _localChapterKey(Chapter chapter) => chimahonChapterIdentityValues(
    url: chapter.url ?? '',
    name: chapter.name ?? '',
    chapterNumber: chapter.chapterNumber,
  );

  String _remoteChapterKey(BackupChapter chapter) =>
      chimahonChapterIdentity(chapter);

  String _localEpisodeKey(Chapter episode) => chimahonEpisodeIdentityValues(
    url: episode.url ?? '',
    name: episode.name ?? '',
    episodeNumber: episode.chapterNumber,
  );

  String _remoteEpisodeKey(BackupEpisode episode) =>
      chimahonEpisodeIdentity(episode);

  String _progressString(int value) => value == 0 ? '1' : '$value';

  Status _status(int value) => switch (value) {
    1 => Status.ongoing,
    2 => Status.completed,
    4 => Status.publishingFinished,
    5 => Status.canceled,
    6 => Status.onHiatus,
    _ => Status.unknown,
  };

  String _normalized(String? value) => (value ?? '').trim().toLowerCase();

  int _max(int first, int second) => first >= second ? first : second;

  Map<int, List<T>> _groupByMangaId<T>(
    Iterable<T> values,
    int? Function(T value) mangaIdOf,
  ) {
    final result = <int, List<T>>{};
    for (final value in values) {
      final mangaId = mangaIdOf(value);
      if (mangaId == null) continue;
      result.putIfAbsent(mangaId, () => <T>[]).add(value);
    }
    return result;
  }

  Map<({ItemType type, String url}), List<Manga>> _indexMangasByTypeAndUrl(
    Iterable<Manga> mangas,
  ) {
    final result = <({ItemType type, String url}), List<Manga>>{};
    for (final manga in mangas) {
      if (manga.isLocalArchive == true) continue;
      result
          .putIfAbsent((
            type: manga.itemType,
            url: manga.link ?? '',
          ), () => <Manga>[])
          .add(manga);
    }
    return result;
  }

  Iterable<Manga> _titleCandidates({
    required List<Manga> all,
    required Map<({ItemType type, String url}), List<Manga>> indexed,
    required ItemType itemType,
    required String url,
  }) => url.isEmpty
      ? all
      : indexed[(type: itemType, url: url)] ?? const <Manga>[];
}
