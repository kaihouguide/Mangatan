import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupPreference.pb.dart';
import 'package:mangayomi/services/sync/sync_bytes.dart';

/// Reconstructs preference intent after an explicit manual restore.
///
/// [pending] is the exact selected wire payload, [projectedBaseline] is what
/// Mangatan exported immediately after importing it, and [current] is the
/// projection at upload time. An unchanged projection keeps the exact pending
/// message (including unsupported values and future fields); a real change
/// made after restore wins while retaining the pending unknown envelope.
class ChimahonPendingPreferenceIntent {
  const ChimahonPendingPreferenceIntent();

  List<BackupPreference> mergeApp({
    required Iterable<BackupPreference> pending,
    Iterable<BackupPreference>? projectedBaseline,
    required Iterable<BackupPreference> current,
  }) => _mergePreferences(
    pending: pending,
    projectedBaseline: projectedBaseline,
    current: current,
    preservePendingWhenCurrentMissing: false,
  );

  List<BackupPreference> _mergePreferences({
    required Iterable<BackupPreference> pending,
    required Iterable<BackupPreference>? projectedBaseline,
    required Iterable<BackupPreference> current,
    required bool preservePendingWhenCurrentMissing,
  }) {
    final pendingByKey = _preferencesByKey(pending);
    final baselineByKey = projectedBaseline == null
        ? null
        : _preferencesByKey(projectedBaseline);
    final currentByKey = _preferencesByKey(current);
    final keys = {...pendingByKey.keys, ...currentByKey.keys}.toList()..sort();
    return [
      for (final key in keys)
        ?_select(
          pending: pendingByKey[key],
          baseline: baselineByKey?[key],
          current: currentByKey[key],
          baselineAvailable: baselineByKey != null,
          preservePendingWhenCurrentMissing: preservePendingWhenCurrentMissing,
        ),
    ];
  }

  List<BackupSourcePreferences> mergeSource({
    required Iterable<BackupSourcePreferences> pending,
    Iterable<BackupSourcePreferences>? projectedBaseline,
    required Iterable<BackupSourcePreferences> current,
  }) {
    final pendingBySource = _groupsBySource(pending);
    final baselineBySource = projectedBaseline == null
        ? null
        : _groupsBySource(projectedBaseline);
    final currentBySource = _groupsBySource(current);
    final sourceKeys = {
      ...pendingBySource.keys,
      ...currentBySource.keys,
    }.toList()..sort();
    final result = <BackupSourcePreferences>[];
    for (final sourceKey in sourceKeys) {
      final pendingGroup = pendingBySource[sourceKey];
      final currentGroup = currentBySource[sourceKey];
      if (pendingGroup == null) {
        if (currentGroup != null) result.add(_wireClone(currentGroup));
        continue;
      }

      final preferences = _mergePreferences(
        pending: pendingGroup.prefs,
        projectedBaseline: baselineBySource == null
            ? null
            : baselineBySource[sourceKey]?.prefs ?? const [],
        current: currentGroup?.prefs ?? const [],
        // Source preference definitions disappear when an extension is
        // uninstalled or changes schema. This projection gap is not a user
        // deletion and cannot erase the selected restore payload.
        preservePendingWhenCurrentMissing: true,
      );
      final merged = BackupSourcePreferences(
        sourceKey: sourceKey,
        prefs: preferences,
      )..mergeUnknownFields(pendingGroup.unknownFields);
      if (currentGroup != null) {
        merged.mergeUnknownFields(currentGroup.unknownFields);
      }
      if (preferences.isNotEmpty || merged.unknownFields.isNotEmpty) {
        result.add(_wireClone(merged));
      }
    }
    return result;
  }

  BackupPreference? _select({
    required BackupPreference? pending,
    required BackupPreference? baseline,
    required BackupPreference? current,
    required bool baselineAvailable,
    required bool preservePendingWhenCurrentMissing,
  }) {
    if (pending == null) return current == null ? null : _wireClone(current);

    // Missing collection evidence (older pending stores) and missing per-key
    // evidence (an unsupported value which never projected) are both
    // ambiguous. Preserve the exact selected value instead of mistaking a
    // constructor default or newly supported value for a user edit.
    if (!baselineAvailable || baseline == null) return _wireClone(pending);

    if (current == null && preservePendingWhenCurrentMissing) {
      return _wireClone(pending);
    }

    final currentChanged = !_sameNullableMessage(current, baseline);
    if (!currentChanged) return _wireClone(pending);
    if (current == null) return null;
    return _selectedOverPending(current, pending);
  }

  BackupPreference _selectedOverPending(
    BackupPreference selected,
    BackupPreference pending,
  ) {
    final result = selected.deepCopy()..unknownFields.clear();
    result
      ..mergeUnknownFields(pending.unknownFields)
      ..mergeUnknownFields(selected.unknownFields);
    if (selected.hasValue() && pending.hasValue()) {
      final value = selected.value.deepCopy()..unknownFields.clear();
      value
        ..mergeUnknownFields(pending.value.unknownFields)
        ..mergeUnknownFields(selected.value.unknownFields);
      result.value = value;
    }
    return _wireClone(result);
  }

  Map<String, BackupPreference> _preferencesByKey(
    Iterable<BackupPreference> values,
  ) => {for (final value in values) value.key: value};

  Map<String, BackupSourcePreferences> _groupsBySource(
    Iterable<BackupSourcePreferences> values,
  ) => {for (final value in values) value.sourceKey: value};

  bool _sameNullableMessage(BackupPreference? first, BackupPreference? second) {
    if (first == null || second == null) return first == second;
    return sameBytes(first.writeToBuffer(), second.writeToBuffer());
  }

  T _wireClone<T extends Object>(T value) {
    if (value is BackupPreference) {
      return BackupPreference.fromBuffer(value.writeToBuffer()) as T;
    }
    if (value is BackupSourcePreferences) {
      return BackupSourcePreferences.fromBuffer(value.writeToBuffer()) as T;
    }
    throw ArgumentError.value(value, 'value', 'Unsupported protobuf type');
  }
}
