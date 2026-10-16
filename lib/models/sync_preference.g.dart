// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sync_preference.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetSyncPreferenceCollection on Isar {
  IsarCollection<SyncPreference> get syncPreferences => this.collection();
}

const SyncPreferenceSchema = CollectionSchema(
  name: r'Sync Preference',
  id: 2788277548653279925,
  properties: {
    r'authToken': PropertySchema(
      id: 0,
      name: r'authToken',
      type: IsarType.string,
    ),
    r'autoSyncFrequency': PropertySchema(
      id: 1,
      name: r'autoSyncFrequency',
      type: IsarType.long,
    ),
    r'chimahonDeviceId': PropertySchema(
      id: 2,
      name: r'chimahonDeviceId',
      type: IsarType.string,
    ),
    r'chimahonMediaSelectionGeneration': PropertySchema(
      id: 3,
      name: r'chimahonMediaSelectionGeneration',
      type: IsarType.long,
    ),
    r'chimahonMediaSelectionInitialized': PropertySchema(
      id: 4,
      name: r'chimahonMediaSelectionInitialized',
      type: IsarType.bool,
    ),
    r'chimahonMediaSelectionScopeToken': PropertySchema(
      id: 5,
      name: r'chimahonMediaSelectionScopeToken',
      type: IsarType.string,
    ),
    r'chimahonMediaSelectionUserSelected': PropertySchema(
      id: 6,
      name: r'chimahonMediaSelectionUserSelected',
      type: IsarType.bool,
    ),
    r'chimahonSyncAnime': PropertySchema(
      id: 7,
      name: r'chimahonSyncAnime',
      type: IsarType.bool,
    ),
    r'chimahonSyncManga': PropertySchema(
      id: 8,
      name: r'chimahonSyncManga',
      type: IsarType.bool,
    ),
    r'chimahonSyncNovels': PropertySchema(
      id: 9,
      name: r'chimahonSyncNovels',
      type: IsarType.bool,
    ),
    r'chimahonSyncProvider': PropertySchema(
      id: 10,
      name: r'chimahonSyncProvider',
      type: IsarType.byte,
      enumMap: _SyncPreferencechimahonSyncProviderEnumValueMap,
    ),
    r'email': PropertySchema(id: 11, name: r'email', type: IsarType.string),
    r'googleDriveConnected': PropertySchema(
      id: 12,
      name: r'googleDriveConnected',
      type: IsarType.bool,
    ),
    r'lastSync': PropertySchema(id: 13, name: r'lastSync', type: IsarType.long),
    r'server': PropertySchema(id: 14, name: r'server', type: IsarType.string),
    r'sessionToken': PropertySchema(
      id: 15,
      name: r'sessionToken',
      type: IsarType.string,
    ),
    r'since': PropertySchema(id: 16, name: r'since', type: IsarType.long),
    r'syncMode': PropertySchema(
      id: 17,
      name: r'syncMode',
      type: IsarType.byte,
      enumMap: _SyncPreferencesyncModeEnumValueMap,
    ),
    r'syncOn': PropertySchema(id: 18, name: r'syncOn', type: IsarType.bool),
    r'syncYomiApiToken': PropertySchema(
      id: 19,
      name: r'syncYomiApiToken',
      type: IsarType.string,
    ),
    r'syncYomiServer': PropertySchema(
      id: 20,
      name: r'syncYomiServer',
      type: IsarType.string,
    ),
  },

  estimateSize: _syncPreferenceEstimateSize,
  serialize: _syncPreferenceSerialize,
  deserialize: _syncPreferenceDeserialize,
  deserializeProp: _syncPreferenceDeserializeProp,
  idName: r'syncId',
  indexes: {},
  links: {},
  embeddedSchemas: {},

  getId: _syncPreferenceGetId,
  getLinks: _syncPreferenceGetLinks,
  attach: _syncPreferenceAttach,
  version: '3.3.2',
);

int _syncPreferenceEstimateSize(
  SyncPreference object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  {
    final value = object.authToken;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.chimahonDeviceId;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.chimahonMediaSelectionScopeToken;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.email;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.server;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.sessionToken;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.syncYomiApiToken;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  {
    final value = object.syncYomiServer;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  return bytesCount;
}

void _syncPreferenceSerialize(
  SyncPreference object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeString(offsets[0], object.authToken);
  writer.writeLong(offsets[1], object.autoSyncFrequency);
  writer.writeString(offsets[2], object.chimahonDeviceId);
  writer.writeLong(offsets[3], object.chimahonMediaSelectionGeneration);
  writer.writeBool(offsets[4], object.chimahonMediaSelectionInitialized);
  writer.writeString(offsets[5], object.chimahonMediaSelectionScopeToken);
  writer.writeBool(offsets[6], object.chimahonMediaSelectionUserSelected);
  writer.writeBool(offsets[7], object.chimahonSyncAnime);
  writer.writeBool(offsets[8], object.chimahonSyncManga);
  writer.writeBool(offsets[9], object.chimahonSyncNovels);
  writer.writeByte(offsets[10], object.chimahonSyncProvider.index);
  writer.writeString(offsets[11], object.email);
  writer.writeBool(offsets[12], object.googleDriveConnected);
  writer.writeLong(offsets[13], object.lastSync);
  writer.writeString(offsets[14], object.server);
  writer.writeString(offsets[15], object.sessionToken);
  writer.writeLong(offsets[16], object.since);
  writer.writeByte(offsets[17], object.syncMode.index);
  writer.writeBool(offsets[18], object.syncOn);
  writer.writeString(offsets[19], object.syncYomiApiToken);
  writer.writeString(offsets[20], object.syncYomiServer);
}

SyncPreference _syncPreferenceDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = SyncPreference(
    authToken: reader.readStringOrNull(offsets[0]),
    autoSyncFrequency: reader.readLongOrNull(offsets[1]) ?? 0,
    chimahonDeviceId: reader.readStringOrNull(offsets[2]),
    chimahonMediaSelectionGeneration: reader.readLongOrNull(offsets[3]) ?? 0,
    chimahonMediaSelectionInitialized:
        reader.readBoolOrNull(offsets[4]) ?? false,
    chimahonMediaSelectionScopeToken: reader.readStringOrNull(offsets[5]),
    chimahonMediaSelectionUserSelected:
        reader.readBoolOrNull(offsets[6]) ?? false,
    chimahonSyncAnime: reader.readBoolOrNull(offsets[7]) ?? true,
    chimahonSyncManga: reader.readBoolOrNull(offsets[8]) ?? true,
    chimahonSyncNovels: reader.readBoolOrNull(offsets[9]) ?? true,
    chimahonSyncProvider:
        _SyncPreferencechimahonSyncProviderValueEnumMap[reader.readByteOrNull(
          offsets[10],
        )] ??
        ChimahonSyncProvider.syncYomi,
    email: reader.readStringOrNull(offsets[11]),
    googleDriveConnected: reader.readBoolOrNull(offsets[12]) ?? false,
    lastSync: reader.readLongOrNull(offsets[13]),
    server: reader.readStringOrNull(offsets[14]),
    sessionToken: reader.readStringOrNull(offsets[15]),
    since: reader.readLongOrNull(offsets[16]),
    syncId: id,
    syncMode:
        _SyncPreferencesyncModeValueEnumMap[reader.readByteOrNull(
          offsets[17],
        )] ??
        SyncMode.native,
    syncOn: reader.readBoolOrNull(offsets[18]) ?? false,
    syncYomiApiToken: reader.readStringOrNull(offsets[19]),
    syncYomiServer: reader.readStringOrNull(offsets[20]),
  );
  return object;
}

P _syncPreferenceDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readStringOrNull(offset)) as P;
    case 1:
      return (reader.readLongOrNull(offset) ?? 0) as P;
    case 2:
      return (reader.readStringOrNull(offset)) as P;
    case 3:
      return (reader.readLongOrNull(offset) ?? 0) as P;
    case 4:
      return (reader.readBoolOrNull(offset) ?? false) as P;
    case 5:
      return (reader.readStringOrNull(offset)) as P;
    case 6:
      return (reader.readBoolOrNull(offset) ?? false) as P;
    case 7:
      return (reader.readBoolOrNull(offset) ?? true) as P;
    case 8:
      return (reader.readBoolOrNull(offset) ?? true) as P;
    case 9:
      return (reader.readBoolOrNull(offset) ?? true) as P;
    case 10:
      return (_SyncPreferencechimahonSyncProviderValueEnumMap[reader
                  .readByteOrNull(offset)] ??
              ChimahonSyncProvider.syncYomi)
          as P;
    case 11:
      return (reader.readStringOrNull(offset)) as P;
    case 12:
      return (reader.readBoolOrNull(offset) ?? false) as P;
    case 13:
      return (reader.readLongOrNull(offset)) as P;
    case 14:
      return (reader.readStringOrNull(offset)) as P;
    case 15:
      return (reader.readStringOrNull(offset)) as P;
    case 16:
      return (reader.readLongOrNull(offset)) as P;
    case 17:
      return (_SyncPreferencesyncModeValueEnumMap[reader.readByteOrNull(
                offset,
              )] ??
              SyncMode.native)
          as P;
    case 18:
      return (reader.readBoolOrNull(offset) ?? false) as P;
    case 19:
      return (reader.readStringOrNull(offset)) as P;
    case 20:
      return (reader.readStringOrNull(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

const _SyncPreferencechimahonSyncProviderEnumValueMap = {
  'syncYomi': 0,
  'googleDrive': 1,
  'webDav': 2,
};
const _SyncPreferencechimahonSyncProviderValueEnumMap = {
  0: ChimahonSyncProvider.syncYomi,
  1: ChimahonSyncProvider.googleDrive,
  2: ChimahonSyncProvider.webDav,
};
const _SyncPreferencesyncModeEnumValueMap = {'native': 0, 'chimahon': 1};
const _SyncPreferencesyncModeValueEnumMap = {
  0: SyncMode.native,
  1: SyncMode.chimahon,
};

Id _syncPreferenceGetId(SyncPreference object) {
  return object.syncId ?? Isar.autoIncrement;
}

List<IsarLinkBase<dynamic>> _syncPreferenceGetLinks(SyncPreference object) {
  return [];
}

void _syncPreferenceAttach(
  IsarCollection<dynamic> col,
  Id id,
  SyncPreference object,
) {
  object.syncId = id;
}

extension SyncPreferenceQueryWhereSort
    on QueryBuilder<SyncPreference, SyncPreference, QWhere> {
  QueryBuilder<SyncPreference, SyncPreference, QAfterWhere> anySyncId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension SyncPreferenceQueryWhere
    on QueryBuilder<SyncPreference, SyncPreference, QWhereClause> {
  QueryBuilder<SyncPreference, SyncPreference, QAfterWhereClause> syncIdEqualTo(
    Id syncId,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.between(lower: syncId, upper: syncId),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterWhereClause>
  syncIdNotEqualTo(Id syncId) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: syncId, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: syncId, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: syncId, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: syncId, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterWhereClause>
  syncIdGreaterThan(Id syncId, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: syncId, includeLower: include),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterWhereClause>
  syncIdLessThan(Id syncId, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: syncId, includeUpper: include),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterWhereClause> syncIdBetween(
    Id lowerSyncId,
    Id upperSyncId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.between(
          lower: lowerSyncId,
          includeLower: includeLower,
          upper: upperSyncId,
          includeUpper: includeUpper,
        ),
      );
    });
  }
}

extension SyncPreferenceQueryFilter
    on QueryBuilder<SyncPreference, SyncPreference, QFilterCondition> {
  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  authTokenIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'authToken'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  authTokenIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'authToken'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  authTokenEqualTo(String? value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'authToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  authTokenGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'authToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  authTokenLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'authToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  authTokenBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'authToken',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  authTokenStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'authToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  authTokenEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'authToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  authTokenContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'authToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  authTokenMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'authToken',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  authTokenIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'authToken', value: ''),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  authTokenIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'authToken', value: ''),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  autoSyncFrequencyEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'autoSyncFrequency', value: value),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  autoSyncFrequencyGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'autoSyncFrequency',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  autoSyncFrequencyLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'autoSyncFrequency',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  autoSyncFrequencyBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'autoSyncFrequency',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonDeviceIdIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'chimahonDeviceId'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonDeviceIdIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'chimahonDeviceId'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonDeviceIdEqualTo(String? value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'chimahonDeviceId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonDeviceIdGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'chimahonDeviceId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonDeviceIdLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'chimahonDeviceId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonDeviceIdBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'chimahonDeviceId',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonDeviceIdStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'chimahonDeviceId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonDeviceIdEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'chimahonDeviceId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonDeviceIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'chimahonDeviceId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonDeviceIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'chimahonDeviceId',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonDeviceIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'chimahonDeviceId', value: ''),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonDeviceIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'chimahonDeviceId', value: ''),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonMediaSelectionGenerationEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'chimahonMediaSelectionGeneration',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonMediaSelectionGenerationGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'chimahonMediaSelectionGeneration',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonMediaSelectionGenerationLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'chimahonMediaSelectionGeneration',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonMediaSelectionGenerationBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'chimahonMediaSelectionGeneration',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonMediaSelectionInitializedEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'chimahonMediaSelectionInitialized',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonMediaSelectionScopeTokenIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(
          property: r'chimahonMediaSelectionScopeToken',
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonMediaSelectionScopeTokenIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(
          property: r'chimahonMediaSelectionScopeToken',
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonMediaSelectionScopeTokenEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'chimahonMediaSelectionScopeToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonMediaSelectionScopeTokenGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'chimahonMediaSelectionScopeToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonMediaSelectionScopeTokenLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'chimahonMediaSelectionScopeToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonMediaSelectionScopeTokenBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'chimahonMediaSelectionScopeToken',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonMediaSelectionScopeTokenStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'chimahonMediaSelectionScopeToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonMediaSelectionScopeTokenEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'chimahonMediaSelectionScopeToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonMediaSelectionScopeTokenContains(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'chimahonMediaSelectionScopeToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonMediaSelectionScopeTokenMatches(
    String pattern, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'chimahonMediaSelectionScopeToken',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonMediaSelectionScopeTokenIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'chimahonMediaSelectionScopeToken',
          value: '',
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonMediaSelectionScopeTokenIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          property: r'chimahonMediaSelectionScopeToken',
          value: '',
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonMediaSelectionUserSelectedEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'chimahonMediaSelectionUserSelected',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonSyncAnimeEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'chimahonSyncAnime', value: value),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonSyncMangaEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'chimahonSyncManga', value: value),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonSyncNovelsEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'chimahonSyncNovels', value: value),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonSyncProviderEqualTo(ChimahonSyncProvider value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'chimahonSyncProvider',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonSyncProviderGreaterThan(
    ChimahonSyncProvider value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'chimahonSyncProvider',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonSyncProviderLessThan(
    ChimahonSyncProvider value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'chimahonSyncProvider',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  chimahonSyncProviderBetween(
    ChimahonSyncProvider lower,
    ChimahonSyncProvider upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'chimahonSyncProvider',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  emailIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'email'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  emailIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'email'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  emailEqualTo(String? value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'email',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  emailGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'email',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  emailLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'email',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  emailBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'email',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  emailStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'email',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  emailEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'email',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  emailContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'email',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  emailMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'email',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  emailIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'email', value: ''),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  emailIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'email', value: ''),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  googleDriveConnectedEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'googleDriveConnected',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  lastSyncIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'lastSync'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  lastSyncIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'lastSync'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  lastSyncEqualTo(int? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'lastSync', value: value),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  lastSyncGreaterThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'lastSync',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  lastSyncLessThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'lastSync',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  lastSyncBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'lastSync',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  serverIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'server'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  serverIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'server'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  serverEqualTo(String? value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'server',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  serverGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'server',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  serverLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'server',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  serverBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'server',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  serverStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'server',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  serverEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'server',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  serverContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'server',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  serverMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'server',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  serverIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'server', value: ''),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  serverIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'server', value: ''),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  sessionTokenIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'sessionToken'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  sessionTokenIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'sessionToken'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  sessionTokenEqualTo(String? value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'sessionToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  sessionTokenGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'sessionToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  sessionTokenLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'sessionToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  sessionTokenBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'sessionToken',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  sessionTokenStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'sessionToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  sessionTokenEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'sessionToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  sessionTokenContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'sessionToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  sessionTokenMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'sessionToken',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  sessionTokenIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'sessionToken', value: ''),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  sessionTokenIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'sessionToken', value: ''),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  sinceIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'since'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  sinceIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'since'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  sinceEqualTo(int? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'since', value: value),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  sinceGreaterThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'since',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  sinceLessThan(int? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'since',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  sinceBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'since',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncIdIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'syncId'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncIdIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'syncId'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncIdEqualTo(Id? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'syncId', value: value),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncIdGreaterThan(Id? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'syncId',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncIdLessThan(Id? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'syncId',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncIdBetween(
    Id? lower,
    Id? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'syncId',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncModeEqualTo(SyncMode value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'syncMode', value: value),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncModeGreaterThan(SyncMode value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'syncMode',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncModeLessThan(SyncMode value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'syncMode',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncModeBetween(
    SyncMode lower,
    SyncMode upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'syncMode',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncOnEqualTo(bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'syncOn', value: value),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiApiTokenIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'syncYomiApiToken'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiApiTokenIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'syncYomiApiToken'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiApiTokenEqualTo(String? value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'syncYomiApiToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiApiTokenGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'syncYomiApiToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiApiTokenLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'syncYomiApiToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiApiTokenBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'syncYomiApiToken',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiApiTokenStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'syncYomiApiToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiApiTokenEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'syncYomiApiToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiApiTokenContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'syncYomiApiToken',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiApiTokenMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'syncYomiApiToken',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiApiTokenIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'syncYomiApiToken', value: ''),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiApiTokenIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'syncYomiApiToken', value: ''),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiServerIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'syncYomiServer'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiServerIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'syncYomiServer'),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiServerEqualTo(String? value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'syncYomiServer',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiServerGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'syncYomiServer',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiServerLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'syncYomiServer',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiServerBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'syncYomiServer',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiServerStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'syncYomiServer',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiServerEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'syncYomiServer',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiServerContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'syncYomiServer',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiServerMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'syncYomiServer',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiServerIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'syncYomiServer', value: ''),
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterFilterCondition>
  syncYomiServerIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'syncYomiServer', value: ''),
      );
    });
  }
}

extension SyncPreferenceQueryObject
    on QueryBuilder<SyncPreference, SyncPreference, QFilterCondition> {}

extension SyncPreferenceQueryLinks
    on QueryBuilder<SyncPreference, SyncPreference, QFilterCondition> {}

extension SyncPreferenceQuerySortBy
    on QueryBuilder<SyncPreference, SyncPreference, QSortBy> {
  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy> sortByAuthToken() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'authToken', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByAuthTokenDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'authToken', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByAutoSyncFrequency() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'autoSyncFrequency', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByAutoSyncFrequencyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'autoSyncFrequency', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByChimahonDeviceId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonDeviceId', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByChimahonDeviceIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonDeviceId', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByChimahonMediaSelectionGeneration() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonMediaSelectionGeneration', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByChimahonMediaSelectionGenerationDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonMediaSelectionGeneration', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByChimahonMediaSelectionInitialized() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonMediaSelectionInitialized', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByChimahonMediaSelectionInitializedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonMediaSelectionInitialized', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByChimahonMediaSelectionScopeToken() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonMediaSelectionScopeToken', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByChimahonMediaSelectionScopeTokenDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonMediaSelectionScopeToken', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByChimahonMediaSelectionUserSelected() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonMediaSelectionUserSelected', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByChimahonMediaSelectionUserSelectedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonMediaSelectionUserSelected', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByChimahonSyncAnime() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonSyncAnime', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByChimahonSyncAnimeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonSyncAnime', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByChimahonSyncManga() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonSyncManga', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByChimahonSyncMangaDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonSyncManga', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByChimahonSyncNovels() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonSyncNovels', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByChimahonSyncNovelsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonSyncNovels', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByChimahonSyncProvider() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonSyncProvider', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByChimahonSyncProviderDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonSyncProvider', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy> sortByEmail() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'email', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy> sortByEmailDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'email', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByGoogleDriveConnected() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'googleDriveConnected', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByGoogleDriveConnectedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'googleDriveConnected', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy> sortByLastSync() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastSync', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByLastSyncDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastSync', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy> sortByServer() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'server', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortByServerDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'server', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortBySessionToken() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sessionToken', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortBySessionTokenDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sessionToken', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy> sortBySince() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'since', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy> sortBySinceDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'since', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy> sortBySyncMode() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'syncMode', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortBySyncModeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'syncMode', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy> sortBySyncOn() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'syncOn', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortBySyncOnDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'syncOn', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortBySyncYomiApiToken() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'syncYomiApiToken', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortBySyncYomiApiTokenDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'syncYomiApiToken', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortBySyncYomiServer() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'syncYomiServer', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  sortBySyncYomiServerDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'syncYomiServer', Sort.desc);
    });
  }
}

extension SyncPreferenceQuerySortThenBy
    on QueryBuilder<SyncPreference, SyncPreference, QSortThenBy> {
  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy> thenByAuthToken() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'authToken', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByAuthTokenDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'authToken', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByAutoSyncFrequency() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'autoSyncFrequency', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByAutoSyncFrequencyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'autoSyncFrequency', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByChimahonDeviceId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonDeviceId', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByChimahonDeviceIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonDeviceId', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByChimahonMediaSelectionGeneration() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonMediaSelectionGeneration', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByChimahonMediaSelectionGenerationDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonMediaSelectionGeneration', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByChimahonMediaSelectionInitialized() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonMediaSelectionInitialized', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByChimahonMediaSelectionInitializedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonMediaSelectionInitialized', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByChimahonMediaSelectionScopeToken() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonMediaSelectionScopeToken', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByChimahonMediaSelectionScopeTokenDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonMediaSelectionScopeToken', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByChimahonMediaSelectionUserSelected() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonMediaSelectionUserSelected', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByChimahonMediaSelectionUserSelectedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonMediaSelectionUserSelected', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByChimahonSyncAnime() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonSyncAnime', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByChimahonSyncAnimeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonSyncAnime', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByChimahonSyncManga() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonSyncManga', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByChimahonSyncMangaDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonSyncManga', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByChimahonSyncNovels() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonSyncNovels', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByChimahonSyncNovelsDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonSyncNovels', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByChimahonSyncProvider() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonSyncProvider', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByChimahonSyncProviderDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chimahonSyncProvider', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy> thenByEmail() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'email', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy> thenByEmailDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'email', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByGoogleDriveConnected() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'googleDriveConnected', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByGoogleDriveConnectedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'googleDriveConnected', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy> thenByLastSync() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastSync', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByLastSyncDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastSync', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy> thenByServer() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'server', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenByServerDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'server', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenBySessionToken() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sessionToken', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenBySessionTokenDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sessionToken', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy> thenBySince() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'since', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy> thenBySinceDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'since', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy> thenBySyncId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'syncId', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenBySyncIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'syncId', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy> thenBySyncMode() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'syncMode', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenBySyncModeDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'syncMode', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy> thenBySyncOn() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'syncOn', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenBySyncOnDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'syncOn', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenBySyncYomiApiToken() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'syncYomiApiToken', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenBySyncYomiApiTokenDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'syncYomiApiToken', Sort.desc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenBySyncYomiServer() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'syncYomiServer', Sort.asc);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QAfterSortBy>
  thenBySyncYomiServerDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'syncYomiServer', Sort.desc);
    });
  }
}

extension SyncPreferenceQueryWhereDistinct
    on QueryBuilder<SyncPreference, SyncPreference, QDistinct> {
  QueryBuilder<SyncPreference, SyncPreference, QDistinct> distinctByAuthToken({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'authToken', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct>
  distinctByAutoSyncFrequency() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'autoSyncFrequency');
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct>
  distinctByChimahonDeviceId({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(
        r'chimahonDeviceId',
        caseSensitive: caseSensitive,
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct>
  distinctByChimahonMediaSelectionGeneration() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'chimahonMediaSelectionGeneration');
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct>
  distinctByChimahonMediaSelectionInitialized() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'chimahonMediaSelectionInitialized');
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct>
  distinctByChimahonMediaSelectionScopeToken({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(
        r'chimahonMediaSelectionScopeToken',
        caseSensitive: caseSensitive,
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct>
  distinctByChimahonMediaSelectionUserSelected() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'chimahonMediaSelectionUserSelected');
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct>
  distinctByChimahonSyncAnime() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'chimahonSyncAnime');
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct>
  distinctByChimahonSyncManga() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'chimahonSyncManga');
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct>
  distinctByChimahonSyncNovels() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'chimahonSyncNovels');
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct>
  distinctByChimahonSyncProvider() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'chimahonSyncProvider');
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct> distinctByEmail({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'email', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct>
  distinctByGoogleDriveConnected() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'googleDriveConnected');
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct> distinctByLastSync() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'lastSync');
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct> distinctByServer({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'server', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct>
  distinctBySessionToken({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'sessionToken', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct> distinctBySince() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'since');
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct> distinctBySyncMode() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'syncMode');
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct> distinctBySyncOn() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'syncOn');
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct>
  distinctBySyncYomiApiToken({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(
        r'syncYomiApiToken',
        caseSensitive: caseSensitive,
      );
    });
  }

  QueryBuilder<SyncPreference, SyncPreference, QDistinct>
  distinctBySyncYomiServer({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(
        r'syncYomiServer',
        caseSensitive: caseSensitive,
      );
    });
  }
}

extension SyncPreferenceQueryProperty
    on QueryBuilder<SyncPreference, SyncPreference, QQueryProperty> {
  QueryBuilder<SyncPreference, int, QQueryOperations> syncIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'syncId');
    });
  }

  QueryBuilder<SyncPreference, String?, QQueryOperations> authTokenProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'authToken');
    });
  }

  QueryBuilder<SyncPreference, int, QQueryOperations>
  autoSyncFrequencyProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'autoSyncFrequency');
    });
  }

  QueryBuilder<SyncPreference, String?, QQueryOperations>
  chimahonDeviceIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'chimahonDeviceId');
    });
  }

  QueryBuilder<SyncPreference, int, QQueryOperations>
  chimahonMediaSelectionGenerationProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'chimahonMediaSelectionGeneration');
    });
  }

  QueryBuilder<SyncPreference, bool, QQueryOperations>
  chimahonMediaSelectionInitializedProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'chimahonMediaSelectionInitialized');
    });
  }

  QueryBuilder<SyncPreference, String?, QQueryOperations>
  chimahonMediaSelectionScopeTokenProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'chimahonMediaSelectionScopeToken');
    });
  }

  QueryBuilder<SyncPreference, bool, QQueryOperations>
  chimahonMediaSelectionUserSelectedProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'chimahonMediaSelectionUserSelected');
    });
  }

  QueryBuilder<SyncPreference, bool, QQueryOperations>
  chimahonSyncAnimeProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'chimahonSyncAnime');
    });
  }

  QueryBuilder<SyncPreference, bool, QQueryOperations>
  chimahonSyncMangaProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'chimahonSyncManga');
    });
  }

  QueryBuilder<SyncPreference, bool, QQueryOperations>
  chimahonSyncNovelsProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'chimahonSyncNovels');
    });
  }

  QueryBuilder<SyncPreference, ChimahonSyncProvider, QQueryOperations>
  chimahonSyncProviderProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'chimahonSyncProvider');
    });
  }

  QueryBuilder<SyncPreference, String?, QQueryOperations> emailProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'email');
    });
  }

  QueryBuilder<SyncPreference, bool, QQueryOperations>
  googleDriveConnectedProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'googleDriveConnected');
    });
  }

  QueryBuilder<SyncPreference, int?, QQueryOperations> lastSyncProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'lastSync');
    });
  }

  QueryBuilder<SyncPreference, String?, QQueryOperations> serverProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'server');
    });
  }

  QueryBuilder<SyncPreference, String?, QQueryOperations>
  sessionTokenProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'sessionToken');
    });
  }

  QueryBuilder<SyncPreference, int?, QQueryOperations> sinceProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'since');
    });
  }

  QueryBuilder<SyncPreference, SyncMode, QQueryOperations> syncModeProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'syncMode');
    });
  }

  QueryBuilder<SyncPreference, bool, QQueryOperations> syncOnProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'syncOn');
    });
  }

  QueryBuilder<SyncPreference, String?, QQueryOperations>
  syncYomiApiTokenProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'syncYomiApiToken');
    });
  }

  QueryBuilder<SyncPreference, String?, QQueryOperations>
  syncYomiServerProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'syncYomiServer');
    });
  }
}
