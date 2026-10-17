import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mangayomi/services/statistics/immersion_stats_storage.dart';
import 'package:mangayomi/services/statistics/manga_statistics_tracker.dart';

/// A stopwatch whose time only moves when the test says so.
class _FakeStopwatch extends Stopwatch {
  int now = 0;

  @override
  int get elapsedMilliseconds => now;
}

void main() {
  late Directory directory;
  late _FakeStopwatch clock;
  late MangaStatisticsTracker tracker;

  // Every page holds 100 OCR characters.
  Future<int> characters(int page) async => 100;

  Future<void> turnTo(int? page, {int afterMs = 0, bool incognito = false}) {
    clock.now += afterMs;
    return tracker.onPageChanged(
      pageIndex: page,
      charactersForPage: characters,
      incognito: incognito,
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('manga_stats_tracker');
    Hive.init(directory.path);
    clock = _FakeStopwatch();
    tracker = MangaStatisticsTracker(mangaId: 7, stopwatchFactory: () => clock);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await Hive.close();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('attributes a page when the reader leaves it', () async {
    await turnTo(0);
    await turnTo(1, afterMs: 10000);

    expect(tracker.session.charactersRead, 100);
    expect(tracker.session.readingTimeMs, 10000);
    final stored = (await ImmersionStatsStorage.loadMangaStats()).single;
    expect(stored.mangaId, 7);
    expect(stored.charactersRead, 100);
  });

  test('a page flipped past in under half a second is not reading', () async {
    await turnTo(0);
    await turnTo(1, afterMs: 400);

    expect(tracker.session.charactersRead, 0);
    expect(await ImmersionStatsStorage.loadMangaStats(), isEmpty);
  });

  test('time on one page is capped at two minutes', () async {
    await turnTo(0);
    await turnTo(1, afterMs: 10 * 60 * 1000);

    expect(
      tracker.session.readingTimeMs,
      MangaStatisticsTracker.maxPageDurationMs,
    );
  });

  test('revisiting a page within a chapter does not count it twice', () async {
    await turnTo(0);
    await turnTo(1, afterMs: 5000);
    await turnTo(0, afterMs: 5000);
    await turnTo(1, afterMs: 5000);

    // Page 0 and page 1 once each; the return visit to page 0 is skipped.
    expect(tracker.session.charactersRead, 200);
  });

  test(
    'closing the reader re-counts the open page, as Chimahon does',
    () async {
      // Chimahon clears its per-chapter set before attributing the page being
      // closed, so a revisited page counts again on close. Kept for parity.
      await turnTo(0);
      await turnTo(1, afterMs: 5000); // page 0 counted
      await turnTo(0, afterMs: 5000); // page 1 counted
      clock.now += 5000;
      await tracker.flush(charactersForPage: characters); // page 0 again

      expect(tracker.session.charactersRead, 300);
      // Nothing is open after closing, so a second flush adds nothing.
      clock.now += 5000;
      await tracker.flush(charactersForPage: characters);
      expect(tracker.session.charactersRead, 300);
    },
  );

  test('incognito reading is never recorded', () async {
    await turnTo(0);
    await turnTo(1, afterMs: 10000, incognito: true);

    expect(tracker.session.charactersRead, 0);
    expect(await ImmersionStatsStorage.loadMangaStats(), isEmpty);
  });

  test('pausing stops the live sheet but still records history', () async {
    await turnTo(0);
    tracker.toggleTracking();
    await turnTo(1, afterMs: 10000);

    expect(tracker.isTracking, isFalse);
    expect(tracker.session.charactersRead, 0);
    expect(
      (await ImmersionStatsStorage.loadMangaStats()).single.charactersRead,
      100,
    );
  });

  test('a new chapter forgets which pages were counted', () async {
    await turnTo(0);
    await turnTo(1, afterMs: 5000);
    tracker.resetChapter();
    await turnTo(0, afterMs: 5000);
    await turnTo(1, afterMs: 5000);

    expect(tracker.session.charactersRead, 300);
  });

  test('remaining time is zero, not infinite, at an unknown speed', () {
    expect(MangaStatsEstimate.secondsRemaining(3600, 0), 0);
    expect(MangaStatsEstimate.secondsRemaining(-5, 3600), 0);
    expect(MangaStatsEstimate.secondsRemaining(3600, 3600), 3600);
  });
}
