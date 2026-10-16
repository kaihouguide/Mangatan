import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/modules/mining/widgets/dictionary_glossary.dart';

void main() {
  final samples = [
    _DictionaryZipSample(
      name: 'JMdict English',
      path: r'D:\Japanese\Yomitan Dictionaries\JMdict_english.zip',
    ),
    _DictionaryZipSample(
      name: 'Chigai Dictionary',
      path: r'D:\Japanese\Yomitan Dictionaries\Chigai_Dictionary.zip',
    ),
    _DictionaryZipSample(
      name: 'Nihongo Bunkei Jiten',
      path: r'D:\Japanese\Yomitan Dictionaries\Nihongo-Bunkei-Jiten.zip',
      expectsCss: true,
    ),
    _DictionaryZipSample(
      name: 'Nihongo no Sensei',
      path:
          r'D:\Japanese\Yomitan Dictionaries\Japanese\[JA Grammar] nihongo_no_sensei_1_04.zip',
    ),
    _DictionaryZipSample(
      name: 'Onomatoproject',
      path:
          r'D:\Japanese\Yomitan Dictionaries\Japanese\[JA-EN Onomatopoeia] Onomatoproject.zip',
    ),
  ];

  for (final sample in samples) {
    test('renders real Yomitan glossary sample: ${sample.name}', () {
      final file = File(sample.path);
      if (!file.existsSync()) {
        markTestSkipped('Dictionary ZIP is not present at ${sample.path}');
        return;
      }

      final data = _loadGlossarySamples(file);
      expect(data.glossaries, isNotEmpty);
      expect(
        data.glossaries.any((glossary) => glossary.structured),
        isTrue,
        reason: 'Expected at least one structured-content glossary sample',
      );
      if (sample.expectsCss) {
        expect(data.styles.trim(), isNotEmpty);
      }

      for (final glossary in data.glossaries.take(4)) {
        final html = yomitanGlossaryToHtml(
          glossary.raw,
          dictionaryCss: data.styles,
        );

        expect(html, contains('dictionary-glossary'));
        expect(
          html,
          anyOf(contains('gloss-sc-'), contains('structured-content')),
        );
        expect(html, isNot(contains('&quot;tag&quot;')));
        expect(html, isNot(contains('&quot;type&quot;')));
        expect(html, isNot(contains('{"tag"')));
        expect(html, isNot(contains('"type":"structured-content"')));
        expect(html, isNot(contains('"type": "structured-content"')));
      }
    });
  }
}

_LoadedDictionarySamples _loadGlossarySamples(File file) {
  final input = InputFileStream(file.path);
  final archive = ZipDecoder().decodeStream(input);
  input.closeSync();

  final stylesFile = _firstFileNamed(archive, 'styles.css');
  final styles = stylesFile == null
      ? ''
      : utf8.decode(stylesFile.content as List<int>);
  final glossaries = <_GlossarySample>[];

  final termBanks = archive.files
      .where((file) => _isTermBank(file.name))
      .take(12);
  for (final bank in termBanks) {
    final rows = jsonDecode(utf8.decode(bank.content as List<int>));
    if (rows is! List) continue;
    for (final row in rows) {
      if (row is! List || row.length <= 5) continue;
      final raw = row[5] is String ? row[5] as String : jsonEncode(row[5]);
      if (raw.trim().isEmpty) continue;
      final structured =
          raw.contains('structured-content') || raw.contains('"tag"');
      final sample = _GlossarySample(raw: raw, structured: structured);
      if (structured) {
        glossaries.insert(0, sample);
      } else if (glossaries.length < 4) {
        glossaries.add(sample);
      }
      if (glossaries.where((item) => item.structured).length >= 4) {
        return _LoadedDictionarySamples(glossaries: glossaries, styles: styles);
      }
    }
  }

  return _LoadedDictionarySamples(glossaries: glossaries, styles: styles);
}

ArchiveFile? _firstFileNamed(Archive archive, String name) {
  for (final file in archive.files) {
    if (file.isFile && file.name == name) return file;
  }
  return null;
}

bool _isTermBank(String name) =>
    RegExp(r'(^|/)term_bank_\d+\.json$').hasMatch(name);

class _DictionaryZipSample {
  const _DictionaryZipSample({
    required this.name,
    required this.path,
    this.expectsCss = false,
  });

  final String name;
  final String path;
  final bool expectsCss;
}

class _LoadedDictionarySamples {
  const _LoadedDictionarySamples({
    required this.glossaries,
    required this.styles,
  });

  final List<_GlossarySample> glossaries;
  final String styles;
}

class _GlossarySample {
  const _GlossarySample({required this.raw, required this.structured});

  final String raw;
  final bool structured;
}
