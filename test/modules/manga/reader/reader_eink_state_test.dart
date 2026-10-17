import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mangayomi/modules/manga/reader/reader_eink_state.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';

void main() {
  late Directory tempDirectory;

  setUpAll(() async {
    tempDirectory = await Directory.systemTemp.createTemp('mangatan-eink-');
    Hive.init(tempDirectory.path);
  });

  setUp(() async {
    if (Hive.isBoxOpen('mining_preferences')) {
      await Hive.box<dynamic>('mining_preferences').close();
    }
    await Hive.deleteBoxFromDisk('mining_preferences');
    ReaderEInkState.resetForTesting();
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDirectory.delete(recursive: true);
  });

  test('loads the stored mode once', () async {
    await MiningPreferences.setReaderEInkMode(true);
    await ReaderEInkState.initialize();
    expect(ReaderEInkState.enabled.value, isTrue);
  });

  test('a toggle during the initial load is not overwritten', () async {
    await MiningPreferences.setReaderEInkMode(true);
    final loading = ReaderEInkState.initialize();
    await ReaderEInkState.setEnabled(false);
    await loading;

    expect(ReaderEInkState.enabled.value, isFalse);
    expect(await MiningPreferences.getReaderEInkMode(), isFalse);
  });
}
