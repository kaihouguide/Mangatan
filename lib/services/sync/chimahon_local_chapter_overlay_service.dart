import 'dart:io';

import 'package:isar_community/isar.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/download.dart';
import 'package:mangayomi/models/epub_book_progress.dart';
import 'package:mangayomi/models/history.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/services/sync/chimahon_local_chapter_policy.dart';
import 'package:mangayomi/repositories/db_write_queue.dart';
import 'package:path/path.dart' as p;

typedef ChimahonLocalChapterPathDeleter = Future<void> Function(String path);

class ChimahonLocalChapterOverlayDeletionResult {
  const ChimahonLocalChapterOverlayDeletionResult({
    required this.deleted,
    required this.failed,
    required this.hasRemainingOverlay,
  });

  final List<Chapter> deleted;
  final List<Chapter> failed;
  final bool hasRemainingOverlay;
}

/// Owns destructive maintenance of Mangatan's device-local chapter overlay.
///
/// Chimahon never receives these rows. Explicit deletion therefore removes
/// the local file and row together, then derives the parent's visibility bit
/// from the rows that actually remain. Chapters sharing one archive (for
/// example split EPUB sections) keep that file until the final row is removed.
/// File removal is attempted before the database transaction so a permission
/// error cannot discard the only row through which the user can retry it.
class ChimahonLocalChapterOverlayService {
  const ChimahonLocalChapterOverlayService({
    this.policy = const ChimahonLocalChapterPolicy(),
  });

  final ChimahonLocalChapterPolicy policy;

  Future<ChimahonLocalChapterOverlayDeletionResult> deleteSelected({
    required Isar database,
    required Manga manga,
    required Iterable<Chapter> selectedChapters,
    ChimahonLocalChapterPathDeleter? deletePath,
  }) async {
    final mangaId = manga.id;
    if (mangaId == null || manga.isLocalArchive == true) {
      return ChimahonLocalChapterOverlayDeletionResult(
        deleted: const [],
        failed: const [],
        hasRemainingOverlay: false,
      );
    }

    final selectedIds = selectedChapters
        .map((chapter) => chapter.id)
        .nonNulls
        .toSet();
    final allChapters = database.chapters
        .filter()
        .mangaIdEqualTo(mangaId)
        .findAllSync();
    final selected = allChapters
        .where(
          (chapter) =>
              selectedIds.contains(chapter.id) && policy.isDeviceLocal(chapter),
        )
        .toList(growable: false);
    if (selected.isEmpty) {
      return ChimahonLocalChapterOverlayDeletionResult(
        deleted: const [],
        failed: const [],
        hasRemainingOverlay: allChapters.any(policy.isDeviceLocal),
      );
    }

    final selectedIdSet = selected.map((chapter) => chapter.id!).toSet();
    final remainingBeforeDelete = allChapters
        .where((chapter) => !selectedIdSet.contains(chapter.id))
        .toList(growable: false);
    final selectedByFile = <String, List<Chapter>>{};
    for (final chapter in selected) {
      final identity =
          policy.deviceLocalFileIdentity(chapter) ?? 'id:${chapter.id}';
      selectedByFile.putIfAbsent(identity, () => []).add(chapter);
    }

    final deleted = <Chapter>[];
    final failed = <Chapter>[];
    final pathDeleter = deletePath ?? _deleteLocalPath;
    for (final entry in selectedByFile.entries) {
      final fileStillUsed = remainingBeforeDelete.any(
        (chapter) => policy.deviceLocalFileIdentity(chapter) == entry.key,
      );
      if (!fileStillUsed) {
        final path = policy.deviceLocalPath(
          entry.value.first,
          windows: Platform.isWindows,
        );
        if (path == null || !p.isAbsolute(path)) {
          failed.addAll(entry.value);
          continue;
        }
        try {
          await pathDeleter(path);
        } on FileSystemException {
          failed.addAll(entry.value);
          continue;
        }
      }
      deleted.addAll(entry.value);
    }

    if (deleted.isEmpty) {
      return ChimahonLocalChapterOverlayDeletionResult(
        deleted: const [],
        failed: failed,
        hasRemainingOverlay: allChapters.any(policy.isDeviceLocal),
      );
    }

    late bool hasRemainingOverlay;
    // Queued: Isar rejects a synchronous transaction while a queued async
    // write (such as reading progress) is still open.
    await dbWriteQueue.run(
      () => database.writeTxnSync(() {
        for (final chapter in deleted) {
          database.historys
              .filter()
              .chapterIdEqualTo(chapter.id)
              .deleteAllSync();
          database.downloads.deleteSync(chapter.id!);
          database.chapters.deleteSync(chapter.id!);
        }

        final remaining = database.chapters
            .filter()
            .mangaIdEqualTo(mangaId)
            .findAllSync();
        hasRemainingOverlay = remaining.any(policy.isDeviceLocal);

        for (final chapter in deleted) {
          final archivePath = chapter.archivePath?.trim() ?? '';
          if (archivePath.isEmpty ||
              remaining.any(
                (candidate) => candidate.archivePath == archivePath,
              )) {
            continue;
          }
          database.epubBookProgress.deleteByMangaIdArchivePathSync(
            mangaId,
            archivePath,
          );
        }

        final storedManga = database.mangas.getSync(mangaId) ?? manga;
        storedManga.hasLocalChapterOverlay = hasRemainingOverlay;
        database.mangas.putSync(storedManga);
      }),
    );

    return ChimahonLocalChapterOverlayDeletionResult(
      deleted: deleted,
      failed: failed,
      hasRemainingOverlay: hasRemainingOverlay,
    );
  }

  static Future<void> _deleteLocalPath(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.directory) {
      // Source-backed overlays are archive files. Never recursively delete an
      // arbitrary directory supplied by persisted or restored metadata.
      throw FileSystemException(
        'Refusing to recursively delete a local chapter directory',
        path,
      );
    } else if (type == FileSystemEntityType.link) {
      await Link(path).delete();
    } else {
      await File(path).delete();
    }
  }
}
