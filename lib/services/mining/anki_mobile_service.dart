import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mangayomi/services/mining/mining_models.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mangayomi/utils/log/logger.dart';

const _ankiMobileInfoUrl = 'anki://x-callback-url/infoForAdding';
const _ankiMobileAddNoteUrl = 'anki://x-callback-url/addnote';
const _ankiMobileChannel = MethodChannel('com.selxo.mangatan.ankimobile');

typedef AnkiMobileUrlOpener = Future<bool> Function(Uri uri);
typedef AnkiMobileInfoReader = Future<String?> Function();
typedef AnkiMobileBackgroundTaskHandler = Future<void> Function();

class AnkiMobileException implements Exception {
  const AnkiMobileException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum AnkiMobileCallbackKind { info, added }

/// Matches AnkiMobile x-success callbacks with the request that opened it.
class AnkiMobileCallbackCoordinator {
  AnkiMobileCallbackCoordinator._();

  static final instance = AnkiMobileCallbackCoordinator._();

  final Map<String, Completer<void>> _pendingInfo = {};
  int _requestCounter = 0;

  String nextRequestId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_requestCounter++}';

  Future<void> registerInfoRequest(String requestId) {
    final completer = Completer<void>();
    _pendingInfo[requestId] = completer;
    return completer.future;
  }

  void cancelInfoRequest(String requestId) {
    _pendingInfo.remove(requestId);
  }

  AnkiMobileCallbackKind? handle(Uri uri) {
    if (uri.scheme.toLowerCase() != 'mangayomi' ||
        uri.host.toLowerCase() != 'anki') {
      return null;
    }
    final path = uri.pathSegments.firstOrNull?.toLowerCase();
    switch (path) {
      case 'info':
        final requestId = uri.queryParameters['request'];
        if (requestId != null) {
          final completer = _pendingInfo.remove(requestId);
          if (completer != null && !completer.isCompleted) completer.complete();
        }
        return AnkiMobileCallbackKind.info;
      case 'added':
        return AnkiMobileCallbackKind.added;
      default:
        return null;
    }
  }
}

class AnkiMobileNoteType {
  const AnkiMobileNoteType({required this.name, required this.fields});

  final String name;
  final List<String> fields;
}

class AnkiMobileInfo {
  const AnkiMobileInfo({required this.decks, required this.noteTypes});

  factory AnkiMobileInfo.fromJson(Map<String, dynamic> json) {
    final rawDecks = json['decks'] is List
        ? json['decks'] as List
        : const <Object?>[];
    final rawNoteTypes = json['notetypes'] is List
        ? json['notetypes'] as List
        : const <Object?>[];
    return AnkiMobileInfo(
      decks: rawDecks
          .map(_itemName)
          .where((name) => name.isNotEmpty)
          .toList(growable: false),
      noteTypes: rawNoteTypes
          .map((item) {
            if (item is! Map) {
              return AnkiMobileNoteType(
                name: item?.toString() ?? '',
                fields: const [],
              );
            }
            final rawFields = item['fields'] is List
                ? item['fields'] as List
                : const <Object?>[];
            return AnkiMobileNoteType(
              name: _itemName(item),
              fields: rawFields
                  .map(_itemName)
                  .where((name) => name.isNotEmpty)
                  .toList(growable: false),
            );
          })
          .where((noteType) => noteType.name.isNotEmpty)
          .toList(growable: false),
    );
  }

  final List<String> decks;
  final List<AnkiMobileNoteType> noteTypes;

  Map<String, List<String>> get fieldsByNoteType => {
    for (final noteType in noteTypes) noteType.name: noteType.fields,
  };

  static String _itemName(Object? item) {
    if (item is Map) return item['name']?.toString() ?? '';
    return item?.toString() ?? '';
  }
}

@visibleForTesting
Uri buildAnkiMobileAddNoteUri({
  required AnkiCardDraft draft,
  required bool allowDuplicate,
  required Uri successCallback,
}) {
  final query = <MapEntry<String, String>>[
    MapEntry('type', draft.modelName),
    MapEntry('deck', draft.deckName),
    for (final field in draft.fields.entries)
      MapEntry('fld${field.key}', field.value),
    if (draft.tags.isNotEmpty) MapEntry('tags', draft.tags.join(' ')),
    if (allowDuplicate) const MapEntry('dupes', '1'),
    MapEntry('x-success', successCallback.toString()),
  ];
  final encoded = query
      .map(
        (entry) =>
            '${Uri.encodeComponent(entry.key)}='
            '${Uri.encodeComponent(entry.value)}',
      )
      .join('&');
  return Uri.parse('$_ankiMobileAddNoteUrl?$encoded');
}

class AnkiMobileService {
  AnkiMobileService({
    AnkiMobileUrlOpener? openUrl,
    AnkiMobileInfoReader? readInfoForAdding,
    AnkiMobileBackgroundTaskHandler? beginMediaImportBackgroundTask,
    AnkiMobileBackgroundTaskHandler? endMediaImportBackgroundTask,
    this.mediaServerLifetime = const Duration(seconds: 60),
    AnkiMobileCallbackCoordinator? callbackCoordinator,
  }) : _openUrl = openUrl ?? _openExternalUrl,
       _readInfoForAdding = readInfoForAdding ?? _readInfoFromPlatform,
       _beginMediaImportBackgroundTask =
           beginMediaImportBackgroundTask ?? _beginBackgroundTaskOnPlatform,
       _endMediaImportBackgroundTask =
           endMediaImportBackgroundTask ?? _endBackgroundTaskOnPlatform,
       _callbackCoordinator =
           callbackCoordinator ?? AnkiMobileCallbackCoordinator.instance;

  final AnkiMobileUrlOpener _openUrl;
  final AnkiMobileInfoReader _readInfoForAdding;
  final AnkiMobileBackgroundTaskHandler _beginMediaImportBackgroundTask;
  final AnkiMobileBackgroundTaskHandler _endMediaImportBackgroundTask;
  final AnkiMobileCallbackCoordinator _callbackCoordinator;
  final Duration mediaServerLifetime;

  static Future<bool> _openExternalUrl(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  static Future<String?> _readInfoFromPlatform() =>
      _ankiMobileChannel.invokeMethod<String>('consumeInfoForAddingPasteboard');

  static Future<void> _beginBackgroundTaskOnPlatform() async {
    if (!Platform.isIOS) return;
    await _ankiMobileChannel.invokeMethod<void>(
      'beginMediaImportBackgroundTask',
    );
  }

  static Future<void> _endBackgroundTaskOnPlatform() async {
    if (!Platform.isIOS) return;
    await _ankiMobileChannel.invokeMethod<void>('endMediaImportBackgroundTask');
  }

  Future<AnkiMobileInfo> fetchInfo() async {
    final requestId = _callbackCoordinator.nextRequestId();
    final callback = Uri(
      scheme: 'mangayomi',
      host: 'anki',
      path: '/info',
      queryParameters: {'request': requestId},
    );
    final returned = _callbackCoordinator.registerInfoRequest(requestId);
    final uri = Uri.parse(_ankiMobileInfoUrl)
        .replace(queryParameters: {'x-success': callback.toString()});
    final opened = await _openUrl(uri);
    if (!opened) {
      _callbackCoordinator.cancelInfoRequest(requestId);
      throw const AnkiMobileException(
        'Could not open AnkiMobile. Install AnkiMobile and try again.',
      );
    }
    try {
      await returned.timeout(const Duration(minutes: 2));
    } on TimeoutException {
      _callbackCoordinator.cancelInfoRequest(requestId);
      throw const AnkiMobileException(
        'AnkiMobile did not return its decks and note types. Try Refresh again.',
      );
    }

    String? raw;
    for (var attempt = 0; attempt < 4; attempt++) {
      raw = await _readInfoForAdding();
      if (raw != null && raw.trim().isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (raw == null || raw.trim().isEmpty) {
      throw const AnkiMobileException(
        'AnkiMobile returned without configuration data.',
      );
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('Expected an object');
      final info = AnkiMobileInfo.fromJson(Map<String, dynamic>.from(decoded));
      if (info.decks.isEmpty || info.noteTypes.isEmpty) {
        throw const AnkiMobileException(
          'AnkiMobile returned no decks or note types.',
        );
      }
      return info;
    } on AnkiMobileException {
      rethrow;
    } catch (error) {
      throw AnkiMobileException(
        'Could not read AnkiMobile configuration: $error',
      );
    }
  }

  Future<void> exportDraft(
    AnkiCardDraft draft, {
    bool allowDuplicate = false,
  }) async {
    AnkiMobileMediaServer? mediaServer;
    var backgroundTaskStarted = false;
    try {
      final media = <AnkiMediaFile>[
        ...draft.mediaFiles,
        if (draft.screenshotBytes != null && draft.screenshotFileName != null)
          AnkiMediaFile(
            filename: draft.screenshotFileName!,
            bytes: draft.screenshotBytes!,
          ),
      ];
      final mediaUrls = <String, String>{};
      if (media.isNotEmpty) {
        mediaServer = await AnkiMobileMediaServer.start();
        for (final file in media) {
          mediaUrls[file.filename] = mediaServer.addBytes(
            file.filename,
            file.bytes,
          );
        }
      }
      final preparedDraft = AnkiCardDraft(
        deckName: draft.deckName,
        modelName: draft.modelName,
        expression: draft.expression,
        fields: {
          for (final field in draft.fields.entries)
            field.key: replaceAnkiMobileMediaReferences(field.value, mediaUrls),
        },
        tags: draft.tags,
      );
      final requestId = _callbackCoordinator.nextRequestId();
      final callback = Uri(
        scheme: 'mangayomi',
        host: 'anki',
        path: '/added',
        queryParameters: {'request': requestId},
      );
      final uri = buildAnkiMobileAddNoteUri(
        draft: preparedDraft,
        allowDuplicate: allowDuplicate,
        successCallback: callback,
      );
      if (mediaServer != null) {
        try {
          await _beginMediaImportBackgroundTask();
          backgroundTaskStarted = true;
        } catch (error, stackTrace) {
          AppLogger.log(
            'Could not start AnkiMobile media background task: '
            '$error\n$stackTrace',
            logLevel: LogLevel.warning,
          );
        }
      }
      final opened = await _openUrl(uri);
      if (!opened) {
        throw const AnkiMobileException(
          'Could not open AnkiMobile. Install AnkiMobile and try again.',
        );
      }
      if (mediaServer != null) {
        final serverToClose = mediaServer;
        mediaServer = null;
        Timer(mediaServerLifetime, () async {
          await serverToClose.close();
          if (backgroundTaskStarted) {
            try {
              await _endMediaImportBackgroundTask();
            } catch (error, stackTrace) {
              AppLogger.log(
                'Could not end AnkiMobile media background task: '
                '$error\n$stackTrace',
                logLevel: LogLevel.warning,
              );
            }
          }
        });
      }
    } catch (_) {
      await mediaServer?.close();
      if (backgroundTaskStarted) {
        try {
          await _endMediaImportBackgroundTask();
        } catch (error, stackTrace) {
          AppLogger.log(
            'Could not end AnkiMobile media background task: '
            '$error\n$stackTrace',
            logLevel: LogLevel.warning,
          );
        }
      }
      rethrow;
    }
  }
}

@visibleForTesting
String replaceAnkiMobileMediaReferences(
  String html,
  Map<String, String> mediaUrls,
) {
  var value = html;
  for (final media in mediaUrls.entries) {
    final escapedName = RegExp.escape(media.key);
    final standaloneImage = RegExp(
      '^\\s*<img\\b[^>]*\\bsrc\\s*=\\s*["\\\']$escapedName["\\\'][^>]*>\\s*\$',
      caseSensitive: false,
    );
    if (standaloneImage.hasMatch(value)) {
      // AnkiMobile imports media when the field value itself is a media URL.
      // Leaving the loopback URL inside HTML would produce a broken image as
      // soon as the temporary media server shuts down.
      value = media.value;
      continue;
    }
    value = value.replaceAll('[sound:${media.key}]', media.value);
    value = value.replaceAllMapped(
      RegExp(
        '(<img\\b[^>]*\\bsrc\\s*=\\s*["\\\'])$escapedName(["\\\'])',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}${media.value}${match.group(2)}',
    );
  }
  return value;
}

@visibleForTesting
class AnkiMobileMediaServer {
  AnkiMobileMediaServer._(this._server) {
    _server.listen(_handleRequest);
  }

  final HttpServer _server;
  final Map<String, _AnkiMobileMedia> _media = {};
  var _nextId = 0;
  var _closed = false;

  static Future<AnkiMobileMediaServer> start() async => AnkiMobileMediaServer._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );

  String addBytes(String filename, Uint8List bytes) {
    final safeName = _safeName(filename);
    // Any app or web page on the device can reach loopback while the server
    // is up, so only AnkiMobile, which gets the full URL, can name the file.
    final path = '/media/${_nextId++}-${_randomToken()}-$safeName';
    _media[path] = _AnkiMobileMedia(
      bytes: Uint8List.fromList(bytes),
      contentType: _contentTypeFor(safeName),
    );
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: _server.port,
      path: path,
    ).toString();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close(force: true);
    _media.clear();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      request.response.headers
        ..set(HttpHeaders.accessControlAllowOriginHeader, '*')
        ..set(HttpHeaders.cacheControlHeader, 'no-store');
      if (request.method != 'GET' && request.method != 'HEAD') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }
      final media = _media[request.uri.path];
      if (media == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.headers
        ..contentType = media.contentType
        ..contentLength = media.bytes.length;
      if (request.method == 'GET') request.response.add(media.bytes);
      await request.response.close();
    } catch (error, stackTrace) {
      AppLogger.log(
        'AnkiMobile media server failed: $error\n$stackTrace',
        logLevel: LogLevel.warning,
      );
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  static final _random = Random.secure();

  static String _randomToken() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  static String _safeName(String filename) {
    final base = filename.split(RegExp(r'[/\\]')).last;
    return (base.isEmpty ? 'media.bin' : base).replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'),
      '_',
    );
  }

  static ContentType _contentTypeFor(String filename) {
    final extension = filename.split('.').last.toLowerCase();
    return switch (extension) {
      'jpg' || 'jpeg' => ContentType('image', 'jpeg'),
      'png' => ContentType('image', 'png'),
      'gif' => ContentType('image', 'gif'),
      'webp' => ContentType('image', 'webp'),
      'svg' => ContentType('image', 'svg+xml'),
      'mp3' => ContentType('audio', 'mpeg'),
      'm4a' || 'mp4' => ContentType('audio', 'mp4'),
      'ogg' => ContentType('audio', 'ogg'),
      'opus' => ContentType('audio', 'opus'),
      'wav' => ContentType('audio', 'wav'),
      'webm' => ContentType('audio', 'webm'),
      'aac' => ContentType('audio', 'aac'),
      'flac' => ContentType('audio', 'flac'),
      _ => ContentType.binary,
    };
  }
}

class _AnkiMobileMedia {
  const _AnkiMobileMedia({required this.bytes, required this.contentType});

  final Uint8List bytes;
  final ContentType contentType;
}
