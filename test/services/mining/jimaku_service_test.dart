import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangayomi/services/mining/jimaku_service.dart';

void main() {
  test(
    'uses Chimahon exact series title instead of combining stream metadata',
    () {
      final guess = buildChimahonJimakuGuess(
        animeTitle: 'Psycho-Pass',
        mediaTitle: ': Rearing Conventions,',
        videoTitle: ': Rearing Conventions,',
        videoUrl: 'https://stream.example/video/master.m3u8',
        episodeNumber: 1,
      );

      expect(guess.title, 'Psycho-Pass');
      expect(guess.episode, 1);
      expect(guess.displayName, 'Psycho-Pass episode 1');
    },
  );

  test(
    'searches both Chimahon entry categories with the raw API key',
    () async {
      final requests = <http.Request>[];
      final service = JimakuSubtitleService(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode([
              {
                'id': request.url.queryParameters['anime'] == 'true' ? 1 : 2,
                'name': 'Psycho-Pass',
              },
            ]),
            200,
          );
        }),
      );

      final entries = await service.searchEntries(
        apiKey: '  jimaku-key  ',
        query: 'Psycho-Pass',
      );

      expect(entries.map((entry) => entry.id), [1, 2]);
      expect(requests, hasLength(2));
      expect(requests.map((request) => request.url.queryParameters['anime']), [
        'true',
        'false',
      ]);
      expect(
        requests.every(
          (request) => request.url.queryParameters['query'] == 'Psycho-Pass',
        ),
        isTrue,
      );
      expect(
        requests.every(
          (request) => request.headers['Authorization'] == 'jimaku-key',
        ),
        isTrue,
      );
    },
  );

  test('sends the API key only to Jimaku file links', () async {
    final keys = <String, String?>{};
    final client = MockClient((request) async {
      keys[request.url.toString()] = request.headers['Authorization'];
      return http.Response('1\n00:00:01,000 --> 00:00:02,000\nhi\n', 200);
    });
    final directory = await Directory.systemTemp.createTemp('jimaku_key');
    addTearDown(() => directory.delete(recursive: true));
    final service = JimakuSubtitleService(client: client);

    for (final url in [
      'https://jimaku.cc/entry/1/download/a.srt',
      'https://cdn.example.test/b.srt',
      'http://jimaku.cc/c.srt',
    ]) {
      await service.downloadFile(
        apiKey: 'jimaku-key',
        file: JimakuFile(
          url: Uri.parse(url),
          name: Uri.parse(url).pathSegments.last,
          size: 0,
          lastModified: '',
        ),
        outputDirectory: directory,
      );
    }

    expect(keys, {
      'https://jimaku.cc/entry/1/download/a.srt': 'jimaku-key',
      'https://cdn.example.test/b.srt': null,
      'http://jimaku.cc/c.srt': null,
    });
  });

  test('selects the same exact-name entry as Chimahon', () {
    const entries = [
      JimakuEntry(id: 1, name: 'Psycho-Pass 2'),
      JimakuEntry(id: 2, name: 'PSYCHO-PASS', englishName: 'Psycho-Pass'),
    ];

    expect(selectBestJimakuEntry(entries, 'Psycho-Pass')?.id, 2);
  });

  test('matches absolute One Piece episodes in season-numbered SRT files', () {
    const fileName =
        'ワンピース.S03E051.第279話 滝に向かって飛べ！ルフィの想い!!'
        'WEBRip.Amazon.ja-jp.srt';
    final parsed = guessJimakuMedia(fileName);
    final files = [
      JimakuFile(
        url: Uri.parse('https://jimaku.cc/files/one-piece-279.srt'),
        name: fileName,
        size: 32380,
        lastModified: '',
      ),
    ];

    expect(parsed?.episode, 279);
    expect(parsed?.episodeCandidates, containsAll(<int>{51, 279}));
    expect(
      files.matchedSrtFiles(
        const JimakuMediaGuess(title: 'One Piece', episode: 51),
        episodeFiltered: false,
      ),
      hasLength(1),
    );
  });

  test('filters exactly like Chimahon by accepting SRT only', () {
    final files = [
      JimakuFile(
        url: Uri.parse('https://jimaku.cc/files/episode-1.srt'),
        name: 'Psycho-Pass Episode 1.srt',
        size: 10,
        lastModified: '',
      ),
      JimakuFile(
        url: Uri.parse('https://jimaku.cc/files/episode-1.ass'),
        name: 'Psycho-Pass Episode 1.ass',
        size: 10,
        lastModified: '',
      ),
    ];

    expect(
      files
          .matchedSrtFiles(
            const JimakuMediaGuess(title: 'Psycho-Pass', episode: 1),
            episodeFiltered: true,
          )
          .single
          .name,
      endsWith('.srt'),
    );
  });

  test(
    'retries the unfiltered file endpoint exactly when episode files miss',
    () async {
      final requestedEpisodes = <String?>[];
      final service = JimakuSubtitleService(
        client: MockClient((request) async {
          requestedEpisodes.add(request.url.queryParameters['episode']);
          return http.Response(
            jsonEncode(
              request.url.queryParameters.containsKey('episode')
                  ? []
                  : [
                      {
                        'url': 'https://jimaku.cc/files/psycho-pass-1.srt',
                        'name': 'Psycho-Pass Episode 1.srt',
                        'size': 10,
                        'last_modified': '',
                      },
                    ],
            ),
            200,
          );
        }),
      );

      final files = await service.matchingFiles(
        apiKey: 'key',
        entry: const JimakuEntry(id: 7, name: 'Psycho-Pass'),
        guess: const JimakuMediaGuess(title: 'Psycho-Pass', episode: 1),
      );

      expect(requestedEpisodes, ['1', null]);
      expect(files.single.name, 'Psycho-Pass Episode 1.srt');
    },
  );

  test('deduplicates matched files by URL exactly like Chimahon', () async {
    final service = JimakuSubtitleService(
      client: MockClient((request) async {
        return http.Response(
          jsonEncode([
            {
              'url': 'https://jimaku.cc/files/psycho-pass-1.srt',
              'name': 'Psycho-Pass Episode 1.srt',
              'size': 10,
              'last_modified': '',
            },
            {
              'url': 'https://jimaku.cc/files/psycho-pass-1.srt',
              'name': 'Psycho-Pass Episode 1 duplicate.srt',
              'size': 10,
              'last_modified': '',
            },
          ]),
          200,
        );
      }),
    );

    final files = await service.matchingFiles(
      apiKey: 'key',
      entry: const JimakuEntry(id: 7, name: 'Psycho-Pass'),
      guess: const JimakuMediaGuess(title: 'Psycho-Pass', episode: 1),
    );

    expect(files, hasLength(1));
  });

  test('downloads every matched Chimahon SRT file', () async {
    final requested = <String>[];
    final service = JimakuSubtitleService(
      client: MockClient((request) async {
        requested.add(request.url.pathSegments.last);
        return http.Response('subtitle:${request.url.pathSegments.last}', 200);
      }),
    );
    final directory = await Directory.systemTemp.createTemp('jimaku-many-');
    addTearDown(() => directory.delete(recursive: true));
    final files = [
      JimakuFile(
        url: Uri.parse('https://jimaku.cc/files/episode-a.srt'),
        name: 'episode-a.srt',
        size: 10,
        lastModified: '',
      ),
      JimakuFile(
        url: Uri.parse('https://jimaku.cc/files/episode-b.srt'),
        name: 'episode-b.srt',
        size: 20,
        lastModified: '',
      ),
    ];

    final downloaded = await service.downloadFiles(
      apiKey: 'token',
      files: files,
      outputDirectory: directory,
    );

    expect(requested, ['episode-a.srt', 'episode-b.srt']);
    expect(await downloaded[0].readAsString(), 'subtitle:episode-a.srt');
    expect(await downloaded[1].readAsString(), 'subtitle:episode-b.srt');
  });
}
