import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/modules/mining/widgets/hoshi_dictionary_popup.dart';
import 'package:mangayomi/services/hoshidicts/hoshidicts_backend.dart';
import 'package:mangayomi/services/hoshidicts/yomitan_kanji_dictionary.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'mangatan-kanji-test-',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('rejects dictionary titles that are not one folder name', () async {
    for (final title in ['../escape', r'a\b', '..', 'C:escape']) {
      final zip = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}unsafe.zip',
      );
      await zip.writeAsBytes(
        ZipEncoder().encode(
          Archive()..addFile(
            ArchiveFile.string('index.json', jsonEncode({'title': title})),
          ),
        ),
      );
      await expectLater(
        ensureYomitanDictionaryTitleIsSafe(zip.path),
        throwsFormatException,
        reason: title,
      );
    }
  });

  test('accepts ordinary dictionary titles', () async {
    final zip = await _writeDictionaryZip(
      temporaryDirectory,
      title: 'JMdict [2024-05-01]',
      kanjiBank: const [],
      tagBank: const [],
    );
    await ensureYomitanDictionaryTitleIsSafe(zip.path);
  });

  test('imports Yomitan V3 Kanji banks and resolves tag metadata', () async {
    final zip = await _writeDictionaryZip(
      temporaryDirectory,
      title: 'KANJIDIC test',
      kanjiBank: [
        [
          '亜',
          'ア',
          'つ.ぐ',
          'jouyou',
          ['Asia', 'rank next'],
          {'grade': '8', 'ucs': '4E9C', 'heisig': '1809'},
        ],
      ],
      tagBank: [
        ['jouyou', 'frequent', -5, 'regular-use character', 0],
        ['grade', 'misc', 0, 'Grade level', 0],
        ['ucs', 'code', 0, 'Unicode hex code', 0],
        ['heisig', 'index', 0, 'Remembering The Kanji', 0],
      ],
      kanjiMetaBank: [
        [
          '亜',
          'freq',
          {'value': 1509, 'displayValue': '1,509'},
        ],
      ],
    );

    final parsed = await YomitanKanjiArchive.read(zip.path);
    expect(parsed, isNotNull);
    expect(parsed!.title, 'KANJIDIC test');
    expect(parsed.entries, hasLength(1));
    expect(parsed.entries.single['onyomi'], ['ア']);
    expect(parsed.entries.single['kunyomi'], ['つ.ぐ']);
    expect(parsed.entries.single['definitions'], ['Asia', 'rank next']);
    expect(
      (parsed.entries.single['stats'] as Map)['code'],
      contains(containsPair('content', 'Unicode hex code')),
    );

    await parsed.persist(temporaryDirectory.path);
    final store = YomitanKanjiStore();
    await store.configure([
      '${temporaryDirectory.path}${Platform.pathSeparator}KANJIDIC test',
    ]);
    final results = store.lookup('亜亜');
    expect(results, hasLength(1), reason: 'characters are unique like Yomitan');
    expect(results.single.matched, '亜');

    final popup = hoshiPopupEntry(results.single);
    expect(popup['type'], yomitanKanjiContentType);
    expect(popup['dictionary'], 'KANJIDIC test');
    expect(popup['definitions'], ['Asia', 'rank next']);
    expect(
      popup['frequencies'],
      contains(containsPair('displayValue', '1,509')),
    );
  });

  test('accepts wrapped meanings emitted by real Kanji dictionaries', () async {
    final zip = await _writeDictionaryZip(
      temporaryDirectory,
      title: 'Wrapped meanings',
      kanjiBank: [
        [
          '万',
          '',
          '',
          'variant',
          {
            'value': ['old form: 萬', 'variant: 㒼'],
            'Count': 2,
          },
          <String, String>{},
        ],
      ],
      tagBank: [
        ['variant', 'class', 0, 'Character variant', 0],
      ],
    );

    final parsed = await YomitanKanjiArchive.read(zip.path);
    expect(parsed!.entries.single['definitions'], [
      'old form: 萬',
      'variant: 㒼',
    ]);
  });

  test('a damaged stored dictionary does not disable the others', () async {
    Future<String> writeStore(String name, Object data) async {
      final directory = Directory('${temporaryDirectory.path}/$name');
      await directory.create();
      await File('${directory.path}/$yomitanKanjiDataFileName')
          .writeAsString(jsonEncode(data));
      return directory.path;
    }

    final damaged = await writeStore('damaged', {
      'title': 'Damaged',
      'entries': [
        {'character': '日'},
      ],
      'frequencies': {'not': 'a list'},
    });
    final valid = await writeStore('valid', {
      'title': 'Valid',
      'entries': [
        {
          'character': '日',
          'meanings': ['day'],
        },
      ],
    });

    final store = YomitanKanjiStore();
    await store.configure([damaged, valid]);

    expect(store.lookup('日'), hasLength(1));
  });

  test(
    'reads all provided Kanji dictionaries when samples are available',
    () async {
      // Point MANGATAN_KANJI_SAMPLES at a folder of real Kanji dictionary
      // ZIPs to run this locally.
      final samplesPath = Platform.environment['MANGATAN_KANJI_SAMPLES'];
      if (samplesPath == null || samplesPath.isEmpty) return;
      final samples = Directory(samplesPath);
      if (!samples.existsSync()) return;

      final archives =
          samples
              .listSync()
              .whereType<File>()
              .where((file) => file.path.toLowerCase().endsWith('.zip'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      expect(archives, isNotEmpty);
      for (final archive in archives) {
        final parsed = await YomitanKanjiArchive.read(archive.path);
        expect(parsed, isNotNull, reason: archive.path);
        expect(parsed!.entries, isNotEmpty, reason: archive.path);
        final imported = await HoshidictsLookupBackend.instance
            .importDictionary(
              zipPath: archive.path,
              outputDir: temporaryDirectory.path,
            );
        expect(imported.success, isTrue, reason: archive.path);
        expect(imported.kanjiCount, greaterThan(BigInt.zero));
        expect(
          File(
            '${temporaryDirectory.path}${Platform.pathSeparator}'
            '${imported.title}${Platform.pathSeparator}'
            '$yomitanKanjiDataFileName',
          ).existsSync(),
          isTrue,
          reason: archive.path,
        );
      }
    },
  );
}

Future<File> _writeDictionaryZip(
  Directory directory, {
  required String title,
  required List<List<dynamic>> kanjiBank,
  required List<List<dynamic>> tagBank,
  List<List<dynamic>> kanjiMetaBank = const [],
}) async {
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        'index.json',
        jsonEncode({'title': title, 'format': 3, 'revision': 'test'}),
      ),
    )
    ..addFile(ArchiveFile.string('kanji_bank_1.json', jsonEncode(kanjiBank)))
    ..addFile(ArchiveFile.string('tag_bank_1.json', jsonEncode(tagBank)));
  if (kanjiMetaBank.isNotEmpty) {
    archive.addFile(
      ArchiveFile.string('kanji_meta_bank_1.json', jsonEncode(kanjiMetaBank)),
    );
  }
  final bytes = ZipEncoder().encode(archive);
  final file = File(
    '${directory.path}${Platform.pathSeparator}${title.replaceAll(' ', '_')}.zip',
  );
  await file.writeAsBytes(bytes);
  return file;
}
