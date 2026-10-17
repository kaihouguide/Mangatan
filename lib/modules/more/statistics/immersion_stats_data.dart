/// Value types for the immersion statistics screen, ported from Chimahon's
/// `StatsData` / `StatsScreenState`.
library;

import 'package:mangayomi/services/statistics/immersion_stats_models.dart';

/// Which library the screen is reporting on.
enum ImmersionStatsType { all, manga, novels }

/// The window the screen aggregates over.
enum ImmersionStatsDateScale { day, week, month, year, allTime }

/// One bar in the hero chart.
class ImmersionHistoryPoint {
  const ImmersionHistoryPoint({
    required this.label,
    required this.durationMs,
    required this.dateOffset,
  });

  final String label;
  final int durationMs;

  /// Offset from the current period, in the units of the active scale. Tapping
  /// a bar navigates to this offset.
  final int dateOffset;
}

/// Everything the stats screen renders for one filter combination.
class ImmersionStatsOverview {
  const ImmersionStatsOverview({
    this.libraryTitleCount = 0,
    this.completedTitleCount = 0,
    this.startedTitleCount = 0,
    this.localTitleCount = 0,
    this.totalReadDurationMs = 0,
    this.readingStreak = 0,
    this.historyPoints = const [],
    this.avgDurationPerDayMs,
    this.ankiCardsAdded = 0,
    this.charactersRead = 0,
    this.charactersPerHour,
    this.totalChapterCount = 0,
    this.readChapterCount = 0,
    this.downloadedChapterCount = 0,
    this.trackedTitleCount = 0,
    this.meanScore = 0,
    this.trackerCount = 0,
  });

  final int libraryTitleCount;
  final int completedTitleCount;
  final int startedTitleCount;
  final int localTitleCount;
  final int totalReadDurationMs;
  final int readingStreak;
  final List<ImmersionHistoryPoint> historyPoints;

  /// Null for the day and all-time scales, where a per-day average is either
  /// the value itself or spans an unknown number of days.
  final int? avgDurationPerDayMs;
  final int ankiCardsAdded;
  final int charactersRead;

  /// Null when no time was recorded, so the UI can distinguish "no data" from
  /// a genuine zero.
  final int? charactersPerHour;
  final int totalChapterCount;
  final int readChapterCount;
  final int downloadedChapterCount;
  final int trackedTitleCount;
  final double meanScore;
  final int trackerCount;
}

/// The filter tuple the screen requests statistics for.
class ImmersionStatsQuery {
  const ImmersionStatsQuery({
    this.type = ImmersionStatsType.all,
    this.scale = ImmersionStatsDateScale.day,
    this.offset = 0,
    this.profileId,
    this.titleId,
    this.isNovel = false,
    this.includeNonLibrary = true,
  });

  final ImmersionStatsType type;
  final ImmersionStatsDateScale scale;

  /// Zero is the current period; negative values move into the past.
  final int offset;

  /// Null means every dictionary profile.
  final String? profileId;

  /// Set for the single-title view. Manga use the Isar ID as a string; novels
  /// use Chimahon's stable book ID.
  final String? titleId;
  final bool isNovel;

  /// Chimahon's "include all read entries" toggle: when false, only titles
  /// currently in the library are counted.
  final bool includeNonLibrary;

  ImmersionStatsQuery copyWith({
    ImmersionStatsType? type,
    ImmersionStatsDateScale? scale,
    int? offset,
    String? profileId,
    bool clearProfileId = false,
    String? titleId,
    bool? isNovel,
    bool? includeNonLibrary,
  }) => ImmersionStatsQuery(
    type: type ?? this.type,
    scale: scale ?? this.scale,
    offset: offset ?? this.offset,
    profileId: clearProfileId ? null : (profileId ?? this.profileId),
    titleId: titleId ?? this.titleId,
    isNovel: isNovel ?? this.isNovel,
    includeNonLibrary: includeNonLibrary ?? this.includeNonLibrary,
  );

  @override
  bool operator ==(Object other) =>
      other is ImmersionStatsQuery &&
      other.type == type &&
      other.scale == scale &&
      other.offset == offset &&
      other.profileId == profileId &&
      other.titleId == titleId &&
      other.isNovel == isNovel &&
      other.includeNonLibrary == includeNonLibrary;

  @override
  int get hashCode => Object.hash(
    type,
    scale,
    offset,
    profileId,
    titleId,
    isNovel,
    includeNonLibrary,
  );
}

/// One row in the per-title statistics list.
class ImmersionStatsTitle {
  const ImmersionStatsTitle({
    required this.id,
    required this.title,
    this.author,
    this.isNovel = false,
    this.mangaId,
    this.lastReadDate,
    this.readDurationMs = 0,
    this.charactersRead = 0,
    this.dateAdded = 0,
  });

  final String id;
  final String title;
  final String? author;
  final bool isNovel;

  /// Local Isar ID, used to load the cover. Novels resolve theirs through the
  /// parent library entry.
  final int? mangaId;
  final DateTime? lastReadDate;
  final int readDurationMs;
  final int charactersRead;
  final int dateAdded;
}

/// Sort orders for the per-title list.
enum ImmersionStatsTitlesSort { alphabetical, lastRead, dateAdded }

/// Inclusive date window for a scale/offset pair.
class ImmersionStatsDateRange {
  const ImmersionStatsDateRange(this.start, this.end);

  final DateTime start;
  final DateTime end;

  bool containsKey(String dateKey) =>
      dateKey.compareTo(_key(start)) >= 0 && dateKey.compareTo(_key(end)) <= 0;

  static String _key(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

/// Resolves the window a scale/offset pair covers.
///
/// All-time uses Chimahon's fixed 2000-01-01 lower bound, which predates any
/// possible reading record.
ImmersionStatsDateRange immersionStatsDateRange(
  ImmersionStatsDateScale scale,
  int offset, {
  DateTime? now,
}) {
  final today = _dateOnly(now ?? DateTime.now());
  switch (scale) {
    case ImmersionStatsDateScale.day:
      final date = addStatsDays(today, offset);
      return ImmersionStatsDateRange(date, date);
    case ImmersionStatsDateScale.week:
      final start = _startOfWeek(addStatsDays(today, offset * 7));
      return ImmersionStatsDateRange(start, addStatsDays(start, 6));
    case ImmersionStatsDateScale.month:
      final start = _addMonths(DateTime(today.year, today.month), offset);
      return ImmersionStatsDateRange(
        start,
        addStatsDays(_addMonths(start, 1), -1),
      );
    case ImmersionStatsDateScale.year:
      final start = DateTime(today.year + offset);
      return ImmersionStatsDateRange(start, DateTime(start.year, 12, 31));
    case ImmersionStatsDateScale.allTime:
      return ImmersionStatsDateRange(DateTime(2000), today);
  }
}

DateTime _dateOnly(DateTime date) => DateTime(date.year, date.month, date.day);

/// Chimahon's weeks start on Monday (`with(DayOfWeek.MONDAY)`).
DateTime _startOfWeek(DateTime date) =>
    addStatsDays(date, DateTime.monday - date.weekday);

/// Moves [date] by whole calendar days and drops its time of day.
///
/// Adding a `Duration` of days to a local time is wrong across a daylight
/// saving change: the result lands an hour off, on the previous day's 23:00
/// or the next day's 01:00.
DateTime addStatsDays(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);

/// Calendar days from [from] to [to], ignoring time of day and daylight
/// saving changes.
int statsDaysBetween(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// Adds months without overflowing into the next month for short months.
DateTime _addMonths(DateTime date, int months) {
  final totalMonths = date.year * 12 + (date.month - 1) + months;
  final year = totalMonths ~/ 12;
  final month = totalMonths % 12 + 1;
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, date.day > lastDay ? lastDay : date.day);
}

/// Consecutive days ending today (or yesterday) with any recorded reading.
int immersionReadingStreak(
  List<MangaStatsEntry> mangaStats,
  List<NovelStatsEntry> novelStats, {
  DateTime? now,
}) {
  final days = <DateTime>{};
  for (final entry in mangaStats) {
    final date = parseStatsDateKey(entry.dateKey);
    if (date != null) days.add(date);
  }
  for (final entry in novelStats) {
    final date = parseStatsDateKey(entry.dateKey);
    if (date != null) days.add(date);
  }
  if (days.isEmpty) return 0;

  var current = _dateOnly(now ?? DateTime.now());
  // Not having read yet today does not break a streak; it resumes from
  // yesterday.
  if (!days.contains(current)) {
    current = addStatsDays(current, -1);
  }
  var streak = 0;
  while (days.contains(current)) {
    streak++;
    current = addStatsDays(current, -1);
  }
  return streak;
}

/// The bars for the hero chart: a week of days, a month of weeks, a year of
/// months, or the last five years.
List<ImmersionHistoryPoint> immersionHistoryPoints({
  required List<MangaStatsEntry> mangaStats,
  required List<NovelStatsEntry> novelStats,
  required ImmersionStatsDateScale scale,
  required int offset,
  DateTime? now,
}) {
  final today = _dateOnly(now ?? DateTime.now());
  final range = immersionStatsDateRange(scale, offset, now: today);

  int durationFor(DateTime start, DateTime end) {
    final window = ImmersionStatsDateRange(start, end);
    var total = 0;
    for (final entry in mangaStats) {
      if (window.containsKey(entry.dateKey)) total += entry.readingTimeMs;
    }
    for (final entry in novelStats) {
      if (window.containsKey(entry.dateKey)) total += entry.readingTimeMs;
    }
    return total;
  }

  switch (scale) {
    case ImmersionStatsDateScale.day:
      final weekStart = _startOfWeek(range.start);
      return [
        for (var i = 0; i < 7; i++)
          () {
            final date = addStatsDays(weekStart, i);
            return ImmersionHistoryPoint(
              label: _weekdayLabels[date.weekday - 1],
              durationMs: durationFor(date, date),
              dateOffset: statsDaysBetween(today, date),
            );
          }(),
      ];
    case ImmersionStatsDateScale.week:
      // Bars cover the weeks of the month the selected week falls in; the
      // Thursday of an ISO week always lies inside its owning month.
      final anchor = addStatsDays(range.start, 3);
      final monthStart = DateTime(anchor.year, anchor.month);
      final monthEnd = DateTime(anchor.year, anchor.month + 1, 0);
      final firstMonday = _startOfWeek(monthStart);
      final lastMonday = _startOfWeek(monthEnd);
      final weeks = statsDaysBetween(firstMonday, lastMonday) ~/ 7 + 1;
      final currentMonday = _startOfWeek(today);
      return [
        for (var i = 0; i < (weeks < 4 ? 4 : weeks); i++)
          () {
            final weekStart = addStatsDays(firstMonday, i * 7);
            final weekEnd = addStatsDays(weekStart, 6);
            return ImmersionHistoryPoint(
              label: 'W${_isoWeekNumber(weekStart)}',
              durationMs: durationFor(weekStart, weekEnd),
              dateOffset: statsDaysBetween(currentMonday, weekStart) ~/ 7,
            );
          }(),
      ];
    case ImmersionStatsDateScale.month:
      return [
        for (var month = 1; month <= 12; month++)
          () {
            final start = DateTime(range.start.year, month);
            final end = DateTime(range.start.year, month + 1, 0);
            return ImmersionHistoryPoint(
              label: _monthLabels[month - 1],
              durationMs: durationFor(start, end),
              dateOffset:
                  (start.year - today.year) * 12 + (start.month - today.month),
            );
          }(),
      ];
    case ImmersionStatsDateScale.year:
    case ImmersionStatsDateScale.allTime:
      return [
        for (var yearsAgo = 4; yearsAgo >= 0; yearsAgo--)
          () {
            final year = today.year - yearsAgo;
            return ImmersionHistoryPoint(
              label: year.toString(),
              durationMs: durationFor(DateTime(year), DateTime(year, 12, 31)),
              dateOffset: -yearsAgo,
            );
          }(),
      ];
  }
}

/// ISO-8601 week number, matching Chimahon's `WEEK_OF_WEEK_BASED_YEAR`.
int _isoWeekNumber(DateTime date) {
  final thursday = addStatsDays(date, DateTime.thursday - date.weekday);
  final firstThursday = DateTime(thursday.year, 1, 4);
  final firstThursdayOfYear = addStatsDays(
    firstThursday,
    DateTime.thursday - firstThursday.weekday,
  );
  return 1 + statsDaysBetween(firstThursdayOfYear, thursday) ~/ 7;
}

/// The most recent valid date among [dateKeys].
DateTime? latestStatsDate(Iterable<String> dateKeys) {
  DateTime? latest;
  for (final key in dateKeys) {
    final date = parseStatsDateKey(key);
    if (date == null) continue;
    if (latest == null || date.isAfter(latest)) latest = date;
  }
  return latest;
}

const _weekdayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _monthLabels = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
