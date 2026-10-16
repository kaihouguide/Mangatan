import 'dart:convert';
import 'dart:io'; // For I/O-operations
import 'dart:typed_data';

import 'package:isar_community/isar.dart'; // Isar database package for local storage
import 'package:mangayomi/main.dart'; // Exposes the global `isar` instance
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/models/epub_book_progress.dart';
import 'package:mangayomi/modules/library/providers/local_archive.dart';
import 'package:mangayomi/src/rust/api/epub.dart';
import 'package:mangayomi/services/epub_chapter_metadata.dart';
import 'package:mangayomi/services/sync/chimahon_novel_materializer.dart';
import 'package:mangayomi/utils/extensions/others.dart';
import 'package:path/path.dart' as p; // For manipulating file system paths
import 'package:bot_toast/bot_toast.dart'; // For Exceptions
import 'package:mangayomi/models/manga.dart'; // Has Manga model and ItemType enum
import 'package:mangayomi/models/chapter.dart'; // Has Chapter model with archivePath
import 'package:mangayomi/providers/storage_provider.dart'; // Provides storage directory selection
import 'package:mangayomi/repositories/chapter_repository.dart';
import 'package:mangayomi/repositories/manga_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart'; // Annotations for code generation
part 'file_scanner.g.dart';

/// Folder scanning can safely infer one cloud placeholder only when there is
/// exactly one EPUB. Multi-book folders retain their normal grouped-library
/// behavior and leave every cloud placeholder for explicit reconciliation.
bool canAutoLinkScannedCloudNovel(int epubFileCount) => epubFileCount == 1;

/// Prevents a scanned EPUB from moving an empty progress row out of a second
/// cloud parent. Only progress already owned by the selected folder parent is
/// eligible for in-place adoption.
List<EpubBookProgress> scannedNovelProgressCandidates(
  Iterable<EpubBookProgress> progresses,
  int parentId,
) => progresses
    .where((progress) => progress.mangaId == parentId)
    .toList(growable: false);

/// Produces a stable identity for a local filesystem path.
///
/// Windows paths are case-insensitive and may arrive with either separator.
/// Keeping the drive/root in the key is important: a custom folder on `D:`
/// must never alias a title with the same relative path on `C:`.
String localLibraryPathKey(String path) {
  final isWindowsPath =
      RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path) || path.startsWith(r'\\');
  final context = p.Context(
    style: isWindowsPath ? p.Style.windows : p.Style.posix,
  );
  final normalized = context.normalize(path);
  return isWindowsPath ? normalized.toLowerCase() : normalized;
}

@riverpod
class LocalFoldersState extends _$LocalFoldersState {
  @override
  List<String> build() {
    return isar.settings.getSync(227)!.localFolders ?? [];
  }

  void set(List<String> value) {
    final settings = isar.settings.getSync(227)!;
    state = value;
    isar.writeTxnSync(
      () => isar.settings.putSync(
        settings
          ..localFolders = state
          ..updatedAt = DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }
}

/// Scans `Mangatan/local` folder (if exists) for Mangas/Animes and imports in library.
///
/// **Folder structure:**
/// ```
/// Mangatan/local/MangaName/CustomCover.jpg (optional)
/// Mangatan/local/MangaName/Chapter1/Page1.jpg
/// Mangatan/local/MangaName/Chapter2.cbz (or .cbr/.rar)
/// Mangatan/local/AnimeName/Episode1.mp4
/// Mangatan/local/NovelName/NovelName.epub
/// ```
/// **Supported filetypes:** (taken from lib/modules/library/providers/local_archive.dart, line 98)
/// ```
/// Videotypes:   mp4, mov, avi, flv, wmv, mpeg, mkv
/// Imagetypes:   jpg, jpeg, png, webp, avif
/// Archivetypes: cbz, zip, cbr, rar, cbt, tar
/// Other types: epub
/// ```
@riverpod
Future<void> scanLocalLibrary(Ref ref) async {
  // Get /local directory
  final localDir = await getLocalLibrary();
  await _scanDirectory(ref, localDir);
  final customDirs = ref.read(localFoldersStateProvider);
  for (final dir in customDirs) {
    await _scanDirectory(ref, Directory(dir));
  }
}

Future<void> _scanDirectory(Ref ref, Directory? dir) async {
  // Don't do anything if /local doesn't exist
  if (dir == null || !await dir.exists()) return;

  final dateNow = DateTime.now().millisecondsSinceEpoch;

  // Fetch all existing mangas in library that are in /local (or \local)
  final List<Manga> existingMangas = await isar.mangas
      .filter()
      .sourceEqualTo("local")
      .or()
      .linkContains("Mangatan/local")
      .or()
      .linkContains("Mangatan\\local")
      .or()
      .linkContains("Mangayomi/local")
      .or()
      .linkContains("Mangayomi\\local")
      .findAll();
  // A restored or hand-edited row can lack its path; it cannot be matched to
  // a folder, and must not abort the whole scan.
  final mangaMap = {
    for (var m in existingMangas)
      if (m.link case final link?) localLibraryPathKey(link): m,
  };

  // Fetch all chapters for existing mangas
  final existingMangaIds = existingMangas.map((m) => m.id);
  final existingChapters = await chapterRepository.getAllByMangaIds(
    existingMangaIds,
  );

  // Map where the key is manga ID and the value is a set of chapter paths.
  final chaptersMap = <int, Set<String>>{};

  // Add manga.Ids with all the corresponding relative! paths (Manga/Chapter)
  for (var chap in existingChapters) {
    final archivePath = chap.archivePath;
    if (archivePath == null || chap.mangaId == null) continue;
    final path = localLibraryPathKey(archivePath);
    // For the given manga ID, add the path to its associated set.
    // If there's no entry for the manga ID yet, create a new empty set.
    chaptersMap.putIfAbsent(chap.mangaId!, () => <String>{}).add(path);
  }

  // Collect all chapter paths chaptersMap into a single set for easy lookup.
  final existingPaths = chaptersMap.values.expand((s) => s).toSet();
  List<Manga> processedMangas = <Manga>[];
  final List<List<dynamic>> newChapters = [];
  // A matching cloud placeholder must keep its exact source/link markers
  // until every EPUB in the folder has passed the full parser. Otherwise a
  // malformed file could turn remote cache into apparent local sync intent.
  final pendingCloudFolderByParentId = <int, String>{};

  // If newMangas > 0, save all collected Mangas in library first to get a Manga ID
  int newMangas = 0;

  /// helper function to add chapters to newChapters list
  void addNewChapters(List<FileSystemEntity> items, bool imageFolder) {
    for (final chapter in items) {
      final pathKey = localLibraryPathKey(chapter.path).trim();
      // Skip if the path is empty (invalid entry).
      if (pathKey.isEmpty) continue;

      if (!existingPaths.contains(pathKey)) {
        newChapters.add([chapter.path, imageFolder]);
        existingPaths.add(pathKey);
      }
    }
  }

  // Iterate over each sub-directory (each representing a title, Manga or Anime)
  await for (final folder in dir.list()) {
    if (folder is! Directory) continue;
    final title = p.basename(folder.path); // Anime/Manga title
    final folderPathKey = localLibraryPathKey(folder.path);

    // List all folders and files inside a Manga/Anime title
    final children = await folder.list().toList();
    final subDirs = children.whereType<Directory>().toList();
    final files = children.whereType<File>().toList();

    // Determine itemtype
    final hasImagesFolders = subDirs
        .where((e) => !e.path.endsWith("_subtitles"))
        .isNotEmpty;
    final hasArchives = files.any((f) => _isArchive(f.path));
    final hasVideos = files.any((f) => _isVideo(f.path));
    final epubFiles = files.where((file) => _isEpub(file.path)).toList();
    final hasEpubs = epubFiles.isNotEmpty;
    late ItemType itemType;
    if (hasImagesFolders || hasArchives) {
      itemType = ItemType.manga;
    } else if (hasVideos) {
      itemType = ItemType.anime;
    } else if (hasEpubs) {
      itemType = ItemType.novel;
    } else {
      continue; // nothing to import from this folder
    }
    // Does Manga/Anime already exist in library?
    final existingManga = mangaMap.containsKey(folderPathKey);

    // Create new Manga entry if it doesn't already exist
    Manga manga;
    if (existingManga) {
      manga = mangaMap[folderPathKey]!;
    } else {
      Manga? matchingCloudParent;
      if (itemType == ItemType.novel &&
          canAutoLinkScannedCloudNovel(epubFiles.length)) {
        try {
          final firstEpub = epubFiles.single;
          final book = await parseEpubFromPath(
            epubPath: firstEpub.path,
            fullData: false,
          );
          matchingCloudParent = const ChimahonNovelMaterializer()
              .matchingCloudParent(
                mangas: isar.mangas.where().findAllSync(),
                progresses: isar.epubBookProgress.where().findAllSync(),
                title: book.name,
                author: book.author,
              );
        } catch (_) {
          // Validation during the content pass below reports malformed EPUBs.
        }
      }
      if (matchingCloudParent != null) {
        manga = matchingCloudParent;
        final parentId = manga.id;
        if (parentId != null) {
          pendingCloudFolderByParentId[parentId] = folder.path;
        }
      } else {
        manga = Manga(
          favorite: false,
          source: 'local',
          author: '',
          artist: '',
          genre: [],
          imageUrl: '',
          lang: '',
          link: folder.path,
          name: title,
          status: Status.unknown,
          description: '',
          isLocalArchive: true,
          itemType: itemType,
          dateAdded: dateNow,
          lastUpdate: dateNow,
          sourceId: null,
        );
        newMangas++;
      }
    }

    // Detect a single image in item's root and use it as custom cover
    final imageFiles = files.where((f) => _isImage(f.path)).toList();
    if (imageFiles.length == 1) {
      try {
        final bytes = await File(imageFiles.first.path).readAsBytes();
        final byteList = bytes.toList();
        if (manga.customCoverImage != byteList) {
          manga.customCoverImage = Uint8List.fromList(byteList).getCoverImage;
          manga.lastUpdate = dateNow;
        }
      } catch (e) {
        BotToast.showText(text: "Error reading cover image: $e");
      }
    } else if (imageFiles.isEmpty && manga.customCoverImage != null) {
      manga.customCoverImage = null;
    }

    final jsonFiles = files.where((f) => _isJson(f.path)).toList();
    if (jsonFiles.isNotEmpty) {
      try {
        final str = await File(jsonFiles.first.path).readAsString();
        final data = jsonDecode(str) as Map<String, dynamic>?;
        manga.updateSourceTitle(data?["name"]);
        manga.description = data?["description"];
        manga.artist = data?["artist"];
        manga.author = data?["author"];
        manga.genre = data?["genre"]?.cast<String>();
        manga.status = data?["status"] != null
            ? Status.values[data!["status"]]
            : Status.unknown;
        manga.lastUpdate = dateNow;
      } catch (e) {
        BotToast.showText(text: "Error reading metadata: $e");
      }
    }

    processedMangas.add(manga);

    // Scan chapters/episodes
    if (hasImagesFolders) {
      // Each subdirectory is a chapter
      addNewChapters(subDirs, hasImagesFolders);
    } // Possible that image folders and archives are mixed in one manga
    if (hasArchives) {
      // Each comic archive file is a chapter
      final archives = files.where((f) => _isArchive(f.path)).toList();
      addNewChapters(archives, false);
    }
    if (hasVideos) {
      // Each .mp4 is an episode
      final videos = files.where((f) => _isVideo(f.path)).toList();
      addNewChapters(videos, false);
    }
    if (hasEpubs) {
      // Each .epub
      addNewChapters(epubFiles, false);
    }
  }

  final changedMangas = <Manga>[];
  for (var manga in processedMangas) {
    if (manga.lastUpdate == dateNow &&
        !pendingCloudFolderByParentId.containsKey(manga.id)) {
      // Filter out items that haven't been changed
      changedMangas.add(manga);
    }
  }
  try {
    // Save all new and changed items to the library
    await mangaRepository.putAll(changedMangas);
  } catch (e) {
    BotToast.showText(
      text: "Database write error. Manga/Anime couldn't be saved: $e",
    );
  }

  // If new Mangas have been added (no Id to save Chapters)
  if (newMangas > 0) {
    final pendingCloudParents = processedMangas
        .where((manga) => pendingCloudFolderByParentId.containsKey(manga.id))
        .toList(growable: false);
    // Fetch all existing mangas in library that are in /local (or \local)
    final savedMangas = await isar.mangas
        .filter()
        .sourceEqualTo("local")
        .or()
        .linkContains("Mangatan/local")
        .or()
        .linkContains("Mangatan\\local")
        .or()
        .linkContains("Mangayomi/local")
        .or()
        .linkContains("Mangayomi\\local")
        .findAll();
    // Save all retrieved Manga objects (now with id) matching the processedMangas list
    final newAddedMangas = [
      ...savedMangas.where(
        (m) =>
            m.link != null &&
            processedMangas.any(
              (newManga) =>
                  localLibraryPathKey(newManga.link!) ==
                  localLibraryPathKey(m.link!),
            ),
      ),
      ...pendingCloudParents,
    ];
    processedMangas.clear();
    processedMangas = newAddedMangas;
  }

  final chaptersToSave = <Chapter>[];
  final epubProgressToSave = <EpubBookProgress>[];
  int saveManga = 0; // Just to update the lastUpdate value of not new Mangas
  final mangaByFolder = {
    for (var m in processedMangas)
      localLibraryPathKey(pendingCloudFolderByParentId[m.id] ?? m.link!): m,
  };

  // iterate through newChapters elements, which are: ["full_path/to/chapter1", "true"]
  for (var pathBool in newChapters) {
    final chapterPath = pathBool[0];
    // pathBool[0] = first element of list (path)
    // dirname = remove last part of path (chapter name), = "full_path/to"
    // basename = remove everything except last (manga name) = "to"
    final itemFolder = localLibraryPathKey(p.dirname(chapterPath));
    final manga = mangaByFolder[itemFolder];
    if (manga != null) {
      if (manga.isLocalArchive != true) manga.hasLocalChapterOverlay = true;
      if (manga.itemType == ItemType.novel) {
        final book = await parseEpubFromPath(
          epubPath: chapterPath,
          fullData: true,
        );

        final pendingCloudFolder = pendingCloudFolderByParentId[manga.id];
        if (pendingCloudFolder != null) {
          manga
            ..source = 'local'
            ..link = pendingCloudFolder
            ..lastUpdate = dateNow
            ..description = manga.description == chimahonMissingEpubGuidance
                ? ''
                : manga.description;
          saveManga++;
        }

        if (book.cover != null) {
          manga.customCoverImage = book.cover!.getCoverImage;
          saveManga++;
        }
        chaptersToSave.addAll(
          epubShortcutChapters(
            book: book,
            manga: manga,
            mangaId: manga.id!,
            archivePath: chapterPath,
          ),
        );
        final progress = const ChimahonNovelMaterializer()
            .progressForImportedEpub(
              progresses: scannedNovelProgressCandidates(
                isar.epubBookProgress.where().findAllSync(),
                manga.id!,
              ),
              mangaId: manga.id!,
              archivePath: chapterPath,
              title: book.name,
              author: book.author,
              lang: book.language,
            );
        epubProgressToSave.add(progress);
      } else {
        final chapterFile = File(chapterPath);
        final chap = Chapter(
          mangaId: manga.id,
          name:
              pathBool[1] // If Chapter is an image folder or archive/video
              ? p.basename(chapterPath)
              : p.basenameWithoutExtension(chapterPath),
          dateUpload: dateNow.toString(),
          archivePath: chapterPath,
          downloadSize: chapterFile.existsSync()
              ? chapterFile.lengthSync().formattedFileSize()
              : null,
        );
        chaptersToSave.add(chap);
      }
      if (manga.lastUpdate != dateNow) {
        manga.lastUpdate = dateNow;
        saveManga++;
      }
    }
  }
  try {
    if (saveManga > 0) {
      // Just to update the lastUpdate value of not new Mangas
      await mangaRepository.putAll(processedMangas);
    }
  } catch (e) {
    BotToast.showText(text: "Error saving chapter/episode to library: $e");
  }
  try {
    if (chaptersToSave.isNotEmpty) {
      await isar.writeTxn(() async {
        // insert chapters
        await isar.chapters.putAll(chaptersToSave);
        if (epubProgressToSave.isNotEmpty) {
          await isar.epubBookProgress.putAll(epubProgressToSave);
        }

        // for each one, set its link and save it
        for (final chap in chaptersToSave) {
          chap.manga.value = processedMangas.firstWhere(
            (m) => m.id == chap.mangaId,
          );
          await chap.manga.save();
        }
      });
    }
  } catch (e) {
    BotToast.showText(
      text: "Database write error. Manga/Anime couldn't be saved: $e",
    );
  }
}

/// Returns the `/local` directory inside the app's default storage.
Future<Directory?> getLocalLibrary() async {
  try {
    final dir = await StorageProvider().getDefaultDirectory();
    return dir == null ? null : Directory(p.join(dir.path, 'local'));
  } catch (e) {
    BotToast.showText(text: "Error getting local library: $e");
    return null;
  }
}

/// Fork-local chapters store an absolute archive path, so no virtual-folder
/// translation is needed when opening them.
Future<String> resolveLocalArchivePath(String archivePath) async => archivePath;

/// Returns if file is a json
bool _isJson(String path) {
  final ext = p.extension(path).toLowerCase();
  return ext == '.json';
}

/// Returns if file is an image
bool _isImage(String path) {
  final ext = p.extension(path).toLowerCase();
  return ext == '.jpg' ||
      ext == '.jpeg' ||
      ext == '.png' ||
      ext == '.webp' ||
      ext == '.avif';
}

/// Returns if file is an archive
bool _isArchive(String path) {
  final ext = p.extension(path).toLowerCase();
  return ext == '.cbz' ||
      ext == '.zip' ||
      ext == '.cbr' ||
      ext == '.rar' ||
      ext == '.cbt' ||
      ext == '.tar';
}

/// Returns if file is a video
bool _isVideo(String path) {
  final ext = p.extension(path).toLowerCase();
  const videoExtensions = {
    '.mp4',
    '.mov',
    '.avi',
    '.flv',
    '.wmv',
    '.mpeg',
    '.mkv',
  };
  return videoExtensions.contains(ext);
}

/// Returns if file is an epub or html
bool _isEpub(String path) {
  final ext = p.extension(path).toLowerCase();
  return ext == '.epub';
}
