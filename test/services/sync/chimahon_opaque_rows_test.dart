import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupCategory.pb.dart';
import 'package:mangayomi/services/sync/chimahon_opaque_rows.dart';

BackupCategory _row(String name) => BackupCategory(name: name);

List<String> _names(Iterable<BackupCategory> rows) =>
    rows.map((row) => row.name).toList();

void main() {
  group('mergeMaxMultiplicity', () {
    test('keeps each exact row as often as either side has it', () {
      final merged = ChimahonOpaqueRows.mergeMaxMultiplicity(
        [_row('a'), _row('a'), _row('b')],
        [_row('a'), _row('c'), _row('c')],
      );

      expect(_names(merged), ['a', 'a', 'b', 'c', 'c']);
    });

    test('returns copies, so editing the result leaves the inputs alone', () {
      final local = [_row('a')];
      final merged = ChimahonOpaqueRows.mergeMaxMultiplicity(
        local,
        const <BackupCategory>[],
      );
      merged.single.name = 'changed';

      expect(local.single.name, 'a');
    });
  });

  group('missingExactRows', () {
    test('reports each baseline row the target lacks, counting repeats', () {
      final missing = ChimahonOpaqueRows.missingExactRows(
        [_row('a'), _row('a'), _row('b')],
        [_row('a')],
      );

      expect(missing, hasLength(2));
      expect(missing.toSet(), hasLength(2)); // one a and one b
    });

    test('reports digests, never row contents', () {
      final missing = ChimahonOpaqueRows.missingExactRows([
        _row('secret title'),
      ], const <BackupCategory>[]);

      expect(missing.single, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(missing.single, isNot(contains('secret')));
    });

    test('nothing is missing when the target covers the baseline', () {
      expect(
        ChimahonOpaqueRows.missingExactRows(
          [_row('a')],
          [_row('a'), _row('b')],
        ),
        isEmpty,
      );
    });
  });
}
