import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/epub_book_progress.dart';
import 'package:mangayomi/models/history.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/services/get_html_content.dart';
import 'package:mangayomi/src/rust/api/epub.dart';
import 'package:mangayomi/repositories/db_write_queue.dart';
import 'package:path/path.dart' as p;

const _epubChapterMetadataPrefix = 'mangatan:epub:v7:';

String epubChapterMetadata({
  required int spineIndex,
  required bool navigationEntry,
  int? logicalChapterSpineIndex,
  int? characterStart,
}) =>
    '$_epubChapterMetadataPrefix'
    '${navigationEntry ? 'navigation' : 'internal'}:'
    '$spineIndex:'
    '${logicalChapterSpineIndex ?? (navigationEntry ? spineIndex : -1)}:'
    '${characterStart ?? -1}';

/// Marker of a legacy whole-book EPUB row. Imports no longer write it;
/// [repairLocalEpubChapterMetadata] migrates such rows, and tests build them.
String epubUnsplitChapterMetadata() => '${_epubChapterMetadataPrefix}unsplit:0';

bool isManagedEpubChapter(Chapter chapter) =>
    chapter.description?.startsWith(_epubChapterMetadataPrefix) ?? false;

bool isInternalEpubSpineChapter(Chapter chapter) =>
    _hasEpubMetadataKind(chapter, 'internal');

bool isEpubNavigationChapter(Chapter chapter) =>
    _hasEpubMetadataKind(chapter, 'navigation');

bool isUnsplitEpubChapter(Chapter chapter) =>
    _hasEpubMetadataKind(chapter, 'unsplit');

bool _hasEpubMetadataKind(Chapter chapter, String kind) {
  final description = chapter.description;
  return description?.startsWith('mangatan:epub:') == true &&
      description!.contains(':$kind:');
}

int? epubChapterSpineIndex(Chapter chapter) {
  final description = chapter.description;
  if (description != null &&
      description.startsWith(_epubChapterMetadataPrefix)) {
    final parts = description.split(':');
    return parts.length >= 6 ? int.tryParse(parts[4]) : null;
  }
  return int.tryParse(chapter.dateUpload ?? '');
}

int? epubChapterCharacterStart(Chapter chapter) {
  final description = chapter.description;
  if (description == null || !description.startsWith('mangatan:epub:')) {
    return null;
  }
  final parts = description.split(':');
  if (parts.length < 7) return null;
  final value = int.tryParse(parts[6]);
  return value == null || value < 0 ? null : value;
}

Map<int, int> epubCharacterStartsBySpine(EpubNovel book) {
  final result = <int, int>{};
  var accumulated = 0;
  for (final chapter in book.chapters) {
    if (chapter.isLinear) {
      result[chapter.spineIndex] = accumulated;
      accumulated += chimahonChapterCharacterCount(chapter.content);
    }
  }
  return result;
}

List<Chapter> epubNavigationChaptersInSpineOrder(Iterable<Chapter> chapters) {
  final all = chapters.toList();
  final byArchive = <String, List<Chapter>>{};
  for (final chapter in all) {
    final archive = p.normalize(chapter.archivePath ?? '').toLowerCase();
    byArchive.putIfAbsent(archive, () => []).add(chapter);
  }

  final groups = byArchive.entries.toList()
    ..sort((a, b) {
      int firstId(List<Chapter> rows) => rows
          .map((row) => row.id ?? 0x7fffffff)
          .reduce((left, right) => left < right ? left : right);
      final byImportOrder = firstId(a.value).compareTo(firstId(b.value));
      return byImportOrder != 0 ? byImportOrder : a.key.compareTo(b.key);
    });

  final result = <Chapter>[];
  for (final group in groups) {
    final hasManagedRows = group.value.any(isManagedEpubChapter);
    final hasNavigationRows = group.value.any(isEpubNavigationChapter);
    final visibleRows =
        group.value
            .where(
              (chapter) => hasManagedRows
                  ? isEpubNavigationChapter(chapter) ||
                        (!hasNavigationRows && isUnsplitEpubChapter(chapter))
                  : !isInternalEpubSpineChapter(chapter),
            )
            .toList()
          ..sort((a, b) {
            final aIndex = epubChapterSpineIndex(a);
            final bIndex = epubChapterSpineIndex(b);
            if (aIndex != null && bIndex != null) {
              final order = aIndex.compareTo(bIndex);
              if (order != 0) return order;
            } else if (aIndex != null) {
              return -1;
            } else if (bIndex != null) {
              return 1;
            }
            return (a.id ?? 0).compareTo(b.id ?? 0);
          });
    result.addAll(visibleRows);
  }
  return result;
}

/// Returns the user-facing EPUB chapter containing [spineIndex].
///
/// A logical chapter can span multiple physical spine items, so the active
/// shortcut is the last navigation row whose spine does not exceed the live
/// reader position.
Chapter? epubNavigationChapterForSpine(
  Iterable<Chapter> chapters,
  int spineIndex,
) {
  final shortcuts = chapters.where(isEpubNavigationChapter).toList()
    ..sort(
      (left, right) => (epubChapterSpineIndex(left) ?? 0).compareTo(
        epubChapterSpineIndex(right) ?? 0,
      ),
    );
  if (shortcuts.isEmpty) return null;
  var current = shortcuts.first;
  for (final shortcut in shortcuts) {
    final shortcutSpine = epubChapterSpineIndex(shortcut);
    if (shortcutSpine == null || shortcutSpine > spineIndex) break;
    current = shortcut;
  }
  return current;
}

bool isLocalEpubManga(Manga manga) =>
    manga.itemType == ItemType.novel && (manga.isLocalArchive ?? false);

/// User-facing rows for counts, filters, and bulk chapter actions.
/// Legacy imports can still have physical spine rows before their first
/// repair, so project them to TOC shortcuts immediately.
List<Chapter> userFacingChapters(Manga manga) {
  final chapters = manga.chapters.toList(growable: false);
  return isLocalEpubManga(manga)
      ? epubNavigationChaptersInSpineOrder(chapters)
      : chapters;
}

/// Projects the live reader position onto TOC shortcut rows.
///
/// Rows before the current marker are read, the current row carries the
/// whole-book progress fraction, and later rows are unread. This is display
/// state only; the Chimahon-compatible bookmark remains independent.
List<Chapter> applyEpubShortcutPositionProjection({
  required Iterable<Chapter> chapters,
  required int spineIndex,
  required double overallProgress,
}) {
  final shortcuts = chapters.where(isEpubNavigationChapter).toList()
    ..sort(
      (left, right) => (epubChapterSpineIndex(left) ?? 0).compareTo(
        epubChapterSpineIndex(right) ?? 0,
      ),
    );
  if (shortcuts.isEmpty) return const [];

  var currentIndex = 0;
  for (var index = 0; index < shortcuts.length; index++) {
    if ((epubChapterSpineIndex(shortcuts[index]) ?? 0) > spineIndex) break;
    currentIndex = index;
  }
  final fraction = overallProgress.clamp(0.0, 1.0).toDouble();
  final completed = fraction >= 0.999999;
  final changed = <Chapter>[];
  for (var index = 0; index < shortcuts.length; index++) {
    final shortcut = shortcuts[index];
    final shouldBeRead = completed || index < currentIndex;
    final progress = !completed && index == currentIndex
        ? fraction.toString()
        : '';
    if (shortcut.isRead == shouldBeRead && shortcut.lastPageRead == progress) {
      continue;
    }
    shortcut
      ..isRead = shouldBeRead
      ..lastPageRead = progress;
    changed.add(shortcut);
  }
  return changed;
}

List<Chapter> epubShortcutChapters({
  required EpubNovel book,
  required Manga manga,
  required int mangaId,
  required String archivePath,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final characterStarts = epubCharacterStartsBySpine(book);
  final shortcuts = <Chapter>[
    for (final epubChapter in book.chapters)
      if (epubChapter.isNavigationEntry)
        Chapter(
          mangaId: mangaId,
          name: epubChapter.name,
          archivePath: archivePath,
          url: epubChapter.path,
          dateUpload: epubChapter.spineIndex.toString(),
          description: epubChapterMetadata(
            spineIndex: epubChapter.spineIndex,
            navigationEntry: true,
            characterStart: characterStarts[epubChapter.spineIndex] ?? 0,
          ),
          updatedAt: now,
        )..manga.value = manga,
  ];
  if (shortcuts.isNotEmpty) return shortcuts;
  return [
    Chapter(
      mangaId: mangaId,
      name: book.name,
      archivePath: archivePath,
      url: book.chapters.firstOrNull?.path,
      dateUpload: '0',
      description: epubChapterMetadata(
        spineIndex: 0,
        navigationEntry: true,
        characterStart: 0,
      ),
      updatedAt: now,
    )..manga.value = manga,
  ];
}

/// Reconciles local EPUB rows into TOC shortcuts plus independent book progress.
///
/// Navigation rows are independent read marks and jump targets. Whole-book
/// reader progress lives in [EpubBookProgress], so manga-oriented chapter
/// actions cannot change it. Physical spine documents remain runtime parser
/// data and are never user-facing database chapters.
Future<void> repairLocalEpubChapterMetadata(Manga manga) async {
  if (manga.itemType != ItemType.novel || !(manga.isLocalArchive ?? false)) {
    return;
  }
  final mangaId = manga.id;
  if (mangaId == null) return;

  final existing = await isar.chapters
      .filter()
      .mangaIdEqualTo(mangaId)
      .findAll();
  final epubRows = existing
      .where(
        (chapter) =>
            p.extension(chapter.archivePath ?? '').toLowerCase() == '.epub',
      )
      .toList();
  if (epubRows.isEmpty) return;

  final byArchive = <String, List<Chapter>>{};
  for (final chapter in epubRows) {
    final archive = chapter.archivePath;
    if (archive == null || archive.isEmpty) continue;
    byArchive.putIfAbsent(archive, () => []).add(chapter);
  }

  for (final entry in byArchive.entries) {
    final currentRows = entry.value;
    if (currentRows.isNotEmpty &&
        currentRows.every(isManagedEpubChapter) &&
        currentRows.every(isEpubNavigationChapter)) {
      final progressExists = await isar.epubBookProgress
          .filter()
          .mangaIdEqualTo(mangaId)
          .archivePathEqualTo(entry.key)
          .isNotEmpty();
      if (progressExists) continue;
    }

    EpubNovel book;
    try {
      book = await parseEpubFromPath(epubPath: entry.key, fullData: true);
    } catch (_) {
      continue;
    }
    final oldRows = currentRows
      ..sort((a, b) => (a.id ?? 0).compareTo(b.id ?? 0));
    final oldUnsplit = oldRows.where(isUnsplitEpubChapter).firstOrNull;
    final linearChapters = book.chapters
        .where((chapter) => chapter.isLinear)
        .toList(growable: false);
    final linearLength = linearChapters.length;
    final now = DateTime.now().millisecondsSinceEpoch;
    final recoveredBookmark = oldUnsplit == null
        ? _recoverBookmark(oldRows, linearChapters)
        : _bookmarkFromWholeBookFraction(
            double.tryParse(oldUnsplit.lastPageRead ?? '') ?? 0,
            linearLength,
          );
    final wholeBookWasRead =
        oldUnsplit?.isRead ??
        recoveredBookmark.chapterIndex >= linearLength - 1 &&
            recoveredBookmark.progress >= 0.9;
    final existingProgress = await isar.epubBookProgress
        .filter()
        .mangaIdEqualTo(mangaId)
        .archivePathEqualTo(entry.key)
        .findFirst();
    final progress =
        existingProgress ??
        EpubBookProgress.forImportedEpub(
          mangaId: mangaId,
          archivePath: entry.key,
          title: book.name,
          author: book.author,
          lang: book.language,
        );
    if (existingProgress == null) {
      progress
        ..chapterIndex = recoveredBookmark.chapterIndex
        ..progress = recoveredBookmark.progress
        ..characterCount = _chimahonExploredCharacterCount(
          linearChapters,
          recoveredBookmark.chapterIndex,
          recoveredBookmark.progress,
        )
        ..lastModified =
            recoveredBookmark.chapterIndex > 0 || recoveredBookmark.progress > 0
            ? oldRows
                  .map((row) => row.updatedAt ?? 0)
                  .fold<int>(
                    0,
                    (latest, value) => value > latest ? value : latest,
                  )
            : 0;
    }
    progress
      ..title = book.name
      ..author = book.author;
    progress.lang ??= book.language;

    final usedRows = <Chapter>{};
    final shortcuts = <Chapter>[];
    final characterStarts = epubCharacterStartsBySpine(book);
    for (final epubChapter in book.chapters.where(
      (chapter) => chapter.isNavigationEntry,
    )) {
      Chapter? shortcut = oldRows.cast<Chapter?>().firstWhere(
        (candidate) =>
            candidate != null &&
            !usedRows.contains(candidate) &&
            isEpubNavigationChapter(candidate) &&
            (_epubReferencesMatch(candidate.url, epubChapter.path) ||
                _epubReferencesMatch(candidate.url, epubChapter.href)),
        orElse: () => null,
      );
      shortcut ??= oldRows.cast<Chapter?>().firstWhere(
        (candidate) =>
            candidate != null &&
            !usedRows.contains(candidate) &&
            isEpubNavigationChapter(candidate) &&
            epubChapterSpineIndex(candidate) == epubChapter.spineIndex,
        orElse: () => null,
      );
      shortcut ??= Chapter(
        mangaId: mangaId,
        name: epubChapter.name,
        archivePath: entry.key,
        url: epubChapter.path,
      )..manga.value = manga;
      usedRows.add(shortcut);
      shortcut
        ..mangaId = mangaId
        ..name = epubChapter.name
        ..url = epubChapter.path
        ..archivePath = entry.key
        ..dateUpload = epubChapter.spineIndex.toString()
        ..description = epubChapterMetadata(
          spineIndex: epubChapter.spineIndex,
          navigationEntry: true,
          characterStart: characterStarts[epubChapter.spineIndex] ?? 0,
        )
        ..lastPageRead = ''
        ..updatedAt = now
        ..manga.value = manga;
      shortcuts.add(shortcut);
    }
    if (shortcuts.isEmpty) {
      final fallback = Chapter(
        mangaId: mangaId,
        name: book.name,
        archivePath: entry.key,
        url: book.chapters.firstOrNull?.path,
        dateUpload: '0',
        description: epubChapterMetadata(
          spineIndex: 0,
          navigationEntry: true,
          characterStart: 0,
        ),
        updatedAt: now,
      )..manga.value = manga;
      usedRows.add(fallback);
      shortcuts.add(fallback);
    }
    if (wholeBookWasRead) {
      for (final shortcut in shortcuts) {
        shortcut.isRead = true;
      }
    }

    final staleIds = oldRows
        .where((row) => !usedRows.contains(row))
        .map((row) => row.id)
        .whereType<int>()
        .toList(growable: false);
    await dbWriteQueue.run(
      () => isar.writeTxn(() async {
        await isar.epubBookProgress.put(progress);
        await isar.chapters.putAll(shortcuts);
        for (final chapter in shortcuts) {
          await chapter.manga.save();
        }
        if (staleIds.isNotEmpty) await isar.chapters.deleteAll(staleIds);

        final history = await isar.historys
            .filter()
            .mangaIdEqualTo(mangaId)
            .findFirst();
        final historyShortcut = _shortcutAtProgress(
          shortcuts,
          linearChapters,
          progress.chapterIndex,
          progress.progress,
        );
        if (history != null && history.chapterId != historyShortcut.id) {
          history
            ..chapterId = historyShortcut.id
            ..chapter.value = historyShortcut
            ..updatedAt = now;
          await isar.historys.put(history);
          await history.chapter.save();
        }
      }),
    );
  }
}

int _chimahonExploredCharacterCount(
  List<EpubChapter> linearChapters,
  int chapterIndex,
  double progress,
) {
  if (linearChapters.isEmpty) return 0;
  final currentIndex = chapterIndex.clamp(0, linearChapters.length - 1);
  var count = 0;
  for (var index = 0; index < currentIndex; index++) {
    count += chimahonChapterCharacterCount(linearChapters[index].content);
  }
  return count +
      (chimahonChapterCharacterCount(linearChapters[currentIndex].content) *
              progress.clamp(0.0, 1.0))
          .toInt();
}

({int chapterIndex, double progress}) _recoverBookmark(
  List<Chapter> rows,
  List<EpubChapter> linearChapters,
) {
  final spineLength = linearChapters.length;
  if (spineLength <= 0) return (chapterIndex: 0, progress: 0);
  final candidates =
      rows.where((row) => epubChapterSpineIndex(row) != null).toList()
        ..sort((a, b) => (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0));
  final current = candidates.firstOrNull;
  if (current == null) return (chapterIndex: 0, progress: 0);
  final physicalSpineIndex = epubChapterSpineIndex(current)!;
  var index = linearChapters.indexWhere(
    (chapter) => chapter.spineIndex == physicalSpineIndex,
  );
  if (index < 0) {
    index = 0;
    for (var i = 0; i < linearChapters.length; i++) {
      if (linearChapters[i].spineIndex > physicalSpineIndex) break;
      index = i;
    }
  }
  final localProgress = current.isRead == true
      ? 1.0
      : (double.tryParse(current.lastPageRead ?? '') ?? 0).clamp(0.0, 1.0);
  return (chapterIndex: index, progress: localProgress.toDouble());
}

({int chapterIndex, double progress}) _bookmarkFromWholeBookFraction(
  double fraction,
  int spineLength,
) {
  if (spineLength <= 0) return (chapterIndex: 0, progress: 0);
  final scaled = fraction.clamp(0.0, 1.0) * spineLength;
  if (scaled >= spineLength) {
    return (chapterIndex: spineLength - 1, progress: 1);
  }
  final chapterIndex = scaled.floor();
  return (chapterIndex: chapterIndex, progress: scaled - chapterIndex);
}

Chapter _shortcutAtProgress(
  List<Chapter> shortcuts,
  List<EpubChapter> linearChapters,
  int chapterIndex,
  double progress,
) {
  if (shortcuts.length == 1) return shortcuts.first;
  final clampedIndex = chapterIndex.clamp(
    0,
    linearChapters.isEmpty ? 0 : linearChapters.length - 1,
  );
  final targetSpine = linearChapters.isEmpty
      ? 0.0
      : linearChapters[clampedIndex].spineIndex + progress.clamp(0.0, 1.0);
  Chapter result = shortcuts.first;
  for (final shortcut in shortcuts) {
    final spineIndex = epubChapterSpineIndex(shortcut) ?? 0;
    if (spineIndex > targetSpine) break;
    result = shortcut;
  }
  return result;
}

bool _epubReferencesMatch(String? left, String right) {
  final normalizedLeft = _normalizeEpubReference(left);
  final normalizedRight = _normalizeEpubReference(right);
  if (normalizedLeft.isEmpty || normalizedRight.isEmpty) return false;
  return normalizedLeft == normalizedRight ||
      normalizedLeft.endsWith('/$normalizedRight') ||
      normalizedRight.endsWith('/$normalizedLeft');
}

String _normalizeEpubReference(String? value) {
  if (value == null || value.isEmpty) return '';
  final withoutSuffix = value.split('#').first.split('?').first;
  String decoded;
  try {
    decoded = Uri.decodeComponent(withoutSuffix);
  } catch (_) {
    decoded = withoutSuffix;
  }
  final parts = <String>[];
  for (final part in decoded.replaceAll('\\', '/').split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  return parts.join('/');
}
