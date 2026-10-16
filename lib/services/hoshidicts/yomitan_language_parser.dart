import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:mangayomi/services/hoshidicts/dictionary_languages.dart';
import 'package:mangayomi/src/rust/api/hoshidicts.dart';

class YomitanLanguageParser {
  YomitanLanguageParser({AssetBundle? assetBundle})
    : _assetBundle = assetBundle ?? rootBundle;

  final AssetBundle _assetBundle;
  QuickJsRuntime2? _runtime;
  Future<void>? _initializing;
  final Set<String> _loadedTransformAssets = {};

  static const _transformAssets = <String, String>{
    'ar': 'ar',
    'arz': 'ar',
    'de': 'de',
    'el': 'el',
    'en': 'en',
    'eo': 'eo',
    'es': 'es',
    'eu': 'eu',
    'fr': 'fr',
    'ga': 'ga',
    'grc': 'grc',
    'ka': 'ka',
    'ko': 'ko',
    'la': 'la',
    'sga': 'sga',
    'sq': 'sq',
    'tl': 'tl',
    'yi': 'yi',
  };

  Future<List<YomitanLookupCandidate>> candidates(
    String language,
    String text, {
    int scanLength = 20,
    int maxCandidates = 48,
  }) async {
    if (language == 'ja' ||
        !supportedDictionaryLanguageCodes.contains(language) ||
        text.trim().isEmpty) {
      return const [];
    }
    try {
      await _ensureInitialized();
      await _ensureTransforms(language);
      final runtime = _runtime;
      if (runtime == null) return const [];
      final result = runtime.evaluate(
        'mangatanYomitanCandidatesJson('
        '${jsonEncode(language)},${jsonEncode(text)},$scanLength,$maxCandidates)',
      );
      if (result.isError) return const [];
      final decoded = jsonDecode(result.rawResult as String) as List<dynamic>;
      return decoded
          .whereType<Map<dynamic, dynamic>>()
          .map(YomitanLookupCandidate.fromJson)
          .where((candidate) => candidate.lemma.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      // Direct dictionary lookup remains available if the optional language
      // rule runtime cannot initialize on a platform.
      return const [];
    }
  }

  Future<void> _ensureInitialized() async {
    if (_runtime != null) return;
    final pending = _initializing;
    if (pending != null) return pending;
    late final Future<void> initialization;
    initialization = _initialize().whenComplete(() {
      if (identical(_initializing, initialization)) _initializing = null;
    });
    _initializing = initialization;
    return initialization;
  }

  Future<void> _initialize() async {
    final source = await _assetBundle.loadString(
      'assets/yomitan_language_bundle.js',
    );
    final runtime = QuickJsRuntime2(stackSize: 4 * 1024 * 1024);
    final result = runtime.evaluate(source, name: 'yomitan_language_bundle.js');
    if (result.isError) {
      runtime.dispose();
      throw StateError(result.stringResult);
    }
    _runtime = runtime;
  }

  Future<void> _ensureTransforms(String language) async {
    final assetName = _transformAssets[language];
    if (assetName == null || _loadedTransformAssets.contains(assetName)) {
      return;
    }
    final runtime = _runtime;
    if (runtime == null) return;
    final source = await _assetBundle.loadString(
      'assets/yomitan_transforms/$assetName.js',
    );
    final result = runtime.evaluate(
      source,
      name: 'yomitan_transforms/$assetName.js',
    );
    if (result.isError) throw StateError(result.stringResult);
    _loadedTransformAssets.add(assetName);
  }

  void dispose() {
    _runtime?.dispose();
    _runtime = null;
    _initializing = null;
    _loadedTransformAssets.clear();
  }
}

class YomitanLookupCandidate {
  const YomitanLookupCandidate({
    required this.surface,
    required this.lemma,
    required this.trace,
    required this.priority,
  });

  factory YomitanLookupCandidate.fromJson(Map<dynamic, dynamic> json) {
    final traceJson = json['trace'];
    return YomitanLookupCandidate(
      surface: json['surface'] as String? ?? '',
      lemma: json['lemma'] as String? ?? '',
      trace: traceJson is List
          ? traceJson
                .whereType<Map<dynamic, dynamic>>()
                .map(YomitanTransform.fromJson)
                .toList(growable: false)
          : const [],
      priority: (json['priority'] as num?)?.toInt() ?? 0,
    );
  }

  final String surface;
  final String lemma;
  final List<YomitanTransform> trace;
  final int priority;
}

class YomitanTransform {
  const YomitanTransform(this.name, this.description);

  factory YomitanTransform.fromJson(Map<dynamic, dynamic> json) =>
      YomitanTransform(
        json['name'] as String? ?? '',
        json['description'] as String? ?? '',
      );

  final String name;
  final String description;
}

typedef YomitanLookupCallback = Future<List<HoshiLookupResult>> Function(
  String text,
  int maxResults,
  int scanLength,
);

typedef YomitanCandidateLoader = Future<List<YomitanLookupCandidate>> Function(
  String language,
  String text,
  int scanLength,
  int maxCandidates,
);

Future<List<HoshiLookupResult>> lookupYomitanDictionary({
  required String language,
  required String text,
  required int maxResults,
  required int scanLength,
  required YomitanLookupCallback lookup,
  required YomitanCandidateLoader loadCandidates,
}) async {
  final direct = await lookup(text, maxResults, scanLength);
  final tokenLength = _leadingWordLength(text, scanLength);
  final exactDirect = tokenLength == 0
      ? direct
      : direct.where((result) => result.matched.runes.length == tokenLength);
  final shorterDirect = tokenLength == 0
      ? const <HoshiLookupResult>[]
      : direct.where((result) => result.matched.runes.length != tokenLength);
  final merged = <String, HoshiLookupResult>{};
  for (final result in exactDirect) {
    merged[_resultKey(result)] = result;
  }

  final candidates = await loadCandidates(
    language,
    text,
    scanLength,
    (maxResults * 6).clamp(24, 64),
  );
  for (final candidate in candidates) {
    if (merged.length >= maxResults) break;
    final results = await lookup(
      candidate.lemma,
      maxResults - merged.length,
      candidate.lemma.runes.length,
    );
    for (final result in results) {
      if (result.matched.runes.length != candidate.lemma.runes.length) {
        continue;
      }
      merged.putIfAbsent(
        _resultKey(result),
        () => HoshiLookupResult(
          matched: candidate.surface,
          deinflected: result.deinflected,
          trace: [
            for (final transform in candidate.trace)
              if (!_isInternalYomitanTrace(transform))
                HoshiTransformGroup(
                  name: '${dictionaryLanguageName(language)} ${transform.name}',
                  description: transform.description,
                ),
            ...result.trace,
          ],
          preprocessorSteps: result.preprocessorSteps,
          term: result.term,
        ),
      );
      if (merged.length >= maxResults) break;
    }
  }
  for (final result in shorterDirect) {
    if (merged.length >= maxResults) break;
    merged.putIfAbsent(_resultKey(result), () => result);
  }
  return List.unmodifiable(merged.values.take(maxResults));
}

String _resultKey(HoshiLookupResult result) =>
    '${result.term.expression}\u0000${result.term.reading}';

int _leadingWordLength(String text, int scanLength) {
  var length = 0;
  for (final rune in text.trimLeft().runes) {
    if (length >= scanLength || !_isWordRune(rune)) break;
    length++;
  }
  return length;
}

final _wordCharacterPattern = RegExp(r'[\p{L}\p{N}\p{M}]', unicode: true);

bool _isWordRune(int rune) {
  if (rune == 0x27 || rune == 0x2019) return true;
  return _wordCharacterPattern.hasMatch(String.fromCharCode(rune));
}

bool _isInternalYomitanTrace(YomitanTransform transform) {
  switch (transform.name) {
    case 'Disassemble Hangul':
    case 'Reassemble Hangul':
      return true;
    default:
      return false;
  }
}
