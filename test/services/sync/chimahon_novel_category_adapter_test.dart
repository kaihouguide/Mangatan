import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/models/category.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/services/sync/chimahon_novel_category_adapter.dart';

void main() {
  const adapter = ChimahonNovelCategoryAdapter();

  Manga novel({required int id, List<int>? categories}) => Manga(
    id: id,
    source: 'Local',
    sourceId: null,
    author: null,
    artist: null,
    genre: const [],
    imageUrl: null,
    lang: 'ja',
    link: '/book-$id',
    name: 'Book $id',
    status: Status.unknown,
    description: null,
    itemType: ItemType.novel,
    isLocalArchive: true,
    categories: categories,
  );

  test('uses normalized names instead of local integer IDs on the wire', () {
    final projection = adapter.buildExportProjection(
      categories: [
        Category(id: 17, name: 'Reading', forItemType: ItemType.novel, pos: 3),
        Category(
          id: 18,
          name: ' reading ',
          forItemType: ItemType.novel,
          pos: 9,
        ),
        Category(id: 19, name: '   ', forItemType: ItemType.novel, pos: 10),
        Category(
          id: 20,
          name: 'Manga category',
          forItemType: ItemType.manga,
          pos: 1,
        ),
      ],
      mangas: [
        novel(id: 1, categories: [18]),
        novel(id: 2, categories: [999]),
      ],
    );

    final readingId = adapter.stableId('READING');
    expect(readingId, adapter.stableId(' reading '));
    expect(readingId, isNot(anyOf('17', '18')));
    expect(projection.categories.map((category) => category.id), [readingId]);
    expect(projection.categories.last.name, 'Reading');
    expect(projection.categories.last.order.toInt(), 3);
    expect(projection.categories.last.hasFlags(), isFalse);
    expect(projection.categoryIdsByMangaId[1], [readingId]);
    expect(projection.categoryIdsByMangaId[2], [
      ChimahonNovelCategoryAdapter.uncategorizedId,
    ]);
  });

  test('normalizes uncategorized membership like Chimahon', () {
    expect(adapter.normalizeIds(const ['', 'default', 'default']), [
      ChimahonNovelCategoryAdapter.uncategorizedId,
    ]);
    expect(adapter.normalizeIds(const ['default', 'reading', 'reading']), [
      'reading',
    ]);
  });
}
