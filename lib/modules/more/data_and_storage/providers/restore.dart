import 'dart:async';
import 'dart:convert';

import 'package:mangayomi/services/sync/chimahon_anime_seasons.dart';
import 'package:archive/archive_io.dart';
import 'package:bot_toast/bot_toast.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/eval/model/m_bridge.dart';
import 'package:mangayomi/l10n/generated/app_localizations.dart';
import 'package:mangayomi/eval/model/source_preference.dart';
import 'package:mangayomi/models/category.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/custom_button.dart';
import 'package:mangayomi/models/download.dart';
import 'package:mangayomi/models/epub_book_progress.dart';
import 'package:mangayomi/models/update.dart';
import 'package:mangayomi/models/history.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/models/sync_preference.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/models/track.dart';
import 'package:mangayomi/models/track_preference.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupAniyomi.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupAnime.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupCategory.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/widgets/backup_encryption_password_dialog.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupSource.pb.dart';
import 'package:mangayomi/services/sync/chimahon_app_settings_adapter.dart';
import 'package:mangayomi/services/sync/chimahon_deferred_payload_store.dart';
import 'package:mangayomi/services/sync/chimahon_manual_restore_category_adapter.dart';
import 'package:mangayomi/services/sync/chimahon_manual_restore_adapter.dart';
import 'package:mangayomi/services/sync/chimahon_mining_settings_adapter.dart';
import 'package:mangayomi/services/sync/chimahon_local_sync_projection_service.dart';
import 'package:mangayomi/services/sync/chimahon_media_sync_selection.dart';
import 'package:mangayomi/services/sync/chimahon_manga_title_adapter.dart';
import 'package:mangayomi/services/sync/chimahon_novel_materializer.dart';
import 'package:mangayomi/services/statistics/immersion_stats_models.dart';
import 'package:mangayomi/services/statistics/immersion_stats_storage.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';
import 'package:mangayomi/services/reconcile_mihon_sources.dart';
import 'package:mangayomi/services/sync/chimahon_stats_adapter.dart';
import 'package:mangayomi/services/sync/chimahon_sync_importer.dart';
import 'package:mangayomi/services/sync/chimahon_sync_codec.dart';
import 'package:mangayomi/services/sync/chimahon_restore_sync_coordinator.dart';
import 'package:mangayomi/services/sync/chimahon_source_preferences_adapter.dart';
import 'package:mangayomi/services/sync/mihon_backup_source_resolver.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/blend_level_state_provider.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/animation_duration_scale_provider.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/flex_scheme_color_state_provider.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/pure_black_dark_mode_state_provider.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/theme_mode_state_provider.dart';
import 'package:mangayomi/modules/more/settings/browse/providers/browse_state_provider.dart';
import 'package:mangayomi/modules/more/settings/sync/providers/sync_providers.dart';
import 'package:mangayomi/modules/more/settings/reader/providers/reader_state_provider.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/router/router.dart';
import 'package:mangayomi/services/backup_password_storage.dart';
import 'package:mangayomi/repositories/category_repository.dart';
import 'package:mangayomi/repositories/chapter_repository.dart';
import 'package:mangayomi/repositories/custom_button_repository.dart';
import 'package:mangayomi/repositories/download_repository.dart';
import 'package:mangayomi/repositories/history_repository.dart';
import 'package:mangayomi/repositories/manga_repository.dart';
import 'package:mangayomi/repositories/restore_repository.dart';
import 'package:mangayomi/repositories/settings_repository.dart';
import 'package:mangayomi/repositories/source_preference_repository.dart';
import 'package:mangayomi/repositories/source_repository.dart';
import 'package:mangayomi/repositories/track_repository.dart';
import 'package:mangayomi/repositories/update_repository.dart';
import 'package:mangayomi/services/sync_server.dart';
import 'package:mangayomi/utils/constant.dart';
import 'package:mangayomi/utils/error_toast.dart';
import 'package:protobuf/protobuf.dart';
import 'package:mangayomi/utils/log/logger.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:mangayomi/main.dart';
part 'restore.g.dart';

@riverpod
Future<void> doRestore(
  Ref ref, {
  required String path,
  required BuildContext context,
  bool merge = false,
  Map<String, bool> categoryDecisions = const {},
  Map<String, int> sourceDecisions = const {},
  // Already-decoded/decrypted mangayomi-format backup, if the caller ran
  // decodeMangayomiBackup itself to preview it first. Skips re-decoding
  // (and re-prompting for a password) here.
  Map<String, dynamic>? decodedMangayomiBackup,
  // Caller's answer to "upload this restore to your sync server?", asked
  // only when a server was connected. true = upload, false = the user chose
  // to turn sync off instead (so stale server data can't come back and
  // undo this restore), null = no server was connected, nothing to do.
  bool? syncAfterRestore,
}) async {
  // Without this, doRestore is autoDispose with only the calling widget's
  // watch keeping it alive — if that widget unmounts mid-restore (dialog
  // closes, screen pops), the provider gets disposed mid-flight and every
  // ref use below throws UnmountedRefException.
  ref.keepAlive();
  // Resolved before any await, so it's safe to use after one.
  final l10n = l10nLocalizations(context);
  // Yield once first: doRestore is itself a provider, and mutating another
  // provider synchronously before its first await counts as modifying it
  // "during initialization", which Riverpod forbids. A microtask (not a
  // real delay) so no frame runs in between — a real delay let the busy
  // dialog close and unmount this autoDispose provider's context first.
  await Future<void>.value();
  // Blocks the auto-sync timer and any manual sync trigger until this
  // restore (and its post-restore upload, if any) finishes — otherwise
  // either could race the restore and pull stale server data back down.
  ref.read(restoreSyncGuardProvider.notifier).start();
  var uploadStarted = false;
  try {
    // Zip filenames aren't encrypted even when file content is, so this
    // initial pass (no password) is always enough to list files and
    // determine backup type. Password resolution only happens below, and
    // only for the mangayomi format, right before reading file *content*.
    final Archive archive;
    final BackupType backupType;
    final tachiType = _tachiBackupTypeFromPath(path);
    if (tachiType != null) {
      archive = Archive();
      backupType = tachiType;
    } else {
      final probeStream = InputFileStream(path);
      try {
        archive = ZipDecoder().decodeStream(probeStream);
      } finally {
        probeStream.close();
      }
      backupType = checkBackupType(path, archive);
    }
    switch (backupType) {
      case BackupType.mangayomi:
        if (!context.mounted) return;
        final backup =
            decodedMangayomiBackup ??
            await decodeMangayomiBackup(path, context);
        await ref.read(
          restoreBackupProvider(
            backup,
            merge: merge,
            categoryDecisions: categoryDecisions,
            sourceDecisions: sourceDecisions,
          ).future,
        );
        break;
      case BackupType.kotatsu:
        await ref.read(restoreKotatsuBackupProvider(archive).future);
        break;
      case BackupType.mihon:
      case BackupType.aniyomi:
      case BackupType.neko:
        await ref.read(
          restoreTachiBkBackupProvider(
            path,
            backupType,
            merge: merge,
            categoryDecisions: categoryDecisions,
            sourceDecisions: sourceDecisions,
          ).future,
        );
        break;
      default:
    }
    if (backupType != BackupType.unknown) {
      showBotToast("Backup restored!");
      if (syncAfterRestore == false) {
        // User declined to push this restore to the server — turn sync off
        // rather than leave it running, since the next sync would otherwise
        // pull the server's old data back down and undo the restore.
        final syncNotifier = ref.read(synchingProvider(syncId: 1).notifier);
        syncNotifier.setSyncOn(false);
        syncNotifier.setAutoSyncFrequency(0);
        if (l10n != null) botToast(l10n.sync_disabled_after_restore);
      } else if (syncAfterRestore == true && l10n != null) {
        // Sync may have been disabled by a previous restore — re-enable it
        // before pushing, since startSync below is the connection check
        // (its own error handling reports a bad server/credentials).
        ref.read(synchingProvider(syncId: 1).notifier).setSyncOn(true);
        // Not awaited: this pushes to the sync server over the network, and
        // shouldn't hold up the restore flow (e.g. a caller's busy dialog)
        // waiting on it. It owns clearing the guard once it settles.
        uploadStarted = true;
        unawaited(_uploadToSyncServerIfConnected(ref, l10n));
      }
    } else {
      showBotToast("Backup Type not supported!");
    }
  } catch (e, s) {
    toastError(e, stack: s, source: 'restore');
  } finally {
    if (!uploadStarted) {
      ref.read(restoreSyncGuardProvider.notifier).finish();
    }
  }
}

/// Pushes the just-restored data to the sync server (if connected) so it
/// isn't left holding the pre-restore state, which the next sync would
/// otherwise pull back down and undo the restore. Silently skipped when no
/// server is configured. Always clears the restore guard on the way out,
/// since doRestore hands off ownership of it to this function once called.
Future<void> _uploadToSyncServerIfConnected(
  Ref ref,
  AppLocalizations l10n,
) async {
  try {
    final syncPreference = ref.read(synchingProvider(syncId: 1));
    final connected =
        (syncPreference.authToken?.isNotEmpty ?? false) &&
        (syncPreference.server?.isNotEmpty ?? false);
    if (!connected) return;
    botToast(l10n.restore_sync_uploading);
    // silent: true suppresses startSync's own generic "Starting/Finished"
    // toasts (this one is restore-specific below) - it still shows its own
    // "Sync failed" toast on failure, so that case doesn't need one here.
    final success = await ref
        .read(syncServerProvider(syncId: 1).notifier)
        .startSync(l10n, true, upload: true, bypassRestoreGuard: true);
    if (success) {
      botToast(l10n.restore_sync_upload_success);
    }
  } catch (e) {
    botToast(
      "Backup restored, but couldn't push it to your sync server: $e. "
      "The server still has the old data until the next successful sync.",
    );
  } finally {
    ref.read(restoreSyncGuardProvider.notifier).finish();
  }
}

/// Decodes a mangayomi-format backup's JSON contents, transparently
/// handling AES-encrypted backups: tries with no password, then the
/// locally-stored password (if any), then prompts the user - retrying on a
/// wrong password until it succeeds or the user cancels.
///
/// On success, if the backup embeds an encryption password (see
/// `backup.dart`), persists it locally so future backups/restores on this
/// device don't need it retyped - mirroring how every other part of a
/// restored backup overwrites the local settings, just kept out of the
/// generic Settings JSON round-trip (see backup_password_fallback.dart).
///
/// Public so the restore UI can decode+preview a mangayomi-format backup
/// (merge/replace choice, category/source conflicts) before committing to
/// the actual restore - doRestore accepts the result back as
/// decodedMangayomiBackup so it isn't decrypted (and the password
/// re-prompted) a second time.
Future<Map<String, dynamic>> decodeMangayomiBackup(
  String path,
  BuildContext context,
) async {
  String? passwordToTry;
  var triedStoredPassword = false;
  var wasIncorrect = false;
  final l10n = l10nLocalizations(context)!;

  while (true) {
    final stream = InputFileStream(path);
    try {
      final archive = ZipDecoder().decodeStream(
        stream,
        password: passwordToTry,
      );
      // decodeStream() only parses headers and buffers raw compressed
      // bytes - it doesn't verify/decrypt content (and so won't throw on a
      // wrong password) until the content is actually read, hence forcing
      // that access here rather than after returning.
      final bytes = archive.files.first.content as List<int>;
      final backup = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

      final embeddedPassword = backup['backupEncryptionPassword'] as String?;
      if (embeddedPassword != null && context.mounted) {
        await persistResolvedPassword(embeddedPassword, context);
      }
      return backup;
    } catch (_) {
      if (!triedStoredPassword) {
        triedStoredPassword = true;
        final stored = await BackupPasswordStorage.get();
        if (stored != null) {
          passwordToTry = stored;
          continue;
        }
      }
      if (!context.mounted) rethrow;
      final entered = await showBackupDecryptPasswordDialog(
        context,
        wasIncorrect: wasIncorrect,
      );
      if (entered == null) {
        throw Exception(l10n.password_required_to_restore);
      }
      passwordToTry = entered;
      wasIncorrect = true;
    } finally {
      stream.close();
    }
  }
}

void showBotToast(String text) {
  BotToast.showNotification(
    animationDuration: const Duration(milliseconds: 200),
    animationReverseDuration: const Duration(milliseconds: 200),
    duration: const Duration(seconds: 5),
    backButtonBehavior: BackButtonBehavior.none,
    leading: (_) => Image.asset(appIconAssets[1], height: 40),
    title: (_) => Text(text, style: TextStyle(fontWeight: FontWeight.bold)),
    enableSlideOff: true,
    onlyOne: true,
    crossPage: true,
  );
}

enum BackupType { unknown, mangayomi, mihon, aniyomi, kotatsu, neko }

BackupType checkBackupType(String path, Archive archive) {
  final normalizedPath = path.toLowerCase();
  if ((normalizedPath.contains("mangatan") ||
          normalizedPath.contains("mangayomi")) &&
      (archive.files.firstOrNull?.name ?? "").endsWith(".backup.db")) {
    return BackupType.mangayomi;
  } else if (path.toLowerCase().contains("kotatsu") &&
      archive.files.where((f) {
            switch (f.name) {
              case "categories":
              case "favourites":
                return true;
              default:
                return false;
            }
          }).length ==
          2) {
    return BackupType.kotatsu;
  } else if (path.toLowerCase().endsWith(".tachibk") ||
      path.toLowerCase().endsWith(".proto.gz")) {
    return path.contains("xyz.jmir.tachiyomi.mi") || path.contains("aniyomi.mi")
        ? BackupType.aniyomi
        : path.contains("tachiyomi") ||
              path.contains("mihon") ||
              path.contains("komikku")
        ? BackupType.mihon
        : path.contains("neko")
        ? BackupType.neko
        : BackupType.unknown;
  }
  return BackupType.unknown;
}

BackupType peekBackupType(String path) {
  final inputStream = InputFileStream(path);
  try {
    final archive = ZipDecoder().decodeStream(inputStream);
    return checkBackupType(path, archive);
  } finally {
    inputStream.close();
  }
}

class TachiBkImportPreview {
  TachiBkImportPreview({
    required this.conflictingCategories,
    required this.unmatchedSourceNames,
    required this.newSeriesCount,
    required this.updatedSeriesCount,
    required this.newChapterCount,
  });

  final List<String> conflictingCategories;

  final Map<String, ItemType> unmatchedSourceNames;

  final int newSeriesCount;
  final int updatedSeriesCount;
  final int newChapterCount;
}

TachiBkImportPreview? previewTachiBkImport(String path) {
  final backupType = peekBackupType(path);
  if (backupType != BackupType.mihon &&
      backupType != BackupType.aniyomi &&
      backupType != BackupType.neko) {
    return null;
  }
  final inputStream = InputFileStream(path);
  final content = GZipDecoder().decodeBytes(inputStream.toUint8List());
  inputStream.close();
  final backup = BackupMihon.create();
  backup.mergeFromCodedBufferReader(
    CodedBufferReader(content, sizeLimit: 250 << 20),
  );

  final existingCategoryNames = categoryRepository
      .getAll()
      .map((c) => c.name)
      .whereType<String>()
      .toSet();
  final categoryNames = <String>{for (var c in backup.backupCategories) c.name};

  final installedSourceNames = sourceRepository
      .getAll()
      .where((s) => s.isAdded ?? false)
      .map((s) => (s.itemType, s.name?.toLowerCase()))
      .toSet();
  final unmatchedSources = <String, ItemType>{};

  final existingMangaByLink = {
    for (var m in mangaRepository.getByItemType(ItemType.manga))
      if (m.link != null) m.link!: m,
  };
  int newSeries = 0, updatedSeries = 0, newChapters = 0;
  for (var m in backup.backupManga) {
    final sourceId = _protoInt(m.source);
    final srcName =
        backup.backupSources
            .firstWhereOrNull((s) => _protoInt(s.sourceId) == sourceId)
            ?.name ??
        "Unknown";
    if (!installedSourceNames.contains((
      ItemType.manga,
      srcName.toLowerCase(),
    ))) {
      unmatchedSources[srcName] = ItemType.manga;
    }
    final existing = existingMangaByLink[m.url];
    if (existing != null) {
      updatedSeries++;
      final existingUrls = chapterRepository
          .getAllByMangaId(existing.id)
          .map((c) => c.url)
          .whereType<String>()
          .toSet();
      newChapters += m.chapters
          .where((c) => !existingUrls.contains(c.url))
          .length;
    } else {
      newSeries++;
      newChapters += m.chapters.length;
    }
  }

  if (backupType == BackupType.aniyomi) {
    final backupAnime = BackupAniyomi.fromBuffer(content);
    final animeCategories = backupAnime.backupAnimeCategories.isNotEmpty
        ? backupAnime.backupAnimeCategories
        : backupAnime.legacyBackupAnimeCategories;
    final animeEntries = backupAnime.backupAnime.isNotEmpty
        ? backupAnime.backupAnime
        : backupAnime.legacyBackupAnime;
    final animeSources = backupAnime.backupAnimeSources.isNotEmpty
        ? backupAnime.backupAnimeSources
        : backupAnime.legacyBackupAnimeSources;
    categoryNames.addAll(animeCategories.map((c) => c.name));
    final existingAnimeByLink = {
      for (var m in mangaRepository.getByItemType(ItemType.anime))
        if (m.link != null) m.link!: m,
    };
    for (var a in animeEntries) {
      final sourceId = _protoInt(a.source);
      final srcName =
          animeSources
              .firstWhereOrNull((s) => _protoInt(s.sourceId) == sourceId)
              ?.name ??
          "Unknown";
      if (!installedSourceNames.contains((
        ItemType.anime,
        srcName.toLowerCase(),
      ))) {
        unmatchedSources[srcName] = ItemType.anime;
      }
      final existing = existingAnimeByLink[a.url];
      if (existing != null) {
        updatedSeries++;
        final existingUrls = chapterRepository
            .getAllByMangaId(existing.id)
            .map((c) => c.url)
            .whereType<String>()
            .toSet();
        newChapters += a.episodes
            .where((c) => !existingUrls.contains(c.url))
            .length;
      } else {
        newSeries++;
        newChapters += a.episodes.length;
      }
    }
  }

  return TachiBkImportPreview(
    conflictingCategories: categoryNames
        .where(existingCategoryNames.contains)
        .toList(),
    unmatchedSourceNames: unmatchedSources,
    newSeriesCount: newSeries,
    updatedSeriesCount: updatedSeries,
    newChapterCount: newChapters,
  );
}

List<Source> installedSourcesFor(ItemType itemType) => sourceRepository
    .getAll()
    .where((s) => s.itemType == itemType && (s.isAdded ?? false))
    .toList();

/// Same preview shape as previewTachiBkImport, but for the native
/// mangayomi backup format - already-decoded (and, for encrypted backups,
/// already-decrypted) JSON rather than a path to re-read from disk.
TachiBkImportPreview previewMangayomiBackup(Map<String, dynamic> backup) {
  final mangaList = (backup["manga"] as List?)
      ?.map((e) => Manga.fromJson(e)..itemType = _convertToItemType(e))
      .toList();
  final chapterList = (backup["chapters"] as List?)
      ?.map((e) => Chapter.fromJson(e))
      .toList();
  final categoryList = (backup["categories"] as List?)
      ?.map(
        (e) =>
            Category.fromJson(e)..forItemType = _convertToItemTypeCategory(e),
      )
      .toList();

  final existingCategoryNames = categoryRepository
      .getAll()
      .map((c) => c.name)
      .whereType<String>()
      .toSet();
  final categoryNames = <String>{
    for (final c in categoryList ?? <Category>[])
      if (c.name != null) c.name!,
  };

  final installedSourceNames = sourceRepository
      .getAll()
      .where((s) => s.isAdded ?? false)
      .map((s) => (s.itemType, s.name?.toLowerCase()))
      .toSet();
  final unmatchedSources = <String, ItemType>{};

  final existingMangaByKey = {
    for (final m in mangaRepository.getAll())
      if (m.link != null) '${m.itemType.index}|${m.link}': m,
  };
  final chaptersByMangaId = <int, List<Chapter>>{};
  for (final c in chapterList ?? <Chapter>[]) {
    if (c.mangaId == null) continue;
    chaptersByMangaId.putIfAbsent(c.mangaId!, () => []).add(c);
  }

  int newSeries = 0, updatedSeries = 0, newChapters = 0;
  for (final m in mangaList ?? <Manga>[]) {
    final srcName = m.source ?? "Unknown";
    if (!installedSourceNames.contains((m.itemType, srcName.toLowerCase()))) {
      unmatchedSources[srcName] = m.itemType;
    }
    final key = '${m.itemType.index}|${m.link}';
    final existing = m.link != null ? existingMangaByKey[key] : null;
    final mangaChapters = m.id != null
        ? chaptersByMangaId[m.id!] ?? const <Chapter>[]
        : const <Chapter>[];
    if (existing != null) {
      updatedSeries++;
      final existingUrls = chapterRepository
          .getAllByMangaId(existing.id)
          .map((c) => c.url)
          .whereType<String>()
          .toSet();
      newChapters += mangaChapters
          .where((c) => c.url != null && !existingUrls.contains(c.url))
          .length;
    } else {
      newSeries++;
      newChapters += mangaChapters.length;
    }
  }

  return TachiBkImportPreview(
    conflictingCategories: categoryNames
        .where(existingCategoryNames.contains)
        .toList(),
    unmatchedSourceNames: unmatchedSources,
    newSeriesCount: newSeries,
    updatedSeriesCount: updatedSeries,
    newChapterCount: newChapters,
  );
}

int currentFavoriteMangaCount() => mangaRepository.countFavorites();

BackupType? _tachiBackupTypeFromPath(String path) {
  final lower = path.toLowerCase();
  if (!lower.endsWith('.tachibk') && !lower.endsWith('.proto.gz')) {
    return null;
  }
  if (lower.contains('xyz.jmir.tachiyomi.mi') ||
      lower.contains('aniyomi.mi') ||
      lower.contains('anikku')) {
    return BackupType.aniyomi;
  }
  if (lower.contains('neko')) return BackupType.neko;
  // Mihon, Komikku, Chimahon, and their forks share the same current envelope.
  return BackupType.mihon;
}

@riverpod
Future<void> restoreBackup(
  Ref ref,
  Map<String, dynamic> backup, {
  bool full = true,
  // When true, adds this backup's library into the existing one instead of
  // wiping it first - only categories/manga/chapters/history/updates
  // participate (mirrors what Mihon-family merge covers; device config like
  // settings/sources/customButtons is a replace-only concept either way).
  bool merge = false,
  Map<String, bool> categoryDecisions = const {},
  Map<String, int> sourceDecisions = const {},
}) async {
  // This provider is awaited through ref.read(...future) by doRestore. Keep
  // the nested operation alive until the database restore and state
  // invalidation have both completed.
  ref.keepAlive();
  final version = backup['version'];
  if (["1", "2"].any((e) => e == version)) {
    try {
      final manga = (backup["manga"] as List?)
          ?.map((e) => Manga.fromJson(e)..itemType = _convertToItemType(e))
          .toList();
      final chapters = (backup["chapters"] as List?)
          ?.map((e) => Chapter.fromJson(e))
          .toList();
      final categories = (backup["categories"] as List?)
          ?.map(
            (e) =>
                Category.fromJson(e)
                  ..forItemType = _convertToItemTypeCategory(e),
          )
          .toList();
      final track = (backup["tracks"] as List?)
          ?.map((e) => Track.fromJson(e)..itemType = _convertToItemType(e))
          .toList();
      final trackPreferences = (backup["trackPreferences"] as List?)
          ?.map((e) => TrackPreference.fromJson(e))
          .toList();
      final history = (backup["history"] as List?)
          ?.map((e) => History.fromJson(e)..itemType = _convertToItemType(e))
          .toList();
      final downloads = (backup["downloads"] as List?)
          ?.map((e) => Download.fromJson(e))
          .toList();
      final settings = (backup["settings"] as List?)
          ?.map((e) => Settings.fromJson(e))
          .toList();
      final extensions = (backup["extensions"] as List?)
          ?.map((e) => Source.fromJson(e)..itemType = _convertToItemType(e))
          .toList();
      final sourcesPrefs = (backup["extensions_preferences"] as List?)
          ?.map((e) => SourcePreference.fromJson(e))
          .toList();
      final updates = (backup["updates"] as List?)
          ?.map((e) => Update.fromJson(e))
          .toList();
      final customButtons = (backup["customButtons"] as List?)
          ?.map((e) => CustomButton.fromJson(e))
          .toList();

      final currentSettings = settingsRepository.currentOrNull;
      await restoreRepository.run(() {
        if (merge) {
          _mergeMangayomiBackup(
            manga: manga,
            chapters: chapters,
            categories: categories,
            history: history,
            updates: updates,
            categoryDecisions: categoryDecisions,
            sourceDecisions: sourceDecisions,
          );
          return;
        }
        mangaRepository.clearSync();
        if (manga != null) {
          mangaRepository.putAllSync(manga);
          if (chapters != null) {
            isar.chapters.clearSync();
            for (var chapter in chapters) {
              final manga = isar.mangas.getSync(chapter.mangaId!);
              if (manga != null) {
                isar.chapters.putSync(chapter..manga.value = manga);
                chapter.manga.saveSync();
              }
            }

            if (full) {
              downloadRepository.clearSync();
              if (downloads != null) {
                for (var download in downloads) {
                  final chapter = isar.chapters.getSync(download.id!);
                  if (chapter != null) {
                    isar.downloads.putSync(download..chapter.value = chapter);
                    download.chapter.saveSync();
                  }
                }
              }
            }

            historyRepository.clearSync();
            if (history != null) {
              for (var element in history) {
                final chapter = isar.chapters.getSync(element.chapterId!);
                if (chapter != null) {
                  isar.historys.putSync(element..chapter.value = chapter);
                  element.chapter.saveSync();
                }
              }
            }

            updateRepository.clearSync();
            if (updates != null) {
              final tempChapters = isar.chapters
                  .filter()
                  .idIsNotNull()
                  .findAllSync()
                  .toList();
              for (var update in updates) {
                final matchingChapter = tempChapters
                    .where(
                      (chapter) =>
                          chapter.mangaId == update.mangaId &&
                          chapter.name == update.chapterName,
                    )
                    .firstOrNull;
                if (matchingChapter != null) {
                  isar.updates.putSync(update..chapter.value = matchingChapter);
                  update.chapter.saveSync();
                }
              }
            }
          }

          categoryRepository.clearSync();
          if (categories != null) {
            categoryRepository.putAllSync(categories);
          }
        }

        trackRepository.clearSync();
        if (track != null) {
          trackRepository.putAllSync(track);
        }

        if (full) {
          if (trackPreferences != null) {
            trackRepository.clearPreferencesSync();
            trackRepository.putAllPreferencesSync(trackPreferences);
          }
          sourceRepository.clearSync();
          if (extensions != null) {
            sourceRepository.putAllSync(extensions);
          }
          sourcePreferenceRepository.clearSync();
          if (sourcesPrefs != null) {
            sourcePreferenceRepository.putAllSync(sourcesPrefs);
          }
          settingsRepository.clearSync();
          if (settings != null) {
            isar.settings.putAllSync([
              for (final incoming in settings)
                currentSettings == null
                    ? incoming
                    : preserveDeviceLocalSettings(incoming, currentSettings),
            ]);
          }
          customButtonRepository.clearSync();
          if (customButtons != null) {
            customButtonRepository.putAllSync(customButtons);
          }
        }
      });
      if (full) {
        _invalidateCommonState(ref);
      }
    } catch (e) {
      rethrow;
    }
  } else {
    throw "Failed to restore the backup";
  }
}

/// Adds a mangayomi-format backup's library into the existing one instead of
/// wiping it first. Mirrors what restoreTachiBkBackup already does for
/// Mihon-family merges: match manga by link, keep the existing entry's
/// state on conflict, only carry over chapters/history/updates that don't
/// already exist. Everything here re-inserts with a fresh id rather than
/// reusing the backup's original one - unlike a full replace (which clears
/// the tables first, so reusing ids is safe), a merge runs against a
/// non-empty library where the backup's ids could belong to something else
/// entirely on this device.
void _mergeMangayomiBackup({
  required List<Manga>? manga,
  required List<Chapter>? chapters,
  required List<Category>? categories,
  required List<History>? history,
  required List<Update>? updates,
  required Map<String, bool> categoryDecisions,
  required Map<String, int> sourceDecisions,
}) {
  final oldToNewCategoryId = <int, int>{};
  if (categories != null) {
    final existingCategories = categoryRepository.getAll();
    for (final category in categories) {
      final oldId = category.id;
      final existing = existingCategories.firstWhereOrNull(
        (c) => c.name == category.name && c.forItemType == category.forItemType,
      );
      if (existing != null) {
        if (oldId != null) oldToNewCategoryId[oldId] = existing.id!;
        continue;
      }
      if (categoryDecisions[category.name] == false) continue;
      category.id = null;
      categoryRepository.putSync(category);
      if (oldId != null) oldToNewCategoryId[oldId] = category.id!;
    }
  }

  final oldToNewMangaId = <int, int>{};
  final newMangaIds = <int>{};
  String restoreIdentity(Manga entry) {
    final source = entry.itemType == ItemType.anime
        ? entry.mihonSourceId?.toString() ?? '${entry.source}|${entry.lang}'
        : '';
    return '${entry.itemType.index}|$source|${entry.link}';
  }

  if (manga != null) {
    final existingMangaByKey = {
      for (final m in mangaRepository.getAll())
        if (m.link != null) restoreIdentity(m): m,
    };
    for (final tempManga in manga) {
      final oldId = tempManga.id;
      final key = restoreIdentity(tempManga);
      final existing = tempManga.link != null ? existingMangaByKey[key] : null;
      final remappedCategories = (tempManga.categories ?? [])
          .map((id) => oldToNewCategoryId[id])
          .whereType<int>()
          .toList();
      if (existing != null) {
        if (existing.itemType == ItemType.anime) {
          if (existing.animeFetchType == null) {
            existing.animeParentUrl = tempManga.animeParentUrl;
          }
          existing.animeFetchType ??= tempManga.animeFetchType;
          existing.seasonNumber ??= tempManga.seasonNumber;
          existing.seasonSourceOrder ??= tempManga.seasonSourceOrder;
          existing.seasonFlags ??= tempManga.seasonFlags;
          existing.backgroundUrl ??= tempManga.backgroundUrl;
        }
        existing.favorite =
            existing.favorite == true || tempManga.favorite == true;
        existing.categories = {
          ...?existing.categories,
          ...remappedCategories,
        }.toList();
        mangaRepository.putSync(existing);
        if (oldId != null) oldToNewMangaId[oldId] = existing.id!;
        continue;
      }
      final originalSourceName = tempManga.source ?? "Unknown";
      final decidedSourceId = sourceDecisions[originalSourceName];
      final boundSource = decidedSourceId != null
          ? sourceRepository.getById(decidedSourceId)
          : installedSourcesFor(tempManga.itemType).firstWhereOrNull(
              (s) => s.name?.toLowerCase() == originalSourceName.toLowerCase(),
            );
      tempManga.id = null;
      tempManga.categories = remappedCategories;
      tempManga.favorite ??= true;
      if (boundSource != null) {
        tempManga.sourceId = boundSource.id;
        tempManga.source = boundSource.name;
      } else {
        tempManga.sourceId = null;
      }
      mangaRepository.putSync(tempManga);
      if (oldId != null) oldToNewMangaId[oldId] = tempManga.id!;
      newMangaIds.add(tempManga.id!);
    }
  }

  final oldToNewChapterId = <int, int>{};
  if (chapters != null) {
    final existingUrlsByMangaId = <int, Set<String>>{};
    for (final tempChapter in chapters) {
      final newMangaId = tempChapter.mangaId != null
          ? oldToNewMangaId[tempChapter.mangaId]
          : null;
      if (newMangaId == null) continue;
      // Only ever landed on genuinely new manga above - an existing manga's
      // own chapters (with real read/download state) are left untouched.
      if (!newMangaIds.contains(newMangaId)) continue;
      final existingUrls = existingUrlsByMangaId.putIfAbsent(
        newMangaId,
        () => chapterRepository
            .getAllByMangaId(newMangaId)
            .map((c) => c.url)
            .whereType<String>()
            .toSet(),
      );
      if (tempChapter.url != null && existingUrls.contains(tempChapter.url)) {
        continue;
      }
      final mangaRef = mangaRepository.findById(newMangaId);
      if (mangaRef == null) continue;
      final oldId = tempChapter.id;
      tempChapter.id = null;
      tempChapter.mangaId = newMangaId;
      chapterRepository.putSync(tempChapter..manga.value = mangaRef);
      tempChapter.manga.saveSync();
      if (tempChapter.url != null) existingUrls.add(tempChapter.url!);
      if (oldId != null) oldToNewChapterId[oldId] = tempChapter.id!;
    }
  }

  if (history != null) {
    for (final tempHistory in history) {
      final newChapterId = tempHistory.chapterId != null
          ? oldToNewChapterId[tempHistory.chapterId]
          : null;
      final newMangaId = tempHistory.mangaId != null
          ? oldToNewMangaId[tempHistory.mangaId]
          : null;
      // Only for chapters we just inserted above - an existing chapter's
      // history already reflects this device's own progress.
      if (newChapterId == null || newMangaId == null) continue;
      final chapterRef = chapterRepository.findByIdSync(newChapterId);
      if (chapterRef == null) continue;
      tempHistory.id = null;
      tempHistory.mangaId = newMangaId;
      tempHistory.chapterId = newChapterId;
      historyRepository.putSync(tempHistory..chapter.value = chapterRef);
      tempHistory.chapter.saveSync();
    }
  }

  if (updates != null) {
    for (final tempUpdate in updates) {
      final newMangaId = tempUpdate.mangaId != null
          ? oldToNewMangaId[tempUpdate.mangaId]
          : null;
      if (newMangaId == null || !newMangaIds.contains(newMangaId)) continue;
      final chapter = chapterRepository.findByMangaIdAndName(
        newMangaId,
        tempUpdate.chapterName,
      );
      if (chapter == null) continue;
      tempUpdate.id = null;
      tempUpdate.mangaId = newMangaId;
      updateRepository.putSync(tempUpdate..chapter.value = chapter);
      tempUpdate.chapter.saveSync();
    }
  }
}

ItemType _convertToItemType(Map<String, dynamic> backup) {
  final isManga = backup['isManga'];
  return isManga == null
      ? ItemType.values[backup['itemType'] ?? 0]
      : isManga
      ? ItemType.manga
      : ItemType.anime;
}

ItemType _convertToItemTypeCategory(Map<String, dynamic> backup) {
  final forManga = backup['forManga'];
  return forManga == null
      ? ItemType.values[backup['forItemType'] ?? 0]
      : forManga
      ? ItemType.manga
      : ItemType.anime;
}

@riverpod
Future<void> restoreKotatsuBackup(Ref ref, Archive archive) async {
  // This provider is awaited through ref.read(...future) by doRestore. Keep
  // the nested operation alive until the restore has finished using ref.
  ref.keepAlive();
  try {
    for (var f in archive.files) {
      List<Category> cats = [];
      switch (f.name) {
        case "categories":
          final categories = jsonDecode(utf8.decode(f.content)) as List? ?? [];
          await restoreRepository.run(() {
            categoryRepository.clearSync();
            for (var category in categories) {
              final cat = Category(
                id: category["id"],
                name: category["title"],
                forItemType: ItemType.manga,
                hide: !(category["show_in_lib"] ?? true),
              );
              categoryRepository.putSync(cat);
              cats.add(cat);
            }
          });
        case "favourites":
          final favourites = jsonDecode(utf8.decode(f.content)) as List? ?? [];
          await restoreRepository.run(() {
            mangaRepository.clearSync();
            for (var favourite in favourites) {
              final tempManga = favourite["manga"];
              final manga = Manga(
                source: tempManga["source"],
                author: tempManga["author"],
                artist: null,
                genre:
                    (tempManga["tags"] as List?)
                        ?.map((t) => t["title"] as String)
                        .toList() ??
                    [],
                imageUrl: tempManga["large_cover_url"],
                lang: 'en',
                link: tempManga["url"],
                name: tempManga["title"],
                status: Status.values.firstWhere(
                  (s) =>
                      s.name.toLowerCase() ==
                      (tempManga["state"] as String?)?.toLowerCase(),
                  orElse: () => Status.unknown,
                ),
                description: null,
                categories: [favourite["category_id"]],
                itemType: ItemType.manga,
                favorite: true,
                sourceId: null,
              );
              mangaRepository.putSync(manga);
            }
          });
        default:
          continue;
      }
    }
    await restoreRepository.run(() {
      chapterRepository.clearSync();
      downloadRepository.clearSync();
      historyRepository.clearSync();
      updateRepository.clearSync();
      trackRepository.clearSync();
      trackRepository.clearPreferencesSync();
    });
    _invalidateCommonState(ref);
  } catch (e) {
    rethrow;
  }
}

@riverpod
Future<void> restoreTachiBkBackup(
  Ref ref,
  String path,
  BackupType bkType, {
  bool merge = false,
  Map<String, bool> categoryDecisions = const {},
  Map<String, int> sourceDecisions = const {},
}) async {
  // doRestore awaits this nested auto-dispose provider through
  // ref.read(...future). Without an explicit keep-alive, Riverpod can dispose
  // it during the restore and invalidate Ref before the final import steps.
  ref.keepAlive();
  final inputStream = InputFileStream(path);
  late final DecodedChimahonSync decoded;
  try {
    decoded = const ChimahonSyncCodec().decode(inputStream.toUint8List());
  } finally {
    inputStream.close();
  }
  final content = decoded.protobufBytes;
  final backup = decoded.backup;
  await restoreTachiBkBackupData(ref, backup, content, bkType);
}

Future<void> restoreTachiBkBackupData(
  Ref ref,
  BackupMihon backup,
  List<int> content,
  BackupType bkType, {
  ChimahonDeferredPayloadStore? pendingManualRestoreStore,
}) => ChimahonRestoreSyncCoordinator.shared.duringManualRestore(
  () => _restoreTachiBkBackupDataExclusive(
    ref,
    backup,
    content,
    bkType,
    pendingManualRestoreStore: pendingManualRestoreStore,
  ),
);

Future<void> _restoreTachiBkBackupDataExclusive(
  Ref ref,
  BackupMihon backup,
  List<int> content,
  BackupType bkType, {
  ChimahonDeferredPayloadStore? pendingManualRestoreStore,
}) async {
  final localSources = isar.sources.filter().idIsNotNull().findAllSync();
  final shouldRestoreAnime =
      bkType == BackupType.aniyomi ||
      backup.backupAnime.isNotEmpty ||
      backup.backupAnimeCategories.isNotEmpty;
  final legacyAnimeBackup = shouldRestoreAnime
      ? BackupAniyomi.fromBuffer(content)
      : null;
  final List<BackupCategory> animeCategories =
      backup.backupAnimeCategories.isNotEmpty
      ? backup.backupAnimeCategories.toList()
      : legacyAnimeBackup?.backupAnimeCategories.isNotEmpty == true
      ? legacyAnimeBackup!.backupAnimeCategories.toList()
      : legacyAnimeBackup?.legacyBackupAnimeCategories.toList() ?? const [];
  final List<BackupAnime> animeEntries = backup.backupAnime.isNotEmpty
      ? backup.backupAnime.toList()
      : legacyAnimeBackup?.backupAnime.isNotEmpty == true
      ? legacyAnimeBackup!.backupAnime.toList()
      : legacyAnimeBackup?.legacyBackupAnime.toList() ?? const [];
  final List<BackupSource> animeSources = backup.backupAnimeSources.isNotEmpty
      ? backup.backupAnimeSources.toList()
      : legacyAnimeBackup?.backupAnimeSources.isNotEmpty == true
      ? legacyAnimeBackup!.backupAnimeSources.toList()
      : legacyAnimeBackup?.legacyBackupAnimeSources.toList() ?? const [];
  final pendingBackup = backup.deepCopy();
  if (pendingBackup.backupAnime.isEmpty) {
    pendingBackup.backupAnime.addAll(animeEntries);
  }
  if (pendingBackup.backupAnimeCategories.isEmpty) {
    pendingBackup.backupAnimeCategories.addAll(animeCategories);
  }
  if (pendingBackup.backupAnimeSources.isEmpty) {
    pendingBackup.backupAnimeSources.addAll(animeSources);
  }
  // Preserve the exact restore payload (including fields this Mangatan build
  // cannot project) until a conditional Chimahon upload succeeds. Persist it
  // before destructive database work so a partial restore cannot lose data.
  final pendingStore =
      pendingManualRestoreStore ??
      await defaultChimahonPendingManualRestoreStore();
  if (pendingStore case ChimahonPendingManualRestoreLifecycleStore lifecycle) {
    await lifecycle.beginPreparing(pendingBackup);
  } else {
    // Custom stores predating the lifecycle keep their legacy ready behavior.
    await pendingStore.save(pendingBackup);
  }
  const manualRestoreAdapter = ChimahonManualRestoreAdapter();
  const novelMaterializer = ChimahonNovelMaterializer();
  final libraryNovels = chimahonEpubLibraryNovels(
    backup,
  ).toList(growable: false);
  final localNovelProgress = isar.epubBookProgress.where().findAllSync();
  final allLocalChapters = isar.chapters.where().findAllSync();
  final allLocalArchiveMangas = isar.mangas
      .filter()
      .isLocalArchiveEqualTo(true)
      .findAllSync();
  final obsoleteCloudNovelParentIds = novelMaterializer
      .staleCloudNovelParentIds(
        localMangas: allLocalArchiveMangas,
        localProgress: localNovelProgress,
        localChapters: allLocalChapters,
        remote: libraryNovels,
      );
  final localArchiveMangas = allLocalArchiveMangas
      .where((manga) => !obsoleteCloudNovelParentIds.contains(manga.id))
      .toList(growable: false);
  final localArchiveIds = localArchiveMangas
      .map((manga) => manga.id)
      .whereType<int>()
      .toSet();
  final manualOverlayChapters = allLocalChapters
      .where(
        (chapter) =>
            !localArchiveIds.contains(chapter.mangaId) &&
            manualRestoreAdapter.isDeviceLocalChapter(chapter),
      )
      .toList(growable: false);
  final manualOverlayParentIds = manualOverlayChapters
      .map((chapter) => chapter.mangaId)
      .whereType<int>()
      .toSet();
  final retainedLocalMangas = [
    ...localArchiveMangas,
    ...isar.mangas.where().findAllSync().where(
      (manga) => manualOverlayParentIds.contains(manga.id),
    ),
  ];
  final retainedLocalMangaIds = retainedLocalMangas
      .map((manga) => manga.id)
      .whereType<int>()
      .toSet();
  final retainedLocalChapters = [
    ...allLocalChapters.where(
      (chapter) => localArchiveIds.contains(chapter.mangaId),
    ),
    ...manualOverlayChapters,
  ];
  final retainedLocalChapterIds = retainedLocalChapters
      .map((chapter) => chapter.id)
      .whereType<int>()
      .toSet();
  final retainedLocalHistories = isar.historys
      .where()
      .findAllSync()
      .where((history) => retainedLocalChapterIds.contains(history.chapterId))
      .toList(growable: false);
  final retainedLastReadByMangaId = <int, int>{};
  for (final manga in retainedLocalMangas) {
    final mangaId = manga.id;
    if (mangaId == null) continue;
    retainedLastReadByMangaId[mangaId] = manualRestoreAdapter.retainedLastRead(
      parentLastRead: manga.lastRead,
      histories: retainedLocalHistories.where(
        (history) => history.mangaId == mangaId,
      ),
    );
  }
  final retainedLocalTracks = manualRestoreAdapter
      .trackingRowsForRetainedParents(
        tracks: isar.tracks.where().findAllSync(),
        retainedParentIds: retainedLocalMangaIds,
      );
  final retainedTracksByMangaId = <int, List<Track>>{};
  for (final track in retainedLocalTracks) {
    final mangaId = track.mangaId;
    if (mangaId != null) {
      retainedTracksByMangaId.putIfAbsent(mangaId, () => []).add(track);
    }
  }
  final localCategories = isar.categorys.where().findAllSync();
  final retainedLocalCategoryIds = retainedLocalMangas
      .expand((manga) => manga.categories ?? const <int>[])
      .toSet();
  final categoryPlan = const ChimahonManualRestoreCategoryAdapter().build(
    localCategories: localCategories,
    retainedLocalCategoryIds: retainedLocalCategoryIds,
    mangaCategories: backup.backupCategories,
    animeCategories: animeCategories,
    novelCategories: backup.backupNovelCategories,
  );
  final retainedNovelProgress = localNovelProgress
      .where((progress) => retainedLocalMangaIds.contains(progress.mangaId))
      .toList(growable: false);
  final novelPlan = novelMaterializer.plan(
    localMangas: retainedLocalMangas,
    localProgress: retainedNovelProgress,
    localChapters: retainedLocalChapters,
    remote: libraryNovels,
  );
  isar.writeTxnSync(() {
    isar.categorys.clearSync();
    isar.mangas.clearSync();
    isar.chapters.clearSync();
    isar.historys.clearSync();
    isar.tracks.clearSync();
    // Progress belongs to retained local EPUB parents or to remote ghosts
    // materialized below. Clearing first prevents an orphan from suppressing
    // a remote book and then attaching to a reused auto-increment parent ID.
    isar.epubBookProgress.clearSync();
    for (final category in categoryPlan.categoriesForInsertion) {
      isar.categorys.putSync(category);
    }
    for (final manga in retainedLocalMangas) {
      manga.hasLocalChapterOverlay = manualOverlayParentIds.contains(manga.id);
      final remoteNovelCategoryIds =
          novelPlan.remoteCategoryIdsByMangaId[manga.id] ?? const <String>[];
      manga.categories = manga.itemType != ItemType.novel
          ? categoryPlan.remapLocalIds(manga.categories)
          : novelPlan.authoritativeCloudParentIds.contains(manga.id)
          ? categoryPlan.idsForNovelBackupIds(remoteNovelCategoryIds)
          : categoryPlan.idsForRetainedNovelTitle(
              localIds: manga.categories,
              backupIds: remoteNovelCategoryIds,
            );
      isar.mangas.putSync(manga);
    }
    if (retainedNovelProgress.isNotEmpty) {
      isar.epubBookProgress.putAllSync(retainedNovelProgress);
    }
    for (final cloudNovel in novelPlan.cloudNovels) {
      cloudNovel.parent.categories = categoryPlan.idsForNovelBackupIds(
        cloudNovel.remote.categoryIds,
      );
      isar.mangas.putSync(cloudNovel.parent);
      cloudNovel.progress.mangaId = cloudNovel.parent.id!;
      isar.epubBookProgress.putSync(cloudNovel.progress);
    }
    for (final chapter in retainedLocalChapters) {
      final manga = isar.mangas.getSync(chapter.mangaId!);
      if (manga == null) continue;
      isar.chapters.putSync(chapter..manga.value = manga);
      chapter.manga.saveSync();
    }
    for (final history in retainedLocalHistories) {
      final chapter = isar.chapters.getSync(history.chapterId!);
      if (chapter == null) continue;
      isar.historys.putSync(history..chapter.value = chapter);
      history.chapter.saveSync();
    }
    if (retainedLocalTracks.isNotEmpty) {
      isar.tracks.putAllSync(retainedLocalTracks);
    }
    for (var tempManga in backup.backupManga) {
      final nativeSourceId = _protoInt(tempManga.source);
      final resolvedSource = resolveMihonBackupSource(
        nativeId: nativeSourceId,
        backupSources: backup.backupSources,
        localSources: localSources,
      );
      final categoryOrders = tempManga.categories.map(_protoInt).toSet();
      final titles = const ChimahonMangaTitleAdapter().fromBackup(tempManga);
      final retained = _findRetainedRestoreTitle(
        retained: retainedLocalMangas,
        itemType: ItemType.manga,
        source: resolvedSource,
        url: tempManga.url,
        sourceTitle: titles.sourceTitle,
      );
      final manga = Manga(
        id: retained?.id,
        source: resolvedSource.name,
        author: tempManga.author,
        artist: tempManga.artist,
        genre: tempManga.genre,
        imageUrl: tempManga.thumbnailUrl,
        lang: resolvedSource.language,
        link: tempManga.url,
        name: titles.displayTitle,
        sourceTitle: titles.sourceTitle,
        status: _convertStatusFromTachiBk(tempManga.status),
        description: tempManga.description,
        categories: categoryPlan.idsForRetainedTitle(
          localIds: retained?.categories,
          itemType: ItemType.manga,
          backupOrders: categoryOrders,
        ),
        itemType: ItemType.manga,
        favorite: tempManga.hasFavorite() ? tempManga.favorite : true,
        favoriteModifiedAt: manualRestoreAdapter.mangaFavoriteModifiedAt(
          tempManga,
        ),
        dateAdded: normalizeMihonTimestamp(_protoInt(tempManga.dateAdded)),
        lastRead: retained?.id == null
            ? 0
            : retainedLastReadByMangaId[retained!.id!] ?? retained.lastRead,
        lastUpdate: normalizeMihonTimestamp(
          _protoInt(tempManga.lastModifiedAt),
        ),
        sourceId: resolvedSource.localId,
        isManga: retained?.isManga,
        isLocalArchive: retained?.isLocalArchive ?? false,
        hasLocalChapterOverlay:
            retained != null && manualOverlayParentIds.contains(retained.id),
        customCoverImage: retained?.customCoverImage,
        customCoverFromTracker: retained?.customCoverFromTracker,
        smartUpdateDays: retained?.smartUpdateDays,
        updatedAt: manualRestoreAdapter.updatedAtFromLastModified(
          _protoInt(tempManga.lastModifiedAt),
        ),
      );
      if (bkType == BackupType.neko) {
        manga.source = "MangaDex";
      }
      isar.mangas.putSync(manga);
      final chaptersByUrl = <String, Chapter>{};
      for (var tempChapter in tempManga.chapters) {
        final chapter = manualRestoreAdapter.mangaChapterRow(
          remote: tempChapter,
          mangaId: manga.id!,
          dateUpload: bkType != BackupType.neko
              ? normalizeMihonTimestamp(_protoInt(tempChapter.dateUpload))
              : DateTime.now().millisecondsSinceEpoch -
                    _protoInt(tempChapter.dateUpload).abs(),
        );
        chapterRepository.putSync(chapter..manga.value = manga);
        chapter.manga.saveSync();
        chaptersByUrl[tempChapter.url] = chapter;
      }
      var lastRead = manga.lastRead ?? 0;
      for (final tempHistory in tempManga.history) {
        final chapter = chaptersByUrl[tempHistory.url];
        if (chapter == null) continue;
        final readAt = normalizeMihonTimestamp(_protoInt(tempHistory.lastRead));
        lastRead = readAt > lastRead ? readAt : lastRead;
        final history = History(
          mangaId: manga.id,
          date: '$readAt',
          itemType: ItemType.manga,
          chapterId: chapter.id,
          readingTimeSeconds: Duration(
            milliseconds: _protoInt(tempHistory.readDuration),
          ).inSeconds,
        )..chapter.value = chapter;
        isar.historys.putSync(history);
        history.chapter.saveSync();
      }
      if (lastRead > 0) isar.mangas.putSync(manga..lastRead = lastRead);
      final restoredTracks = manualRestoreAdapter.trackingRows(
        remote: tempManga.tracking,
        mangaId: manga.id!,
        itemType: ItemType.manga,
        parentModifiedAt: _protoInt(tempManga.lastModifiedAt),
        existing: retainedTracksByMangaId[manga.id] ?? const <Track>[],
      );
      if (restoredTracks.isNotEmpty) {
        isar.tracks.putAllSync(restoredTracks);
      }
    }
  });
  if (shouldRestoreAnime) {
    final seasonParents = chimahonSeasonParents(animeEntries);
    isar.writeTxnSync(() {
      for (var tempAnime in animeEntries) {
        final nativeSourceId = _protoInt(tempAnime.source);
        final resolvedSource = resolveMihonBackupSource(
          nativeId: nativeSourceId,
          backupSources: animeSources,
          localSources: localSources,
        );
        final categoryOrders = tempAnime.categories.map(_protoInt).toSet();
        final retained = _findRetainedRestoreTitle(
          retained: retainedLocalMangas,
          itemType: ItemType.anime,
          source: resolvedSource,
          url: tempAnime.url,
          sourceTitle: tempAnime.title,
        );
        final anime = Manga(
          id: retained?.id,
          source: resolvedSource.name,
          author: tempAnime.author,
          artist: tempAnime.artist,
          genre: tempAnime.genre,
          imageUrl: tempAnime.thumbnailUrl,
          lang: resolvedSource.language,
          link: tempAnime.url,
          name: tempAnime.title,
          status: _convertStatusFromTachiBk(tempAnime.status),
          description: tempAnime.description,
          categories: categoryPlan.idsForRetainedTitle(
            localIds: retained?.categories,
            itemType: ItemType.anime,
            backupOrders: categoryOrders,
          ),
          itemType: ItemType.anime,
          favorite: tempAnime.hasFavorite() ? tempAnime.favorite : true,
          favoriteModifiedAt: manualRestoreAdapter.animeFavoriteModifiedAt(
            tempAnime,
          ),
          dateAdded: normalizeMihonTimestamp(_protoInt(tempAnime.dateAdded)),
          lastRead: retained?.id == null
              ? 0
              : retainedLastReadByMangaId[retained!.id!] ?? retained.lastRead,
          lastUpdate: normalizeMihonTimestamp(
            _protoInt(tempAnime.lastModifiedAt),
          ),
          sourceId: resolvedSource.localId,
          isManga: retained?.isManga,
          isLocalArchive: retained?.isLocalArchive ?? false,
          hasLocalChapterOverlay:
              retained != null && manualOverlayParentIds.contains(retained.id),
          customCoverImage: retained?.customCoverImage,
          customCoverFromTracker: retained?.customCoverFromTracker,
          smartUpdateDays: retained?.smartUpdateDays,
          updatedAt: manualRestoreAdapter.updatedAtFromLastModified(
            _protoInt(tempAnime.lastModifiedAt),
          ),
        );
        applyChimahonAnimeSeasons(anime, tempAnime, seasonParents[tempAnime]);
        isar.mangas.putSync(anime);
        final episodesByUrl = <String, Chapter>{};
        for (var tempEpisode in tempAnime.episodes) {
          final episode = manualRestoreAdapter.animeEpisodeRow(
            remote: tempEpisode,
            mangaId: anime.id!,
            dateUpload: normalizeMihonTimestamp(
              _protoInt(tempEpisode.dateUpload),
            ),
          );
          chapterRepository.putSync(episode..manga.value = anime);
          episode.manga.saveSync();
          episodesByUrl[tempEpisode.url] = episode;
        }
        var lastRead = anime.lastRead ?? 0;
        for (final tempHistory in tempAnime.history) {
          final episode = episodesByUrl[tempHistory.url];
          if (episode == null) continue;
          final readAt = normalizeMihonTimestamp(
            _protoInt(tempHistory.lastRead),
          );
          lastRead = readAt > lastRead ? readAt : lastRead;
          final history = History(
            mangaId: anime.id,
            date: '$readAt',
            itemType: ItemType.anime,
            chapterId: episode.id,
            readingTimeSeconds: Duration(
              milliseconds: _protoInt(tempHistory.readDuration),
            ).inSeconds,
          )..chapter.value = episode;
          isar.historys.putSync(history);
          history.chapter.saveSync();
        }
        if (lastRead > 0) isar.mangas.putSync(anime..lastRead = lastRead);
        final restoredTracks = manualRestoreAdapter.trackingRows(
          remote: tempAnime.tracking,
          mangaId: anime.id!,
          itemType: ItemType.anime,
          parentModifiedAt: _protoInt(tempAnime.lastModifiedAt),
          existing: retainedTracksByMangaId[anime.id] ?? const <Track>[],
        );
        if (restoredTracks.isNotEmpty) {
          isar.tracks.putAllSync(restoredTracks);
        }
      }
    });
  }
  isar.writeTxnSync(() {
    // Chimahon has no representation for Mangatan's tracker account
    // preferences, so an explicit restore must leave that local table intact.
    isar.downloads.clearSync();
    isar.updates.clearSync();
  });
  await _importChimahonSettings(ref, backup);
  await _importImmersionStats(backup, replace: true);
  _importChimahonMediaSelection(ref, backup);
  ref.invalidate(synchingProvider(syncId: 1));
  if (pendingStore case ChimahonLocalPreferenceBaselineStore preferenceStore) {
    final syncPreference =
        isar.syncPreferences.getSync(1) ?? SyncPreference(syncId: 1);
    final projection = await ChimahonLocalSyncProjectionService(
      database: isar,
      mediaSelection: ChimahonMediaSyncSelection(
        manga: syncPreference.chimahonSyncManga,
        anime: syncPreference.chimahonSyncAnime,
        novels: syncPreference.chimahonSyncNovels,
      ),
      mediaSelectionInitialized:
          syncPreference.chimahonMediaSelectionInitialized,
    ).createSnapshot();
    await preferenceStore.saveLocalPreferenceBaseline(
      projection.backup.backupPreferences,
    );
    if (pendingStore
        case ChimahonLocalSourcePreferenceBaselineStore sourceStore) {
      await sourceStore.saveLocalSourcePreferenceBaseline(
        projection.backup.backupSourcePreferences,
      );
    }
  }
  if (pendingStore case ChimahonPendingManualRestoreLifecycleStore lifecycle) {
    await lifecycle.markReady();
  }
  _invalidateCommonState(ref);
}

/// Restores immersion statistics from a Chimahon-compatible backup.
///
/// A manual restore is an explicit "make this device look like the backup", so
/// it replaces the local rows. Sync merges instead, because both sides may hold
/// reading the other has not seen.
Future<void> _importImmersionStats(
  BackupMihon backup, {
  required bool replace,
}) async {
  const adapter = ChimahonStatsAdapter();
  final mangaStats = adapter.importAllMangaStats(backup.backupMangaStats);
  final ankiStats = adapter.importAllAnkiStats(backup.backupAnkiStats);
  final novelStats = <String, List<NovelStatsEntry>>{};
  for (final novel in backup.backupNovels) {
    if (novel.stats.isEmpty || novel.id.isEmpty) continue;
    novelStats
        .putIfAbsent(novel.id, () => [])
        .addAll(adapter.importAllNovelStats(novel.stats));
  }

  if (replace) {
    await ImmersionStatsStorage.clear();
    await ImmersionStatsStorage.saveMangaStats(mangaStats);
    await ImmersionStatsStorage.saveAnkiStats(ankiStats);
    for (final entry in novelStats.entries) {
      await ImmersionStatsStorage.saveNovelStats(entry.key, entry.value);
    }
    return;
  }
  await ImmersionStatsStorage.mergeMangaStats(mangaStats);
  await ImmersionStatsStorage.mergeAnkiStats(ankiStats);
  for (final entry in novelStats.entries) {
    await ImmersionStatsStorage.mergeNovelStats(entry.key, entry.value);
  }
}

void _importChimahonMediaSelection(Ref ref, BackupMihon backup) {
  final preferences = backup.backupPreferences;
  if (!ChimahonMediaSyncSelection.hasAnyPreference(preferences)) {
    return;
  }
  isar.writeTxnSync(() {
    final preference =
        isar.syncPreferences.getSync(1) ?? SyncPreference(syncId: 1);
    final selection = chimahonMediaSelectionForExplicitRestore(
      preferences: preferences,
      current: ChimahonMediaSyncSelection(
        manga: preference.chimahonSyncManga,
        anime: preference.chimahonSyncAnime,
        novels: preference.chimahonSyncNovels,
      ),
    );
    final malformed = ChimahonMediaSyncSelection.hasMalformedPreference(
      preferences,
    );
    final nextGeneration = preference.chimahonMediaSelectionGeneration + 1;
    preference
      ..chimahonSyncManga = selection.manga
      ..chimahonSyncAnime = selection.anime
      ..chimahonSyncNovels = selection.novels
      ..chimahonMediaSelectionInitialized = !malformed
      ..chimahonMediaSelectionUserSelected = !malformed
      ..chimahonMediaSelectionScopeToken = null
      ..chimahonMediaSelectionGeneration = nextGeneration;
    isar.syncPreferences.putSync(preference);
  });
  _invalidateCommonState(ref);
}

/// Applies a Chimahon sync payload while preserving device-only artifacts.
///
/// Routine merge sync is incremental. Passing [authoritativeSelection] makes
/// the enabled media scopes remote-authoritative while retaining downloads,
/// manual chapters, archives, EPUB files, and disabled scopes. Matching title
/// and chapter IDs remain stable in both modes.
Future<ChimahonSyncImportResult> restoreChimahonSyncData(
  Ref ref,
  BackupMihon backup, {
  ChimahonMediaSyncSelection? authoritativeSelection,
}) async {
  final totalWatch = Stopwatch()..start();
  final mediaWatch = Stopwatch()..start();
  var result = const ChimahonSyncImporter().apply(
    database: isar,
    backup: backup,
    authoritativeSelection: authoritativeSelection,
  );
  mediaWatch.stop();
  final settingsWatch = Stopwatch()..start();
  final factoryRefresh = await _importChimahonSettings(
    ref,
    backup,
    preserveUnrepresentableLocalSettings: true,
  );
  settingsWatch.stop();
  result = result.withSourceReconciliation(
    rebound: factoryRefresh.reconciliation.rebound,
    unavailable: factoryRefresh.reconciliation.unavailable,
    unresolved: factoryRefresh.unresolvedGroups,
  );
  final statisticsWatch = Stopwatch()..start();
  await _importImmersionStats(backup, replace: false);
  statisticsWatch.stop();
  _invalidateCommonState(ref);
  totalWatch.stop();
  AppLogger.log(
    'Chimahon import performance: total=${_syncMilliseconds(totalWatch.elapsed)}ms '
    'media=${_syncMilliseconds(mediaWatch.elapsed)}ms '
    'settings=${_syncMilliseconds(settingsWatch.elapsed)}ms '
    'statistics=${_syncMilliseconds(statisticsWatch.elapsed)}ms',
    logLevel: LogLevel.debug,
  );
  return result;
}

Future<MihonFactoryRefreshResult> _importChimahonSettings(
  Ref ref,
  BackupMihon backup, {
  bool preserveUnrepresentableLocalSettings = false,
}) async {
  final totalWatch = Stopwatch()..start();
  final snapshotWatch = Stopwatch()..start();
  final miningSnapshot = await MiningPreferences.writableSnapshot();
  snapshotWatch.stop();
  final localSettingsWatch = Stopwatch()..start();
  late final Stopwatch miningWatch;
  late final ChimahonSourcePreferencesImportResult sourcePreferencesImport;
  try {
    isar.writeTxnSync(() {
      final settings = isar.settings.getSync(227);
      if (settings != null) {
        const adapter = ChimahonAppSettingsAdapter();
        final preserveLocalKeys = preserveUnrepresentableLocalSettings
            ? adapter.project(settings).unrepresentableKeys
            : const <String>{};
        adapter.importInto(
          settings,
          backup.backupPreferences,
          preserveLocalKeys: preserveLocalKeys,
        );
        isar.settings.putSync(settings);
      }
    });
    const sourcePreferencesAdapter = ChimahonSourcePreferencesAdapter();
    sourcePreferencesImport = sourcePreferencesAdapter.importInto(
      database: isar,
      sourcePreferences: backup.backupSourcePreferences,
    );
    localSettingsWatch.stop();
    miningWatch = Stopwatch()..start();
    final sources = isar.sources.filter().idIsNotNull().findAllSync();
    const miningAdapter = ChimahonMiningSettingsAdapter();
    final portableSourceIds = chimahonPortableSourceOverrideIds(sources);
    final preserveLocalMiningKeys = preserveUnrepresentableLocalSettings
        ? (await miningAdapter.project(portableSourceIds: portableSourceIds))
              .unrepresentableKeys
        : const <String>{};
    await miningAdapter.import(
      backup.backupPreferences,
      portableSourceIds: portableSourceIds,
      preserveLocalKeys: preserveLocalMiningKeys,
    );
    miningWatch.stop();
  } catch (_) {
    await MiningPreferences.restoreSnapshot(miningSnapshot);
    rethrow;
  }
  // JVM discovery is deliberately outside the settings rollback boundary.
  // A missing bridge leaves native IDs unresolved and retryable; it must not
  // revert an otherwise successful authoritative settings import.
  final factoryWatch = Stopwatch()..start();
  final factoryRefresh = await refreshInstalledMihonFactorySources(
    ref,
    remoteSourcePreferences: backup.backupSourcePreferences,
    replacePresentPreferences: true,
    requiredNativeSourceIds: {
      for (final source in backup.backupSources)
        source.sourceId.toInt().toString(),
      for (final source in backup.backupAnimeSources)
        source.sourceId.toInt().toString(),
      for (final manga in backup.backupManga) manga.source.toInt().toString(),
      for (final anime in backup.backupAnime) anime.source.toInt().toString(),
    },
    changedPreferenceSourceIds: sourcePreferencesImport.valueChangedSourceIds,
  );
  factoryWatch.stop();
  final reconcileWatch = Stopwatch()..start();
  if (factoryRefresh.groupsReconciled > 0) {
    const ChimahonSourcePreferencesAdapter().importInto(
      database: isar,
      sourcePreferences: backup.backupSourcePreferences,
    );
  }
  reconcileWatch.stop();
  totalWatch.stop();
  AppLogger.log(
    'Chimahon settings import performance: '
    'total=${_syncMilliseconds(totalWatch.elapsed)}ms '
    'snapshot=${_syncMilliseconds(snapshotWatch.elapsed)}ms '
    'local=${_syncMilliseconds(localSettingsWatch.elapsed)}ms '
    'mining=${_syncMilliseconds(miningWatch.elapsed)}ms '
    'factory=${_syncMilliseconds(factoryWatch.elapsed)}ms '
    'reconcile=${_syncMilliseconds(reconcileWatch.elapsed)}ms '
    'factoryGroups=${factoryRefresh.groupsReconciled} '
    'unresolvedGroups=${factoryRefresh.unresolvedGroups}',
    logLevel: LogLevel.debug,
  );
  return factoryRefresh;
}

String _syncMilliseconds(Duration duration) =>
    (duration.inMicroseconds / Duration.microsecondsPerMillisecond)
        .toStringAsFixed(2);

int _protoInt(Object value) {
  if (value is int) {
    return value;
  }
  return (value as dynamic).toInt() as int;
}

/// Keeps fields that describe this device rather than the library: folder
/// paths, the Java runtime, and the proxy. A backup made on another device
/// would otherwise point them at paths that do not exist here.
Settings preserveDeviceLocalSettings(Settings incoming, Settings current) {
  return incoming
    ..id = current.id
    ..localFolders = current.localFolders
    ..askDownloadDestination = current.askDownloadDestination
    ..androidProxyServer = current.androidProxyServer
    ..jrePath = current.jrePath
    ..extensionServerPath = current.extensionServerPath;
}

void _invalidateCommonState(Ref ref) {
  // Sync markers are durable local intent. In particular, tracker deletion
  // tombstones are cleared by SyncServer only after a successful upload.
  // A restore/import must not clear unrelated or concurrently-created rows.
  ref.invalidate(followSystemThemeStateProvider);
  ref.invalidate(themeModeStateProvider);
  ref.invalidate(animationDurationScaleProvider);
  ref.invalidate(blendLevelStateProvider);
  ref.invalidate(flexSchemeColorStateProvider);
  ref.invalidate(pureBlackDarkModeStateProvider);
  ref.invalidate(l10nLocaleStateProvider);
  ref.invalidate(navigationOrderStateProvider);
  ref.invalidate(hideItemsStateProvider);
  ref.invalidate(extensionsRepoStateProvider(ItemType.manga));
  ref.invalidate(extensionsRepoStateProvider(ItemType.anime));
  ref.invalidate(extensionsRepoStateProvider(ItemType.novel));
  ref.read(routerCurrentLocationStateProvider.notifier).refresh();
}

Manga? _findRetainedRestoreTitle({
  required Iterable<Manga> retained,
  required ItemType itemType,
  required ResolvedMihonBackupSource source,
  required String url,
  required String sourceTitle,
}) => const ChimahonManualRestoreAdapter().retainedTitle(
  retained: retained,
  itemType: itemType,
  source: source,
  url: url,
  sourceTitle: sourceTitle,
);

Status _convertStatusFromTachiBk(int idx) {
  switch (idx) {
    case 1:
      return Status.ongoing;
    case 2:
      return Status.completed;
    case 4:
      return Status.publishingFinished;
    case 5:
      return Status.canceled;
    case 6:
      return Status.onHiatus;
    default:
      return Status.unknown;
  }
}
