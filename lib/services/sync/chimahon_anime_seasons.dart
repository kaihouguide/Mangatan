import 'package:mangayomi/models/manga.dart';
import 'package:fixnum/fixnum.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupAnime.pb.dart';
import 'package:mangayomi/services/sync/chimahon_media_identity.dart';

// Kotlin omits default-valued fields. In a season-aware record, an absent
// fetchType means Episodes (1), not the Dart protobuf getter's default of 0.
bool hasChimahonSeasonMetadata(BackupAnime anime) =>
    (anime.hasId() && anime.id > Int64.ZERO) ||
    (anime.hasParentId() && anime.parentId > Int64.ZERO);

int chimahonAnimeFetchType(BackupAnime anime) =>
    anime.hasFetchType() ? anime.fetchType : 1;

/// Resolves only explicit, unique IDs within one backup. Missing IDs in older
/// backups are not zero-valued parents, and a cross-source link is invalid.
Map<BackupAnime, BackupAnime> chimahonSeasonParents(
  Iterable<BackupAnime> entries,
) {
  final all = entries.toList();
  final byId = <Int64, List<BackupAnime>>{};
  for (final anime in all) {
    if (anime.hasId() && anime.id > Int64.ZERO) {
      byId.putIfAbsent(anime.id, () => []).add(anime);
    }
  }
  final parents = <BackupAnime, BackupAnime>{};
  for (final anime in all) {
    if (!anime.hasParentId()) continue;
    final matches = byId[anime.parentId];
    if (matches?.length != 1) continue;
    final parent = matches!.single;
    if (parent == anime ||
        parent.source != anime.source ||
        parent.url == anime.url ||
        chimahonAnimeFetchType(parent) != 0) {
      continue;
    }
    parents[anime] = parent;
  }
  // Reject cycles before either importing or reassigning IDs.
  final cyclic = <BackupAnime>{};
  for (final anime in parents.keys) {
    final seen = <BackupAnime>{anime};
    var parent = parents[anime];
    while (parent != null) {
      if (!seen.add(parent)) {
        cyclic.add(anime);
        break;
      }
      parent = parents[parent];
    }
  }
  parents.removeWhere((anime, _) => cyclic.contains(anime));
  return parents;
}

/// Relationships are resolved within each input before their database IDs can
/// collide. Both sides then use one namespace keyed by Chimahon wire identity.
/// This also handles a remote parent without an ID and duplicate remote IDs.
class ChimahonSeasonNamespace {
  ChimahonSeasonNamespace(
    Iterable<BackupAnime> local,
    Iterable<BackupAnime> remote, {
    bool preserveLocalUnresolvedParents = false,
  }) {
    final left = local.toList();
    final right = remote.toList();
    // Reserve even unresolved remote handles so a newly introduced local row
    // cannot accidentally become the parent of an opaque remote relationship.
    final reserved = <Int64>{
      for (final anime in right) ...[
        if (anime.hasId()) anime.id,
        if (anime.hasParentId()) anime.parentId,
      ],
    };
    final remoteIdCounts = <Int64, int>{};
    for (final anime in right.where((anime) => anime.hasId())) {
      remoteIdCounts.update(anime.id, (count) => count + 1, ifAbsent: () => 1);
    }
    final used = <Int64>{};
    var next = Int64.ONE;
    for (final entry in [
      ...right.map((anime) => (anime: anime, isRemote: true)),
      ...left.map((anime) => (anime: anime, isRemote: false)),
    ]) {
      final anime = entry.anime;
      if (!anime.hasId() || anime.id <= Int64.ZERO) continue;
      final key = chimahonAnimeIdentity(anime);
      if (_ids.containsKey(key)) continue;
      if ((entry.isRemote
              ? remoteIdCounts[anime.id] == 1
              : !reserved.contains(anime.id)) &&
          used.add(anime.id)) {
        _ids[key] = anime.id;
      } else {
        while (used.contains(next) || reserved.contains(next)) {
          next += Int64.ONE;
        }
        _ids[key] = next;
        used.add(next);
        next += Int64.ONE;
      }
    }
    this.local = _rebase(
      left,
      keepUnresolvedParents: preserveLocalUnresolvedParents,
    );
    this.remote = _rebase(right, keepUnresolvedParents: true);
  }

  final _ids = <String, Int64>{};
  late final List<BackupAnime> local;
  late final List<BackupAnime> remote;

  void assignId(BackupAnime anime) {
    if (_ids[chimahonAnimeIdentity(anime)] case final id?) anime.id = id;
  }

  List<BackupAnime> _rebase(
    List<BackupAnime> entries, {
    bool keepUnresolvedParents = false,
  }) {
    final parents = chimahonSeasonParents(entries);
    return entries.map((anime) {
      final result = anime.deepCopy();
      // Do not make an older client appear season-aware before winner and
      // projection-gap handling. assignId is also called on the final winner.
      if (anime.hasId()) assignId(result);
      if (anime.hasParentId()) {
        final parent = parents[anime];
        final parentId = parent == null
            ? null
            : _ids[chimahonAnimeIdentity(parent)];
        if (parentId == null && !keepUnresolvedParents) {
          result.clearParentId();
        } else if (parentId != null) {
          result.parentId = parentId;
        }
      }
      return result;
    }).toList();
  }
}

/// A source refresh knows the fetch type but may not supply display flags or
/// background art. An older client knows none of these fields. Fill only these
/// representation gaps; a known parent's absent parentId is an explicit detach.
void retainAnimeSeasonProjectionGaps(
  BackupAnime selected,
  BackupAnime local,
  BackupAnime remote,
) {
  if (!hasChimahonSeasonMetadata(local)) return;
  if (!hasChimahonSeasonMetadata(remote)) {
    for (final tag in [500, 502, 503, 504, 505, 506, 507]) {
      selected.clearField(tag);
      if (local.hasField(tag)) selected.setField(tag, local.getField(tag));
    }
  }
  // Fields absent in a season-aware winner are Kotlin defaults (including an
  // explicit reset to zero/null). Only legacy representations have gaps.
  if (!hasChimahonSeasonMetadata(remote)) {
    for (final tag in [500, 504, 505, 506]) {
      if (!selected.hasField(tag) && remote.hasField(tag)) {
        selected.setField(tag, remote.getField(tag));
      }
    }
  }
}

bool animeSeasonProjectionEquals(BackupAnime local, BackupAnime remote) =>
    !hasChimahonSeasonMetadata(local) ||
    (hasChimahonSeasonMetadata(remote) &&
        local.backgroundUrl == remote.backgroundUrl &&
        local.seasonFlags == remote.seasonFlags &&
        (local.hasSeasonNumber() ? local.seasonNumber : -1) ==
            (remote.hasSeasonNumber() ? remote.seasonNumber : -1) &&
        local.seasonSourceOrder == remote.seasonSourceOrder &&
        chimahonAnimeFetchType(local) == chimahonAnimeFetchType(remote) &&
        local.hasParentId() == remote.hasParentId() &&
        local.parentId == remote.parentId);

/// Shared by manual restore and incremental sync. Field presence distinguishes
/// older clients from an explicit update or detach by a season-aware client.
void applyChimahonAnimeSeasons(
  Manga local,
  BackupAnime remote,
  BackupAnime? parent,
) {
  if (hasChimahonSeasonMetadata(remote)) {
    local.animeFetchType = chimahonAnimeFetchType(remote);
    local.seasonNumber = remote.hasSeasonNumber() ? remote.seasonNumber : -1;
    local.seasonSourceOrder = remote.seasonSourceOrder.toInt();
    local.seasonFlags = remote.seasonFlags.toInt();
    local.backgroundUrl = remote.hasBackgroundUrl()
        ? remote.backgroundUrl
        : null;
    local.animeParentUrl = parent?.url;
    return;
  }
  if (remote.hasFetchType()) local.animeFetchType = remote.fetchType;
  if (remote.hasSeasonNumber()) local.seasonNumber = remote.seasonNumber;
  if (remote.hasSeasonSourceOrder()) {
    local.seasonSourceOrder = remote.seasonSourceOrder.toInt();
  }
  if (remote.hasSeasonFlags()) local.seasonFlags = remote.seasonFlags.toInt();
  if (remote.hasBackgroundUrl()) local.backgroundUrl = remote.backgroundUrl;
}
