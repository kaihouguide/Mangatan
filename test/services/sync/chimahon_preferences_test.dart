import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupPreference.pb.dart';
import 'package:mangayomi/services/sync/chimahon_preferences.dart';

void main() {
  const codec = ChimahonPreferenceCodec();

  test('preserves exact primitive preference values', () {
    final values = <String, Object>{
      'integer': 42,
      'floating': 1.25,
      'string': 'filled field',
      'boolean': true,
      'set': <String>{'one', 'two'},
    };

    for (final entry in values.entries) {
      final decoded = codec.decode(codec.encode(entry.key, entry.value));
      expect(decoded.value, entry.value);
    }
  });

  test('keeps a damaged preference value as an opaque envelope', () {
    final damaged = BackupPreference(
      key: 'library_entries',
      value: BackupPreferenceValue(
        type: 'eu.kanade.tachiyomi.data.backup.models.BooleanPreferenceValue',
        // A field tag with a truncated length-delimited payload.
        value: [10, 200],
      ),
    );

    final decoded = codec.decode(damaged);

    expect(decoded.kind, ChimahonPreferenceKind.unknown);
    expect(decoded.value, isNull);
    expect(decoded.encoded.writeToBuffer(), damaged.writeToBuffer());
  });

  test('decodes a fixture emitted by Chimahon kotlinx serialization', () {
    const fixture =
        'wgZXCgtwcmVmX3N0cmluZxJICjxldS5rYW5hZGUudGFjaGl5b21pLmRhdGEuYmFja3VwLm1vZGVscy5TdHJpbmdQcmVmZXJlbmNlVmFsdWUSCAoGZmlsbGVkwgZLCghwcmVmX2ludBI/CjlldS5rYW5hZGUudGFjaGl5b21pLmRhdGEuYmFja3VwLm1vZGVscy5JbnRQcmVmZXJlbmNlVmFsdWUSAggqwgZQCglwcmVmX2Jvb2wSQwo9ZXUua2FuYWRlLnRhY2hpeW9taS5kYXRhLmJhY2t1cC5tb2RlbHMuQm9vbGVhblByZWZlcmVuY2VWYWx1ZRICCAE=';
    final backup = BackupMihon.fromBuffer(base64Decode(fixture));
    final values = {
      for (final preference in backup.backupPreferences)
        preference.key: codec.decode(preference).value,
    };

    expect(values, {
      'pref_string': 'filled',
      'pref_int': 42,
      'pref_bool': true,
    });
  });

  test('parses Chimahon profiles, field mappings, and dictionary order', () {
    final profile = {
      'id': 'japanese',
      'name': 'Japanese',
      'ankiEnabled': true,
      'ankiDeck': 'Mining',
      'ankiModel': 'Lapis',
      'ankiFieldMap': jsonEncode({
        'Expression': '{expression}',
        'Sentence': '{sentence}',
      }),
      'ankiTags': 'chimahon mining',
      'ankiDupCheck': true,
      'ankiDupScope': 'deck',
      'ankiDupAction': 'prevent',
      'ankiCropMode': 'selection',
      'ankiSyncOnCreate': true,
      'dictionaryOrder': ['JMdict', 'JPDB'],
      'enabledDictionaries': ['JMdict'],
      'dictionaryCollapseMode': 'custom',
      'dictionaryDisplayModes': {'JMdict': 'always_expanded'},
      'languageCode': 'ja',
    };
    final payload = ChimahonSettingsPayload.fromBackup([
      codec.encode('pref_anki_profiles', jsonEncode([profile])),
      codec.encode('pref_active_profile_id', 'japanese'),
      codec.encode('pref_dictionary_popup_mode', 'floating'),
      codec.encode('pref_dict_show_frequency_average', true),
    ]);

    final active = payload.activeLanguageProfile!;
    expect(active.languageCode, 'ja');
    expect(active.ankiFieldMap['Sentence'], '{sentence}');
    expect(active.dictionaryOrder, ['JMdict', 'JPDB']);
    expect(active.enabledDictionaries, {'JMdict'});
    expect(
      payload.dictionaryPreferences,
      contains('pref_dictionary_popup_mode'),
    );
    expect(payload.ankiPreferences, contains('pref_anki_profiles'));
  });

  test('extracts exact dynamic cascade overrides as strings', () {
    final payload = ChimahonSettingsPayload.fromBackup([
      codec.encode('pref_dict_profile_manga_42', 'japanese'),
      codec.encode('pref_dict_profile_source_9001', 'english'),
      codec.encode('pref_dict_profile_novel_book-id', 'korean'),
      codec.encode('pref_dict_profile_source_ignored', 123),
      codec.encode('pref_dictionary_popup_width', 500),
    ]);

    expect(payload.dictionaryProfileOverrides, {
      'pref_dict_profile_manga_42': 'japanese',
      'pref_dict_profile_source_9001': 'english',
      'pref_dict_profile_novel_book-id': 'korean',
    });
  });
}
