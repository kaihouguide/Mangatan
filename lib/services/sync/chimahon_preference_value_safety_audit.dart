import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupPreference.pb.dart';
import 'package:mangayomi/services/sync/chimahon_preference_safety_policy.dart';
import 'package:protobuf/protobuf.dart';
import 'package:mangayomi/services/sync/sync_bytes.dart';

/// Focused value-level proof for three-way preference selections.
class ChimahonPreferenceValueSafetyAudit {
  const ChimahonPreferenceValueSafetyAudit();

  Map<String, List<String>> audit({
    required BackupMihon remote,
    required BackupMihon local,
    required BackupMihon proposed,
    required ChimahonPreferenceSafetyPolicy policy,
  }) {
    final failures = <String, List<String>>{};
    final remoteApp = _preferencesByKey(remote.backupPreferences);
    final localApp = _preferencesByKey(local.backupPreferences);
    final proposedApp = _preferencesByKey(proposed.backupPreferences);
    _auditCoverage(
      failures: failures,
      inputs: [remoteApp.keys, localApp.keys, proposedApp.keys],
      classified: policy.appSelections.keys.toSet(),
      code: 'preference_selection_origin_missing',
      identityOf: (key) => key,
    );

    for (final entry in policy.appSelections.entries) {
      _auditPreferenceSelection(
        failures: failures,
        identity: entry.key,
        origin: entry.value,
        remote: remoteApp[entry.key],
        local: localApp[entry.key],
        proposed: proposedApp[entry.key],
        remoteValueCode: 'remote_preference_value_not_preserved',
        remoteUnknownCode: 'remote_preference_unknown_envelope_not_preserved',
        remoteDeletionCode: 'remote_preference_deletion_not_preserved',
        localMissingCode: 'local_preference_key_missing_from_proposed',
        localPolicyMissingCode: 'preference_policy_local_key_missing',
        localValueCode: 'local_preference_value_not_preserved',
        localUnknownCode: 'local_preference_unknown_envelope_not_preserved',
        localDeletionCode: 'local_preference_deletion_not_preserved',
      );
    }

    final remoteSource = _sourcePreferencesByKey(remote);
    final localSource = _sourcePreferencesByKey(local);
    final proposedSource = _sourcePreferencesByKey(proposed);
    _auditCoverage(
      failures: failures,
      inputs: [remoteSource.keys, localSource.keys, proposedSource.keys],
      classified: policy.sourceSelections.keys.toSet(),
      code: 'source_preference_selection_origin_missing',
      identityOf: _sourceIdentity,
    );

    for (final entry in policy.sourceSelections.entries) {
      final identity = _sourceIdentity(entry.key);
      _auditPreferenceSelection(
        failures: failures,
        identity: identity,
        origin: entry.value,
        remote: remoteSource[entry.key],
        local: localSource[entry.key],
        proposed: proposedSource[entry.key],
        remoteValueCode: 'remote_source_preference_value_not_preserved',
        remoteUnknownCode:
            'remote_source_preference_unknown_envelope_not_preserved',
        remoteDeletionCode: 'remote_source_preference_deletion_not_preserved',
        localMissingCode: 'local_source_preference_key_missing_from_proposed',
        localPolicyMissingCode: 'source_preference_policy_local_key_missing',
        localValueCode: 'local_source_preference_value_not_preserved',
        localUnknownCode:
            'local_source_preference_unknown_envelope_not_preserved',
        localDeletionCode: 'local_source_preference_deletion_not_preserved',
      );
    }

    _auditSourceGroupEnvelopes(
      failures: failures,
      remote: _sourceGroupsByKey(remote),
      local: _sourceGroupsByKey(local),
      proposed: _sourceGroupsByKey(proposed),
      policy: policy,
    );
    return failures;
  }

  void _auditPreferenceSelection({
    required Map<String, List<String>> failures,
    required String identity,
    required ChimahonPreferenceSelectionOrigin origin,
    required BackupPreference? remote,
    required BackupPreference? local,
    required BackupPreference? proposed,
    required String remoteValueCode,
    required String remoteUnknownCode,
    required String remoteDeletionCode,
    required String localMissingCode,
    required String localPolicyMissingCode,
    required String localValueCode,
    required String localUnknownCode,
    required String localDeletionCode,
  }) {
    switch (origin) {
      case ChimahonPreferenceSelectionOrigin.remote:
        if (remote == null) {
          if (proposed != null) _add(failures, remoteDeletionCode, identity);
          return;
        }
        if (proposed == null) {
          // The multiset key-preservation audit owns this failure and also
          // detects duplicate-key loss.
          return;
        }
        _compareRemote(
          failures: failures,
          identity: identity,
          expected: remote,
          actual: proposed,
          valueCode: remoteValueCode,
          unknownCode: remoteUnknownCode,
        );
        return;
      case ChimahonPreferenceSelectionOrigin.local:
        if (local == null) {
          _add(failures, localPolicyMissingCode, identity);
          return;
        }
        if (proposed == null) {
          _add(failures, localMissingCode, identity);
          return;
        }
        _compareLocal(
          failures: failures,
          identity: identity,
          expected: local,
          actual: proposed,
          valueCode: localValueCode,
          unknownCode: localUnknownCode,
        );
        return;
      case ChimahonPreferenceSelectionOrigin.deleted:
        if (proposed != null) _add(failures, localDeletionCode, identity);
        return;
    }
  }

  void _auditSourceGroupEnvelopes({
    required Map<String, List<String>> failures,
    required Map<String, BackupSourcePreferences> remote,
    required Map<String, BackupSourcePreferences> local,
    required Map<String, BackupSourcePreferences> proposed,
    required ChimahonPreferenceSafetyPolicy policy,
  }) {
    final groupsWithUnknownFields = <String>{
      for (final groups in [remote, local, proposed])
        for (final entry in groups.entries)
          if (entry.value.unknownFields.isNotEmpty) entry.key,
    };
    _auditCoverage(
      failures: failures,
      inputs: [groupsWithUnknownFields],
      classified: policy.sourceGroupEnvelopeSelections.keys.toSet(),
      code: 'source_preference_group_selection_origin_missing',
      identityOf: (key) => key,
    );

    for (final entry in policy.sourceGroupEnvelopeSelections.entries) {
      final expected = switch (entry.value) {
        ChimahonPreferenceSelectionOrigin.remote => remote[entry.key],
        ChimahonPreferenceSelectionOrigin.local => local[entry.key],
        ChimahonPreferenceSelectionOrigin.deleted => null,
      };
      final actual = proposed[entry.key];
      if (entry.value == ChimahonPreferenceSelectionOrigin.deleted) {
        if (actual != null) {
          _add(
            failures,
            'local_source_preference_group_deletion_not_preserved',
            entry.key,
          );
        }
        continue;
      }
      if (expected == null) {
        _add(failures, 'source_preference_group_policy_key_missing', entry.key);
      } else if (actual == null) {
        _add(failures, 'source_preference_group_missing', entry.key);
      } else if (!_unknownFieldsEndWith(actual, expected)) {
        _add(
          failures,
          'source_preference_group_unknown_envelope_not_preserved',
          entry.key,
        );
      }
    }
  }

  void _auditCoverage<K>({
    required Map<String, List<String>> failures,
    required Iterable<Iterable<K>> inputs,
    required Set<K> classified,
    required String code,
    required String Function(K key) identityOf,
  }) {
    final unclassified = <K>{
      for (final keys in inputs)
        for (final key in keys)
          if (!classified.contains(key)) key,
    };
    for (final key in unclassified) {
      _add(failures, code, identityOf(key));
    }
  }

  void _compareRemote({
    required Map<String, List<String>> failures,
    required String identity,
    required BackupPreference expected,
    required BackupPreference actual,
    required String valueCode,
    required String unknownCode,
  }) {
    if (!_sameKnownFields(expected, actual)) {
      _add(failures, valueCode, identity);
    } else if (!sameMessageBytes(expected, actual)) {
      _add(failures, unknownCode, identity);
    }
  }

  void _compareLocal({
    required Map<String, List<String>> failures,
    required String identity,
    required BackupPreference expected,
    required BackupPreference actual,
    required String valueCode,
    required String unknownCode,
  }) {
    if (!_sameKnownFields(expected, actual)) {
      _add(failures, valueCode, identity);
    } else if (!_unknownFieldsEndWith(actual, expected) ||
        (expected.hasValue() &&
            !_unknownFieldsEndWith(actual.value, expected.value))) {
      _add(failures, unknownCode, identity);
    }
  }

  Map<String, BackupPreference> _preferencesByKey(
    Iterable<BackupPreference> values,
  ) => {for (final value in values) value.key: value};

  Map<ChimahonSourcePreferenceKey, BackupPreference> _sourcePreferencesByKey(
    BackupMihon backup,
  ) => {
    for (final group in backup.backupSourcePreferences)
      for (final preference in group.prefs)
        (sourceKey: group.sourceKey, preferenceKey: preference.key): preference,
  };

  Map<String, BackupSourcePreferences> _sourceGroupsByKey(
    BackupMihon backup,
  ) => {
    for (final group in backup.backupSourcePreferences) group.sourceKey: group,
  };

  String _sourceIdentity(ChimahonSourcePreferenceKey key) =>
      '${key.sourceKey}\u0000${key.preferenceKey}';

  bool _sameKnownFields(BackupPreference left, BackupPreference right) {
    final leftKnown = _withoutEnvelopeUnknownFields(left);
    final rightKnown = _withoutEnvelopeUnknownFields(right);
    return sameMessageBytes(leftKnown, rightKnown);
  }

  BackupPreference _withoutEnvelopeUnknownFields(BackupPreference value) {
    final result = value.deepCopy()..unknownFields.clear();
    if (result.hasValue()) result.value.unknownFields.clear();
    return result;
  }

  bool _unknownFieldsEndWith(
    GeneratedMessage actual,
    GeneratedMessage selected,
  ) {
    for (final entry in selected.unknownFields.asMap().entries) {
      final actualField = actual.unknownFields.getField(entry.key);
      if (actualField == null ||
          !_endsWith(actualField.varints, entry.value.varints) ||
          !_endsWith(actualField.fixed32s, entry.value.fixed32s) ||
          !_endsWith(actualField.fixed64s, entry.value.fixed64s) ||
          !_endsWith(actualField.groups, entry.value.groups) ||
          !_byteListsEndWith(
            actualField.lengthDelimited,
            entry.value.lengthDelimited,
          )) {
        return false;
      }
    }
    return true;
  }

  bool _endsWith<T>(List<T> actual, List<T> suffix) {
    if (suffix.length > actual.length) return false;
    final offset = actual.length - suffix.length;
    for (var index = 0; index < suffix.length; index++) {
      if (actual[offset + index] != suffix[index]) return false;
    }
    return true;
  }

  bool _byteListsEndWith(List<List<int>> actual, List<List<int>> suffix) {
    if (suffix.length > actual.length) return false;
    final offset = actual.length - suffix.length;
    for (var index = 0; index < suffix.length; index++) {
      final actualBytes = actual[offset + index];
      final suffixBytes = suffix[index];
      if (actualBytes.length != suffixBytes.length) return false;
      for (var byte = 0; byte < suffixBytes.length; byte++) {
        if (actualBytes[byte] != suffixBytes[byte]) return false;
      }
    }
    return true;
  }

  void _add(Map<String, List<String>> failures, String code, String identity) {
    failures.putIfAbsent(code, () => <String>[]).add(identity);
  }
}
