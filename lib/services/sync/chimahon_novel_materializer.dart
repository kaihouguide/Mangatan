import 'package:isar_community/isar.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/epub_book_progress.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupNovel.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupSourceNovel.pb.dart';
import 'package:protobuf/protobuf.dart';
import 'package:mangayomi/services/sync/chimahon_novel_progress_adapter.dart';
import 'package:mangayomi/utils/chimahon_novel_identity.dart';

/// Source/link markers for a Chimahon novel whose metadata and reading state
/// are present locally while its EPUB bytes are not.
const chimahonCloudNovelSource = 'Chimahon sync';
const chimahonCloudNovelLinkPrefix = 'chimahon://novel/';
const chimahonMissingEpubBadge = 'Missing EPUB';
const chimahonMissingEpubGuidance =
    'EPUB file missing on this device. Select the matching EPUB to read.';

/// `BackupMihon.backupSourceNovels`, which Mangatan carries but does not model.
const _chimahonSourceNovelsTag = 702;

/// The novels in [backup] that can become Mangatan EPUB books.
///
/// Chimahon 2.4 also exports favorites from its novel extensions as
/// `backupNovels` rows, alongside a `backupSourceNovels` entry for the same
/// book. Mangatan has no source for them, so materializing one would leave a
/// "Missing EPUB" entry that no file can satisfy. They still travel on the
/// wire unchanged; only the local library projection skips them.
Iterable<BackupNovel> chimahonEpubLibraryNovels(BackupMihon backup) {
  final sourceNovelIds = <String>{};
  final encoded =
      backup.unknownFields.getField(_chimahonSourceNovelsTag)?.lengthDelimited ??
      const <List<int>>[];
  for (final bytes in encoded) {
    try {
      final novel = BackupSourceNovel.fromBuffer(bytes);
      final id = ChimahonNovelIdentity.stableIdOrNull(
        title: novel.title,
        author: novel.hasAuthor() ? novel.author : null,
      );
      if (id != null) sourceNovelIds.add(id);
    } on InvalidProtocolBufferException {
      // An unreadable entry cannot identify a book; keep the novel visible.
    }
  }
  if (sourceNovelIds.isEmpty) return backup.backupNovels;
  return backup.backupNovels.where((novel) {
    final id = ChimahonNovelIdentity.stableIdOrNull(
      title: novel.title,
      author: novel.author,
      fallbackId: novel.id,
    );
    return id == null || !sourceNovelIds.contains(id);
  });
}

/// One remote-only novel which still needs an Isar parent ID assigned.
class ChimahonCloudNovelMaterialization {
  const ChimahonCloudNovelMaterialization({
    required this.stableId,
    required this.remote,
    required this.parent,
    required this.progress,
  });

  final String stableId;
  final BackupNovel remote;
  final Manga parent;
  final EpubBookProgress progress;
}

class ChimahonNovelMaterializationPlan {
  const ChimahonNovelMaterializationPlan({
    required this.updatedProgress,
    required this.updatedCloudParents,
    required this.cloudNovels,
    required this.remoteCategoryIdsByMangaId,
    required this.authoritativeCloudParentIds,
  });

  /// Existing local EPUB rows changed by Chimahon's bookmark/metadata policy.
  final List<EpubBookProgress> updatedProgress;

  /// Existing database-only parents whose display metadata changed.
  final List<Manga> updatedCloudParents;

  /// Remote books which had no local EPUB row at all.
  final List<ChimahonCloudNovelMaterialization> cloudNovels;

  /// Category memberships for already materialized local parents.
  final Map<int, List<String>> remoteCategoryIdsByMangaId;

  /// Exact database-only placeholders refreshed from the incoming payload.
  /// These rows are remote cache and carry no cross-account local intent.
  final Set<int> authoritativeCloudParentIds;

  int get novelsUpdated =>
      {
        ...updatedProgress.map((progress) => progress.mangaId),
        ...updatedCloudParents.map((parent) => parent.id).nonNulls,
      }.length +
      cloudNovels.length;
}

/// Plans Chimahon-compatible ghost books without inventing a local file.
///
/// Chimahon stores an `isGhost` metadata bit in a book directory. Mangatan's
/// equivalent is deliberately database-only: a favorite local-archive Novel
/// parent and one [EpubBookProgress] whose archive path is empty. The remote
/// protobuf remains the authority for statistics and fields Mangatan cannot
/// represent, while this projection makes identity, categories, and bookmark
/// state visible and reconnectable to an EPUB imported later.
class ChimahonNovelMaterializer {
  const ChimahonNovelMaterializer({
    this.progressAdapter = const ChimahonNovelProgressAdapter(),
  });

  final ChimahonNovelProgressAdapter progressAdapter;

  ChimahonNovelMaterializationPlan plan({
    required Iterable<Manga> localMangas,
    required Iterable<EpubBookProgress> localProgress,
    Iterable<Chapter> localChapters = const [],
    required Iterable<BackupNovel> remote,
  }) {
    final localMangaList = localMangas.toList(growable: false);
    final localNovelParentIds = localMangaList
        .where((manga) => manga.itemType == ItemType.novel)
        .map((manga) => manga.id)
        .nonNulls
        .toSet();
    final localProgressList = localProgress
        .where((progress) => localNovelParentIds.contains(progress.mangaId))
        .toList(growable: false);
    final canonicalRemote = progressAdapter.canonicalRemoteByStableId(remote);
    final authoritativeCloudParentIds = exactCloudNovelParentIds(
      localMangas: localMangaList,
      localProgress: localProgressList,
      localChapters: localChapters,
    );
    final localStableIds = localProgressList
        .map(progressAdapter.stableLocalIdOrNull)
        .nonNulls
        .toSet();
    final cloudNovels = <ChimahonCloudNovelMaterialization>[];

    for (final entry in canonicalRemote.entries) {
      if (localStableIds.contains(entry.key)) continue;
      final remoteNovel = entry.value;
      final parent = _cloudParent(remoteNovel, entry.key);
      cloudNovels.add(
        ChimahonCloudNovelMaterialization(
          stableId: entry.key,
          remote: remoteNovel,
          parent: parent,
          progress: _cloudProgress(remoteNovel, entry.key),
        ),
      );
    }

    final updatedProgress = <EpubBookProgress>[];
    for (final progress in localProgressList) {
      final stableId = progressAdapter.stableLocalIdOrNull(progress);
      final remoteNovel = stableId == null ? null : canonicalRemote[stableId];
      if (remoteNovel == null) continue;
      final changed = authoritativeCloudParentIds.contains(progress.mangaId)
          ? progressAdapter.applyAuthoritative(progress, remoteNovel)
          : progressAdapter.applyIfNewer(progress, remoteNovel);
      if (changed) updatedProgress.add(progress);
    }
    final updatedCloudParents = <Manga>[];
    for (final parent in localMangaList.where(
      (manga) => authoritativeCloudParentIds.contains(manga.id),
    )) {
      final progress = localProgressList
          .where((row) => row.mangaId == parent.id)
          .firstOrNull;
      final stableId = progressAdapter.stableLocalIdOrNull(progress);
      final remoteNovel = stableId == null ? null : canonicalRemote[stableId];
      if (remoteNovel != null &&
          _refreshCloudParent(parent, remoteNovel, stableId!)) {
        updatedCloudParents.add(parent);
      }
    }

    return ChimahonNovelMaterializationPlan(
      updatedProgress: updatedProgress,
      updatedCloudParents: updatedCloudParents,
      cloudNovels: cloudNovels,
      remoteCategoryIdsByMangaId: progressAdapter.remoteCategoryIdsByMangaId(
        local: localProgressList,
        remote: canonicalRemote.values,
      ),
      authoritativeCloudParentIds: authoritativeCloudParentIds,
    );
  }

  /// Returns only Mangatan-created placeholders which still have no EPUB or
  /// chapter data. These parents are a projection of remote state, so their
  /// bookmark and categories may safely be replaced by the current account.
  Set<int> exactCloudNovelParentIds({
    required Iterable<Manga> localMangas,
    required Iterable<EpubBookProgress> localProgress,
    Iterable<Chapter> localChapters = const [],
  }) {
    final progressList = localProgress.toList(growable: false);
    final parentIdsWithChapters = localChapters
        .map((chapter) => chapter.mangaId)
        .nonNulls
        .toSet();
    return localMangas
        .where((manga) {
          final mangaId = manga.id;
          if (mangaId == null ||
              manga.itemType != ItemType.novel ||
              manga.isLocalArchive != true ||
              manga.source != chimahonCloudNovelSource ||
              manga.link?.startsWith(chimahonCloudNovelLinkPrefix) != true ||
              parentIdsWithChapters.contains(mangaId)) {
            return false;
          }
          final parentProgress = progressList
              .where((progress) => progress.mangaId == mangaId)
              .toList(growable: false);
          return parentProgress.isNotEmpty &&
              parentProgress.every(isCloudOnlyProgress);
        })
        .map((manga) => manga.id)
        .nonNulls
        .toSet();
  }

  /// Identifies only Mangatan-created, still-missing cloud parents whose
  /// retained wire IDs are absent from the authoritative imported payload.
  /// Real EPUB parents and linked former ghosts are never deletion targets.
  Set<int> staleCloudNovelParentIds({
    required Iterable<Manga> localMangas,
    required Iterable<EpubBookProgress> localProgress,
    required Iterable<Chapter> localChapters,
    required Iterable<BackupNovel> remote,
  }) {
    final progressList = localProgress.toList(growable: false);
    final remoteIds = progressAdapter
        .canonicalRemoteByStableId(remote)
        .keys
        .toSet();
    final exactParentIds = exactCloudNovelParentIds(
      localMangas: localMangas,
      localProgress: progressList,
      localChapters: localChapters,
    );
    return localMangas
        .where((manga) => exactParentIds.contains(manga.id))
        .where((manga) {
          final ids = progressList
              .where((progress) => progress.mangaId == manga.id)
              .map(progressAdapter.stableLocalIdOrNull)
              .nonNulls;
          return !ids.any(remoteIds.contains);
        })
        .map((manga) => manga.id)
        .nonNulls
        .toSet();
  }

  /// Empty is a marker, never a filesystem path or placeholder filename.
  bool isCloudOnlyProgress(EpubBookProgress progress) =>
      progress.archivePath.trim().isEmpty;

  Set<int> missingEpubParentIds(Iterable<EpubBookProgress> progresses) =>
      progresses
          .where(isCloudOnlyProgress)
          .map((progress) => progress.mangaId)
          .toSet();

  bool isMissingEpubParent(Manga manga, Iterable<EpubBookProgress> progresses) {
    final mangaId = manga.id;
    if (mangaId == null ||
        manga.itemType != ItemType.novel ||
        manga.isLocalArchive != true) {
      return false;
    }
    return progresses.any(
      (progress) =>
          progress.mangaId == mangaId && isCloudOnlyProgress(progress),
    );
  }

  /// Finds the one ghost whose canonical identity matches imported metadata.
  /// Empty metadata is intentionally not guessed because Chimahon assigns a
  /// random retained ID in that case.
  EpubBookProgress? matchingCloudProgress({
    required Iterable<EpubBookProgress> progresses,
    required String title,
    String? author,
    int? preferredMangaId,
    bool allowUnidentifiablePreferredParent = false,
  }) {
    final ghosts = progresses
        .where(isCloudOnlyProgress)
        .toList(growable: false);
    final importedId = ChimahonNovelIdentity.newBookId(
      title: title,
      author: author,
    );
    final matches = ghosts.where(
      (progress) => progressAdapter.stableLocalIdOrNull(progress) == importedId,
    );
    if (preferredMangaId != null) {
      final preferred = matches
          .where((progress) => progress.mangaId == preferredMangaId)
          .firstOrNull;
      if (preferred != null) return preferred;
    }
    final firstMatch = matches.firstOrNull;
    if (firstMatch != null) return firstMatch;

    final metadataIsEmpty =
        title.trim().isEmpty && (author ?? '').trim().isEmpty;
    if (!metadataIsEmpty ||
        !allowUnidentifiablePreferredParent ||
        preferredMangaId == null) {
      return null;
    }
    final preferred = ghosts
        .where((progress) => progress.mangaId == preferredMangaId)
        .toList(growable: false);
    return preferred.length == 1 ? preferred.single : null;
  }

  Manga? matchingCloudParent({
    required Iterable<Manga> mangas,
    required Iterable<EpubBookProgress> progresses,
    required String title,
    String? author,
  }) {
    final progress = matchingCloudProgress(
      progresses: progresses,
      title: title,
      author: author,
    );
    if (progress == null) return null;
    return mangas
        .where(
          (manga) =>
              manga.id == progress.mangaId &&
              manga.itemType == ItemType.novel &&
              manga.isLocalArchive == true,
        )
        .firstOrNull;
  }

  /// Returns an existing path row, adopts a matching ghost bookmark, or
  /// creates fresh progress for a genuinely new EPUB.
  EpubBookProgress progressForImportedEpub({
    required Iterable<EpubBookProgress> progresses,
    required int mangaId,
    required String archivePath,
    required String title,
    String? author,
    String? lang,
    bool allowUnidentifiablePreferredParent = false,
  }) {
    final progressList = progresses.toList(growable: false);
    final existing = progressList
        .where(
          (progress) =>
              progress.mangaId == mangaId &&
              progress.archivePath == archivePath,
        )
        .firstOrNull;
    final progress =
        existing ??
        matchingCloudProgress(
          progresses: progressList,
          title: title,
          author: author,
          preferredMangaId: mangaId,
          allowUnidentifiablePreferredParent:
              allowUnidentifiablePreferredParent,
        ) ??
        EpubBookProgress.forImportedEpub(
          mangaId: mangaId,
          archivePath: archivePath,
          title: title,
          author: author,
          lang: lang,
        );

    // Adopting a ghost changes only the local file association. Its bookmark,
    // retained Chimahon ID, and newer remote metadata must survive.
    progress
      ..mangaId = mangaId
      ..archivePath = archivePath
      ..title = title
      ..author = author;
    progress.lang ??= lang;
    return progress;
  }

  Manga _cloudParent(BackupNovel remote, String stableId) {
    final exactTitle = remote.title;
    final displayTitle = exactTitle.trim().isEmpty ? 'Cloud novel' : exactTitle;
    final modified = remote.lastModified.toInt();
    return Manga(
      source: chimahonCloudNovelSource,
      author: remote.hasAuthor() ? remote.author : null,
      artist: null,
      genre: const [],
      imageUrl: remote.hasCover() ? remote.cover : null,
      lang: remote.hasLang() ? remote.lang : '',
      link: '$chimahonCloudNovelLinkPrefix$stableId',
      name: displayTitle,
      sourceTitle: exactTitle,
      status: Status.unknown,
      description: chimahonMissingEpubGuidance,
      sourceId: null,
      itemType: ItemType.novel,
      favorite: true,
      dateAdded: modified,
      lastUpdate: modified,
      updatedAt: modified,
      isLocalArchive: true,
      categories: const [],
    );
  }

  bool _refreshCloudParent(Manga parent, BackupNovel remote, String stableId) {
    final desired = _cloudParent(remote, stableId);
    final changed =
        parent.source != desired.source ||
        parent.author != desired.author ||
        parent.imageUrl != desired.imageUrl ||
        parent.lang != desired.lang ||
        parent.link != desired.link ||
        parent.name != desired.name ||
        parent.sourceTitle != desired.sourceTitle ||
        parent.status != desired.status ||
        parent.description != desired.description ||
        parent.itemType != desired.itemType ||
        parent.favorite != desired.favorite ||
        parent.dateAdded != desired.dateAdded ||
        parent.lastUpdate != desired.lastUpdate ||
        parent.updatedAt != desired.updatedAt ||
        parent.isLocalArchive != desired.isLocalArchive;
    if (!changed) return false;

    parent
      ..source = desired.source
      ..author = desired.author
      ..imageUrl = desired.imageUrl
      ..lang = desired.lang
      ..link = desired.link
      ..name = desired.name
      ..sourceTitle = desired.sourceTitle
      ..status = desired.status
      ..description = desired.description
      ..itemType = desired.itemType
      ..favorite = desired.favorite
      ..dateAdded = desired.dateAdded
      ..lastUpdate = desired.lastUpdate
      ..updatedAt = desired.updatedAt
      ..isLocalArchive = desired.isLocalArchive;
    return true;
  }

  EpubBookProgress _cloudProgress(BackupNovel remote, String stableId) =>
      EpubBookProgress(
        mangaId: Isar.autoIncrement,
        archivePath: '',
        title: remote.title,
        author: remote.hasAuthor() ? remote.author : null,
        chimahonId: stableId,
        lang: remote.hasLang() ? remote.lang : null,
        chapterIndex: remote.chapterIndex,
        progress: remote.progress,
        characterCount: remote.characterCount,
        lastModified: remote.lastModified.toInt(),
      );
}
