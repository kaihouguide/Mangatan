import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/eval/mihon/bridge_protocol.dart';
import 'package:mangayomi/eval/model/source_preference.dart';
import 'package:mangayomi/models/category.dart';
import 'package:mangayomi/models/changed.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/epub_book_progress.dart';
import 'package:mangayomi/models/history.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/models/track.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupManga.pb.dart';
import 'package:mangayomi/services/hoshidicts/dictionary_storage.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';
import 'package:mangayomi/services/sync/chimahon_app_settings_adapter.dart';
import 'package:mangayomi/services/sync/chimahon_local_sync_projection_service.dart';
import 'package:mangayomi/services/sync/chimahon_mining_settings_adapter.dart';
import 'package:mangayomi/services/sync/chimahon_media_sync_selection.dart';
import 'package:mangayomi/services/sync/chimahon_novel_materializer.dart';
import 'package:mangayomi/services/sync/chimahon_source_preferences_adapter.dart';
import 'package:mangayomi/services/sync/chimahon_tracking_adapter.dart';
import 'package:mangayomi/services/sync/mihon_backup_exporter.dart';

void main() {
  late Directory databaseDirectory;
  late Directory hiveDirectory;
  late Isar database;
  late _DictionaryStorageStub dictionaryStorage;
  late Manga manga;
  late ChangedPart validDeletionMarker;

  setUpAll(() async {
    await Isar.initializeIsarCore(
      libraries: {Abi.current(): await _isarLibraryPath()},
    );
    hiveDirectory = await Directory.systemTemp.createTemp(
      'mangatan-local-projection-hive-',
    );
    Hive.init(hiveDirectory.path);
    MiningPreferences.configureStorageDirectory(hiveDirectory.path);
  });

  setUp(() async {
    await _resetMiningPreferences();
    databaseDirectory = await Directory.systemTemp.createTemp(
      'mangatan-local-projection-isar-',
    );
    database = await Isar.open(
      [
        MangaSchema,
        ChapterSchema,
        CategorySchema,
        HistorySchema,
        SourceSchema,
        EpubBookProgressSchema,
        TrackSchema,
        SettingsSchema,
        SourcePreferenceSchema,
        ChangedPartSchema,
      ],
      directory: databaseDirectory.path,
      name: 'chimahon_local_projection_test',
    );
    dictionaryStorage = _DictionaryStorageStub(const [
      InstalledDictionary(
        name: 'Portable dictionary',
        hasTerms: true,
        hasFrequencies: false,
        hasPitch: false,
      ),
    ]);

    await MiningPreferences.setOcrEngine(OcrEnginePreference.mokuroOnly);
    await MiningPreferences.setOcrBoxScaleX(1.2);
    await MiningPreferences.setOcrBoxScaleY(0.9);

    final sourcePreference = SourcePreference(
      sourceId: 42,
      key: 'include_adult',
      checkBoxPreference: CheckBoxPreference(value: true),
    );
    final source = Source(
      id: 42,
      name: 'Portable source',
      lang: 'ja',
      additionalParams: encodeMihonSourceMetadata(
        sourceId: 9001,
        packageName: 'test.extension',
      ),
      preferenceList: jsonEncode([sourcePreference.toJson()]),
    )..sourceCodeLanguage = SourceCodeLanguage.mihon;
    final category = Category(
      name: 'Learning',
      forItemType: ItemType.manga,
      pos: 0,
      hide: true,
      shouldUpdate: false,
    );
    manga = Manga(
      source: source.name,
      author: 'Author',
      artist: 'Artist',
      genre: const ['Drama'],
      imageUrl: 'https://example.invalid/cover.jpg',
      lang: 'ja',
      link: '/series',
      name: 'Custom title',
      sourceTitle: 'Source title',
      status: Status.ongoing,
      description: 'Description',
      sourceId: source.id,
      favorite: true,
      favoriteModifiedAt: 100,
      updatedAt: 100,
    );

    database.writeTxnSync(() {
      database.settings.putSync(
        Settings(defaultPageMode: PageMode.doublePageCover),
      );
      database.sources.putSync(source);
      database.sourcePreferences.putSync(sourcePreference);
      database.categorys.putSync(category);
      manga.categories = [category.id!];
      database.mangas.putSync(manga);

      final chapter = Chapter(
        mangaId: manga.id,
        name: 'Chapter 1',
        url: '/chapter-1',
        isRead: true,
        updatedAt: 200000,
      )..manga.value = manga;
      database.chapters.putSync(chapter);
      chapter.manga.saveSync();
      final history = History(
        itemType: ItemType.manga,
        chapterId: chapter.id,
        mangaId: manga.id,
        date: '300000',
        readingTimeSeconds: 12,
      )..chapter.value = chapter;
      database.historys.putSync(history);
      history.chapter.saveSync();

      validDeletionMarker = ChangedPart(
        actionType: ActionType.removeTrack,
        isarId: 71,
        data: jsonEncode(
          ChimahonTrackingDeletionMarker(
            mangaId: manga.id,
            syncId: 2,
            modifiedAt: 700,
          ).toJson(),
        ),
        clientDate: 700,
      );
      database.changedParts.putSync(validDeletionMarker);
      database.changedParts.putAllSync([
        ChangedPart(
          actionType: ActionType.removeTrack,
          data: jsonEncode(
            ChimahonTrackingDeletionMarker(
              mangaId: manga.id,
              syncId: 4,
              modifiedAt: 800,
            ).toJson(),
          ),
          clientDate: 800,
        ),
        ChangedPart(
          actionType: ActionType.removeTrack,
          data: '{malformed',
          clientDate: 900,
        ),
        ChangedPart(
          actionType: ActionType.removeHistory,
          data: jsonEncode(
            ChimahonTrackingDeletionMarker(
              mangaId: manga.id,
              syncId: 3,
              modifiedAt: 1000,
            ).toJson(),
          ),
          clientDate: 1000,
        ),
      ]);
    });
  });

  tearDown(() async {
    await database.close(deleteFromDisk: true);
    if (await databaseDirectory.exists()) {
      await databaseDirectory.delete(recursive: true);
    }
  });

  tearDownAll(() async {
    await Hive.close();
    if (await hiveDirectory.exists()) {
      await hiveDirectory.delete(recursive: true);
    }
  });

  test('matches the previous export pipeline byte for byte', () async {
    final snapshot = await ChimahonLocalSyncProjectionService(
      database: database,
      dictionaryStorage: dictionaryStorage,
    ).createSnapshot();

    final settingsProjection = const ChimahonAppSettingsAdapter().project(
      database.settings.getSync(227)!,
    );
    final sources = database.sources.filter().idIsNotNull().findAllSync();
    final miningProjection = await const ChimahonMiningSettingsAdapter()
        .project(
          dictionaryStorage: dictionaryStorage,
          portableSourceIds: chimahonPortableSourceOverrideIds(sources),
        );
    final expected = const ChimahonMediaSyncSelection().withBackedPreferences(
      const MihonBackupExporter().export(
        mangas: database.mangas.filter().idIsNotNull().findAllSync(),
        categories: database.categorys.filter().idIsNotNull().findAllSync(),
        chapters: database.chapters.filter().idIsNotNull().findAllSync(),
        histories: database.historys.filter().idIsNotNull().findAllSync(),
        sources: sources,
        epubBookProgress: database.epubBookProgress.where().findAllSync(),
        tracks: database.tracks.filter().idIsNotNull().findAllSync(),
        deletedTracks: [
          ChimahonTrackingDeletion(
            mangaId: manga.id!,
            syncId: 2,
            modifiedAt: 700,
          ),
        ],
        appPreferences: [
          ...settingsProjection.preferences,
          ...miningProjection.preferences,
        ],
        sourcePreferences: const ChimahonSourcePreferencesAdapter().export(
          sources: sources,
          storedPreferences: database.sourcePreferences.where().findAllSync(),
        ),
      ),
    );

    expect(snapshot.backup.writeToBuffer(), expected.writeToBuffer());
    expect(snapshot.backup.backupManga.single.customTitle, 'Custom title');
    expect(snapshot.backup.backupManga.single.lastModifiedAt.toInt(), 700);
    expect(snapshot.unrepresentablePreferenceKeys, {
      ...settingsProjection.unrepresentableKeys,
      ...miningProjection.unrepresentableKeys,
    });
    expect(
      snapshot.unrepresentablePreferenceKeys,
      containsAll({'page_layout', 'pref_ocr_engine', 'pref_ocr_box_scale'}),
    );
    expect(snapshot.trackingDeletionKeys, {
      (source: 9001, url: '/series', syncId: 2),
    });
    expect(snapshot.changedPartIds, [validDeletionMarker.id]);
    expect(snapshot.mediaSelection, const ChimahonMediaSyncSelection());
    expect(snapshot.mediaSelectionInitialized, isFalse);
    expect(snapshot.changedPartIdsByTrackingDeletionKey, {
      (source: 9001, url: '/series', syncId: 2): [validDeletionMarker.id!],
    });
  });

  test(
    'excludes remote-cache ghost rows only from live sync projection',
    () async {
      late Manga ghostParent;
      late Manga realParent;
      late Category ghostCategory;
      late Category realCategory;
      late Category localUnassignedCategory;
      database.writeTxnSync(() {
        ghostCategory = Category(
          name: 'Account A cache',
          forItemType: ItemType.novel,
          pos: 0,
        );
        realCategory = Category(
          name: 'Local EPUB category',
          forItemType: ItemType.novel,
          pos: 1,
        );
        localUnassignedCategory = Category(
          name: 'Locally created empty category',
          forItemType: ItemType.novel,
          pos: 2,
          updatedAt: 123,
        );
        database.categorys.putAllSync([
          ghostCategory,
          realCategory,
          localUnassignedCategory,
        ]);
        ghostParent = Manga(
          source: chimahonCloudNovelSource,
          author: 'Writer',
          artist: null,
          genre: const [],
          imageUrl: null,
          lang: 'ja',
          link: '${chimahonCloudNovelLinkPrefix}ghost',
          name: 'Cloud cache',
          status: Status.unknown,
          description: chimahonMissingEpubGuidance,
          sourceId: null,
          itemType: ItemType.novel,
          favorite: true,
          isLocalArchive: true,
          categories: [ghostCategory.id!],
        );
        realParent = Manga(
          source: 'archive',
          author: 'Writer',
          artist: null,
          genre: const [],
          imageUrl: null,
          lang: 'ja',
          link: '/books/real.epub',
          name: 'Real local EPUB',
          status: Status.unknown,
          description: '',
          sourceId: null,
          itemType: ItemType.novel,
          favorite: true,
          isLocalArchive: true,
          categories: [realCategory.id!],
        );
        database.mangas.putAllSync([ghostParent, realParent]);
        database.epubBookProgress.putAllSync([
          EpubBookProgress(
            mangaId: ghostParent.id!,
            archivePath: '',
            title: 'Cloud cache',
            author: 'Writer',
          ),
          EpubBookProgress(
            mangaId: realParent.id!,
            archivePath: '/books/real.epub',
            title: 'Real local EPUB',
            author: 'Writer',
          ),
        ]);
      });

      final snapshot = await ChimahonLocalSyncProjectionService(
        database: database,
        dictionaryStorage: dictionaryStorage,
      ).createSnapshot();
      expect(snapshot.backup.backupNovels.map((novel) => novel.title), [
        'Real local EPUB',
      ]);
      expect(
        snapshot.backup.backupNovelCategories.map((category) => category.name),
        unorderedEquals([
          'Local EPUB category',
          'Locally created empty category',
        ]),
      );
      expect(
        snapshot.backup.backupNovelCategories.map((category) => category.name),
        isNot(contains('Account A cache')),
      );

      // Standalone/manual backup still includes the visible cloud placeholder;
      // only account-scoped live sync treats it as remote cache.
      final manual = const MihonBackupExporter().export(
        mangas: database.mangas.where().findAllSync(),
        categories: database.categorys.where().findAllSync(),
        chapters: database.chapters.where().findAllSync(),
        histories: database.historys.where().findAllSync(),
        sources: database.sources.where().findAllSync(),
        epubBookProgress: database.epubBookProgress.where().findAllSync(),
        tracks: database.tracks.where().findAllSync(),
      );
      expect(
        manual.backupNovels.map((novel) => novel.title),
        unorderedEquals(['Cloud cache', 'Real local EPUB']),
      );
      expect(
        manual.backupNovelCategories.map((category) => category.name),
        containsAll([
          'Account A cache',
          'Local EPUB category',
          'Locally created empty category',
        ]),
      );
    },
  );

  test(
    'freezes every exposed part and leaves invalid markers queued',
    () async {
      final snapshot = await ChimahonLocalSyncProjectionService(
        database: database,
        dictionaryStorage: dictionaryStorage,
      ).createSnapshot();

      expect(snapshot.backup.isFrozen, isTrue);
      expect(snapshot.backup.backupManga.single.isFrozen, isTrue);
      expect(
        () => snapshot.backup.backupManga.add(BackupManga()),
        throwsUnsupportedError,
      );
      expect(
        () => snapshot.backup.backupManga.single.title = 'Mutation',
        throwsUnsupportedError,
      );
      expect(
        () => snapshot.unrepresentablePreferenceKeys.add('mutation'),
        throwsUnsupportedError,
      );
      expect(
        () => snapshot.trackingDeletionKeys.add((
          source: 1,
          url: '/mutation',
          syncId: 1,
        )),
        throwsUnsupportedError,
      );
      expect(() => snapshot.changedPartIds.add(999), throwsUnsupportedError);

      final allMarkers = database.changedParts.where().findAllSync();
      expect(allMarkers, hasLength(4));
      expect(snapshot.changedPartIds, hasLength(1));
    },
  );

  test(
    'read-only local projection is exact with a closed box and writes no files',
    () async {
      final service = ChimahonLocalSyncProjectionService(
        database: database,
        dictionaryStorage: dictionaryStorage,
        readOnly: true,
      );
      final openProjection = await service.createSnapshot();

      await Hive.box<dynamic>('mining_preferences').close();
      expect(Hive.isBoxOpen('mining_preferences'), isFalse);
      final before = await _hiveFileSnapshot(hiveDirectory);

      final closedProjection = await service.createSnapshot();

      expect(
        closedProjection.backup.writeToBuffer(),
        openProjection.backup.writeToBuffer(),
      );
      expect(
        closedProjection.unrepresentablePreferenceKeys,
        openProjection.unrepresentablePreferenceKeys,
      );
      expect(
        closedProjection.trackingDeletionKeys,
        openProjection.trackingDeletionKeys,
      );
      expect(Hive.isBoxOpen('mining_preferences'), isFalse);
      expect(await _hiveFileSnapshot(hiveDirectory), before);
    },
  );
}

Future<void> _resetMiningPreferences() async {
  if (Hive.isBoxOpen('mining_preferences')) {
    await Hive.box<dynamic>('mining_preferences').close();
  }
  await Hive.deleteBoxFromDisk('mining_preferences');
}

class _DictionaryStorageStub implements DictionaryStorage {
  const _DictionaryStorageStub(this.dictionaries);

  final List<InstalledDictionary> dictionaries;

  @override
  Future<List<InstalledDictionary>> installed({
    Directory? root,
    List<String> order = const [],
  }) async => dictionaries;

  @override
  Future<List<InstalledDictionary>> installedReadOnly({
    Directory? root,
    List<String> order = const [],
  }) async => dictionaries;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
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

Future<Map<String, String>> _hiveFileSnapshot(Directory directory) async {
  final snapshot = <String, String>{};
  await for (final entity in directory.list(recursive: true)) {
    if (entity is! File) continue;
    // Hive lock files can remain exclusively locked by another open box on
    // Windows. They contain no persisted preference data and are not part of
    // the read-only projection contract this snapshot verifies.
    if (entity.path.endsWith('.lock')) continue;
    final relativePath = entity.path.substring(directory.path.length);
    final stat = await entity.stat();
    final bytes = await entity.readAsBytes();
    snapshot[relativePath] =
        '${stat.modified.microsecondsSinceEpoch}:${base64Encode(bytes)}';
  }
  return snapshot;
}
