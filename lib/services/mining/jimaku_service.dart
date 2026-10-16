import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

class JimakuException implements Exception {
  const JimakuException(this.message);

  final String message;

  @override
  String toString() => message;
}

class JimakuEntry {
  const JimakuEntry({
    required this.id,
    required this.name,
    this.englishName,
    this.japaneseName,
  });

  factory JimakuEntry.fromJson(Map<String, dynamic> json) => JimakuEntry(
    id: (json['id'] as num).toInt(),
    name: json['name']?.toString() ?? '',
    englishName: json['english_name']?.toString(),
    japaneseName: json['japanese_name']?.toString(),
  );

  final int id;
  final String name;
  final String? englishName;
  final String? japaneseName;
}

class JimakuFile {
  const JimakuFile({
    required this.url,
    required this.name,
    required this.size,
    required this.lastModified,
  });

  factory JimakuFile.fromJson(Map<String, dynamic> json) => JimakuFile(
    url: Uri.parse(json['url']?.toString() ?? ''),
    name: json['name']?.toString() ?? 'jimaku-subtitle.srt',
    size: (json['size'] as num?)?.toInt() ?? 0,
    lastModified: json['last_modified']?.toString() ?? '',
  );

  final Uri url;
  final String name;
  final int size;
  final String lastModified;
}

class JimakuMediaGuess {
  const JimakuMediaGuess({
    required this.title,
    this.episode,
    this.season,
    Set<int>? episodeCandidates,
  }) : episodeCandidates = episodeCandidates ?? const {};

  final String title;
  final int? episode;
  final int? season;
  final Set<int> episodeCandidates;

  String get displayName {
    final seasonText = season == null ? '' : ' season $season';
    final episodeText = episode == null ? '' : ' episode $episode';
    return '$title$seasonText$episodeText';
  }

  bool matchesEpisode(int value) =>
      value == episode || episodeCandidates.contains(value);

  bool get hasEpisodeCandidates =>
      episode != null || episodeCandidates.isNotEmpty;
}

class JimakuSubtitleService {
  JimakuSubtitleService({http.Client? client})
    : _client = client ?? http.Client();

  static const _baseUrl = 'https://jimaku.cc/api';
  static const _requestTimeout = Duration(seconds: 30);
  final http.Client _client;

  void close() => _client.close();

  Future<List<JimakuEntry>> searchEntries({
    required String apiKey,
    required String query,
  }) async {
    final entries = [
      ...await _searchEntries(apiKey: apiKey, query: query, anime: true),
      ...await _searchEntries(apiKey: apiKey, query: query, anime: false),
    ];
    final seen = <int>{};
    return entries.where((entry) => seen.add(entry.id)).toList();
  }

  Future<List<JimakuFile>> getFiles({
    required String apiKey,
    required int entryId,
    int? episode,
  }) async {
    final builder = Uri.parse('$_baseUrl/entries/$entryId/files');
    final uri = episode == null
        ? builder
        : builder.replace(queryParameters: {'episode': episode.toString()});
    final response = await _client
        .get(uri, headers: _headers(apiKey))
        .timeout(_requestTimeout);
    _throwIfBad(response);
    return (jsonDecode(response.body) as List)
        .whereType<Map>()
        .map((value) => JimakuFile.fromJson(value.cast<String, dynamic>()))
        .toList();
  }

  Future<File> downloadFile({
    required String apiKey,
    required JimakuFile file,
    required Directory outputDirectory,
  }) async {
    await outputDirectory.create(recursive: true);
    final output = File(p.join(outputDirectory.path, _safeFileName(file.name)));
    // Fetch before touching the existing file, so a failed request keeps
    // the subtitle that is already on disk.
    final response = await _client
        .get(file.url, headers: _headers(apiKey))
        .timeout(_requestTimeout);
    _throwIfBad(response);
    await output.writeAsBytes(response.bodyBytes);
    return output;
  }

  Future<List<File>> downloadFiles({
    required String apiKey,
    required Iterable<JimakuFile> files,
    required Directory outputDirectory,
  }) async {
    final downloaded = <File>[];
    for (final file in files) {
      downloaded.add(
        await downloadFile(
          apiKey: apiKey,
          file: file,
          outputDirectory: outputDirectory,
        ),
      );
    }
    return downloaded;
  }

  Future<List<JimakuFile>> matchingFiles({
    required String apiKey,
    required JimakuEntry entry,
    required JimakuMediaGuess guess,
  }) async {
    final episodeFiles = await getFiles(
      apiKey: apiKey,
      entryId: entry.id,
      episode: guess.episode,
    );
    final matched = episodeFiles.matchedSrtFiles(
      guess,
      episodeFiltered: guess.episode != null,
    );
    if (matched.isNotEmpty || guess.episode == null) {
      return _distinctJimakuFilesByUrl(matched);
    }
    final allFiles = await getFiles(apiKey: apiKey, entryId: entry.id);
    return _distinctJimakuFilesByUrl(
      allFiles.matchedSrtFiles(guess, episodeFiltered: false),
    );
  }

  Future<List<JimakuEntry>> _searchEntries({
    required String apiKey,
    required String query,
    required bool anime,
  }) async {
    final uri = Uri.parse('$_baseUrl/entries/search')
        .replace(queryParameters: {'anime': anime.toString(), 'query': query});
    final response = await _client
        .get(uri, headers: _headers(apiKey))
        .timeout(_requestTimeout);
    _throwIfBad(response);
    return (jsonDecode(response.body) as List)
        .whereType<Map>()
        .map((value) => JimakuEntry.fromJson(value.cast<String, dynamic>()))
        .toList();
  }

  Map<String, String> _headers(String apiKey) => {
    'Authorization': apiKey.trim(),
  };

  void _throwIfBad(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw JimakuException(
      'Jimaku HTTP ${response.statusCode}: ${response.body}',
    );
  }
}

class _JimakuEpisodeNumbers {
  const _JimakuEpisodeNumbers(this.primary, this.candidates);

  final int? primary;
  final Set<int> candidates;
}

JimakuMediaGuess? guessJimakuMedia(String value) {
  final withoutExtension = _toJimakuFilename(value)
      .replaceAll(_knownExtensionRegex, '');
  final season = _firstNumber(_seasonRegexes, withoutExtension);
  final episodeNumbers = _jimakuEpisodeNumbers(withoutExtension);
  final title = _cleanJimakuTitleCandidate(
    _preferredJimakuTitleSeed(withoutExtension),
  );
  if (title.trim().isEmpty) return null;
  return JimakuMediaGuess(
    title: title,
    episode: episodeNumbers.primary,
    season: season,
    episodeCandidates: episodeNumbers.candidates,
  );
}

JimakuMediaGuess buildChimahonJimakuGuess({
  String overrideTitle = '',
  String animeTitle = '',
  String mediaTitle = '',
  String videoTitle = '',
  String videoUrl = '',
  int? episodeNumber,
}) {
  final candidates = [
    animeTitle,
    mediaTitle,
    videoTitle,
    videoUrl,
  ].where((value) => value.trim().isNotEmpty);
  final parsedCandidates = candidates
      .map(guessJimakuMedia)
      .whereType<JimakuMediaGuess>()
      .toList();
  JimakuMediaGuess? parsed;
  for (final candidate in parsedCandidates) {
    if (candidate.season != null || candidate.episode != null) {
      parsed = candidate;
      break;
    }
  }
  parsed ??= parsedCandidates.firstOrNull;
  final title = overrideTitle.trim().isNotEmpty
      ? overrideTitle.trim()
      : animeTitle.trim().isNotEmpty
      ? animeTitle.trim()
      : parsed?.title.trim().isNotEmpty == true
      ? parsed!.title.trim()
      : mediaTitle.trim();
  final episode = episodeNumber != null && episodeNumber >= 0
      ? episodeNumber
      : parsed?.episode;
  return JimakuMediaGuess(
    title: title,
    episode: episode,
    season: parsed?.season,
  );
}

JimakuEntry? selectBestJimakuEntry(List<JimakuEntry> entries, String title) {
  if (entries.isEmpty) return null;
  if (entries.length == 1) return entries.first;

  final target = _normalizedJimakuText(title);
  for (final entry in entries) {
    final names = [
      entry.name,
      entry.englishName ?? '',
      entry.japaneseName ?? '',
    ];
    if (names.any((name) => _normalizedJimakuText(name) == target)) {
      return entry;
    }
  }

  final ranked =
      entries.map((entry) => (entry, _entryScore(entry, title))).toList()
        ..sort((a, b) => b.$2.compareTo(a.$2));
  return ranked.firstOrNull?.$1;
}

extension JimakuFileMatcher on List<JimakuFile> {
  List<JimakuFile> matchedSrtFiles(
    JimakuMediaGuess guess, {
    required bool episodeFiltered,
  }) {
    final result = where((file) => file.name.toLowerCase().endsWith('.srt'))
        .where((file) {
          final parsed = guessJimakuMedia(file.name);
          final parsedEpisode = parsed?.episode;
          final parsedSeason = parsed?.season;
          final seasonMatches =
              guess.season == null ||
              parsedSeason == null ||
              parsedSeason == guess.season;
          return seasonMatches &&
              (guess.episode == null ||
                  parsed?.matchesEpisode(guess.episode!) == true ||
                  (episodeFiltered &&
                      parsed?.hasEpisodeCandidates != true &&
                      parsedEpisode == null));
        })
        .toList();
    result.sort((a, b) {
      final score = _fileScore(b, guess).compareTo(_fileScore(a, guess));
      return score == 0 ? a.name.compareTo(b.name) : score;
    });
    return result;
  }
}

final _absoluteEpisodeRegexes = [
  RegExp(r'\u7b2c\s*(\d{1,4})\s*[\u8a71\u96c6\u56de]'),
  RegExp(r'(\d{1,4})\s*[\u8a71\u96c6\u56de]'),
  RegExp(r'(?:\uc81c\s*)?(\d{1,4})\s*(?:\ud654|\ud68c)', caseSensitive: false),
];

final _episodeRegexes = [
  RegExp(r'\bS\s*\d{1,3}\s*[._ -]*E\s*(\d{1,4})\b', caseSensitive: false),
  RegExp(r'\bS\s*\d{1,3}\s*[._ -]*x\s*E?\s*(\d{1,4})\b', caseSensitive: false),
  RegExp(r'\b\d{1,3}\s*x\s*(\d{1,4})\b', caseSensitive: false),
  RegExp(
    r'\b(?:ep|eps|episode|episodes|episodio|episodios|capitulo|capitulos|cap|e)\.?\s*[-_ ]?(\d{1,4})(?:v\d+)?\b',
    caseSensitive: false,
  ),
  RegExp(
    r'\b(\d{1,4})(?:st|nd|rd|th)?\s*(?:ep|episode|episodes)\b',
    caseSensitive: false,
  ),
  RegExp(r'[#\uff03]\s*(\d{1,4})\b'),
];

final _standaloneEpisodeRegex = RegExp(
  r'(?<![A-Za-z0-9])(\d{1,4})(?![A-Za-z0-9]|p|P)',
);

final _episodeCleanupRegex = RegExp(
  r'\bS\s*\d{1,3}\s*[._ -]*(?:E|xE?|x)\s*\d{1,4}\b|\b\d{1,3}\s*x\s*\d{1,4}\b|\b(?:ep|eps|episode|episodes|episodio|episodios|capitulo|capitulos|cap|e)\.?\s*[-_ ]?\d{1,4}(?:v\d+)?\b|[#\uff03]\s*\d{1,4}\b|\u7b2c\s*\d{1,4}\s*[\u8a71\u96c6\u56de]|\d{1,4}\s*[\u8a71\u96c6\u56de]|(?:\uc81c\s*)?\d{1,4}\s*(?:\ud654|\ud68c)',
  caseSensitive: false,
);

final _seasonRegexes = [
  RegExp(
    r'\bS\s*(\d{1,3})\s*[._ -]*(?:E|xE?|x)\s*\d{1,4}\b',
    caseSensitive: false,
  ),
  RegExp(r'\b(\d{1,3})\s*x\s*\d{1,4}\b', caseSensitive: false),
  RegExp(
    r'\b(?:season|seasons|saison|saisons|seizoen|temporada|temporadas|stagione|temp|s)\.?\s*(\d{1,3})\b',
    caseSensitive: false,
  ),
];

final _seasonCleanupRegex = RegExp(
  r'\bseason[ ._-]*\d{1,3}\b',
  caseSensitive: false,
);

final _knownExtensionRegex = RegExp(
  r'\.(?:3g2|3gp|avi|divx|flv|m2ts|m4v|mkv|mov|mp4|mpeg|mpg|ogm|ogv|rmvb|ts|vob|webm|wmv|ass|idx|smi|srt|ssa|sub|vtt)$',
  caseSensitive: false,
);

const _releaseInfoPattern =
    r'144p|240p|360p|368p|480p|540p|576p|720p|900p|960p|1080[pi]|1440p|2160p|4320p|4k|8k|uhd|fhd|vhs(?:rip)?|cam(?:rip)?|hdcam|telesync|hdts|ts|workprint|wp|telecine|hdtc|tc|ppv|sdtv|pdtv|hdtv|tvrip|dvb|dsr|dth|satrip|vod(?:rip)?|web(?:rip|dl|cap|uhd)?|webrip|web-dl|webdl|webcap|dlweb|dvd(?:rip|r|5|9)?|dvdrip|hddvd|blu-?ray|b[dr](?:rip|remux)?|brrip|bdrip|remux|xvid|divx|x264|x265|h[._-]?264|h[._-]?265|hevc|avc|av1|vp9|vc-?1|mpeg-?2|hi10p|10bit|8bit|mp3|mp2|aac|ac-?3|e-?ac-?3|ddp?|dd\+|dts(?:-?hd|-?ma|-?x)?|true-?hd|atmos|flac|opus|vorbis|pcm|lpcm|[257]\.?1(?:ch)?|[12678]ch|dual[ ._-]?audio|multi[ ._-]?audio|fansub|fastsub|hardsub|softsub|subbed|dubbed|vostfr|vost|pal|ntsc|secam|hdr(?:10\+?)?|dv|dolby[ ._-]?vision|sdr|bt[ ._-]?2020|proper|repack|rerip|internal|limited|extended|uncensored|uncut|remastered|directors?[ ._-]?cut|hybrid|complete|amzn|amazon|nf|netflix|hulu|dsnp|disney\+?|cr|crunchyroll|hidive|hbo|hmax|atvp|baha|bilibili|funi|yye?ts';

final _filenameReleaseTailRegex = RegExp(
  '(?<=\\S)(?:[\\s._-]+|[\\[(]\\s*)(?:$_releaseInfoPattern)(?=\$|[\\s._-]|\\]|\\)|\\}).*\$',
  caseSensitive: false,
);
final _filenameJunkRegex = RegExp(
  '(?:^|[\\s._-])(?:$_releaseInfoPattern)(?=\$|[\\s._-])|\\[[^\\]]*]|\\([^)]*\\)|\\{[^}]*\\}',
  caseSensitive: false,
);
final _trailingEpisodeCleanupRegex = RegExp(
  r'(?<=\S)\s*(?:[-._]+\s*(?:ep|episode|e)?\.?|(?:ep|episode|e)\.?\s*)\d{1,4}\s*$',
  caseSensitive: false,
);
final _leadingReleaseGroupRegex = RegExp(
  r'^\s*(?:\[[^\]]{1,80}]|\([^)]{1,80}\)|\{[^}]{1,80}\})\s*',
);
final _trailingReleaseGroupRegex = RegExp(
  r'(?<=\S)-[A-Za-z0-9][A-Za-z0-9._-]{1,40}$',
  caseSensitive: false,
);
final _hashRegex = RegExp(
  r'[\[(]?[A-F0-9]{8}(?:[A-F0-9]{8})?[\])]?(?=$|[\s._-])',
  caseSensitive: false,
);
final _websiteRegex = RegExp(
  r'\b(?:www\.)?[A-Za-z0-9-]+\.(?:com|net|org|ru|cc|tv)\b',
  caseSensitive: false,
);
final _subtitleLanguageSuffixRegex = RegExp(
  r'(?:[\s._-]+(?:sub|subs|subtitle|subtitles|dub|dual|multi|eng|english|en|en-us|en-gb|fre|french|fr|spa|spanish|es|ger|deu|de|ita|it|por|pt|rus|ru|jpn|japanese|ja|jp|ja-jp|kor|korean|ko|chi|chs|cht|zho|zh|ara|ar))+\s*$',
  caseSensitive: false,
);

final _titleBeforeEpisodeRegexes = [
  RegExp(
    r'^(.+?)(?=[\s._-]+S\s*\d{1,3}\s*[._ -]*(?:E|xE?|x)\s*\d{1,4}\b)',
    caseSensitive: false,
  ),
  RegExp(r'^(.+?)(?=[\s._-]+\d{1,3}\s*x\s*\d{1,4}\b)', caseSensitive: false),
  RegExp(
    r'^(.+?)(?=\s*[-._]\s*(?:ep|episode|e)?\.?\s*\d{1,4}\b)',
    caseSensitive: false,
  ),
  RegExp(r'^(.+?)(?=[\s._-]+\u7b2c\s*\d{1,4}\s*[\u8a71\u96c6\u56de])'),
];

final _titleAfterLeadingEpisodeRegexes = [
  RegExp(
    r'^\s*(?:\[[^\]]{1,80}]\s*)?(?:[#\uff03]\s*)?\d{1,4}(?:v\d+)?\s*[-._ ]+\s*(.+)$',
    caseSensitive: false,
  ),
  RegExp(
    r'^\s*(?:\[[^\]]{1,80}]\s*)?(?:ep|episode|e)\.?\s*\d{1,4}(?:v\d+)?\s*[-._ ]+\s*(.+)$',
    caseSensitive: false,
  ),
];

const _ignoredNumbers = {480, 720, 1080, 2160, 264, 265, 10};

String _toJimakuFilename(String value) => value
    .split('?')
    .first
    .split('#')
    .first
    .split('/')
    .last
    .split('\\')
    .last
    .trim();

_JimakuEpisodeNumbers _jimakuEpisodeNumbers(String value) {
  final absolute = _numbersFrom(_absoluteEpisodeRegexes, value);
  final marked = _numbersFrom(_episodeRegexes, value);
  final standalone = _standaloneEpisodeRegex
      .allMatches(value)
      .map((match) => int.tryParse(match.group(1) ?? ''))
      .whereType<int>()
      .where(
        (number) => _validEpisode(number) && !_ignoredNumbers.contains(number),
      )
      .toList();
  final weak = absolute.isEmpty && marked.isEmpty ? standalone : <int>[];
  final primary = absolute.firstOrNull ?? marked.firstOrNull ?? weak.lastOrNull;
  final candidates = <int>{...absolute, ...marked, ...weak}
    ..removeWhere((number) => !_validEpisode(number));
  return _JimakuEpisodeNumbers(primary, candidates);
}

List<int> _numbersFrom(List<RegExp> regexes, String value) => regexes
    .expand((regex) => regex.allMatches(value))
    .map((match) => int.tryParse(match.group(match.groupCount) ?? ''))
    .whereType<int>()
    .where(_validEpisode)
    .toList();

int? _firstNumber(List<RegExp> regexes, String value) => regexes
    .map((regex) => int.tryParse(regex.firstMatch(value)?.group(1) ?? ''))
    .whereType<int>()
    .firstOrNull;

bool _validEpisode(int value) => value >= 0 && value <= 9999;

String _preferredJimakuTitleSeed(String value) {
  for (final regex in _titleBeforeEpisodeRegexes) {
    final candidate = regex.firstMatch(value)?.group(1) ?? '';
    if (_normalizedJimakuText(_cleanJimakuTitleCandidate(candidate)).length >=
        2) {
      return candidate;
    }
  }
  for (final regex in _titleAfterLeadingEpisodeRegexes) {
    final candidate = regex.firstMatch(value)?.group(1) ?? '';
    if (_normalizedJimakuText(_cleanJimakuTitleCandidate(candidate)).length >=
        2) {
      return candidate;
    }
  }
  return value;
}

String _cleanJimakuTitleCandidate(String value) => value
    .replaceAll(_knownExtensionRegex, '')
    .replaceAll(_leadingReleaseGroupRegex, ' ')
    .replaceAll(_hashRegex, ' ')
    .replaceAll(_websiteRegex, ' ')
    .replaceAll(_episodeCleanupRegex, ' ')
    .replaceAll(_seasonCleanupRegex, ' ')
    .replaceAll(_filenameReleaseTailRegex, ' ')
    .replaceAll(_filenameJunkRegex, ' ')
    .replaceAll(_subtitleLanguageSuffixRegex, ' ')
    .replaceAll(_trailingEpisodeCleanupRegex, ' ')
    .replaceAll(_trailingReleaseGroupRegex, ' ')
    .replaceAll(RegExp(r'[._-]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _normalizedJimakuText(String value) {
  final buffer = StringBuffer();
  var lastWasSpace = true;
  for (final rune in value.toLowerCase().runes) {
    final character = String.fromCharCode(rune);
    if (RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(character)) {
      buffer.write(character);
      lastWasSpace = false;
    } else if (!lastWasSpace) {
      buffer.write(' ');
      lastWasSpace = true;
    }
  }
  return buffer.toString().trim();
}

int _entryScore(JimakuEntry entry, String title) {
  final target = _normalizedJimakuText(title);
  var best = 0;
  for (final candidate in [
    entry.name,
    entry.englishName ?? '',
    entry.japaneseName ?? '',
  ]) {
    if (candidate.trim().isEmpty) continue;
    final normalized = _normalizedJimakuText(candidate);
    final score = normalized == target
        ? 100
        : normalized.contains(target) || target.contains(normalized)
        ? 90
        : _tokenScore(target, normalized);
    if (score > best) best = score;
  }
  return best;
}

int _fileScore(JimakuFile file, JimakuMediaGuess guess) {
  final parsed = guessJimakuMedia(file.name);
  var score = 0;
  if (guess.season != null) {
    score += parsed?.season == guess.season
        ? 60
        : parsed?.season == null
        ? 0
        : -160;
  }
  if (guess.episode != null) {
    score += parsed?.matchesEpisode(guess.episode!) == true
        ? 100
        : parsed?.hasEpisodeCandidates == true
        ? -80
        : parsed?.episode == null
        ? 20
        : -80;
  }
  final fileTitle = _normalizedJimakuText(parsed?.title ?? '');
  final targetTitle = _normalizedJimakuText(guess.title);
  if (fileTitle.isNotEmpty &&
      targetTitle.isNotEmpty &&
      (fileTitle.contains(targetTitle) || targetTitle.contains(fileTitle))) {
    score += 25;
  }
  final lower = file.name.toLowerCase();
  if (lower.contains('ja-jp') ||
      lower.contains('japanese') ||
      lower.contains('.ja.')) {
    score += 25;
  }
  if (lower.endsWith('.ass') ||
      lower.endsWith('.srt') ||
      lower.endsWith('.ssa')) {
    score += 10;
  }
  return score;
}

int _tokenScore(String target, String candidate) {
  final targetTokens = target
      .split(' ')
      .where((item) => item.isNotEmpty)
      .toSet();
  final candidateTokens = candidate
      .split(' ')
      .where((item) => item.isNotEmpty)
      .toSet();
  if (targetTokens.isEmpty || candidateTokens.isEmpty) return 0;
  return (targetTokens.intersection(candidateTokens).length * 100) ~/
      (targetTokens.length > candidateTokens.length
          ? targetTokens.length
          : candidateTokens.length);
}

String _safeFileName(String value) {
  final safe = value
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return safe.isEmpty ? 'jimaku-subtitle.srt' : safe;
}

List<JimakuFile> _distinctJimakuFilesByUrl(Iterable<JimakuFile> files) {
  final seen = <Uri>{};
  return files.where((file) => seen.add(file.url)).toList();
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
  T? get lastOrNull => isEmpty ? null : last;
}
