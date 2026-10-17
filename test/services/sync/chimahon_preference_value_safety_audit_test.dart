import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupPreference.pb.dart';
import 'package:mangayomi/services/sync/chimahon_preference_safety_policy.dart';
import 'package:mangayomi/services/sync/chimahon_preference_value_safety_audit.dart';

BackupPreference _pref(String key, String value) => BackupPreference(
  key: key,
  value: BackupPreferenceValue(type: 'string', value: utf8.encode(value)),
);

/// [preference] plus a future protobuf field this build does not know.
BackupPreference _withFutureField(BackupPreference preference) =>
    BackupPreference.fromBuffer([
      ...preference.writeToBuffer(),
      0x98, 0x06, 0x01, // field 99, varint 1
    ]);

BackupMihon _backup(List<BackupPreference> preferences) =>
    BackupMihon(backupPreferences: preferences);

void main() {
  const audit = ChimahonPreferenceValueSafetyAudit();
  const remote = ChimahonPreferenceSelectionOrigin.remote;
  const local = ChimahonPreferenceSelectionOrigin.local;
  const deleted = ChimahonPreferenceSelectionOrigin.deleted;

  test('a merge that honours every selection passes', () {
    final failures = audit.audit(
      remote: _backup([_pref('theme', 'dark'), _pref('font', 'serif')]),
      local: _backup([_pref('theme', 'light'), _pref('deck', 'Mining')]),
      proposed: _backup([_pref('theme', 'dark'), _pref('deck', 'Mining')]),
      policy: ChimahonPreferenceSafetyPolicy(
        appSelections: {'theme': remote, 'deck': local, 'font': deleted},
      ),
    );

    expect(failures, isEmpty);
  });

  test('reports each way a merge can lose a selected value', () {
    final failures = audit.audit(
      remote: _backup([_pref('theme', 'dark')]),
      local: _backup([_pref('deck', 'Mining'), _pref('font', 'serif')]),
      proposed: _backup([
        _pref('theme', 'light'),
        _pref('deck', 'Default'),
        _pref('font', 'serif'),
        _pref('stray', 'x'),
      ]),
      policy: ChimahonPreferenceSafetyPolicy(
        appSelections: {'theme': remote, 'deck': local, 'font': deleted},
      ),
    );

    expect(failures, {
      'preference_selection_origin_missing': ['stray'],
      'remote_preference_value_not_preserved': ['theme'],
      'local_preference_value_not_preserved': ['deck'],
      'local_preference_deletion_not_preserved': ['font'],
    });
  });

  test('a remote preference must keep fields from newer Chimahon builds', () {
    final future = _withFutureField(_pref('theme', 'dark'));
    expect(future.unknownFields.isEmpty, isFalse);
    final policy = ChimahonPreferenceSafetyPolicy(
      appSelections: {'theme': remote},
    );

    expect(
      audit.audit(
        remote: _backup([future]),
        local: _backup([]),
        proposed: _backup([future]),
        policy: policy,
      ),
      isEmpty,
    );
    expect(
      audit.audit(
        remote: _backup([future]),
        local: _backup([]),
        proposed: _backup([_pref('theme', 'dark')]),
        policy: policy,
      ),
      {
        'remote_preference_unknown_envelope_not_preserved': ['theme'],
      },
    );
  });
}
