import 'package:protobuf/protobuf.dart';
import 'package:mangayomi/services/sync/sync_bytes.dart';

enum ChimahonUnknownFieldPlacement { prefix, suffix, anywhere }

/// Sequence-aware checks for protobuf unknown-field envelopes.
///
/// Protobuf singular values use the last encoded value. The Chimahon merger
/// therefore deliberately retains a loser's values as a prefix and writes the
/// selected winner last. These checks prove preservation without requiring the
/// whole envelope to be byte-identical.
abstract final class ChimahonUnknownFieldSafety {
  static Iterable<int> missingOrReorderedTags({
    required GeneratedMessage baseline,
    required GeneratedMessage target,
    ChimahonUnknownFieldPlacement placement =
        ChimahonUnknownFieldPlacement.anywhere,
  }) sync* {
    for (final entry in baseline.unknownFields.asMap().entries) {
      final candidate = target.unknownFields.getField(entry.key);
      if (candidate == null ||
          !_fieldContains(candidate, entry.value, placement)) {
        yield entry.key;
      }
    }
  }

  static bool _fieldContains(
    UnknownFieldSetField target,
    UnknownFieldSetField baseline,
    ChimahonUnknownFieldPlacement placement,
  ) =>
      _contains(target.varints, baseline.varints, placement) &&
      _contains(target.fixed32s, baseline.fixed32s, placement) &&
      _contains(target.fixed64s, baseline.fixed64s, placement) &&
      _contains(target.groups, baseline.groups, placement) &&
      _containsBytes(
        target.lengthDelimited,
        baseline.lengthDelimited,
        placement,
      );

  static bool _contains<T>(
    List<T> target,
    List<T> baseline,
    ChimahonUnknownFieldPlacement placement,
  ) => _containsBy(target, baseline, placement, (left, right) => left == right);

  static bool _containsBytes(
    List<List<int>> target,
    List<List<int>> baseline,
    ChimahonUnknownFieldPlacement placement,
  ) => _containsBy(target, baseline, placement, sameBytes);

  static bool _containsBy<T>(
    List<T> target,
    List<T> baseline,
    ChimahonUnknownFieldPlacement placement,
    bool Function(T left, T right) equals,
  ) {
    if (baseline.isEmpty) return true;
    if (baseline.length > target.length) return false;
    final starts = switch (placement) {
      ChimahonUnknownFieldPlacement.prefix => const [0],
      ChimahonUnknownFieldPlacement.suffix => [target.length - baseline.length],
      ChimahonUnknownFieldPlacement.anywhere => List<int>.generate(
        target.length - baseline.length + 1,
        (index) => index,
      ),
    };
    for (final start in starts) {
      var matches = true;
      for (var offset = 0; offset < baseline.length; offset++) {
        if (!equals(target[start + offset], baseline[offset])) {
          matches = false;
          break;
        }
      }
      if (matches) return true;
    }
    return false;
  }
}
