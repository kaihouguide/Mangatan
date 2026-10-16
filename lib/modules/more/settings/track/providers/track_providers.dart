import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/track.dart';
import 'package:mangayomi/models/track_preference.dart';
import 'package:mangayomi/modules/more/settings/sync/providers/sync_providers.dart';
import 'package:mangayomi/services/sync/chimahon_tracking_adapter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/changed.dart';
import 'package:mangayomi/repositories/settings_repository.dart';
import 'package:mangayomi/repositories/track_repository.dart';
part 'track_providers.g.dart';

@riverpod
class Tracks extends _$Tracks {
  @override
  TrackPreference? build({required int? syncId}) {
    return trackRepository.getPreferenceById(syncId!);
  }

  void setRefreshing(bool refreshing) {
    if (state != null) {
      state!.refreshing = refreshing;
      trackRepository.savePreference(state!);
    }
  }

  void login(TrackPreference trackPreference) {
    trackRepository.savePreference(trackPreference);
  }

  void logout() {
    trackRepository.deletePreference(syncId!);
  }

  void updateTrackManga(Track track, ItemType itemType) {
    final tra = trackRepository.getBySyncIdAndMangaId(syncId, track.mangaId);
    if (tra.isNotEmpty) {
      if (tra.first.mediaId != track.mangaId) {
        track.id = tra.first.id;
      }
    }

    trackRepository.save(
      track
        ..syncId = syncId
        ..itemType = itemType,
    );
  }

  void deleteTrackManga(Track track) {
    final deletedAt = DateTime.now().millisecondsSinceEpoch;
    final deletionMarker = ChimahonTrackingDeletionMarker(
      mangaId: track.mangaId,
      syncId: track.syncId,
      modifiedAt: deletedAt,
    );
    isar.writeTxnSync(() {
      isar.tracks.deleteSync(track.id!);
      ref
          .read(synchingProvider(syncId: 1).notifier)
          .addChangedPart(
            ActionType.removeTrack,
            track.id,
            deletionMarker.toJson(),
            false,
          );
    });
  }
}

@riverpod
class UpdateProgressAfterReadingState
    extends _$UpdateProgressAfterReadingState {
  @override
  bool build() {
    return settingsRepository.current.updateProgressAfterReading ?? true;
  }

  void set(bool value) {
    state = value;
    settingsRepository.update((s) => s.updateProgressAfterReading = value);
  }
}
