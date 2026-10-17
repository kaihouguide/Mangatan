import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mangayomi/services/mining/dictionary_profile.dart';
import 'package:mangayomi/services/mining/mining_models.dart';
import 'package:mangayomi/services/statistics/anki_stats_recorder.dart';
import 'package:mangayomi/services/statistics/immersion_stats_storage.dart';

void main() {
  late Directory tempDirectory;
  const profile = DictionaryProfile(id: 'ja', name: 'Japanese');

  setUpAll(() async {
    tempDirectory = await Directory.systemTemp.createTemp('mangatan-anki-');
    Hive.init(tempDirectory.path);
  });

  setUp(() async {
    if (Hive.isBoxOpen(ImmersionStatsStorage.boxName)) {
      await Hive.box<dynamic>(ImmersionStatsStorage.boxName).close();
    }
    await Hive.deleteBoxFromDisk(ImmersionStatsStorage.boxName);
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDirectory.delete(recursive: true);
  });

  test('cards are bucketed and attributed the way Chimahon does', () async {
    await AnkiStatsRecorder.recordCard(
      context: const MiningContext(
        mediaType: MiningMediaType.novel,
        novelId: 'book-1',
      ),
      profile: profile,
    );
    // Chimahon only separates manga; anime cards count as novel cards.
    await AnkiStatsRecorder.recordCard(
      context: const MiningContext(mediaType: MiningMediaType.anime),
      profile: profile,
    );

    final stats = await ImmersionStatsStorage.loadAnkiStats();
    final book = stats.singleWhere((entry) => entry.titleId == 'book-1');
    expect(book.novelCards, 1);
    expect(book.mangaCards, 0);
    expect(book.profileId, 'ja');
    final untitled = stats.singleWhere((entry) => entry.titleId == null);
    expect(untitled.novelCards, 1);
  });
}
