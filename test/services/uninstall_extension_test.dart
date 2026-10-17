import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/eval/model/source_preference.dart';
import 'package:mangayomi/main.dart' as app;
import 'package:mangayomi/models/changed.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/services/uninstall_extension.dart';

void main() {
  late Directory databaseDirectory;
  late Isar database;

  setUpAll(() async {
    await Isar.initializeIsarCore(
      libraries: {Abi.current(): await _isarLibraryPath()},
    );
  });

  setUp(() async {
    databaseDirectory = await Directory.systemTemp.createTemp(
      'mangatan-uninstall-extension-',
    );
    database = await Isar.open(
      [
        SourceSchema,
        SourcePreferenceSchema,
        SourcePreferenceStringValueSchema,
        ChangedPartSchema,
      ],
      directory: databaseDirectory.path,
      name: 'uninstall_extension_test',
    );
    app.isar = database;
  });

  tearDown(() async {
    await database.close(deleteFromDisk: true);
    if (await databaseDirectory.exists()) {
      await databaseDirectory.delete(recursive: true);
    }
  });

  test('records an obsolete removal in the uninstall transaction', () async {
    database.writeTxnSync(() {
      database.sources.putSync(
        Source(
          id: 7,
          name: 'Old source',
          sourceCode: 'code',
          itemType: ItemType.manga,
          isAdded: true,
        )..isObsolete = true,
      );
      database.sourcePreferenceStringValues.putSync(
        SourcePreferenceStringValue()
          ..sourceId = 7
          ..key = 'k'
          ..value = 'v',
      );
    });
    final source = database.sources.getSync(7)!;

    // putSync throws outside a write transaction, so this also proves the
    // change record is written atomically with the deletion.
    final result = await uninstallExtension(
      source,
      recordObsoleteRemoval: (sourceId) => database.changedParts.putSync(
        ChangedPart(
          actionType: ActionType.removeExtension,
          isarId: sourceId,
          data: '{}',
          clientDate: 0,
        ),
      ),
    );

    expect(result.removedObsoleteSourceIds, [7]);
    expect(database.sources.getSync(7), isNull);
    expect(database.sourcePreferenceStringValues.countSync(), 0);
    expect(database.changedParts.where().findAllSync().single.isarId, 7);
  });

  test('a current source is reset rather than deleted', () async {
    database.writeTxnSync(() {
      database.sources.putSync(
        Source(
          id: 8,
          name: 'Current source',
          sourceCode: 'code',
          itemType: ItemType.manga,
          isAdded: true,
          isPinned: true,
        ),
      );
    });
    var recorded = 0;

    final result = await uninstallExtension(
      database.sources.getSync(8)!,
      recordObsoleteRemoval: (_) => recorded++,
    );

    final stored = database.sources.getSync(8)!;
    expect(result.removedObsoleteSourceIds, isEmpty);
    expect(recorded, 0);
    expect(stored.sourceCode, isEmpty);
    expect(stored.isAdded, isFalse);
    expect(stored.isPinned, isFalse);
  });
}

Future<String> _isarLibraryPath() async {
  final packageConfig = File(
    '${Directory.current.path}/.dart_tool/package_config.json',
  );
  final config = jsonDecode(await packageConfig.readAsString());
  final packages = (config['packages'] as List).cast<Map<String, dynamic>>();
  final package = packages.firstWhere(
    (entry) => entry['name'] == 'isar_community_flutter_libs',
  );
  final rootUri = Uri.parse(package['rootUri'] as String);
  final packageDirectory = Directory.fromUri(
    rootUri.isAbsolute ? rootUri : packageConfig.parent.uri.resolveUri(rootUri),
  );
  if (Platform.isMacOS) {
    return '${packageDirectory.path}/macos/libisar.dylib';
  }
  if (Platform.isLinux) return '${packageDirectory.path}/linux/libisar.so';
  if (Platform.isWindows) {
    return '${packageDirectory.path}/windows/libisar.dll';
  }
  throw UnsupportedError('Isar test is unsupported on this platform');
}
