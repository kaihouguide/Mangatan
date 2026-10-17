import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupCategory.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupManga.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/services/sync/chimahon_backup_references.dart';

BackupCategory _category(String name, int order) =>
    BackupCategory(name: name, order: Int64(order));

BackupMihon _backup(List<BackupCategory> categories, List<int> membership) =>
    BackupMihon(
      backupCategories: categories,
      backupManga: [
        BackupManga(
          title: 'A',
          url: '/a',
          categories: membership.map(Int64.new),
        ),
      ],
    );

List<int> _membership(BackupMihon backup) =>
    backup.backupManga.single.categories.map((order) => order.toInt()).toList();

void main() {
  test('re-expresses memberships in the reference category orders', () {
    final local = _backup(
      [_category('Reading', 5), _category('Done', 6)],
      [5, 6],
    );
    final reference = _backup([
      _category('Reading', 1),
      _category('Done', 2),
    ], []);

    final rebased = rebaseChimahonBackupReferences(local, reference);

    expect(_membership(rebased), [1, 2]);
    expect(rebased.backupCategories.map((c) => c.order.toInt()), [1, 2]);
    // Neither input is mutated.
    expect(_membership(local), [5, 6]);
  });

  test('a category missing from the reference cannot merge into another', () {
    // "Local only" keeps order 1, which the reference gives to "Reading".
    final local = _backup(
      [_category('Local only', 1), _category('Reading', 2)],
      [1, 2],
    );
    final reference = _backup([_category('Reading', 1)], [1]);

    final rebased = rebaseChimahonBackupReferences(local, reference);

    // Two memberships must stay two; collapsing them would let a validator
    // accept an upload that dropped the "Local only" membership.
    expect(_membership(rebased), hasLength(2));
    expect(_membership(rebased), isNot(_membership(reference)));
  });
}
