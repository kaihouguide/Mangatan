import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/modules/widgets/manga_image_card_widget.dart';

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
    dir = await Directory.systemTemp.createTemp('resolve_browsed_manga');
    isar = await Isar.open(
      [MangaSchema, ChapterSchema],
      directory: dir.path,
      name: 'resolve_browsed_${dir.path.hashCode}',
    );
  });

  tearDown(() async {
    await isar.close(deleteFromDisk: true);
    await dir.delete(recursive: true);
  });

  Manga browsed(String source, int? sourceId) => Manga(
    name: 'Re:Zero',
    source: source,
    sourceId: sourceId,
    lang: 'all',
    link: 'https://example.test/series',
    imageUrl: '',
    genre: const [],
    author: '',
    artist: '',
    status: Status.unknown,
    description: '',
    itemType: ItemType.anime,
  );

  test('a renamed source reuses the stored entry', () async {
    // Jellyfin names its sources after a custom label that is not always
    // applied yet, so the same source can be browsed under two names.
    final stored = await resolveBrowsedMangaId(
      browsed('Jellyfin (Anime)', 7),
      'all',
      7,
    );

    final again = await resolveBrowsedMangaId(
      browsed('Jellyfin (1)', 7),
      'all',
      7,
    );

    expect(again, stored);
    expect(await isar.mangas.count(), 1);
  });

  test('the same title from another source stays separate', () async {
    final first = await resolveBrowsedMangaId(browsed('Source A', 7), 'all', 7);
    final second = await resolveBrowsedMangaId(
      browsed('Source B', 8),
      'all',
      8,
    );

    expect(second, isNot(first));
    expect(await isar.mangas.count(), 2);
  });
}
