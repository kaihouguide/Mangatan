import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/manga/reader/providers/push_router.dart';

void main() {
  late Directory dir;

  setUp(() async {
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    try {
      await Isar.initializeIsarCore(download: true);
    } finally {
      HttpOverrides.global = overrides;
    }
    dir = await Directory.systemTemp.createTemp('push_router');
    isar = await Isar.open(
      [MangaSchema, ChapterSchema, SourceSchema],
      directory: dir.path,
      name: 'push_router_${dir.path.hashCode}',
    );
  });

  tearDown(() async {
    await isar.close(deleteFromDisk: true);
    await dir.delete(recursive: true);
  });

  testWidgets('an episode opens after its source was renamed', (tester) async {
    // Jellyfin names its sources after a custom label, and that label is not
    // always applied yet when the name is read. Entries browsed meanwhile keep
    // the default name, but the source ID is the same.
    late Chapter episode;
    await tester.runAsync(() async {
      await isar.writeTxn(() async {
        await isar.sources.put(
          Source(
            id: 7,
            name: 'Jellyfin (Anime)',
            lang: 'all',
            isAdded: true,
            sourceCode: 'apk',
            itemType: ItemType.anime,
          ),
        );
        final manga = Manga(
          name: 'Season 1',
          source: 'Jellyfin (1)',
          sourceId: 7,
          lang: 'all',
          link: 'https://example.test/season',
          imageUrl: '',
          genre: const [],
          author: '',
          artist: '',
          status: Status.unknown,
          description: '',
          isLocalArchive: false,
          itemType: ItemType.anime,
        );
        await isar.mangas.put(manga);
        episode = Chapter(name: 'Episode 1', url: '/episode', mangaId: manga.id)
          ..manga.value = manga;
        await isar.chapters.put(episode);
        await episode.manga.save();
      });
    });

    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => TextButton(
            onPressed: () =>
                pushMangaReaderView(context: context, chapter: episode),
            child: const Text('play'),
          ),
        ),
        GoRoute(
          path: '/animePlayerView',
          builder: (_, state) => Text('player ${state.extra}'),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));

    await tester.tap(find.text('play'));
    await tester.pumpAndSettle();

    expect(find.text('player ${episode.id}'), findsOneWidget);
  });
}
