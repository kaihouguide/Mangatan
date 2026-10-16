import 'package:mangayomi/models/category.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupCategory.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupNovel.pb.dart';
import 'package:mangayomi/services/sync/chimahon_novel_category_adapter.dart';

/// Reconciles Chimahon backup categories with categories needed by retained
/// local-archive titles during an explicit, destructive restore.
///
/// Category IDs are local database identities and cannot be taken from the
/// protobuf. A same-name/category-type local row therefore supplies the stable
/// ID and Mangatan-only flags, while the backup supplies its portable name and
/// order. Categories that are neither in the backup nor referenced by a
/// retained local title are intentionally left out of the restore plan.
class ChimahonManualRestoreCategoryAdapter {
  const ChimahonManualRestoreCategoryAdapter();

  ChimahonManualRestoreCategoryPlan build({
    required Iterable<Category> localCategories,
    required Set<int> retainedLocalCategoryIds,
    required Iterable<BackupCategory> mangaCategories,
    required Iterable<BackupCategory> animeCategories,
    required Iterable<BackupNovelCategory> novelCategories,
  }) {
    final records = <String, ChimahonManualRestoreCategoryRecord>{};

    void addBackupCategory({
      required ItemType itemType,
      required String name,
      required int order,
      required bool hidden,
      String? novelBackupId,
    }) {
      final key = _key(itemType, name);
      final existing = records[key];
      if (existing != null) {
        existing.backupOrders.add(order);
        if (novelBackupId != null) {
          existing.novelBackupIds.add(novelBackupId);
        }
        existing.category.hide = hidden;
        return;
      }
      records[key] = ChimahonManualRestoreCategoryRecord(
        category: Category(
          name: name,
          forItemType: itemType,
          pos: order,
          hide: hidden,
        ),
        backupOrders: {order},
        novelBackupIds: {?novelBackupId},
      );
    }

    for (final category in mangaCategories) {
      addBackupCategory(
        itemType: ItemType.manga,
        name: category.name,
        order: category.order.toInt(),
        hidden: category.hidden,
      );
    }
    for (final category in animeCategories) {
      addBackupCategory(
        itemType: ItemType.anime,
        name: category.name,
        order: category.order.toInt(),
        hidden: category.hidden,
      );
    }
    for (final category in novelCategories) {
      // Chimahon 2.4 exports its uncategorized system row as ID `0` with a
      // blank name; neither form is a user category.
      if (category.id == ChimahonNovelCategoryAdapter.uncategorizedId ||
          category.name.trim().isEmpty) {
        continue;
      }
      addBackupCategory(
        itemType: ItemType.novel,
        name: category.name,
        order: category.order.toInt(),
        hidden: false,
        novelBackupId: category.id,
      );
    }

    for (final local in localCategories) {
      final localId = local.id;
      if (localId == null) continue;
      final key = _key(local.forItemType, local.name);
      final existing = records[key];
      if (existing == null) {
        if (!retainedLocalCategoryIds.contains(localId)) continue;
        records[key] = ChimahonManualRestoreCategoryRecord(
          category: _copyLocal(local),
          localIds: {localId},
          novelBackupIds: _stableLocalNovelCategoryIds(local),
        );
        continue;
      }

      existing.localIds.add(localId);
      existing.novelBackupIds.addAll(_stableLocalNovelCategoryIds(local));
      if (existing.localIds.length == 1) {
        final backupName = existing.category.name;
        final backupOrder = existing.category.pos;
        final backupHidden = existing.category.hide;
        existing.category = _copyLocal(local)
          ..name = backupName
          ..pos = backupOrder
          ..hide = backupHidden;
      }
    }

    return ChimahonManualRestoreCategoryPlan(records.values.toList());
  }

  Category _copyLocal(Category category) => Category(
    id: category.id,
    name: category.name,
    forItemType: category.forItemType,
    pos: category.pos,
    hide: category.hide,
    shouldUpdate: category.shouldUpdate,
    updatedAt: category.updatedAt,
  )..forManga = category.forManga;

  Set<String> _stableLocalNovelCategoryIds(Category category) {
    const adapter = ChimahonNovelCategoryAdapter();
    if (category.forItemType != ItemType.novel ||
        adapter.normalizeName(category.name).isEmpty) {
      return const {};
    }
    return {adapter.stableId(category.name)};
  }

  String _key(ItemType itemType, String? name) =>
      '${itemType.index}|${(name ?? '').trim().toLowerCase()}';
}

class ChimahonManualRestoreCategoryPlan {
  ChimahonManualRestoreCategoryPlan(this.records);

  final List<ChimahonManualRestoreCategoryRecord> records;

  /// Insert stable local-ID rows first so auto-incremented backup-only rows
  /// cannot claim an ID still referenced by a retained title.
  Iterable<Category> get categoriesForInsertion sync* {
    for (final record in records.where(
      (record) => record.localIds.isNotEmpty,
    )) {
      yield record.category;
    }
    for (final record in records.where((record) => record.localIds.isEmpty)) {
      yield record.category;
    }
  }

  List<int> remapLocalIds(Iterable<int>? oldIds) {
    final requested = oldIds?.toSet() ?? const <int>{};
    return records
        .where((record) => record.localIds.any(requested.contains))
        .map((record) => record.category.id)
        .nonNulls
        .toSet()
        .toList();
  }

  List<int> idsForBackupOrders(ItemType itemType, Iterable<int> orders) {
    final requested = orders.toSet();
    return records
        .where(
          (record) =>
              record.category.forItemType == itemType &&
              record.backupOrders.any(requested.contains),
        )
        .map((record) => record.category.id)
        .nonNulls
        .toSet()
        .toList();
  }

  List<int> idsForNovelBackupIds(Iterable<String> ids) {
    final requested = ids
        .where((id) => id != ChimahonNovelCategoryAdapter.uncategorizedId)
        .toSet();
    return records
        .where(
          (record) =>
              record.category.forItemType == ItemType.novel &&
              record.novelBackupIds.any(requested.contains),
        )
        .map((record) => record.category.id)
        .nonNulls
        .toSet()
        .toList();
  }

  /// Rebuilds a retained title with both sides of its category membership.
  /// Backup categories remain portable, while categories attached to a local
  /// archive or manual-chapter overlay remain device-local state.
  List<int> idsForRetainedTitle({
    required Iterable<int>? localIds,
    required ItemType itemType,
    required Iterable<int> backupOrders,
  }) => {
    ...remapLocalIds(localIds),
    ...idsForBackupOrders(itemType, backupOrders),
  }.toList();

  /// Rebuilds a retained novel parent with the union of its local memberships
  /// and every matched Chimahon EPUB's string category memberships.
  List<int> idsForRetainedNovelTitle({
    required Iterable<int>? localIds,
    required Iterable<String> backupIds,
  }) =>
      {...remapLocalIds(localIds), ...idsForNovelBackupIds(backupIds)}.toList();
}

class ChimahonManualRestoreCategoryRecord {
  ChimahonManualRestoreCategoryRecord({
    required this.category,
    Set<int>? localIds,
    Set<int>? backupOrders,
    Set<String>? novelBackupIds,
  }) : localIds = localIds ?? <int>{},
       backupOrders = backupOrders ?? <int>{},
       novelBackupIds = novelBackupIds ?? <String>{};

  Category category;
  final Set<int> localIds;
  final Set<int> backupOrders;
  final Set<String> novelBackupIds;
}
