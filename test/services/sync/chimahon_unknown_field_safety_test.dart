import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupManga.pb.dart';
import 'package:mangayomi/services/sync/chimahon_unknown_field_safety.dart';

/// A message whose unknown field 900 holds [varints] in order, plus an
/// optional length-delimited unknown field 901.
BackupManga _message(List<int> varints, {List<int>? bytes}) {
  final message = BackupManga(title: 'A');
  for (final value in varints) {
    message.unknownFields.mergeVarintField(900, Int64(value));
  }
  if (bytes != null) {
    message.unknownFields.mergeLengthDelimitedField(901, bytes);
  }
  return message;
}

List<int> _missing(
  BackupManga baseline,
  BackupManga target, [
  ChimahonUnknownFieldPlacement placement =
      ChimahonUnknownFieldPlacement.anywhere,
]) => ChimahonUnknownFieldSafety.missingOrReorderedTags(
  baseline: baseline,
  target: target,
  placement: placement,
).toList();

void main() {
  test('an identical envelope preserves every tag', () {
    expect(
      _missing(_message([1, 2], bytes: [7]), _message([1, 2], bytes: [7])),
      isEmpty,
    );
  });

  test('a dropped tag is reported', () {
    expect(_missing(_message([1], bytes: [7]), _message([1])), [901]);
  });

  test('changed bytes are reported, not just a missing field', () {
    expect(_missing(_message([], bytes: [7]), _message([], bytes: [8])), [901]);
  });

  test('reordered values are not preserved', () {
    expect(_missing(_message([1, 2]), _message([2, 1])), [900]);
  });

  test('a baseline with no unknown fields is trivially preserved', () {
    expect(_missing(_message([]), _message([1, 2])), isEmpty);
  });

  group('placement', () {
    // A merge keeps the loser's values first and writes the winner last, since
    // protobuf reads the last value of a singular field.
    final merged = _message([1, 2, 3, 4]);

    test('prefix requires the values at the start', () {
      expect(
        _missing(
          _message([1, 2]),
          merged,
          ChimahonUnknownFieldPlacement.prefix,
        ),
        isEmpty,
      );
      expect(
        _missing(
          _message([3, 4]),
          merged,
          ChimahonUnknownFieldPlacement.prefix,
        ),
        [900],
      );
    });

    test('suffix requires the values at the end', () {
      expect(
        _missing(
          _message([3, 4]),
          merged,
          ChimahonUnknownFieldPlacement.suffix,
        ),
        isEmpty,
      );
      expect(
        _missing(
          _message([1, 2]),
          merged,
          ChimahonUnknownFieldPlacement.suffix,
        ),
        [900],
      );
    });

    test('anywhere accepts a contiguous run but not a scattered one', () {
      expect(_missing(_message([2, 3]), merged), isEmpty);
      expect(_missing(_message([1, 3]), merged), [900]);
    });

    test('a baseline longer than the target cannot be contained', () {
      expect(_missing(_message([1, 2, 3, 4, 5]), merged), [900]);
    });
  });
}
