import 'package:isar_community/isar.dart';
import 'package:mangayomi/eval/model/m_manga.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/repositories/db_write_queue.dart';

/// The season flag layout used by Anikku 0.2 and its Mihon/Chimahon backup
/// schema. Keep these values in one place because the same bit field is also
/// edited by the season list controls and transported through protobuf.
abstract final class AnimeSeasonFlags {
  static const sortDirectionMask = 0x00000001;
  static const sortDescending = 0x00000000;
  static const sortAscending = 0x00000001;

  static const showDownloaded = 0x00000002;
  static const showNotDownloaded = 0x00000004;
  static const downloadedMask = 0x00000006;
  static const showUnseen = 0x00000008;
  static const showSeen = 0x00000010;
  static const unseenMask = 0x00000018;
  static const showStarted = 0x00000020;
  static const showNotStarted = 0x00000040;
  static const startedMask = 0x00000060;
  static const showCompleted = 0x00000080;
  static const showNotCompleted = 0x00000100;
  static const completedMask = 0x00000180;
  static const showBookmarked = 0x00000200;
  static const showNotBookmarked = 0x00000400;
  static const bookmarkedMask = 0x00000600;
  static const showFillermarked = 0x00000800;
  static const showNotFillermarked = 0x00001000;
  static const fillermarkedMask = 0x00001800;
  static const filtersMask =
      downloadedMask |
      unseenMask |
      startedMask |
      completedMask |
      bookmarkedMask |
      fillermarkedMask;

  static const sortSource = 0x00000000;
  static const sortSeasonNumber = 0x00002000;
  static const sortUploadDate = 0x00004000;
  static const sortAlphabetical = 0x00006000;
  static const sortUnseen = 0x00008000;
  static const sortLastSeen = 0x0000a000;
  static const sortFetchDate = 0x0000c000;
  static const sortMask = 0x0000e000;

  static const gridDisplayModeShift = 16;
  static const gridDisplayModeMask = 0x00030000;
  static const gridDisplaySizeShift = 18;
  static const gridDisplaySizeMask = 0x003c0000;
  static const overlayDownloadedMask = 0x00400000;
  static const overlayUnseenMask = 0x00800000;
  static const overlayLocalMask = 0x01000000;
  static const overlayLanguageMask = 0x02000000;
  static const overlayContinueMask = 0x04000000;
  static const displayModeNumber = 0x08000000;
  static const displayModeMask = 0x08000000;

  /// What Anikku and Animiru apply to an anime that has never had season
  /// settings: newest season first by source order, a compact grid, and the
  /// unseen, local and continue-watching overlays.
  static const defaults =
      sortDescending |
      sortSource |
      overlayUnseenMask |
      overlayLocalMask |
      overlayContinueMask;

  /// [flags] as stored, or [defaults] for an anime never configured.
  static int effective(int? flags) => flags ?? defaults;

  static int sortMode(int flags) => flags & sortMask;

  static bool isAscending(int flags) =>
      flags & sortDirectionMask == sortAscending;

  /// Anikku's sort control: choosing the current sort flips its direction,
  /// and choosing another sort starts it ascending.
  static int withSortOrFlip(int flags, int sort) {
    if (sortMode(flags) == sort & sortMask) {
      return flags ^ sortDirectionMask;
    }
    return (flags & ~(sortMask | sortDirectionMask)) |
        (sort & sortMask) |
        sortAscending;
  }

  static AnimeSeasonFilter filter(int flags, int include, int exclude) {
    final mask = include | exclude;
    return switch (flags & mask) {
      final value when value == include => AnimeSeasonFilter.include,
      final value when value == exclude => AnimeSeasonFilter.exclude,
      _ => AnimeSeasonFilter.any,
    };
  }

  static int withFilter(
    int flags,
    int include,
    int exclude,
    AnimeSeasonFilter state,
  ) {
    final value = switch (state) {
      AnimeSeasonFilter.any => 0,
      AnimeSeasonFilter.include => include,
      AnimeSeasonFilter.exclude => exclude,
    };
    return (flags & ~(include | exclude)) | value;
  }

  static bool hasActiveFilters(int flags) => flags & filtersMask != 0;

  static AnimeSeasonDisplayMode displayMode(int flags) =>
      AnimeSeasonDisplayMode.values[(flags & gridDisplayModeMask) >>
          gridDisplayModeShift];

  static int withDisplayMode(int flags, AnimeSeasonDisplayMode mode) =>
      (flags & ~gridDisplayModeMask) | (mode.index << gridDisplayModeShift);

  /// Grid columns, or rows of list entries; zero means automatic.
  static int gridSize(int flags) =>
      (flags & gridDisplaySizeMask) >> gridDisplaySizeShift;

  static int withGridSize(int flags, int size) =>
      (flags & ~gridDisplaySizeMask) |
      ((size.clamp(0, 15) << gridDisplaySizeShift) & gridDisplaySizeMask);

  static bool isSet(int flags, int mask) => flags & mask == mask;

  static int withBit(int flags, int mask, bool enabled) =>
      enabled ? flags | mask : flags & ~mask;
}

/// A tri-state season filter, as in Anikku's filter sheet.
enum AnimeSeasonFilter { any, include, exclude }

/// Season presentation, in Anikku's wire order.
enum AnimeSeasonDisplayMode {
  compactGrid,
  comfortableGrid,
  coverOnlyGrid,
  list,
}

/// Episode and download totals for one season, mirroring Anikku's
/// `SeasonAnime` plus the per-item download count.
class AnimeSeasonStats {
  const AnimeSeasonStats({
    this.totalCount = 0,
    this.seenCount = 0,
    this.bookmarkCount = 0,
    this.fillermarkCount = 0,
    this.downloadCount = 0,
    this.latestUpload = 0,
    this.fetchedAt = 0,
    this.lastSeen = 0,
  });

  final int totalCount;
  final int seenCount;
  final int bookmarkCount;
  final int fillermarkCount;
  final int downloadCount;
  final int latestUpload;
  final int fetchedAt;
  final int lastSeen;

  int get unseenCount => totalCount - seenCount;
  bool get seen => totalCount == seenCount;
  bool get hasStarted => seenCount > 0;
}

/// One season with its statistics.
typedef AnimeSeasonEntry = ({Manga season, AnimeSeasonStats stats});

/// Applies the season filters and sort in [flags] the way Anikku does:
/// "completed" is the source's status, "downloaded" includes local seasons,
/// and ties fall back to the title.
List<AnimeSeasonEntry> filterAndSortAnimeSeasons(
  Iterable<AnimeSeasonEntry> entries,
  int flags,
) {
  bool keep(int include, int exclude, bool value) =>
      switch (AnimeSeasonFlags.filter(flags, include, exclude)) {
        AnimeSeasonFilter.any => true,
        AnimeSeasonFilter.include => value,
        AnimeSeasonFilter.exclude => !value,
      };

  final kept = entries.where((entry) {
    final (:season, :stats) = entry;
    return keep(
          AnimeSeasonFlags.showUnseen,
          AnimeSeasonFlags.showSeen,
          !stats.seen,
        ) &&
        keep(
          AnimeSeasonFlags.showDownloaded,
          AnimeSeasonFlags.showNotDownloaded,
          stats.downloadCount > 0 || season.isLocalArchive == true,
        ) &&
        keep(
          AnimeSeasonFlags.showStarted,
          AnimeSeasonFlags.showNotStarted,
          stats.hasStarted,
        ) &&
        keep(
          AnimeSeasonFlags.showCompleted,
          AnimeSeasonFlags.showNotCompleted,
          season.status == Status.completed,
        ) &&
        keep(
          AnimeSeasonFlags.showBookmarked,
          AnimeSeasonFlags.showNotBookmarked,
          stats.bookmarkCount > 0,
        ) &&
        keep(
          AnimeSeasonFlags.showFillermarked,
          AnimeSeasonFlags.showNotFillermarked,
          stats.fillermarkCount > 0,
        );
  }).toList();

  int byTitle(AnimeSeasonEntry a, AnimeSeasonEntry b) => (a.season.name ?? '')
      .toLowerCase()
      .compareTo((b.season.name ?? '').toLowerCase());

  int bySort(AnimeSeasonEntry a, AnimeSeasonEntry b) =>
      switch (AnimeSeasonFlags.sortMode(flags)) {
        AnimeSeasonFlags.sortSeasonNumber =>
          (a.season.seasonNumber ?? -1).compareTo(b.season.seasonNumber ?? -1),
        AnimeSeasonFlags.sortUploadDate => a.stats.latestUpload.compareTo(
          b.stats.latestUpload,
        ),
        AnimeSeasonFlags.sortAlphabetical => byTitle(a, b),
        AnimeSeasonFlags.sortUnseen => a.stats.unseenCount.compareTo(
          b.stats.unseenCount,
        ),
        AnimeSeasonFlags.sortLastSeen => a.stats.lastSeen.compareTo(
          b.stats.lastSeen,
        ),
        AnimeSeasonFlags.sortFetchDate => a.stats.fetchedAt.compareTo(
          b.stats.fetchedAt,
        ),
        _ => (a.season.seasonSourceOrder ?? 0).compareTo(
          b.season.seasonSourceOrder ?? 0,
        ),
      };

  final ascending = AnimeSeasonFlags.isAscending(flags);
  kept.sort((a, b) {
    final order = ascending ? bySort(a, b) : bySort(b, a);
    return order != 0 ? order : byTitle(a, b);
  });
  return kept;
}

/// Anikku's "Season N" title, dropping a whole number's decimal.
String animeSeasonNumberLabel(double? number) {
  if (number == null || number < 0) return '?';
  return number == number.truncateToDouble()
      ? number.toInt().toString()
      : number.toString();
}

final _seasonNumberPattern = RegExp(r'([0-9]+)(\.[0-9]+)?(\.?[a-z]+)?');
final _seasonBasicPattern = RegExp(
  r'(?:\bs\.|\bs|season)\s*([0-9]+)(\.[0-9]+)?(\.?[a-z]+)?',
  caseSensitive: false,
);
final _seasonTagPattern = RegExp(
  r'^\s*(?:\[[^]]+\]\s*|\([^)]+\)\s*)+|\s*(?:\[[^]]+\]\s*|\([^)]+\)\s*)+$',
);
final _seasonUnwantedPattern = RegExp(
  r'\b\d+p\b|\d+x\d+|Hi10|\(\d+\)',
  caseSensitive: false,
);
final _seasonUnwantedWhitespace = RegExp(
  r'\s(?=extra|special|omake)',
  caseSensitive: false,
);

/// Port of Anikku's season recognition. Sources often omit `season_number`
/// and put the information only in names such as "Series S02" or
/// "Series 1 special". The decimal suffixes keep specials and split seasons
/// ordered without inventing a new wire field.
double recognizeAnimeSeasonNumber(
  String animeTitle,
  String seasonTitle,
  double? sourceNumber,
) {
  if (sourceNumber != null &&
      (sourceNumber == -2 || sourceNumber > -1) &&
      !sourceNumber.isNaN) {
    return sourceNumber;
  }

  var clean = seasonTitle.toLowerCase();
  if (animeTitle.isNotEmpty) {
    clean = clean.replaceAll(
      RegExp(RegExp.escape(animeTitle.toLowerCase()), caseSensitive: false),
      '',
    );
  }
  clean = clean
      .replaceAll(',', '.')
      .replaceAll('-', '.')
      .replaceAll(_seasonUnwantedWhitespace, '')
      .replaceAll(_seasonTagPattern, '')
      .trim();

  final matches = _seasonNumberPattern.allMatches(clean).toList();
  if (matches.isEmpty) return sourceNumber ?? -1;

  RegExpMatch match = matches.first;
  if (matches.length > 1) {
    final withoutQuality = clean.replaceAll(_seasonUnwantedPattern, '');
    final basic = _seasonBasicPattern.firstMatch(withoutQuality);
    match = basic ?? _seasonNumberPattern.firstMatch(withoutQuality) ?? match;
  }
  return _seasonNumberFromMatch(match);
}

double _seasonNumberFromMatch(RegExpMatch match) {
  final initial = double.parse(match.group(1)!);
  final decimal = match.group(2);
  final alpha = match.group(3);
  if (decimal != null && decimal.isNotEmpty) {
    return initial + double.parse(decimal);
  }
  if (alpha == null || alpha.isEmpty) return initial;
  final normalized = alpha.toLowerCase().replaceFirst('.', '');
  if (normalized.contains('extra')) return initial + .99;
  if (normalized.contains('omake')) return initial + .98;
  if (normalized.contains('special')) return initial + .97;
  if (normalized.length == 1) {
    final suffix = normalized.codeUnitAt(0) - 'a'.codeUnitAt(0) + 1;
    if (suffix > 0 && suffix < 10) return initial + suffix / 10;
  }
  return initial;
}

bool sameAnimeSource(Manga left, Manga right) =>
    left.itemType == ItemType.anime &&
    right.itemType == ItemType.anime &&
    (left.mihonSourceId != null && right.mihonSourceId != null
        ? left.mihonSourceId == right.mihonSourceId
        : left.sourceId != null && left.sourceId == right.sourceId);

/// Includes unfavorited seasons of library series in portable backups.
List<Manga> animeSeasonLibraryClosure(Iterable<Manga> entries) {
  final all = entries.toList();
  final included = all
      .where((m) => m.favorite == true || m.favoriteModifiedAt != null)
      .toSet();
  bool changed;
  do {
    changed = false;
    for (final entry in all) {
      if (included.contains(entry) || entry.animeParentUrl == null) continue;
      if (included.any(
        (parent) =>
            parent.hasSeasons &&
            parent.link == entry.animeParentUrl &&
            sameAnimeSource(parent, entry),
      )) {
        included.add(entry);
        changed = true;
      }
    }
  } while (changed);
  return all.where(included.contains).toList();
}

/// Reuses source identities, keeping season progress and custom titles. A
/// removed season is detached, never deleted together with its downloads.
Future<List<int>> storeAnimeSeasons(
  Isar database,
  Manga parent,
  List<MManga> seasons, {
  bool sourceIsLocal = false,
}) async {
  if (seasons.isEmpty && !sourceIsLocal) {
    throw StateError('The source returned no seasons. Try refreshing again.');
  }
  if (parent.link == null || parent.link!.isEmpty) {
    throw StateError('The parent anime has no source URL.');
  }
  final urls = <String>{};
  for (final season in seasons) {
    if (season.link == null ||
        season.link!.isEmpty ||
        season.link == parent.link) {
      throw StateError('The source returned an invalid season relationship.');
    }
    urls.add(season.link!);
  }
  final uniqueSeasons = seasons.where((season) => season.link != null).toList();
  final deduplicatedSeasons = <MManga>[];
  final seenUrls = <String>{};
  for (final season in uniqueSeasons) {
    if (seenUrls.add(season.link!)) deduplicatedSeasons.add(season);
  }
  final result = <int>[];
  await dbWriteQueue.run(
    () => database.writeTxn(() async {
      final all = (await database.mangas.where().findAll())
          .where((m) => sameAnimeSource(m, parent))
          .toList();
      final ancestors = <String>{parent.link!};
      var ancestorUrl = parent.animeParentUrl;
      while (ancestorUrl != null && ancestors.add(ancestorUrl)) {
        ancestorUrl = all
            .where((m) => m.link == ancestorUrl)
            .firstOrNull
            ?.animeParentUrl;
      }
      if (urls.any(ancestors.contains)) {
        throw StateError('The source returned a cyclic season relationship.');
      }
      for (final existing in all) {
        if (existing.animeParentUrl == parent.link &&
            !urls.contains(existing.link)) {
          existing.animeParentUrl = null;
          existing.updatedAt = DateTime.now().millisecondsSinceEpoch;
          await database.mangas.put(existing);
        }
      }
      final seen = <String>{};
      for (final (order, detail) in deduplicatedSeasons.indexed) {
        if (!seen.add(detail.link!)) continue;
        final matches = all.where((m) => m.link == detail.link).toList();
        if (matches.length > 1) {
          throw StateError('Multiple local entries match a season.');
        }
        final season =
            matches.firstOrNull ??
            Manga(
              source: parent.source,
              sourceId: parent.sourceId,
              mihonSourceId: parent.mihonSourceId,
              lang: parent.lang,
              link: detail.link,
              name: detail.name,
              author: detail.author,
              artist: detail.artist,
              genre: detail.genre,
              imageUrl: detail.imageUrl,
              description: detail.description,
              status: detail.status ?? Status.unknown,
              itemType: ItemType.anime,
            );
        season
          ..animeParentUrl = parent.link
          ..animeFetchType = detail.animeFetchType ?? 1
          ..seasonNumber = recognizeAnimeSeasonNumber(
            parent.name ?? '',
            detail.name ?? '',
            detail.seasonNumber,
          )
          ..seasonSourceOrder = order
          ..backgroundUrl = detail.backgroundUrl ?? season.backgroundUrl
          ..imageUrl = (detail.imageUrl?.isNotEmpty ?? false)
              ? detail.imageUrl
              : season.imageUrl
          ..status = switch (detail.status) {
            null || Status.unknown => season.status,
            final status => status,
          }
          ..updateSourceTitle(detail.name)
          ..updatedAt = DateTime.now().millisecondsSinceEpoch;
        result.add(await database.mangas.put(season));
      }
      await database.mangas.put(parent);
    }),
  );
  return result;
}
