import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/eval/model/m_manga.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/manga/detail/providers/update_manga_detail_providers.dart';
import 'package:mangayomi/services/get_detail.dart';

void main() {
  late Directory directory;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    try {
      await Isar.initializeIsarCore(download: true);
    } finally {
      HttpOverrides.global = overrides;
    }
  });

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('update_manga_detail');
    isar = await Isar.open(
      [MangaSchema, ChapterSchema, SourceSchema],
      directory: directory.path,
      name: 'update_manga_detail_${directory.path.hashCode}',
    );
  });

  tearDown(() async {
    await isar.close(deleteFromDisk: true);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('a slow detail request still saves its seasons', () async {
    const seriesUrl = 'http://192.0.2.10:8096/Users/u/Items/s#series';
    const seasonUrl = 'http://192.0.2.10:8096/Users/u/Items/a#season,s';
    final source = Source(
      name: 'Jellyfin',
      lang: 'all',
      sourceCode: 'apk',
      itemType: ItemType.anime,
    )..isAdded = true;
    late int animeId;
    await isar.writeTxn(() async {
      await isar.sources.put(source);
      animeId = await isar.mangas.put(
        Manga(
          source: 'Jellyfin',
          author: '',
          artist: '',
          genre: const [],
          imageUrl: '',
          lang: 'all',
          link: seriesUrl,
          name: 'Show',
          status: Status.unknown,
          description: '',
          sourceId: source.id,
          itemType: ItemType.anime,
        ),
      );
    });

    final container = ProviderContainer(
      overrides: [
        getDetailProvider.overrideWith((ref, args) async {
          // Longer than Riverpod waits before disposing an unlistened
          // provider, as with a real extension-server round trip.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return MManga(
            name: 'Show',
            link: args.url,
            animeFetchType: 0,
            chapters: [],
            seasons: [
              MManga(
                name: 'Season 1',
                link: seasonUrl,
                animeFetchType: 1,
                seasonNumber: 1,
                chapters: [],
              ),
            ],
          );
        }),
      ],
    );
    addTearDown(container.dispose);

    // The detail screen reads the provider without listening to it.
    await container.read(
      updateMangaDetailProvider(
        mangaId: animeId,
        isInit: true,
        showToast: false,
      ).future,
    );

    final anime = await isar.mangas.get(animeId);
    expect(anime!.hasSeasons, isTrue);
    final season = await isar.mangas
        .filter()
        .linkEqualTo(seasonUrl)
        .findFirst();
    expect(season?.animeParentUrl, seriesUrl);
  });
}
