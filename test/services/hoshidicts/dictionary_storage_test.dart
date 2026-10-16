import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/services/hoshidicts/dictionary_storage.dart';
import 'package:mangayomi/services/hoshidicts/yomitan_kanji_dictionary.dart';
import 'package:path/path.dart' as p;

void main() {
  test('read-only listing does not create a missing root', () async {
    final parent = await Directory.systemTemp.createTemp('dictionary-storage-');
    addTearDown(() => parent.delete(recursive: true));
    final missingRoot = Directory(p.join(parent.path, 'dictionaries'));

    final installed = await DictionaryStorage.instance.installedReadOnly(
      root: missingRoot,
    );

    expect(installed, isEmpty);
    expect(await missingRoot.exists(), isFalse);
  });

  test(
    'finds existing Hoshidicts imports in the flat output directory',
    () async {
      final root = await Directory.systemTemp.createTemp('dictionary-storage-');
      addTearDown(() => root.delete(recursive: true));
      final dictionary = Directory(p.join(root.path, 'JMdict [test]'));
      await dictionary.create();
      await File(p.join(dictionary.path, 'index.json')).writeAsString('{}');

      final paths = await DictionaryStorage.instance.paths(root: root);
      final installed = await DictionaryStorage.instance.installed(root: root);

      expect(paths.termPaths, [dictionary.path]);
      expect(paths.frequencyPaths, isEmpty);
      expect(installed.single.name, 'JMdict [test]');
      expect(installed.single.hasTerms, isTrue);
    },
  );

  test('uses persisted import capabilities for flat dictionaries', () async {
    final root = await Directory.systemTemp.createTemp('dictionary-storage-');
    addTearDown(() => root.delete(recursive: true));
    final dictionary = Directory(p.join(root.path, 'Frequency'));
    await dictionary.create();
    await File(p.join(dictionary.path, 'index.json')).writeAsString('{}');
    await File(p.join(root.path, '.mangayomi-dictionaries.json')).writeAsString(
      '{"Frequency":{"terms":false,"frequencies":true,"pitch":false}}',
    );

    final paths = await DictionaryStorage.instance.paths(root: root);

    expect(paths.termPaths, isEmpty);
    expect(paths.frequencyPaths, [dictionary.path]);
  });

  test('routes Kanji-only dictionaries outside the term query', () async {
    final root = await Directory.systemTemp.createTemp('dictionary-storage-');
    addTearDown(() => root.delete(recursive: true));
    final dictionary = await _createDictionary(root, 'Kanji');
    await File(
      p.join(dictionary.path, yomitanKanjiDataFileName),
    ).writeAsString('{}');

    await DictionaryStorage.instance.recordImport(
      name: 'Kanji',
      termCount: BigInt.zero,
      frequencyCount: BigInt.zero,
      pitchCount: BigInt.zero,
      kanjiCount: BigInt.one,
      root: root,
    );

    final paths = await DictionaryStorage.instance.paths(root: root);
    final installed = await DictionaryStorage.instance.installed(root: root);

    expect(paths.termPaths, isEmpty);
    expect(paths.kanjiPaths, [dictionary.path]);
    expect(installed.single.hasKanji, isTrue);
  });

  test('orders installed dictionaries from persisted manifest order', () async {
    final root = await Directory.systemTemp.createTemp('dictionary-storage-');
    addTearDown(() => root.delete(recursive: true));
    final jmdict = await _createDictionary(root, 'JMdict');
    final frequency = await _createDictionary(root, 'Frequency');
    final pitch = await _createDictionary(root, 'Pitch');
    await File(p.join(root.path, '.mangayomi-dictionaries.json')).writeAsString(
      '{"JMdict":{"terms":true,"frequencies":false,"pitch":false,"order":1},'
      '"Frequency":{"terms":true,"frequencies":true,"pitch":false,"order":0},'
      '"Pitch":{"terms":true,"frequencies":false,"pitch":true,"order":2}}',
    );

    final installed = await DictionaryStorage.instance.installed(root: root);
    final paths = await DictionaryStorage.instance.paths(root: root);

    expect(installed.map((dictionary) => dictionary.name), [
      'Frequency',
      'JMdict',
      'Pitch',
    ]);
    expect(paths.termPaths, [frequency.path, jmdict.path, pitch.path]);
    expect(paths.frequencyPaths, [frequency.path]);
    expect(paths.pitchPaths, [pitch.path]);
  });

  test('reorders installed dictionaries and query paths', () async {
    final root = await Directory.systemTemp.createTemp('dictionary-storage-');
    addTearDown(() => root.delete(recursive: true));
    final alpha = await _createDictionary(root, 'Alpha');
    final beta = await _createDictionary(root, 'Beta');
    final gamma = await _createDictionary(root, 'Gamma');

    await DictionaryStorage.instance.reorder([
      'Gamma',
      'Alpha',
      'Beta',
    ], root: root);

    final installed = await DictionaryStorage.instance.installed(root: root);
    final paths = await DictionaryStorage.instance.paths(root: root);

    expect(installed.map((dictionary) => dictionary.name), [
      'Gamma',
      'Alpha',
      'Beta',
    ]);
    expect(paths.termPaths, [gamma.path, alpha.path, beta.path]);
  });

  test('appends newly imported dictionaries after the current order', () async {
    final root = await Directory.systemTemp.createTemp('dictionary-storage-');
    addTearDown(() => root.delete(recursive: true));
    await _createDictionary(root, 'Alpha');
    await _createDictionary(root, 'Beta');
    await DictionaryStorage.instance.reorder(['Beta', 'Alpha'], root: root);
    final gamma = await _createDictionary(root, 'Gamma');

    await DictionaryStorage.instance.recordImport(
      name: 'Gamma',
      termCount: BigInt.one,
      frequencyCount: BigInt.zero,
      pitchCount: BigInt.zero,
      root: root,
    );

    final installed = await DictionaryStorage.instance.installed(root: root);
    final paths = await DictionaryStorage.instance.paths(root: root);

    expect(installed.map((dictionary) => dictionary.name), [
      'Beta',
      'Alpha',
      'Gamma',
    ]);
    expect(paths.termPaths.last, gamma.path);
  });

  test(
    'reads update metadata and stores a safe display-name override',
    () async {
      final root = await Directory.systemTemp.createTemp('dictionary-storage-');
      addTearDown(() => root.delete(recursive: true));
      final dictionary = Directory(p.join(root.path, 'stable-storage-name'));
      await dictionary.create();
      await File(p.join(dictionary.path, 'index.json')).writeAsString(
        '{"title":"Original","revision":"3.2","isUpdatable":true,'
        '"indexUrl":"https://example.test/index.json",'
        '"downloadUrl":"https://example.test/dictionary.zip"}',
      );

      await DictionaryStorage.instance.renameDisplayName(
        'stable-storage-name',
        'My preferred name',
        root: root,
      );
      final installed = (await DictionaryStorage.instance.installed(
        root: root,
      )).single;

      expect(installed.name, 'stable-storage-name');
      expect(installed.displayName, 'My preferred name');
      expect(installed.revision, '3.2');
      expect(installed.isUpdatable, isTrue);
      expect(installed.indexUrl, 'https://example.test/index.json');
      expect(installed.downloadUrl, 'https://example.test/dictionary.zip');
      expect(await dictionary.exists(), isTrue);
    },
  );

  test('re-importing keeps the priority and display name', () async {
    final root = await Directory.systemTemp.createTemp('dictionary-storage-');
    addTearDown(() => root.delete(recursive: true));
    await _createDictionary(root, 'Alpha');
    await _createDictionary(root, 'Beta');
    await DictionaryStorage.instance.reorder(['Beta', 'Alpha'], root: root);
    await DictionaryStorage.instance.renameDisplayName(
      'Beta',
      'Preferred',
      root: root,
    );

    await DictionaryStorage.instance.recordImport(
      name: 'Beta',
      termCount: BigInt.one,
      frequencyCount: BigInt.zero,
      pitchCount: BigInt.zero,
      root: root,
    );

    final installed = await DictionaryStorage.instance.installed(root: root);
    expect(installed.map((dictionary) => dictionary.name), ['Beta', 'Alpha']);
    expect(installed.first.displayName, 'Preferred');
  });

  test(
    'applies profile order and enabled dictionaries without rewriting disk order',
    () async {
      final root = await Directory.systemTemp.createTemp('dictionary-storage-');
      addTearDown(() => root.delete(recursive: true));
      final alpha = await _createDictionary(root, 'Alpha');
      await _createDictionary(root, 'Beta');
      final gamma = await _createDictionary(root, 'Gamma');

      final installed = await DictionaryStorage.instance.installed(
        root: root,
        order: const ['Gamma', 'Alpha', 'Beta'],
      );
      final paths = await DictionaryStorage.instance.paths(
        root: root,
        order: const ['Gamma', 'Alpha', 'Beta'],
        enabled: const {'Gamma', 'Alpha'},
      );

      expect(installed.map((dictionary) => dictionary.name), [
        'Gamma',
        'Alpha',
        'Beta',
      ]);
      expect(paths.termPaths, [gamma.path, alpha.path]);
    },
  );
}

Future<Directory> _createDictionary(Directory root, String name) async {
  final dictionary = Directory(p.join(root.path, name));
  await dictionary.create();
  await File(p.join(dictionary.path, 'index.json')).writeAsString('{}');
  return dictionary;
}
