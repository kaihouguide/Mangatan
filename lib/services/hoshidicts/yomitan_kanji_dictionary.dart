import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:mangayomi/src/rust/api/hoshidicts.dart';
import 'package:path/path.dart' as p;

const yomitanKanjiDataFileName = '.mangatan-kanji.json';
const yomitanKanjiContentType = 'mangatan-yomitan-kanji-v1';

/// Rejects a dictionary whose `index.json` title cannot be used as a single
/// directory name.
///
/// The native importer stores a dictionary at `outputDir/title`, so a title
/// such as `../x` would place files outside the dictionary folder. Archives
/// without a readable title are left for the importer to report.
Future<void> ensureYomitanDictionaryTitleIsSafe(String zipPath) async {
  final input = InputFileStream(zipPath);
  try {
    final archive = ZipDecoder().decodeStream(input);
    ArchiveFile? indexFile;
    for (final file in archive.files) {
      if (file.isFile && file.name.replaceAll('\\', '/') == 'index.json') {
        indexFile = file;
        break;
      }
    }
    if (indexFile == null) return;
    final Object? index;
    try {
      index = jsonDecode(utf8.decode(indexFile.content));
    } on FormatException {
      return;
    }
    final title = index is Map ? index['title'] : null;
    if (title is! String) return;
    if (title.trim().isEmpty ||
        title == '.' ||
        title == '..' ||
        title.contains('/') ||
        title.contains('\\') ||
        title.contains('\u0000') ||
        // On Windows a drive prefix makes the joined path leave outputDir.
        RegExp(r'^[A-Za-z]:').hasMatch(title)) {
      throw FormatException(
        'Dictionary title "$title" cannot be used as a folder name.',
      );
    }
  } finally {
    await input.close();
  }
}

class DictionaryImportResult {
  const DictionaryImportResult({
    required this.success,
    required this.title,
    required this.termCount,
    required this.metaCount,
    required this.freqCount,
    required this.pitchCount,
    required this.mediaCount,
    required this.kanjiCount,
    required this.errors,
  });

  factory DictionaryImportResult.fromHoshi(
    HoshiImportResult result, {
    BigInt? kanjiCount,
  }) {
    return DictionaryImportResult(
      success: result.success,
      title: result.title,
      termCount: result.termCount,
      metaCount: result.metaCount,
      freqCount: result.freqCount,
      pitchCount: result.pitchCount,
      mediaCount: result.mediaCount,
      kanjiCount: kanjiCount ?? BigInt.zero,
      errors: result.errors,
    );
  }

  final bool success;
  final String title;
  final BigInt termCount;
  final BigInt metaCount;
  final BigInt freqCount;
  final BigInt pitchCount;
  final BigInt mediaCount;
  final BigInt kanjiCount;
  final List<String> errors;
}

class YomitanKanjiArchive {
  const YomitanKanjiArchive({
    required this.title,
    required this.index,
    required this.entries,
    required this.frequencies,
    required this.hasNativeBanks,
  });

  final String title;
  final Map<String, dynamic> index;
  final List<Map<String, dynamic>> entries;
  final List<Map<String, dynamic>> frequencies;
  final bool hasNativeBanks;

  String get storageName => _safeFileName(title);

  static Future<YomitanKanjiArchive?> read(String zipPath) async {
    // Keep large dictionaries on disk. Reading the whole ZIP before handing
    // the same file to the native term importer doubles peak memory during a
    // batch import and can make the native iostream fail on later files.
    final input = InputFileStream(zipPath);
    try {
      final archive = ZipDecoder().decodeStream(input, verify: true);
      final files = <String, ArchiveFile>{
        for (final file in archive.files)
          if (file.isFile) file.name.replaceAll('\\', '/'): file,
      };
      final indexFile = files['index.json'];
      if (indexFile == null) return null;
      final index = _decodeObject(indexFile);
      final title = index['title'];
      if (title is! String || title.trim().isEmpty) {
        throw const FormatException('Dictionary index.json has no title.');
      }
      final kanjiFiles =
          files.entries
              .where(
                (entry) =>
                    RegExp(r'(^|/)kanji_bank_\d+\.json$').hasMatch(entry.key),
              )
              .toList()
            ..sort((a, b) => _bankNumber(a.key).compareTo(_bankNumber(b.key)));
      final kanjiMetaFiles =
          files.entries
              .where(
                (entry) => RegExp(
                  r'(^|/)kanji_meta_bank_\d+\.json$',
                ).hasMatch(entry.key),
              )
              .toList()
            ..sort((a, b) => _bankNumber(a.key).compareTo(_bankNumber(b.key)));
      if (kanjiFiles.isEmpty && kanjiMetaFiles.isEmpty) return null;

      final tags = <String, Map<String, dynamic>>{};
      final legacyTags = index['tagMeta'];
      if (legacyTags is Map) {
        for (final entry in legacyTags.entries) {
          if (entry.key is! String || entry.value is! Map) continue;
          final value = entry.value as Map;
          tags[entry.key as String] = {
            'name': entry.key,
            'category': value['category'] is String ? value['category'] : '',
            'order': value['order'] is num ? value['order'] : 0,
            'notes': value['notes'] is String ? value['notes'] : '',
            'score': value['score'] is num ? value['score'] : 0,
          };
        }
      }
      final tagFiles =
          files.entries
              .where(
                (entry) =>
                    RegExp(r'(^|/)tag_bank_\d+\.json$').hasMatch(entry.key),
              )
              .toList()
            ..sort((a, b) => _bankNumber(a.key).compareTo(_bankNumber(b.key)));
      for (final file in tagFiles) {
        for (final raw in _decodeList(file.value)) {
          if (raw is! List || raw.length < 5 || raw[0] is! String) continue;
          tags[raw[0] as String] = {
            'name': raw[0],
            'category': raw[1] is String ? raw[1] : '',
            'order': raw[2] is num ? raw[2] : 0,
            'notes': raw[3] is String ? raw[3] : '',
            'score': raw[4] is num ? raw[4] : 0,
          };
        }
      }

      final version = index['format'] ?? index['version'];
      final entries = <Map<String, dynamic>>[];
      for (final file in kanjiFiles) {
        for (final raw in _decodeList(file.value)) {
          final normalized = _normalizeEntry(raw, tags, version);
          if (normalized != null) entries.add(normalized);
        }
      }
      final frequencies = <Map<String, dynamic>>[];
      for (final file in kanjiMetaFiles) {
        for (final raw in _decodeList(file.value)) {
          if (raw is! List ||
              raw.length != 3 ||
              raw[0] is! String ||
              raw[1] != 'freq') {
            continue;
          }
          final data = raw[2];
          final value = data is Map ? data['value'] : data;
          final displayValue = data is Map ? data['displayValue'] : null;
          if (value is! num && value is! String) continue;
          frequencies.add({
            'character': raw[0],
            'value': value,
            if (displayValue is String) 'displayValue': displayValue,
          });
        }
      }
      final hasNativeBanks = files.keys.any(
        (name) =>
            RegExp(r'(^|/)term_bank_\d+\.json$').hasMatch(name) ||
            RegExp(r'(^|/)term_meta_bank_\d+\.json$').hasMatch(name),
      );
      return YomitanKanjiArchive(
        title: title,
        index: index,
        entries: entries,
        frequencies: frequencies,
        hasNativeBanks: hasNativeBanks,
      );
    } finally {
      await input.close();
    }
  }

  Future<void> persist(String outputDir) async {
    final directory = Directory(p.join(outputDir, storageName));
    await directory.create(recursive: true);
    await File(
      p.join(directory.path, 'index.json'),
    ).writeAsString(jsonEncode(index));
    await File(p.join(directory.path, yomitanKanjiDataFileName)).writeAsString(
      jsonEncode({
        'version': 1,
        'title': title,
        'entries': entries,
        'frequencies': frequencies,
      }),
    );
  }

  static Map<String, dynamic>? _normalizeEntry(
    dynamic raw,
    Map<String, Map<String, dynamic>> tags,
    dynamic version,
  ) {
    if (raw is! List || raw.length < 5 || raw[0] is! String) return null;
    final character = raw[0] as String;
    if (character.isEmpty) return null;
    final meanings = version == 1
        ? raw.sublist(4).whereType<String>().toList()
        : _meaningValues(raw[4]);
    final stats = raw.length > 5 && raw[5] is Map ? raw[5] as Map : const {};
    final statGroups = <String, List<Map<String, dynamic>>>{};
    for (final stat in stats.entries) {
      final name = stat.key.toString();
      final metadata = tags[name];
      if (metadata == null) continue;
      final category = metadata['category'] as String;
      (statGroups[category] ??= []).add({
        'name': name,
        'content': (metadata['notes'] as String).trim().isEmpty
            ? name
            : metadata['notes'],
        'value': stat.value.toString(),
        'order': metadata['order'],
      });
    }
    for (final group in statGroups.values) {
      group.sort((a, b) {
        final order = (a['order'] as num).compareTo(b['order'] as num);
        return order != 0
            ? order
            : (a['content'] as String).compareTo(b['content'] as String);
      });
    }
    final entryTags = <Map<String, dynamic>>[];
    for (final name in _splitTags(raw[3])) {
      final metadata = tags[name];
      entryTags.add({
        'name': name,
        'content':
            metadata == null || (metadata['notes'] as String).trim().isEmpty
            ? name
            : metadata['notes'],
        'category': metadata?['category'] ?? '',
        'order': metadata?['order'] ?? 0,
        'score': metadata?['score'] ?? 0,
      });
    }
    entryTags.sort((a, b) => (a['order'] as num).compareTo(b['order'] as num));
    return {
      'character': character,
      'onyomi': _splitReadings(raw[1]),
      'kunyomi': _splitReadings(raw[2]),
      'tags': entryTags,
      'definitions': meanings,
      'stats': statGroups,
    };
  }

  static List<String> _meaningValues(dynamic value) {
    // Some widely distributed dictionaries were generated from Go structs
    // and encode []string as {"value": [...], "Count": n}.
    if (value is Map) value = value['value'];
    if (value is! List) return const [];
    return [
      for (final item in value)
        if (item is String) item,
    ];
  }

  static List<String> _splitReadings(dynamic value) => value is String
      ? value.split(' ').where((v) => v.isNotEmpty).toList()
      : [];

  static List<String> _splitTags(dynamic value) => value is String
      ? value.split(' ').where((v) => v.isNotEmpty).toList()
      : [];

  static int _bankNumber(String name) =>
      int.tryParse(RegExp(r'_(\d+)\.json$').firstMatch(name)?.group(1) ?? '') ??
      0;

  static Map<String, dynamic> _decodeObject(ArchiveFile file) {
    final decoded = jsonDecode(utf8.decode(_bytes(file)));
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('${file.name} is not a JSON object.');
    }
    return decoded;
  }

  static List<dynamic> _decodeList(ArchiveFile file) {
    final decoded = jsonDecode(utf8.decode(_bytes(file)));
    if (decoded is! List) {
      throw FormatException('${file.name} is not a JSON array.');
    }
    return decoded;
  }

  static Uint8List _bytes(ArchiveFile file) => file.content;

  static String _safeFileName(String title) {
    const replacements = {
      '<': '＜',
      '>': '＞',
      ':': '：',
      '"': '＂',
      '/': '／',
      r'\': '＼',
      '|': '｜',
      '?': '？',
      '*': '＊',
    };
    var result = title
        .split('')
        .map(
          (character) =>
              replacements[character] ??
              (character.codeUnitAt(0) < 32 ? '�' : character),
        )
        .join()
        .trim();
    while (result.endsWith('.')) {
      result = '${result.substring(0, result.length - 1)}．';
    }
    if (result.isEmpty || result == '.' || result == '..') {
      result = 'Yomitan Kanji Dictionary';
    }
    if (RegExp(
      r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)',
      caseSensitive: false,
    ).hasMatch(result)) {
      result = '_$result';
    }
    return result;
  }
}

class YomitanKanjiStore {
  List<_KanjiDictionary> _dictionaries = const [];

  Future<void> configure(List<String> paths) async {
    final dictionaries = <_KanjiDictionary>[];
    for (final path in paths) {
      final file = File(p.join(path, yomitanKanjiDataFileName));
      if (!await file.exists()) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(await file.readAsString());
      } on FormatException {
        // One damaged dictionary must not disable the others.
        continue;
      }
      if (decoded is! Map<String, dynamic> ||
          decoded['title'] is! String ||
          decoded['entries'] is! List) {
        continue;
      }
      dictionaries.add(
        _KanjiDictionary(
          decoded['title'] as String,
          (decoded['entries'] as List)
              .whereType<Map>()
              .map((entry) => Map<String, dynamic>.from(entry))
              .toList(),
          (decoded['frequencies'] as List? ?? const [])
              .whereType<Map>()
              .map((entry) => Map<String, dynamic>.from(entry))
              .toList(),
        ),
      );
    }
    _dictionaries = dictionaries;
  }

  List<HoshiLookupResult> lookup(String text) {
    final unique = <String>{};
    for (final rune in text.runes) {
      unique.add(String.fromCharCode(rune));
    }
    final results = <HoshiLookupResult>[];
    for (final character in unique) {
      final frequencies = [
        for (final dictionary in _dictionaries)
          for (final frequency in dictionary.frequencies[character] ?? const [])
            {'dictionary': dictionary.title, ...frequency},
      ];
      for (final dictionary in _dictionaries) {
        for (final entry in dictionary.entries[character] ?? const []) {
          final content = jsonEncode({
            'type': yomitanKanjiContentType,
            'dictionary': dictionary.title,
            'frequencies': frequencies,
            ...entry,
          });
          results.add(
            HoshiLookupResult(
              matched: character,
              deinflected: character,
              trace: const [],
              preprocessorSteps: 0,
              term: HoshiTermResult(
                expression: character,
                reading: '',
                rules: '',
                score: 0,
                glossaries: [
                  HoshiGlossaryEntry(
                    dictName: dictionary.title,
                    glossary: content,
                    definitionTags: '',
                    termTags: '',
                  ),
                ],
                frequencies: const [],
                pitches: const [],
              ),
            ),
          );
        }
      }
    }
    return results;
  }
}

class _KanjiDictionary {
  _KanjiDictionary(
    this.title,
    List<Map<String, dynamic>> source,
    List<Map<String, dynamic>> frequencySource,
  ) {
    for (final entry in source) {
      final character = entry['character'];
      if (character is String) (entries[character] ??= []).add(entry);
    }
    for (final frequency in frequencySource) {
      final character = frequency['character'];
      if (character is String) {
        (frequencies[character] ??= []).add(frequency);
      }
    }
  }

  final String title;
  final Map<String, List<Map<String, dynamic>>> entries = {};
  final Map<String, List<Map<String, dynamic>>> frequencies = {};
}
