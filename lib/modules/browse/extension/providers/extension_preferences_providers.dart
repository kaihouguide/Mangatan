import 'dart:convert';

import 'package:mangayomi/eval/model/source_preference.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/repositories/source_preference_repository.dart';
import 'package:mangayomi/repositories/source_repository.dart';
import 'package:mangayomi/services/get_source_preference.dart';
import 'package:mangayomi/services/mihon_source_preferences.dart';

import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';

import 'package:mangayomi/eval/aidoku/aidoku_ext_dart.dart' as aidoku;

// Written synchronously: extensions read a value back through the database
// right after setting it, and a queued write would return the stale value.
void setPreferenceSetting(SourcePreference sourcePreference, Source source) {
  final sourcePref = isar.sourcePreferences
      .filter()
      .sourceIdEqualTo(source.id)
      .keyEqualTo(sourcePreference.key)
      .findFirstSync();
  final key = sourcePreference.key;
  final runtimeValue = key == null ? null : _runtimeValue(sourcePreference);
  isar.writeTxnSync(() {
    if ((source.sourceCodeLanguage == SourceCodeLanguage.mihon ||
            source.sourceCodeLanguage == SourceCodeLanguage.aidoku) &&
        source.preferenceList != null) {
      final prefs = decodeMihonSourcePreferences(source.preferenceList);
      final idx = prefs.indexWhere((e) => e.key == sourcePreference.key);
      if (idx != -1) {
        prefs[idx] = SourcePreference.fromJson(sourcePreference.toJson())
          ..id = null;
        isar.sources.putSync(
          source
            ..preferenceList = jsonEncode(
              prefs.map((e) => e.toJson()).toList(),
            ),
        );
      }
    }
    if (sourcePref != null) {
      isar.sourcePreferences.putSync(
        sourcePreference
          ..id = sourcePref.id
          ..sourceId = source.id,
      );
    } else {
      isar.sourcePreferences.putSync(sourcePreference..sourceId = source.id);
    }
    // LNReader plugins read their settings from the string-value table.
    if (source.sourceCodeLanguage == SourceCodeLanguage.lnreader &&
        source.id != null &&
        key != null &&
        runtimeValue != null) {
      _putStringValue(
        source.id!,
        key,
        runtimeValue is String ? runtimeValue : jsonEncode(runtimeValue),
      );
    }
  });
  // A loaded Aidoku source reads its settings from this store, not the database.
  if (source.sourceCodeLanguage == SourceCodeLanguage.aidoku &&
      key != null &&
      runtimeValue != null) {
    aidoku.SettingsStore.shared.setValue(key, runtimeValue);
  }
}

/// The value a runtime sees for [preference]; a list falls back to its index.
dynamic _runtimeValue(SourcePreference preference) {
  if (preference.listPreference case final list?) {
    final values = list.entryValues;
    final index = list.valueIndex;
    return values != null &&
            index != null &&
            index >= 0 &&
            index < values.length
        ? values[index]
        : index;
  }
  if (preference.checkBoxPreference case final checkBox?) return checkBox.value;
  if (preference.switchPreferenceCompat case final toggle?) return toggle.value;
  if (preference.multiSelectListPreference case final multi?) {
    return multi.values;
  }
  return preference.editTextPreference?.value;
}

dynamic getPreferenceValue(int sourceId, String key) {
  final sourcePreference = getSourcePreferenceEntry(key, sourceId);

  if (sourcePreference.listPreference != null) {
    final pref = sourcePreference.listPreference!;
    final index = pref.valueIndex;
    final values = pref.entryValues ?? const <String>[];
    return index != null && index >= 0 && index < values.length
        ? values[index]
        : null;
  } else if (sourcePreference.checkBoxPreference != null) {
    return sourcePreference.checkBoxPreference!.value;
  } else if (sourcePreference.switchPreferenceCompat != null) {
    return sourcePreference.switchPreferenceCompat!.value;
  } else if (sourcePreference.editTextPreference != null) {
    return sourcePreference.editTextPreference!.value;
  }
  return sourcePreference.multiSelectListPreference!.values;
}

SourcePreference getSourcePreferenceEntry(String key, int sourceId) {
  SourcePreference? sourcePreference = sourcePreferenceRepository.findByKey(
    sourceId,
    key,
  );
  if (sourcePreference == null) {
    final source = sourceRepository.getById(sourceId)!;
    sourcePreference = getSourcePreference(source: source).firstWhere(
      (element) => element.key == key,
      orElse: () => throw "Error when getting source preference",
    );
    setPreferenceSetting(sourcePreference, source);
  }

  return sourcePreference;
}

String getSourcePreferenceStringValue(
  int sourceId,
  String key,
  String defaultValue,
) {
  SourcePreferenceStringValue? sourcePreferenceStringValue =
      sourcePreferenceRepository.findStringValueByKey(sourceId, key);
  if (sourcePreferenceStringValue == null) {
    setSourcePreferenceStringValue(sourceId, key, defaultValue);
    return defaultValue;
  }

  return sourcePreferenceStringValue.value ?? "";
}

void setSourcePreferenceStringValue(int sourceId, String key, String value) {
  isar.writeTxnSync(() => _putStringValue(sourceId, key, value));
}

/// Must run inside a write transaction.
void _putStringValue(int sourceId, String key, String value) {
  final existing = isar.sourcePreferenceStringValues
      .filter()
      .sourceIdEqualTo(sourceId)
      .keyEqualTo(key)
      .findFirstSync();
  isar.sourcePreferenceStringValues.putSync(
    (existing ??
          (SourcePreferenceStringValue()
            ..key = key
            ..sourceId = sourceId))
      ..value = value,
  );
}
