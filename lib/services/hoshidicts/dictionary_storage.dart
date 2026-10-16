import 'dart:convert';
import 'dart:io';

import 'package:mangayomi/services/hoshidicts/yomitan_kanji_dictionary.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class DictionaryPaths {
  final List<String> termPaths;
  final List<String> frequencyPaths;
  final List<String> pitchPaths;
  final List<String> kanjiPaths;

  const DictionaryPaths({
    this.termPaths = const [],
    this.frequencyPaths = const [],
    this.pitchPaths = const [],
    this.kanjiPaths = const [],
  });
}

class InstalledDictionary {
  final String name;
  final String displayName;
  final bool hasTerms;
  final bool hasFrequencies;
  final bool hasPitch;
  final bool hasKanji;
  final String? revision;
  final bool isUpdatable;
  final String? indexUrl;
  final String? downloadUrl;

  const InstalledDictionary({
    required this.name,
    String? displayName,
    required this.hasTerms,
    required this.hasFrequencies,
    required this.hasPitch,
    this.hasKanji = false,
    this.revision,
    this.isUpdatable = false,
    this.indexUrl,
    this.downloadUrl,
  }) : displayName = displayName ?? name;
}

class DictionaryStorage {
  DictionaryStorage._();

  static final DictionaryStorage instance = DictionaryStorage._();

  Future<Directory> get rootDirectory async {
    final support = await getApplicationSupportDirectory();
    final root = Directory(p.join(support.path, 'dictionaries'));
    await root.create(recursive: true);
    return root;
  }

  static const _manifestName = '.mangayomi-dictionaries.json';

  Future<DictionaryPaths> paths({
    Directory? root,
    List<String> order = const [],
    Set<String> enabled = const {},
  }) async {
    final directory = root ?? await rootDirectory;
    final installed = await _installedFromRoot(directory);
    final dictionaries = _applyProfileOrder(installed, order)
        .where(
          (dictionary) => enabled.isEmpty || enabled.contains(dictionary.name),
        )
        .toList(growable: false);
    return DictionaryPaths(
      termPaths: [
        for (final dictionary in dictionaries)
          if (dictionary.hasTerms) p.join(directory.path, dictionary.name),
      ],
      frequencyPaths: [
        for (final dictionary in dictionaries)
          if (dictionary.hasFrequencies)
            p.join(directory.path, dictionary.name),
      ],
      pitchPaths: [
        for (final dictionary in dictionaries)
          if (dictionary.hasPitch) p.join(directory.path, dictionary.name),
      ],
      kanjiPaths: [
        for (final dictionary in dictionaries)
          if (dictionary.hasKanji) p.join(directory.path, dictionary.name),
      ],
    );
  }

  Future<List<InstalledDictionary>> installed({
    Directory? root,
    List<String> order = const [],
  }) async {
    final dictionaries = await _installedFromRoot(root ?? await rootDirectory);
    return _applyProfileOrder(dictionaries, order);
  }

  /// Lists dictionaries without creating the application-support directory.
  ///
  /// Diagnostics and other dry-run projections use this path so observing an
  /// otherwise pristine profile cannot become a filesystem mutation. Normal
  /// callers should continue using [installed], whose create-on-first-use
  /// behavior is retained for imports and interactive dictionary features.
  Future<List<InstalledDictionary>> installedReadOnly({
    Directory? root,
    List<String> order = const [],
  }) async {
    final directory =
        root ??
        Directory(
          p.join((await getApplicationSupportDirectory()).path, 'dictionaries'),
        );
    final dictionaries = await _installedFromRoot(directory);
    return _applyProfileOrder(dictionaries, order);
  }

  Future<void> recordImport({
    required String name,
    required BigInt termCount,
    required BigInt frequencyCount,
    required BigInt pitchCount,
    BigInt? kanjiCount,
    Directory? root,
  }) async {
    final directory = root ?? await rootDirectory;
    final manifest = await _readManifest(directory);
    final names = await _dictionaryNames(directory);
    // Re-importing or updating a dictionary replaces its data in place: it
    // keeps the priority and display name the user gave it. Only a new
    // dictionary goes to the end.
    final previous = manifest[name];
    final orderedNames = _orderedNames(names, manifest);
    final preferredOrder = previous?['order'] is int
        ? orderedNames
        : [
            for (final dictionaryName in orderedNames)
              if (dictionaryName != name) dictionaryName,
            name,
          ];
    manifest[name] = {
      'terms': termCount > BigInt.zero,
      'frequencies': frequencyCount > BigInt.zero,
      'pitch': pitchCount > BigInt.zero,
      'kanji': (kanjiCount ?? BigInt.zero) > BigInt.zero,
      if (previous?['displayName'] case final String displayName)
        'displayName': displayName,
    };
    _writeOrder(manifest, names, preferredOrder);
    await _writeManifest(directory, manifest);
  }

  Future<void> delete(String name, {Directory? root}) async {
    final rootDirectory = root ?? await this.rootDirectory;
    final dictionaryDirectory = Directory(p.join(rootDirectory.path, name));
    if (await dictionaryDirectory.exists()) {
      await dictionaryDirectory.delete(recursive: true);
    }
    final manifest = await _readManifest(rootDirectory);
    if (manifest.remove(name) != null) {
      final names = await _dictionaryNames(rootDirectory);
      _writeOrder(manifest, names, _orderedNames(names, manifest));
      await _writeManifest(rootDirectory, manifest);
    }
  }

  Future<void> reorder(List<String> names, {Directory? root}) async {
    final directory = root ?? await rootDirectory;
    final manifest = await _readManifest(directory);
    final installedNames = await _dictionaryNames(directory);
    _writeOrder(manifest, installedNames, names);
    await _writeManifest(directory, manifest);
  }

  Future<void> renameDisplayName(
    String name,
    String displayName, {
    Directory? root,
  }) async {
    final value = displayName.trim();
    if (value.isEmpty) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        'Must not be empty',
      );
    }
    final directory = root ?? await rootDirectory;
    final names = await _dictionaryNames(directory);
    if (!names.contains(name)) {
      throw StateError('Dictionary "$name" is not installed.');
    }
    final manifest = await _readManifest(directory);
    manifest.putIfAbsent(name, () => <String, dynamic>{})['displayName'] =
        value;
    _writeOrder(manifest, names, _orderedNames(names, manifest));
    await _writeManifest(directory, manifest);
  }

  Future<List<InstalledDictionary>> _installedFromRoot(Directory root) async {
    if (!await root.exists()) return const [];
    final manifest = await _readManifest(root);
    final directories = await root
        .list()
        .where((entity) => entity is Directory)
        .cast<Directory>()
        .toList();
    directories.removeWhere((directory) {
      final name = p.basename(directory.path);
      return const {'term', 'frequency', 'pitch'}.contains(name) ||
          !File(p.join(directory.path, 'index.json')).existsSync();
    });
    final orderedNames = _orderedNames(
      directories.map((directory) => p.basename(directory.path)).toList(),
      manifest,
    );
    final orderByName = {
      for (final indexed in orderedNames.indexed) indexed.$2: indexed.$1,
    };
    directories.sort((a, b) {
      return (orderByName[p.basename(a.path)] ?? 0).compareTo(
        orderByName[p.basename(b.path)] ?? 0,
      );
    });

    return [
      for (final directory in directories)
        _dictionaryFromMetadata(
          p.basename(directory.path),
          manifest[p.basename(directory.path)],
          directory,
        ),
    ];
  }

  List<InstalledDictionary> _applyProfileOrder(
    List<InstalledDictionary> dictionaries,
    List<String> preferredOrder,
  ) {
    if (preferredOrder.isEmpty) return dictionaries;
    final byName = {
      for (final dictionary in dictionaries) dictionary.name: dictionary,
    };
    return [
      for (final name in preferredOrder) ?byName.remove(name),
      for (final dictionary in dictionaries) ?byName.remove(dictionary.name),
    ];
  }

  InstalledDictionary _dictionaryFromMetadata(
    String name,
    Map<String, dynamic>? metadata,
    Directory directory,
  ) {
    // Imports made before the manifest was introduced are overwhelmingly term
    // dictionaries. This fallback also repairs existing JMdict installations.
    final hasKanjiMarker = File(
      p.join(directory.path, yomitanKanjiDataFileName),
    ).existsSync();
    final index = _readDictionaryIndex(directory);
    return InstalledDictionary(
      name: name,
      displayName:
          metadata?['displayName']?.toString() ?? index?['title']?.toString(),
      hasTerms: _flag(metadata?['terms']) ?? !hasKanjiMarker,
      hasFrequencies: _flag(metadata?['frequencies']) ?? false,
      hasPitch: _flag(metadata?['pitch']) ?? false,
      hasKanji: _flag(metadata?['kanji']) ?? hasKanjiMarker,
      revision: index?['revision']?.toString(),
      // index.json comes from the imported archive; a non-boolean value must
      // not make the whole dictionary list unreadable.
      isUpdatable: _flag(index?['isUpdatable']) ?? false,
      indexUrl: index?['indexUrl']?.toString(),
      downloadUrl: index?['downloadUrl']?.toString(),
    );
  }

  static bool? _flag(Object? value) => value is bool ? value : null;

  Map<String, dynamic>? _readDictionaryIndex(Directory directory) {
    final file = File(p.join(directory.path, 'index.json'));
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  Future<List<String>> _dictionaryNames(Directory root) async {
    if (!await root.exists()) return const [];
    final directories = await root
        .list()
        .where((entity) => entity is Directory)
        .cast<Directory>()
        .toList();
    final names = <String>[];
    for (final directory in directories) {
      final name = p.basename(directory.path);
      if (const {'term', 'frequency', 'pitch'}.contains(name)) continue;
      if (!File(p.join(directory.path, 'index.json')).existsSync()) continue;
      names.add(name);
    }
    names.sort();
    return names;
  }

  List<String> _orderedNames(
    List<String> names,
    Map<String, Map<String, dynamic>> manifest,
  ) {
    final fallback = [...names]..sort();
    final fallbackIndex = {
      for (final indexed in fallback.indexed) indexed.$2: indexed.$1,
    };
    final ordered = [...names];
    ordered.sort((a, b) {
      final aOrder = manifest[a]?['order'];
      final bOrder = manifest[b]?['order'];
      if (aOrder is int && bOrder is int && aOrder != bOrder) {
        return aOrder.compareTo(bOrder);
      }
      if (aOrder is int && bOrder is! int) return -1;
      if (aOrder is! int && bOrder is int) return 1;
      return (fallbackIndex[a] ?? 0).compareTo(fallbackIndex[b] ?? 0);
    });
    return ordered;
  }

  void _writeOrder(
    Map<String, Map<String, dynamic>> manifest,
    List<String> installedNames,
    List<String> preferredOrder,
  ) {
    final installed = installedNames.toSet();
    final ordered = <String>[];
    for (final name in preferredOrder) {
      if (installed.contains(name) && !ordered.contains(name)) {
        ordered.add(name);
      }
    }
    for (final name in installedNames) {
      if (!ordered.contains(name)) ordered.add(name);
    }
    for (final indexed in ordered.indexed) {
      manifest.putIfAbsent(indexed.$2, () => <String, dynamic>{})['order'] =
          indexed.$1;
    }
  }

  Future<Map<String, Map<String, dynamic>>> _readManifest(
    Directory root,
  ) async {
    final file = File(p.join(root.path, _manifestName));
    if (!await file.exists()) return {};
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return {};
      return decoded.map(
        (key, value) => MapEntry(
          key,
          value is Map<String, dynamic> ? value : <String, dynamic>{},
        ),
      );
    } on FormatException {
      return {};
    }
  }

  Future<void> _writeManifest(
    Directory root,
    Map<String, Map<String, dynamic>> manifest,
  ) async {
    await root.create(recursive: true);
    // Write beside the manifest and rename over it, so an interrupted write
    // cannot leave a truncated file that reads back as an empty manifest.
    final target = p.join(root.path, _manifestName);
    final temporary = File('$target.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest),
      flush: true,
    );
    await temporary.rename(target);
  }
}
