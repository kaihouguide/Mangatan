import 'dart:convert';
import 'dart:typed_data';

import 'package:mangayomi/services/hoshidicts/dictionary_storage.dart';
import 'package:mangayomi/services/hoshidicts/yomitan_language_parser.dart';
import 'package:mangayomi/services/hoshidicts/yomitan_kanji_dictionary.dart';
import 'package:mangayomi/services/mining/dictionary_profile.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';
import 'package:mangayomi/src/rust/api/hoshidicts.dart';
import 'package:mangayomi/src/rust/api/hoshidicts/native.dart' as hoshidicts;

class HoshidictsLookupBackend {
  HoshidictsLookupBackend._();

  static final HoshidictsLookupBackend instance = HoshidictsLookupBackend._();

  // Hovering commonly revisits nearby words, so retain a small LRU without
  // holding an entire subtitle or chapter's materialized glossary data.
  static const _maxCachedLookups = 32;
  static const _directProfileKey = '<direct-rebuild>';

  final YomitanLanguageParser _yomitanParser = YomitanLanguageParser();
  final YomitanKanjiStore _kanjiStore = YomitanKanjiStore();

  hoshidicts.HoshiLookupSession? _session;
  Future<hoshidicts.HoshiLookupSession>? _initializing;
  bool _configured = false;
  String? _configuredProfileKey;
  Future<void> _queryQueue = Future.value();
  int _queryGeneration = 0;
  final Map<_LookupRequest, List<HoshiLookupResult>> _lookupCache = {};
  final Map<_LookupRequest, Future<List<HoshiLookupResult>>> _lookupsInFlight =
      {};
  final Map<String, List<HoshiDictionaryStyle>> _stylesCache = {};
  final Map<String, Future<List<HoshiDictionaryStyle>>> _stylesInFlight = {};

  bool get hasSession => _session != null;

  Future<DictionaryImportResult> importDictionary({
    required String zipPath,
    required String outputDir,
    bool lowRam = false,
  }) async {
    try {
      await ensureYomitanDictionaryTitleIsSafe(zipPath);
      final kanjiArchive = await YomitanKanjiArchive.read(zipPath);
      if (kanjiArchive == null) {
        return DictionaryImportResult.fromHoshi(
          await hoshidicts.importDictionary(
            zipPath: zipPath,
            outputDir: outputDir,
            lowRam: lowRam,
          ),
        );
      }
      HoshiImportResult? nativeResult;
      if (kanjiArchive.hasNativeBanks) {
        if (kanjiArchive.storageName != kanjiArchive.title) {
          throw const FormatException(
            'Mixed term/Kanji dictionaries must use a filesystem-safe title.',
          );
        }
        nativeResult = await hoshidicts.importDictionary(
          zipPath: zipPath,
          outputDir: outputDir,
          lowRam: lowRam,
        );
        if (!nativeResult.success) {
          return DictionaryImportResult.fromHoshi(nativeResult);
        }
      }
      await kanjiArchive.persist(outputDir);
      return DictionaryImportResult(
        success: true,
        title: kanjiArchive.storageName,
        termCount: nativeResult?.termCount ?? BigInt.zero,
        metaCount: nativeResult?.metaCount ?? BigInt.zero,
        freqCount: nativeResult?.freqCount ?? BigInt.zero,
        pitchCount: nativeResult?.pitchCount ?? BigInt.zero,
        mediaCount: nativeResult?.mediaCount ?? BigInt.zero,
        kanjiCount: BigInt.from(
          kanjiArchive.entries.length + kanjiArchive.frequencies.length,
        ),
        errors: nativeResult?.errors ?? const [],
      );
    } catch (error) {
      return DictionaryImportResult(
        success: false,
        title: '',
        termCount: BigInt.zero,
        metaCount: BigInt.zero,
        freqCount: BigInt.zero,
        pitchCount: BigInt.zero,
        mediaCount: BigInt.zero,
        kanjiCount: BigInt.zero,
        errors: [error.toString()],
      );
    }
  }

  Future<void> rebuildQuery({
    required List<String> termPaths,
    List<String> freqPaths = const [],
    List<String> pitchPaths = const [],
    List<String> kanjiPaths = const [],
  }) async {
    await _enqueueQuery(() async {
      final pending = _initializing;
      if (pending != null) await pending;
      _configured = false;
      _configuredProfileKey = null;
      _invalidateQueryCaches();
      await _rebuildQuery(
        termPaths: termPaths,
        freqPaths: freqPaths,
        pitchPaths: pitchPaths,
        kanjiPaths: kanjiPaths,
      );
      // A direct rebuild has always remained active until an explicit reload.
      // Profile-less operations preserve it; an explicitly supplied profile
      // still opts into profile-managed dictionary paths.
      _configuredProfileKey = _directProfileKey;
    });
  }

  Future<void> reloadFromStorage() async {
    await _enqueueQuery(() async {
      _configured = false;
      _configuredProfileKey = null;
      _invalidateQueryCaches();
      await _ensureSession();
    });
  }

  Future<List<HoshiLookupResult>> lookup(
    String text, {
    int maxResults = 10,
    int scanLength = 20,
    String? language,
    DictionaryProfile? profile,
  }) async {
    final query = text.trim();
    if (query.isEmpty || maxResults <= 0 || scanLength <= 0) {
      return const [];
    }

    final preserveDirectConfiguration = profile == null;
    final resolvedProfile =
        profile ?? await MiningPreferences.getActiveDictionaryProfile();
    final lookupLanguage = language ?? resolvedProfile.languageCode;
    final profileKey = _cacheProfileKey(
      _profileKey(resolvedProfile),
      preserveDirectConfiguration,
    );
    final request = _LookupRequest(
      query,
      maxResults,
      scanLength,
      lookupLanguage.toLowerCase(),
      profileKey,
    );
    final cached = _lookupCache.remove(request);
    if (cached != null) {
      _lookupCache[request] = cached;
      return cached;
    }

    final pending = _lookupsInFlight[request];
    if (pending != null) return pending;

    final generation = _queryGeneration;
    final lookup = _performLookup(
      request,
      generation,
      resolvedProfile,
      preserveDirectConfiguration,
    );
    _lookupsInFlight[request] = lookup;
    return lookup;
  }

  Future<List<HoshiLookupResult>> lookupKanji(
    String text, {
    DictionaryProfile? profile,
  }) async {
    final query = text.trim();
    if (query.isEmpty) return const [];
    final preserveDirectConfiguration = profile == null;
    final resolvedProfile =
        profile ?? await MiningPreferences.getActiveDictionaryProfile();
    return _enqueueQuery(() async {
      await _ensureSession(resolvedProfile, preserveDirectConfiguration);
      return List<HoshiLookupResult>.unmodifiable(_kanjiStore.lookup(query));
    });
  }

  Future<List<HoshiDictionaryStyle>> getStyles({
    DictionaryProfile? profile,
  }) async {
    final preserveDirectConfiguration = profile == null;
    final resolvedProfile =
        profile ?? await MiningPreferences.getActiveDictionaryProfile();
    final resolvedProfileKey = _profileKey(resolvedProfile);
    if (!_matchesConfiguredProfile(
      resolvedProfileKey,
      preserveDirectConfiguration,
    )) {
      await _enqueueQuery(
        () => _ensureSession(resolvedProfile, preserveDirectConfiguration),
      );
    }
    final profileKey = _cacheProfileKey(
      resolvedProfileKey,
      preserveDirectConfiguration,
    );
    final cached = _stylesCache[profileKey];
    if (cached != null) return cached;
    final pending = _stylesInFlight[profileKey];
    if (pending != null) return pending;

    final generation = _queryGeneration;
    final styles = _loadStyles(
      generation,
      resolvedProfile,
      profileKey,
      preserveDirectConfiguration,
    );
    _stylesInFlight[profileKey] = styles;
    return styles;
  }

  Future<Uint8List?> getMediaFile({
    required String dictName,
    required String mediaPath,
    DictionaryProfile? profile,
  }) async {
    if (dictName.isEmpty || mediaPath.isEmpty) return null;
    final preserveDirectConfiguration = profile == null;
    return _enqueueQuery(
      () async => hoshidicts.getMediaFile(
        session: await _ensureSession(profile, preserveDirectConfiguration),
        dictName: dictName,
        mediaPath: mediaPath,
      ),
    );
  }

  void clearSession() {
    _session = null;
    _initializing = null;
    _configured = false;
    _configuredProfileKey = null;
    _invalidateQueryCaches();
  }

  void invalidateLookups() => _invalidateQueryCaches();

  Future<hoshidicts.HoshiLookupSession> _ensureSession([
    DictionaryProfile? profile,
    bool preserveDirectConfiguration = false,
  ]) async {
    final resolvedProfile =
        profile ?? await MiningPreferences.getActiveDictionaryProfile();
    final profileKey = _profileKey(resolvedProfile);
    final session = _session;
    if (session != null &&
        _configured &&
        _matchesConfiguredProfile(profileKey, preserveDirectConfiguration)) {
      return session;
    }

    final pending = _initializing;
    if (pending != null) {
      await pending;
      final initialized = _session;
      if (initialized != null &&
          _configured &&
          _matchesConfiguredProfile(profileKey, preserveDirectConfiguration)) {
        return initialized;
      }
    }

    late final Future<hoshidicts.HoshiLookupSession> initialization;
    initialization = _initializeFromStorage(resolvedProfile, profileKey)
        .whenComplete(() {
          if (identical(_initializing, initialization)) {
            _initializing = null;
          }
        });
    _initializing = initialization;
    return initialization;
  }

  Future<hoshidicts.HoshiLookupSession> _initializeFromStorage(
    DictionaryProfile profile,
    String profileKey,
  ) async {
    final paths = await DictionaryStorage.instance.paths(
      order: profile.dictionaryOrder,
      enabled: profile.enabledDictionaries,
    );
    final session = await _rebuildQuery(
      termPaths: paths.termPaths,
      freqPaths: paths.frequencyPaths,
      pitchPaths: paths.pitchPaths,
      kanjiPaths: paths.kanjiPaths,
    );
    _configuredProfileKey = profileKey;
    return session;
  }

  Future<hoshidicts.HoshiLookupSession> _rebuildQuery({
    required List<String> termPaths,
    required List<String> freqPaths,
    required List<String> pitchPaths,
    List<String> kanjiPaths = const [],
  }) async {
    // A failed rebuild can leave the native session half-configured; never
    // let the previous profile key vouch for it afterwards.
    _configured = false;
    final session = _session ??= await hoshidicts.createLookupSession();
    await hoshidicts.rebuildQuery(
      session: session,
      termPaths: termPaths,
      freqPaths: freqPaths,
      pitchPaths: pitchPaths,
    );
    await _kanjiStore.configure(kanjiPaths);
    _configured = true;
    return session;
  }

  Future<List<HoshiLookupResult>> _performLookup(
    _LookupRequest request,
    int generation,
    DictionaryProfile profile,
    bool preserveDirectConfiguration,
  ) async {
    try {
      final rawResults = await _enqueueQuery(() async {
        final session = await _ensureSession(
          profile,
          preserveDirectConfiguration,
        );
        Future<List<HoshiLookupResult>> nativeLookup(
          String text,
          int maxResults,
          int scanLength,
        ) {
          return hoshidicts.lookup(
            session: session,
            text: text,
            maxResults: maxResults,
            scanLength: BigInt.from(scanLength),
          );
        }

        return switch (request.language) {
          'ja' => await nativeLookup(
            request.text,
            request.maxResults,
            request.scanLength,
          ),
          _ => await lookupYomitanDictionary(
            language: request.language,
            text: request.text,
            maxResults: request.maxResults,
            scanLength: request.scanLength,
            lookup: nativeLookup,
            loadCandidates: (language, text, scanLength, maxCandidates) =>
                _yomitanParser.candidates(
                  language,
                  text,
                  scanLength: scanLength,
                  maxCandidates: maxCandidates,
                ),
          ),
        };
      });
      final results = List<HoshiLookupResult>.unmodifiable(rawResults);
      if (generation == _queryGeneration) {
        _lookupCache[request] = results;
        while (_lookupCache.length > _maxCachedLookups) {
          _lookupCache.remove(_lookupCache.keys.first);
        }
      }
      return results;
    } finally {
      if (generation == _queryGeneration) _lookupsInFlight.remove(request);
    }
  }

  Future<List<HoshiDictionaryStyle>> _loadStyles(
    int generation,
    DictionaryProfile profile,
    String profileKey,
    bool preserveDirectConfiguration,
  ) async {
    try {
      final styles = List<HoshiDictionaryStyle>.unmodifiable(
        await _enqueueQuery(
          () async => hoshidicts.getStyles(
            session: await _ensureSession(profile, preserveDirectConfiguration),
          ),
        ),
      );
      if (generation == _queryGeneration) _stylesCache[profileKey] = styles;
      return styles;
    } finally {
      if (generation == _queryGeneration) {
        _stylesInFlight.remove(profileKey);
      }
    }
  }

  void _invalidateQueryCaches() {
    _queryGeneration++;
    _lookupCache.clear();
    _lookupsInFlight.clear();
    _stylesCache.clear();
    _stylesInFlight.clear();
  }

  Future<T> _enqueueQuery<T>(Future<T> Function() operation) {
    final result = _queryQueue.then((_) => operation());
    _queryQueue = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  bool _matchesConfiguredProfile(
    String profileKey,
    bool preserveDirectConfiguration,
  ) =>
      _configuredProfileKey == profileKey ||
      (preserveDirectConfiguration &&
          _configuredProfileKey == _directProfileKey);

  String _cacheProfileKey(
    String profileKey,
    bool preserveDirectConfiguration,
  ) => preserveDirectConfiguration && _configuredProfileKey == _directProfileKey
      ? _directProfileKey
      : profileKey;

  String _profileKey(DictionaryProfile profile) => jsonEncode({
    'id': profile.id,
    'languageCode': profile.languageCode.toLowerCase(),
    'dictionaryOrder': profile.dictionaryOrder,
    'enabledDictionaries': profile.enabledDictionaries.toList()..sort(),
  });
}

class _LookupRequest {
  const _LookupRequest(
    this.text,
    this.maxResults,
    this.scanLength,
    this.language,
    this.profileKey,
  );

  final String text;
  final int maxResults;
  final int scanLength;
  final String language;
  final String profileKey;

  @override
  bool operator ==(Object other) =>
      other is _LookupRequest &&
      other.text == text &&
      other.maxResults == maxResults &&
      other.scanLength == scanLength &&
      other.language == language &&
      other.profileKey == profileKey;

  @override
  int get hashCode =>
      Object.hash(text, maxResults, scanLength, language, profileKey);
}
