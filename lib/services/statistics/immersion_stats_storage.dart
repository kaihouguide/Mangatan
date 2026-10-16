import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:mangayomi/services/statistics/immersion_stats_models.dart';

/// Persistence for Chimahon-compatible immersion statistics.
///
/// Chimahon keeps three separate stores — `manga_stats.json`, `anki_stats.json`,
/// and a per-book `statistics.json` — so this keeps the same three logical
/// collections. They live in one Hive box because Mangatan has no equivalent of
/// Chimahon's per-book directory, and the book's stable Chimahon ID is a
/// sufficient key.
///
/// Every mutation is serialized through [_lock] so concurrent readers (page
/// turns, the stats screen, a sync export) cannot interleave a read-modify-write
/// and drop a day's reading.
class ImmersionStatsStorage {
  ImmersionStatsStorage._();

  static const boxName = 'immersion_statistics';
  static const _mangaKey = 'manga_stats';
  static const _ankiKey = 'anki_stats';
  static const _novelKeyPrefix = 'novel_stats_';

  /// Bumped whenever anything is written so UI can re-read without polling.
  static final revision = _StatsRevisionNotifier();

  static Future<void> _lock = Future<void>.value();

  /// Serializes [action] against every other mutation.
  static Future<T> _synchronized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _lock = _lock.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  static Future<Box<dynamic>?> _box() async {
    try {
      if (Hive.isBoxOpen(boxName)) return Hive.box<dynamic>(boxName);
      return await Hive.openBox<dynamic>(boxName);
    } catch (_) {
      // A stats read must never take down a reader. Losing the box degrades to
      // "no statistics" rather than an unhandled error mid page turn.
      return null;
    }
  }

  // ---------------------------------------------------------------- manga

  static Future<List<MangaStatsEntry>> loadMangaStats() async {
    final raw = (await _box())?.get(_mangaKey);
    return _decodeList(raw, MangaStatsEntry.fromJson);
  }

  static Future<void> saveMangaStats(List<MangaStatsEntry> stats) =>
      _synchronized(() => _writeMangaStats(stats));

  static Future<void> _writeMangaStats(List<MangaStatsEntry> stats) async {
    final box = await _box();
    if (box == null) return;
    await box.put(_mangaKey, _encodeList(stats));
    revision.bump();
  }

  /// Adds one page's worth of reading to today's row for [mangaId].
  ///
  /// Chimahon drops calls with nothing to record, which also keeps the store
  /// from growing a row per idle page turn.
  static Future<void> addMangaStats({
    required int characters,
    required int timeMs,
    int mangaId = 0,
    DateTime? date,
  }) async {
    if (characters <= 0 && timeMs <= 0) return;
    final dateKey = statsDateKey(date ?? DateTime.now());
    await _synchronized(() async {
      final stats = await loadMangaStats();
      final index = stats.indexWhere(
        (entry) => entry.dateKey == dateKey && entry.mangaId == mangaId,
      );
      if (index >= 0) {
        final existing = stats[index];
        stats[index] = existing.copyWith(
          charactersRead: existing.charactersRead + characters,
          readingTimeMs: existing.readingTimeMs + timeMs,
        );
      } else {
        stats.add(
          MangaStatsEntry(
            dateKey: dateKey,
            charactersRead: characters,
            readingTimeMs: timeMs,
            mangaId: mangaId,
          ),
        );
      }
      await _writeMangaStats(stats);
    });
  }

  /// Merges restored rows using Chimahon's max-per-field rule.
  ///
  /// Daily rows from two devices cannot be summed without double counting a
  /// day that both devices already synced, so the larger value wins per field.
  static Future<void> mergeMangaStats(
    Iterable<MangaStatsEntry> incoming,
  ) async {
    final remote = incoming.toList();
    if (remote.isEmpty) return;
    await _synchronized(() async {
      final local = await loadMangaStats();
      var changed = false;
      for (final entry in remote) {
        final index = local.indexWhere(
          (existing) =>
              existing.dateKey == entry.dateKey &&
              existing.mangaId == entry.mangaId,
        );
        if (index < 0) {
          local.add(entry);
          changed = true;
          continue;
        }
        final existing = local[index];
        if (entry.charactersRead > existing.charactersRead ||
            entry.readingTimeMs > existing.readingTimeMs) {
          local[index] = existing.copyWith(
            charactersRead: entry.charactersRead > existing.charactersRead
                ? entry.charactersRead
                : existing.charactersRead,
            readingTimeMs: entry.readingTimeMs > existing.readingTimeMs
                ? entry.readingTimeMs
                : existing.readingTimeMs,
          );
          changed = true;
        }
      }
      if (changed) await _writeMangaStats(local);
    });
  }

  // ----------------------------------------------------------------- anki

  static Future<List<AnkiStatsEntry>> loadAnkiStats() async {
    final raw = (await _box())?.get(_ankiKey);
    return _decodeList(raw, AnkiStatsEntry.fromJson);
  }

  /// Loads the three collections used by sync from one box snapshot.
  ///
  /// Besides keeping the export internally consistent, this avoids opening
  /// and resolving the same Hive box three times on every synchronization.
  static Future<
    ({
      List<MangaStatsEntry> mangaStats,
      List<AnkiStatsEntry> ankiStats,
      Map<String, List<NovelStatsEntry>> novelStats,
    })
  >
  loadSyncSnapshot() async {
    final box = await _box();
    if (box == null) {
      return (
        mangaStats: const <MangaStatsEntry>[],
        ankiStats: const <AnkiStatsEntry>[],
        novelStats: const <String, List<NovelStatsEntry>>{},
      );
    }
    final novelStats = <String, List<NovelStatsEntry>>{};
    for (final key in box.keys) {
      final name = key.toString();
      if (!name.startsWith(_novelKeyPrefix)) continue;
      final novelId = name.substring(_novelKeyPrefix.length);
      if (novelId.isEmpty) continue;
      final stats = _decodeList(box.get(key), NovelStatsEntry.fromJson);
      if (stats.isNotEmpty) novelStats[novelId] = stats;
    }
    return (
      mangaStats: _decodeList(box.get(_mangaKey), MangaStatsEntry.fromJson),
      ankiStats: _decodeList(box.get(_ankiKey), AnkiStatsEntry.fromJson),
      novelStats: novelStats,
    );
  }

  static Future<void> saveAnkiStats(List<AnkiStatsEntry> stats) =>
      _synchronized(() => _writeAnkiStats(stats));

  static Future<void> _writeAnkiStats(List<AnkiStatsEntry> stats) async {
    final box = await _box();
    if (box == null) return;
    await box.put(_ankiKey, _encodeList(stats));
    revision.bump();
  }

  /// Records one mined card. Anything that is not `manga` counts as a novel
  /// card, matching Chimahon's branch.
  static Future<void> addAnkiCard({
    String? type,
    String profileId = '',
    String? titleId,
    DateTime? date,
  }) async {
    final dateKey = statsDateKey(date ?? DateTime.now());
    final isManga = type == 'manga';
    await _synchronized(() async {
      final stats = await loadAnkiStats();
      final index = stats.indexWhere(
        (entry) =>
            entry.dateKey == dateKey &&
            entry.profileId == profileId &&
            entry.titleId == titleId,
      );
      if (index >= 0) {
        final existing = stats[index];
        stats[index] = existing.copyWith(
          mangaCards: existing.mangaCards + (isManga ? 1 : 0),
          novelCards: existing.novelCards + (isManga ? 0 : 1),
        );
      } else {
        stats.add(
          AnkiStatsEntry(
            dateKey: dateKey,
            mangaCards: isManga ? 1 : 0,
            novelCards: isManga ? 0 : 1,
            profileId: profileId,
            titleId: titleId,
          ),
        );
      }
      await _writeAnkiStats(stats);
    });
  }

  static Future<void> mergeAnkiStats(Iterable<AnkiStatsEntry> incoming) async {
    final remote = incoming.toList();
    if (remote.isEmpty) return;
    await _synchronized(() async {
      final local = await loadAnkiStats();
      var changed = false;
      for (final entry in remote) {
        final index = local.indexWhere(
          (existing) =>
              existing.dateKey == entry.dateKey &&
              existing.profileId == entry.profileId &&
              existing.titleId == entry.titleId,
        );
        if (index < 0) {
          local.add(entry);
          changed = true;
          continue;
        }
        final existing = local[index];
        if (entry.mangaCards > existing.mangaCards ||
            entry.novelCards > existing.novelCards) {
          local[index] = existing.copyWith(
            mangaCards: entry.mangaCards > existing.mangaCards
                ? entry.mangaCards
                : existing.mangaCards,
            novelCards: entry.novelCards > existing.novelCards
                ? entry.novelCards
                : existing.novelCards,
          );
          changed = true;
        }
      }
      if (changed) await _writeAnkiStats(local);
    });
  }

  // ---------------------------------------------------------------- novel

  static String _novelKey(String novelId) => '$_novelKeyPrefix$novelId';

  static Future<List<NovelStatsEntry>> loadNovelStats(String novelId) async {
    if (novelId.isEmpty) return const [];
    final raw = (await _box())?.get(_novelKey(novelId));
    return _decodeList(raw, NovelStatsEntry.fromJson);
  }

  static Future<void> saveNovelStats(
    String novelId,
    List<NovelStatsEntry> stats,
  ) => _synchronized(() => _writeNovelStats(novelId, stats));

  static Future<void> _writeNovelStats(
    String novelId,
    List<NovelStatsEntry> stats,
  ) async {
    if (novelId.isEmpty) return;
    final box = await _box();
    if (box == null) return;
    await box.put(_novelKey(novelId), _encodeList(stats));
    revision.bump();
  }

  /// Returns every book that has stored statistics, keyed by Chimahon ID.
  static Future<Map<String, List<NovelStatsEntry>>> loadAllNovelStats() async {
    final box = await _box();
    if (box == null) return const {};
    final result = <String, List<NovelStatsEntry>>{};
    for (final key in box.keys) {
      final name = key.toString();
      if (!name.startsWith(_novelKeyPrefix)) continue;
      final novelId = name.substring(_novelKeyPrefix.length);
      if (novelId.isEmpty) continue;
      final stats = _decodeList(box.get(key), NovelStatsEntry.fromJson);
      if (stats.isNotEmpty) result[novelId] = stats;
    }
    return result;
  }

  /// Merges one book's restored or synced rows per day and per field.
  ///
  /// Chimahon's database-backed backups write `lastStatisticModified = 0`, and
  /// its restorer only adds the missing delta per day. A timestamp therefore
  /// cannot pick a winner: the counters only grow, so the larger value per
  /// field already contains the other side's reading. This mirrors both
  /// Chimahon's `NovelRestorer` and the sync merger's `mergeNovelStatDay`.
  static Future<void> mergeNovelStats(
    String novelId,
    Iterable<NovelStatsEntry> incoming,
  ) async {
    if (novelId.isEmpty) return;
    final remote = incoming.toList();
    if (remote.isEmpty) return;
    await _synchronized(() async {
      final local = await loadNovelStats(novelId);
      var changed = false;
      for (final entry in remote) {
        final index = local.indexWhere(
          (existing) => existing.dateKey == entry.dateKey,
        );
        if (index < 0) {
          local.add(entry);
          changed = true;
          continue;
        }
        final existing = local[index];
        final merged = mergeNovelStatsDay(existing, entry);
        if (merged != existing) {
          local[index] = merged;
          changed = true;
        }
      }
      if (changed) await _writeNovelStats(novelId, local);
    });
  }

  @visibleForTesting
  static NovelStatsEntry mergeNovelStatsDay(
    NovelStatsEntry local,
    NovelStatsEntry remote,
  ) {
    final newer =
        remote.charactersRead > local.charactersRead ||
            (remote.charactersRead == local.charactersRead &&
                remote.readingTimeSeconds > local.readingTimeSeconds)
        ? remote
        : local;
    int minNonZero(int first, int second) => first <= 0
        ? second
        : second <= 0
        ? first
        : math.min(first, second);
    return local.copyWith(
      charactersRead: math.max(local.charactersRead, remote.charactersRead),
      readingTimeSeconds: math.max(
        local.readingTimeSeconds,
        remote.readingTimeSeconds,
      ),
      minReadingSpeed: minNonZero(
        local.minReadingSpeed,
        remote.minReadingSpeed,
      ),
      altMinReadingSpeed: minNonZero(
        local.altMinReadingSpeed,
        remote.altMinReadingSpeed,
      ),
      lastReadingSpeed: newer.lastReadingSpeed,
      maxReadingSpeed: math.max(local.maxReadingSpeed, remote.maxReadingSpeed),
      lastStatisticModified: math.max(
        local.lastStatisticModified,
        remote.lastStatisticModified,
      ),
    );
  }

  /// Drops a book's statistics when its library entry is removed.
  static Future<void> deleteNovelStats(String novelId) async {
    if (novelId.isEmpty) return;
    await _synchronized(() async {
      final box = await _box();
      if (box == null) return;
      await box.delete(_novelKey(novelId));
      revision.bump();
    });
  }

  /// Clears everything. Used by "reset statistics" and by tests.
  static Future<void> clear() async {
    await _synchronized(() async {
      final box = await _box();
      if (box == null) return;
      await box.clear();
      revision.bump();
    });
  }

  static List<T> _decodeList<T>(
    Object? raw,
    T Function(Map<dynamic, dynamic>) fromJson,
  ) {
    if (raw is! String || raw.isEmpty) return <T>[];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      // A corrupt payload is treated as empty rather than propagating: the
      // next write repairs it, and reading is on the page-turn path.
      return <T>[];
    }
    if (decoded is! List) return <T>[];
    final entries = <T>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      // Skip a malformed row on its own. Failing the whole list would make
      // the next read-modify-write save it back empty and erase the history.
      try {
        entries.add(fromJson(item));
      } catch (_) {}
    }
    return entries;
  }

  static String _encodeList(List<dynamic> stats) =>
      jsonEncode([for (final entry in stats) entry.toJson()]);
}

/// A tiny listenable so widgets can rebuild after a write without importing
/// Flutter into the storage layer's dependencies beyond `ChangeNotifier`.
class _StatsRevisionNotifier {
  int _value = 0;
  final _listeners = <void Function()>[];

  int get value => _value;

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void bump() {
    _value++;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}
