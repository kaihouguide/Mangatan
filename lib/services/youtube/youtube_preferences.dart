import 'package:hive/hive.dart';

const youtubePreferredQualities = <String>[
  '2160p',
  '1440p',
  '1080p',
  '720p',
  '480p',
  '360p',
];

class YouTubePreferences {
  static const _boxName = 'youtube_preferences';
  static const _qualityKey = 'preferred_quality';
  static const _autoAddChannelKey = 'auto_add_channels';
  static const _historyKey = 'search_history';

  static bool _storageReady = false;

  /// Called immediately after the app's deferred Hive initialization.
  static void markStorageReady() {
    _storageReady = true;
  }

  static Future<Box<dynamic>?> _box() async {
    if (!_storageReady) return null;
    try {
      if (Hive.isBoxOpen(_boxName)) return Hive.box<dynamic>(_boxName);
      return await Hive.openBox<dynamic>(_boxName);
    } catch (_) {
      return null;
    }
  }

  static Future<String> preferredQuality() async =>
      (await _box())?.get(_qualityKey, defaultValue: '1080p') as String? ??
      '1080p';

  static Future<void> setPreferredQuality(String value) async {
    await (await _box())?.put(_qualityKey, value);
  }

  static Future<bool> autoAddChannels() async =>
      (await _box())?.get(_autoAddChannelKey, defaultValue: false) as bool? ??
      false;

  static Future<void> setAutoAddChannels(bool value) async {
    await (await _box())?.put(_autoAddChannelKey, value);
  }

  static Future<List<String>> searchHistory() async {
    final value = (await _box())?.get(
      _historyKey,
      defaultValue: const <String>[],
    );
    return value is List ? List<String>.from(value) : const [];
  }

  static Future<void> rememberSearch(String query) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return;
    // Before deferred storage is ready there is nowhere to keep the search.
    final box = await _box();
    if (box == null) return;
    final history = List<String>.of(await searchHistory())
      ..removeWhere((entry) => entry.toLowerCase() == normalized.toLowerCase())
      ..insert(0, normalized);
    await box.put(_historyKey, history.take(10).toList());
  }

  static Future<void> clearSearchHistory() async {
    await (await _box())?.delete(_historyKey);
  }
}
