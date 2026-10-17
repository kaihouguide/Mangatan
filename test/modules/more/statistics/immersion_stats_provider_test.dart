import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/download.dart';
import 'package:mangayomi/models/epub_book_progress.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/models/track.dart';
import 'package:mangayomi/models/track_preference.dart';
import 'package:mangayomi/modules/more/statistics/immersion_stats_data.dart';
import 'package:mangayomi/modules/more/statistics/immersion_stats_provider.dart';
import 'package:mangayomi/services/statistics/immersion_stats_models.dart';
import 'package:mangayomi/services/statistics/immersion_stats_storage.dart';

Manga _manga(
  String name, {
  bool favorite = true,
  Status status = Status.ongoing,
}) => Manga(
  source: 'source',
  author: null,
  artist: null,
  genre: const [],
  imageUrl: null,
  lang: 'ja',
  link: '/$name',
  name: name,
  status: status,
  description: null,
  sourceId: null,
  itemType: ItemType.manga,
  favorite: favorite,
);

void main() {
  late Directory dir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    try {
      await Isar.initializeIsarCore(download: true);
    } finally {
      HttpOverrides.global = overrides;
    }
    dir = await Directory.systemTemp.createTemp('immersion_stats');
    Hive.init(dir.path);
    isar = await Isar.open(
      [
        MangaSchema,
        ChapterSchema,
        DownloadSchema,
        EpubBookProgressSchema,
        SourceSchema,
        TrackSchema,
        TrackPreferenceSchema,
      ],
      directory: dir.path,
      name: 'stats_${dir.path.hashCode}',
    );
  });

  tearDown(() async {
    await Hive.close();
    await isar.close(deleteFromDisk: true);
    await dir.delete(recursive: true);
  });

  test('aggregates library, reading time and characters per hour', () async {
    final finished = _manga('Finished', status: Status.completed);
    final reading = _manga('Reading');
    final dropped = _manga('Dropped', favorite: false);
    isar.writeTxnSync(() {
      isar.mangas.putAllSync([finished, reading, dropped]);
      isar.chapters.putAllSync([
        Chapter(name: '1', mangaId: finished.id, isRead: true),
        Chapter(name: '1', mangaId: reading.id, isRead: true),
        Chapter(name: '2', mangaId: reading.id, isRead: false),
      ]);
    });
    await ImmersionStatsStorage.saveMangaStats([
      MangaStatsEntry(
        dateKey: '2026-01-01',
        mangaId: finished.id!,
        charactersRead: 3000,
        readingTimeMs: 3600000,
      ),
      MangaStatsEntry(
        dateKey: '2026-01-02',
        mangaId: dropped.id!,
        charactersRead: 1000,
        readingTimeMs: 600000,
      ),
    ]);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final overview = await container.read(
      immersionStatsProvider(
        query: const ImmersionStatsQuery(
          type: ImmersionStatsType.manga,
          scale: ImmersionStatsDateScale.allTime,
          includeNonLibrary: false,
        ),
      ).future,
    );

    expect(overview.libraryTitleCount, 2);
    expect(overview.completedTitleCount, 1);
    expect(overview.startedTitleCount, 2);
    expect(overview.totalChapterCount, 3);
    expect(overview.readChapterCount, 2);
    // The unfavourited title's reading is excluded with non-library titles.
    expect(overview.charactersRead, 3000);
    expect(overview.totalReadDurationMs, 3600000);
    expect(overview.charactersPerHour, 3000);
  });

  test(
    'unattributed reading counts until a profile filter is applied',
    () async {
      await ImmersionStatsStorage.saveMangaStats(const [
        MangaStatsEntry(
          dateKey: '2026-01-01',
          charactersRead: 500,
          readingTimeMs: 60000,
        ),
      ]);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      Future<ImmersionStatsOverview> read(String? profileId) => container.read(
        immersionStatsProvider(
          query: ImmersionStatsQuery(
            type: ImmersionStatsType.manga,
            scale: ImmersionStatsDateScale.allTime,
            includeNonLibrary: false,
            profileId: profileId,
          ),
        ).future,
      );

      // Chimahon keeps the id-0 bucket when non-library titles are hidden...
      expect((await read(null)).charactersRead, 500);
      // ...but it cannot be attributed to any dictionary profile.
      expect((await read('ja')).charactersRead, 0);
    },
  );
}
