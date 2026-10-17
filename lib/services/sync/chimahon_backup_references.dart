import 'package:fixnum/fixnum.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupCategory.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/services/sync/chimahon_anime_seasons.dart';

/// Re-expresses relationships using the reference's category orders and anime
/// IDs. Neither input is mutated. Database handles are not portable identity.
BackupMihon rebaseChimahonBackupReferences(
  BackupMihon backup,
  BackupMihon reference,
) {
  final result = backup.deepCopy();
  void categories(
    List<BackupCategory> source,
    List<BackupCategory> target,
    Iterable<List<Int64>> memberships,
  ) {
    final targetByName = {
      for (final category in target) category.name: category,
    };
    final targetOrders = {for (final category in target) category.order};
    final usedOrders = {
      ...targetOrders,
      for (final category in source) category.order,
    };
    var placeholder = Int64(-1);
    final remapped = <Int64, Int64>{};
    for (final category in source) {
      final match = targetByName[category.name];
      if (match == null) {
        // A category the reference lacks keeps its own order, which may be a
        // reference category's order. Move it to an unused placeholder so its
        // memberships cannot merge into that category's and look equal.
        if (!targetOrders.contains(category.order)) continue;
        while (usedOrders.contains(placeholder)) {
          placeholder -= 1;
        }
        usedOrders.add(placeholder);
        remapped[category.order] = placeholder;
        category.order = placeholder;
        continue;
      }
      remapped[category.order] = match.order;
      if (match.hasOrder()) {
        category.order = match.order;
      } else {
        category.clearOrder();
      }
    }
    for (final membership in memberships) {
      final values =
          membership.map((order) => remapped[order] ?? order).toSet().toList()
            ..sort();
      membership
        ..clear()
        ..addAll(values);
    }
  }

  categories(
    result.backupCategories,
    reference.backupCategories,
    result.backupManga.map((manga) => manga.categories),
  );
  categories(
    result.backupAnimeCategories,
    reference.backupAnimeCategories,
    result.backupAnime.map((anime) => anime.categories),
  );
  // This is evidence normalization, not an import repair. Keep invalid/opaque
  // handles visible so a validator cannot accidentally hide a changed link.
  final anime = ChimahonSeasonNamespace(
    result.backupAnime,
    reference.backupAnime,
    preserveLocalUnresolvedParents: true,
  ).local;
  result.backupAnime
    ..clear()
    ..addAll(anime);
  return result;
}
