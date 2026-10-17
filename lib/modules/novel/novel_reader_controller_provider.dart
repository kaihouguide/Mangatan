import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/epub_book_progress.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/modules/manga/reader/mixins/chapter_reader_settings_mixin.dart';
import 'package:mangayomi/modules/manga/reader/mixins/chapter_controller_mixin.dart';
import 'package:mangayomi/services/epub_chapter_metadata.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:mangayomi/repositories/settings_repository.dart';
import 'package:mangayomi/repositories/chapter_repository.dart';
part 'novel_reader_controller_provider.g.dart';

@riverpod
class NovelReaderController extends _$NovelReaderController
    with ChapterControllerMixin, ChapterReaderSettingsMixin {
  @override
  void build({required Chapter chapter}) {}

  // Keep incognitoMode as a final field (read once, not on every access).
  @override
  final bool incognitoMode = settingsRepository.current.incognitoMode!;

  @override
  Settings getIsarSetting() => isar.settings.getSync(227)!;

  // ---------------------------------------------------------------------------
  // Reader mode
  // ---------------------------------------------------------------------------

  ReaderMode getReaderMode() {
    final personalReaderModeList =
        getIsarSetting().personalReaderModeList ?? [];
    final personalReaderMode = personalReaderModeList.where(
      (element) => element.mangaId == getManga().id,
    );
    if (personalReaderMode.isNotEmpty) {
      return personalReaderMode.first.readerMode;
    }
    return ReaderMode.verticalContinuous;
  }

  void setReaderMode(ReaderMode newReaderMode) {
    List<PersonalReaderMode>? personalReaderModeLists = [];
    for (var personalReaderMode
        in getIsarSetting().personalReaderModeList ?? []) {
      if (personalReaderMode.mangaId != getManga().id) {
        personalReaderModeLists.add(personalReaderMode);
      }
    }
    personalReaderModeLists.add(
      PersonalReaderMode()
        ..mangaId = getManga().id
        ..readerMode = newReaderMode,
    );
    settingsRepository.save(
      getIsarSetting()..personalReaderModeList = personalReaderModeLists,
    );
    onSettingsMutated();
  }

  // ---------------------------------------------------------------------------
  // Scroll-position tracking
  // ---------------------------------------------------------------------------

  // Progress writes run as queued async transactions: reading can overlap a
  // sync import, and Isar rejects a synchronous transaction while an async one
  // is open. The queue keeps them from overlapping other queued writes.
  Future<void> setChapterOffset(
    double newOffset,
    double maxOffset, {
    int? epubChapterIndex,
    double? epubChapterProgress,
    int? epubCharacterCount,
  }) async {
    if (incognitoMode) return;
    final progress = maxOffset != 0 ? newOffset / maxOffset : 0.0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final ch = chapter;
    if (isEpubNavigationChapter(ch) && ch.archivePath?.isNotEmpty == true) {
      final bookmark = epubBookmark();
      if (bookmark == null) return;
      final nextChapterIndex = epubChapterIndex ?? bookmark.chapterIndex;
      final nextProgress = (epubChapterProgress ?? bookmark.progress)
          .clamp(0.0, 1.0)
          .toDouble();
      final nextCharacterCount = epubCharacterCount ?? bookmark.characterCount;
      if (nextChapterIndex == bookmark.chapterIndex &&
          nextCharacterCount == bookmark.characterCount &&
          (nextProgress - bookmark.progress).abs() <= 0.0001) {
        return;
      }
      bookmark
        ..chapterIndex = nextChapterIndex
        ..progress = nextProgress
        ..characterCount = nextCharacterCount
        ..lastModified = now;
      await chapterRepository.writeTransactionAsync(
        () => isar.epubBookProgress.put(bookmark),
      );
      return;
    }

    await chapterRepository.writeTransactionAsync(() async {
      if (ch.isRead ?? false) return;
      ch
        ..isRead = progress >= 0.9
        ..lastPageRead = progress.clamp(0.0, 1.0).toString()
        ..updatedAt = now;
      await isar.chapters.put(ch);
    });
  }

  EpubBookProgress? epubBookmark() {
    final mangaId = chapter.mangaId;
    final archivePath = chapter.archivePath;
    if (mangaId == null || archivePath == null || archivePath.isEmpty) {
      return null;
    }
    return isar.epubBookProgress
        .filter()
        .mangaIdEqualTo(mangaId)
        .archivePathEqualTo(archivePath)
        .findFirstSync();
  }

  Future<void> updateEpubShortcutPosition({
    required int spineIndex,
    required double overallProgress,
  }) async {
    if (incognitoMode) return;
    final mangaId = chapter.mangaId;
    final archivePath = chapter.archivePath;
    if (mangaId == null || archivePath == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = isar.chapters
        .filter()
        .idIsNotNull()
        .mangaIdEqualTo(mangaId)
        .findAllSync()
        .where(
          (row) =>
              row.archivePath == archivePath && isEpubNavigationChapter(row),
        )
        .toList(growable: false);
    final changed = applyEpubShortcutPositionProjection(
      chapters: rows,
      spineIndex: spineIndex,
      overallProgress: overallProgress,
    );
    if (changed.isEmpty) return;
    for (final shortcut in changed) {
      shortcut.updatedAt = now;
    }
    await chapterRepository.writeTransactionAsync(
      () => isar.chapters.putAll(changed),
    );
  }
}
