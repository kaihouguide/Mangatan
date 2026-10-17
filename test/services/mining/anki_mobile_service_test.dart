import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/services/mining/anki_mobile_service.dart';
import 'package:mangayomi/services/mining/mining_models.dart';

void main() {
  test('builds an encoded AnkiMobile add-note callback', () {
    final uri = buildAnkiMobileAddNoteUri(
      draft: const AnkiCardDraft(
        deckName: 'Japanese::Mining',
        modelName: 'Kaishi 1.5k 日本語',
        expression: '猫',
        fields: {'Expression': '猫 & ねこ', 'Meaning': '<b>cat</b>'},
        tags: ['mangatan', '日本語'],
      ),
      allowDuplicate: true,
      successCallback: Uri.parse('mangayomi://anki/added?request=request-1'),
    );

    expect(uri.scheme, 'anki');
    expect(uri.host, 'x-callback-url');
    expect(uri.path, '/addnote');
    expect(uri.queryParameters['deck'], 'Japanese::Mining');
    expect(uri.queryParameters['type'], 'Kaishi 1.5k 日本語');
    expect(uri.toString(), contains('type=Kaishi%201.5k%20'));
    expect(uri.toString(), isNot(contains('Kaishi+1.5k')));
    expect(uri.queryParameters['fldExpression'], '猫 & ねこ');
    expect(uri.queryParameters['fldMeaning'], '<b>cat</b>');
    expect(uri.queryParameters['tags'], 'mangatan 日本語');
    expect(uri.queryParameters['dupes'], '1');
    expect(
      uri.queryParameters['x-success'],
      'mangayomi://anki/added?request=request-1',
    );
  });

  test('parses AnkiMobile decks, note types, and fields', () {
    final info = AnkiMobileInfo.fromJson({
      'decks': [
        {'name': 'Mining'},
        'Default',
      ],
      'notetypes': [
        {
          'name': 'Lapis',
          'fields': [
            {'name': 'Expression'},
            {'name': 'Meaning'},
          ],
        },
      ],
    });

    expect(info.decks, ['Mining', 'Default']);
    expect(info.noteTypes.single.name, 'Lapis');
    expect(info.fieldsByNoteType['Lapis'], ['Expression', 'Meaning']);
  });

  test(
    'waits for callback before consuming infoForAdding pasteboard',
    () async {
      Uri? openedUri;
      final service = AnkiMobileService(
        openUrl: (uri) async {
          openedUri = uri;
          final callback = Uri.parse(uri.queryParameters['x-success']!);
          Future<void>.microtask(
            () => AnkiMobileCallbackCoordinator.instance.handle(callback),
          );
          return true;
        },
        readInfoForAdding: () async => jsonEncode({
          'decks': [
            {'name': 'Mining'},
          ],
          'notetypes': [
            {
              'name': 'Basic',
              'fields': [
                {'name': 'Front'},
                {'name': 'Back'},
              ],
            },
          ],
        }),
      );

      final info = await service.fetchInfo();

      expect(openedUri?.toString(), startsWith('anki://x-callback-url/'));
      expect(info.decks, ['Mining']);
      expect(info.fieldsByNoteType['Basic'], ['Front', 'Back']);
    },
  );

  test('serves and rewrites image and audio media for AnkiMobile', () async {
    var beganBackgroundTask = false;
    var endedBackgroundTask = false;
    final fetched = <String, List<int>>{};
    late Uri openedUri;
    final service = AnkiMobileService(
      mediaServerLifetime: const Duration(milliseconds: 20),
      beginMediaImportBackgroundTask: () async {
        beganBackgroundTask = true;
      },
      endMediaImportBackgroundTask: () async {
        endedBackgroundTask = true;
      },
      openUrl: (uri) async {
        openedUri = uri;
        final fields = {
          uri.queryParameters['fldImage']!,
          uri.queryParameters['fldAudio']!,
        };
        final urls = RegExp(r'http://127\.0\.0\.1:\d+/media/[^"\s<]+')
            .allMatches(fields.join('\n'))
            .map((match) => match.group(0)!)
            .toSet();
        final client = HttpClient();
        client
          ..findProxy = ((_) => 'DIRECT')
          ..connectionTimeout = const Duration(seconds: 3);
        try {
          for (final value in urls) {
            final request = await client
                .getUrl(Uri.parse(value))
                .timeout(const Duration(seconds: 3));
            final response = await request.close().timeout(
              const Duration(seconds: 3),
            );
            fetched[value] = await response
                .fold<List<int>>(
                  <int>[],
                  (bytes, chunk) => bytes..addAll(chunk),
                )
                .timeout(const Duration(seconds: 3));
          }
        } finally {
          client.close(force: true);
        }
        return true;
      },
    );

    await service.exportDraft(
      AnkiCardDraft(
        deckName: 'Mining',
        modelName: 'Basic',
        expression: '猫',
        fields: const {
          'Image': '<img src="page image.png">',
          'Audio': '[sound:word.mp3]',
        },
        mediaFiles: [
          AnkiMediaFile(
            filename: 'word.mp3',
            bytes: Uint8List.fromList([1, 2, 3]),
          ),
        ],
        screenshotFileName: 'page image.png',
        screenshotBytes: Uint8List.fromList([4, 5, 6]),
      ),
    );

    expect(openedUri.queryParameters['fldImage'], startsWith('http://'));
    expect(openedUri.queryParameters['fldImage'], endsWith('.png'));
    expect(openedUri.queryParameters['fldAudio'], endsWith('.mp3'));
    expect(
      fetched.values,
      containsAll(<List<int>>[
        [1, 2, 3],
        [4, 5, 6],
      ]),
    );
    expect(beganBackgroundTask, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(endedBackgroundTask, isTrue);
  });

  test('keeps media URLs inside fields that contain other HTML', () {
    final value = replaceAnkiMobileMediaReferences(
      '<b>cat</b><br><img src="dictionary.png">',
      {'dictionary.png': 'http://127.0.0.1:1234/media/dictionary.png'},
    );

    expect(value, startsWith('<b>cat</b>'));
    expect(value, contains('<img src="http://127.0.0.1:1234/'));
  });

  test('iOS runner declares callback bridge and Anki URL scheme', () {
    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(appDelegate, contains('net.ankimobile.json'));
    expect(appDelegate, contains('consumeInfoForAddingPasteboard'));
    expect(appDelegate, contains('beginMediaImportBackgroundTask'));
    expect(infoPlist, contains('<key>LSApplicationQueriesSchemes</key>'));
    expect(infoPlist, contains('<string>anki</string>'));
    expect(infoPlist, contains('<string>mangayomi</string>'));
  });

  test('media URLs cannot be guessed by other apps on the device', () async {
    final server = await AnkiMobileMediaServer.start();
    addTearDown(server.close);
    final url = Uri.parse(
      server.addBytes('shot.png', Uint8List.fromList([1, 2, 3])),
    );
    expect(url.path, matches(RegExp(r'^/media/0-[0-9a-f]{32}-shot\.png$')));

    final client = HttpClient()..findProxy = ((_) => 'DIRECT');
    addTearDown(client.close);
    Future<int> status(Uri uri) async =>
        (await (await client.getUrl(uri)).close()).statusCode;
    expect(await status(url), 200);
    expect(await status(url.replace(path: '/media/0-shot.png')), 404);
  });
}
