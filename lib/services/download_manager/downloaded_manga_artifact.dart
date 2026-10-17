import 'dart:io';

import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/utils/extensions/string_extensions.dart';
import 'package:path/path.dart' as p;

String downloadedMangaChapterBaseName(Chapter chapter) {
  return (chapter.name ?? '').replaceForbiddenCharacters(' ');
}

File downloadedMangaChapterCbz(Directory mangaDirectory, Chapter chapter) {
  return File(
    p.join(
      mangaDirectory.path,
      '${downloadedMangaChapterBaseName(chapter)}.cbz',
    ),
  );
}
