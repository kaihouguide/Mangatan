import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/eval/mihon/bridge_http_client.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/services/extension_repository_catalog.dart';
import 'package:mangayomi/services/fetch_item_sources.dart';
import 'package:mangayomi/services/http/m_client.dart';
import 'package:mangayomi/utils/log/logger.dart';
import 'package:mangayomi/utils/platform_utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:mangayomi/repositories/settings_repository.dart';
import 'package:mangayomi/services/extension_store_service.dart';
import 'package:mangayomi/repositories/db_write_queue.dart';
part 'browse_state_provider.g.dart';

@riverpod
class AndroidProxyServerState extends _$AndroidProxyServerState {
  @override
  String build() {
    // The embedded iOS bridge outlives any individual source provider.
    ref.keepAlive();
    final savedAddress = settingsRepository.currentOrNull?.androidProxyServer;
    return normalizeMihonBridgeBaseUrl(
      savedAddress == null || savedAddress.trim().isEmpty
          ? "http://127.0.0.1:8080"
          : savedAddress,
    );
  }

  String get currentValue => state;

  void set(String value) {
    final proxyServer = normalizeMihonBridgeBaseUrl(value);
    state = proxyServer;
    settingsRepository.update(
      (settings) => settings.androidProxyServer = proxyServer,
    );
  }

  /// Changes the address used by the running app without overwriting the
  /// user's external bridge fallback in the database.
  void setRuntime(String value) {
    state = normalizeMihonBridgeBaseUrl(value);
  }

  void restoreSaved() {
    final savedAddress = settingsRepository.currentOrNull?.androidProxyServer;
    state = normalizeMihonBridgeBaseUrl(
      savedAddress == null || savedAddress.trim().isEmpty
          ? "http://127.0.0.1:8080"
          : savedAddress,
    );
  }
}

@riverpod
class AutoStartExtensionServerOnLaunchState
    extends _$AutoStartExtensionServerOnLaunchState {
  @override
  bool build() {
    return settingsRepository.currentOrNull?.autoStartExtensionServerOnLaunch ??
        false;
  }

  void set(bool value) {
    state = value;
    settingsRepository.update(
      (settings) => settings.autoStartExtensionServerOnLaunch = value,
    );
  }
}

final developerModeStateProvider = NotifierProvider<DeveloperModeState, bool>(
  DeveloperModeState.new,
);

class DeveloperModeState extends Notifier<bool> {
  @override
  bool build() {
    return settingsRepository.currentOrNull?.developerMode ?? false;
  }

  void set(bool value) {
    state = value;
    settingsRepository.update((s) => s.developerMode = value);
  }
}

@riverpod
class OnlyIncludePinnedSourceState extends _$OnlyIncludePinnedSourceState {
  @override
  bool build() {
    return settingsRepository.current.onlyIncludePinnedSources!;
  }

  void set(bool value) {
    state = value;
    settingsRepository.update((s) => s.onlyIncludePinnedSources = value);
  }
}

@riverpod
class ShowNSFWState extends _$ShowNSFWState {
  @override
  bool build() {
    return settingsRepository.current.showNSFW ?? false;
  }

  void set(bool value) {
    state = value;
    settingsRepository.update((s) => s.showNSFW = value);
  }
}

@riverpod
class ShowNavDoubleTapTooltipState extends _$ShowNavDoubleTapTooltipState {
  @override
  bool build() {
    return settingsRepository.current.showNavDoubleTapTooltip ?? true;
  }

  void set(bool value) {
    state = value;
    settingsRepository.update((s) => s.showNavDoubleTapTooltip = value);
  }
}

@riverpod
class ExtensionsRepoState extends _$ExtensionsRepoState {
  static List<Repo> _deduplicate(List<Repo> repos) {
    final seen = <String>{};
    final result = <Repo>[];
    for (final repo in repos) {
      final key = repo.jsonUrl?.trim().toLowerCase();
      if (key != null && key.isNotEmpty) {
        if (seen.add(key)) {
          result.add(repo);
        }
      } else {
        result.add(repo);
      }
    }
    return result;
  }

  @override
  List<Repo> build(ItemType itemType) {
    final settings = settingsRepository.current;
    final list =
        switch (itemType) {
          ItemType.manga => settings.mangaExtensionsRepo,
          ItemType.anime => settings.animeExtensionsRepo,
          _ => settings.novelExtensionsRepo,
        } ??
        [];
    return _deduplicate(list);
  }

  bool containsRepo(String url) {
    final clean = url.trim().toLowerCase();
    return state.any((r) {
      final rUrl = r.jsonUrl?.trim().toLowerCase();
      if (rUrl == null) return false;
      return rUrl == clean || rUrl == '$clean/' || '$rUrl/' == clean;
    });
  }

  void setVisibility(Repo repo, bool hidden) {
    final value = state.map((e) {
      if (e == repo) {
        e.hidden = hidden;
      }
      return e;
    }).toList();
    unawaited(set(value));
  }

  Future<void> set(List<Repo> value) async {
    state = value;
    await dbWriteQueue.run(
      () => isar.writeTxn(() async {
        final settings = await isar.settings.get(227);
        if (settings == null) return;
        switch (itemType) {
          case ItemType.manga:
            settings.mangaExtensionsRepo = value;
            break;
          case ItemType.anime:
            settings.animeExtensionsRepo = value;
            break;
          case ItemType.novel:
            settings.novelExtensionsRepo = value;
            break;
        }
        settings.updatedAt = DateTime.now().millisecondsSinceEpoch;
        await isar.settings.put(settings);
      }),
    );
    unawaited(_refreshSources());
  }

  Future<void> _refreshSources() async {
    try {
      final refresh = ref.refresh(
        fetchItemSourcesListProvider(
          id: null,
          reFresh: true,
          itemType: itemType,
        ).future,
      );
      await refresh;
    } catch (_) {}
  }
}

@riverpod
class AutoUpdateExtensionsState extends _$AutoUpdateExtensionsState {
  @override
  bool build() {
    return settingsRepository.current.autoExtensionsUpdates ?? false;
  }

  void set(bool value) {
    state = value;
    settingsRepository.update((s) => s.autoExtensionsUpdates = value);
  }
}

@riverpod
class CheckForExtensionsUpdateState extends _$CheckForExtensionsUpdateState {
  @override
  bool build() {
    return settingsRepository.current.checkForExtensionUpdates ?? true;
  }

  void set(bool value) {
    state = value;
    settingsRepository.update((s) => s.checkForExtensionUpdates = value);
  }
}

@riverpod
Future<Repo?> getRepoInfos(Ref ref, {required String jsonUrl}) async {
  final http = MClient.init(reqcopyWith: {'useDartHttpClient': true});
  final cleanUrl = jsonUrl.trim();
  if (cleanUrl.isEmpty) return null;

  final urlsToTry = <String>[cleanUrl];
  // Every format is tried in turn, so keep why each attempt failed: the
  // user only sees "unsupported repository".
  final failures = <String>[];
  if (!cleanUrl.endsWith('.json') && !cleanUrl.endsWith('.pb')) {
    final normalized = cleanUrl.endsWith('/')
        ? cleanUrl.substring(0, cleanUrl.length - 1)
        : cleanUrl;
    urlsToTry.addAll([
      '$normalized/index.min.json',
      '$normalized/repo.json',
      '$normalized/index.json',
      '$normalized/index_v2.json',
    ]);
  }

  // Upstream 0.9.2 stores, including Aidoku and protobuf indexes.
  for (final url in urlsToTry) {
    try {
      final result = await ExtensionStoreService.fetchStore(url, http);
      if (result != null &&
          (result.sources.isNotEmpty || result.name.isNotEmpty)) {
        var repoName = result.name;
        bool isIndexFile(String name) =>
            name.endsWith('.json') || name.endsWith('.pb');
        if (repoName.isEmpty || isIndexFile(repoName)) {
          final uri = Uri.parse(url);
          final segments = uri.pathSegments
              .where((segment) => segment.isNotEmpty && !isIndexFile(segment))
              .toList();
          repoName = segments.lastOrNull ?? uri.host;
        }
        return Repo(
          name: repoName,
          website: result.website ?? url,
          jsonUrl: result.indexUrl,
        );
      }
    } catch (error) {
      failures.add('$url: $error');
    }
  }

  // Mangatan's package-aware catalog parser remains available for its custom
  // repository formats.
  for (final url in urlsToTry) {
    try {
      final catalog = await loadExtensionRepositoryCatalog(Uri.parse(url), (
        uri,
      ) async {
        final response = await http.get(uri);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw StateError(
            'Extension repository returned HTTP ${response.statusCode}.',
          );
        }
        return response.bodyBytes;
      });
      if (catalog.entries.isNotEmpty) {
        return Repo(
          name: catalog.name,
          website: catalog.website ?? url,
          jsonUrl: url,
        );
      }
    } catch (error) {
      failures.add('$url: $error');
    }
  }

  // Legacy JSON list format.
  for (final url in urlsToTry) {
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        Map<String, dynamic> infos = {};
        final match = RegExp(r'^(.*)/[^/]+\.json$').firstMatch(url);
        if (match != null) {
          String baseUrl = match.group(1)!;
          try {
            final repoRes = await http.get(Uri.parse("$baseUrl/repo.json"));
            if (repoRes.statusCode == 200) {
              final decoded = jsonDecode(repoRes.body);
              if (decoded is Map<String, dynamic>) {
                infos.addAll(decoded);
              }
            }
          } catch (_) {}
        }
        infos["jsonUrl"] = url;
        final repo = Repo.fromJson(infos);
        if (repo.name == null ||
            repo.name!.isEmpty ||
            repo.name!.endsWith('.json') ||
            repo.name == '.dist' ||
            repo.name == 'dist') {
          repo.name = _inferRepoName(Uri.parse(url));
        }
        return repo;
      }
    } catch (error) {
      failures.add('$url: $error');
    }
  }

  AppLogger.log(
    'Could not add extension repository $cleanUrl:\n${failures.join('\n')}',
    logLevel: LogLevel.warning,
  );
  return null;
}

String _inferRepoName(Uri uri) {
  if (uri.host == 'raw.githubusercontent.com' && uri.pathSegments.length >= 2) {
    return uri.pathSegments[1];
  }
  final segments = uri.pathSegments.where(
    (segment) =>
        segment.isNotEmpty &&
        !segment.endsWith('.json') &&
        !const {'.dist', 'dist', 'build', '.build'}.contains(segment),
  );
  return segments.lastOrNull ?? uri.host;
}

final isExtensionServerInstalledStreamProvider = StreamProvider<bool>((
  ref,
) async* {
  if (!isDesktop) {
    yield true;
    return;
  }
  await for (final settings in isar.settings.watchObject(
    227,
    fireImmediately: true,
  )) {
    final jrePath = settings?.jrePath ?? '';
    final serverPath = settings?.extensionServerPath ?? '';
    yield jrePath.isNotEmpty &&
        serverPath.isNotEmpty &&
        File(jrePath).existsSync() &&
        File(serverPath).existsSync();
  }
});
