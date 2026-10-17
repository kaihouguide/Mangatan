import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/services/anime_seasons.dart';

Manga _season(
  String name, {
  int order = 0,
  double? number,
  Status status = Status.ongoing,
  bool local = false,
}) =>
    Manga(
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
        sourceId: 1,
        itemType: ItemType.anime,
        isLocalArchive: local,
      )
      ..seasonSourceOrder = order
      ..seasonNumber = number;

List<String> _names(List<AnimeSeasonEntry> entries) => [
  for (final entry in entries) entry.season.name!,
];

void main() {
  group('flags', () {
    test('an anime never configured gets the Anikku defaults', () {
      final flags = AnimeSeasonFlags.effective(null);
      expect(AnimeSeasonFlags.sortMode(flags), AnimeSeasonFlags.sortSource);
      expect(AnimeSeasonFlags.isAscending(flags), isFalse);
      expect(
        AnimeSeasonFlags.displayMode(flags),
        AnimeSeasonDisplayMode.compactGrid,
      );
      expect(
        AnimeSeasonFlags.isSet(flags, AnimeSeasonFlags.overlayUnseenMask),
        isTrue,
      );
      expect(
        AnimeSeasonFlags.isSet(flags, AnimeSeasonFlags.overlayContinueMask),
        isTrue,
      );
      expect(AnimeSeasonFlags.effective(0), 0);
    });

    test('a new sort starts ascending and the same sort flips', () {
      var flags = AnimeSeasonFlags.defaults;
      flags = AnimeSeasonFlags.withSortOrFlip(
        flags,
        AnimeSeasonFlags.sortSeasonNumber,
      );
      expect(
        AnimeSeasonFlags.sortMode(flags),
        AnimeSeasonFlags.sortSeasonNumber,
      );
      expect(AnimeSeasonFlags.isAscending(flags), isTrue);

      flags = AnimeSeasonFlags.withSortOrFlip(
        flags,
        AnimeSeasonFlags.sortSeasonNumber,
      );
      expect(AnimeSeasonFlags.isAscending(flags), isFalse);
      // Other settings are untouched.
      expect(
        AnimeSeasonFlags.isSet(flags, AnimeSeasonFlags.overlayUnseenMask),
        isTrue,
      );
    });

    test('filters cycle through any, include and exclude independently', () {
      var flags = 0;
      flags = AnimeSeasonFlags.withFilter(
        flags,
        AnimeSeasonFlags.showUnseen,
        AnimeSeasonFlags.showSeen,
        AnimeSeasonFilter.include,
      );
      flags = AnimeSeasonFlags.withFilter(
        flags,
        AnimeSeasonFlags.showDownloaded,
        AnimeSeasonFlags.showNotDownloaded,
        AnimeSeasonFilter.exclude,
      );
      expect(
        AnimeSeasonFlags.filter(
          flags,
          AnimeSeasonFlags.showUnseen,
          AnimeSeasonFlags.showSeen,
        ),
        AnimeSeasonFilter.include,
      );
      expect(
        AnimeSeasonFlags.filter(
          flags,
          AnimeSeasonFlags.showDownloaded,
          AnimeSeasonFlags.showNotDownloaded,
        ),
        AnimeSeasonFilter.exclude,
      );
      expect(AnimeSeasonFlags.hasActiveFilters(flags), isTrue);

      flags = AnimeSeasonFlags.withFilter(
        flags,
        AnimeSeasonFlags.showUnseen,
        AnimeSeasonFlags.showSeen,
        AnimeSeasonFilter.any,
      );
      flags = AnimeSeasonFlags.withFilter(
        flags,
        AnimeSeasonFlags.showDownloaded,
        AnimeSeasonFlags.showNotDownloaded,
        AnimeSeasonFilter.any,
      );
      expect(AnimeSeasonFlags.hasActiveFilters(flags), isFalse);
    });

    test('display mode and grid size use the Anikku bit layout', () {
      var flags = AnimeSeasonFlags.withDisplayMode(
        0,
        AnimeSeasonDisplayMode.list,
      );
      expect(flags, 0x00030000);
      flags = AnimeSeasonFlags.withGridSize(flags, 4);
      expect(AnimeSeasonFlags.gridSize(flags), 4);
      expect(AnimeSeasonFlags.displayMode(flags), AnimeSeasonDisplayMode.list);
      expect(
        AnimeSeasonFlags.gridSize(AnimeSeasonFlags.withGridSize(0, 99)),
        15,
      );
    });
  });

  group('filter and sort', () {
    final entries = <AnimeSeasonEntry>[
      (
        season: _season(
          'Season 1',
          order: 0,
          number: 1,
          status: Status.completed,
        ),
        stats: const AnimeSeasonStats(totalCount: 12, seenCount: 12),
      ),
      (
        season: _season('Season 2', order: 1, number: 2),
        stats: const AnimeSeasonStats(
          totalCount: 12,
          seenCount: 3,
          downloadCount: 2,
        ),
      ),
      (
        season: _season('Movie', order: 2, number: 1.5, local: true),
        stats: const AnimeSeasonStats(totalCount: 1),
      ),
    ];

    test('the default shows the newest source entry first', () {
      expect(
        _names(filterAndSortAnimeSeasons(entries, AnimeSeasonFlags.defaults)),
        ['Movie', 'Season 2', 'Season 1'],
      );
    });

    test('season number ascending interleaves specials', () {
      final flags = AnimeSeasonFlags.withSortOrFlip(
        AnimeSeasonFlags.defaults,
        AnimeSeasonFlags.sortSeasonNumber,
      );
      expect(_names(filterAndSortAnimeSeasons(entries, flags)), [
        'Season 1',
        'Movie',
        'Season 2',
      ]);
    });

    test('completed follows the source status, not watch progress', () {
      final flags = AnimeSeasonFlags.withFilter(
        AnimeSeasonFlags.defaults,
        AnimeSeasonFlags.showCompleted,
        AnimeSeasonFlags.showNotCompleted,
        AnimeSeasonFilter.include,
      );
      expect(_names(filterAndSortAnimeSeasons(entries, flags)), ['Season 1']);
    });

    test('downloaded includes local seasons', () {
      final flags = AnimeSeasonFlags.withFilter(
        AnimeSeasonFlags.defaults,
        AnimeSeasonFlags.showDownloaded,
        AnimeSeasonFlags.showNotDownloaded,
        AnimeSeasonFilter.include,
      );
      expect(_names(filterAndSortAnimeSeasons(entries, flags)), [
        'Movie',
        'Season 2',
      ]);
    });

    test('unwatched excludes fully watched seasons', () {
      final flags = AnimeSeasonFlags.withFilter(
        AnimeSeasonFlags.defaults,
        AnimeSeasonFlags.showUnseen,
        AnimeSeasonFlags.showSeen,
        AnimeSeasonFilter.include,
      );
      expect(_names(filterAndSortAnimeSeasons(entries, flags)), [
        'Movie',
        'Season 2',
      ]);
    });

    test('ties fall back to the title', () {
      final tied = <AnimeSeasonEntry>[
        (season: _season('b', number: 1), stats: const AnimeSeasonStats()),
        (season: _season('A', number: 1), stats: const AnimeSeasonStats()),
      ];
      final flags = AnimeSeasonFlags.withSortOrFlip(
        0,
        AnimeSeasonFlags.sortSeasonNumber,
      );
      expect(_names(filterAndSortAnimeSeasons(tied, flags)), ['A', 'b']);
    });
  });

  test('season number labels drop a whole number decimal', () {
    expect(animeSeasonNumberLabel(2), '2');
    expect(animeSeasonNumberLabel(1.5), '1.5');
    expect(animeSeasonNumberLabel(-1), '?');
    expect(animeSeasonNumberLabel(null), '?');
  });
}
