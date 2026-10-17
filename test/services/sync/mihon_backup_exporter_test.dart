import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/eval/mihon/bridge_protocol.dart';
import 'package:mangayomi/models/category.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/epub_book_progress.dart';
import 'package:mangayomi/models/history.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/models/track.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupPreference.pb.dart';
import 'package:mangayomi/services/sync/chimahon_preferences.dart';
import 'package:mangayomi/services/sync/chimahon_novel_category_adapter.dart';
import 'package:mangayomi/services/sync/mihon_backup_exporter.dart';
import 'package:mangayomi/services/sync/chimahon_tracking_adapter.dart';

void main() {
  test('exports native source identity, categories, progress, and history', () {
    final source = Source(
      id: 99,
      name: 'Manga source',
      lang: 'ja',
      isAdded: true,
      sourceCode: 'apk',
      additionalParams: encodeMihonSourceMetadata(
        sourceId: 123456789,
        packageName: 'pkg.source',
      ),
    )..sourceCodeLanguage = SourceCodeLanguage.mihon;
    final category = Category(
      id: 10,
      name: 'Reading',
      pos: 3,
      hide: true,
      forItemType: ItemType.manga,
    );
    final manga = Manga(
      id: 1,
      source: source.name,
      sourceId: source.id,
      author: 'Author',
      artist: 'Artist',
      genre: const ['Action'],
      imageUrl: 'cover',
      lang: 'ja',
      link: '/manga',
      name: 'Custom Manga',
      sourceTitle: 'Source Manga',
      status: Status.ongoing,
      description: 'Description',
      favorite: true,
      categories: [category.id!],
      updatedAt: 12,
    );
    final chapter = Chapter(
      id: 2,
      mangaId: manga.id,
      name: 'Chapter 4.5',
      url: '/chapter',
      isRead: false,
      lastPageRead: '8',
      updatedAt: 13,
    );
    final manualChapter = Chapter(
      id: 4,
      mangaId: manga.id,
      name: 'Dropped local archive',
      archivePath: r'C:\Users\reader\Books\dropped.cbz',
      isRead: true,
      isBookmarked: true,
      lastPageRead: '12',
    );
    const legacyMacPath = '/Users/reader/Books/legacy-local.cbz';
    final legacyManualChapter = Chapter(
      id: 8,
      mangaId: manga.id,
      name: 'Legacy dropped local archive',
      url: legacyMacPath,
      archivePath: legacyMacPath,
      isRead: true,
      isBookmarked: true,
      lastPageRead: '13',
    );
    const orphanedMacPath = '/Users/reader/Books/orphaned-url-only-local.cbz';
    final orphanedManualChapter = Chapter(
      id: 10,
      mangaId: manga.id,
      name: 'Orphaned legacy local archive',
      url: orphanedMacPath,
      archivePath: '',
      isRead: true,
    );
    final localArchiveManga = Manga(
      id: 6,
      source: source.name,
      sourceId: source.id,
      author: '',
      artist: '',
      genre: const [],
      imageUrl: null,
      lang: 'ja',
      link: '/local-title',
      name: 'Local title',
      sourceTitle: 'Local title',
      status: Status.unknown,
      description: null,
      favorite: true,
      itemType: ItemType.manga,
      isLocalArchive: true,
    );
    final localArchiveChapter = Chapter(
      id: 7,
      mangaId: localArchiveManga.id,
      name: 'Local chapter with a non-empty URL',
      url: 'magnet:?xt=urn:btih:local-only',
      archivePath: r'C:\Users\reader\Books\local-only.torrent',
      isRead: true,
    );
    final history = History(
      id: 3,
      itemType: ItemType.manga,
      chapterId: chapter.id,
      mangaId: manga.id,
      date: '1700000000000',
      readingTimeSeconds: 25,
    );
    final manualHistory = History(
      id: 5,
      itemType: ItemType.manga,
      chapterId: manualChapter.id,
      mangaId: manga.id,
      date: '1700000001000',
      readingTimeSeconds: 40,
    );
    final legacyManualHistory = History(
      id: 9,
      itemType: ItemType.manga,
      chapterId: legacyManualChapter.id,
      mangaId: manga.id,
      date: '1700000002000',
      readingTimeSeconds: 41,
    );

    final backup = const MihonBackupExporter().export(
      mangas: [manga, localArchiveManga],
      categories: [category],
      chapters: [
        chapter,
        manualChapter,
        legacyManualChapter,
        orphanedManualChapter,
        localArchiveChapter,
      ],
      histories: [history, manualHistory, legacyManualHistory],
      sources: [source],
      epubBookProgress: const [],
      sourcePreferences: [
        BackupSourcePreferences(
          sourceKey: 'source_123456789',
          prefs: [
            const ChimahonPreferenceCodec().encode('quality', 'original'),
          ],
        ),
      ],
    );

    expect(backup.backupSources.single.sourceId, Int64(123456789));
    expect(backup.backupManga.single.source, Int64(123456789));
    expect(backup.backupManga.single.title, 'Source Manga');
    expect(backup.backupManga.single.customTitle, 'Custom Manga');
    expect(backup.backupManga.single.categories, [Int64(3)]);
    expect(backup.backupManga.single.chapters.single.lastPageRead, Int64(8));
    expect(backup.backupManga.single.chapters.single.url, '/chapter');
    expect(backup.backupManga.single.chapters, hasLength(1));
    expect(backup.backupManga.single.chapters.single.chapterNumber, 4.5);
    expect(
      backup.backupManga.single.history.single.lastRead,
      Int64(1700000000000),
    );
    expect(backup.backupManga.single.history.single.readDuration, Int64(25000));
    expect(backup.backupManga.single.history, hasLength(1));
    final wire = String.fromCharCodes(backup.writeToBuffer());
    expect(wire, isNot(contains(r'C:\Users\reader\Books\dropped.cbz')));
    expect(wire, isNot(contains(legacyMacPath)));
    expect(wire, isNot(contains(orphanedMacPath)));
    expect(wire, isNot(contains(r'C:\Users\reader\Books\local-only.torrent')));
    expect(backup.backupCategories.single.hidden, isTrue);
    expect(backup.backupSourcePreferences.single.sourceKey, 'source_123456789');
    expect(
      const ChimahonPreferenceCodec()
          .decode(backup.backupSourcePreferences.single.prefs.single)
          .value,
      'original',
    );
  });

  test('collapses duplicate manga history onto Chimahon URL identity', () {
    final source = Source(
      id: 201,
      name: 'Manga source',
      lang: 'en',
      additionalParams: encodeMihonSourceMetadata(
        sourceId: 201001,
        packageName: 'pkg.manga.history',
      ),
    );
    final manga = Manga(
      id: 202,
      source: source.name,
      sourceId: source.id,
      author: null,
      artist: null,
      genre: const [],
      imageUrl: null,
      lang: 'en',
      link: '/manga-history',
      name: 'Manga history',
      status: Status.ongoing,
      description: null,
      favorite: true,
    );
    final chapter = Chapter(
      id: 203,
      mangaId: manga.id,
      name: 'Chapter 1',
      url: '/shared-history-url',
    );
    final otherChapter = Chapter(
      id: 207,
      mangaId: manga.id,
      name: 'Chapter 2',
      url: '/another-history-url',
    );
    final histories = [
      History(
        id: 204,
        itemType: ItemType.manga,
        chapterId: chapter.id,
        mangaId: manga.id,
        date: '1700000003000',
        readingTimeSeconds: 30,
      ),
      History(
        id: 205,
        itemType: ItemType.manga,
        chapterId: chapter.id,
        mangaId: manga.id,
        date: '1700000002000',
        readingTimeSeconds: 90,
      ),
      History(
        id: 206,
        itemType: ItemType.manga,
        chapterId: chapter.id,
        mangaId: manga.id,
        date: '1700000003000',
        readingTimeSeconds: 120,
      ),
      History(
        id: 208,
        itemType: ItemType.manga,
        chapterId: otherChapter.id,
        mangaId: manga.id,
        date: '1700000001000',
        readingTimeSeconds: 15,
      ),
    ];

    BackupMihon export(Iterable<History> input) =>
        const MihonBackupExporter().export(
          mangas: [manga],
          categories: const [],
          chapters: [chapter, otherChapter],
          histories: input,
          sources: [source],
          epubBookProgress: const [],
        );

    final forward = export(histories);
    final reverse = export(histories.reversed);
    final projected = forward.backupManga.single.history.singleWhere(
      (history) => history.url == '/shared-history-url',
    );
    expect(forward.backupManga.single.history, hasLength(2));
    expect(projected.url, '/shared-history-url');
    expect(projected.lastRead, Int64(1700000003000));
    expect(projected.readDuration, Int64(120000));
    expect(reverse.writeToBuffer(), forward.writeToBuffer());
  });

  test('maps Mangatan no-resume sentinels to Chimahon zero progress', () {
    final source = Source(
      id: 101,
      name: 'Shared source',
      lang: 'ja',
      additionalParams: encodeMihonSourceMetadata(
        sourceId: 111222333,
        packageName: 'pkg.shared',
      ),
    )..sourceCodeLanguage = SourceCodeLanguage.mihon;
    final manga = Manga(
      id: 10,
      source: source.name,
      sourceId: source.id,
      author: '',
      artist: '',
      genre: const [],
      imageUrl: null,
      lang: 'ja',
      link: '/manga',
      name: 'Manga',
      sourceTitle: 'Manga',
      status: Status.unknown,
      description: null,
      itemType: ItemType.manga,
      favorite: true,
    );
    final anime = Manga(
      id: 11,
      source: source.name,
      sourceId: source.id,
      author: '',
      artist: '',
      genre: const [],
      imageUrl: null,
      lang: 'ja',
      link: '/anime',
      name: 'Anime',
      sourceTitle: 'Anime',
      status: Status.unknown,
      description: null,
      itemType: ItemType.anime,
      favorite: true,
    );

    final backup = const MihonBackupExporter().export(
      mangas: [manga, anime],
      categories: const [],
      chapters: [
        Chapter(
          mangaId: manga.id,
          name: 'New chapter',
          url: '/new',
          lastPageRead: '1',
        ),
        Chapter(
          mangaId: manga.id,
          name: 'Started chapter',
          url: '/started',
          lastPageRead: '9',
          updatedAt: 1700000000123,
        ),
        Chapter(
          mangaId: anime.id,
          name: 'Unseen episode',
          url: '/unseen',
          lastPageRead: '1',
        ),
        Chapter(
          mangaId: anime.id,
          name: 'Seen episode',
          url: '/seen',
          lastPageRead: '12',
        ),
      ],
      histories: const [],
      sources: [source],
      epubBookProgress: const [],
    );

    final chapters = {
      for (final chapter in backup.backupManga.single.chapters)
        chapter.url: chapter.lastPageRead.toInt(),
    };
    final episodes = {
      for (final episode in backup.backupAnime.single.episodes)
        episode.url: episode.lastSecondSeen.toInt(),
    };
    expect(chapters, {'/new': 0, '/started': 9});
    expect(
      backup.backupManga.single.chapters
          .singleWhere((chapter) => chapter.url == '/started')
          .lastModifiedAt,
      Int64(1700000001),
    );
    expect(episodes, {'/unseen': 0, '/seen': 12});
  });

  test(
    'exports anime source identity, categories, episodes, and watch history',
    () {
      final source = Source(
        id: 100,
        name: 'Anime source',
        lang: 'ja',
        isAdded: true,
        sourceCode: 'apk',
        additionalParams: encodeMihonSourceMetadata(
          sourceId: 987654321,
          packageName: 'pkg.anime',
        ),
      )..sourceCodeLanguage = SourceCodeLanguage.mihon;
      final category = Category(
        id: 20,
        name: 'Watching',
        pos: 2,
        hide: true,
        forItemType: ItemType.anime,
      );
      final anime = Manga(
        id: 4,
        source: source.name,
        sourceId: source.id,
        author: 'Director',
        artist: 'Studio',
        genre: const ['Adventure'],
        imageUrl: 'poster',
        lang: 'ja',
        link: '/anime',
        name: 'Anime',
        status: Status.ongoing,
        description: 'Anime description',
        favorite: false,
        favoriteModifiedAt: 21,
        categories: [category.id!],
        itemType: ItemType.anime,
        updatedAt: 22,
      );
      final episode = Chapter(
        id: 5,
        mangaId: anime.id,
        name: 'Episode 12',
        url: '/episode',
        chapterNumber: 12.5,
        isRead: true,
        lastPageRead: '713',
        isFiller: true,
        thumbnailUrl: 'preview',
        description: 'summary',
        duration: '1440',
        updatedAt: 23,
      );
      final history = History(
        id: 6,
        itemType: ItemType.anime,
        chapterId: episode.id,
        mangaId: anime.id,
        date: '1700000005000',
        readingTimeSeconds: 120,
      );

      final backup = const MihonBackupExporter().export(
        mangas: [anime],
        categories: [category],
        chapters: [episode],
        histories: [history],
        sources: [source],
        epubBookProgress: const [],
      );

      expect(backup.backupAnimeSources.single.sourceId, Int64(987654321));
      expect(backup.backupAnime.single.source, Int64(987654321));
      expect(backup.backupAnime.single.favorite, isFalse);
      expect(backup.backupAnimeCategories.single.hidden, isTrue);
      expect(backup.backupAnime.single.favoriteModifiedAt, Int64(21));
      expect(backup.backupAnime.single.lastModifiedAt, Int64(21));
      expect(backup.backupAnime.single.version, Int64.ZERO);
      expect(backup.backupAnime.single.categories, [Int64(2)]);
      expect(
        backup.backupAnime.single.episodes.single.lastSecondSeen,
        Int64(713),
      );
      expect(backup.backupAnime.single.episodes.single.episodeNumber, 12.5);
      expect(backup.backupAnime.single.episodes.single.fillermark, isTrue);
      expect(backup.backupAnime.single.episodes.single.previewUrl, 'preview');
      expect(backup.backupAnime.single.episodes.single.summary, 'summary');
      expect(
        backup.backupAnime.single.episodes.single.totalSeconds,
        Int64(1440),
      );
      expect(backup.backupAnime.single.episodes.single.version, Int64.ZERO);
      expect(
        backup.backupAnime.single.history.single.lastRead,
        Int64(1700000005000),
      );
      expect(
        backup.backupAnime.single.history.single.readDuration,
        Int64(120000),
      );
    },
  );

  test('collapses duplicate anime history onto Chimahon URL identity', () {
    final source = Source(
      id: 211,
      name: 'Anime source',
      lang: 'en',
      additionalParams: encodeMihonSourceMetadata(
        sourceId: 211001,
        packageName: 'pkg.anime.history',
      ),
    );
    final anime = Manga(
      id: 212,
      source: source.name,
      sourceId: source.id,
      author: null,
      artist: null,
      genre: const [],
      imageUrl: null,
      lang: 'en',
      link: '/anime-history',
      name: 'Anime history',
      status: Status.ongoing,
      description: null,
      favorite: true,
      itemType: ItemType.anime,
    );
    final episode = Chapter(
      id: 213,
      mangaId: anime.id,
      name: 'Episode 1',
      url: '/shared-episode-history-url',
    );
    final histories = [
      History(
        id: 214,
        itemType: ItemType.anime,
        chapterId: episode.id,
        mangaId: anime.id,
        date: '1700000005000',
        readingTimeSeconds: 10,
      ),
      History(
        id: 215,
        itemType: ItemType.anime,
        chapterId: episode.id,
        mangaId: anime.id,
        date: '1700000004000',
        readingTimeSeconds: 45,
      ),
    ];

    BackupMihon export(Iterable<History> input) =>
        const MihonBackupExporter().export(
          mangas: [anime],
          categories: const [],
          chapters: [episode],
          histories: input,
          sources: [source],
          epubBookProgress: const [],
        );

    final forward = export(histories);
    final reverse = export(histories.reversed);
    final projected = forward.backupAnime.single.history.single;
    expect(forward.backupAnime.single.history, hasLength(1));
    expect(projected.url, '/shared-episode-history-url');
    expect(projected.lastRead, Int64(1700000005000));
    expect(projected.readDuration, Int64(45000));
    expect(reverse.writeToBuffer(), forward.writeToBuffer());
  });

  test('uses stored source chapter number instead of reparsing its name', () {
    final source = Source(
      id: 103,
      name: 'Manga source',
      lang: 'en',
      isAdded: true,
      sourceCode: 'apk',
      additionalParams: encodeMihonSourceMetadata(
        sourceId: 86420,
        packageName: 'pkg.number',
      ),
    )..sourceCodeLanguage = SourceCodeLanguage.mihon;
    final manga = Manga(
      id: 40,
      source: source.name,
      sourceId: source.id,
      author: null,
      artist: null,
      genre: const [],
      imageUrl: null,
      lang: 'en',
      link: '/title',
      name: 'Title',
      status: Status.ongoing,
      description: null,
      favorite: true,
    );
    final chapter = Chapter(
      id: 41,
      mangaId: manga.id,
      name: 'Vol.1 Ch.32 - Hybrid 2',
      url: '/chapter',
      chapterNumber: 32,
    );

    final backup = const MihonBackupExporter().export(
      mangas: [manga],
      categories: const [],
      chapters: [chapter],
      histories: const [],
      sources: [source],
      epubBookProgress: const [],
    );

    expect(backup.backupManga.single.chapters.single.chapterNumber, 32);
  });

  test('collapses unknown-number aliases while preserving progress', () {
    final source = Source(
      id: 104,
      name: 'Manga source',
      lang: 'en',
      isAdded: true,
      sourceCode: 'apk',
      additionalParams: encodeMihonSourceMetadata(
        sourceId: 97531,
        packageName: 'pkg.sentinel',
      ),
    )..sourceCodeLanguage = SourceCodeLanguage.mihon;
    final manga = Manga(
      id: 50,
      source: source.name,
      sourceId: source.id,
      author: null,
      artist: null,
      genre: const [],
      imageUrl: null,
      lang: 'en',
      link: '/sentinel-title',
      name: 'Sentinel title',
      status: Status.ongoing,
      description: null,
      favorite: true,
    );
    final original = Chapter(
      id: 51,
      mangaId: manga.id,
      name: 'Chapter 54',
      url: '/chapter-54',
      chapterNumber: 54,
      lastPageRead: '4',
      updatedAt: 100000,
    );
    final duplicate = Chapter(
      id: 52,
      mangaId: manga.id,
      name: 'Chapter 54',
      url: '/chapter-54',
      chapterNumber: -1,
      lastPageRead: '5',
      isBookmarked: true,
      updatedAt: 101000,
    );

    final backup = const MihonBackupExporter().export(
      mangas: [manga],
      categories: const [],
      chapters: [original, duplicate],
      histories: const [],
      sources: [source],
      epubBookProgress: const [],
    );

    final chapter = backup.backupManga.single.chapters.single;
    expect(chapter.chapterNumber, 54);
    expect(chapter.lastPageRead, Int64(5));
    expect(chapter.bookmark, isTrue);
  });

  test(
    'exports favorite tombstones from their deletion clock, not stale metadata',
    () {
      final source = Source(
        id: 101,
        name: 'Portable source',
        lang: 'en',
        isAdded: true,
        sourceCode: 'apk',
        additionalParams: encodeMihonSourceMetadata(
          sourceId: 13579,
          packageName: 'pkg.portable',
        ),
      )..sourceCodeLanguage = SourceCodeLanguage.mihon;

      Manga title({
        required int id,
        required String link,
        required bool favorite,
        int? favoriteModifiedAt,
        int? dateAdded,
        int? updatedAt,
      }) => Manga(
        id: id,
        source: source.name,
        sourceId: source.id,
        author: null,
        artist: null,
        genre: const [],
        imageUrl: null,
        lang: 'en',
        link: link,
        name: link,
        status: Status.ongoing,
        description: null,
        favorite: favorite,
        favoriteModifiedAt: favoriteModifiedAt,
        dateAdded: dateAdded,
        updatedAt: updatedAt,
      );

      final legacyFavorite = title(
        id: 10,
        link: '/legacy-favorite',
        favorite: true,
        dateAdded: 1699999999123,
        updatedAt: 1700000000123,
      );
      final tombstone = title(
        id: 11,
        link: '/unfavorited',
        favorite: false,
        favoriteModifiedAt: 1700000002,
        updatedAt: 1700000002123,
      );
      final ordinaryNonFavorite = title(
        id: 12,
        link: '/not-in-library',
        favorite: false,
        updatedAt: 1700000003123,
      );
      final chapter = Chapter(
        id: 20,
        mangaId: tombstone.id,
        name: 'Chapter 1',
        url: '/chapter-1',
        updatedAt: 1700000003456,
      );

      final backup = const MihonBackupExporter().export(
        mangas: [legacyFavorite, tombstone, ordinaryNonFavorite],
        categories: const [],
        chapters: [chapter],
        histories: const [],
        sources: [source],
        epubBookProgress: const [],
      );

      expect(backup.backupManga, hasLength(2));
      final exportedLegacy = backup.backupManga.singleWhere(
        (manga) => manga.url == '/legacy-favorite',
      );
      final exportedTombstone = backup.backupManga.singleWhere(
        (manga) => manga.url == '/unfavorited',
      );
      expect(exportedLegacy.favoriteModifiedAt, Int64(1699999999));
      expect(exportedLegacy.lastModifiedAt, Int64(1700000001));
      expect(exportedLegacy.version, Int64.ZERO);
      expect(exportedTombstone.favorite, isFalse);
      expect(exportedTombstone.favoriteModifiedAt, Int64(1700000002));
      // A non-favorite can be an old source-cache row which only became
      // exportable when a remote tombstone supplied its favorite clock. Its
      // unrelated metadata timestamp must not promote the deletion record.
      expect(exportedTombstone.lastModifiedAt, Int64(1700000002));
      expect(exportedTombstone.version, Int64.ZERO);
      expect(
        exportedTombstone.chapters.single.lastModifiedAt,
        Int64(1700000004),
      );
      expect(exportedTombstone.chapters.single.version, Int64.ZERO);
    },
  );

  test('favorite timestamps stay monotonic within one clock second', () {
    final manga = Manga(
      source: 'source',
      sourceId: 1,
      author: null,
      artist: null,
      genre: const [],
      imageUrl: null,
      lang: 'en',
      link: '/manga',
      name: 'Manga',
      status: Status.ongoing,
      description: null,
    );
    final instant = DateTime.fromMillisecondsSinceEpoch(1700000000123);

    manga.updateFavorite(true, modifiedAt: instant);
    manga.updateFavorite(false, modifiedAt: instant);

    expect(manga.favorite, isFalse);
    expect(manga.favoriteModifiedAt, 1700000001);
    expect(manga.updatedAt, 1700000001000);
  });

  test('a later re-favorite resumes the normal parent metadata clock', () {
    final source = Source(
      id: 111,
      name: 'Portable source',
      lang: 'en',
      additionalParams: encodeMihonSourceMetadata(
        sourceId: 97531,
        packageName: 'pkg.portable',
      ),
    );
    final manga = Manga(
      id: 112,
      source: source.name,
      sourceId: source.id,
      author: null,
      artist: null,
      genre: const [],
      imageUrl: null,
      lang: 'en',
      link: '/toggle',
      name: 'Toggle',
      status: Status.ongoing,
      description: null,
      favorite: true,
    );

    BackupMihon export() => const MihonBackupExporter().export(
      mangas: [manga],
      categories: const [],
      chapters: const [],
      histories: const [],
      sources: [source],
      epubBookProgress: const [],
    );

    manga.updateFavorite(
      false,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(1700000000123),
    );
    expect(export().backupManga.single.lastModifiedAt, Int64(1700000000));

    manga.updateFavorite(
      true,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(1700000002123),
    );
    final refavorited = export().backupManga.single;
    expect(refavorited.favorite, isTrue);
    expect(refavorited.favoriteModifiedAt, Int64(1700000002));
    expect(refavorited.lastModifiedAt, Int64(1700000003));
  });

  test('exports only tracker IDs shared with Chimahon', () {
    final source = Source(
      id: 102,
      name: 'Portable source',
      lang: 'en',
      isAdded: true,
      sourceCode: 'apk',
      additionalParams: encodeMihonSourceMetadata(
        sourceId: 24680,
        packageName: 'pkg.portable',
      ),
    )..sourceCodeLanguage = SourceCodeLanguage.mihon;
    final manga = Manga(
      id: 30,
      source: source.name,
      sourceId: source.id,
      author: null,
      artist: null,
      genre: const [],
      imageUrl: null,
      lang: 'en',
      link: '/tracked',
      name: 'Tracked',
      status: Status.ongoing,
      description: null,
      favorite: true,
    );
    Track track(int syncId, TrackStatus status) => Track(
      mangaId: manga.id,
      syncId: syncId,
      mediaId: 123,
      status: status,
      updatedAt: syncId == 2 ? 1700000005000 : 0,
    );

    final backup = const MihonBackupExporter().export(
      mangas: [manga],
      categories: const [],
      chapters: const [],
      histories: const [],
      sources: [source],
      epubBookProgress: const [],
      tracks: [
        track(2, TrackStatus.reReading),
        track(4, TrackStatus.reading),
        track(5, TrackStatus.reading),
      ],
      deletedTracks: const [
        ChimahonTrackingDeletion(
          mangaId: 30,
          syncId: 3,
          modifiedAt: 1700000007000,
        ),
      ],
    );

    expect(backup.backupManga.single.tracking, hasLength(1));
    expect(backup.backupManga.single.tracking.single.syncId, 2);
    expect(backup.backupManga.single.tracking.single.status, 6);
    expect(backup.backupManga.single.lastModifiedAt, Int64(1700000007));
  });

  test('projects each novel parent category set onto each of its EPUBs', () {
    final reading = Category(
      id: 71,
      name: 'Reading',
      forItemType: ItemType.novel,
      pos: 4,
    );
    final study = Category(
      id: 72,
      name: 'Study',
      forItemType: ItemType.novel,
      pos: 2,
    );
    Manga parent(int id, List<int>? categories) => Manga(
      id: id,
      source: 'Local',
      sourceId: null,
      author: null,
      artist: null,
      genre: const [],
      imageUrl: null,
      lang: 'ja',
      link: '/parent-$id',
      name: 'Parent $id',
      status: Status.unknown,
      description: null,
      itemType: ItemType.novel,
      isLocalArchive: true,
      categories: categories,
    );

    final backup = const MihonBackupExporter().export(
      mangas: [
        parent(80, [reading.id!, study.id!]),
        parent(81, null),
      ],
      categories: [reading, study],
      chapters: const [],
      histories: const [],
      sources: const [],
      epubBookProgress: [
        EpubBookProgress(
          mangaId: 80,
          archivePath: '/books/one.epub',
          title: 'Volume One',
        ),
        EpubBookProgress(
          mangaId: 80,
          archivePath: r'C:\Books\two.epub',
          title: 'Volume Two',
        ),
        EpubBookProgress(
          mangaId: 81,
          archivePath: '/books/three.epub',
          title: 'Volume Three',
        ),
      ],
    );

    const categoryAdapter = ChimahonNovelCategoryAdapter();
    final readingId = categoryAdapter.stableId('reading');
    final studyId = categoryAdapter.stableId('study');
    final novelsByTitle = {
      for (final novel in backup.backupNovels) novel.title: novel,
    };
    expect(
      novelsByTitle['Volume One']!.categoryIds,
      unorderedEquals([readingId, studyId]),
    );
    expect(
      novelsByTitle['Volume Two']!.categoryIds,
      unorderedEquals([readingId, studyId]),
    );
    expect(novelsByTitle['Volume Three']!.categoryIds, ['default']);
    // The uncategorized row is implied by membership, never exported.
    expect(backup.backupNovelCategories.map((category) => category.id), [
      studyId,
      readingId,
    ]);
    expect(
      backup.backupNovelCategories.map((category) => category.id),
      isNot(contains(anyOf('71', '72'))),
    );
  });
}
