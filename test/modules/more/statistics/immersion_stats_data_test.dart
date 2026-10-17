import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/modules/more/statistics/immersion_stats_data.dart';
import 'package:mangayomi/modules/more/statistics/widgets/immersion_stats_format.dart';
import 'package:mangayomi/services/statistics/immersion_stats_models.dart';

void main() {
  // A Saturday, so weekday handling is exercised away from the boundaries.
  final now = DateTime(2026, 7, 18, 15, 30);

  group('date ranges', () {
    test('a day is a single date', () {
      final range = immersionStatsDateRange(
        ImmersionStatsDateScale.day,
        0,
        now: now,
      );
      expect(range.start, DateTime(2026, 7, 18));
      expect(range.end, DateTime(2026, 7, 18));
    });

    test('a negative day offset moves into the past', () {
      final range = immersionStatsDateRange(
        ImmersionStatsDateScale.day,
        -3,
        now: now,
      );
      expect(range.start, DateTime(2026, 7, 15));
    });

    test('weeks start on Monday and span seven days', () {
      final range = immersionStatsDateRange(
        ImmersionStatsDateScale.week,
        0,
        now: now,
      );
      expect(range.start.weekday, DateTime.monday);
      expect(range.start, DateTime(2026, 7, 13));
      expect(range.end, DateTime(2026, 7, 19));
    });

    test('a month covers its own length', () {
      final range = immersionStatsDateRange(
        ImmersionStatsDateScale.month,
        0,
        now: now,
      );
      expect(range.start, DateTime(2026, 7, 1));
      expect(range.end, DateTime(2026, 7, 31));
    });

    test('stepping back from a long month lands on a valid date', () {
      // 31 July minus one month must not overflow into 1 July via a 31 June.
      final range = immersionStatsDateRange(
        ImmersionStatsDateScale.month,
        -1,
        now: DateTime(2026, 7, 31),
      );
      expect(range.start, DateTime(2026, 6, 1));
      expect(range.end, DateTime(2026, 6, 30));
    });

    test('February is handled including leap years', () {
      final leap = immersionStatsDateRange(
        ImmersionStatsDateScale.month,
        0,
        now: DateTime(2028, 2, 10),
      );
      expect(leap.end, DateTime(2028, 2, 29));

      final common = immersionStatsDateRange(
        ImmersionStatsDateScale.month,
        0,
        now: DateTime(2026, 2, 10),
      );
      expect(common.end, DateTime(2026, 2, 28));
    });

    test('a year spans January to December', () {
      final range = immersionStatsDateRange(
        ImmersionStatsDateScale.year,
        0,
        now: now,
      );
      expect(range.start, DateTime(2026, 1, 1));
      expect(range.end, DateTime(2026, 12, 31));
    });

    test('all time reaches back before any possible record', () {
      final range = immersionStatsDateRange(
        ImmersionStatsDateScale.allTime,
        0,
        now: now,
      );
      expect(range.start, DateTime(2000));
      expect(range.end, DateTime(2026, 7, 18));
      expect(range.containsKey('2001-01-01'), isTrue);
    });

    test('containsKey is inclusive at both ends', () {
      final range = immersionStatsDateRange(
        ImmersionStatsDateScale.week,
        0,
        now: now,
      );
      expect(range.containsKey('2026-07-13'), isTrue);
      expect(range.containsKey('2026-07-19'), isTrue);
      expect(range.containsKey('2026-07-12'), isFalse);
      expect(range.containsKey('2026-07-20'), isFalse);
    });
  });

  group('date keys', () {
    test('are zero-padded like Chimahon LocalDate.toString', () {
      expect(statsDateKey(DateTime(2026, 1, 5)), '2026-01-05');
      expect(statsDateKey(DateTime(2026, 12, 31)), '2026-12-31');
    });

    test('sort lexicographically in chronological order', () {
      final keys = [
        statsDateKey(DateTime(2026, 12, 1)),
        statsDateKey(DateTime(2026, 2, 1)),
        statsDateKey(DateTime(2025, 12, 1)),
      ]..sort();
      expect(keys, ['2025-12-01', '2026-02-01', '2026-12-01']);
    });

    test('parse discards the time component and rejects garbage', () {
      expect(parseStatsDateKey('2026-07-18'), DateTime(2026, 7, 18));
      expect(parseStatsDateKey('nonsense'), isNull);
      expect(parseStatsDateKey(''), isNull);
    });
  });

  group('formatting', () {
    test('counts are grouped with commas', () {
      expect(formatCount(0), '0');
      expect(formatCount(999), '999');
      expect(formatCount(1000), '1,000');
      expect(formatCount(1234567), '1,234,567');
      expect(formatCount(-1234), '-1,234');
    });

    test('elapsed time drops the hour component when there is none', () {
      expect(formatElapsed(const Duration(seconds: 5)), '00:05');
      expect(formatElapsed(const Duration(minutes: 3, seconds: 7)), '03:07');
      expect(
        formatElapsed(const Duration(hours: 2, minutes: 3, seconds: 7)),
        '2:03:07',
      );
    });

    test('estimates omit leading zero components', () {
      expect(formatEstimate(45), '45s');
      expect(formatEstimate(125), '2m 5s');
      expect(formatEstimate(7325), '2h 2m 5s');
    });

    test('a non-finite or negative estimate reads as zero', () {
      expect(formatEstimate(double.infinity), '0s');
      expect(formatEstimate(double.nan), '0s');
      expect(formatEstimate(-100), '0s');
    });

    test('period labels use relative wording for recent periods', () {
      expect(
        immersionStatsPeriodLabel(ImmersionStatsDateScale.day, 0, now: now),
        'Today',
      );
      expect(
        immersionStatsPeriodLabel(ImmersionStatsDateScale.day, -1, now: now),
        'Yesterday',
      );
      expect(
        immersionStatsPeriodLabel(ImmersionStatsDateScale.day, -5, now: now),
        'Jul 13',
      );
      expect(
        immersionStatsPeriodLabel(ImmersionStatsDateScale.week, -1, now: now),
        'Last week',
      );
      expect(
        immersionStatsPeriodLabel(ImmersionStatsDateScale.month, -2, now: now),
        'May 2026',
      );
      expect(
        immersionStatsPeriodLabel(ImmersionStatsDateScale.year, -2, now: now),
        '2024',
      );
    });
  });

  test('a query compares by value so providers can cache on it', () {
    const a = ImmersionStatsQuery(type: ImmersionStatsType.manga, offset: -1);
    const b = ImmersionStatsQuery(type: ImmersionStatsType.manga, offset: -1);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a.copyWith(offset: -2), isNot(b));
  });

  test('clearing the profile filter is distinct from leaving it alone', () {
    const withProfile = ImmersionStatsQuery(profileId: 'ja');
    // copyWith cannot express "set to null" via the value parameter alone.
    expect(withProfile.copyWith(offset: -1).profileId, 'ja');
    expect(withProfile.copyWith(clearProfileId: true).profileId, isNull);
  });

  // Europe and North America change clocks on a Sunday in late March and late
  // October. These dates straddle those changes; run `flutter test` with `TZ`
  // set to a zone that observes daylight saving to exercise them.
  group('daylight saving changes', () {
    final afterSpringChange = DateTime(2026, 3, 30, 9);

    test('calendar day arithmetic ignores the lost or gained hour', () {
      expect(addStatsDays(DateTime(2026, 3, 30), -1), DateTime(2026, 3, 29));
      expect(addStatsDays(DateTime(2026, 10, 19), 7), DateTime(2026, 10, 26));
      expect(
        statsDaysBetween(DateTime(2026, 3, 30), DateTime(2026, 3, 23)),
        -7,
      );
      expect(statsDaysBetween(DateTime(2026, 3, 1), DateTime(2026, 3, 31)), 30);
    });

    test('stepping back a day lands on the previous date', () {
      final range = immersionStatsDateRange(
        ImmersionStatsDateScale.day,
        -1,
        now: afterSpringChange,
      );
      expect(range.start, DateTime(2026, 3, 29));
    });

    test('a streak continues across the change', () {
      final streak = immersionReadingStreak(
        [
          for (final day in [27, 28, 29, 30])
            MangaStatsEntry(dateKey: '2026-03-$day', readingTimeMs: 1000),
        ],
        const [],
        now: afterSpringChange,
      );
      expect(streak, 4);
    });

    test('day bars point at their own date', () {
      final points = immersionHistoryPoints(
        mangaStats: const [
          MangaStatsEntry(dateKey: '2026-03-23', readingTimeMs: 5000),
        ],
        novelStats: const [],
        scale: ImmersionStatsDateScale.day,
        offset: -7,
        now: afterSpringChange,
      );
      expect(points.first.label, 'Mon');
      expect(points.first.durationMs, 5000);
      expect(points.first.dateOffset, -7);
    });

    test('week bars stay Monday to Sunday after the autumn change', () {
      final points = immersionHistoryPoints(
        mangaStats: const [
          MangaStatsEntry(dateKey: '2026-10-26', readingTimeMs: 3000),
          MangaStatsEntry(dateKey: '2026-11-01', readingTimeMs: 4000),
        ],
        novelStats: const [],
        scale: ImmersionStatsDateScale.week,
        offset: 0,
        now: DateTime(2026, 10, 28, 9),
      );
      final week = points.singleWhere((point) => point.dateOffset == 0);
      expect(week.label, 'W44');
      expect(week.durationMs, 7000);
    });
  });

  group('history', () {
    test('a streak survives not having read yet today', () {
      final streak = immersionReadingStreak(
        const [
          MangaStatsEntry(dateKey: '2026-07-16'),
          MangaStatsEntry(dateKey: '2026-07-17'),
        ],
        const [NovelStatsEntry(dateKey: '2026-07-15')],
        now: now,
      );
      expect(streak, 3);
    });

    test('a gap ends the streak', () {
      final streak = immersionReadingStreak(
        const [
          MangaStatsEntry(dateKey: '2026-07-18'),
          MangaStatsEntry(dateKey: '2026-07-16'),
        ],
        const [],
        now: now,
      );
      expect(streak, 1);
    });

    test('the latest date ignores malformed keys', () {
      expect(
        latestStatsDate(['2026-07-01', 'garbage', '2026-07-09', '2026-06-30']),
        DateTime(2026, 7, 9),
      );
      expect(latestStatsDate(['garbage']), isNull);
    });
  });
}
