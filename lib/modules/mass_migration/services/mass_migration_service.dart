import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangayomi/eval/model/m_manga.dart';
import 'package:mangayomi/models/changed.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/history.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/mass_migration/models/mass_migration_models.dart';
import 'package:mangayomi/modules/manga/detail/providers/isar_providers.dart';
import 'package:mangayomi/modules/more/settings/sync/providers/sync_providers.dart';
import 'package:mangayomi/repositories/history_repository.dart';
import 'package:mangayomi/repositories/manga_repository.dart';
import 'package:mangayomi/repositories/track_repository.dart';
import 'package:mangayomi/services/get_detail.dart';
import 'package:mangayomi/services/search.dart';
import 'package:mangayomi/utils/chapter_recognition.dart';
import 'package:mangayomi/services/sync/chimahon_local_chapter_policy.dart';
import 'package:mangayomi/utils/extensions/string_extensions.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/update.dart';

Future<void> migrateLibraryItem({
  required WidgetRef ref,
  required Manga oldManga,
  required MManga selectedManga,
  required MManga preview,
  required Source destinationSource,
}) async {
  final migrationSnapshot = await _captureMigrationSnapshot(
    ref: ref,
    oldManga: oldManga,
  );
  await _rewriteMigratedItemMetadata(
    oldManga: oldManga,
    selectedManga: selectedManga,
    preview: preview,
    destinationSource: destinationSource,
  );
  await _syncMigratedMangaFromPreview(
    oldManga: oldManga,
    preview: preview,
    destinationSource: destinationSource,
  );
  await _restoreMigrationProgress(
    oldManga: oldManga,
    snapshot: migrationSnapshot,
  );
  ref.invalidate(getMangaDetailStreamProvider(mangaId: oldManga.id!));
}

class _MigrationSnapshot {
  const _MigrationSnapshot({
    required this.chaptersProgress,
    required this.sourceTitle,
    this.historyChapter,
    this.historyDate,
  });

  final List<Chapter> chaptersProgress;

  /// The title the item had before the migration rewrote it. Chapter names are
  /// parsed with their own item's title stripped out, so the old chapters have
  /// to be read against the old title and the new ones against the new one.
  final String sourceTitle;

  /// Chapter number of the last thing read, as [ChapterRecognition] sees it.
  final double? historyChapter;
  final String? historyDate;
}

Future<_MigrationSnapshot> _captureMigrationSnapshot({
  required WidgetRef ref,
  required Manga oldManga,
}) async {
  double? historyChapter;
  String? historyDate;
  final chaptersProgress = <Chapter>[];
  final existingChapters = isar.chapters
      .filter()
      .mangaIdEqualTo(oldManga.id)
      .findAllSync();
  const localChapterPolicy = ChimahonLocalChapterPolicy();
  final localOverlayChapterIds = oldManga.isLocalArchive == true
      ? const <int>{}
      : existingChapters
            .where(localChapterPolicy.isDeviceLocal)
            .map((chapter) => chapter.id)
            .nonNulls
            .toSet();
  oldManga.hasLocalChapterOverlay = localOverlayChapterIds.isNotEmpty;
  final sourceTitle = oldManga.name ?? '';

  isar.writeTxnSync(() {
    final histories = isar.historys
        .filter()
        .mangaIdEqualTo(oldManga.id)
        .sortByDate()
        .findAllSync();
    final portableHistories = histories
        .where((history) => !localOverlayChapterIds.contains(history.chapterId))
        .toList(growable: false);
    historyChapter = _chapterNumber(
      sourceTitle,
      portableHistories.lastOrNull?.chapter.value?.name,
    );
    historyDate = portableHistories.lastOrNull?.date;
    for (final history in portableHistories) {
      isar.historys.deleteSync(history.id!);
      ref
          .read(synchingProvider(syncId: 1).notifier)
          .addChangedPart(
            ActionType.removeHistory,
            history.id,
            '{}',
            false,
            clientId: history.clientId,
          );
    }
    for (final chapter in existingChapters) {
      // The parent keeps its stable Isar ID during migration, so local file
      // overlays can remain linked while only portable source rows are rebuilt.
      if (localOverlayChapterIds.contains(chapter.id)) continue;
      chaptersProgress.add(chapter);
      isar.updates
          .filter()
          .mangaIdEqualTo(chapter.mangaId)
          .chapterNameEqualTo(chapter.name)
          .deleteAllSync();
      isar.chapters.deleteSync(chapter.id!);
      ref
          .read(synchingProvider(syncId: 1).notifier)
          .addChangedPart(
            ActionType.removeChapter,
            chapter.id,
            '{}',
            false,
            clientId: chapter.clientId,
          );
    }
  });

  return _MigrationSnapshot(
    chaptersProgress: chaptersProgress,
    sourceTitle: sourceTitle,
    historyChapter: historyChapter,
    historyDate: historyDate,
  );
}

Future<void> _rewriteMigratedItemMetadata({
  required Manga oldManga,
  required MManga selectedManga,
  required MManga preview,
  required Source destinationSource,
}) {
  oldManga.resetTitleFromSource(selectedManga.name);
  oldManga.link = selectedManga.link;
  oldManga.imageUrl = selectedManga.imageUrl;
  oldManga.lang = destinationSource.lang;
  oldManga.source = destinationSource.name;
  oldManga.sourceId = destinationSource.id;
  oldManga.artist = preview.artist;
  oldManga.author = preview.author;
  oldManga.status = preview.status ?? oldManga.status;
  oldManga.description = preview.description;
  oldManga.genre = preview.genre;
  return mangaRepository.save(oldManga);
}

Future<void> _syncMigratedMangaFromPreview({
  required Manga oldManga,
  required MManga preview,
  required Source destinationSource,
}) async {
  final genre =
      preview.genre
          ?.map((entry) => entry.toString().trim())
          .where((entry) => entry.isNotEmpty)
          .toSet()
          .toList() ??
      [];

  final previewImageUrl = preview.imageUrl.trimmedOrDefault(oldManga.imageUrl);
  final previewSourceTitle = preview.name.trimmedOrDefault(
    oldManga.sourceTitle ?? oldManga.name,
  );
  oldManga
    ..imageUrl = previewImageUrl == null
        ? null
        : previewImageUrl.startsWith('http')
        ? previewImageUrl
        : '${destinationSource.baseUrl ?? ''}/${previewImageUrl.getUrlWithoutDomain}'
    ..resetTitleFromSource(previewSourceTitle)
    ..genre = genre.isEmpty ? oldManga.genre ?? [] : genre
    ..author = preview.author.trimmedOrDefault(oldManga.author) ?? ''
    ..artist = preview.artist.trimmedOrDefault(oldManga.artist) ?? ''
    ..status = preview.status == Status.unknown
        ? oldManga.status
        : preview.status ?? Status.unknown
    ..description =
        preview.description.trimmedOrDefault(oldManga.description) ?? ''
    ..link = preview.link.trimmedOrDefault(oldManga.link)
    ..source = destinationSource.name
    ..lang = destinationSource.lang
    ..itemType = destinationSource.itemType
    ..lastUpdate = DateTime.now().millisecondsSinceEpoch
    ..updatedAt = DateTime.now().millisecondsSinceEpoch;

  await mangaRepository.writeTransaction(() {
    final mangaId = mangaRepository.putSync(oldManga);
    final previewChapters = preview.chapters ?? const [];
    final chapters = previewChapters
        .map(
          (previewChapter) => Chapter(
            name: previewChapter.name ?? '',
            url: previewChapter.url?.trim() ?? '',
            dateUpload: previewChapter.dateUpload == null
                ? DateTime.now().millisecondsSinceEpoch.toString()
                : previewChapter.dateUpload.toString(),
            scanlator: previewChapter.scanlator ?? '',
            mangaId: mangaId,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
            isFiller: previewChapter.isFiller,
            thumbnailUrl: previewChapter.thumbnailUrl,
            description: previewChapter.description,
            downloadSize: previewChapter.downloadSize,
            duration: previewChapter.duration,
          )..manga.value = oldManga,
        )
        .toList();
    for (final chapter in chapters.reversed) {
      isar.chapters.putSync(chapter);
      chapter.manga.saveSync();
    }
  });
}

Future<void> _restoreMigrationProgress({
  required Manga oldManga,
  required _MigrationSnapshot snapshot,
}) {
  return mangaRepository.writeTransaction(() {
    // Index the destination's chapters by number once, then match on that
    // number. The old lookup extracted the leading digits of the name and ran
    // nameContains against them, so "Chapter 1" also matched "Chapter 10" and
    // "Chapter 19" and findFirst took whichever the index happened to return:
    // progress could land on a chapter the reader had never opened.
    final destinationTitle = oldManga.name ?? '';
    final byNumber = <double, Chapter>{};
    for (final chapter
        in isar.chapters.filter().mangaIdEqualTo(oldManga.id).findAllSync()) {
      final number = _chapterNumber(destinationTitle, chapter.name);
      if (number != null) byNumber.putIfAbsent(number, () => chapter);
    }

    for (final oldChapter in snapshot.chaptersProgress) {
      final number = _chapterNumber(snapshot.sourceTitle, oldChapter.name);
      final chapter = number == null ? null : byNumber[number];
      if (chapter != null) {
        chapter.isBookmarked = oldChapter.isBookmarked;
        chapter.lastPageRead = oldChapter.lastPageRead;
        chapter.isRead = oldChapter.isRead;
        isar.chapters.putSync(chapter);
      }
    }

    final historyChapter = snapshot.historyChapter == null
        ? null
        : byNumber[snapshot.historyChapter];
    if (historyChapter != null) {
      historyRepository.putSync(
        History(
          mangaId: oldManga.id,
          date:
              snapshot.historyDate ??
              DateTime.now().millisecondsSinceEpoch.toString(),
          itemType: oldManga.itemType,
          chapterId: historyChapter.id,
        )..chapter.value = historyChapter,
      );
    }
  });
}

Future<MassMigrationSearchResult> findBestMassMigrationMatch({
  required WidgetRef ref,
  required Manga manga,
  required Source destinationSource,
}) async {
  final queries = buildMassMigrationQueries(manga);

  for (final query in queries) {
    final pages = await ref.read(
      searchProvider(
        source: destinationSource,
        page: 1,
        query: query,
        filterList: const [],
      ).future,
    );
    final candidates = pages?.list ?? const <MManga>[];
    if (candidates.isEmpty) continue;
    return MassMigrationSearchResult(
      queries: queries,
      usedQuery: query,
      candidates: candidates,
      selected: _selectBestCandidate(
        manga: manga,
        queries: queries,
        candidates: candidates,
      ),
    );
  }

  return MassMigrationSearchResult(queries: queries, candidates: const []);
}

Future<MassMigrationResolvedItem> resolveMassMigrationItem({
  required WidgetRef ref,
  required Manga manga,
  required Source destinationSource,
}) async {
  try {
    final searchResult = await _resolveSearchResult(
      ref: ref,
      manga: manga,
      destinationSource: destinationSource,
    );
    return await _resolveMatchedPreview(
      ref: ref,
      manga: manga,
      destinationSource: destinationSource,
      searchResult: searchResult,
    );
  } catch (error) {
    return _buildErroredResolvedItem(
      sourceItem: manga,
      errorMessage: error.toString(),
    );
  }
}

Future<MassMigrationSearchResult> _resolveSearchResult({
  required WidgetRef ref,
  required Manga manga,
  required Source destinationSource,
}) {
  return findBestMassMigrationMatch(
    ref: ref,
    manga: manga,
    destinationSource: destinationSource,
  );
}

Future<MassMigrationResolvedItem> _resolveMatchedPreview({
  required WidgetRef ref,
  required Manga manga,
  required Source destinationSource,
  required MassMigrationSearchResult searchResult,
}) async {
  final selectedCandidate = searchResult.selected;
  if (selectedCandidate == null) {
    return MassMigrationResolvedItem(
      sourceItem: manga,
      searchResult: searchResult,
    );
  }

  try {
    final preview = await ref.read(
      getDetailProvider(
        url: selectedCandidate.link!,
        source: destinationSource,
      ).future,
    );
    return MassMigrationResolvedItem(
      sourceItem: manga,
      searchResult: searchResult,
      selectedCandidate: selectedCandidate,
      destinationPreview: preview,
      shouldMigrate: true,
    );
  } catch (error) {
    return MassMigrationResolvedItem(
      sourceItem: manga,
      searchResult: searchResult,
      selectedCandidate: selectedCandidate,
      errorMessage: error.toString(),
    );
  }
}

MassMigrationResolvedItem _buildErroredResolvedItem({
  required Manga sourceItem,
  required String errorMessage,
}) {
  return MassMigrationResolvedItem(
    sourceItem: sourceItem,
    searchResult: MassMigrationSearchResult(
      queries: buildMassMigrationQueries(sourceItem),
      candidates: const [],
    ),
    errorMessage: errorMessage,
  );
}

List<String> buildMassMigrationQueries(Manga manga) {
  final queries = <String>{};

  void addQuery(String? value) {
    final cleaned = value?.trim();
    if (cleaned == null || cleaned.isEmpty) return;
    queries.add(cleaned);
  }

  addQuery(manga.name);
  for (final track in trackRepository.getAllByMangaId(manga.id)) {
    addQuery(track.title);
  }

  final name = manga.name?.trim();
  if (name != null && name.isNotEmpty) {
    addQuery(name.split(RegExp(r'\s*[:\-|/]\s*')).first);
    final beforeParenthesis = name.split('(').first.trim();
    if (beforeParenthesis.isNotEmpty && beforeParenthesis != name) {
      addQuery(beforeParenthesis);
    }
    final matches = RegExp(r'\(([^)]+)\)').allMatches(name);
    for (final match in matches) {
      addQuery(match.group(1));
    }
  }

  return queries.toList();
}

/// The chapter number [ChapterRecognition] reads out of [chapterName], or null
/// when the name carries no number at all.
///
/// Migration used to do its own extraction, which meant it did not understand
/// decimal chapters, `ch.` notation, or volume and season noise, and it never
/// benefited from fixes to the shared parser.
double? _chapterNumber(String itemTitle, String? chapterName) {
  if (chapterName == null || chapterName.isEmpty) return null;
  // The exact number rather than the sort key, so a chapter 12 on one source
  // does not match a 12.5 on the other and carry the reader's progress onto
  // the wrong one.
  final (_, number) = ChapterRecognition().rawSeasonAndNumber(
    itemTitle,
    chapterName,
  );
  return (number ?? 0) > 0 ? number : null;
}

MManga _selectBestCandidate({
  required Manga manga,
  required List<String> queries,
  required List<MManga> candidates,
}) {
  candidates.sort((left, right) {
    final leftScore = _scoreCandidate(
      manga: manga,
      queries: queries,
      candidate: left,
    );
    final rightScore = _scoreCandidate(
      manga: manga,
      queries: queries,
      candidate: right,
    );
    return rightScore.compareTo(leftScore);
  });
  return candidates.first;
}

double _scoreCandidate({
  required Manga manga,
  required List<String> queries,
  required MManga candidate,
}) {
  final candidateName = _normalizeTitle(candidate.name);
  if (candidateName.isEmpty) return 0;

  var score = 0.0;
  for (final query in queries) {
    final normalizedQuery = _normalizeTitle(query);
    if (normalizedQuery.isEmpty) continue;
    if (normalizedQuery == candidateName) {
      score = score < 100 ? 100 : score;
      continue;
    }
    if (candidateName.contains(normalizedQuery) ||
        normalizedQuery.contains(candidateName)) {
      final ratio = normalizedQuery.length < candidateName.length
          ? normalizedQuery.length / candidateName.length
          : candidateName.length / normalizedQuery.length;
      score = score < (80 * ratio) ? 80 * ratio : score;
    }
    final tokenScore = _tokenOverlapScore(normalizedQuery, candidateName);
    score = score < tokenScore ? tokenScore : score;
  }

  final sourceAuthor = _normalizeTitle(manga.author);
  final sourceArtist = _normalizeTitle(manga.artist);
  final candidateAuthor = _normalizeTitle(candidate.author);
  final candidateArtist = _normalizeTitle(candidate.artist);
  if (sourceAuthor.isNotEmpty &&
      (sourceAuthor == candidateAuthor || sourceAuthor == candidateArtist)) {
    score += 15;
  }
  if (sourceArtist.isNotEmpty &&
      (sourceArtist == candidateArtist || sourceArtist == candidateAuthor)) {
    score += 10;
  }

  return score;
}

double _tokenOverlapScore(String left, String right) {
  final leftTokens = left.split(' ').where((token) => token.isNotEmpty).toSet();
  final rightTokens = right
      .split(' ')
      .where((token) => token.isNotEmpty)
      .toSet();
  if (leftTokens.isEmpty || rightTokens.isEmpty) return 0;
  final overlap = leftTokens.intersection(rightTokens).length;
  return (overlap / leftTokens.union(rightTokens).length) * 70;
}

String _normalizeTitle(String? value) {
  return value
          ?.toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
          .replaceAll(RegExp(r'\b(the|a|an)\b'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim() ??
      '';
}
