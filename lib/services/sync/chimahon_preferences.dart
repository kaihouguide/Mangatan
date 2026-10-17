import 'dart:convert';

import 'package:fixnum/fixnum.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupPreference.pb.dart';
import 'package:mangayomi/services/mining/anki_markers.dart';
import 'package:protobuf/protobuf.dart';

enum ChimahonPreferenceKind {
  integer,
  longInteger,
  floatingPoint,
  string,
  boolean,
  stringSet,
  unknown,
}

class DecodedChimahonPreference {
  const DecodedChimahonPreference({
    required this.key,
    required this.kind,
    required this.value,
    required this.encoded,
  });

  final String key;
  final ChimahonPreferenceKind kind;
  final Object? value;

  /// Original envelope retained for types introduced by a newer Chimahon.
  final BackupPreference encoded;
}

class ChimahonPreferenceCodec {
  const ChimahonPreferenceCodec();

  static const _modelPrefix = 'eu.kanade.tachiyomi.data.backup.models.';

  DecodedChimahonPreference decode(BackupPreference preference) {
    final type = preference.value.type.split('.').last;
    final bytes = preference.value.value;
    try {
      return _decode(preference, type, bytes);
    } on InvalidProtocolBufferException {
      // A damaged value is kept exactly like a type from a newer Chimahon:
      // opaque, and still carried in [DecodedChimahonPreference.encoded].
      return DecodedChimahonPreference(
        key: preference.key,
        kind: ChimahonPreferenceKind.unknown,
        value: null,
        encoded: preference.deepCopy(),
      );
    }
  }

  DecodedChimahonPreference _decode(
    BackupPreference preference,
    String type,
    List<int> bytes,
  ) {
    final (kind, value) = switch (type) {
      'IntPreferenceValue' => (
        ChimahonPreferenceKind.integer,
        IntPreferenceValue.fromBuffer(bytes).value,
      ),
      'LongPreferenceValue' => (
        ChimahonPreferenceKind.longInteger,
        LongPreferenceValue.fromBuffer(bytes).value.toInt(),
      ),
      'FloatPreferenceValue' => (
        ChimahonPreferenceKind.floatingPoint,
        FloatPreferenceValue.fromBuffer(bytes).value,
      ),
      'StringPreferenceValue' => (
        ChimahonPreferenceKind.string,
        StringPreferenceValue.fromBuffer(bytes).value,
      ),
      'BooleanPreferenceValue' => (
        ChimahonPreferenceKind.boolean,
        BooleanPreferenceValue.fromBuffer(bytes).value,
      ),
      'StringSetPreferenceValue' => (
        ChimahonPreferenceKind.stringSet,
        StringSetPreferenceValue.fromBuffer(bytes).value.toSet(),
      ),
      _ => (ChimahonPreferenceKind.unknown, null),
    };
    return DecodedChimahonPreference(
      key: preference.key,
      kind: kind,
      value: value,
      encoded: preference.deepCopy(),
    );
  }

  BackupPreference encode(String key, Object value) {
    final (type, bytes) = switch (value) {
      Int64 value => (
        'LongPreferenceValue',
        LongPreferenceValue(value: value).writeToBuffer(),
      ),
      int value => (
        'IntPreferenceValue',
        IntPreferenceValue(value: value).writeToBuffer(),
      ),
      double value => (
        'FloatPreferenceValue',
        FloatPreferenceValue(value: value).writeToBuffer(),
      ),
      String value => (
        'StringPreferenceValue',
        StringPreferenceValue(value: value).writeToBuffer(),
      ),
      bool value => (
        'BooleanPreferenceValue',
        BooleanPreferenceValue(value: value).writeToBuffer(),
      ),
      Set<String> value => (
        'StringSetPreferenceValue',
        StringSetPreferenceValue(value: value).writeToBuffer(),
      ),
      _ => throw ArgumentError.value(value, 'value', 'Unsupported preference'),
    };
    return BackupPreference(
      key: key,
      value: BackupPreferenceValue(type: '$_modelPrefix$type', value: bytes),
    );
  }
}

class ChimahonLanguageProfile {
  const ChimahonLanguageProfile({
    required this.id,
    required this.name,
    required this.ankiEnabled,
    required this.ankiDeck,
    required this.ankiModel,
    required this.ankiFieldMap,
    required this.ankiTags,
    required this.ankiDuplicateCheck,
    required this.ankiDuplicateScope,
    required this.ankiDuplicateAction,
    required this.ankiCropMode,
    required this.ankiSyncOnCreate,
    required this.dictionaryOrder,
    required this.enabledDictionaries,
    required this.dictionaryCollapseMode,
    required this.dictionaryDisplayModes,
    required this.languageCode,
  });

  final String id;
  final String name;
  final bool ankiEnabled;
  final String ankiDeck;
  final String ankiModel;
  final Map<String, String> ankiFieldMap;
  final String ankiTags;
  final bool ankiDuplicateCheck;
  final String ankiDuplicateScope;
  final String ankiDuplicateAction;
  final String ankiCropMode;
  final bool ankiSyncOnCreate;
  final List<String> dictionaryOrder;
  final Set<String> enabledDictionaries;
  final String dictionaryCollapseMode;
  final Map<String, String> dictionaryDisplayModes;
  final String languageCode;

  factory ChimahonLanguageProfile.fromJson(Map<String, dynamic> json) {
    final rawModelName = json['ankiModel']?.toString() ?? '';
    final modelName = rawModelName.trim().isEmpty
        ? AnkiMarker.lapisModelName
        : rawModelName;
    final rawFieldMap = json['ankiFieldMap'];
    Map<String, String> fieldMap = const {};
    if (rawFieldMap is String && rawFieldMap.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawFieldMap);
        if (decoded is Map) {
          fieldMap = decoded.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          );
        }
      } on FormatException {
        fieldMap = const {};
      }
    } else if (rawFieldMap is Map) {
      fieldMap = rawFieldMap.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    }

    return ChimahonLanguageProfile(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      ankiEnabled: json['ankiEnabled'] as bool? ?? false,
      ankiDeck: json['ankiDeck']?.toString() ?? '',
      ankiModel: modelName,
      ankiFieldMap: AnkiMarker.effectiveFieldMap(modelName, fieldMap),
      ankiTags: json['ankiTags']?.toString() ?? '',
      ankiDuplicateCheck: json['ankiDupCheck'] as bool? ?? true,
      ankiDuplicateScope: json['ankiDupScope']?.toString() ?? 'deck',
      ankiDuplicateAction: json['ankiDupAction']?.toString() ?? 'prevent',
      ankiCropMode: json['ankiCropMode']?.toString() ?? 'full',
      ankiSyncOnCreate: json['ankiSyncOnCreate'] as bool? ?? false,
      dictionaryOrder: _stringList(json['dictionaryOrder']),
      enabledDictionaries: _stringList(json['enabledDictionaries']).toSet(),
      dictionaryCollapseMode:
          json['dictionaryCollapseMode']?.toString() ?? 'expand_all',
      dictionaryDisplayModes: _stringMap(json['dictionaryDisplayModes']),
      languageCode: json['languageCode']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'ankiEnabled': ankiEnabled,
    'ankiDeck': ankiDeck,
    'ankiModel': ankiModel,
    'ankiFieldMap': jsonEncode(ankiFieldMap),
    'ankiTags': ankiTags,
    'ankiDupCheck': ankiDuplicateCheck,
    'ankiDupScope': ankiDuplicateScope,
    'ankiDupAction': ankiDuplicateAction,
    'ankiCropMode': ankiCropMode,
    'ankiSyncOnCreate': ankiSyncOnCreate,
    'dictionaryOrder': dictionaryOrder,
    'enabledDictionaries': enabledDictionaries.toList(),
    'dictionaryCollapseMode': dictionaryCollapseMode,
    'dictionaryDisplayModes': dictionaryDisplayModes,
    'languageCode': languageCode,
  };

  static List<String> _stringList(Object? value) =>
      value is List ? value.map((item) => item.toString()).toList() : const [];

  static Map<String, String> _stringMap(Object? value) => value is Map
      ? value.map((key, item) => MapEntry(key.toString(), item.toString()))
      : const {};
}

class ChimahonSettingsPayload {
  ChimahonSettingsPayload._(this.preferences);

  final Map<String, DecodedChimahonPreference> preferences;

  factory ChimahonSettingsPayload.fromBackup(
    Iterable<BackupPreference> preferences, {
    ChimahonPreferenceCodec codec = const ChimahonPreferenceCodec(),
  }) => ChimahonSettingsPayload._({
    for (final preference in preferences)
      preference.key: codec.decode(preference),
  });

  Object? operator [](String key) => preferences[key]?.value;

  List<ChimahonLanguageProfile> get languageProfiles {
    final raw = this['pref_anki_profiles'];
    if (raw is! String || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map(
            (profile) => ChimahonLanguageProfile.fromJson(
              profile.map((key, value) => MapEntry(key.toString(), value)),
            ),
          )
          .toList();
    } on FormatException {
      return const [];
    }
  }

  String get activeProfileId =>
      this['pref_active_profile_id']?.toString() ?? '';

  ChimahonLanguageProfile? get activeLanguageProfile {
    final profiles = languageProfiles;
    if (profiles.isEmpty) return null;
    return profiles
            .where((profile) => profile.id == activeProfileId)
            .firstOrNull ??
        profiles.first;
  }

  Map<String, DecodedChimahonPreference> get dictionaryPreferences => {
    for (final entry in preferences.entries)
      if (entry.key.startsWith('pref_dict_') ||
          entry.key.startsWith('pref_dictionary_') ||
          entry.key == 'pref_display_names')
        entry.key: entry.value,
  };

  Map<String, DecodedChimahonPreference> get ankiPreferences => {
    for (final entry in preferences.entries)
      if (entry.key.startsWith('pref_anki_') ||
          entry.key == 'pref_active_profile_id')
        entry.key: entry.value,
  };

  Map<String, String> get dictionaryProfileOverrides => {
    for (final entry in preferences.entries)
      if (_isDictionaryProfileOverrideKey(entry.key) &&
          entry.value.value is String)
        entry.key: entry.value.value! as String,
  };

  static bool _isDictionaryProfileOverrideKey(String key) =>
      key.startsWith('pref_dict_profile_manga_') ||
      key.startsWith('pref_dict_profile_source_') ||
      key.startsWith('pref_dict_profile_novel_');
}
