import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mangayomi/services/hoshidicts/dictionary_storage.dart';
import 'package:mangayomi/services/hoshidicts/hoshidicts_backend.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';
import 'package:path/path.dart' as p;

class DictionaryUpdateInfo {
  const DictionaryUpdateInfo({
    required this.dictionary,
    this.latestRevision,
    this.latestDownloadUrl,
    this.hasUpdate = false,
    this.error,
  });

  final InstalledDictionary dictionary;
  final String? latestRevision;
  final String? latestDownloadUrl;
  final bool hasUpdate;
  final String? error;
}

bool hasNewerDictionaryRevision(String? current, String? latest) {
  if (current == null || latest == null) return false;
  final currentValue = current.trim();
  final latestValue = latest.trim();
  if (currentValue == latestValue) return false;
  final numeric = RegExp(r'^(\d+\.)*\d+$');
  if (!numeric.hasMatch(currentValue) || !numeric.hasMatch(latestValue)) {
    return currentValue.compareTo(latestValue) < 0;
  }
  // Date-stamped revisions such as 20240501123000 can exceed an int.
  final currentParts = currentValue.split('.').map(BigInt.parse).toList();
  final latestParts = latestValue.split('.').map(BigInt.parse).toList();
  final length = currentParts.length > latestParts.length
      ? currentParts.length
      : latestParts.length;
  for (var index = 0; index < length; index++) {
    if (index >= currentParts.length) return true;
    if (index >= latestParts.length) return false;
    if (currentParts[index] != latestParts[index]) {
      return currentParts[index] < latestParts[index];
    }
  }
  return false;
}

class DictionaryUpdateService {
  DictionaryUpdateService({
    http.Client? client,
    DictionaryStorage? storage,
    HoshidictsLookupBackend? backend,
  }) : _client = client ?? http.Client(),
       _storage = storage ?? DictionaryStorage.instance,
       _backend = backend ?? HoshidictsLookupBackend.instance;

  static final instance = DictionaryUpdateService();

  final http.Client _client;
  final DictionaryStorage _storage;
  final HoshidictsLookupBackend _backend;
  Future<List<DictionaryUpdateInfo>>? _runningAutomaticUpdate;

  Future<List<DictionaryUpdateInfo>> checkAll() async {
    final installed = await _storage.installed();
    final updates = <DictionaryUpdateInfo>[];
    for (final dictionary in installed) {
      updates.add(await check(dictionary));
    }
    await MiningPreferences.setDictionaryLastUpdateCheck(DateTime.now());
    return updates;
  }

  Future<DictionaryUpdateInfo> check(InstalledDictionary dictionary) async {
    if (!dictionary.isUpdatable ||
        dictionary.indexUrl == null ||
        dictionary.indexUrl!.trim().isEmpty) {
      return DictionaryUpdateInfo(dictionary: dictionary);
    }
    try {
      final uri = Uri.parse(dictionary.indexUrl!);
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Update index returned HTTP ${response.statusCode}',
          uri: uri,
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Update index is not a JSON object.');
      }
      final latestRevision = decoded['revision']?.toString();
      final latestDownloadUrl =
          decoded['downloadUrl']?.toString() ?? dictionary.downloadUrl;
      return DictionaryUpdateInfo(
        dictionary: dictionary,
        latestRevision: latestRevision,
        latestDownloadUrl: latestDownloadUrl,
        hasUpdate:
            hasNewerDictionaryRevision(dictionary.revision, latestRevision) ||
            (latestDownloadUrl != null &&
                latestDownloadUrl != dictionary.downloadUrl),
      );
    } catch (error) {
      return DictionaryUpdateInfo(
        dictionary: dictionary,
        error: error.toString(),
      );
    }
  }

  Future<InstalledDictionary> apply(DictionaryUpdateInfo update) async {
    final downloadUrl =
        update.latestDownloadUrl ?? update.dictionary.downloadUrl;
    if (downloadUrl == null || downloadUrl.trim().isEmpty) {
      throw StateError(
        '${update.dictionary.displayName} has no update download URL.',
      );
    }
    final root = await _storage.rootDirectory;
    final stagingRoot = Directory(
      p.join(
        root.path,
        '.dictionary-update-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    final importRoot = Directory(p.join(stagingRoot.path, 'import'));
    final archive = File(p.join(stagingRoot.path, 'dictionary.zip'));
    final backup = Directory(p.join(stagingRoot.path, 'backup'));
    final target = Directory(p.join(root.path, update.dictionary.name));
    await importRoot.create(recursive: true);
    try {
      await _download(Uri.parse(downloadUrl), archive);
      final imported = await _backend.importDictionary(
        zipPath: archive.path,
        outputDir: importRoot.path,
      );
      if (!imported.success) {
        throw StateError(imported.errors.join('\n'));
      }
      final importedDirectory = Directory(
        p.join(importRoot.path, imported.title),
      );
      if (!await importedDirectory.exists()) {
        throw StateError('The updated dictionary did not produce data files.');
      }
      if (await target.exists()) await target.rename(backup.path);
      try {
        await importedDirectory.rename(target.path);
        await _storage.recordImport(
          name: update.dictionary.name,
          termCount: imported.termCount,
          frequencyCount: imported.freqCount,
          pitchCount: imported.pitchCount,
          kanjiCount: imported.kanjiCount,
          root: root,
        );
        await _backend.reloadFromStorage();
        return (await _storage.installed(root: root)).firstWhere(
          (dictionary) => dictionary.name == update.dictionary.name,
        );
      } catch (_) {
        if (await target.exists()) await target.delete(recursive: true);
        if (await backup.exists()) await backup.rename(target.path);
        await _storage.recordImport(
          name: update.dictionary.name,
          termCount: update.dictionary.hasTerms ? BigInt.one : BigInt.zero,
          frequencyCount: update.dictionary.hasFrequencies
              ? BigInt.one
              : BigInt.zero,
          pitchCount: update.dictionary.hasPitch ? BigInt.one : BigInt.zero,
          kanjiCount: update.dictionary.hasKanji ? BigInt.one : BigInt.zero,
          root: root,
        );
        // The failure may have come after the backend loaded the new files.
        // Point it back at the restored dictionary; the update error is the
        // one worth reporting.
        try {
          await _backend.reloadFromStorage();
        } catch (_) {}
        rethrow;
      }
    } finally {
      if (await stagingRoot.exists()) {
        await stagingRoot.delete(recursive: true);
      }
    }
  }

  Future<List<DictionaryUpdateInfo>> runAutomaticIfDue() async {
    final running = _runningAutomaticUpdate;
    if (running != null) return running;
    final operation = _runAutomaticIfDue();
    _runningAutomaticUpdate = operation;
    try {
      return await operation;
    } finally {
      _runningAutomaticUpdate = null;
    }
  }

  Future<List<DictionaryUpdateInfo>> _runAutomaticIfDue() async {
    if (!await MiningPreferences.getDictionaryAutoUpdateEnabled()) {
      return const [];
    }
    final interval = Duration(
      hours: await MiningPreferences.getDictionaryAutoUpdateIntervalHours(),
    );
    final lastCheck = await MiningPreferences.getDictionaryLastUpdateCheck();
    if (lastCheck != null && DateTime.now().difference(lastCheck) < interval) {
      return const [];
    }
    final results = await checkAll();
    for (final update in results.where((update) => update.hasUpdate)) {
      try {
        await apply(update);
      } catch (_) {
        // A broken remote dictionary must not prevent the remaining
        // dictionaries from updating during the background check.
      }
    }
    return results;
  }

  Future<void> _download(Uri uri, File destination) async {
    final request = http.Request('GET', uri);
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 60));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>().catchError((_) {});
      throw HttpException(
        'Dictionary download returned HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    final sink = destination.openWrite();
    try {
      await sink.addStream(response.stream);
    } finally {
      await sink.close();
    }
  }
}
