import 'package:fixnum/fixnum.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupChapter.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupEpisode.pb.dart';
import 'package:mangayomi/services/sync/chimahon_unknown_field_safety.dart';
import 'package:protobuf/protobuf.dart';
import 'package:mangayomi/services/sync/sync_bytes.dart';

/// Proofs for the deliberately lossy Mangatan chapter and episode projection.
///
/// Mangatan does not represent Chimahon's fetch/order fields or protobuf field
/// presence, and a source refresh can advance a child record's modification
/// clock without changing any portable value. These predicates keep that
/// narrow equivalence rule shared by the merger and its pre-upload audit.
abstract final class ChimahonMediaChildProjectionProof {
  /// Rebases only the legacy identity fields that Mangatan historically
  /// projected from a chapter name. This is safe solely for one remote row
  /// with the same URL and either an exact imported clock or proof that the
  /// local number is the old name parser's output.
  static BackupChapter rebaseLocalChapterIdentity({
    required BackupChapter localProjection,
    required BackupChapter remote,
  }) {
    if (localProjection.version != Int64.ZERO ||
        localProjection.url.isEmpty ||
        localProjection.url != remote.url ||
        _chapterIdentityEqual(localProjection, remote)) {
      return localProjection;
    }
    final hasExactProjectionClock =
        localProjection.hasLastModifiedAt() &&
        remote.hasLastModifiedAt() &&
        localProjection.lastModifiedAt == remote.lastModifiedAt;
    final hasLegacyParsedNumber =
        localProjection.name == remote.name &&
        localProjection.hasChapterNumber() &&
        remote.hasChapterNumber() &&
        localProjection.chapterNumber ==
            _legacyParsedNumber(localProjection.name) &&
        localProjection.chapterNumber != remote.chapterNumber;
    if (!hasExactProjectionClock && !hasLegacyParsedNumber) {
      return localProjection;
    }

    final rebased = localProjection.deepCopy();
    if (remote.hasName()) {
      rebased.name = remote.name;
    } else {
      rebased.clearName();
    }
    if (remote.hasChapterNumber()) {
      rebased.chapterNumber = remote.chapterNumber;
    } else {
      rebased.clearChapterNumber();
    }
    return rebased;
  }

  /// Episode counterpart to [rebaseLocalChapterIdentity].
  static BackupEpisode rebaseLocalEpisodeIdentity({
    required BackupEpisode localProjection,
    required BackupEpisode remote,
  }) {
    if (localProjection.version != Int64.ZERO ||
        localProjection.url.isEmpty ||
        localProjection.url != remote.url ||
        _episodeIdentityEqual(localProjection, remote)) {
      return localProjection;
    }
    final hasExactProjectionClock =
        localProjection.hasLastModifiedAt() &&
        remote.hasLastModifiedAt() &&
        localProjection.lastModifiedAt == remote.lastModifiedAt;
    final hasLegacyParsedNumber =
        localProjection.name == remote.name &&
        localProjection.hasEpisodeNumber() &&
        remote.hasEpisodeNumber() &&
        localProjection.episodeNumber ==
            _legacyParsedNumber(localProjection.name) &&
        localProjection.episodeNumber != remote.episodeNumber;
    if (!hasExactProjectionClock && !hasLegacyParsedNumber) {
      return localProjection;
    }

    final rebased = localProjection.deepCopy();
    if (remote.hasName()) {
      rebased.name = remote.name;
    } else {
      rebased.clearName();
    }
    if (remote.hasEpisodeNumber()) {
      rebased.episodeNumber = remote.episodeNumber;
    } else {
      rebased.clearEpisodeNumber();
    }
    return rebased;
  }

  static bool chapterPortableValuesEqual(
    BackupChapter local,
    BackupChapter remote,
  ) =>
      local.url == remote.url &&
      local.name == remote.name &&
      local.scanlator == remote.scanlator &&
      local.read == remote.read &&
      local.bookmark == remote.bookmark &&
      _sentinelProgressEqual(local.lastPageRead, remote.lastPageRead) &&
      local.dateUpload == remote.dateUpload &&
      local.chapterNumber == remote.chapterNumber;

  static bool episodePortableValuesEqual(
    BackupEpisode local,
    BackupEpisode remote,
  ) =>
      local.url == remote.url &&
      local.name == remote.name &&
      local.scanlator == remote.scanlator &&
      local.seen == remote.seen &&
      local.bookmark == remote.bookmark &&
      _sentinelProgressEqual(local.lastSecondSeen, remote.lastSecondSeen) &&
      local.dateUpload == remote.dateUpload &&
      local.episodeNumber == remote.episodeNumber &&
      (local.totalSeconds == Int64.ZERO ||
          local.totalSeconds == remote.totalSeconds) &&
      local.fillermark == remote.fillermark &&
      local.summary == remote.summary &&
      local.previewUrl == remote.previewUrl;

  static bool exactRemoteChapterWinsClockOnlyLocalProjection({
    required BackupChapter localProjection,
    required BackupChapter remote,
    required BackupChapter proposed,
  }) => _exactRemoteWinsClockOnlyLocalProjection(
    localProjection: localProjection,
    remote: remote,
    proposed: proposed,
    localVersion: localProjection.version,
    localModifiedAt: localProjection.lastModifiedAt,
    proposedModifiedAt: proposed.lastModifiedAt,
    portableValuesAreEqual: chapterPortableValuesEqual(localProjection, remote),
  );

  static bool exactRemoteEpisodeWinsClockOnlyLocalProjection({
    required BackupEpisode localProjection,
    required BackupEpisode remote,
    required BackupEpisode proposed,
  }) => _exactRemoteWinsClockOnlyLocalProjection(
    localProjection: localProjection,
    remote: remote,
    proposed: proposed,
    localVersion: localProjection.version,
    localModifiedAt: localProjection.lastModifiedAt,
    proposedModifiedAt: proposed.lastModifiedAt,
    portableValuesAreEqual: episodePortableValuesEqual(localProjection, remote),
  );

  /// Whether an apparent local clock regression is exactly the merger's
  /// clock-only projection case.
  ///
  /// The proposed row must be the exact remote wire message, all portable
  /// local values must agree with it, and any local unknown fields must still
  /// be present. Consequently this cannot excuse losing reading progress,
  /// bookmarks, source metadata, or opaque future-client state.
  static bool
  _exactRemoteWinsClockOnlyLocalProjection<T extends GeneratedMessage>({
    required T localProjection,
    required T remote,
    required T proposed,
    required Int64 localVersion,
    required Int64 localModifiedAt,
    required Int64 proposedModifiedAt,
    required bool portableValuesAreEqual,
  }) {
    if (localVersion != Int64.ZERO ||
        localModifiedAt <= proposedModifiedAt ||
        !portableValuesAreEqual ||
        !sameBytes(remote.writeToBuffer(), proposed.writeToBuffer())) {
      return false;
    }
    return ChimahonUnknownFieldSafety.missingOrReorderedTags(
      baseline: localProjection,
      target: proposed,
    ).isEmpty;
  }

  /// Mangatan historically stores `1` as its no-resume sentinel, while
  /// Chimahon uses `0`. Treat those two wire projections as equivalent so a
  /// clock-only local refresh retains the exact remote value. Any meaningful
  /// progress above the first page/millisecond remains a real conflict.
  static bool _sentinelProgressEqual(Int64 left, Int64 right) =>
      left == right || (left <= Int64.ONE && right <= Int64.ONE);

  static bool _chapterIdentityEqual(BackupChapter left, BackupChapter right) =>
      left.url == right.url &&
      left.name == right.name &&
      left.chapterNumber == right.chapterNumber;

  static bool _episodeIdentityEqual(BackupEpisode left, BackupEpisode right) =>
      left.url == right.url &&
      left.name == right.name &&
      left.episodeNumber == right.episodeNumber;

  static double _legacyParsedNumber(String name) {
    final matches = RegExp(r'\d+(?:\.\d+)?').allMatches(name).toList();
    return matches.isEmpty
        ? 0
        : double.tryParse(matches.last.group(0) ?? '') ?? 0;
  }
}
