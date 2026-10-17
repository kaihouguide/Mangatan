import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:mangayomi/modules/anime/youtube/youtube_browser_screen.dart';
import 'package:mangayomi/services/youtube/youtube_service.dart';

void main() {
  test('uses Chimahon-compatible YouTube quality choices', () {
    expect(youtubePreferredQualities, const [
      '2160p',
      '1440p',
      '1080p',
      '720p',
      '480p',
      '360p',
    ]);
  });

  test('distinguishes playable videos from browsable collections', () {
    const video = YouTubeBrowseItem(
      id: 'video',
      type: YouTubeBrowseItemType.video,
      title: 'Video',
      url: 'https://www.youtube.com/watch?v=video',
    );
    const channel = YouTubeBrowseItem(
      id: 'channel',
      type: YouTubeBrowseItemType.channel,
      title: 'Channel',
      url: 'https://www.youtube.com/channel/channel',
    );

    expect(video.isVideo, isTrue);
    expect(channel.isVideo, isFalse);
  });

  test('wraps YouTube library writes in explicit Isar transactions', () {
    final source = File('lib/services/youtube/youtube_service.dart')
        .readAsStringSync();

    // Async transactions: a synchronous one throws while a sync import holds
    // an async write transaction.
    expect(source, contains('() => isar.mangas.put(createdManga)'));
    expect(source, contains('chapterRepository.writeTransactionAsync('));
    expect(source, contains('await isar.chapters.put(createdChapter)'));
    expect(source, contains('await createdChapter.manga.save()'));
  });

  test('prefers the cross-platform NewPipe bridge before Dart extraction', () {
    final youtubeSource = File('lib/services/youtube/youtube_service.dart')
        .readAsStringSync();
    final bridgeSource = File('lib/services/m_extension_server.dart')
        .readAsStringSync();

    expect(youtubeSource, contains('prepareYouTubeResolverBridge()'));
    expect(youtubeSource, contains("'\$baseUrl/youtube/resolve'"));
    expect(
      youtubeSource,
      contains('final bridgeVideo = await _resolveWithBridge'),
    );
    expect(bridgeSource, contains("capabilities['youtubeResolver'] == true"));
    expect(
      bridgeSource,
      contains('Future<String?> prepareYouTubeResolverBridge()'),
    );
  });

  test('uses safe defaults before deferred Hive startup completes', () async {
    expect(await YouTubePreferences.preferredQuality(), '1080p');
    expect(await YouTubePreferences.autoAddChannels(), isFalse);
    expect(await YouTubePreferences.searchHistory(), isEmpty);
  });

  test('recognizes every YouTube page shape intercepted by Chimahon', () {
    const id = 'dQw4w9WgXcQ';
    expect(directYouTubeVideoId('https://www.youtube.com/watch?v=$id&t=4'), id);
    expect(directYouTubeVideoId('https://m.youtube.com/shorts/$id'), id);
    expect(directYouTubeVideoId('https://youtube.com/live/$id'), id);
    expect(directYouTubeVideoId('https://youtube-nocookie.com/embed/$id'), id);
    expect(directYouTubeVideoId('https://youtu.be/$id'), id);
    expect(directYouTubeVideoId('https://youtube.com/@channel'), isNull);
    expect(directYouTubeVideoId('https://notyoutube.com/watch?v=$id'), isNull);
  });

  test('browser script intercepts clicks and YouTube SPA history changes', () {
    expect(youtubeInterceptScript, contains("addEventListener('click'"));
    expect(youtubeInterceptScript, contains('history.pushState'));
    expect(youtubeInterceptScript, contains('history.replaceState'));
    expect(youtubeInterceptScript, contains("addEventListener('popstate'"));
    expect(youtubeInterceptScript, contains('openYouTubeVideo'));
    expect(youtubeInterceptScript, contains('setTimeout(fallback, 350)'));
    expect(youtubeInterceptScript, contains('window.location.assign(href)'));
    expect(youtubeInterceptScript, contains('result === true'));
  });

  test('keeps YouTube embedded on Windows', () {
    expect(usesExternalYouTubeWindow(TargetPlatform.windows), isFalse);
    expect(usesExternalYouTubeWindow(TargetPlatform.linux), isTrue);
  });

  test('persists YouTube preferences after Hive startup', () async {
    final directory = await Directory.systemTemp.createTemp(
      'mangatan-youtube-preferences-',
    );
    Hive.init(directory.path);
    YouTubePreferences.markStorageReady();
    try {
      await YouTubePreferences.setPreferredQuality('720p');
      await YouTubePreferences.setAutoAddChannels(true);
      await YouTubePreferences.rememberSearch('Japanese listening');

      expect(await YouTubePreferences.preferredQuality(), '720p');
      expect(await YouTubePreferences.autoAddChannels(), isTrue);
      expect(await YouTubePreferences.searchHistory(), ['Japanese listening']);
    } finally {
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });
}
