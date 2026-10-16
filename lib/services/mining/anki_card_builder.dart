import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:mangayomi/services/mining/anki_markers.dart';
import 'package:mangayomi/services/mining/media_file_name.dart';
import 'package:mangayomi/services/mining/mining_models.dart';
import 'package:mangayomi/src/rust/api/hoshidicts.dart';

class AnkiCardBuilder {
  const AnkiCardBuilder();

  Future<AnkiCardDraft> build({
    required HoshiLookupResult result,
    required MiningContext context,
    AnkiMiningProfile profile = const AnkiMiningProfile(),
    Map<String, dynamic> renderedContent = const {},
    List<AnkiMediaFile> dictionaryMedia = const [],
    AnkiMediaFile? wordAudio,
    AnkiScreenshotMode screenshotMode = AnkiScreenshotMode.full,
  }) async {
    final prepared = await _buildPrepared(
      result: result,
      context: context,
      profile: profile,
      renderedContent: renderedContent,
      dictionaryMedia: dictionaryMedia,
      wordAudio: wordAudio,
      screenshotMode: screenshotMode,
    );
    return prepared.draft;
  }

  Future<PendingAnkiCard> buildPending({
    required HoshiLookupResult result,
    required MiningContext context,
    AnkiMiningProfile profile = const AnkiMiningProfile(),
    AnkiScreenshotMode screenshotMode = AnkiScreenshotMode.full,
    Map<String, dynamic> renderedContent = const {},
    Future<List<AnkiMediaFile>> Function()? dictionaryMediaLoader,
    Future<AnkiMediaFile?> Function()? wordAudioLoader,
  }) async {
    final fieldMap = profile.effectiveFieldMap;
    final placeholder = await _buildPrepared(
      result: result,
      context: context.copyWith(
        imageBytesLoader: () async => null,
        sentenceAudioLoader: (_) async => null,
      ),
      profile: profile,
      renderedContent: renderedContent,
      screenshotMode: AnkiScreenshotMode.noScreenshot,
    );
    final usesScreenshot = _usesScreenshotMarker(fieldMap);
    final usesWordAudio =
        _usesMarker(fieldMap, AnkiMarker.audio) ||
        _usesMarker(fieldMap, AnkiMarker.wordAudio);
    final requests = <AnkiMediaRequest>[
      if (dictionaryMediaLoader != null)
        AnkiMediaRequest(
          marker: 'dictionary-media',
          load: dictionaryMediaLoader,
        ),
      if (usesWordAudio && wordAudioLoader != null)
        AnkiMediaRequest(marker: AnkiMarker.wordAudio, load: wordAudioLoader),
      if (_usesMarker(fieldMap, AnkiMarker.sentenceAudio) &&
          context.sentenceAudioLoader != null)
        AnkiMediaRequest(
          marker: AnkiMarker.sentenceAudio,
          load: () => Future<Object?>.value(
            context.sentenceAudioLoader!(profile.sentenceAudioFormat),
          ),
        ),
      if (usesScreenshot && screenshotMode != AnkiScreenshotMode.noScreenshot)
        AnkiMediaRequest(
          marker: AnkiMarker.screenshot,
          load: () async => context.sceneCapture ?? context.imageBytesLoader,
        ),
    ];

    return PendingAnkiCard(
      placeholderDraft: placeholder.draft,
      jobController: screenshotMode == AnkiScreenshotMode.animatedScene
          ? context.sceneCapture?.jobController
          : null,
      mediaRequests: requests,
      prepare: (session) async {
        session?.registerCancel(() {});
        session?.throwIfCancelled();
        final dictionaryMedia = dictionaryMediaLoader == null
            ? const <AnkiMediaFile>[]
            : await dictionaryMediaLoader();
        session?.throwIfCancelled();
        final wordAudio = !usesWordAudio || wordAudioLoader == null
            ? null
            : await wordAudioLoader();
        session?.throwIfCancelled();

        AnkiScreenshotPreparation? animatedScreenshot;
        final capture = context.sceneCapture;
        if (usesScreenshot &&
            screenshotMode == AnkiScreenshotMode.animatedScene &&
            capture != null) {
          if (session == null) {
            throw StateError(
              'Animated scene preparation requires a player job session.',
            );
          }
          try {
            animatedScreenshot = await capture.prepareAnimatedScreenshot(
              session,
            );
          } on AnkiExportCancelledException {
            rethrow;
          } catch (_) {
            // The normal screenshot path below is the authoritative fallback.
          }
        }
        session?.throwIfCancelled();
        var handedOff = false;
        try {
          final prepared = await _buildPrepared(
            result: result,
            context: context,
            profile: profile,
            renderedContent: renderedContent,
            dictionaryMedia: dictionaryMedia,
            wordAudio: wordAudio,
            screenshotMode: screenshotMode,
            screenshotOverride: animatedScreenshot,
          );
          handedOff = true;
          return PreparedAnkiCard(
            draft: prepared.draft,
            screenshot: prepared.screenshot,
            warnings: prepared.screenshot?.warnings ?? const [],
          );
        } finally {
          if (!handedOff) {
            await animatedScreenshot?.dispose();
            for (final media in dictionaryMedia) {
              await media.source.dispose();
            }
            await wordAudio?.source.dispose();
          }
        }
      },
    );
  }

  Future<({AnkiCardDraft draft, AnkiScreenshotPreparation? screenshot})>
  _buildPrepared({
    required HoshiLookupResult result,
    required MiningContext context,
    required AnkiMiningProfile profile,
    required Map<String, dynamic> renderedContent,
    List<AnkiMediaFile> dictionaryMedia = const [],
    AnkiMediaFile? wordAudio,
    required AnkiScreenshotMode screenshotMode,
    AnkiScreenshotPreparation? screenshotOverride,
  }) async {
    final fieldMap = profile.effectiveFieldMap;
    final sentenceAudioFuture = _usesMarker(fieldMap, AnkiMarker.sentenceAudio)
        ? Future<AnkiMediaFile?>.sync(
            () =>
                context.sentenceAudioLoader?.call(profile.sentenceAudioFormat),
          )
        : Future<AnkiMediaFile?>.value();
    final screenshotFuture =
        !_usesScreenshotMarker(fieldMap) ||
            screenshotMode == AnkiScreenshotMode.noScreenshot
        ? Future<_ScreenshotPayload?>.value()
        : screenshotOverride != null
        ? Future<_ScreenshotPayload?>.value(
            _ScreenshotPayload.fromPreparation(screenshotOverride),
          )
        : _loadScreenshot(context);
    final media = await Future.wait<Object?>([
      sentenceAudioFuture,
      screenshotFuture,
    ]);
    final sentenceAudio = media[0] as AnkiMediaFile?;
    final screenshot = media[1] as _ScreenshotPayload?;
    final screenshotName =
        screenshot?.filename ??
        (screenshot == null
            ? null
            : _safeMediaName(
                [
                  context.sourceTitle,
                  context.chapterTitle,
                  result.term.expression,
                  DateTime.now().millisecondsSinceEpoch.toString(),
                ].where((part) => part.trim().isNotEmpty).join(' '),
                extension: screenshot.extension,
              ));
    final screenshotPreparation = screenshot == null || screenshotName == null
        ? null
        : screenshot.preparation ??
              AnkiScreenshotPreparation(
                filename: screenshotName,
                source: AnkiMediaSource.bytes(screenshot.bytes!),
                fallbackFilename: screenshotName,
                fallbackSource: AnkiMediaSource.bytes(screenshot.bytes!),
              );

    final selectedGlossary = result.term.glossaries.take(1).toList();
    String rendered(String key, String fallback) {
      final value = renderedContent[key];
      return value is String && value.isNotEmpty ? value : fallback;
    }

    final renderedSingleGlossaries = _renderedSingleGlossaries(
      renderedContent['singleGlossaries'],
    );
    final selectedText = _escape(
      renderedContent['popupSelectionText']?.toString() ?? '',
    );
    final glossary = rendered('glossary', _glossary(result.term.glossaries));
    final glossaryPlain = _glossaryPlain(result.term.glossaries);
    final selectedDictionary =
        renderedContent['selectedDictionary']?.toString().trim() ?? '';
    final selectedGlossaryEntries = selectedDictionary.isEmpty
        ? selectedGlossary
        : _filterGlossaries(result.term.glossaries, selectedDictionary);
    final effectiveSelectedGlossary = selectedGlossaryEntries.isEmpty
        ? selectedGlossary
        : selectedGlossaryEntries;
    final selectedGlossaryHtml = selectedDictionary.isEmpty
        ? rendered('glossaryFirst', _glossary(selectedGlossary))
        : _renderedGlossaryForSingleDictionary(
                effectiveSelectedGlossary,
                renderedSingleGlossaries,
              ) ??
              _glossary(effectiveSelectedGlossary);
    final selectedGlossaryPlain = _glossaryPlain(effectiveSelectedGlossary);
    final frequencySummary = rendered(
      'freqHarmonicRank',
      _frequencySummary(result.term.frequencies),
    );
    final cloze = _cloze(context.sentence, result.matched);
    final wordAudioTag = wordAudio == null
        ? ''
        : '[sound:${_soundFilename(wordAudio.filename)}]';
    final sentenceAudioTag = sentenceAudio == null
        ? ''
        : '[sound:${_soundFilename(sentenceAudio.filename)}]';
    final replacements = <String, String>{
      AnkiMarker.expression: _escape(result.term.expression),
      AnkiMarker.reading: _escape(result.term.reading),
      AnkiMarker.furigana: _furigana(
        result.term.expression,
        result.term.reading,
      ),
      AnkiMarker.furiganaPlain: rendered(
        'furiganaPlain',
        _furiganaPlain(result.term.expression, result.term.reading),
      ),
      AnkiMarker.audio: wordAudioTag,
      AnkiMarker.glossary: glossary,
      AnkiMarker.glossaryBrief: selectedGlossaryHtml,
      AnkiMarker.glossaryPlain: glossaryPlain,
      AnkiMarker.glossaryFirst: selectedGlossaryHtml,
      AnkiMarker.selectedGlossary: selectedGlossaryHtml,
      AnkiMarker.singleGlossary: selectedGlossaryPlain,
      AnkiMarker.sentence: _escape(context.sentence),
      AnkiMarker.sentenceBold: _sentenceBold(context.sentence, result.matched),
      AnkiMarker.sentenceFurigana: _escape(context.sentence),
      AnkiMarker.clozePrefix: cloze.$1,
      AnkiMarker.clozeBody: cloze.$2,
      AnkiMarker.clozeBodyKana: cloze.$2,
      AnkiMarker.clozeSuffix: cloze.$3,
      AnkiMarker.tags: profile.tags.join(' '),
      AnkiMarker.partOfSpeech: _escape(result.term.rules),
      AnkiMarker.conjugation: _escape(
        result.trace.map((t) => t.name).join(' '),
      ),
      AnkiMarker.dictionary: result.term.glossaries
          .map((entry) => entry.dictName)
          .where((name) => name.trim().isNotEmpty)
          .toSet()
          .map(_escape)
          .join(', '),
      AnkiMarker.dictionaryAlias: result.term.glossaries
          .map((entry) => entry.dictName)
          .where((name) => name.trim().isNotEmpty)
          .toSet()
          .map(_escape)
          .join(', '),
      AnkiMarker.frequencies: rendered(
        'frequenciesHtml',
        _frequencies(result.term.frequencies),
      ),
      AnkiMarker.frequencyLowest: frequencySummary,
      AnkiMarker.frequencyHarmonic: frequencySummary,
      AnkiMarker.frequencyHarmonicRank: frequencySummary,
      AnkiMarker.frequencyAverage: frequencySummary,
      AnkiMarker.frequencyAverageRank: frequencySummary,
      AnkiMarker.pitchAccents: _pitchAccents(result.term.pitches),
      AnkiMarker.pitchAccentPositions: rendered(
        'pitchPositions',
        result.term.pitches
            .expand((pitch) => pitch.pitchPositions)
            .map((position) => position.toString())
            .toSet()
            .join(', '),
      ),
      AnkiMarker.pitchAccentCategories: rendered(
        'pitchCategories',
        result.term.pitches
            .map((pitch) => pitch.dictName)
            .where((name) => name.trim().isNotEmpty)
            .toSet()
            .map(_escape)
            .join(', '),
      ),
      AnkiMarker.screenshot: screenshotName == null
          ? ''
          : '<img src="$screenshotName">',
      AnkiMarker.wordAudio: wordAudioTag,
      AnkiMarker.sentenceAudio: sentenceAudioTag,
      AnkiMarker.url: _escape(context.sourceUri?.toString() ?? ''),
      AnkiMarker.book: _escape(context.sourceTitle),
      AnkiMarker.chapter: _escape(context.chapterTitle),
      AnkiMarker.media: _escape(context.locationLabel),
      AnkiMarker.source: _escape(context.locationLabel),
      AnkiMarker.documentTitle: _escape(context.sourceTitle),
      AnkiMarker.selectionText: selectedText,
      AnkiMarker.popupSelectionText: selectedText,
      AnkiMarker.mediaName: _escape(context.sourceTitle),
    };

    final fields = fieldMap.map((field, template) {
      if (_normalizeFieldName(field) == 'definitionpicture') {
        return MapEntry(field, '');
      }
      var value = template;
      for (final replacement in replacements.entries) {
        value = value.replaceAll(replacement.key, replacement.value);
      }
      value = _replaceDynamicMarkers(
        value,
        result.term.glossaries,
        renderedSingleGlossaries,
      );
      return MapEntry(field, value);
    });

    return (
      draft: AnkiCardDraft(
        deckName: profile.deckName,
        modelName: profile.modelName,
        expression: result.term.expression,
        fields: fields,
        tags: profile.tags,
        screenshotBytes: screenshot?.bytes,
        screenshotSource: screenshotPreparation?.source,
        screenshotFileName: screenshotName,
        mediaFiles: [...dictionaryMedia, ?wordAudio, ?sentenceAudio],
      ),
      screenshot: screenshotPreparation,
    );
  }

  bool _usesMarker(Map<String, String> fieldMap, String marker) =>
      fieldMap.values.any((template) => template.contains(marker));

  bool _usesScreenshotMarker(Map<String, String> fieldMap) =>
      fieldMap.entries.any(
        (entry) =>
            _normalizeFieldName(entry.key) != 'definitionpicture' &&
            entry.value.contains(AnkiMarker.screenshot),
      );

  Future<_ScreenshotPayload?> _loadScreenshot(MiningContext context) async {
    final loader = context.imageBytesLoader;
    if (loader == null) return null;
    final bytes = await loader();
    if (bytes == null || bytes.isEmpty) return null;
    final original = Uint8List.fromList(bytes);
    final compressed = await Isolate.run(() => _compressScreenshot(original));
    if (compressed != null && compressed.length < original.length) {
      return _ScreenshotPayload(compressed, 'jpg');
    }
    if (original.length <= _absoluteScreenshotUploadBytes) {
      return _ScreenshotPayload(original, _extensionForImage(original));
    }
    return null;
  }

  static String _furigana(String expression, String reading) {
    if (reading.trim().isEmpty || reading == expression) {
      return _escape(expression);
    }
    return '<ruby>${_escape(expression)}<rt>${_escape(reading)}</rt></ruby>';
  }

  static String _furiganaPlain(String expression, String reading) {
    if (reading.trim().isEmpty || reading == expression) return expression;
    return '$expression[$reading]';
  }

  static String _glossary(
    Iterable<HoshiGlossaryEntry> entries, {
    bool includeDictionary = true,
    bool brief = false,
  }) {
    final rows = entries.where((entry) => entry.glossary.trim().isNotEmpty).map(
      (entry) {
        final dict =
            brief || !includeDictionary || entry.dictName.trim().isEmpty
            ? ''
            : '<span class="dict">${_escape(entry.dictName)}</span> ';
        return '<li>$dict${_escape(entry.glossary)}</li>';
      },
    ).join();
    return rows.isEmpty ? '' : '<ol>$rows</ol>';
  }

  static String _glossaryPlain(
    Iterable<HoshiGlossaryEntry> entries, {
    bool includeDictionary = false,
  }) {
    return entries
        .where((entry) => entry.glossary.trim().isNotEmpty)
        .map((entry) {
          final glossary = _escape(entry.glossary.trim());
          final dictionary = entry.dictName.trim();
          if (!includeDictionary || dictionary.isEmpty) return glossary;
          return '(${_escape(dictionary)})<br>$glossary';
        })
        .join('<br>');
  }

  static Map<String, String> _renderedSingleGlossaries(Object? value) {
    Object? decoded = value;
    if (value is String) {
      if (value.trim().isEmpty) return const {};
      try {
        decoded = jsonDecode(value);
      } on FormatException {
        return const {};
      }
    }
    if (decoded is! Map) return const {};
    final glossaries = <String, String>{};
    decoded.forEach((key, value) {
      if (value is String && value.trim().isNotEmpty) {
        glossaries[key.toString()] = value;
      }
    });
    return glossaries;
  }

  static String _replaceDynamicMarkers(
    String value,
    Iterable<HoshiGlossaryEntry> entries,
    Map<String, String> renderedSingleGlossaries,
  ) {
    return value.replaceAllMapped(_markerPattern, (match) {
      final marker = match.group(1);
      if (marker == null) return match.group(0) ?? '';
      final dynamicValue = _parseSingleGlossaryMarker(
        marker,
        entries,
        renderedSingleGlossaries,
      );
      return dynamicValue ?? match.group(0) ?? '';
    });
  }

  static String? _parseSingleGlossaryMarker(
    String marker,
    Iterable<HoshiGlossaryEntry> entries,
    Map<String, String> renderedSingleGlossaries,
  ) {
    const prefix = 'single-glossary-';
    if (!marker.startsWith(prefix)) return null;

    final rest = marker.substring(prefix.length);
    if (rest.trim().isEmpty) return '';

    final tokens = rest.split('-').where((token) => token.isNotEmpty).toList();
    var brief = false;
    var firstOnly = false;
    var plain = false;
    var noDictionary = false;
    while (tokens.isNotEmpty) {
      final suffix = tokens.last.toLowerCase();
      if (suffix == 'brief') {
        brief = true;
        tokens.removeLast();
      } else if (suffix == 'first') {
        firstOnly = true;
        tokens.removeLast();
      } else if (suffix == 'plain') {
        plain = true;
        tokens.removeLast();
      } else if (tokens.length >= 2 &&
          tokens[tokens.length - 2].toLowerCase() == 'no' &&
          suffix == 'dictionary') {
        noDictionary = true;
        tokens.removeLast();
        tokens.removeLast();
      } else {
        break;
      }
    }

    final dictionaryKey = tokens.join('-').trim();
    if (dictionaryKey.isEmpty) return '';

    final filtered = dictionaryKey.toLowerCase() == 'all'
        ? entries.where((entry) => entry.glossary.trim().isNotEmpty).toList()
        : _filterGlossaries(entries, dictionaryKey);
    final selected = firstOnly ? filtered.take(1).toList() : filtered;
    if (selected.isEmpty) return '';

    if (plain) {
      return _glossaryPlain(selected, includeDictionary: !noDictionary);
    }

    if (!brief && !noDictionary && !firstOnly) {
      final rendered = _renderedGlossaryForSingleDictionary(
        selected,
        renderedSingleGlossaries,
      );
      if (rendered != null) return rendered;
    }

    return _glossary(selected, includeDictionary: !noDictionary, brief: brief);
  }

  static List<HoshiGlossaryEntry> _filterGlossaries(
    Iterable<HoshiGlossaryEntry> entries,
    String dictionaryFilter,
  ) {
    final filter = dictionaryFilter.trim().toLowerCase();
    if (filter.isEmpty) return const [];
    return entries.where((entry) {
      if (entry.glossary.trim().isEmpty) return false;
      final dictionary = entry.dictName.trim();
      if (dictionary.isEmpty) return false;
      final dictionaryLower = dictionary.toLowerCase();
      final dictionaryKebab = AnkiMarker.kebabCase(dictionary);
      return dictionaryLower.contains(filter) ||
          dictionaryKebab == filter ||
          dictionaryKebab.contains(filter);
    }).toList();
  }

  static String? _renderedGlossaryForSingleDictionary(
    Iterable<HoshiGlossaryEntry> entries,
    Map<String, String> renderedSingleGlossaries,
  ) {
    final dictionaries = entries
        .map((entry) => entry.dictName.trim())
        .where((dictionary) => dictionary.isNotEmpty)
        .toSet();
    if (dictionaries.length != 1) return null;
    final rendered = renderedSingleGlossaries[dictionaries.first];
    return rendered != null && rendered.trim().isNotEmpty ? rendered : null;
  }

  static String _frequencies(List<HoshiFrequencyEntry> entries) {
    return entries
        .expand(
          (entry) => entry.frequencies.map(
            (frequency) =>
                '${entry.dictName}: ${frequency.displayValue.trim().isEmpty ? frequency.value : frequency.displayValue}',
          ),
        )
        .map(_escape)
        .join('<br>');
  }

  static String _frequencySummary(List<HoshiFrequencyEntry> entries) {
    final values = entries
        .expand((entry) => entry.frequencies)
        .map((frequency) => frequency.value)
        .toList();
    if (values.isEmpty) return '';
    values.sort();
    return values.first.toString();
  }

  static String _pitchAccents(List<HoshiPitchEntry> entries) {
    return entries
        .map((entry) {
          final positions = entry.pitchPositions
              .map((p) => p.toString())
              .join(', ');
          final transcriptions = entry.transcriptions.join(', ');
          return [
            if (entry.dictName.trim().isNotEmpty) entry.dictName,
            if (positions.isNotEmpty) positions,
            if (transcriptions.isNotEmpty) transcriptions,
          ].join(': ');
        })
        .where((text) => text.trim().isNotEmpty)
        .map(_escape)
        .join('<br>');
  }

  static (String, String, String) _cloze(String sentence, String matched) {
    if (sentence.trim().isEmpty || matched.trim().isEmpty) {
      return ('', _escape(matched), '');
    }
    final index = sentence.indexOf(matched);
    if (index < 0) return ('', _escape(matched), '');
    return (
      _escape(sentence.substring(0, index)),
      _escape(matched),
      _escape(sentence.substring(index + matched.length)),
    );
  }

  static String _sentenceBold(String sentence, String matched) {
    if (sentence.trim().isEmpty || matched.trim().isEmpty) {
      return _escape(sentence);
    }
    final index = sentence.indexOf(matched);
    if (index < 0) return _escape(sentence);
    return [
      _escape(sentence.substring(0, index)),
      '<b>${_escape(matched)}</b>',
      _escape(sentence.substring(index + matched.length)),
    ].join();
  }

  static String _safeMediaName(String value, {required String extension}) {
    final safe = sanitizeMediaFileName(value);
    return '${safe.isEmpty ? 'mangatan-mining' : safe}.$extension';
  }

  static String _soundFilename(String value) {
    return value.replaceAll(']', '_');
  }

  static String _escape(String value) {
    return const HtmlEscape(HtmlEscapeMode.element).convert(value);
  }

  static String _normalizeFieldName(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), '');

  static final _markerPattern = RegExp(r'\{([^{}]+)\}');

  static const _absoluteScreenshotUploadBytes = 8 * 1024 * 1024;
  static const _maxScreenshotDimension = 1280;

  static String _extensionForImage(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return 'jpg';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    return 'png';
  }
}

Uint8List? _compressScreenshot(Uint8List bytes) {
  try {
    final decoded = image.decodeImage(bytes);
    if (decoded == null) return null;
    final longest = decoded.width > decoded.height
        ? decoded.width
        : decoded.height;
    final resized = longest > AnkiCardBuilder._maxScreenshotDimension
        ? image.copyResize(
            decoded,
            width: decoded.width >= decoded.height
                ? AnkiCardBuilder._maxScreenshotDimension
                : null,
            height: decoded.height > decoded.width
                ? AnkiCardBuilder._maxScreenshotDimension
                : null,
            interpolation: image.Interpolation.average,
          )
        : decoded;
    return Uint8List.fromList(image.encodeJpg(resized, quality: 82));
  } catch (_) {
    return null;
  }
}

class _ScreenshotPayload {
  const _ScreenshotPayload(this.bytes, this.extension)
    : filename = null,
      preparation = null;

  _ScreenshotPayload.fromPreparation(AnkiScreenshotPreparation preparation)
    : preparation = preparation,
      bytes = null,
      extension = 'avif',
      filename = preparation.filename;

  final Uint8List? bytes;
  final String extension;
  final String? filename;
  final AnkiScreenshotPreparation? preparation;
}
