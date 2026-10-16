import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/epub_book_progress.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/services/sync/mangatan_epub_blob_storage.dart';
import 'package:mangayomi/services/sync/mangatan_epub_sync_manifest.dart';
import 'package:mangayomi/services/sync/mangatan_epub_sync_service.dart';
import 'package:mangayomi/utils/chimahon_novel_identity.dart';

void main() {
  late Directory directory;
  late Isar database;

  setUpAll(() async {
    await Isar.initializeIsarCore(
      libraries: {Abi.current(): await _isarLibraryPath()},
    );
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('mangatan-epub-sync-');
    database = await Isar.open(
      [MangaSchema, ChapterSchema, EpubBookProgressSchema],
      directory: directory.path,
      name: 'mangatan_epub_sync_test',
    );
  });

  tearDown(() async {
    await database.close(deleteFromDisk: true);
    await directory.delete(recursive: true);
  });

  test('one unavailable EPUB does not stop the others or fail sync', () async {
    final entries = <String, MangatanEpubManifestEntry>{};
    database.writeTxnSync(() {
      for (final (index, title) in ['Corrupt', 'Missing'].indexed) {
        database.epubBookProgress.putSync(
          EpubBookProgress(mangaId: index + 1, archivePath: '', title: title),
        );
        final id = ChimahonNovelIdentity.newBookId(title: title);
        entries[id] = MangatanEpubManifestEntry(
          stableNovelId: id,
          sha256: title == 'Corrupt' ? 'a' * 64 : 'b' * 64,
          sizeBytes: 3,
          fileName: '$title.epub',
          title: title,
          updatedAtUtc: DateTime.utc(2026),
        );
      }
    });

    final result =
        await MangatanEpubSyncService(
          database: database,
          storage: _FailingBlobStorage(),
          deviceId: 'device',
          downloadDirectory: Directory('${directory.path}/downloads'),
        ).materializeMissingPlaceholders(
          MangatanEpubManifest(
            generatedAtUtc: DateTime.utc(2026),
            deviceId: 'other',
            entries: entries,
          ),
        );

    expect(result.placeholdersFailed, 2);
    expect(result.placeholdersMaterialized, 0);
  });
}

class _FailingBlobStorage implements MangatanEpubBlobStorage {
  @override
  Future<Uint8List> downloadEpubBlob(String sha256) async {
    // The first blob does not match its digest; the second is gone.
    if (sha256.startsWith('a')) return Uint8List.fromList([1, 2, 3]);
    throw const FileSystemException('blob not found');
  }

  @override
  Future<MangatanRemoteEpubManifest?> downloadEpubManifest() async => null;

  @override
  Future<bool> hasEpubBlob(String sha256) async => false;

  @override
  Future<void> uploadEpubBlob({
    required String sha256,
    required int sizeBytes,
    required Stream<List<int>> bytes,
  }) async {}

  @override
  Future<String?> uploadEpubManifest(
    MangatanEpubManifest manifest, {
    String? expectedRevision,
    bool expectedAbsent = false,
  }) async => null;
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
  if (Platform.isMacOS) return '${packageDirectory.path}/macos/libisar.dylib';
  if (Platform.isLinux) return '${packageDirectory.path}/linux/libisar.so';
  return '${packageDirectory.path}/windows/isar.dll';
}
