import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
part 'isar_providers.g.dart';

@riverpod
Stream<List<Manga>> getAllMangaStream(
  Ref ref, {
  required int? categoryId,
  required ItemType itemType,
}) async* {
  yield* categoryId == null
      ? isar.mangas
            .filter()
            .idIsNotNull()
            .group(
              (query) => query
                  .favoriteEqualTo(true)
                  .or()
                  .hasLocalChapterOverlayEqualTo(true),
            )
            .and()
            .itemTypeEqualTo(itemType)
            .watch(fireImmediately: true)
      : isar.mangas
            .filter()
            .idIsNotNull()
            .group(
              (query) => query
                  .favoriteEqualTo(true)
                  .or()
                  .hasLocalChapterOverlayEqualTo(true),
            )
            .categoriesIsNotEmpty()
            .categoriesElementEqualTo(categoryId)
            .and()
            .itemTypeEqualTo(itemType)
            .watch(fireImmediately: true);
}

@riverpod
Stream<List<Manga>> getAllMangaWithoutCategoriesStream(
  Ref ref, {
  required ItemType itemType,
}) async* {
  yield* isar.mangas
      .filter()
      .idIsNotNull()
      .group(
        (query) => query
            .favoriteEqualTo(true)
            .or()
            .hasLocalChapterOverlayEqualTo(true),
      )
      .categoriesIsEmpty()
      .and()
      .itemTypeEqualTo(itemType)
      .or()
      .idIsNotNull()
      .categoriesIsNull()
      .group(
        (query) => query
            .favoriteEqualTo(true)
            .or()
            .hasLocalChapterOverlayEqualTo(true),
      )
      .and()
      .itemTypeEqualTo(itemType)
      .watch(fireImmediately: true);
}

@riverpod
Stream<List<Settings>> getSettingsStream(Ref ref) async* {
  yield* isar.settings
      .filter()
      .idIsNotNull()
      .and()
      .idEqualTo(227)
      .watch(fireImmediately: true);
}
