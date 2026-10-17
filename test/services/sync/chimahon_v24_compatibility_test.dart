import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupCategory.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupChapter.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupManga.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupNovel.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupPreference.pb.dart';
import 'package:mangayomi/models/category.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupSourceNovel.pb.dart';
import 'package:mangayomi/services/sync/chimahon_manual_restore_category_adapter.dart';
import 'package:mangayomi/services/sync/chimahon_novel_materializer.dart';
import 'package:mangayomi/services/sync/chimahon_sync_merger.dart';
import 'package:mangayomi/services/sync/chimahon_sync_safety_audit.dart';

void main() {
  // Chimahon 2.4 database-backed books carry their chapter rows (12) and
  // reading history (13).
  BackupNovel novel(int lastModified, {String chapter = '/c1'}) => BackupNovel(
    id: 'n',
    title: 'Book',
    author: 'Author',
    lastModified: Int64(lastModified),
    chapters: [BackupChapter(url: chapter, name: 'One', progress: 0.25)],
    history: [BackupNovelHistory(chapterUrl: chapter, lastRead: Int64(5))],
  );

  test('the newer novel keeps its own lists, once', () {
    final merged = const ChimahonSyncMerger().merge(
      local: BackupMihon(backupNovels: [novel(20, chapter: '/local')]),
      remote: BackupMihon(backupNovels: [novel(10, chapter: '/remote')]),
    );
    final result = merged.backupNovels.single;
    expect(result.chapters.map((row) => row.url), ['/local']);
    expect(result.history.map((row) => row.chapterUrl), ['/local']);
  });

  test('a newer Mangatan record keeps Chimahon lists it cannot project', () {
    final local = BackupNovel(
      id: 'n',
      title: 'Book',
      author: 'Author',
      lastModified: Int64(20),
    );
    final merged = const ChimahonSyncMerger().merge(
      local: BackupMihon(backupNovels: [local]),
      remote: BackupMihon(backupNovels: [novel(10)]),
    );
    final result = merged.backupNovels.single;
    expect(result.chapters.single.progress, 0.25);
    expect(result.history.single.chapterUrl, '/c1');
  });

  test('merges a novel stat day per field like Chimahon', () {
    BackupNovel withStat(BackupNovelStat stat, int modified) => BackupNovel(
      id: 'n',
      title: 'Book',
      author: 'Author',
      lastModified: Int64(modified),
      stats: [stat],
    );
    // Mangatan stamps its rows; Chimahon 2.4 database exports write 0.
    final local = BackupNovelStat(
      dateKey: '2026-10-01',
      charactersRead: 100,
      readingTime: 60,
      minReadingSpeed: 0,
      altMinReadingSpeed: 300,
      lastReadingSpeed: 400,
      maxReadingSpeed: 500,
      lastStatisticModified: Int64(1000),
    );
    final remote = BackupNovelStat(
      dateKey: '2026-10-01',
      charactersRead: 900,
      readingTime: 300,
      minReadingSpeed: 200,
      altMinReadingSpeed: 250,
      lastReadingSpeed: 350,
      maxReadingSpeed: 450,
      lastStatisticModified: Int64(0),
    );

    final merged = const ChimahonSyncMerger().merge(
      local: BackupMihon(backupNovels: [withStat(local, 20)]),
      remote: BackupMihon(backupNovels: [withStat(remote, 10)]),
    );
    final stat = merged.backupNovels.single.stats.single;
    expect(stat.charactersRead, 900);
    expect(stat.readingTime, 300);
    expect(stat.minReadingSpeed, 200);
    expect(stat.altMinReadingSpeed, 250);
    expect(stat.lastReadingSpeed, 350);
    expect(stat.maxReadingSpeed, 500);
    expect(stat.lastStatisticModified, Int64(1000));
  });

  test('passes Chimahon 2.4 records Mangatan does not model through', () {
    final remote =
        BackupMihon(
            backupNovels: [novel(10)],
            backupManga: [
              BackupManga(
                source: Int64(1),
                url: '/m',
                title: 'Manga',
                chapters: [
                  BackupChapter(url: '/c1', name: 'One', progress: 0.5),
                ],
              ),
            ],
          )
          // backupSourceNovels (702) and backupNovelExtensionRepo (703).
          ..unknownFields.mergeLengthDelimitedField(702, [8, 1])
          ..unknownFields.mergeLengthDelimitedField(703, [10, 0]);

    final merged = const ChimahonSyncMerger().merge(
      local: BackupMihon(),
      remote: remote,
    );

    expect(merged.unknownFields.getField(702)!.lengthDelimited, [
      [8, 1],
    ]);
    expect(merged.unknownFields.getField(703)!.lengthDelimited, [
      [10, 0],
    ]);
    expect(merged.backupNovels.single.chapters, hasLength(1));
    expect(merged.backupNovels.single.history, hasLength(1));
    expect(merged.backupManga.single.chapters.single.progress, 0.5);
  });

  // Chimahon's NovelRestorer restores the resume point from the top-level
  // chapterIndex, progress and lastModified, and inserts the `chapters` list
  // only into an empty database. A newer Mangatan novel must therefore carry
  // its own position while keeping Chimahon's lists.
  test('a newer Mangatan novel uploads its own resume point', () {
    final local = BackupNovel(
      id: 'n',
      title: 'Book',
      author: 'Author',
      chapterIndex: 7,
      progress: 0.5,
      characterCount: 1200,
      lastModified: Int64(2000),
    );
    final merged = const ChimahonSyncMerger().merge(
      local: BackupMihon(backupNovels: [local]),
      remote: BackupMihon(
        backupNovels: [
          novel(1000)
            ..chapterIndex = 2
            ..progress = 0.1,
        ],
      ),
    );
    final result = merged.backupNovels.single;
    expect(result.chapterIndex, 7);
    expect(result.progress, 0.5);
    expect(result.characterCount, 1200);
    expect(result.lastModified, Int64(2000));
    expect(result.chapters, hasLength(1));
    expect(result.history, hasLength(1));
  });

  // Chimahon's PreferenceRestorer resolves `default_anime_category` by
  // looking the stored ID up in the backup's anime categories, then matching
  // that category by name on the device.
  test('keeps default_anime_category resolvable for Chimahon', () {
    BackupCategory watching(int id) =>
        BackupCategory(name: 'Watching', id: Int64(id), order: Int64(1));
    final defaultAnimeCategory = BackupPreference(
      key: 'default_anime_category',
      value: BackupPreferenceValue(
        type: 'eu.kanade.tachiyomi.data.backup.models.IntPreferenceValue',
        value: IntPreferenceValue(value: 7).writeToBuffer(),
      ),
    );

    final merged = const ChimahonSyncMerger().merge(
      // Mangatan numbers the same category with its own database ID.
      local: BackupMihon(backupAnimeCategories: [watching(3)]),
      remote: BackupMihon(
        backupAnimeCategories: [watching(7)],
        backupPreferences: [defaultAnimeCategory],
      ),
    );

    final preference = merged.backupPreferences.singleWhere(
      (preference) => preference.key == 'default_anime_category',
    );
    final id = IntPreferenceValue.fromBuffer(preference.value.value).value;
    final category = merged.backupAnimeCategories.singleWhere(
      (category) => category.id.toInt() == id,
    );
    expect(category.name, 'Watching');
  });

  // Chimahon 2.4 exports its uncategorized row as database row 0 with a
  // blank name. A manual restore must not turn it into a category.
  test('manual restore ignores the Chimahon 2.4 system category row', () {
    final plan = const ChimahonManualRestoreCategoryAdapter().build(
      localCategories: const <Category>[],
      retainedLocalCategoryIds: const {},
      mangaCategories: const [],
      animeCategories: const [],
      novelCategories: [
        BackupNovelCategory(id: '0', name: '', order: Int64(-1)),
        BackupNovelCategory(id: '5', name: 'Reading', order: Int64(1)),
      ],
    );
    expect(plan.categoriesForInsertion.map((category) => category.name), [
      'Reading',
    ]);
    expect(plan.categoriesForInsertion.single.forItemType, ItemType.novel);
  });

  test('the safety audit accepts a newer remote list over a restored one', () {
    // A pending manual restore carries Chimahon's novel lists locally.
    final local = BackupMihon(backupNovels: [novel(10, chapter: '/restored')]);
    final remote = BackupMihon(backupNovels: [novel(20, chapter: '/cloud')]);
    final report = const ChimahonSyncSafetyAudit().audit(
      remote: remote,
      local: local,
      proposed: const ChimahonSyncMerger().merge(local: local, remote: remote),
    );
    expect(report.safeToUpload, isTrue);
  });

  // Chimahon 2.4 exports favorites from novel extensions as backupNovels too,
  // alongside a backupSourceNovels (702) entry. They cannot become EPUB books.
  test('web-novel favorites are not materialized as missing EPUBs', () {
    BackupNovel book(String title) =>
        BackupNovel(id: title, title: title, author: 'Writer');
    final backup =
        BackupMihon(backupNovels: [book('Web serial'), book('EPUB book')])
          ..unknownFields.mergeLengthDelimitedField(
            702,
            BackupSourceNovel(
              source: Int64(7),
              url: '/serial',
              title: 'Web serial',
              author: 'Writer',
            ).writeToBuffer(),
          )
          // An unreadable entry identifies nothing.
          ..unknownFields.mergeLengthDelimitedField(702, [10, 200]);

    expect(chimahonEpubLibraryNovels(backup).map((novel) => novel.title), [
      'EPUB book',
    ]);
    expect(backup.backupNovels, hasLength(2));
  });
}
