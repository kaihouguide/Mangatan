import 'package:mangayomi/models/settings.dart';

int doublePageViewCount(int pageCount, PageMode pageMode) {
  if (pageCount <= 0) return 0;
  if (!pageMode.isDoublePage) return pageCount;
  if (!pageMode.usesCoverOffset) return (pageCount / 2).ceil();
  if (pageCount == 1) return 1;
  return 1 + ((pageCount - 1) / 2).ceil();
}

int doublePageViewToActualIndex(
  int viewIndex,
  int pageCount,
  PageMode pageMode,
) {
  if (pageCount <= 0) return 0;
  if (!pageMode.isDoublePage) {
    return viewIndex.clamp(0, pageCount - 1).toInt();
  }
  final actualIndex = pageMode.usesCoverOffset
      ? (viewIndex <= 0 ? 0 : viewIndex * 2 - 1)
      : viewIndex * 2;
  return actualIndex.clamp(0, pageCount - 1).toInt();
}

int actualIndexToDoublePageView(int actualIndex, PageMode pageMode) {
  if (!pageMode.isDoublePage) return actualIndex;
  if (!pageMode.usesCoverOffset) return actualIndex ~/ 2;
  if (actualIndex <= 0) return 0;
  return ((actualIndex - 1) ~/ 2) + 1;
}

List<List<int?>> transitionAwareDoublePageSpreadIndices(
  int pageCount,
  PageMode pageMode, {
  required bool Function(int index) isTransitionPage,
}) {
  if (pageCount <= 0) return const [];
  if (!pageMode.isDoublePage) {
    return List.generate(pageCount, (index) => <int?>[index]);
  }

  final spreads = <List<int?>>[];
  var index = 0;
  while (index < pageCount) {
    if (isTransitionPage(index)) {
      spreads.add(<int?>[index, null]);
      index++;
      continue;
    }

    final chapterStart = index;
    var chapterEnd = chapterStart;
    while (chapterEnd < pageCount && !isTransitionPage(chapterEnd)) {
      chapterEnd++;
    }

    if (pageMode.usesCoverOffset && index < chapterEnd) {
      spreads.add(<int?>[index, null]);
      index++;
    }
    while (index < chapterEnd) {
      final secondIndex = index + 1;
      spreads.add(<int?>[index, secondIndex < chapterEnd ? secondIndex : null]);
      index += 2;
    }
    index = chapterEnd;
  }
  return spreads;
}

String doublePageIndexLabel(int viewIndex, int totalPages, PageMode pageMode) {
  if (!pageMode.isDoublePage) return '${viewIndex + 1}';
  if (totalPages <= 0) return '0';
  final first = doublePageViewToActualIndex(viewIndex, totalPages, pageMode);
  final second = first + 1;
  if (pageMode.usesCoverOffset && viewIndex <= 0) return '1';
  if (second >= totalPages) return '${first + 1}';
  return '${first + 1}-${second + 1}';
}

String doublePageActualIndexLabel(
  int actualIndex,
  int totalPages,
  PageMode pageMode,
) {
  final viewIndex = actualIndexToDoublePageView(actualIndex, pageMode);
  return doublePageIndexLabel(viewIndex, totalPages, pageMode);
}
