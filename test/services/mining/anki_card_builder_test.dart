import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:mangayomi/services/mining/anki_card_builder.dart';
import 'package:mangayomi/services/mining/anki_markers.dart';
import 'package:mangayomi/services/mining/mining_models.dart';
import 'package:mangayomi/src/rust/api/hoshidicts.dart';

void main() {
  test('Lapis autofill matches Chimahon sentence defaults', () async {
    final result = HoshiLookupResult(
      matched: '食べさせられました',
      deinflected: '食べる',
      trace: const [],
      preprocessorSteps: 0,
      term: const HoshiTermResult(
        expression: '食べる',
        reading: 'たべる',
        rules: 'v1',
        score: 1,
        glossaries: [],
        frequencies: [],
        pitches: [],
      ),
    );
    const fields = ['Expression', 'Sentence'];
    final fieldMap = AnkiMarker.defaultsForFields(fields, isLapis: true);

    expect(
      AnkiMarker.defaultsForFields(fields)['Sentence'],
      AnkiMarker.sentence,
    );
    expect(fieldMap['Sentence'], AnkiMarker.sentence);

    final draft = await const AnkiCardBuilder().build(
      result: result,
      context: const MiningContext(sentence: 'パンを食べさせられました。'),
      profile: AnkiMiningProfile(modelName: 'Lapis', fieldMap: fieldMap),
    );

    expect(draft.fields['Sentence'], 'パンを食べさせられました。');
  });

  test('blank bundled Lapis maps use Chimahon defaults at export', () async {
    final result = HoshiLookupResult(
      matched: '食べる',
      deinflected: '食べる',
      trace: const [],
      preprocessorSteps: 0,
      term: const HoshiTermResult(
        expression: '食べる',
        reading: 'たべる',
        rules: 'v1',
        score: 1,
        glossaries: [
          HoshiGlossaryEntry(
            dictName: 'JMdict',
            glossary: 'to eat',
            definitionTags: 'v1',
            termTags: '',
          ),
        ],
        frequencies: [],
        pitches: [],
      ),
    );

    final draft = await const AnkiCardBuilder().build(
      result: result,
      context: const MiningContext(
        sentence: 'パンを食べる。',
        sourceTitle: 'Example book',
      ),
      profile: const AnkiMiningProfile(modelName: 'Lapis', fieldMap: {}),
      renderedContent: const {'popupSelectionText': 'selected'},
    );

    expect(draft.fields['Expression'], '食べる');
    expect(draft.fields['Sentence'], 'パンを食べる。');
    expect(draft.fields['SelectionText'], 'selected');
    expect(draft.fields['MiscInfo'], 'Example book');
    expect(draft.fields, isNotEmpty);
  });

  test('uses the Yomitan-rendered payload for Lapis fields', () async {
    final result = HoshiLookupResult(
      matched: 'term',
      deinflected: 'term',
      trace: const [],
      preprocessorSteps: 0,
      term: HoshiTermResult(
        expression: 'term',
        reading: 'reading',
        rules: 'n',
        score: 1,
        glossaries: const [
          HoshiGlossaryEntry(
            dictName: 'Test',
            glossary: '{"type":"structured-content"}',
            definitionTags: 'n',
            termTags: '',
          ),
        ],
        frequencies: const [],
        pitches: const [],
      ),
    );
    final fields = [
      'Expression',
      'ExpressionFurigana',
      'MainDefinition',
      'DefinitionPicture',
      'Picture',
      'Glossary',
      'SelectionText',
      'IsWordAndSentenceCard',
      'Frequency',
      'FreqSort',
    ];
    final media = AnkiMediaFile(
      filename: 'hoshi_dict_0.png',
      bytes: Uint8List.fromList([1, 2, 3]),
    );

    final draft = await const AnkiCardBuilder().build(
      result: result,
      context: const MiningContext(sentence: 'a term in context'),
      profile: AnkiMiningProfile(
        modelName: 'Lapis',
        fieldMap: AnkiMarker.defaultsForFields(fields, isLapis: true),
      ),
      renderedContent: const {
        'furiganaPlain': 'term[reading]',
        'glossary': '<div class="yomitan-glossary">all</div>',
        'glossaryFirst': '<div class="yomitan-glossary">first</div>',
        'popupSelectionText': 'chosen definition',
        'frequenciesHtml': '<ul><li>Test: 10</li></ul>',
        'freqHarmonicRank': '10',
      },
      dictionaryMedia: [media],
    );

    expect(draft.fields['ExpressionFurigana'], 'term[reading]');
    expect(draft.fields['MainDefinition'], contains('first'));
    expect(draft.fields['Glossary'], contains('all'));
    expect(draft.fields['SelectionText'], 'chosen definition');
    expect(draft.fields['DefinitionPicture'], isEmpty);
    expect(draft.fields['IsWordAndSentenceCard'], 'x');
    expect(draft.fields['Frequency'], contains('Test: 10'));
    expect(draft.fields['FreqSort'], '10');
    expect(draft.mediaFiles, [media]);
  });

  test('fills selection markers from highlighted popup text only', () async {
    expect(AnkiMarker.standardTemplates['Selection text'], '{selection-text}');

    final result = HoshiLookupResult(
      matched: 'term',
      deinflected: 'term',
      trace: const [],
      preprocessorSteps: 0,
      term: const HoshiTermResult(
        expression: 'term',
        reading: 'term',
        rules: '',
        score: 1,
        glossaries: [
          HoshiGlossaryEntry(
            dictName: 'JMdict',
            glossary: 'long definition',
            definitionTags: '',
            termTags: '',
          ),
        ],
        frequencies: [],
        pitches: [],
      ),
    );

    final selectedDraft = await const AnkiCardBuilder().build(
      result: result,
      context: const MiningContext(sentence: 'a term in context'),
      profile: const AnkiMiningProfile(
        fieldMap: {
          'SelectionText': AnkiMarker.selectionText,
          'LegacyPopupSelectionText': '{popup-selection-text}',
        },
      ),
      renderedContent: const {'popupSelectionText': 'chosen <definition>'},
    );

    expect(selectedDraft.fields['SelectionText'], 'chosen &lt;definition&gt;');
    expect(
      selectedDraft.fields['LegacyPopupSelectionText'],
      'chosen &lt;definition&gt;',
    );

    final emptyDraft = await const AnkiCardBuilder().build(
      result: result,
      context: const MiningContext(sentence: 'a term in context'),
      profile: const AnkiMiningProfile(
        fieldMap: {
          'SelectionText': AnkiMarker.selectionText,
          'LegacyPopupSelectionText': '{popup-selection-text}',
        },
      ),
    );

    expect(emptyDraft.fields['SelectionText'], isEmpty);
    expect(emptyDraft.fields['LegacyPopupSelectionText'], isEmpty);
  });

  test('fills audio markers and attaches audio media', () async {
    final result = HoshiLookupResult(
      matched: '食べる',
      deinflected: '食べる',
      trace: const [],
      preprocessorSteps: 0,
      term: const HoshiTermResult(
        expression: '食べる',
        reading: 'たべる',
        rules: 'v1',
        score: 1,
        glossaries: [
          HoshiGlossaryEntry(
            dictName: 'JMdict',
            glossary: 'to eat',
            definitionTags: 'v1',
            termTags: '',
          ),
        ],
        frequencies: [],
        pitches: [],
      ),
    );
    final audio = AnkiMediaFile(
      filename: 'taberu.mp3',
      bytes: Uint8List.fromList([0x49, 0x44, 0x33]),
    );

    final draft = await const AnkiCardBuilder().build(
      result: result,
      context: const MiningContext(sentence: 'パンを食べる。'),
      profile: const AnkiMiningProfile(
        fieldMap: {
          'Audio': AnkiMarker.audio,
          'WordAudio': AnkiMarker.wordAudio,
        },
      ),
      wordAudio: audio,
    );

    expect(draft.fields['Audio'], '[sound:taberu.mp3]');
    expect(draft.fields['WordAudio'], '[sound:taberu.mp3]');
    expect(draft.mediaFiles, [audio]);
  });

  test('fills sentence audio only when an Anki field requests it', () async {
    final result = HoshiLookupResult(
      matched: '食べる',
      deinflected: '食べる',
      trace: const [],
      preprocessorSteps: 0,
      term: const HoshiTermResult(
        expression: '食べる',
        reading: 'たべる',
        rules: 'v1',
        score: 1,
        glossaries: [],
        frequencies: [],
        pitches: [],
      ),
    );
    final sentenceAudio = AnkiMediaFile(
      filename: 'sentence.opus',
      bytes: Uint8List.fromList([0x4f, 0x67, 0x67, 0x53]),
    );
    var loads = 0;
    final context = MiningContext(
      sentence: 'パンを食べる。',
      sentenceAudioLoader: (format) {
        loads++;
        expect(format, AnkiSentenceAudioFormat.opus);
        return sentenceAudio;
      },
    );

    final draft = await const AnkiCardBuilder().build(
      result: result,
      context: context,
      profile: const AnkiMiningProfile(
        sentenceAudioFormat: AnkiSentenceAudioFormat.opus,
        fieldMap: {'SentenceAudio': AnkiMarker.sentenceAudio},
      ),
    );

    expect(loads, 1);
    expect(draft.fields['SentenceAudio'], '[sound:sentence.opus]');
    expect(draft.mediaFiles, [sentenceAudio]);
    expect(
      AnkiMiningProfile.fromJson({'sentenceAudioFormat': 'opus'})
          .sentenceAudioFormat,
      AnkiSentenceAudioFormat.opus,
    );

    await const AnkiCardBuilder().build(
      result: result,
      context: context,
      profile: const AnkiMiningProfile(
        fieldMap: {'Sentence': AnkiMarker.sentence},
      ),
    );
    expect(loads, 1);
  });

  test('captures anime audio and screenshot concurrently', () async {
    final audioStarted = Completer<void>();
    final imageStarted = Completer<void>();
    final release = Completer<void>();
    final result = HoshiLookupResult(
      matched: '事件',
      deinflected: '事件',
      trace: const [],
      preprocessorSteps: 0,
      term: const HoshiTermResult(
        expression: '事件',
        reading: 'じけん',
        rules: 'n',
        score: 1,
        glossaries: [],
        frequencies: [],
        pitches: [],
      ),
    );
    final context = MiningContext(
      sentence: '事件が起きた。',
      imageBytesLoader: () async {
        imageStarted.complete();
        await release.future;
        return Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);
      },
      sentenceAudioLoader: (format) async {
        audioStarted.complete();
        await release.future;
        return AnkiMediaFile(
          filename: 'sentence.${format.name}',
          bytes: Uint8List.fromList([1, 2, 3]),
        );
      },
    );

    final build = const AnkiCardBuilder().build(
      result: result,
      context: context,
      profile: const AnkiMiningProfile(
        fieldMap: {
          'Audio': AnkiMarker.sentenceAudio,
          'Picture': AnkiMarker.screenshot,
        },
      ),
    );
    await Future.wait([audioStarted.future, imageStarted.future])
        .timeout(const Duration(seconds: 1));
    release.complete();

    final draft = await build;
    expect(draft.mediaFiles.single.filename, 'sentence.mp3');
  });

  test('a failed screenshot capture only drops the image', () async {
    final result = HoshiLookupResult(
      matched: '猫',
      deinflected: '猫',
      trace: const [],
      preprocessorSteps: 0,
      term: const HoshiTermResult(
        expression: '猫',
        reading: 'ねこ',
        rules: 'n',
        score: 1,
        glossaries: [],
        frequencies: [],
        pitches: [],
      ),
    );
    const profile = AnkiMiningProfile(
      fieldMap: {
        'Front': AnkiMarker.expression,
        'Picture': AnkiMarker.screenshot,
      },
    );
    Future<PreparedAnkiCard> prepare(Object error) async {
      final pending = await const AnkiCardBuilder().buildPending(
        result: result,
        context: MiningContext(
          sentence: '猫がいる。',
          imageBytesLoader: () async => throw error,
        ),
        profile: profile,
      );
      return pending.prepare(null);
    }

    final prepared = await prepare(StateError('page failed to load'));
    expect(prepared.draft.fields, {'Front': '猫', 'Picture': ''});
    expect(prepared.warnings.single, contains('page failed to load'));

    // Closing the crop dialog still cancels the whole card.
    await expectLater(
      prepare(const AnkiExportCancelledException()),
      throwsA(isA<AnkiExportCancelledException>()),
    );
  });

  test(
    'fills Chimahon/Yomitan-style dictionary single glossary markers',
    () async {
      final result = HoshiLookupResult(
        matched: '食べる',
        deinflected: '食べる',
        trace: const [],
        preprocessorSteps: 0,
        term: const HoshiTermResult(
          expression: '食べる',
          reading: 'たべる',
          rules: 'v1',
          score: 1,
          glossaries: [
            HoshiGlossaryEntry(
              dictName: 'JMdict (English)',
              glossary: 'to eat',
              definitionTags: 'v1',
              termTags: '',
            ),
            HoshiGlossaryEntry(
              dictName: '大辞林',
              glossary: '食物を口に入れる',
              definitionTags: '',
              termTags: '',
            ),
            HoshiGlossaryEntry(
              dictName: 'JMdict (English)',
              glossary: 'to consume',
              definitionTags: 'v1',
              termTags: '',
            ),
          ],
          frequencies: [],
          pitches: [],
        ),
      );

      final draft = await const AnkiCardBuilder().build(
        result: result,
        context: const MiningContext(sentence: 'パンを食べる。'),
        profile: const AnkiMiningProfile(
          fieldMap: {
            'Rendered': '{single-glossary-jmdict-english}',
            'Substring': '{single-glossary-jmdict}',
            'NoDictionary': '{single-glossary-jmdict-english-no-dictionary}',
            'Brief': '{single-glossary-jmdict-english-brief}',
            'FirstBrief': '{single-glossary-jmdict-first-brief}',
            'Plain': '{single-glossary-jmdict-english-plain}',
            'PlainNoDictionary':
                '{single-glossary-jmdict-english-plain-no-dictionary}',
            'AllFirstPlain': '{single-glossary-all-first-plain}',
            'Cjk': '{single-glossary-大辞林}',
            'Selected': AnkiMarker.selectedGlossary,
          },
        ),
        renderedContent: {
          'selectedDictionary': '大辞林',
          'singleGlossaries': jsonEncode({
            'JMdict (English)': '<div>rendered jmdict</div>',
            '大辞林': '<div>rendered daijirin</div>',
          }),
        },
      );

      expect(draft.fields['Rendered'], '<div>rendered jmdict</div>');
      expect(draft.fields['Substring'], '<div>rendered jmdict</div>');
      expect(draft.fields['NoDictionary'], contains('to eat'));
      expect(draft.fields['NoDictionary'], isNot(contains('JMdict')));
      expect(draft.fields['Brief'], contains('to consume'));
      expect(draft.fields['Brief'], isNot(contains('JMdict')));
      expect(draft.fields['FirstBrief'], '<ol><li>to eat</li></ol>');
      expect(
        draft.fields['Plain'],
        '(JMdict (English))<br>to eat<br>(JMdict (English))<br>to consume',
      );
      expect(draft.fields['PlainNoDictionary'], 'to eat<br>to consume');
      expect(draft.fields['AllFirstPlain'], '(JMdict (English))<br>to eat');
      expect(draft.fields['Cjk'], '<div>rendered daijirin</div>');
      expect(draft.fields['Selected'], '<div>rendered daijirin</div>');
      expect(
        AnkiMarker.singleGlossaryTemplatesForDictionaries(const [
          'JMdict (English)',
        ]),
        const {
          'Single glossary: JMdict (English)':
              '{single-glossary-jmdict-english}',
        },
      );
    },
  );

  test(
    'keeps screenshots out of DefinitionPicture even for old profiles',
    () async {
      final result = HoshiLookupResult(
        matched: '割方',
        deinflected: '割方',
        trace: const [],
        preprocessorSteps: 0,
        term: const HoshiTermResult(
          expression: '割方',
          reading: 'わりかた',
          rules: 'adv',
          score: 1,
          glossaries: [
            HoshiGlossaryEntry(
              dictName: 'JMdict',
              glossary: 'comparatively',
              definitionTags: 'adv',
              termTags: '',
            ),
          ],
          frequencies: [],
          pitches: [],
        ),
      );

      final draft = await const AnkiCardBuilder().build(
        result: result,
        context: MiningContext(
          sentence: '割方わかった',
          imageBytesLoader: () async => Uint8List.fromList([
            0x89,
            0x50,
            0x4e,
            0x47,
            0x0d,
            0x0a,
            0x1a,
            0x0a,
          ]),
        ),
        profile: const AnkiMiningProfile(
          fieldMap: {
            'DefinitionPicture': AnkiMarker.screenshot,
            'Picture': AnkiMarker.screenshot,
          },
        ),
      );

      expect(draft.fields['DefinitionPicture'], isEmpty);
      expect(draft.fields['Picture'], contains('<img src="'));
    },
  );

  test('compresses screenshots before adding them to Anki media', () async {
    final source = image.Image(width: 1500, height: 900);
    final random = Random(7);
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        source.setPixelRgb(
          x,
          y,
          random.nextInt(256),
          random.nextInt(256),
          random.nextInt(256),
        );
      }
    }
    final png = Uint8List.fromList(image.encodePng(source));
    final result = HoshiLookupResult(
      matched: '事件',
      deinflected: '事件',
      trace: const [],
      preprocessorSteps: 0,
      term: const HoshiTermResult(
        expression: '事件',
        reading: 'じけん',
        rules: 'n',
        score: 1,
        glossaries: [],
        frequencies: [],
        pitches: [],
      ),
    );

    final draft = await const AnkiCardBuilder().build(
      result: result,
      context: MiningContext(
        sentence: '事件が起きた。',
        imageBytesLoader: () async => png,
      ),
      profile: const AnkiMiningProfile(
        fieldMap: {'Picture': AnkiMarker.screenshot},
      ),
    );

    expect(draft.screenshotFileName, endsWith('.jpg'));
    expect(draft.screenshotBytes, isNotNull);
    expect(draft.screenshotBytes!.length, lessThan(png.length));
    expect(draft.screenshotBytes!.take(3), [0xff, 0xd8, 0xff]);
    final compressed = image.decodeImage(draft.screenshotBytes!);
    expect(compressed, isNotNull);
    expect(compressed!.width, lessThanOrEqualTo(1280));
  });

  test('pending cards gate media work until preparation', () async {
    var screenshotLoads = 0;
    var audioLoads = 0;
    var wordAudioLoads = 0;
    final pending = await const AnkiCardBuilder().buildPending(
      result: _simpleResult(),
      context: MiningContext(
        sentence: '事件だ。',
        imageBytesLoader: () async {
          screenshotLoads++;
          return Uint8List.fromList([
            0x89,
            0x50,
            0x4e,
            0x47,
            0x0d,
            0x0a,
            0x1a,
            0x0a,
          ]);
        },
        sentenceAudioLoader: (_) async {
          audioLoads++;
          return AnkiMediaFile(
            filename: 'sentence.mp3',
            bytes: Uint8List.fromList([1]),
          );
        },
      ),
      profile: const AnkiMiningProfile(
        fieldMap: {
          'Front': AnkiMarker.expression,
          'Picture': AnkiMarker.screenshot,
        },
      ),
      wordAudioLoader: () async {
        wordAudioLoads++;
        return AnkiMediaFile(
          filename: 'word.mp3',
          bytes: Uint8List.fromList([2]),
        );
      },
    );

    expect(pending.placeholderDraft.fields['Front'], '事件');
    expect(pending.placeholderDraft.fields['Picture'], isEmpty);
    expect(screenshotLoads, 0);
    expect(audioLoads, 0);
    expect(wordAudioLoads, 0);

    final prepared = await pending.prepare(null);
    expect(screenshotLoads, 1);
    expect(audioLoads, 0);
    expect(wordAudioLoads, 0);
    expect(prepared.draft.fields['Picture'], contains('<img src="'));
  });

  test(
    'no_screenshot suppresses the image loader even with a marker',
    () async {
      var loads = 0;
      final draft = await const AnkiCardBuilder().build(
        result: _simpleResult(),
        context: MiningContext(
          imageBytesLoader: () async {
            loads++;
            return Uint8List.fromList([1, 2, 3]);
          },
        ),
        profile: const AnkiMiningProfile(
          fieldMap: {'Picture': AnkiMarker.screenshot},
        ),
        screenshotMode: AnkiScreenshotMode.noScreenshot,
      );

      expect(loads, 0);
      expect(draft.fields['Picture'], isEmpty);
      expect(draft.screenshotFileName, isNull);
    },
  );

  test(
    'animated mode without a desktop capture keeps the frozen still',
    () async {
      final draft = await const AnkiCardBuilder().build(
        result: _simpleResult(),
        context: MiningContext(
          imageBytesLoader: () async => Uint8List.fromList([
            0x89,
            0x50,
            0x4e,
            0x47,
            0x0d,
            0x0a,
            0x1a,
            0x0a,
          ]),
        ),
        profile: const AnkiMiningProfile(
          fieldMap: {'Picture': AnkiMarker.screenshot},
        ),
        screenshotMode: AnkiScreenshotMode.animatedScene,
      );

      expect(draft.screenshotFileName, endsWith('.png'));
      expect(draft.fields['Picture'], contains('<img src="'));
    },
  );

  test('DefinitionPicture alone does not request screenshot media', () async {
    var loads = 0;
    final draft = await const AnkiCardBuilder().build(
      result: _simpleResult(),
      context: MiningContext(
        imageBytesLoader: () async {
          loads++;
          return Uint8List.fromList([1, 2, 3]);
        },
      ),
      profile: const AnkiMiningProfile(
        fieldMap: {'DefinitionPicture': AnkiMarker.screenshot},
      ),
    );

    expect(loads, 0);
    expect(draft.fields['DefinitionPicture'], isEmpty);
  });
}

HoshiLookupResult _simpleResult() => const HoshiLookupResult(
  matched: '事件',
  deinflected: '事件',
  trace: [],
  preprocessorSteps: 0,
  term: HoshiTermResult(
    expression: '事件',
    reading: 'じけん',
    rules: 'n',
    score: 1,
    glossaries: [],
    frequencies: [],
    pitches: [],
  ),
);
