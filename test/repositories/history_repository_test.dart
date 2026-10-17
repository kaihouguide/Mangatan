import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/history.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/repositories/history_repository.dart';

void main() {
  late Directory dir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    try {
      await Isar.initializeIsarCore(download: true);
    } finally {
      HttpOverrides.global = overrides;
    }
    dir = await Directory.systemTemp.createTemp('history_repository');
    isar = await Isar.open(
      [HistorySchema, ChapterSchema, MangaSchema],
      directory: dir.path,
      name: 'history_${dir.path.hashCode}',
    );
  });

  tearDown(() async {
    await isar.close(deleteFromDisk: true);
    await dir.delete(recursive: true);
  });

  History entry(int mangaId, int chapterId) => History(
    itemType: ItemType.anime,
    chapterId: chapterId,
    mangaId: mangaId,
    date: '0',
  );

  test(
    'per-title history ignores other titles open at the same time',
    () async {
      // A season page and its series page both watch history; each must only
      // see its own entries, or the resume button follows the wrong title.
      final seasonHistory = historyRepository.watchByMangaId(1);
      final emissions = <List<int?>>[];
      final subscription = seasonHistory.listen(
        (entries) => emissions.add([for (final e in entries) e.chapterId]),
      );
      addTearDown(subscription.cancel);

      await isar.writeTxn(() async {
        await isar.historys.putAll([entry(1, 10), entry(2, 20)]);
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(emissions.first, isEmpty);
      expect(emissions.last, [10]);
    },
  );
}
