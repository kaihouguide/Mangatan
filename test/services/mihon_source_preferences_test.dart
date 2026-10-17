import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/eval/model/source_preference.dart';
import 'package:mangayomi/services/mihon_source_preferences.dart';

SourcePreference _checkBox(String key, bool value) => SourcePreference(
  key: key,
  checkBoxPreference: CheckBoxPreference(value: value),
);

void main() {
  group('decodeMihonSourcePreferences', () {
    test('decodes the persisted preference list', () {
      final payload = jsonEncode([
        _checkBox('nsfw', true).toJson(),
        _checkBox('hd', false).toJson(),
      ]);

      final decoded = decodeMihonSourcePreferences(payload);

      expect(decoded.map((p) => p.key), ['nsfw', 'hd']);
      expect(decoded.first.checkBoxPreference?.value, isTrue);
    });

    test('treats absent or malformed extension data as no preferences', () {
      expect(decodeMihonSourcePreferences(null), isEmpty);
      expect(decodeMihonSourcePreferences(''), isEmpty);
      expect(decodeMihonSourcePreferences('not json'), isEmpty);
      expect(decodeMihonSourcePreferences('{"key": "a"}'), isEmpty);
    });

    test('skips non-object entries but keeps the valid ones', () {
      final payload = jsonEncode([1, 'x', _checkBox('nsfw', true).toJson()]);

      expect(decodeMihonSourcePreferences(payload).single.key, 'nsfw');
    });
  });

  group('mergeMihonSourcePreferenceDefinitions', () {
    test('primary values win and fallback fills missing keys', () {
      final merged = mergeMihonSourcePreferenceDefinitions(
        [_checkBox('nsfw', true)],
        [_checkBox('nsfw', false), _checkBox('hd', true)],
      );

      expect(merged.map((p) => p.key), ['nsfw', 'hd']);
      expect(merged.first.checkBoxPreference?.value, isTrue);
    });

    test('drops definitions without a usable key', () {
      final merged = mergeMihonSourcePreferenceDefinitions(
        [SourcePreference(key: ''), SourcePreference()],
        [_checkBox('hd', true)],
      );

      expect(merged.single.key, 'hd');
    });
  });
}
