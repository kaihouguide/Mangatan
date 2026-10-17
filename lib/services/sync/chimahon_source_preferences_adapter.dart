import 'dart:convert';

import 'package:isar_community/isar.dart';
import 'package:mangayomi/eval/mihon/bridge_protocol.dart';
import 'package:mangayomi/eval/model/source_preference.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupPreference.pb.dart';
import 'package:mangayomi/services/mihon_source_preferences.dart';
import 'package:mangayomi/services/sync/chimahon_preferences.dart';
import 'package:mangayomi/repositories/db_write_queue.dart';

/// Lossless bridge for preferences owned by installed Mihon source factories.
///
/// Chimahon identifies a preference store as `source_<native source id>`.
/// Mangatan's Isar source ID is a process-local hash and must never appear on
/// that wire. Unknown stores, keys, value types, and malformed values are left
/// untouched locally; the deferred payload retains their original protobuf.
class ChimahonSourcePreferencesAdapter {
  const ChimahonSourcePreferencesAdapter({
    this.codec = const ChimahonPreferenceCodec(),
  });

  final ChimahonPreferenceCodec codec;

  List<BackupSourcePreferences> export({
    required Iterable<Source> sources,
    Iterable<SourcePreference> storedPreferences = const [],
  }) {
    final storedBySource = <int, List<SourcePreference>>{};
    for (final preference in storedPreferences) {
      final sourceId = preference.sourceId;
      if (sourceId == null) continue;
      storedBySource.putIfAbsent(sourceId, () => []).add(preference);
    }

    final result = <String, BackupSourcePreferences>{};
    for (final source in sources) {
      final sourceKey = sourcePreferenceKey(source);
      final localId = source.id;
      if (sourceKey == null || localId == null) continue;

      final preferences = mergeMihonSourcePreferenceDefinitions(
        decodeMihonSourcePreferences(source.preferenceList),
        storedBySource[localId] ?? const [],
      );
      final encoded = <BackupPreference>[];
      for (final preference in preferences) {
        final key = preference.key;
        final value = _valueOf(preference);
        if (key == null || key.isEmpty || value == null) continue;
        encoded.add(codec.encode(key, value));
      }
      if (encoded.isNotEmpty) {
        encoded.sort((left, right) => left.key.compareTo(right.key));
        result[sourceKey] = BackupSourcePreferences(
          sourceKey: sourceKey,
          prefs: encoded,
        );
      }
    }
    final keys = result.keys.toList()..sort();
    return [for (final key in keys) result[key]!];
  }

  /// Applies compatible values to installed source definitions.
  ///
  /// This intentionally does not delete a local definition merely because it
  /// is absent remotely. An absent key can mean the extension now uses its
  /// default, while deleting the definition would also discard its UI schema.
  ChimahonSourcePreferencesImportResult importInto({
    required Isar database,
    required Iterable<BackupSourcePreferences> sourcePreferences,
    Iterable<Source>? candidateSources,
  }) {
    final changes = _prepareImport(
      database: database,
      sourcePreferences: sourcePreferences,
      candidateSources: candidateSources,
    );
    if (changes.sources.isEmpty && changes.preferences.isEmpty) {
      return ChimahonSourcePreferencesImportResult(
        valueChangedSourceIds: changes.valueChangedSourceIds,
      );
    }
    database.writeTxnSync(() {
      if (changes.sources.isNotEmpty) {
        database.sources.putAllSync(changes.sources);
      }
      if (changes.preferences.isNotEmpty) {
        database.sourcePreferences.putAllSync(changes.preferences);
      }
    });
    return ChimahonSourcePreferencesImportResult(
      valueChangedSourceIds: changes.valueChangedSourceIds,
    );
  }

  /// Async transaction variant for independent factory groups refreshed in
  /// parallel. Each caller can limit work to its own [candidateSources], while
  /// the write queue serializes the resulting writes with every other queued
  /// write. Callers must not already be running inside a queued write.
  Future<ChimahonSourcePreferencesImportResult> importIntoAsync({
    required Isar database,
    required Iterable<BackupSourcePreferences> sourcePreferences,
    Iterable<Source>? candidateSources,
  }) async {
    final changes = _prepareImport(
      database: database,
      sourcePreferences: sourcePreferences,
      candidateSources: candidateSources,
    );
    if (changes.sources.isEmpty && changes.preferences.isEmpty) {
      return ChimahonSourcePreferencesImportResult(
        valueChangedSourceIds: changes.valueChangedSourceIds,
      );
    }
    await dbWriteQueue.run(
      () => database.writeTxn(() async {
        if (changes.sources.isNotEmpty) {
          await database.sources.putAll(changes.sources);
        }
        if (changes.preferences.isNotEmpty) {
          await database.sourcePreferences.putAll(changes.preferences);
        }
      }),
    );
    return ChimahonSourcePreferencesImportResult(
      valueChangedSourceIds: changes.valueChangedSourceIds,
    );
  }

  ({
    List<Source> sources,
    List<SourcePreference> preferences,
    Set<int> valueChangedSourceIds,
  })
  _prepareImport({
    required Isar database,
    required Iterable<BackupSourcePreferences> sourcePreferences,
    required Iterable<Source>? candidateSources,
  }) {
    final sources =
        candidateSources?.toList(growable: false) ??
        database.sources.where().findAllSync();
    final remoteByKey = {
      for (final group in sourcePreferences) group.sourceKey: group,
    };
    if (remoteByKey.isEmpty) {
      return (
        sources: <Source>[],
        preferences: <SourcePreference>[],
        valueChangedSourceIds: <int>{},
      );
    }

    final stored = database.sourcePreferences.where().findAllSync();
    final storedBySource = <int, List<SourcePreference>>{};
    for (final preference in stored) {
      final sourceId = preference.sourceId;
      if (sourceId == null) continue;
      storedBySource.putIfAbsent(sourceId, () => []).add(preference);
    }

    final changedSources = <Source>[];
    final changedPreferences = <SourcePreference>[];
    final valueChangedSourceIds = <int>{};
    for (final source in sources) {
      final sourceKey = sourcePreferenceKey(source);
      final localId = source.id;
      final remote = sourceKey == null ? null : remoteByKey[sourceKey];
      if (remote == null || localId == null) continue;

      final definitions = mergeMihonSourcePreferenceDefinitions(
        decodeMihonSourcePreferences(source.preferenceList),
        storedBySource[localId] ?? const [],
      );
      final definitionsByKey = <String, SourcePreference>{};
      for (final preference in definitions) {
        if (preference.key case final key?) {
          definitionsByKey[key] = preference;
        }
      }
      final storedByKey = <String, SourcePreference>{};
      for (final preference in storedBySource[localId] ?? const []) {
        if (preference.key case final key?) {
          storedByKey[key] = preference;
        }
      }
      var sourceChanged = false;
      for (final encoded in remote.prefs) {
        final definition = definitionsByKey[encoded.key];
        if (definition == null) continue;
        DecodedChimahonPreference decoded;
        try {
          decoded = codec.decode(encoded);
        } on Object {
          continue;
        }
        final priorValue = _valueOf(definition);
        if (!_applyCompatible(definition, decoded)) continue;
        sourceChanged = true;
        if (!_samePreferenceValue(priorValue, decoded.value)) {
          valueChangedSourceIds.add(localId);
        }

        final persisted = SourcePreference.fromJson(definition.toJson())
          ..id = storedByKey[encoded.key]?.id
          ..sourceId = localId;
        changedPreferences.add(persisted);
        storedByKey[encoded.key] = persisted;
      }
      if (!sourceChanged) continue;
      source.preferenceList = jsonEncode(
        definitions.map((preference) => preference.toJson()).toList(),
      );
      changedSources.add(source);
    }

    return (
      sources: changedSources,
      preferences: changedPreferences,
      valueChangedSourceIds: valueChangedSourceIds,
    );
  }

  /// Returns Chimahon's portable preference-store key for [source].
  String? sourcePreferenceKey(Source source) {
    if (source.sourceCodeLanguage != SourceCodeLanguage.mihon) return null;
    final encodedId = mihonSourceMetadata(source)?.sourceId.trim();
    final nativeId = int.tryParse(encodedId ?? '');
    if (nativeId == null) return null;
    return 'source_$nativeId';
  }

  Object? _valueOf(SourcePreference preference) {
    if (preference.checkBoxPreference case final value?) return value.value;
    if (preference.switchPreferenceCompat case final value?) {
      return value.value;
    }
    if (preference.editTextPreference case final value?) {
      return value.value ?? value.text;
    }
    if (preference.listPreference case final value?) {
      final index = value.valueIndex;
      final values = value.entryValues ?? const <String>[];
      if (index == null || index < 0 || index >= values.length) return null;
      return values[index];
    }
    if (preference.multiSelectListPreference case final value?) {
      final values = value.values;
      return values?.toSet();
    }
    return null;
  }

  bool _samePreferenceValue(Object? left, Object? right) {
    if (left is Set<String> && right is Set<String>) {
      return left.length == right.length && left.containsAll(right);
    }
    return left == right;
  }

  bool _applyCompatible(
    SourcePreference preference,
    DecodedChimahonPreference decoded,
  ) {
    if (preference.checkBoxPreference case final target?) {
      if (decoded.kind != ChimahonPreferenceKind.boolean ||
          decoded.value is! bool) {
        return false;
      }
      final value = decoded.value! as bool;
      target.value = value;
      return true;
    }
    if (preference.switchPreferenceCompat case final target?) {
      if (decoded.kind != ChimahonPreferenceKind.boolean ||
          decoded.value is! bool) {
        return false;
      }
      final value = decoded.value! as bool;
      target.value = value;
      return true;
    }
    if (preference.editTextPreference case final target?) {
      if (decoded.kind != ChimahonPreferenceKind.string ||
          decoded.value is! String) {
        return false;
      }
      final value = decoded.value! as String;
      target
        ..value = value
        ..text = value;
      return true;
    }
    if (preference.listPreference case final target?) {
      if (decoded.kind != ChimahonPreferenceKind.string ||
          decoded.value is! String) {
        return false;
      }
      final index = target.entryValues?.indexOf(decoded.value! as String) ?? -1;
      if (index < 0) return false;
      target.valueIndex = index;
      return true;
    }
    if (preference.multiSelectListPreference case final target?) {
      if (decoded.kind != ChimahonPreferenceKind.stringSet ||
          decoded.value is! Set<String>) {
        return false;
      }
      final value = decoded.value! as Set<String>;
      final entryValues = target.entryValues ?? const <String>[];
      target.values = [
        for (final entry in entryValues)
          if (value.contains(entry)) entry,
        for (final entry in value)
          if (!entryValues.contains(entry)) entry,
      ];
      return true;
    }
    return false;
  }
}

class ChimahonSourcePreferencesImportResult {
  const ChimahonSourcePreferencesImportResult({
    required this.valueChangedSourceIds,
  });

  /// Local source rows whose effective value changed, and therefore need to
  /// be propagated to the JVM bridge before factory descriptors are queried.
  final Set<int> valueChangedSourceIds;
}
