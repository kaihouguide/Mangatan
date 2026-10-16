import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/eval/model/m_bridge.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/epub_book_progress.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/modules/manga/archive_reader/models/models.dart';
import 'package:mangayomi/modules/manga/archive_reader/providers/archive_reader_providers.dart';
import 'package:mangayomi/services/epub_chapter_metadata.dart';
import 'package:mangayomi/services/sync/chimahon_novel_materializer.dart';
import 'package:mangayomi/src/rust/api/epub.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:mangayomi/main.dart';
part 'local_archive.g.dart';

@riverpod
Future importArchivesFromFile(
  Ref ref,
  Manga? mManga, {
  required ItemType itemType,
  required bool init,
  bool splitChapters = false,
}) async {
  final keepAlive = ref.keepAlive();
  try {
    final requestedParentId = mManga?.id;
    final currentParent = requestedParentId == null
        ? mManga
        : isar.mangas.getSync(requestedParentId);
    final currentParentId = currentParent?.id;
    final progress = itemType == ItemType.novel && currentParentId != null
        ? isar.epubBookProgress
              .filter()
              .mangaIdEqualTo(currentParentId)
              .findAllSync()
        : const <EpubBookProgress>[];
    final extensions = supportedLocalArchiveExtensions(itemType);
    final result = allowMultipleArchiveImport(currentParent, progress)
        ? await FilePicker.pickFiles(
            type: FileType.custom,
            allowedExtensions: extensions,
          )
        : [
            ?await FilePicker.pickFile(
              type: FileType.custom,
              allowedExtensions: extensions,
            ),
          ];
    if (result.isEmpty) return;

    final filePaths = result
        .map((file) => file.path)
        .whereType<String>()
        .toList();
    await _importArchivesFromPaths(
      ref,
      requestedParentId == null
          ? currentParent
          : isar.mangas.getSync(requestedParentId),
      filePaths: filePaths,
      itemType: itemType,
      init: init,
      splitChapters: splitChapters,
    );
  } finally {
    keepAlive.close();
  }
}

bool allowMultipleArchiveImport(
  Manga? parent,
  Iterable<EpubBookProgress> progress,
) =>
    parent == null ||
    !const ChimahonNovelMaterializer().isMissingEpubParent(parent, progress);

/// Chooses an already-persisted parent for one parsed EPUB.
///
/// A matching ghost wins over an unrelated supplied normal parent so its
/// bookmark is reconciled in place. A supplied ghost wins only when the
/// parsed identity matches that exact parent; mismatch never consumes it.
Manga? resolveExistingNovelImportParent({
  required Manga? requestedParent,
  required Manga? matchingCloudParent,
  required EpubBookProgress? matchingRequestedProgress,
  required bool requestedParentWasMissing,
}) {
  if (requestedParent != null &&
      matchingRequestedProgress?.mangaId == requestedParent.id) {
    return requestedParent;
  }
  if (requestedParentWasMissing) return matchingCloudParent;
  return matchingCloudParent ?? requestedParent;
}

/// Imports paths supplied by a non-picker source, such as desktop drag-and-drop.
@riverpod
Future<void> importArchivesFromPaths(
  Ref ref,
  Manga? mManga, {
  required List<String> filePaths,
  required ItemType itemType,
  required bool init,
  bool splitChapters = false,
}) async {
  final keepAlive = ref.keepAlive();
  try {
    await _importArchivesFromPaths(
      ref,
      mManga,
      filePaths: filterSupportedLocalArchivePaths(filePaths, itemType),
      itemType: itemType,
      init: init,
      splitChapters: splitChapters,
    );
  } finally {
    keepAlive.close();
  }
}

Future<void> _importArchivesFromPaths(
  Ref ref,
  Manga? mManga, {
  required List<String> filePaths,
  required ItemType itemType,
  required bool init,
  required bool splitChapters,
}) async {
  if (filePaths.isEmpty) return;

  final dateNow = DateTime.now().millisecondsSinceEpoch;
  // Novel chapters are always persisted now. Keep honoring the legacy flag
  // in the shared import API so older callers remain source-compatible.
  final persistEpubChapters = itemType == ItemType.novel || splitChapters;
  Manga? currentRequestedParent() {
    final requestedId = mManga?.id;
    if (requestedId == null || requestedId == Isar.autoIncrement) {
      return mManga;
    }
    return isar.mangas.getSync(requestedId);
  }

  final initialRequestedParent = currentRequestedParent();
  final sharedParent = itemType == ItemType.novel
      ? null
      : initialRequestedParent ??
            _newLocalArchiveParent(
              itemType: itemType,
              name: localArchiveName(filePaths.first),
              dateNow: dateNow,
            );
  Manga? novelSharedParent;
  if (sharedParent?.isLocalArchive != true && sharedParent != null) {
    sharedParent.hasLocalChapterOverlay = true;
  }
  const materializer = ChimahonNovelMaterializer();
  final suppliedParentWasMissing =
      itemType == ItemType.novel &&
      initialRequestedParent != null &&
      materializer.isMissingEpubParent(
        initialRequestedParent,
        isar.epubBookProgress.where().findAllSync(),
      );

  // One unreadable archive must not silently skip the rest of a multi-file
  // import; finish the others and report every failure together.
  final failures = <(String, Object, StackTrace)>[];
  for (final filePath in filePaths.reversed) {
    try {
      final (String, LocalExtensionType, Uint8List, String)? data =
          itemType == ItemType.manga
          ? await ref.watch(getArchivesDataFromFileProvider(filePath).future)
          : null;
      final name = localArchiveName(filePath);
      final book = itemType == ItemType.novel
          ? await parseEpubFromPath(
              epubPath: filePath,
              fullData: persistEpubChapters,
            )
          : null;
      final progressBeforeImport = itemType == ItemType.novel
          ? isar.epubBookProgress.where().findAllSync()
          : const <EpubBookProgress>[];
      final mangasBeforeImport = itemType == ItemType.novel
          ? isar.mangas.where().findAllSync()
          : const <Manga>[];
      final requestedParent = itemType == ItemType.novel
          ? currentRequestedParent()
          : initialRequestedParent;
      final matchingSuppliedProgress = suppliedParentWasMissing
          ? materializer.matchingCloudProgress(
              progresses: progressBeforeImport,
              title: book!.name,
              author: book.author,
              preferredMangaId: requestedParent?.id,
              allowUnidentifiablePreferredParent: true,
            )
          : null;
      final matchingCloudParent = itemType == ItemType.novel
          ? materializer.matchingCloudParent(
              mangas: mangasBeforeImport,
              progresses: progressBeforeImport,
              title: book!.name,
              author: book.author,
            )
          : null;
      final existingNovelParent = itemType == ItemType.novel
          ? resolveExistingNovelImportParent(
              requestedParent: requestedParent,
              matchingCloudParent: matchingCloudParent,
              matchingRequestedProgress: matchingSuppliedProgress,
              requestedParentWasMissing: suppliedParentWasMissing,
            )
          : null;
      final Manga manga;
      if (itemType != ItemType.novel) {
        manga = sharedParent!;
      } else if (existingNovelParent != null) {
        manga = existingNovelParent;
      } else {
        // A mismatched EPUB must not consume the selected ghost's bookmark.
        // Generic Chimahon import semantics create a separate normal book.
        manga = novelSharedParent ??= _newLocalArchiveParent(
          itemType: itemType,
          name: book!.name.trim().isEmpty ? name : book.name,
          dateNow: dateNow,
        );
        if (suppliedParentWasMissing) {
          botToast(
            'This EPUB does not match the selected cloud novel; imported separately.',
            second: 4,
          );
        }
      }
      final wasMissingEpub = materializer.isMissingEpubParent(
        manga,
        progressBeforeImport,
      );
      if (manga.isLocalArchive != true) manga.hasLocalChapterOverlay = true;

      if (init && itemType == ItemType.manga) {
        manga.customCoverImage = data!.$3.getCoverImage;
      }
      await isar.writeTxn(() async {
        final mangaId = await isar.mangas.put(manga);
        final List<Chapter> chapters = [];
        if (itemType == ItemType.novel) {
          if (book!.cover != null) {
            await isar.mangas.put(
              manga..customCoverImage = book.cover!.getCoverImage,
            );
          }
          chapters.addAll(
            epubShortcutChapters(
              book: book,
              manga: manga,
              mangaId: mangaId,
              archivePath: filePath,
            ),
          );
          final progress = materializer.progressForImportedEpub(
            progresses: progressBeforeImport,
            mangaId: mangaId,
            archivePath: filePath,
            title: book.name,
            author: book.author,
            lang: book.language,
            allowUnidentifiablePreferredParent:
                wasMissingEpub && manga.id == requestedParent?.id,
          );
          await isar.epubBookProgress.put(progress);
          if (wasMissingEpub && progress.id != Isar.autoIncrement) {
            manga
              ..source = 'archive'
              ..link = filePath
              ..description = manga.description == chimahonMissingEpubGuidance
                  ? ''
                  : manga.description
              ..name = book.name.trim().isEmpty ? manga.name : book.name
              ..sourceTitle = book.name
              ..author = book.author
              ..lang = book.language ?? manga.lang;
            await isar.mangas.put(manga);
          }
        } else {
          chapters.add(
            Chapter(
              name: itemType == ItemType.manga ? data!.$1 : name,
              archivePath: itemType == ItemType.manga ? data!.$4 : filePath,
              mangaId: manga.id,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            )..manga.value = manga,
          );
        }
        for (final chapter in chapters) {
          await isar.chapters.put(chapter);
          await chapter.manga.save();
        }
      });
    } catch (error, stackTrace) {
      failures.add((filePath, error, stackTrace));
    }
  }
  if (failures.isEmpty) return;
  if (failures.length == 1 && filePaths.length == 1) {
    final (_, error, stackTrace) = failures.single;
    Error.throwWithStackTrace(error, stackTrace);
  }
  throw StateError(
    'Could not import ${failures.length} of ${filePaths.length} files: '
    '${failures.map((failure) => '${localArchiveName(failure.$1)} (${failure.$2})').join('; ')}',
  );
}

Manga _newLocalArchiveParent({
  required ItemType itemType,
  required String name,
  required int dateNow,
}) => Manga(
  favorite: true,
  source: 'archive',
  author: '',
  itemType: itemType,
  genre: const [],
  imageUrl: '',
  lang: '',
  link: '',
  name: name,
  dateAdded: dateNow,
  lastUpdate: dateNow,
  status: Status.unknown,
  description: '',
  isLocalArchive: true,
  artist: '',
  updatedAt: dateNow,
  sourceId: null,
);

List<String> supportedLocalArchiveExtensions(ItemType itemType) {
  return switch (itemType) {
    ItemType.manga => const ['cbz', 'zip', 'cbr', 'rar', 'epub'],
    ItemType.anime => const ['mp4', 'mov', 'avi', 'flv', 'wmv', 'mpeg', 'mkv'],
    ItemType.novel => const ['epub'],
  };
}

List<String> filterSupportedLocalArchivePaths(
  Iterable<String> filePaths,
  ItemType itemType,
) {
  final extensions = supportedLocalArchiveExtensions(itemType).toSet();
  return filePaths.where((filePath) {
    final name = filePath.split(RegExp(r'[/\\]')).last;
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex < 0 || dotIndex == name.length - 1) return false;
    return extensions.contains(name.substring(dotIndex + 1).toLowerCase());
  }).toList();
}

String localArchiveName(String path) {
  return path
      .split('/')
      .last
      .split("\\")
      .last
      .replaceAll(
        RegExp(
          r'\.(mp4|mov|avi|flv|wmv|mpeg|mkv|cbz|zip|cbr|rar|cbt|tar|epub)$',
          caseSensitive: false,
        ),
        '',
      );
}

extension Uint8ListExtensions on Uint8List {
  Uint8List get getCoverImage => this;
}
