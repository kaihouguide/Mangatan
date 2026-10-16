import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/services/epub_chapter_metadata.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/repositories/manga_repository.dart';
part 'isar_providers.g.dart';

@riverpod
Stream<Manga?> getMangaDetailStream(Ref ref, {required int mangaId}) async* {
  yield* mangaRepository.watchById(mangaId);
}

@riverpod
Stream<List<Chapter>> getChaptersStream(
  Ref ref, {
  required int mangaId,
}) async* {
  final manga = await isar.mangas.get(mangaId);
  if (manga != null) {
    await repairLocalEpubChapterMetadata(manga);
  }
  yield* isar.chapters
      .filter()
      .mangaIdEqualTo(mangaId)
      .watch(fireImmediately: true);
}
