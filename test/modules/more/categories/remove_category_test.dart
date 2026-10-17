import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/category.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/modules/more/categories/categories_screen.dart';

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
    directory = Directory.systemTemp.createTempSync('remove_category');
    isar = await Isar.open(
      [MangaSchema, ChapterSchema, CategorySchema],
      directory: directory.path,
      name: 'remove_category_${directory.path.hashCode}',
    );
  });

  tearDown(() async {
    await isar.close(deleteFromDisk: true);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Manga item(ItemType itemType, List<int> categories) => Manga(
    source: 'test',
    author: '',
    artist: '',
    genre: const [],
    imageUrl: '',
    lang: 'en',
    link: '/${itemType.name}',
    name: itemType.name,
    status: Status.unknown,
    description: '',
    sourceId: 1,
    itemType: itemType,
    categories: categories,
  );

  test(
    'removes membership for the tab type and closes the order gap',
    () async {
      final first = Category(name: 'a', forItemType: ItemType.manga, pos: 0);
      final removed = Category(name: 'b', forItemType: ItemType.manga, pos: 1);
      final last = Category(name: 'c', forItemType: ItemType.manga, pos: 2);
      late int mangaId;
      late int animeId;
      await isar.writeTxn(() async {
        await isar.categorys.putAll([first, removed, last]);
        mangaId = await isar.mangas.put(
          item(ItemType.manga, [first.id!, removed.id!]),
        );
        animeId = await isar.mangas.put(item(ItemType.anime, [removed.id!]));
      });

      await removeCategoryForItemType(removed, ItemType.manga);

      expect(await isar.categorys.get(removed.id!), isNull);
      expect((await isar.categorys.get(last.id!))!.pos, 1);
      expect((await isar.mangas.get(mangaId))!.categories, [first.id]);
      expect((await isar.mangas.get(animeId))!.categories, [removed.id]);
    },
  );
}
