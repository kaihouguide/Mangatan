import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mangayomi/services/youtube/youtube_preferences.dart';

void main() {
  test('a search before storage is ready is skipped, not a crash', () async {
    // Runs first: markStorageReady has not been called in this isolate yet.
    await YouTubePreferences.rememberSearch('anime');
    expect(await YouTubePreferences.searchHistory(), isEmpty);
    expect(await YouTubePreferences.preferredQuality(), '1080p');
  });

  group('with storage', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('youtube_prefs');
      Hive.init(directory.path);
      YouTubePreferences.markStorageReady();
    });

    tearDown(() async {
      await Hive.deleteFromDisk();
      await Hive.close();
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    test('keeps the newest ten searches, newest first', () async {
      for (var i = 0; i < 12; i++) {
        await YouTubePreferences.rememberSearch('query $i');
      }

      final history = await YouTubePreferences.searchHistory();
      expect(history, hasLength(10));
      expect(history.first, 'query 11');
      expect(history.last, 'query 2');
    });

    test('a repeated search moves to the top regardless of case', () async {
      await YouTubePreferences.rememberSearch('Anime');
      await YouTubePreferences.rememberSearch('drama');
      await YouTubePreferences.rememberSearch('  anime ');

      expect(await YouTubePreferences.searchHistory(), ['anime', 'drama']);
    });

    test('blank searches are ignored and history can be cleared', () async {
      await YouTubePreferences.rememberSearch('   ');
      expect(await YouTubePreferences.searchHistory(), isEmpty);

      await YouTubePreferences.rememberSearch('anime');
      await YouTubePreferences.clearSearchHistory();
      expect(await YouTubePreferences.searchHistory(), isEmpty);
    });

    test('stores quality and channel preferences', () async {
      await YouTubePreferences.setPreferredQuality('720p');
      await YouTubePreferences.setAutoAddChannels(true);

      expect(await YouTubePreferences.preferredQuality(), '720p');
      expect(await YouTubePreferences.autoAddChannels(), isTrue);
    });
  });
}
