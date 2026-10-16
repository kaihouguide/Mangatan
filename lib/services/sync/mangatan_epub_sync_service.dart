import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/epub_book_progress.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/services/epub_chapter_metadata.dart';
import 'package:mangayomi/services/sync/chimahon_novel_materializer.dart';
import 'package:mangayomi/services/sync/chimahon_novel_progress_adapter.dart';
import 'package:mangayomi/services/sync/cross_device_sync_storage.dart';
import 'package:mangayomi/services/sync/mangatan_epub_blob_storage.dart';
import 'package:mangayomi/services/sync/mangatan_epub_sync_manifest.dart';
import 'package:mangayomi/src/rust/api/epub.dart';
import 'package:mangayomi/utils/log/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class MangatanEpubSyncResult {
  const MangatanEpubSyncResult({
    this.blobsUploaded = 0,
    this.blobsDownloaded = 0,
    this.placeholdersMaterialized = 0,
    this.entriesAdvertised = 0,
    this.entriesRetained = 0,
    this.placeholdersFailed = 0,
  });

  final int blobsUploaded;
  final int blobsDownloaded;
  final int placeholdersMaterialized;
  final int entriesAdvertised;
  final int entriesRetained;

  /// Cloud books whose EPUB could not be downloaded or attached this time.
  /// They stay placeholders and are retried on the next sync.
  final int placeholdersFailed;

  bool get changedAnything =>
      blobsUploaded > 0 ||
      blobsDownloaded > 0 ||
      placeholdersMaterialized > 0;
}

class MangatanEpubSyncService {
  MangatanEpubSyncService({
    required this.database,
    required this.storage,
    required this.deviceId,
    this.materializer = const ChimahonNovelMaterializer(),
    this.progressAdapter = const ChimahonNovelProgressAdapter(),
    this.downloadDirectory,
  });

  final Isar database;
  final MangatanEpubBlobStorage storage;
  final String deviceId;
  final ChimahonNovelMaterializer materializer;
  final ChimahonNovelProgressAdapter progressAdapter;
  final Directory? downloadDirectory;

  Future<MangatanEpubSyncResult> synchronize() async {
    final remote = await storage.downloadEpubManifest();
    final remoteManifest =
        remote?.manifest ?? MangatanEpubManifest.empty(deviceId: deviceId);
    final localEntries = await _localEntries();
    var blobsUploaded = 0;
    for (final entry in localEntries.values) {
      if (await storage.hasEpubBlob(entry.sha256)) continue;
      await storage.uploadEpubBlob(
        sha256: entry.sha256,
        sizeBytes: entry.sizeBytes,
        bytes: File(_localArchivePathFor(entry)).openRead(),
      );
      blobsUploaded++;
    }

    final mergedEntries = <String, MangatanEpubManifestEntry>{
      ...remoteManifest.entries,
      ...localEntries,
    };
    final retained = remoteManifest.entries.keys
        .where((key) => !localEntries.containsKey(key))
        .length;
    final entriesChanged = !_sameEntryMaps(remoteManifest.entries, mergedEntries);
    final proposed = remoteManifest.mergeLocalEntries(
      generatedAtUtc: DateTime.now().toUtc(),
      deviceId: deviceId,
      localEntries: localEntries,
    );
    if (entriesChanged || remoteManifest.deviceId != deviceId) {
      await storage.uploadEpubManifest(
        proposed,
        expectedRevision: remote?.revision,
        expectedAbsent: remote == null,
      );
    }
    final downloadResult = await materializeMissingPlaceholders(proposed);
    return MangatanEpubSyncResult(
      blobsUploaded: blobsUploaded,
      blobsDownloaded: downloadResult.blobsDownloaded,
      placeholdersMaterialized: downloadResult.placeholdersMaterialized,
      placeholdersFailed: downloadResult.placeholdersFailed,
      entriesAdvertised: localEntries.length,
      entriesRetained: retained,
    );
  }

  Future<MangatanEpubSyncResult> materializeRemoteOnly() async {
    final remote = await storage.downloadEpubManifest();
    if (remote == null) return const MangatanEpubSyncResult();
    return materializeMissingPlaceholders(remote.manifest);
  }

  Future<MangatanEpubSyncResult> materializeMissingPlaceholders(
    MangatanEpubManifest manifest,
  ) async {
    final progress = database.epubBookProgress.where().findAllSync();
    final missingProgress = progress
        .where(materializer.isCloudOnlyProgress)
        .toList(growable: false);
    if (missingProgress.isEmpty) return const MangatanEpubSyncResult();

    var downloaded = 0;
    var materialized = 0;
    var failed = 0;
    for (final placeholder in missingProgress) {
      final stableId = progressAdapter.stableLocalIdOrNull(placeholder);
      if (stableId == null) continue;
      final entry = manifest.entries[stableId];
      if (entry == null || entry.deleted) continue;
      // One missing or corrupt blob must not keep every other book from
      // downloading, nor fail a sync whose library data already completed.
      try {
        final target = await _downloadTargetFor(entry);
        if (!await _verifiedFileExists(target, entry)) {
          await _downloadVerifiedBlob(entry, target);
          downloaded++;
        }
        if (await _attachDownloadedEpub(placeholder, entry, target)) {
          materialized++;
        }
      } catch (error) {
        failed++;
        AppLogger.log(
          'Could not download synced EPUB ${entry.stableNovelId}: '
          '${error.runtimeType}',
          logLevel: LogLevel.warning,
        );
      }
    }
    return MangatanEpubSyncResult(
      blobsDownloaded: downloaded,
      placeholdersMaterialized: materialized,
      placeholdersFailed: failed,
    );
  }

  Future<Map<String, MangatanEpubManifestEntry>> _localEntries() async {
    final entries = <String, MangatanEpubManifestEntry>{};
    final progresses = database.epubBookProgress.where().findAllSync();
    for (final progress in progresses) {
      if (materializer.isCloudOnlyProgress(progress)) continue;
      final stableId = progressAdapter.stableLocalIdOrNull(progress);
      if (stableId == null) continue;
      final path = progress.archivePath.trim();
      if (path.isEmpty) continue;
      final file = File(path);
      if (!await file.exists()) continue;
      final List<int> bytes;
      try {
        bytes = await file.readAsBytes();
      } on FileSystemException {
        // An unreadable local file is simply not advertised this time.
        continue;
      }
      final digest = sha256.convert(bytes).toString();
      entries[stableId] = MangatanEpubManifestEntry(
        stableNovelId: stableId,
        sha256: digest,
        sizeBytes: bytes.length,
        fileName: p.basename(path),
        title: progress.title,
        author: progress.author,
        lang: progress.lang,
        updatedAtUtc: DateTime.fromMillisecondsSinceEpoch(
          progress.lastModified ?? 0,
          isUtc: true,
        ),
      );
      _archivePathByEntry[digest] = path;
    }
    return entries;
  }

  final Map<String, String> _archivePathByEntry = {};

  String _localArchivePathFor(MangatanEpubManifestEntry entry) =>
      _archivePathByEntry[entry.sha256] ??
      (throw StateError('Missing local EPUB path for ${entry.stableNovelId}'));

  Future<Directory> _downloadRoot() async =>
      downloadDirectory ??
      Directory(
        p.join(
          (await getApplicationSupportDirectory()).path,
          'mangatan_epub_sync',
          'downloads',
        ),
      );

  Future<File> _downloadTargetFor(MangatanEpubManifestEntry entry) async {
    final safeName = entry.fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final root = await _downloadRoot();
    return File(
      p.join(root.path, entry.stableNovelId, '${entry.sha256}-$safeName'),
    );
  }

  Future<void> _downloadVerifiedBlob(
    MangatanEpubManifestEntry entry,
    File target,
  ) async {
    await target.parent.create(recursive: true);
    final temp = File('${target.path}.part');
    final bytes = await storage.downloadEpubBlob(entry.sha256);
    if (bytes.length != entry.sizeBytes ||
        sha256.convert(bytes).toString() != entry.sha256) {
      throw SyncStorageException(
        'Downloaded EPUB for ${entry.title} failed integrity verification',
      );
    }
    await temp.writeAsBytes(bytes, flush: true);
    if (await target.exists()) await target.delete();
    await temp.rename(target.path);
  }

  Future<bool> _verifiedFileExists(
    File file,
    MangatanEpubManifestEntry entry,
  ) async {
    if (!await file.exists()) return false;
    final bytes = await file.readAsBytes();
    return bytes.length == entry.sizeBytes &&
        sha256.convert(bytes).toString() == entry.sha256;
  }

  Future<bool> _attachDownloadedEpub(
    EpubBookProgress placeholder,
    MangatanEpubManifestEntry entry,
    File file,
  ) async {
    final book = await parseEpubFromPath(epubPath: file.path, fullData: true);
    final mangas = database.mangas.where().findAllSync();
    final parent = mangas
        .where((manga) => manga.id == placeholder.mangaId)
        .firstOrNull;
    if (parent == null) return false;

    final progressBefore = database.epubBookProgress.where().findAllSync();
    final wasMissing = materializer.isMissingEpubParent(parent, progressBefore);
    if (!wasMissing) return false;
    final chapters = epubShortcutChapters(
      book: book,
      manga: parent,
      mangaId: parent.id!,
      archivePath: file.path,
    );
    await database.writeTxn(() async {
      if (book.cover != null) parent.customCoverImage = book.cover;
      parent
        ..source = 'archive'
        ..link = file.path
        ..description = parent.description == chimahonMissingEpubGuidance
            ? ''
            : parent.description
        ..name = book.name.trim().isEmpty ? parent.name : book.name
        ..sourceTitle = book.name
        ..author = book.author
        ..lang = book.language ?? parent.lang;
      await database.mangas.put(parent);
      for (final chapter in chapters) {
        await database.chapters.put(chapter);
        await chapter.manga.save();
      }
      final importedProgress = materializer.progressForImportedEpub(
        progresses: progressBefore,
        mangaId: parent.id!,
        archivePath: file.path,
        title: book.name,
        author: book.author,
        lang: book.language,
        allowUnidentifiablePreferredParent: true,
      );
      await database.epubBookProgress.put(importedProgress);
    });
    return true;
  }

  bool _sameEntryMaps(
    Map<String, MangatanEpubManifestEntry> first,
    Map<String, MangatanEpubManifestEntry> second,
  ) {
    final firstBytes = MangatanEpubManifest(
      generatedAtUtc: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      deviceId: '',
      entries: first,
    ).encode();
    final secondBytes = MangatanEpubManifest(
      generatedAtUtc: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      deviceId: '',
      entries: second,
    ).encode();
    if (firstBytes.length != secondBytes.length) return false;
    for (var i = 0; i < firstBytes.length; i++) {
      if (firstBytes[i] != secondBytes[i]) return false;
    }
    return true;
  }
}
