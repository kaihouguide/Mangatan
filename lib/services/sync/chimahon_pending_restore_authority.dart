import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fixnum/fixnum.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupAnime.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupCategory.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupChapter.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupEpisode.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupHistory.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupManga.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupNovel.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupStatistics.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupTracking.pb.dart';
import 'package:mangayomi/services/sync/chimahon_stats_row_merge.dart';
import 'package:mangayomi/services/sync/chimahon_child_identity.dart';
import 'package:mangayomi/services/sync/chimahon_media_identity.dart';
import 'package:mangayomi/services/sync/chimahon_anime_seasons.dart';
import 'package:mangayomi/services/sync/chimahon_backup_references.dart';
import 'package:mangayomi/services/sync/chimahon_unknown_field_safety.dart';
import 'package:mangayomi/services/sync/chimahon_sync_merger.dart';
import 'package:protobuf/protobuf.dart';
import 'package:mangayomi/services/sync/sync_bytes.dart';

/// Applies an explicitly selected Chimahon backup after the ordinary
/// local/cloud merge.
///
/// The ordinary merger is deliberately newest-wins. That is correct for
/// routine sync, but not for the first upload after a user deliberately chose
/// an older `.tachibk` file. Here, only identities present in that selected
/// backup become authoritative. Current Mangatan projections are used for
/// those identities so edits made after restore are retained, while identities
/// that exist only in the cloud remain untouched.
class ChimahonPendingRestoreAuthority {
  const ChimahonPendingRestoreAuthority();

  BackupMihon apply({
    required BackupMihon pending,
    required BackupMihon localIntent,
    required BackupMihon? remote,
    required BackupMihon merged,
    Set<ChimahonTrackingDeletionKey> localTrackingDeletions = const {},
  }) {
    final namespace = ChimahonSeasonNamespace(
      localIntent.backupAnime,
      merged.backupAnime,
    );
    localIntent = localIntent.deepCopy()
      ..backupAnime.clear()
      ..backupAnime.addAll(namespace.local);
    final result = merged.deepCopy();

    _putSelectedUnknownFieldsLast(result, pending);

    final selectedMangaCategories = _selectedRows(
      pending: pending.backupCategories,
      current: localIntent.backupCategories,
      keyOf: _categoryKey,
    );
    result.backupCategories
      ..clear()
      ..addAll(
        _overlaySelected(
          fallback: merged.backupCategories,
          selected: selectedMangaCategories,
          keyOf: _categoryKey,
          overlay: _selectedOverFallback,
        ),
      );
    final selectedAnimeCategories = _selectedRows(
      pending: pending.backupAnimeCategories,
      current: localIntent.backupAnimeCategories,
      keyOf: _categoryKey,
    );
    result.backupAnimeCategories
      ..clear()
      ..addAll(
        _overlaySelected(
          fallback: merged.backupAnimeCategories,
          selected: selectedAnimeCategories,
          keyOf: _categoryKey,
          overlay: _selectedOverFallback,
        ),
      );
    result.backupNovelCategories
      ..clear()
      ..addAll(
        _overlayNovelCategories(
          fallback: merged.backupNovelCategories,
          selected: _selectedNovelCategories(
            pending.backupNovelCategories,
            localIntent.backupNovelCategories,
          ),
        ),
      );

    final selectedManga = _selectedRows(
      pending: pending.backupManga,
      current: localIntent.backupManga,
      keyOf: _mangaKey,
    );
    final remoteManga = _lastByKey(
      remote?.backupManga ?? const <BackupManga>[],
      _mangaKey,
    );
    result.backupManga
      ..clear()
      ..addAll(
        _overlaySelected(
          fallback: merged.backupManga,
          selected: selectedManga,
          keyOf: _mangaKey,
          overlay: (selected, fallback) => _overlayManga(
            selected,
            fallback,
            remoteManga[_mangaKey(selected)],
            localTrackingDeletions,
          ),
        ),
      );

    final selectedAnime = _selectedRows(
      pending: pending.backupAnime,
      current: localIntent.backupAnime,
      keyOf: _animeKey,
    );
    final remoteAnime = _lastByKey(
      remote?.backupAnime ?? const <BackupAnime>[],
      _animeKey,
    );
    result.backupAnime
      ..clear()
      ..addAll(
        _overlaySelected(
          fallback: merged.backupAnime,
          selected: selectedAnime,
          keyOf: _animeKey,
          overlay: (selected, fallback) => _overlayAnime(
            selected,
            fallback,
            remoteAnime[_animeKey(selected)],
            localTrackingDeletions,
          ),
        ),
      );

    final remoteNovels = _lastByKey(
      remote?.backupNovels ?? const <BackupNovel>[],
      _novelKey,
    );
    result.backupNovels
      ..clear()
      ..addAll(
        _overlaySelected(
          fallback: merged.backupNovels,
          selected: _selectedRows(
            pending: pending.backupNovels,
            current: localIntent.backupNovels,
            keyOf: _novelKey,
          ),
          keyOf: _novelKey,
          overlay: (selected, fallback) => _overlayNovel(
            selected,
            fallback,
            remoteNovels[_novelKey(selected)],
          ),
        ),
      );

    result.backupMangaStats
      ..clear()
      ..addAll(
        ChimahonStatsRowMerge.mangaStats(
          merged.backupMangaStats,
          pending.backupMangaStats,
        ),
      );
    result.backupAnkiStats
      ..clear()
      ..addAll(
        ChimahonStatsRowMerge.ankiStats(
          merged.backupAnkiStats,
          pending.backupAnkiStats,
        ),
      );

    _canonicalizeCategoryOrdersAndRemapMedia<BackupManga>(
      categories: result.backupCategories,
      selectedCategories: selectedMangaCategories,
      selectedSourceCategories: localIntent.backupCategories,
      fallbackSourceCategories: merged.backupCategories,
      media: result.backupManga,
      selectedMediaKeys: selectedManga.map(_mangaKey).toSet(),
      keyOf: _mangaKey,
      categoryOrdersOf: (manga) => manga.categories,
    );
    _canonicalizeCategoryOrdersAndRemapMedia<BackupAnime>(
      categories: result.backupAnimeCategories,
      selectedCategories: selectedAnimeCategories,
      selectedSourceCategories: localIntent.backupAnimeCategories,
      fallbackSourceCategories: merged.backupAnimeCategories,
      media: result.backupAnime,
      selectedMediaKeys: selectedAnime.map(_animeKey).toSet(),
      keyOf: _animeKey,
      categoryOrdersOf: (anime) => anime.categories,
    );

    return result;
  }

  /// Confirms that all selected/current media records are represented in the
  /// exact protobuf that will be handed to storage. Additional cloud-only
  /// records and children are intentionally ignored.
  bool containsSelectedIntent({
    required BackupMihon uploaded,
    required BackupMihon pending,
    required BackupMihon localIntent,
  }) =>
      selectedIntentFailure(
        uploaded: uploaded,
        pending: pending,
        localIntent: localIntent,
      ) ==
      null;

  /// Privacy-safe diagnostic: only a fixed collection-level code, never URLs,
  /// titles, preference values, or contents from the user's backup.
  String? selectedIntentFailure({
    required BackupMihon uploaded,
    required BackupMihon pending,
    required BackupMihon localIntent,
  }) {
    localIntent = rebaseChimahonBackupReferences(localIntent, uploaded);
    uploaded = rebaseChimahonBackupReferences(uploaded, uploaded);
    if (!_unknownFieldsEndWith(uploaded, pending)) {
      return 'restore_selected_root_unknown_fields_lost';
    }

    final uploadedManga = _lastByKey(uploaded.backupManga, _mangaKey);
    for (final selected in _selectedRows(
      pending: pending.backupManga,
      current: localIntent.backupManga,
      keyOf: _mangaKey,
    )) {
      final actual = uploadedManga[_mangaKey(selected)];
      if (actual == null || !_containsManga(actual, selected)) {
        return 'restore_selected_manga_mismatch';
      }
    }

    final uploadedAnime = _lastByKey(uploaded.backupAnime, _animeKey);
    for (final selected in _selectedRows(
      pending: pending.backupAnime,
      current: localIntent.backupAnime,
      keyOf: _animeKey,
    )) {
      final actual = uploadedAnime[_animeKey(selected)];
      if (actual == null || !_containsAnime(actual, selected)) {
        return 'restore_selected_anime_mismatch';
      }
    }

    final uploadedNovels = _lastByKey(uploaded.backupNovels, _novelKey);
    for (final selected in _selectedRows(
      pending: pending.backupNovels,
      current: localIntent.backupNovels,
      keyOf: _novelKey,
    )) {
      final actual = uploadedNovels[_novelKey(selected)];
      if (actual == null || !_containsNovel(actual, selected)) {
        return 'restore_selected_novel_mismatch';
      }
    }

    if (!_containsSelectedRows(
      uploaded: uploaded.backupCategories,
      selected: _selectedRows(
        pending: pending.backupCategories,
        current: localIntent.backupCategories,
        keyOf: _categoryKey,
      ),
      keyOf: _categoryKey,
    )) {
      return 'restore_selected_manga_category_mismatch';
    }
    if (!_containsSelectedRows(
      uploaded: uploaded.backupAnimeCategories,
      selected: _selectedRows(
        pending: pending.backupAnimeCategories,
        current: localIntent.backupAnimeCategories,
        keyOf: _categoryKey,
      ),
      keyOf: _categoryKey,
    )) {
      return 'restore_selected_anime_category_mismatch';
    }
    if (!_containsSelectedNovelCategories(
      uploaded.backupNovelCategories,
      _selectedNovelCategories(
        pending.backupNovelCategories,
        localIntent.backupNovelCategories,
      ),
    )) {
      return 'restore_selected_novel_category_mismatch';
    }
    // Statistics are merged rather than passed through, so the upload cannot be
    // expected to contain the pending rows byte for byte. What must hold is that
    // every pending day survives and no counter went backwards.
    if (!_statisticsRepresented<BackupMangaStats>(
      pending: pending.backupMangaStats,
      uploaded: uploaded.backupMangaStats,
      keyOf: ChimahonStatsRowMerge.mangaKey,
      covers: (uploadedRow, pendingRow) =>
          uploadedRow.charactersRead >= pendingRow.charactersRead &&
          uploadedRow.readingTime >= pendingRow.readingTime,
    )) {
      return 'restore_selected_manga_statistics_mismatch';
    }
    if (!_statisticsRepresented<BackupAnkiStats>(
      pending: pending.backupAnkiStats,
      uploaded: uploaded.backupAnkiStats,
      keyOf: ChimahonStatsRowMerge.ankiKey,
      covers: (uploadedRow, pendingRow) =>
          uploadedRow.mangaCards >= pendingRow.mangaCards &&
          uploadedRow.novelCards >= pendingRow.novelCards,
    )) {
      return 'restore_selected_anki_statistics_mismatch';
    }

    return _containsPendingPreferences(uploaded, pending, localIntent)
        ? null
        : 'restore_selected_preferences_mismatch';
  }

  /// The ordinary merge and the explicit restore are separate transitions.
  /// After proving selected values, also prove that the restore changed only
  /// those identities and advanced the clocks needed by Chimahon. This proof
  /// has no dependency on [apply] and is checked against decoded upload bytes.
  String? transitionFailure({
    required BackupMihon uploaded,
    required BackupMihon pending,
    required BackupMihon localIntent,
    required BackupMihon ordinaryMerged,
    BackupMihon? remote,
    Set<ChimahonTrackingDeletionKey> localTrackingDeletions = const {},
  }) {
    final animeIds = <Int64>{};
    for (final anime in uploaded.backupAnime) {
      if (anime.hasId() && anime.id > Int64.ZERO && !animeIds.add(anime.id)) {
        return 'restore_duplicate_anime_id';
      }
    }
    // Rebinding to a collapsed namespace could otherwise make two different
    // category memberships appear equal. Validate handles before rebasing.
    for (final categories in [
      uploaded.backupCategories,
      uploaded.backupAnimeCategories,
    ]) {
      if (categories.map((row) => row.order).toSet().length !=
          categories.length) {
        return 'restore_duplicate_category_order';
      }
    }
    final actual = rebaseChimahonBackupReferences(uploaded, uploaded);
    final before = rebaseChimahonBackupReferences(ordinaryMerged, actual);
    final intent = rebaseChimahonBackupReferences(localIntent, actual);
    final manga = _selectedRows(
      pending: pending.backupManga,
      current: intent.backupManga,
      keyOf: _mangaKey,
    );
    final anime = _selectedRows(
      pending: pending.backupAnime,
      current: intent.backupAnime,
      keyOf: _animeKey,
    );
    final novels = _selectedRows(
      pending: pending.backupNovels,
      current: intent.backupNovels,
      keyOf: _novelKey,
    );
    final remoteManga = _lastByKey(
      remote?.backupManga ?? <BackupManga>[],
      _mangaKey,
    );
    final remoteAnime = _lastByKey(
      remote?.backupAnime ?? <BackupAnime>[],
      _animeKey,
    );
    final remoteNovels = _lastByKey(
      remote?.backupNovels ?? <BackupNovel>[],
      _novelKey,
    );

    bool children<T extends GeneratedMessage, K>(
      List<T> old,
      List<T> next,
      List<T> selected,
      K Function(T) keyOf, {
      List<T>? competing,
      int? clockTag,
    }) {
      if (clockTag != null) {
        final nextByKey = _lastByKey(next, keyOf);
        final cloudByKey = _lastByKey(competing ?? <T>[], keyOf);
        for (final row in selected) {
          final uploaded = nextByKey[keyOf(row)];
          final cloud = cloudByKey[keyOf(row)];
          final selectedClock = row.getField(clockTag) as Int64;
          final expectedClock = cloud == null
              ? selectedClock
              : _promoteIfNeeded(
                  selectedClock,
                  cloud.getField(clockTag) as Int64,
                );
          if (uploaded == null ||
              uploaded.getField(clockTag) != expectedClock) {
            return false;
          }
        }
      }
      return _preservesUnselected(old, next, selected, keyOf);
    }

    bool trackers(
      List<BackupTracking> old,
      List<BackupTracking> next,
      List<BackupTracking> selected,
      int source,
      String url,
    ) => children(
      old
          .where(
            (row) =>
                !localTrackingDeletions.contains((
                  source: source,
                  url: url,
                  syncId: row.syncId,
                )) ||
                selected.any((s) => s.syncId == row.syncId),
          )
          .toList(),
      next,
      selected,
      (row) => row.syncId,
    );

    if (!_preservesUnselected(
      before.backupManga,
      actual.backupManga,
      manga,
      _mangaKey,
      selectedValid: (old, next, selected) {
        final cloud = remoteManga[_mangaKey(selected)];
        return _parentPromotionValid(next, selected, cloud) &&
            children(
              old.chapters,
              next.chapters,
              selected.chapters,
              _chapterKey,
              competing: cloud?.chapters,
              clockTag: 12,
            ) &&
            children(
              old.history,
              next.history,
              selected.history,
              (row) => row.url,
              competing: cloud?.history,
              clockTag: 2,
            ) &&
            trackers(
              old.tracking,
              next.tracking,
              selected.tracking,
              selected.source.toInt(),
              selected.url,
            );
      },
    )) {
      return 'restore_unselected_manga_or_clocks_changed';
    }
    if (!_preservesUnselected(
      before.backupAnime,
      actual.backupAnime,
      anime,
      _animeKey,
      selectedValid: (old, next, selected) {
        final cloud = remoteAnime[_animeKey(selected)];
        return _parentPromotionValid(next, selected, cloud) &&
            _retainsLegacyAnimeSeasons(old, next, selected) &&
            children(
              old.episodes,
              next.episodes,
              selected.episodes,
              _episodeKey,
              competing: cloud?.episodes,
              clockTag: 12,
            ) &&
            children(
              old.history,
              next.history,
              selected.history,
              (row) => row.url,
              competing: cloud?.history,
              clockTag: 2,
            ) &&
            trackers(
              old.tracking,
              next.tracking,
              selected.tracking,
              selected.source.toInt(),
              selected.url,
            );
      },
    )) {
      return 'restore_unselected_anime_or_clocks_changed';
    }
    if (!_preservesUnselected(
      before.backupNovels,
      actual.backupNovels,
      novels,
      _novelKey,
      selectedValid: (old, next, selected) {
        final cloud = remoteNovels[_novelKey(selected)];
        return next.lastModified ==
                (cloud == null
                    ? selected.lastModified
                    : _promoteIfNeeded(
                        selected.lastModified,
                        cloud.lastModified,
                      )) &&
            children(
              old.stats,
              next.stats,
              selected.stats,
              (row) => row.dateKey,
              competing: cloud?.stats,
              clockTag: 8,
            );
      },
    )) {
      return 'restore_unselected_novel_or_clocks_changed';
    }
    for (final group in [
      (
        before.backupCategories,
        actual.backupCategories,
        pending.backupCategories,
        intent.backupCategories,
      ),
      (
        before.backupAnimeCategories,
        actual.backupAnimeCategories,
        pending.backupAnimeCategories,
        intent.backupAnimeCategories,
      ),
    ]) {
      if (!_preservesUnselected(
        group.$1,
        group.$2,
        _selectedRows(
          pending: group.$3,
          current: group.$4,
          keyOf: _categoryKey,
        ),
        _categoryKey,
      )) {
        return 'restore_unselected_category_changed';
      }
    }
    final selectedNovelCategories = _selectedNovelCategories(
      pending.backupNovelCategories,
      intent.backupNovelCategories,
    );
    if (!_preservesNovelCategories(
      before.backupNovelCategories,
      actual.backupNovelCategories,
      selectedNovelCategories,
    )) {
      return 'restore_unselected_novel_category_changed';
    }
    if (!_preservesUnselected<BackupMangaStats, String>(
          before.backupMangaStats,
          actual.backupMangaStats,
          pending.backupMangaStats,
          ChimahonStatsRowMerge.mangaKey,
          selectedValid: (old, next, selected) =>
              _statisticsTransitionValid(old, next, selected),
        ) ||
        !_preservesUnselected<BackupAnkiStats, String>(
          before.backupAnkiStats,
          actual.backupAnkiStats,
          pending.backupAnkiStats,
          ChimahonStatsRowMerge.ankiKey,
          selectedValid: (old, next, selected) =>
              _statisticsTransitionValid(old, next, selected),
        )) {
      return 'restore_unselected_statistics_changed';
    }
    if (!_retainsUnknown(before, actual)) return 'restore_unknown_fields_lost';
    // All other collections, notably preferences and source stores, were
    // already resolved and audited before the media restore overlay.
    for (final backup in [before, actual]) {
      for (final tag in [1, 2, 501, 502, 700, 701, 710, 711]) {
        backup.clearField(tag);
      }
      backup.unknownFields.clear();
    }
    return sameMessageBytes(before, actual)
        ? null
        : 'restore_unselected_collection_changed';
  }

  bool _retainsLegacyAnimeSeasons(
    BackupAnime before,
    BackupAnime after,
    BackupAnime selected,
  ) {
    if (hasChimahonSeasonMetadata(selected)) return true;
    final beforeHasSeasons = hasChimahonSeasonMetadata(before);
    for (final tag in [500, 502, 503, 504, 505, 506, 507]) {
      // A legacy restore cannot select a different relationship. Its explicit
      // display values only fill fields the season-aware fallback lacks.
      final owner =
          beforeHasSeasons &&
              (before.hasField(tag) || const {502, 503, 507}.contains(tag))
          ? before
          : selected;
      if (after.hasField(tag) != owner.hasField(tag) ||
          after.getField(tag) != owner.getField(tag)) {
        return false;
      }
    }
    return true;
  }

  bool _statisticsTransitionValid(
    GeneratedMessage before,
    GeneratedMessage after,
    GeneratedMessage selected,
  ) {
    // Both root statistics messages put their two max-merged counters at 2/3.
    // Merely checking non-regression would accept fabricated extra reading.
    for (final tag in [2, 3]) {
      final old = before.getField(tag) as Comparable;
      final chosen = selected.getField(tag) as Comparable;
      final expected = old.compareTo(chosen) >= 0 ? old : chosen;
      if (after.getField(tag) != expected) return false;
    }
    final oldEnvelope = before.deepCopy()
      ..clearField(2)
      ..clearField(3)
      ..unknownFields.clear();
    final newEnvelope = after.deepCopy()
      ..clearField(2)
      ..clearField(3)
      ..unknownFields.clear();
    return sameMessageBytes(oldEnvelope, newEnvelope) &&
        _retainsUnknown(selected, after);
  }

  bool _preservesNovelCategories(
    List<BackupNovelCategory> before,
    List<BackupNovelCategory> after,
    List<BackupNovelCategory> selected,
  ) {
    final remaining = List.of(after);
    final selections = List.of(selected);
    for (final old in before) {
      final chosenIndex = selections.indexWhere(
        (row) => _sameNovelCategoryIdentity(old, row),
      );
      final chosen = chosenIndex < 0 ? null : selections.removeAt(chosenIndex);
      final nextIndex = remaining.indexWhere(
        (row) => _sameNovelCategoryIdentity(chosen ?? old, row),
      );
      if (nextIndex < 0) return false;
      final next = remaining.removeAt(nextIndex);
      if (!_retainsUnknown(old, next) ||
          (chosen == null
              ? !sameMessageBytes(old, next)
              : !_sameKnownWithSelectedUnknown(next, chosen))) {
        return false;
      }
    }
    // Any additions must correspond one-to-one to a selected category, not an
    // invented row or another copy of one already consumed above.
    for (final chosen in selections) {
      final index = remaining.indexWhere(
        (row) => _sameNovelCategoryIdentity(chosen, row),
      );
      if (index < 0 ||
          !_sameKnownWithSelectedUnknown(remaining.removeAt(index), chosen)) {
        return false;
      }
    }
    return remaining.isEmpty;
  }

  bool _preservesUnselected<T extends GeneratedMessage, K>(
    List<T> before,
    List<T> after,
    List<T> selected,
    K Function(T) keyOf, {
    bool Function(T before, T after, T selected)? selectedValid,
  }) {
    final selectedByKey = _lastByKey(selected, keyOf);
    final afterByKey = _lastByKey(after, keyOf);
    final allowed = {...before.map(keyOf), ...selectedByKey.keys};
    if (after.length != afterByKey.length ||
        afterByKey.keys.any((key) => !allowed.contains(key))) {
      return false;
    }
    for (final old in before) {
      final next = afterByKey[keyOf(old)];
      if (next == null) return false;
      final chosen = selectedByKey[keyOf(old)];
      if (chosen == null) {
        if (!sameMessageBytes(old, next)) return false;
      } else if (!_retainsUnknown(old, next) ||
          !(selectedValid?.call(old, next, chosen) ?? true)) {
        return false;
      }
    }
    return true;
  }

  bool _retainsUnknown(GeneratedMessage before, GeneratedMessage after) =>
      ChimahonUnknownFieldSafety.missingOrReorderedTags(
        baseline: before,
        target: after,
      ).isEmpty;

  bool _parentPromotionValid(
    GeneratedMessage actual,
    GeneratedMessage selected,
    GeneratedMessage? remote,
  ) {
    // Manga and anime share the three clock tags in Chimahon's wire schema.
    if (actual.getField(109) !=
        (remote == null
            ? selected.getField(109)
            : _promoteIfNeeded(
                selected.getField(109) as Int64,
                remote.getField(109) as Int64,
              ))) {
      return false;
    }
    final hasFavoriteClock =
        selected.hasField(107) || (remote?.hasField(107) ?? false);
    final favoriteClock = remote == null || !hasFavoriteClock
        ? selected.getField(107) as Int64
        : _promoteIfNeeded(
            selected.getField(107) as Int64,
            remote.getField(107) as Int64,
          );
    var modified = selected.getField(106) as Int64;
    if (remote != null && hasFavoriteClock && favoriteClock > modified) {
      modified = favoriteClock;
    }
    return actual.hasField(107) == hasFavoriteClock &&
        actual.getField(107) == favoriteClock &&
        actual.getField(106) == modified;
  }

  /// True when every pending statistics row has an uploaded counterpart on the
  /// same daily identity whose counters are at least as large.
  bool _statisticsRepresented<T extends GeneratedMessage>({
    required Iterable<T> pending,
    required Iterable<T> uploaded,
    required String Function(T row) keyOf,
    required bool Function(T uploadedRow, T pendingRow) covers,
  }) {
    final uploadedByKey = <String, T>{};
    for (final row in uploaded) {
      uploadedByKey[keyOf(row)] = row;
    }
    for (final row in pending) {
      final candidate = uploadedByKey[keyOf(row)];
      if (candidate == null || !covers(candidate, row)) return false;
    }
    return true;
  }

  BackupManga _overlayManga(
    BackupManga selected,
    BackupManga fallback,
    BackupManga? competing,
    Set<ChimahonTrackingDeletionKey> localTrackingDeletions,
  ) {
    final result = _selectedOverFallback(selected, fallback);
    final competingChapters = _lastByKey(
      competing?.chapters ?? const <BackupChapter>[],
      _chapterKey,
    );
    result.chapters
      ..clear()
      ..addAll(
        _overlaySelected(
          fallback: fallback.chapters,
          selected: selected.chapters,
          keyOf: _chapterKey,
          overlay: (chapter, old) => _overlayChapter(
            chapter,
            old,
            competingChapters[_chapterKey(chapter)],
          ),
        ),
      );
    final competingHistory = _lastByKey(
      competing?.history ?? const <BackupHistory>[],
      (history) => history.url,
    );
    result.history
      ..clear()
      ..addAll(
        _overlaySelected(
          fallback: fallback.history,
          selected: selected.history,
          keyOf: (history) => history.url,
          overlay: (history, old) =>
              _overlayHistory(history, old, competingHistory[history.url]),
        ),
      );
    result.tracking
      ..clear()
      ..addAll(
        _overlaySelected(
          fallback: fallback.tracking,
          selected: selected.tracking,
          keyOf: (tracking) => tracking.syncId,
          overlay: _selectedOverFallback,
        ),
      );
    _removeExplicitlyDeletedTracking(
      result.tracking,
      selectedTracking: selected.tracking,
      source: selected.source.toInt(),
      url: selected.url,
      localTrackingDeletions: localTrackingDeletions,
    );
    if (competing != null) {
      result.version = _promoteIfNeeded(selected.version, competing.version);
      if (competing.hasFavoriteModifiedAt() ||
          selected.hasFavoriteModifiedAt()) {
        result.favoriteModifiedAt = _promoteIfNeeded(
          selected.hasFavoriteModifiedAt()
              ? selected.favoriteModifiedAt
              : Int64.ZERO,
          competing.hasFavoriteModifiedAt()
              ? competing.favoriteModifiedAt
              : Int64.ZERO,
        );
        if (result.lastModifiedAt < result.favoriteModifiedAt) {
          result.lastModifiedAt = result.favoriteModifiedAt;
        }
      }
    }
    return result;
  }

  BackupAnime _overlayAnime(
    BackupAnime selected,
    BackupAnime fallback,
    BackupAnime? competing,
    Set<ChimahonTrackingDeletionKey> localTrackingDeletions,
  ) {
    final result = _selectedOverFallback(selected, fallback);
    if (!hasChimahonSeasonMetadata(selected)) {
      retainAnimeSeasonProjectionGaps(result, fallback, selected);
    }
    final competingEpisodes = _lastByKey(
      competing?.episodes ?? const <BackupEpisode>[],
      _episodeKey,
    );
    result.episodes
      ..clear()
      ..addAll(
        _overlaySelected(
          fallback: fallback.episodes,
          selected: selected.episodes,
          keyOf: _episodeKey,
          overlay: (episode, old) => _overlayEpisode(
            episode,
            old,
            competingEpisodes[_episodeKey(episode)],
          ),
        ),
      );
    final competingHistory = _lastByKey(
      competing?.history ?? const <BackupHistory>[],
      (history) => history.url,
    );
    result.history
      ..clear()
      ..addAll(
        _overlaySelected(
          fallback: fallback.history,
          selected: selected.history,
          keyOf: (history) => history.url,
          overlay: (history, old) =>
              _overlayHistory(history, old, competingHistory[history.url]),
        ),
      );
    result.tracking
      ..clear()
      ..addAll(
        _overlaySelected(
          fallback: fallback.tracking,
          selected: selected.tracking,
          keyOf: (tracking) => tracking.syncId,
          overlay: _selectedOverFallback,
        ),
      );
    _removeExplicitlyDeletedTracking(
      result.tracking,
      selectedTracking: selected.tracking,
      source: selected.source.toInt(),
      url: selected.url,
      localTrackingDeletions: localTrackingDeletions,
    );
    if (competing != null) {
      result.version = _promoteIfNeeded(selected.version, competing.version);
      if (competing.hasFavoriteModifiedAt() ||
          selected.hasFavoriteModifiedAt()) {
        result.favoriteModifiedAt = _promoteIfNeeded(
          selected.hasFavoriteModifiedAt()
              ? selected.favoriteModifiedAt
              : Int64.ZERO,
          competing.hasFavoriteModifiedAt()
              ? competing.favoriteModifiedAt
              : Int64.ZERO,
        );
        if (result.lastModifiedAt < result.favoriteModifiedAt) {
          result.lastModifiedAt = result.favoriteModifiedAt;
        }
      }
    }
    return result;
  }

  void _removeExplicitlyDeletedTracking(
    List<BackupTracking> tracking, {
    required Iterable<BackupTracking> selectedTracking,
    required int source,
    required String url,
    required Set<ChimahonTrackingDeletionKey> localTrackingDeletions,
  }) {
    // Ordinary tracking absence is upsert-only, but these keys are durable
    // evidence that the user explicitly removed a portable tracker after the
    // manual restore was selected. Do not let the fallback cloud row revive it;
    // a currently selected row still wins when the user re-added the tracker.
    final selectedSyncIds = selectedTracking.map((row) => row.syncId).toSet();
    tracking.removeWhere(
      (row) =>
          !selectedSyncIds.contains(row.syncId) &&
          _isPortableTrackingService(row.syncId) &&
          localTrackingDeletions.contains((
            source: source,
            url: url,
            syncId: row.syncId,
          )),
    );
  }

  bool _isPortableTrackingService(int syncId) =>
      syncId == 1 || syncId == 2 || syncId == 3;

  BackupChapter _overlayChapter(
    BackupChapter selected,
    BackupChapter fallback,
    BackupChapter? competing,
  ) {
    final result = _selectedOverFallback(selected, fallback);
    if (competing != null) {
      result.version = _promoteIfNeeded(selected.version, competing.version);
    }
    return result;
  }

  BackupEpisode _overlayEpisode(
    BackupEpisode selected,
    BackupEpisode fallback,
    BackupEpisode? competing,
  ) {
    final result = _selectedOverFallback(selected, fallback);
    if (competing != null) {
      result.version = _promoteIfNeeded(selected.version, competing.version);
    }
    return result;
  }

  BackupHistory _overlayHistory(
    BackupHistory selected,
    BackupHistory fallback,
    BackupHistory? competing,
  ) {
    final result = _selectedOverFallback(selected, fallback);
    if (competing != null) {
      result.lastRead = _promoteIfNeeded(selected.lastRead, competing.lastRead);
    }
    return result;
  }

  BackupNovel _overlayNovel(
    BackupNovel selected,
    BackupNovel fallback,
    BackupNovel? competing,
  ) {
    final result = _selectedOverFallback(selected, fallback);
    final competingStats = _lastByKey(
      competing?.stats ?? const <BackupNovelStat>[],
      (stat) => stat.dateKey,
    );
    result.stats
      ..clear()
      ..addAll(
        _overlaySelected(
          fallback: fallback.stats,
          selected: selected.stats,
          keyOf: (stat) => stat.dateKey,
          overlay: (stat, old) {
            final restored = _selectedOverFallback(stat, old);
            final cloud = competingStats[stat.dateKey];
            if (cloud != null) {
              restored.lastStatisticModified = _promoteIfNeeded(
                stat.lastStatisticModified,
                cloud.lastStatisticModified,
              );
            }
            return restored;
          },
        ),
      );
    if (competing != null) {
      result.lastModified = _promoteIfNeeded(
        selected.lastModified,
        competing.lastModified,
      );
    }
    return result;
  }

  bool _containsManga(BackupManga actual, BackupManga selected) {
    final actualRoot = actual.deepCopy()
      ..chapters.clear()
      ..history.clear()
      ..tracking.clear()
      ..unknownFields.clear();
    _copyMangaPromotionFields(actualRoot, selected);
    if (selected.hasFavoriteModifiedAt()) {
      actualRoot.favoriteModifiedAt = selected.favoriteModifiedAt;
    } else {
      actualRoot.clearFavoriteModifiedAt();
    }
    final selectedRoot = selected.deepCopy()
      ..chapters.clear()
      ..history.clear()
      ..tracking.clear()
      ..unknownFields.clear();
    if (!sameMessageBytes(actualRoot, selectedRoot) ||
        !_unknownFieldsEndWith(actual, selected)) {
      return false;
    }
    return _containsSelectedMessages(
          actual: actual.chapters,
          selected: selected.chapters,
          keyOf: _chapterKey,
          normalize: _copyChapterVersion,
        ) &&
        _containsSelectedMessages(
          actual: actual.history,
          selected: selected.history,
          keyOf: (history) => history.url,
          normalize: _copyHistoryClock,
        ) &&
        _containsSelectedMessages(
          actual: actual.tracking,
          selected: selected.tracking,
          keyOf: (tracking) => tracking.syncId,
        );
  }

  bool _containsAnime(BackupAnime actual, BackupAnime selected) {
    final actualRoot = actual.deepCopy()
      ..episodes.clear()
      ..history.clear()
      ..tracking.clear()
      ..unknownFields.clear();
    _copyAnimePromotionFields(actualRoot, selected);
    if (!hasChimahonSeasonMetadata(selected)) {
      for (final tag in [500, 502, 503, 504, 505, 506, 507]) {
        actualRoot.clearField(tag);
        if (selected.hasField(tag)) {
          actualRoot.setField(tag, selected.getField(tag));
        }
      }
    }
    if (selected.hasFavoriteModifiedAt()) {
      actualRoot.favoriteModifiedAt = selected.favoriteModifiedAt;
    } else {
      actualRoot.clearFavoriteModifiedAt();
    }
    final selectedRoot = selected.deepCopy()
      ..episodes.clear()
      ..history.clear()
      ..tracking.clear()
      ..unknownFields.clear();
    if (!sameMessageBytes(actualRoot, selectedRoot) ||
        !_unknownFieldsEndWith(actual, selected)) {
      return false;
    }
    return _containsSelectedMessages(
          actual: actual.episodes,
          selected: selected.episodes,
          keyOf: _episodeKey,
          normalize: _copyEpisodeVersion,
        ) &&
        _containsSelectedMessages(
          actual: actual.history,
          selected: selected.history,
          keyOf: (history) => history.url,
          normalize: _copyHistoryClock,
        ) &&
        _containsSelectedMessages(
          actual: actual.tracking,
          selected: selected.tracking,
          keyOf: (tracking) => tracking.syncId,
        );
  }

  bool _containsNovel(BackupNovel actual, BackupNovel selected) {
    final actualRoot = actual.deepCopy()
      ..stats.clear()
      ..unknownFields.clear();
    _copyNovelClock(actualRoot, selected);
    final selectedRoot = selected.deepCopy()
      ..stats.clear()
      ..unknownFields.clear();
    if (!sameMessageBytes(actualRoot, selectedRoot) ||
        !_unknownFieldsEndWith(actual, selected)) {
      return false;
    }
    return _containsSelectedMessages(
      actual: actual.stats,
      selected: selected.stats,
      keyOf: (stat) => stat.dateKey,
      normalize: _copyNovelStatClock,
    );
  }

  BackupManga _copyMangaPromotionFields(
    BackupManga actual,
    BackupManga selected,
  ) {
    if (selected.hasVersion()) {
      actual.version = selected.version;
    } else {
      actual.clearVersion();
    }
    if (selected.hasLastModifiedAt()) {
      actual.lastModifiedAt = selected.lastModifiedAt;
    } else {
      actual.clearLastModifiedAt();
    }
    return actual;
  }

  BackupAnime _copyAnimePromotionFields(
    BackupAnime actual,
    BackupAnime selected,
  ) {
    if (selected.hasVersion()) {
      actual.version = selected.version;
    } else {
      actual.clearVersion();
    }
    if (selected.hasLastModifiedAt()) {
      actual.lastModifiedAt = selected.lastModifiedAt;
    } else {
      actual.clearLastModifiedAt();
    }
    return actual;
  }

  BackupChapter _copyChapterVersion(
    BackupChapter actual,
    BackupChapter selected,
  ) {
    if (selected.hasVersion()) {
      actual.version = selected.version;
    } else {
      actual.clearVersion();
    }
    return actual;
  }

  BackupEpisode _copyEpisodeVersion(
    BackupEpisode actual,
    BackupEpisode selected,
  ) {
    if (selected.hasVersion()) {
      actual.version = selected.version;
    } else {
      actual.clearVersion();
    }
    return actual;
  }

  BackupHistory _copyHistoryClock(
    BackupHistory actual,
    BackupHistory selected,
  ) {
    if (selected.hasLastRead()) {
      actual.lastRead = selected.lastRead;
    } else {
      actual.clearLastRead();
    }
    return actual;
  }

  BackupNovel _copyNovelClock(BackupNovel actual, BackupNovel selected) {
    if (selected.hasLastModified()) {
      actual.lastModified = selected.lastModified;
    } else {
      actual.clearLastModified();
    }
    return actual;
  }

  BackupNovelStat _copyNovelStatClock(
    BackupNovelStat actual,
    BackupNovelStat selected,
  ) {
    if (selected.hasLastStatisticModified()) {
      actual.lastStatisticModified = selected.lastStatisticModified;
    } else {
      actual.clearLastStatisticModified();
    }
    return actual;
  }

  bool _containsPendingPreferences(
    BackupMihon uploaded,
    BackupMihon pending,
    BackupMihon localIntent,
  ) {
    final currentPreferences = _lastByKey(
      localIntent.backupPreferences,
      (preference) => preference.key,
    );
    final uploadedPreferences = _lastByKey(
      uploaded.backupPreferences,
      (preference) => preference.key,
    );
    for (final pendingPreference in pending.backupPreferences) {
      final selected = currentPreferences[pendingPreference.key];
      final actual = uploadedPreferences[pendingPreference.key];
      if (selected == null) {
        // The engine preserves legacy/unsupported pending values in effective
        // local intent. Absence here is therefore a proven post-restore delete.
        if (actual != null) return false;
        continue;
      }
      if (actual == null || !_sameKnownWithSelectedUnknown(actual, selected)) {
        return false;
      }
      if (selected.hasValue() &&
          (!_unknownFieldsEndWith(actual.value, selected.value))) {
        return false;
      }
    }

    final currentGroups = _lastByKey(
      localIntent.backupSourcePreferences,
      (group) => group.sourceKey,
    );
    final uploadedGroups = _lastByKey(
      uploaded.backupSourcePreferences,
      (group) => group.sourceKey,
    );
    for (final pendingGroup in pending.backupSourcePreferences) {
      final selectedGroup = currentGroups[pendingGroup.sourceKey];
      final actualGroup = uploadedGroups[pendingGroup.sourceKey];
      if (selectedGroup == null) {
        if (actualGroup != null) {
          final pendingKeys = {
            for (final preference in pendingGroup.prefs) preference.key,
          };
          if (actualGroup.prefs.any(
            (preference) => pendingKeys.contains(preference.key),
          )) {
            return false;
          }
        }
        continue;
      }
      if (actualGroup == null) return false;
      if (!_unknownFieldsEndWith(actualGroup, selectedGroup)) return false;
      final selectedPreferences = _lastByKey(
        selectedGroup.prefs,
        (preference) => preference.key,
      );
      final actualPreferences = _lastByKey(
        actualGroup.prefs,
        (preference) => preference.key,
      );
      for (final pendingPreference in pendingGroup.prefs) {
        final selected = selectedPreferences[pendingPreference.key];
        final actual = actualPreferences[pendingPreference.key];
        if (selected == null) {
          if (actual != null) return false;
          continue;
        }
        if (actual == null ||
            !_sameKnownWithSelectedUnknown(actual, selected)) {
          return false;
        }
        if (selected.hasValue() &&
            !_unknownFieldsEndWith(actual.value, selected.value)) {
          return false;
        }
      }
    }
    return true;
  }

  bool _containsSelectedRows<T extends GeneratedMessage, K>({
    required Iterable<T> uploaded,
    required Iterable<T> selected,
    required K Function(T value) keyOf,
  }) => _containsSelectedMessages(
    actual: uploaded,
    selected: selected,
    keyOf: keyOf,
  );

  bool _containsSelectedMessages<T extends GeneratedMessage, K>({
    required Iterable<T> actual,
    required Iterable<T> selected,
    required K Function(T value) keyOf,
    T Function(T actual, T selected)? normalize,
  }) {
    // A few Mihon/Chimahon exports contain duplicate child identities (for
    // example, two chapter rows with the same URL but different display
    // metadata). Match those rows one-to-one instead of collapsing them to
    // the last value for a key. The latter made a valid restored payload fail
    // the safety audit whenever duplicate rows differed.
    final actualByKey = <K, List<T>>{};
    for (final actualValue in actual) {
      actualByKey.putIfAbsent(keyOf(actualValue), () => []).add(actualValue);
    }
    for (final selectedValue in selected) {
      final candidates = actualByKey[keyOf(selectedValue)];
      if (candidates == null) return false;
      final match = candidates.indexWhere((candidate) {
        final normalized =
            normalize?.call(candidate.deepCopy(), selectedValue) ?? candidate;
        return _sameKnownWithSelectedUnknown(normalized, selectedValue);
      });
      if (match < 0) return false;
      candidates.removeAt(match);
    }
    return true;
  }

  bool _sameKnownWithSelectedUnknown<T extends GeneratedMessage>(
    T actual,
    T selected,
  ) {
    final actualKnown = actual.deepCopy()..unknownFields.clear();
    final selectedKnown = selected.deepCopy()..unknownFields.clear();
    return sameMessageBytes(actualKnown, selectedKnown) &&
        _unknownFieldsEndWith(actual, selected);
  }

  bool _containsSelectedNovelCategories(
    Iterable<BackupNovelCategory> uploaded,
    Iterable<BackupNovelCategory> selected,
  ) {
    final remaining = uploaded.toList();
    for (final selectedCategory in selected) {
      final index = remaining.indexWhere(
        (candidate) => _sameNovelCategoryIdentity(candidate, selectedCategory),
      );
      if (index < 0 ||
          !_sameKnownWithSelectedUnknown(remaining[index], selectedCategory)) {
        return false;
      }
      remaining.removeAt(index);
    }
    return true;
  }

  List<BackupNovelCategory> _selectedNovelCategories(
    Iterable<BackupNovelCategory> pending,
    Iterable<BackupNovelCategory> current,
  ) {
    final currentList = current.toList();
    return [
      for (final selected in pending)
        currentList.firstWhere(
          (candidate) => _sameNovelCategoryIdentity(candidate, selected),
          orElse: () => selected,
        ),
    ];
  }

  List<BackupNovelCategory> _overlayNovelCategories({
    required Iterable<BackupNovelCategory> fallback,
    required Iterable<BackupNovelCategory> selected,
  }) {
    final result = [for (final value in fallback) value.deepCopy()];
    for (final selectedValue in selected) {
      final index = result.indexWhere(
        (candidate) => _sameNovelCategoryIdentity(candidate, selectedValue),
      );
      if (index < 0) {
        result.add(selectedValue.deepCopy());
      } else {
        result[index] = _selectedOverFallback(selectedValue, result[index]);
      }
    }
    return result;
  }

  bool _sameNovelCategoryIdentity(
    BackupNovelCategory left,
    BackupNovelCategory right,
  ) =>
      (left.id.isNotEmpty && left.id == right.id) ||
      _normalized(left.name) == _normalized(right.name);

  List<T> _selectedRows<T extends GeneratedMessage, K>({
    required Iterable<T> pending,
    required Iterable<T> current,
    required K Function(T value) keyOf,
  }) {
    final currentByKey = _lastByKey(current, keyOf);
    return [
      for (final pendingValue in pending)
        (currentByKey[keyOf(pendingValue)] ?? pendingValue).deepCopy(),
    ];
  }

  /// Category membership in Chimahon is encoded with [BackupCategory.order].
  /// Reapplying an older selected category can therefore collide with a
  /// cloud-only category even though the ordinary merger had already made its
  /// category orders unique. Keep selected orders where possible, move only
  /// colliding fallback rows, and remap both selected and fallback media by
  /// category name so neither membership silently changes meaning.
  void _canonicalizeCategoryOrdersAndRemapMedia<T extends GeneratedMessage>({
    required List<BackupCategory> categories,
    required Iterable<BackupCategory> selectedCategories,
    required Iterable<BackupCategory> selectedSourceCategories,
    required Iterable<BackupCategory> fallbackSourceCategories,
    required Iterable<T> media,
    required Set<String> selectedMediaKeys,
    required String Function(T value) keyOf,
    required List<Int64> Function(T value) categoryOrdersOf,
  }) {
    final selectedNames = selectedCategories.map(_categoryKey).toSet();
    final selectedIndexes = <int>[];
    final fallbackIndexes = <int>[];
    for (var index = 0; index < categories.length; index++) {
      (selectedNames.contains(_categoryKey(categories[index]))
              ? selectedIndexes
              : fallbackIndexes)
          .add(index);
    }

    final usedOrders = <Int64>{};
    final finalOrderByName = <String, Int64>{};
    var nextFreeOrder = Int64.ZERO;
    for (final index in [...selectedIndexes, ...fallbackIndexes]) {
      final category = categories[index];
      var order = category.order;
      if (!usedOrders.add(order)) {
        while (usedOrders.contains(nextFreeOrder)) {
          nextFreeOrder += 1;
        }
        order = nextFreeOrder;
        category.order = order;
        usedOrders.add(order);
      }
      finalOrderByName[_categoryKey(category)] = order;
    }

    final selectedNameByOrder = {
      for (final category in selectedSourceCategories)
        category.order: _categoryKey(category),
    };
    final fallbackNameByOrder = {
      for (final category in fallbackSourceCategories)
        category.order: _categoryKey(category),
    };
    for (final value in media) {
      final nameByOrder = selectedMediaKeys.contains(keyOf(value))
          ? selectedNameByOrder
          : fallbackNameByOrder;
      final remapped = <Int64>[];
      final seen = <Int64>{};
      for (final oldOrder in categoryOrdersOf(value)) {
        final name = nameByOrder[oldOrder];
        final newOrder = name == null ? null : finalOrderByName[name];
        if (newOrder != null && seen.add(newOrder)) remapped.add(newOrder);
      }
      categoryOrdersOf(value)
        ..clear()
        ..addAll(remapped);
    }
  }

  List<T> _overlaySelected<T extends GeneratedMessage, K>({
    required Iterable<T> fallback,
    required Iterable<T> selected,
    required K Function(T value) keyOf,
    required T Function(T selected, T fallback) overlay,
  }) {
    final result = [for (final value in fallback) value.deepCopy()];
    final indexByKey = <K, int>{
      for (var index = 0; index < result.length; index++)
        keyOf(result[index]): index,
    };
    for (final selectedValue in selected) {
      final key = keyOf(selectedValue);
      final index = indexByKey[key];
      if (index == null) {
        indexByKey[key] = result.length;
        result.add(selectedValue.deepCopy());
      } else {
        result[index] = overlay(selectedValue, result[index]);
      }
    }
    return result;
  }

  Map<K, T> _lastByKey<T extends GeneratedMessage, K>(
    Iterable<T> values,
    K Function(T value) keyOf,
  ) => {for (final value in values) keyOf(value): value};

  T _selectedOverFallback<T extends GeneratedMessage>(T selected, T fallback) {
    final result = selected.deepCopy()..unknownFields.clear();
    result
      ..mergeUnknownFields(fallback.unknownFields)
      ..mergeUnknownFields(selected.unknownFields);
    return result;
  }

  void _putSelectedUnknownFieldsLast(
    GeneratedMessage target,
    GeneratedMessage selected,
  ) {
    final previous = target.unknownFields.clone();
    target.unknownFields
      ..clear()
      ..mergeFromUnknownFieldSet(previous)
      ..mergeFromUnknownFieldSet(selected.unknownFields);
  }

  bool _unknownFieldsEndWith(
    GeneratedMessage actual,
    GeneratedMessage selected,
  ) {
    for (final entry in selected.unknownFields.asMap().entries) {
      final actualField = actual.unknownFields.getField(entry.key);
      if (actualField == null ||
          !_endsWith(actualField.varints, entry.value.varints) ||
          !_endsWith(actualField.fixed32s, entry.value.fixed32s) ||
          !_endsWith(actualField.fixed64s, entry.value.fixed64s) ||
          !_endsWith(actualField.groups, entry.value.groups) ||
          !_byteListsEndWith(
            actualField.lengthDelimited,
            entry.value.lengthDelimited,
          )) {
        return false;
      }
    }
    return true;
  }

  bool _endsWith<T>(List<T> actual, List<T> suffix) {
    if (suffix.length > actual.length) return false;
    final offset = actual.length - suffix.length;
    for (var index = 0; index < suffix.length; index++) {
      if (actual[offset + index] != suffix[index]) return false;
    }
    return true;
  }

  bool _byteListsEndWith(List<List<int>> actual, List<List<int>> suffix) {
    if (suffix.length > actual.length) return false;
    final offset = actual.length - suffix.length;
    for (var index = 0; index < suffix.length; index++) {
      final actualBytes = actual[offset + index];
      final suffixBytes = suffix[index];
      if (actualBytes.length != suffixBytes.length) return false;
      for (var byte = 0; byte < suffixBytes.length; byte++) {
        if (actualBytes[byte] != suffixBytes[byte]) return false;
      }
    }
    return true;
  }

  Int64 _promoteIfNeeded(Int64 selected, Int64 competing) {
    if (selected > competing) return selected;
    if (competing == Int64.MAX_VALUE) {
      throw StateError(
        'Cannot promote a selected Chimahon restore record above Int64.MAX_VALUE.',
      );
    }
    return competing + 1;
  }

  // Chimahon identifies ordered manga/anime categories by their exact names.
  // Names that differ only by case or surrounding whitespace can coexist and
  // must not collapse while a pending restore is reapplied.
  String _categoryKey(BackupCategory category) => category.name;

  String _mangaKey(BackupManga manga) => chimahonMangaIdentity(manga);

  String _animeKey(BackupAnime anime) => chimahonAnimeIdentity(anime);

  String _chapterKey(BackupChapter chapter) => chimahonChapterIdentity(chapter);

  String _episodeKey(BackupEpisode episode) => chimahonEpisodeIdentity(episode);

  String _novelKey(BackupNovel novel) {
    final title = _normalized(novel.title);
    final author = _normalized(novel.author);
    if (title.isEmpty && author.isEmpty) return novel.id;
    return md5.convert(utf8.encode('$title|$author')).toString();
  }

  String _normalized(String value) => value.trim().toLowerCase();
}
