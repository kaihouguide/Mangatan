import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:mangayomi/services/mining/media_file_name.dart';
import 'package:mangayomi/services/mining/mining_models.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';

class AnkiAudioService {
  AnkiAudioService({http.Client? client, bool? closeClient})
    : _client = client,
      _closeClient = closeClient ?? client == null;

  final http.Client? _client;
  final bool _closeClient;

  Future<AnkiMediaFile?> fetchTermAudio({
    required String term,
    required String reading,
    required AnkiAudioPreferences preferences,
  }) async {
    if (!preferences.enabled || preferences.effectiveSources.isEmpty) {
      return null;
    }
    final client = _client ?? http.Client();
    try {
      for (final source in preferences.effectiveSources) {
        try {
          final results = await _resolveSource(
            client,
            source,
            term: term,
            reading: reading,
            language: preferences.language,
            timeout: preferences.timeout,
          );
          for (final result in results) {
            final media = await _tryDownloadAudio(
              client,
              result.url,
              term: term,
              reading: reading,
              timeout: preferences.timeout,
              rejectJapanesePod101Placeholder:
                  source.type == AnkiAudioSourceType.japanesePod101,
            );
            if (media != null) return media;
          }
        } catch (_) {
          // Try the next configured source, matching Yomitan fallback order.
        }
      }
      return null;
    } finally {
      if (_closeClient) client.close();
    }
  }

  Future<List<AnkiAudioSourceResult>> resolveTermAudioSources({
    required String term,
    required String reading,
    required AnkiAudioPreferences preferences,
  }) async {
    if (!preferences.enabled || preferences.effectiveSources.isEmpty) {
      return const [];
    }
    final client = _client ?? http.Client();
    try {
      final groupedResults = await Future.wait(
        preferences.effectiveSources.map((source) async {
          try {
            final resolved = await _resolveSource(
              client,
              source,
              term: term,
              reading: reading,
              language: preferences.language,
              timeout: preferences.timeout,
            );
            if (source.type == AnkiAudioSourceType.japanesePod101 &&
                resolved.isNotEmpty) {
              final valid = await _tryDownloadAudio(
                client,
                resolved.first.url,
                term: term,
                reading: reading,
                timeout: preferences.timeout,
                rejectJapanesePod101Placeholder: true,
              );
              if (valid == null) return const <AnkiAudioSourceResult>[];
            }
            return resolved;
          } catch (_) {
            // A broken source must not hide later sources from the popup menu.
            return const <AnkiAudioSourceResult>[];
          }
        }),
      );
      return groupedResults
          .expand((results) => results)
          .toList(growable: false);
    } finally {
      if (_closeClient) client.close();
    }
  }

  Future<List<AnkiAudioSourceResult>> _resolveSource(
    http.Client client,
    AnkiAudioSource source, {
    required String term,
    required String reading,
    required String language,
    required Duration timeout,
  }) async {
    switch (source.type) {
      case AnkiAudioSourceType.japanesePod101:
        return [
          AnkiAudioSourceResult(
            name: source.displayName,
            url: _japanesePod101Uri(term, reading),
          ),
        ];
      case AnkiAudioSourceType.jisho:
        return _fetchJishoSources(
          client,
          term: term,
          reading: reading,
          timeout: timeout,
        );
      case AnkiAudioSourceType.languagePod101:
        return _fetchLanguagePod101Sources(
          client,
          term: term,
          reading: reading,
          language: language,
          timeout: timeout,
        );
      case AnkiAudioSourceType.customUrl:
        if (source.url.trim().isEmpty) return const [];
        final uri = _templateUri(
          source.url,
          term: term,
          reading: reading,
          language: language,
        );
        return [AnkiAudioSourceResult(name: _sourceName(uri), url: uri)];
      case AnkiAudioSourceType.customJson:
        if (source.url.trim().isEmpty) return const [];
        final uri = _templateUri(
          source.url,
          term: term,
          reading: reading,
          language: language,
        );
        return _fetchCustomJsonSources(client, uri, timeout: timeout);
    }
  }

  Uri _japanesePod101Uri(String term, String reading) {
    final kanaOnly =
        term.isNotEmpty &&
        RegExp(r'^[\u3040-\u30ffー]+$').hasMatch(term) &&
        term == reading;
    return Uri.https(
      'assets.languagepod101.com',
      '/dictionary/japanese/audiomp3.php',
      {
        if (!kanaOnly && term.isNotEmpty) 'kanji': term,
        if (reading.isNotEmpty) 'kana': reading,
      },
    );
  }

  Future<List<AnkiAudioSourceResult>> _fetchJishoSources(
    http.Client client, {
    required String term,
    required String reading,
    required Duration timeout,
  }) async {
    final searchUri = Uri.https('jisho.org', '/search/$term');
    final response = await client
        .get(searchUri, headers: _htmlRequestHeaders)
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return const [];
    }
    final document = html_parser.parse(utf8.decode(response.bodyBytes));
    final audioId = 'audio_$term:$reading';
    final audio = document
        .querySelectorAll('audio')
        .where((element) => element.attributes['id'] == audioId)
        .firstOrNull;
    final rawUrl = audio?.querySelector('source')?.attributes['src'];
    if (rawUrl == null || rawUrl.trim().isEmpty) return const [];
    return [
      AnkiAudioSourceResult(name: 'Jisho.org', url: searchUri.resolve(rawUrl)),
    ];
  }

  Future<List<AnkiAudioSourceResult>> _fetchLanguagePod101Sources(
    http.Client client, {
    required String term,
    required String reading,
    required String language,
    required Duration timeout,
  }) async {
    final host = switch (language) {
      'en' => 'www.englishclass101.com',
      'zh' => 'www.chineseclass101.com',
      'ko' => 'www.koreanclass101.com',
      _ => 'www.japanesepod101.com',
    };
    final uri = Uri.https(host, '/learningcenter/reference/dictionary_post');
    final response = await client
        .post(
          uri,
          headers: const {
            'content-type': 'application/x-www-form-urlencoded',
            ..._htmlRequestHeaders,
          },
          body: {
            'post': 'dictionary_reference',
            'match_type': 'exact',
            'search_query': term,
            'vulgar': 'true',
          },
        )
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return const [];
    }
    final document = html_parser.parse(utf8.decode(response.bodyBytes));
    final urls = <Uri>{};
    for (final row in document.querySelectorAll('.dc-result-row')) {
      if (language == 'ja') {
        final rowReading = row.querySelector('.dc-vocab_kana')?.text.trim();
        if (rowReading == null || (reading != term && rowReading != reading)) {
          continue;
        }
      } else {
        final rowTerm = row.querySelector('.dc-vocab')?.text.trim();
        if (rowTerm != term) continue;
      }
      final rawUrl = row.querySelector('audio source')?.attributes['src'];
      if (rawUrl == null || rawUrl.trim().isEmpty) continue;
      urls.add(uri.resolve(rawUrl));
    }
    return [
      for (final url in urls)
        AnkiAudioSourceResult(name: 'LanguagePod101', url: url),
    ];
  }

  Future<AnkiMediaFile?> _tryDownloadAudio(
    http.Client client,
    Uri uri, {
    required String term,
    required String reading,
    required Duration timeout,
    bool rejectJapanesePod101Placeholder = false,
  }) async {
    try {
      return await _downloadAudio(
        client,
        uri,
        term: term,
        reading: reading,
        timeout: timeout,
        rejectJapanesePod101Placeholder: rejectJapanesePod101Placeholder,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<AnkiAudioSourceResult>> _fetchCustomJsonSources(
    http.Client client,
    Uri sourceUri, {
    required Duration timeout,
  }) async {
    final response = await client.get(sourceUri).timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return const [];
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map || decoded['type'] != 'audioSourceList') {
      return const [];
    }
    final rawSources = decoded['audioSources'];
    if (rawSources is! List) return const [];
    final sources = <AnkiAudioSourceResult>[];
    for (final (index, source) in rawSources.indexed) {
      if (source is! Map) continue;
      final rawUrl = source['url']?.toString();
      if (rawUrl == null || rawUrl.trim().isEmpty) continue;
      final uri = sourceUri.resolve(rawUrl);
      sources.add(
        AnkiAudioSourceResult(
          name: _sourceName(uri, source['name']?.toString(), index),
          url: uri,
        ),
      );
    }
    return sources;
  }

  Future<AnkiMediaFile?> _downloadAudio(
    http.Client client,
    Uri uri, {
    required String term,
    required String reading,
    required Duration timeout,
    bool rejectJapanesePod101Placeholder = false,
  }) async {
    final response = await client.get(uri).timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final contentType = response.headers['content-type'] ?? '';
    if (!_looksLikeAudio(contentType, response.bodyBytes)) return null;
    if (rejectJapanesePod101Placeholder &&
        sha256.convert(response.bodyBytes).toString() ==
            'ae6398b5a27bc8c0a771df6c907ade794be15518174773c58c7c7ddd17098906') {
      return null;
    }
    final extension = _audioExtension(contentType, uri);
    return AnkiMediaFile(
      filename: _safeAudioFilename(term, reading, extension),
      bytes: Uint8List.fromList(response.bodyBytes),
    );
  }

  Uri _templateUri(
    String template, {
    required String term,
    required String reading,
    required String language,
  }) {
    final values = {'term': term, 'reading': reading, 'language': language};
    final raw = template.replaceAllMapped(RegExp(r'\{([^}]*)\}'), (match) {
      final key = match.group(1);
      return key != null && values.containsKey(key) ? values[key]! : match[0]!;
    });
    return Uri.parse(raw);
  }

  bool _looksLikeAudio(String contentType, List<int> bytes) {
    final type = contentType.toLowerCase();
    if (type.startsWith('audio/')) return true;
    if (bytes.length >= 3 &&
        bytes[0] == 0x49 &&
        bytes[1] == 0x44 &&
        bytes[2] == 0x33) {
      return true;
    }
    if (bytes.length >= 4) {
      final magic = String.fromCharCodes(bytes.take(4)).toLowerCase();
      return magic == 'oggs' || magic == 'riff';
    }
    return false;
  }

  String _audioExtension(String contentType, Uri uri) {
    final type = contentType.split(';').first.trim().toLowerCase();
    final contentTypeExtension = switch (type) {
      'audio/mpeg' || 'audio/mp3' => 'mp3',
      'audio/ogg' => 'ogg',
      'audio/opus' => 'opus',
      'audio/wav' || 'audio/wave' || 'audio/x-wav' => 'wav',
      'audio/webm' => 'webm',
      'audio/mp4' || 'audio/x-m4a' => 'm4a',
      'audio/aac' => 'aac',
      'audio/flac' || 'audio/x-flac' => 'flac',
      _ => null,
    };
    // Dynamic audio endpoints frequently end in .php or another server-side
    // extension. Prefer their declared audio MIME type so AnkiMobile receives
    // a filename it recognizes as downloadable media.
    if (contentTypeExtension != null) return contentTypeExtension;
    final pathExtension = uri.pathSegments.isEmpty
        ? ''
        : uri.pathSegments.last.split('.').last.toLowerCase();
    if (const {
      'mp3',
      'ogg',
      'opus',
      'wav',
      'webm',
      'm4a',
      'aac',
      'mp4',
      'flac',
    }.contains(pathExtension)) {
      return pathExtension;
    }
    return 'mp3';
  }

  String _safeAudioFilename(String term, String reading, String extension) {
    final base = sanitizeMediaFileName(
      [term, reading].where((part) => part.trim().isNotEmpty).join(' '),
      forbidBrackets: true,
    );
    final prefix = base.isEmpty ? 'mangatan-audio' : base;
    return '$prefix-${DateTime.now().millisecondsSinceEpoch}.$extension';
  }

  String _sourceName(Uri uri, [String? rawName, int? index]) {
    final name = rawName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final filename = uri.pathSegments.isEmpty
        ? ''
        : uri.pathSegments.last.trim();
    if (filename.isNotEmpty) return filename;
    return index == null ? 'Audio' : 'Audio ${index + 1}';
  }

  static const _htmlRequestHeaders = <String, String>{
    'accept': 'text/html,application/xhtml+xml',
    'user-agent':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
        'AppleWebKit/605.1.15 Mobile/15E148',
  };
}

class AnkiAudioSourceResult {
  const AnkiAudioSourceResult({required this.name, required this.url});

  final String name;
  final Uri url;

  Map<String, String> toJson() => {'name': name, 'url': url.toString()};
}
