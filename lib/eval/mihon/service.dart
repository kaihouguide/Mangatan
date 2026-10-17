import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:mangayomi/eval/http_response_extensions.dart';
import 'package:mangayomi/eval/model/filter.dart';
import 'package:mangayomi/eval/model/m_chapter.dart';
import 'package:mangayomi/eval/model/m_manga.dart';
import 'package:mangayomi/eval/model/m_pages.dart';
import 'package:mangayomi/eval/model/source_preference.dart';
import 'package:mangayomi/eval/mihon/bridge_http_client.dart';
import 'package:mangayomi/eval/mihon/bridge_protocol.dart';
import 'package:mangayomi/eval/mihon/image_proxy.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/page.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/utils/chapter_recognition.dart';
import 'package:mangayomi/models/video.dart';
import 'package:mangayomi/services/http/m_client.dart';
import 'package:mangayomi/services/mihon_source_preferences.dart';
import 'package:mangayomi/services/http/cf_proxy_store.dart';

import '../../models/manga.dart';
import '../interface.dart';
import 'models.dart';

import 'package:mangayomi/models/settings.dart';

class MihonExtensionService implements ExtensionService {
  late String androidProxyServer;
  @override
  late Source source;
  late final http.Client client;
  final Map<String, String>? requestHeaders;
  final bool _ownsClient;

  MihonExtensionService(
    this.source,
    this.androidProxyServer, {
    http.Client? client,
    this.requestHeaders,
  }) : _ownsClient = client == null {
    this.client = client ?? _createClient();
  }

  @override
  void dispose() {
    if (_ownsClient) client.close();
  }

  bool get _usesLoopbackBridge => isLoopbackMihonBridge(androidProxyServer);

  String? _resolveBridgeMediaUrl(String? mediaUrl) => mediaUrl == null
      ? null
      : resolveMihonMediaUrl(androidProxyServer, mediaUrl);

  http.Client _createClient() {
    final httpClient = HttpClient();
    httpClient.findProxy = (_) => 'DIRECT';
    httpClient.connectionTimeout = const Duration(seconds: 10);
    httpClient.idleTimeout = const Duration(seconds: 15);
    return IOClient(httpClient);
  }

  Future<http.Response> _postDalvik({
    Object? body,
    Map<String, String>? headers,
  }) async {
    // The pinned APKBridge DataBody rejects unknown top-level fields. Source
    // selection travels in mihonPreferencePayload's bridge context instead.
    Future<http.Response> send(Map<String, String>? requestHeaders) =>
        postMihonBridge(
          client,
          mihonBridgeDalvikUri(androidProxyServer),
          body: body,
          headers: requestHeaders,
          retryTransientFailures: _usesLoopbackBridge,
        );
    var response = await send(headers);
    if (_isCloudflareBlocked(response)) {
      final proxyUrl = requestHeaders == null
          ? CfProxyStore.url.trim()
          : (requestHeaders!['cf-proxy-url'] ?? '').trim();
      if (proxyUrl.isNotEmpty &&
          await solveWithCfProxy(proxyUrl, source.baseUrl!)) {
        response = await send(getCookie());
      }
    }
    return response;
  }

  @override
  Map<String, String> getHeaders() {
    return source.headers != null && source.headers!.isNotEmpty
        ? (jsonDecode(source.headers!) as Map?)?.toMapStringString ?? {}
        : {};
  }

  @override
  bool get supportsLatest {
    return source.supportLatest ?? false;
  }

  @override
  String get sourceBaseUrl {
    return source.baseUrl!;
  }

  @override
  Future<MPages> getPopular(int page) async {
    final name = source.itemType == ItemType.anime ? "Anime" : "Manga";
    final res = await _postDalvik(
      body: {
        "method": "getPopular$name",
        "page": mihonCataloguePage(page),
        "search": "",
        "preferences": mihonPreferencePayload(source, getSourcePreferences()),
        "data": source.sourceCode,
      },
      headers: getCookie(),
    );
    hasError(res);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final pages = MangaPages.fromJson(data, source.itemType);
    return MPages(
      list: pages.list
          .map(
            (e) => MManga(
              name: e.title,
              link: e.url,
              artist: e.artist,
              author: e.author,
              description: e.description,
              genre: e.genre,
              status: e.status,
              imageUrl: _resolveBridgeMediaUrl(e.thumbnailUrl),
              chapters: [],
            ),
          )
          .toList(),
      hasNextPage: pages.hasNextPage,
    );
  }

  @override
  Future<MPages> getLatestUpdates(int page) async {
    final name = source.itemType == ItemType.anime ? "Anime" : "Manga";
    final res = await _postDalvik(
      body: {
        "method": "getLatest$name",
        "page": mihonCataloguePage(page),
        "search": "",
        "preferences": mihonPreferencePayload(source, getSourcePreferences()),
        "data": source.sourceCode,
      },
      headers: getCookie(),
    );
    hasError(res);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final pages = MangaPages.fromJson(data, source.itemType);
    return MPages(
      list: pages.list
          .map(
            (e) => MManga(
              name: e.title,
              link: e.url,
              artist: e.artist,
              author: e.author,
              description: e.description,
              genre: e.genre,
              status: e.status,
              imageUrl: _resolveBridgeMediaUrl(e.thumbnailUrl),
              chapters: [],
            ),
          )
          .toList(),
      hasNextPage: pages.hasNextPage,
    );
  }

  @override
  Future<MPages> search(String query, int page, List<dynamic> filters) async {
    final name = source.itemType == ItemType.anime ? "Anime" : "Manga";
    final res = await _postDalvik(
      body: {
        "method": "getSearch$name",
        "page": mihonCataloguePage(page),
        "search": query,
        "filterList": _convertFilters(filters),
        "preferences": mihonPreferencePayload(source, getSourcePreferences()),
        "data": source.sourceCode,
      },
      headers: getCookie(),
    );
    hasError(res);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final pages = MangaPages.fromJson(data, source.itemType);
    return MPages(
      list: pages.list
          .map(
            (e) => MManga(
              name: e.title,
              link: e.url,
              artist: e.artist,
              author: e.author,
              description: e.description,
              genre: e.genre,
              status: e.status,
              imageUrl: _resolveBridgeMediaUrl(e.thumbnailUrl),
              chapters: [],
            ),
          )
          .toList(),
      hasNextPage: pages.hasNextPage,
    );
  }

  @override
  Future<MManga> getDetail(String url) async {
    final name = source.itemType == ItemType.anime ? "Anime" : "Manga";
    final res = await _postDalvik(
      body: {
        "method": "getDetails$name",
        if (source.itemType == ItemType.manga) "mangaData": {"url": url},
        if (source.itemType == ItemType.anime) "animeData": {"url": url},
        "preferences": mihonPreferencePayload(source, getSourcePreferences()),
        "data": source.sourceCode,
      },
      headers: getCookie(),
    );
    hasError(res);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final detail = _animeOrManga(data);
    if (source.itemType == ItemType.anime && detail.animeFetchType == 0) {
      detail.seasons = await getSeasonList(data);
    } else {
      detail.chapters = await getChapterList(url);
    }
    return detail;
  }

  MManga _animeOrManga(Map<String, dynamic> data) {
    return MManga(
      name: data['title'],
      link: data['url'],
      artist: data['artist'],
      author: data['author'],
      description: data['description'],
      genre:
          (data['genre'] as String?)
              ?.split(',')
              .map((e) => e.toString())
              .toList() ??
          [],
      status: switch (data['status'] as int?) {
        1 => Status.ongoing,
        2 => Status.completed,
        4 => Status.publishingFinished,
        5 => Status.canceled,
        6 => Status.onHiatus,
        _ => Status.unknown,
      },
      imageUrl: _resolveBridgeMediaUrl(data['thumbnail_url'] as String?),
      animeFetchType: switch (data['fetch_type']) {
        'Seasons' || 0 => 0,
        'Episodes' || 1 => 1,
        _ => null,
      },
      seasonNumber: (data['season_number'] as num?)?.toDouble(),
      backgroundUrl: _resolveBridgeMediaUrl(data['background_url'] as String?),
      chapters: [],
    );
  }

  Future<List<MManga>> getSeasonList(Map<String, dynamic> anime) async {
    final res = await _postDalvik(
      body: {
        'method': 'getSeasonList',
        'animeData': anime,
        'preferences': mihonPreferencePayload(source, getSourcePreferences()),
        'data': source.sourceCode,
      },
      headers: getCookie(),
    );
    hasError(res);
    final data = jsonDecode(res.body);
    if (data is! List) {
      throw StateError(
        'The extension server does not support seasons. Update the server and try again.',
      );
    }
    return data.map((e) => _animeOrManga(e as Map<String, dynamic>)).toList();
  }

  Future<List<MChapter>> getChapterList(String url) async {
    final res = await _postDalvik(
      body: {
        "method": source.itemType == ItemType.anime
            ? "getEpisodeList"
            : "getChapterList",
        if (source.itemType == ItemType.manga) "mangaData": {"url": url},
        if (source.itemType == ItemType.anime) "animeData": {"url": url},
        "preferences": mihonPreferencePayload(source, getSourcePreferences()),
        "data": source.sourceCode,
      },
      headers: getCookie(),
    );
    hasError(res);
    final data = jsonDecode(res.body) as List;
    return data
        .map(
          (e) => MChapter(
            name: e['name'],
            url: e['url'],
            dateUpload:
                (e['date_upload'] as int?)?.toString() ??
                DateTime.now().millisecondsSinceEpoch.toString(),
            scanlator: e['scanlator'],
            isFiller: e['fillermark'] as bool?,
            description: e['summary'] as String?,
            thumbnailUrl: _resolveBridgeMediaUrl(e['preview_url'] as String?),
            chapterNumber: normalizeSourceChapterNumber(
              (e[source.itemType == ItemType.anime
                          ? 'episode_number'
                          : 'chapter_number']
                      as num?)
                  ?.toDouble(),
            ),
          ),
        )
        .toList();
  }

  Future<String> getMangaWebViewUrl(Manga manga) async {
    final isAnime = source.itemType == ItemType.anime;
    final mediaData = {
      'url': manga.link,
      'title': manga.name,
      'artist': manga.artist,
      'author': manga.author,
      'description': manga.description,
      'genre': manga.genre?.join(', '),
      'thumbnail_url': manga.imageUrl,
      'initialized': true,
    };
    final res = await _postDalvik(
      body: {
        'method': isAnime ? 'getAnimeUrl' : 'getMangaUrl',
        isAnime ? 'animeData' : 'mangaData': mediaData,
        'preferences': mihonPreferencePayload(source, getSourcePreferences()),
        'data': source.sourceCode,
      },
      headers: getCookie(),
    );
    hasError(res);
    return jsonDecode(res.body) as String;
  }

  Future<String> getChapterWebViewUrl(Chapter chapter) async {
    final isAnime = source.itemType == ItemType.anime;
    final chapterData = {
      'url': chapter.url,
      'name': chapter.name,
      'date_upload': int.tryParse(chapter.dateUpload ?? ''),
      isAnime ? 'episode_number' : 'chapter_number': chapter.chapterNumber,
      'scanlator': chapter.scanlator,
    };
    final res = await _postDalvik(
      body: {
        'method': isAnime ? 'getEpisodeUrl' : 'getChapterUrl',
        isAnime ? 'episodeData' : 'chapterData': chapterData,
        'preferences': mihonPreferencePayload(source, getSourcePreferences()),
        'data': source.sourceCode,
      },
      headers: getCookie(),
    );
    hasError(res);
    return jsonDecode(res.body) as String;
  }

  @override
  Future<List<PageUrl>> getPageList(String url) async {
    final res = await _postDalvik(
      body: {
        "method": "getPageList",
        "chapterData": {"url": url},
        "preferences": mihonPreferencePayload(source, getSourcePreferences()),
        "data": source.sourceCode,
      },
      headers: getCookie(),
    );
    hasError(res);
    final data = jsonDecode(res.body) as List;
    return data
        .map(
          (e) => PageUrl(
            resolveMihonImageUrl(
              androidProxyServer,
              e['imageUrl']?.toString() ?? '',
            ),
            // Bridges that return direct image URLs (rather than proxy
            // tokens) also return the request headers those URLs need.
            headers: switch (e['headers']) {
              final Map headers => {
                for (final entry in headers.entries)
                  if (entry.value != null)
                    entry.key.toString(): entry.value.toString(),
              },
              _ => null,
            },
          ),
        )
        .toList();
  }

  @override
  Future<List<Video>> getVideoList(String url) async {
    final res = await _postDalvik(
      body: {
        "method": "getVideoList",
        "episodeData": {"url": url},
        "preferences": mihonPreferencePayload(source, getSourcePreferences()),
        "data": source.sourceCode,
      },
      headers: getCookie(),
    );
    hasError(res);
    final data = jsonDecode(res.body) as List;
    return data.map((e) {
      final tempHeaders =
          e['headers']?['namesAndValues\$okhttp'] as List<dynamic>?;
      final Map<String, String> headers = {};
      if (tempHeaders != null) {
        for (var i = 0; i + 1 < tempHeaders.length; i += 2) {
          headers[tempHeaders[i]] = tempHeaders[i + 1];
        }
      }
      return Video(
        _resolveBridgeMediaUrl(e['videoUrl']?.toString()) ?? '',
        e['quality'],
        e['url'],
        headers: headers,
        audios:
            (e['audioTracks'] as List?)
                ?.map(
                  (e) => Track(
                    file: _resolveBridgeMediaUrl(
                      (e['file'] ?? e['url'])?.toString(),
                    ),
                    label: e['label']?.toString(),
                    language: (e['language'] ?? e['lang'])?.toString(),
                  ),
                )
                .toList() ??
            [],
        subtitles:
            (e['subtitleTracks'] as List?)
                ?.map(
                  (e) => Track(
                    file: _resolveBridgeMediaUrl(
                      (e['file'] ?? e['url'])?.toString(),
                    ),
                    label: e['label']?.toString(),
                    language: (e['language'] ?? e['lang'])?.toString(),
                  ),
                )
                .toList() ??
            [],
      );
    }).toList();
  }

  @override
  Future<String> getHtmlContent(String name, String url) async {
    return "";
  }

  @override
  Future<String> cleanHtmlContent(String html) async {
    return html;
  }

  @override
  FilterList getFilterList() {
    return source.getFilterList() ?? FilterList([]);
  }

  @override
  List<SourcePreference> getSourcePreferences() {
    return decodeMihonSourcePreferences(source.preferenceList);
  }

  List<dynamic> _convertFilters(List<dynamic> filters) {
    return filters.expand((e) sync* {
      if (e is TextFilter) {
        yield {"name": e.name, "stateString": e.state, "type": "TextFilter"};
      } else if (e is GroupFilter) {
        yield {
          "name": e.name,
          "stateList": e.state.expand((e) sync* {
            if (e is CheckBoxFilter) {
              yield {
                "name": e.name,
                "stateBoolean": e.state,
                "type": "CheckBoxFilter",
              };
            } else if (e is TriStateFilter) {
              yield {
                "name": e.name,
                "stateInt": e.state,
                "type": "TriStateFilter",
              };
            }
          }).toList(),
          "type": "GroupFilter",
        };
      } else if (e is SelectFilter) {
        yield {"name": e.name, "stateInt": e.state, "type": "SelectFilter"};
      } else if (e is SortFilter) {
        yield {
          "name": e.name,
          "stateSort": {"ascending": e.state.ascending, "index": e.state.index},
          "type": "SortFilter",
        };
      }
    }).toList();
  }

  Map<String, String> getCookie() {
    if (requestHeaders != null) {
      return {...requestHeaders!, 'source-base-url': ?source.baseUrl};
    }

    final userAgent = isar.settings.getSync(227)!.userAgent;
    final cfProxyUrl = CfProxyStore.url.trim();
    return {
      ...MClient.getCookiesPref(source.baseUrl!),
      'user-agent': ?userAgent,
      // Which source of the extension this call is for. The id sent alongside
      // it is a Dart hashCode of the original one (see ExtensionStoreService),
      // which the server cannot reproduce on the JVM, so an extension holding
      // several sources would otherwise always resolve to the same one.
      'source-base-url': ?source.baseUrl,
      // Lets an extension server that supports it solve the challenge itself,
      // which is better placed than the retry below: it owns the request and
      // its cookie jar. Servers that don't support it ignore the header.
      if (cfProxyUrl.isNotEmpty) 'cf-proxy-url': cfProxyUrl,
    };
  }

  /// Extension requests run outside MClient, so bridge errors need their own
  /// Cloudflare proxy retry.
  bool _isCloudflareBlocked(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> &&
          decoded['error'] != null &&
          decoded['code'] == 403;
    } catch (_) {
      // Not JSON: hasError() reports the malformed-response case itself.
      return false;
    }
  }
}

void hasError(http.Response response) {
  Map<String, dynamic>? decoded;
  try {
    final parsed = jsonDecode(response.body);
    if (parsed is Map<String, dynamic>) decoded = parsed;
  } catch (_) {
    // Not valid JSON - the Android extension bridge (the device/emulator
    // configured in Settings > Browse > Extension Server) returned something
    // other than the expected response, most likely because it crashed, was
    // unreachable, or dropped the connection mid-response. Say so clearly
    // instead of letting the caller's own jsonDecode() on the same empty/
    // malformed body fail moments later with a bare "Unexpected end of
    // input" that gives no indication of the actual cause.
    if (response.body.trim().isEmpty) {
      throw "The Android extension bridge server returned an empty response "
          "(HTTP ${response.statusCode}). Check that the device/emulator set "
          "in Settings > Browse > Extension Server is running and reachable.";
    }
    throw "The Android extension bridge server returned an unexpected "
        "response (HTTP ${response.statusCode}): ${response.body}";
  }

  final errorMessage = decoded?['error'];
  final code = decoded?['code'];
  if (errorMessage != null && code != null) {
    if (code == 403) {
      throw "Failed to bypass Cloudflare.\n\n\nYou can try to bypass it manually in the webview \n\n\nstatusCode: 403";
    }
    throw "$errorMessage \n\n\nstatusCode: $code";
  }
}
