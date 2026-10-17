import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/eval/model/source_preference.dart';
import 'package:mangayomi/models/category.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/download.dart';
import 'package:mangayomi/models/history.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/models/sync_preference.dart';
import 'package:mangayomi/models/track.dart';
import 'package:mangayomi/models/update.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';
import 'package:mangayomi/services/sync/chimahon_local_revision.dart';

void main() {
  late Directory testDirectory;
  late Directory databaseDirectory;
  late Isar database;

  setUpAll(() async {
    await Isar.initializeIsarCore(
      libraries: {Abi.current(): await _isarLibraryPath()},
    );
    testDirectory = await Directory.systemTemp.createTemp(
      'mangatan-local-revision-',
    );
    Hive.init(testDirectory.path);
    MiningPreferences.configureStorageDirectory(testDirectory.path);
  });

  setUp(() async {
    databaseDirectory = await Directory.systemTemp.createTemp(
      'mangatan-local-revision-isar-',
    );
    database = await Isar.open(
      [
        MangaSchema,
        ChapterSchema,
        CategorySchema,
        DownloadSchema,
        HistorySchema,
        UpdateSchema,
        TrackSchema,
        SourceSchema,
        SourcePreferenceSchema,
        SettingsSchema,
        SyncPreferenceSchema,
      ],
      directory: databaseDirectory.path,
      name: 'chimahon_local_revision_test',
    );
  });

  tearDown(() async {
    await database.close(deleteFromDisk: true);
    if (await databaseDirectory.exists()) {
      await databaseDirectory.delete(recursive: true);
    }
  });

  tearDownAll(() async {
    await Hive.close();
    if (await testDirectory.exists()) {
      await testDirectory.delete(recursive: true);
    }
  });

  test('is stable and changes when persisted local state changes', () async {
    final projection = BackupMihon();
    final empty = await ChimahonLocalRevision.capture(database, projection);
    final repeated = await ChimahonLocalRevision.capture(database, projection);

    expect(repeated.value, empty.value);

    final download = Download(
      id: 7,
      succeeded: 1,
      failed: 0,
      total: 2,
      isDownload: true,
      isStartDownload: false,
    );
    database.writeTxnSync(() => database.downloads.putSync(download));
    final inserted = await ChimahonLocalRevision.capture(database, projection);

    expect(inserted.value, isNot(empty.value));

    download.succeeded = 2;
    database.writeTxnSync(() => database.downloads.putSync(download));
    final updated = await ChimahonLocalRevision.capture(database, projection);

    expect(updated.value, isNot(inserted.value));
    expect(
      (await ChimahonLocalRevision.capture(database, projection)).value,
      updated.value,
    );
  });

  test('names the local areas that changed, and only those', () async {
    final projection = BackupMihon();
    final before = await ChimahonLocalRevision.capture(database, projection);
    expect(before.changedSections(before), isEmpty);

    database.writeTxnSync(
      () => database.sources.putSync(Source(id: 3, name: 'Source')),
    );
    final after = await ChimahonLocalRevision.capture(database, projection);

    expect(after.value, isNot(before.value));
    expect(before.changedSections(after), ['source']);
  });

  test('a revision built without sections reports none', () {
    const plain = ChimahonLocalRevision('a');
    expect(plain.changedSections(const ChimahonLocalRevision('b')), isEmpty);
  });
}

Future<String> _isarLibraryPath() async {
  final packageConfig = File(
    '${Directory.current.path}/.dart_tool/package_config.json',
  );
  final config = jsonDecode(await packageConfig.readAsString());
  final packages = (config['packages'] as List).cast<Map<String, dynamic>>();
  final package = packages
      .where((entry) => entry['name'] == 'isar_community_flutter_libs')
      .firstOrNull;
  if (package == null) {
    throw StateError('Could not locate isar_community_flutter_libs');
  }
  final rootUri = Uri.parse(package['rootUri'] as String);
  final packageDirectory = Directory.fromUri(
    rootUri.isAbsolute ? rootUri : packageConfig.parent.uri.resolveUri(rootUri),
  );
  if (Platform.isMacOS) {
    return '${packageDirectory.path}/macos/libisar.dylib';
  }
  if (Platform.isLinux) {
    return '${packageDirectory.path}/linux/libisar.so';
  }
  if (Platform.isWindows) {
    return '${packageDirectory.path}/windows/libisar.dll';
  }
  throw UnsupportedError('Isar test is unsupported on this platform');
}
