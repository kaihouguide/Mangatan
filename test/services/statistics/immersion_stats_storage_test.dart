import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mangayomi/services/statistics/immersion_stats_models.dart';
import 'package:mangayomi/services/statistics/immersion_stats_storage.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('immersion_stats_test');
    Hive.init(directory.path);
  });

  tearDown(() async {
    ImmersionStatsStorage.boxOpener = ImmersionStatsStorage.openDefaultBox;
    await Hive.deleteFromDisk();
    await Hive.close();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test(
    'a failed box open skips the update instead of erasing history',
    () async {
      await ImmersionStatsStorage.addMangaStats(
        characters: 100,
        timeMs: 5000,
        mangaId: 1,
        date: DateTime(2026, 7, 17),
      );
      await ImmersionStatsStorage.addAnkiCard(type: 'manga');

      // The first open fails and later ones succeed, as with a transient error.
      var failNext = true;
      ImmersionStatsStorage.boxOpener = () async {
        if (failNext) {
          failNext = false;
          return null;
        }
        return ImmersionStatsStorage.openDefaultBox();
      };
      await ImmersionStatsStorage.addMangaStats(
        characters: 10,
        timeMs: 1000,
        mangaId: 2,
        date: DateTime(2026, 7, 18),
      );
      failNext = true;
      await ImmersionStatsStorage.addAnkiCard(type: 'novel');

      final manga = await ImmersionStatsStorage.loadMangaStats();
      expect(manga.map((entry) => entry.mangaId), [1]);
      final anki = await ImmersionStatsStorage.loadAnkiStats();
      expect(anki.single.mangaCards, 1);
      expect(anki.single.novelCards, 0);
    },
  );

  group('manga statistics', () {
    test('accumulates into one row per day and title', () async {
      final date = DateTime(2026, 7, 18);
      await ImmersionStatsStorage.addMangaStats(
        characters: 100,
        timeMs: 5000,
        mangaId: 7,
        date: date,
      );
      await ImmersionStatsStorage.addMangaStats(
        characters: 50,
        timeMs: 2000,
        mangaId: 7,
        date: date,
      );

      final stats = await ImmersionStatsStorage.loadMangaStats();
      expect(stats, hasLength(1));
      expect(stats.single.charactersRead, 150);
      expect(stats.single.readingTimeMs, 7000);
      expect(stats.single.dateKey, '2026-07-18');
    });

    test('separates days and titles', () async {
      await ImmersionStatsStorage.addMangaStats(
        characters: 100,
        timeMs: 1000,
        mangaId: 7,
        date: DateTime(2026, 7, 18),
      );
      await ImmersionStatsStorage.addMangaStats(
        characters: 100,
        timeMs: 1000,
        mangaId: 7,
        date: DateTime(2026, 7, 19),
      );
      await ImmersionStatsStorage.addMangaStats(
        characters: 100,
        timeMs: 1000,
        mangaId: 8,
        date: DateTime(2026, 7, 18),
      );

      expect(await ImmersionStatsStorage.loadMangaStats(), hasLength(3));
    });

    test('a page with neither characters nor time is not recorded', () async {
      await ImmersionStatsStorage.addMangaStats(characters: 0, timeMs: 0);
      expect(await ImmersionStatsStorage.loadMangaStats(), isEmpty);
    });

    test('reading with no library entry uses the id-0 bucket', () async {
      await ImmersionStatsStorage.addMangaStats(characters: 10, timeMs: 100);
      final stats = await ImmersionStatsStorage.loadMangaStats();
      expect(stats.single.mangaId, 0);
    });

    test('merge takes the larger value per field, never the sum', () async {
      final date = DateTime(2026, 7, 18);
      await ImmersionStatsStorage.addMangaStats(
        characters: 100,
        timeMs: 5000,
        mangaId: 7,
        date: date,
      );
      // Both fields already synced once; summing would double count the day.
      await ImmersionStatsStorage.mergeMangaStats([
        const MangaStatsEntry(
          dateKey: '2026-07-18',
          charactersRead: 80,
          readingTimeMs: 9000,
          mangaId: 7,
        ),
      ]);

      final stats = await ImmersionStatsStorage.loadMangaStats();
      expect(stats, hasLength(1));
      expect(stats.single.charactersRead, 100);
      expect(stats.single.readingTimeMs, 9000);
    });

    test('merge adds days the device has never seen', () async {
      await ImmersionStatsStorage.mergeMangaStats([
        const MangaStatsEntry(dateKey: '2026-07-01', charactersRead: 42),
      ]);
      final stats = await ImmersionStatsStorage.loadMangaStats();
      expect(stats.single.charactersRead, 42);
    });

    test('concurrent writes do not lose a page', () async {
      // Read-modify-write under concurrency is exactly how a day's reading gets
      // silently dropped, so every mutation is serialized.
      await Future.wait([
        for (var i = 0; i < 20; i++)
          ImmersionStatsStorage.addMangaStats(
            characters: 10,
            timeMs: 100,
            mangaId: 7,
            date: DateTime(2026, 7, 18),
          ),
      ]);

      final stats = await ImmersionStatsStorage.loadMangaStats();
      expect(stats, hasLength(1));
      expect(stats.single.charactersRead, 200);
      expect(stats.single.readingTimeMs, 2000);
    });
  });

  group('Anki statistics', () {
    test('counts manga and novel cards separately', () async {
      final date = DateTime(2026, 7, 18);
      await ImmersionStatsStorage.addAnkiCard(
        type: 'manga',
        profileId: 'ja',
        date: date,
      );
      await ImmersionStatsStorage.addAnkiCard(
        type: 'manga',
        profileId: 'ja',
        date: date,
      );
      await ImmersionStatsStorage.addAnkiCard(profileId: 'ja', date: date);

      final stats = await ImmersionStatsStorage.loadAnkiStats();
      expect(stats, hasLength(1));
      expect(stats.single.mangaCards, 2);
      expect(stats.single.novelCards, 1);
      expect(stats.single.totalCards, 3);
    });

    test('scopes rows by profile and title', () async {
      final date = DateTime(2026, 7, 18);
      await ImmersionStatsStorage.addAnkiCard(profileId: 'ja', date: date);
      await ImmersionStatsStorage.addAnkiCard(profileId: 'ko', date: date);
      await ImmersionStatsStorage.addAnkiCard(
        profileId: 'ja',
        titleId: 'book',
        date: date,
      );

      expect(await ImmersionStatsStorage.loadAnkiStats(), hasLength(3));
    });

    test('a null titleId is distinct from an empty one', () async {
      final date = DateTime(2026, 7, 18);
      await ImmersionStatsStorage.addAnkiCard(profileId: 'ja', date: date);
      await ImmersionStatsStorage.addAnkiCard(
        profileId: 'ja',
        titleId: '',
        date: date,
      );

      expect(await ImmersionStatsStorage.loadAnkiStats(), hasLength(2));
    });

    test('merge takes the larger card count per field', () async {
      await ImmersionStatsStorage.addAnkiCard(
        type: 'manga',
        profileId: 'ja',
        date: DateTime(2026, 7, 18),
      );
      await ImmersionStatsStorage.mergeAnkiStats([
        const AnkiStatsEntry(
          dateKey: '2026-07-18',
          mangaCards: 5,
          novelCards: 2,
          profileId: 'ja',
        ),
      ]);

      final stats = await ImmersionStatsStorage.loadAnkiStats();
      expect(stats, hasLength(1));
      expect(stats.single.mangaCards, 5);
      expect(stats.single.novelCards, 2);
    });
  });

  group('novel statistics', () {
    test('round-trips per book', () async {
      await ImmersionStatsStorage.saveNovelStats('book-a', [
        const NovelStatsEntry(
          dateKey: '2026-07-18',
          charactersRead: 900,
          readingTimeSeconds: 120.5,
          lastReadingSpeed: 26879,
        ),
      ]);
      await ImmersionStatsStorage.saveNovelStats('book-b', [
        const NovelStatsEntry(dateKey: '2026-07-18', charactersRead: 100),
      ]);

      final bookA = await ImmersionStatsStorage.loadNovelStats('book-a');
      expect(bookA.single.charactersRead, 900);
      // Fractional seconds must survive: Chimahon stores a double.
      expect(bookA.single.readingTimeSeconds, 120.5);
      expect(bookA.single.readingTimeMs, 120500);
      expect(
        (await ImmersionStatsStorage.loadNovelStats('book-b'))
            .single
            .charactersRead,
        100,
      );
    });

    test('loads every book that has statistics', () async {
      await ImmersionStatsStorage.saveNovelStats('book-a', [
        const NovelStatsEntry(dateKey: '2026-07-18', charactersRead: 1),
      ]);
      await ImmersionStatsStorage.saveNovelStats('book-b', [
        const NovelStatsEntry(dateKey: '2026-07-18', charactersRead: 2),
      ]);

      final all = await ImmersionStatsStorage.loadAllNovelStats();
      expect(all.keys, containsAll(['book-a', 'book-b']));
    });

    test('merge keeps the larger value per field, like Chimahon', () async {
      await ImmersionStatsStorage.saveNovelStats('book', [
        const NovelStatsEntry(
          dateKey: '2026-07-18',
          charactersRead: 500,
          readingTimeSeconds: 60,
          minReadingSpeed: 900,
          maxReadingSpeed: 3000,
          lastStatisticModified: 100,
        ),
        const NovelStatsEntry(
          dateKey: '2026-07-19',
          charactersRead: 100,
          lastStatisticModified: 100,
        ),
      ]);
      await ImmersionStatsStorage.mergeNovelStats('book', [
        // A newer clock does not erase reading the local row already holds.
        const NovelStatsEntry(
          dateKey: '2026-07-18',
          charactersRead: 300,
          readingTimeSeconds: 90,
          minReadingSpeed: 700,
          maxReadingSpeed: 2000,
          lastStatisticModified: 200,
        ),
        // Chimahon database backups carry no clock; the larger count wins.
        const NovelStatsEntry(dateKey: '2026-07-19', charactersRead: 999),
      ]);

      final byDate = {
        for (final entry in await ImmersionStatsStorage.loadNovelStats('book'))
          entry.dateKey: entry,
      };
      final first = byDate['2026-07-18']!;
      expect(first.charactersRead, 500);
      expect(first.readingTimeSeconds, 90);
      expect(first.minReadingSpeed, 700);
      expect(first.maxReadingSpeed, 3000);
      expect(first.lastStatisticModified, 200);
      final second = byDate['2026-07-19']!;
      expect(second.charactersRead, 999);
      expect(second.lastStatisticModified, 100);
    });

    test('deleting a book drops only its statistics', () async {
      await ImmersionStatsStorage.saveNovelStats('book-a', [
        const NovelStatsEntry(dateKey: '2026-07-18', charactersRead: 1),
      ]);
      await ImmersionStatsStorage.saveNovelStats('book-b', [
        const NovelStatsEntry(dateKey: '2026-07-18', charactersRead: 2),
      ]);
      await ImmersionStatsStorage.deleteNovelStats('book-a');

      expect(await ImmersionStatsStorage.loadNovelStats('book-a'), isEmpty);
      expect(
        await ImmersionStatsStorage.loadNovelStats('book-b'),
        hasLength(1),
      );
    });

    test('an empty book ID is not persisted', () async {
      await ImmersionStatsStorage.saveNovelStats('', [
        const NovelStatsEntry(dateKey: '2026-07-18', charactersRead: 1),
      ]);
      expect(await ImmersionStatsStorage.loadAllNovelStats(), isEmpty);
    });
  });

  test('a write bumps the revision so the UI can refresh', () async {
    final before = ImmersionStatsStorage.revision.value;
    await ImmersionStatsStorage.addMangaStats(characters: 10, timeMs: 100);
    expect(ImmersionStatsStorage.revision.value, greaterThan(before));
  });

  test('sync snapshot loads every statistics collection together', () async {
    await ImmersionStatsStorage.addMangaStats(
      characters: 10,
      timeMs: 100,
      mangaId: 7,
    );
    await ImmersionStatsStorage.addAnkiCard(profileId: 'ja');
    await ImmersionStatsStorage.saveNovelStats('book', [
      const NovelStatsEntry(dateKey: '2026-07-18', charactersRead: 1),
    ]);

    final snapshot = await ImmersionStatsStorage.loadSyncSnapshot();

    expect(snapshot.mangaStats.single.mangaId, 7);
    expect(snapshot.ankiStats.single.profileId, 'ja');
    expect(snapshot.novelStats['book'], hasLength(1));
  });

  test('clear removes every collection', () async {
    await ImmersionStatsStorage.addMangaStats(characters: 10, timeMs: 100);
    await ImmersionStatsStorage.addAnkiCard(profileId: 'ja');
    await ImmersionStatsStorage.saveNovelStats('book', [
      const NovelStatsEntry(dateKey: '2026-07-18', charactersRead: 1),
    ]);

    await ImmersionStatsStorage.clear();

    expect(await ImmersionStatsStorage.loadMangaStats(), isEmpty);
    expect(await ImmersionStatsStorage.loadAnkiStats(), isEmpty);
    expect(await ImmersionStatsStorage.loadAllNovelStats(), isEmpty);
  });

  test('a corrupt payload reads as empty rather than throwing', () async {
    final box = await Hive.openBox<dynamic>(ImmersionStatsStorage.boxName);
    await box.put('manga_stats', 'not json at all');

    expect(await ImmersionStatsStorage.loadMangaStats(), isEmpty);
    // The next write repairs the payload.
    await ImmersionStatsStorage.addMangaStats(characters: 10, timeMs: 100);
    expect(await ImmersionStatsStorage.loadMangaStats(), hasLength(1));
  });
}
