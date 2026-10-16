import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/services/epub_chapter_metadata.dart';
import 'package:mangayomi/utils/chapter_recognition.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/download.dart';

/// Sort/identity keys that only bucket by season if numbering actually
/// repeats across seasons (a real reset) — otherwise chapters key by raw
/// number. Precise (not truncated) so split chapters (12, 12.1, 12.5, ...)
/// sort and dedup correctly instead of colliding at the same integer. A
/// null value means the name had no detectable number at all (e.g.
/// "Special") — distinct from a genuine chapter 0, so callers know not to
/// treat every such chapter as a duplicate of every other one.
Map<int?, double?> _chapterSortKeys(
  String mangaTitle,
  List<Chapter> chapterList,
) {
  final recognition = ChapterRecognition();
  final raw = <int?, (int, double?)>{
    for (final c in chapterList)
      c.id: switch (normalizeSourceChapterNumber(c.chapterNumber)) {
        final number? => (0, number),
        null => recognition.rawSeasonAndNumber(mangaTitle, c.name ?? ''),
      },
  };
  final episodeToSeasons = <double, Set<int>>{};
  for (final pair in raw.values) {
    if (pair.$2 == null) continue;
    episodeToSeasons.putIfAbsent(pair.$2!, () => {}).add(pair.$1);
  }
  // A single collision is more likely a stray "S1-5 Recap"-style title
  // falsely matching the season regex than a real reset — require several
  // before trusting it, since a genuine per-season reset repeats numbers
  // across many chapters, not just one.
  final collisions = episodeToSeasons.values
      .where((seasons) => seasons.length > 1)
      .length;
  final resets = collisions >= 3;
  return {
    for (final entry in raw.entries)
      entry.key: switch (entry.value.$2) {
        null => null,
        final ep =>
          resets
              ? (entry.value.$1 > 0 ? entry.value.$1 * 100000 + ep : ep)
              : ep,
      },
  };
}

List<Chapter> sortChaptersForDisplay({
  required Iterable<Chapter> chapters,
  required String mangaTitle,
  required int sortIndex,
  required bool reverse,
}) {
  final list = chapters.toList();
  final recognition = ChapterRecognition();
  final numCache = <Chapter, double>{};
  double chapterNumber(Chapter chapter) =>
      numCache[chapter] ??= recognition.resolveChapterNumber(
        mangaTitle,
        chapter.name ?? '',
        sourceChapterNumber: chapter.chapterNumber,
      );

  switch (sortIndex) {
    case 0:
      list.sort((a, b) {
        final scanlatorOrder = (a.scanlator ?? '').compareTo(b.scanlator ?? '');
        if (scanlatorOrder != 0) return scanlatorOrder;
        return chapterNumber(a).compareTo(chapterNumber(b));
      });
      break;
    case 2:
      list.sort(
        (a, b) => (int.tryParse(a.dateUpload ?? '') ?? 0).compareTo(
          int.tryParse(b.dateUpload ?? '') ?? 0,
        ),
      );
      break;
    case 3:
      list.sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));
      break;
    case 1:
    default:
      list.sort((a, b) => chapterNumber(a).compareTo(chapterNumber(b)));
      break;
  }

  return reverse ? list : list.reversed.toList();
}

extension MangaExtensions on Manga {
  /// Number of unread chapters, excluding chapters from scanlators the user has
  /// filtered out for this manga. Mirrors the chapter list's scanlator filter,
  /// so the library "unread" badge and the unread sort reflect what the user
  /// actually sees rather than counting duplicate chapters from hidden
  /// scanlators (#796).
  int get unreadChaptersCount {
    final filter = isar.settings
        .getSync(227)
        ?.filterScanlatorList
        ?.where((e) => e.mangaId == id)
        .firstOrNull
        ?.scanlators;
    if (filter == null || filter.isEmpty) {
      return chapters.where((c) => !(c.isRead ?? false)).length;
    }
    return chapters
        .where((c) => !(c.isRead ?? false) && !filter.contains(c.scanlator))
        .length;
  }

  /// Filtered chapters respecting the user's active filters (unread,
  /// bookmarked, downloaded, scanlator). Sorted by chapter number ascending.
  /// Base list — no user-chosen sort, no deduplication.
  List<Chapter> getFilteredChapters({Iterable<Chapter>? sourceChapters}) {
    final recognition = ChapterRecognition();
    final mangaTitle = name ?? '';
    final settings = isar.settings.getSync(227)!;

    final filterUnread =
        (settings.chapterFilterUnreadList!
                    .where((e) => e.mangaId == id)
                    .firstOrNull ??
                ChapterFilterUnread(mangaId: id, type: 0))
            .type!;

    final filterBookmarked =
        (settings.chapterFilterBookmarkedList!
                    .where((e) => e.mangaId == id)
                    .firstOrNull ??
                ChapterFilterBookmarked(mangaId: id, type: 0))
            .type!;

    final filterDownloaded =
        (settings.chapterFilterDownloadedList!
                    .where((e) => e.mangaId == id)
                    .firstOrNull ??
                ChapterFilterDownloaded(mangaId: id, type: 0))
            .type!;

    final scanlators = settings.filterScanlatorList ?? [];
    final filter = scanlators.where((e) => e.mangaId == id);
    final filterScanlator = filter.firstOrNull?.scanlators ?? [];

    // Memoize so each chapter name is parsed at most once during the sort.
    final numCache = <Chapter, double>{};
    double chapNum(Chapter c) =>
        numCache[c] ??= recognition.resolveChapterNumber(
          mangaTitle,
          c.name ?? '',
          sourceChapterNumber: c.chapterNumber,
        );

    // Sort by chapter number — DB insertion order is NOT guaranteed to be ascending
    final chapterSource = sourceChapters ?? chapters;
    final data = chapterSource.toList()
      ..sort((a, b) => chapNum(a).compareTo(chapNum(b)));

    if (isLocalEpubManga(this)) {
      data
        ..clear()
        ..addAll(epubNavigationChaptersInSpineOrder(chapterSource));
    }

    final chapterIds = data.map((c) => c.id).whereType<int>().toList();
    final downloadedIds = (filterDownloaded == 0 || chapterIds.isEmpty)
        ? const <int>{}
        : isar.downloads
              .filter()
              .anyOf(chapterIds, (q, id) => q.idEqualTo(id))
              .isDownloadEqualTo(true)
              .findAllSync()
              .map((d) => d.id!)
              .toSet();

    return data
        .where(
          (e) => filterUnread == 1
              ? e.isRead == false
              : filterUnread == 2
              ? e.isRead == true
              : true,
        )
        .where(
          (e) => filterBookmarked == 1
              ? e.isBookmarked == true
              : filterBookmarked == 2
              ? e.isBookmarked == false
              : true,
        )
        .where((e) {
          if (filterDownloaded == 0) return true;
          final dl = downloadedIds.contains(e.id);
          return filterDownloaded == 1 ? dl : !dl;
        })
        .where((e) => !filterScanlator.contains(e.scanlator))
        .toList();
  }

  /// Filtered chapters for display in the chapter list UI: same filters as
  /// [getFilteredChapters] with the user's chosen sort order and direction applied.
  List<Chapter> getSortedFilteredChapters({Iterable<Chapter>? sourceChapters}) {
    final settings = isar.settings.getSync(227)!;

    final sortChapterEntry =
        (settings.sortChapterList ?? const [])
            .where((e) => e.mangaId == id)
            .firstOrNull ??
        SortChapter(mangaId: id, index: 1);

    // Build on getFilteredChapters so filter logic lives in one place.
    return sortChaptersForDisplay(
      chapters: getFilteredChapters(sourceChapters: sourceChapters),
      mangaTitle: name ?? '',
      sortIndex: sortChapterEntry.index ?? 1,
      reverse: sortChapterEntry.reverse ?? false,
    );
  }

  /// Filtered chapters ready for sequential reading: same filters as
  /// [getFilteredChapters] but with duplicate chapter numbers collapsed to a
  /// single entry so the reader advances to the next story chapter rather than
  /// another scanlator's copy of the same one. Chapters with no detectable
  /// number (key is null — e.g. "Special") are never collapsed: there is no
  /// reliable way to tell them apart, so treating them all as duplicates
  /// would silently drop real chapters instead of just scanlator copies.
  List<Chapter> getChapterListForReading({Iterable<Chapter>? sourceChapters}) {
    final list = getFilteredChapters(sourceChapters: sourceChapters);
    if (isLocalEpubManga(this)) return list;
    final sortKeys = _chapterSortKeys(name ?? '', list);
    final seen = <double>{};
    return list.where((c) {
      final key = sortKeys[c.id];
      return key == null || seen.add(key);
    }).toList();
  }

  /// Number of currently-filtered chapters whose name has no detectable
  /// chapter/episode number at all — surfaced to the user since it means
  /// automatic sort/dedup can't place them reliably.
  int unrecognizedChapterNumberCount() {
    final list = getFilteredChapters();
    final sortKeys = _chapterSortKeys(name ?? '', list);
    return list.where((c) => sortKeys[c.id] == null).length;
  }

  /// Count of whole numbers missing from the recognized chapter sequence —
  /// e.g. chapters 1, 2, 4, 5 present means 1 (chapter 3) is missing. Decimal
  /// extras (12.5) are floored into their whole chapter, since they aren't
  /// part of the main numbering. Season-bucketed keys are unbucketed back to
  /// their raw episode number first, since gaps only make sense within one
  /// season's own numbering, not across a season * 100000 jump.
  int missingChapterCount() {
    final list = getFilteredChapters();
    final mangaTitle = name ?? '';
    final recognition = ChapterRecognition();
    final numbers = <int>{};
    for (final c in list) {
      final (_, ep) = recognition.rawSeasonAndNumber(mangaTitle, c.name ?? '');
      if (ep != null) numbers.add(ep.floor());
    }
    if (numbers.length < 2) return 0;
    final lowest = numbers.reduce((a, b) => a < b ? a : b);
    final highest = numbers.reduce((a, b) => a > b ? a : b);
    return (highest - lowest + 1) - numbers.length;
  }
}
