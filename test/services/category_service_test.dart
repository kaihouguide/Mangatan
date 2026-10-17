import 'package:mangayomi/models/category.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/services/category_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes duplicate names and orders categories contiguously', () {
    final categories = [
      Category(
        name: ' Reading ',
        forItemType: ItemType.manga,
        pos: 7,
      ),
      Category(
        name: 'watching',
        forItemType: ItemType.anime,
        pos: 1,
      ),
      Category(
        name: 'Study',
        forItemType: ItemType.novel,
        pos: 3,
      ),
    ];

    expect(
      CategoryService.hasDuplicateName(categories, 'reading'),
      isTrue,
    );
    expect(
      CategoryService.hasDuplicateName(categories, 'Notes'),
      isFalse,
    );

    final ordered = CategoryService.ordered(categories);
    expect(ordered.first.name, 'watching');

    final normalized = CategoryService.normalizePositions(categories);
    expect(normalized.map((category) => category.pos), [0, 1, 2]);
  });

  test('membership state treats mixed selections distinctly', () {
    final mangaA = Manga(
      source: '',
      author: '',
      artist: '',
      genre: const [],
      imageUrl: '',
      lang: '',
      link: '',
      name: 'A',
      status: Status.ongoing,
      description: '',
      sourceId: 1,
      itemType: ItemType.manga,
      categories: [1],
    );
    final mangaB = Manga(
      source: '',
      author: '',
      artist: '',
      genre: const [],
      imageUrl: '',
      lang: '',
      link: '',
      name: 'B',
      status: Status.ongoing,
      description: '',
      sourceId: 2,
      itemType: ItemType.manga,
      categories: const [],
    );

    expect(CategoryService.membershipState([mangaA], 1), 1);
    expect(CategoryService.membershipState([mangaB], 1), 0);
    expect(CategoryService.membershipState([mangaA, mangaB], 1), 2);
  });
}
