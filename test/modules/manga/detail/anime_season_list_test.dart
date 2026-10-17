import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/l10n/generated/app_localizations.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/download.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/manga/detail/widgets/anime_season_list.dart';

Manga _anime(String name, String link, {String? parentUrl, int order = 0}) =>
    Manga(
        source: 'source',
        author: null,
        artist: null,
        genre: const [],
        imageUrl: null,
        lang: 'ja',
        link: link,
        name: name,
        status: Status.ongoing,
        description: null,
        sourceId: 1,
        itemType: ItemType.anime,
      )
      ..animeParentUrl = parentUrl
      ..animeFetchType = parentUrl == null ? 0 : 1
      ..seasonSourceOrder = order;

void main() {
  late Manga series;
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
    dir = await Directory.systemTemp.createTemp('anime_season_list');
    isar = await Isar.open(
      [
        MangaSchema,
        ChapterSchema,
        DownloadSchema,
        SettingsSchema,
        SourceSchema,
      ],
      directory: dir.path,
      name: 'seasons_${dir.path.hashCode}',
    );
    series = _anime('Series', '/series');
    final first = _anime('First', '/s1', parentUrl: '/series');
    final second = _anime('Second', '/s2', parentUrl: '/series', order: 1);
    isar.writeTxnSync(() {
      isar.mangas.putAllSync([series, first, second]);
      for (final (index, read) in [true, false].indexed) {
        final episode = Chapter(
          name: 'Episode ${index + 1}',
          mangaId: second.id,
          isRead: read,
        );
        isar.chapters.putSync(episode);
        episode.manga.value = second;
        episode.manga.saveSync();
      }
    });
  });

  tearDown(() async {
    await isar.close(deleteFromDisk: true);
    await dir.delete(recursive: true);
  });

  // Every Isar call completes on a real isolate, so let real time pass and
  // pump between each step of the widget's reload chain.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('shows seasons newest first and follows episode progress', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(child: AnimeSeasonList(anime: series)),
          ),
        ),
      ),
    );
    await settle(tester);

    expect(find.text('2 seasons'), findsOneWidget);
    // Anikku's default: source order, descending.
    expect(
      tester.getTopLeft(find.text('Second').first).dx,
      lessThan(tester.getTopLeft(find.text('First').first).dx),
    );
    // One unwatched episode badge on the second season.
    expect(find.text('1'), findsOneWidget);

    await tester.runAsync(() async {
      final unwatched = await isar.chapters
          .filter()
          .isReadEqualTo(false)
          .findFirst();
      await isar.writeTxn(() async {
        await isar.chapters.put(unwatched!..isRead = true);
      });
    });
    await settle(tester);

    expect(find.text('1'), findsNothing);

    // Cancel the widget's Isar watchers before the database closes.
    await tester.pumpWidget(const SizedBox());
  });
}
