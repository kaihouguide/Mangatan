import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/modules/manga/reader/utils/double_page_layout.dart';

void main() {
  test('regular double page groups pages from the first page', () {
    expect(doublePageViewCount(5, PageMode.doublePage), 3);
    expect(doublePageViewToActualIndex(0, 5, PageMode.doublePage), 0);
    expect(doublePageViewToActualIndex(1, 5, PageMode.doublePage), 2);
    expect(actualIndexToDoublePageView(3, PageMode.doublePage), 1);
    expect(doublePageIndexLabel(1, 5, PageMode.doublePage), '3-4');
    expect(doublePageActualIndexLabel(0, 59, PageMode.doublePage), '1-2');
    expect(doublePageActualIndexLabel(2, 59, PageMode.doublePage), '3-4');
  });

  test('cover offset keeps the first page solo and pairs from page two', () {
    expect(doublePageViewCount(5, PageMode.doublePageCover), 3);
    expect(doublePageViewToActualIndex(0, 5, PageMode.doublePageCover), 0);
    expect(doublePageViewToActualIndex(1, 5, PageMode.doublePageCover), 1);
    expect(doublePageViewToActualIndex(2, 5, PageMode.doublePageCover), 3);
    expect(actualIndexToDoublePageView(0, PageMode.doublePageCover), 0);
    expect(actualIndexToDoublePageView(1, PageMode.doublePageCover), 1);
    expect(actualIndexToDoublePageView(2, PageMode.doublePageCover), 1);
    expect(doublePageIndexLabel(0, 5, PageMode.doublePageCover), '1');
    expect(doublePageIndexLabel(1, 5, PageMode.doublePageCover), '2-3');
    expect(doublePageActualIndexLabel(0, 59, PageMode.doublePageCover), '1');
    expect(doublePageActualIndexLabel(1, 59, PageMode.doublePageCover), '2-3');
  });

  test('transition pages never consume an orphan chapter page', () {
    final transitionIndices = {5};
    expect(
      transitionAwareDoublePageSpreadIndices(
        6,
        PageMode.doublePage,
        isTransitionPage: transitionIndices.contains,
      ),
      [
        [0, 1],
        [2, 3],
        [4, null],
        [5, null],
      ],
    );
  });

  test('cover offset restarts after each chapter transition', () {
    final transitionIndices = {3};
    expect(
      transitionAwareDoublePageSpreadIndices(
        7,
        PageMode.doublePageCover,
        isTransitionPage: transitionIndices.contains,
      ),
      [
        [0, null],
        [1, 2],
        [3, null],
        [4, null],
        [5, 6],
      ],
    );
  });
}
