// This is a generated file - do not edit.
//
// Generated from BackupNovel.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

import 'BackupChapter.pb.dart' as $0;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

class BackupNovel extends $pb.GeneratedMessage {
  factory BackupNovel({
    $core.String? id,
    $core.String? title,
    $core.String? author,
    $core.String? cover,
    $core.int? chapterIndex,
    $core.double? progress,
    $core.int? characterCount,
    $fixnum.Int64? lastModified,
    $core.Iterable<BackupNovelStat>? stats,
    $core.Iterable<$core.String>? categoryIds,
    $core.String? lang,
    $core.Iterable<$0.BackupChapter>? chapters,
    $core.Iterable<BackupNovelHistory>? history,
  }) {
    final result = create();
    if (id != null) result.id = id;
    if (title != null) result.title = title;
    if (author != null) result.author = author;
    if (cover != null) result.cover = cover;
    if (chapterIndex != null) result.chapterIndex = chapterIndex;
    if (progress != null) result.progress = progress;
    if (characterCount != null) result.characterCount = characterCount;
    if (lastModified != null) result.lastModified = lastModified;
    if (stats != null) result.stats.addAll(stats);
    if (categoryIds != null) result.categoryIds.addAll(categoryIds);
    if (lang != null) result.lang = lang;
    if (chapters != null) result.chapters.addAll(chapters);
    if (history != null) result.history.addAll(history);
    return result;
  }

  BackupNovel._();

  factory BackupNovel.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory BackupNovel.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupNovel',
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'id')
    ..aOS(2, _omitFieldNames ? '' : 'title')
    ..aOS(3, _omitFieldNames ? '' : 'author')
    ..aOS(4, _omitFieldNames ? '' : 'cover')
    ..aI(5, _omitFieldNames ? '' : 'chapterIndex', protoName: 'chapterIndex')
    ..aD(6, _omitFieldNames ? '' : 'progress')
    ..aI(7, _omitFieldNames ? '' : 'characterCount',
        protoName: 'characterCount')
    ..aInt64(8, _omitFieldNames ? '' : 'lastModified',
        protoName: 'lastModified')
    ..pPM<BackupNovelStat>(9, _omitFieldNames ? '' : 'stats',
        subBuilder: BackupNovelStat.create)
    ..pPS(10, _omitFieldNames ? '' : 'categoryIds', protoName: 'categoryIds')
    ..aOS(11, _omitFieldNames ? '' : 'lang')
    ..pPM<$0.BackupChapter>(12, _omitFieldNames ? '' : 'chapters',
        subBuilder: $0.BackupChapter.create)
    ..pPM<BackupNovelHistory>(13, _omitFieldNames ? '' : 'history',
        subBuilder: BackupNovelHistory.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BackupNovel clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BackupNovel copyWith(void Function(BackupNovel) updates) =>
      super.copyWith((message) => updates(message as BackupNovel))
          as BackupNovel;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupNovel create() => BackupNovel._();
  @$core.override
  BackupNovel createEmptyInstance() => create();
  static $pb.PbList<BackupNovel> createRepeated() => $pb.PbList<BackupNovel>();
  @$core.pragma('dart2js:noInline')
  static BackupNovel getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupNovel>(create);
  static BackupNovel? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get id => $_getSZ(0);
  @$pb.TagNumber(1)
  set id($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasId() => $_has(0);
  @$pb.TagNumber(1)
  void clearId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get title => $_getSZ(1);
  @$pb.TagNumber(2)
  set title($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasTitle() => $_has(1);
  @$pb.TagNumber(2)
  void clearTitle() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get author => $_getSZ(2);
  @$pb.TagNumber(3)
  set author($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasAuthor() => $_has(2);
  @$pb.TagNumber(3)
  void clearAuthor() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get cover => $_getSZ(3);
  @$pb.TagNumber(4)
  set cover($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasCover() => $_has(3);
  @$pb.TagNumber(4)
  void clearCover() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.int get chapterIndex => $_getIZ(4);
  @$pb.TagNumber(5)
  set chapterIndex($core.int value) => $_setSignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasChapterIndex() => $_has(4);
  @$pb.TagNumber(5)
  void clearChapterIndex() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.double get progress => $_getN(5);
  @$pb.TagNumber(6)
  set progress($core.double value) => $_setDouble(5, value);
  @$pb.TagNumber(6)
  $core.bool hasProgress() => $_has(5);
  @$pb.TagNumber(6)
  void clearProgress() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.int get characterCount => $_getIZ(6);
  @$pb.TagNumber(7)
  set characterCount($core.int value) => $_setSignedInt32(6, value);
  @$pb.TagNumber(7)
  $core.bool hasCharacterCount() => $_has(6);
  @$pb.TagNumber(7)
  void clearCharacterCount() => $_clearField(7);

  @$pb.TagNumber(8)
  $fixnum.Int64 get lastModified => $_getI64(7);
  @$pb.TagNumber(8)
  set lastModified($fixnum.Int64 value) => $_setInt64(7, value);
  @$pb.TagNumber(8)
  $core.bool hasLastModified() => $_has(7);
  @$pb.TagNumber(8)
  void clearLastModified() => $_clearField(8);

  @$pb.TagNumber(9)
  $pb.PbList<BackupNovelStat> get stats => $_getList(8);

  @$pb.TagNumber(10)
  $pb.PbList<$core.String> get categoryIds => $_getList(9);

  @$pb.TagNumber(11)
  $core.String get lang => $_getSZ(10);
  @$pb.TagNumber(11)
  set lang($core.String value) => $_setString(10, value);
  @$pb.TagNumber(11)
  $core.bool hasLang() => $_has(10);
  @$pb.TagNumber(11)
  void clearLang() => $_clearField(11);

  /// Chimahon 2.4 database-backed books carry their chapter rows and reading
  /// history. Mangatan does not model them, but must carry them losslessly.
  @$pb.TagNumber(12)
  $pb.PbList<$0.BackupChapter> get chapters => $_getList(11);

  @$pb.TagNumber(13)
  $pb.PbList<BackupNovelHistory> get history => $_getList(12);
}

class BackupNovelHistory extends $pb.GeneratedMessage {
  factory BackupNovelHistory({
    $core.String? chapterUrl,
    $fixnum.Int64? lastRead,
    $fixnum.Int64? timeRead,
  }) {
    final result = create();
    if (chapterUrl != null) result.chapterUrl = chapterUrl;
    if (lastRead != null) result.lastRead = lastRead;
    if (timeRead != null) result.timeRead = timeRead;
    return result;
  }

  BackupNovelHistory._();

  factory BackupNovelHistory.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory BackupNovelHistory.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupNovelHistory',
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'chapterUrl', protoName: 'chapterUrl')
    ..aInt64(2, _omitFieldNames ? '' : 'lastRead', protoName: 'lastRead')
    ..aInt64(3, _omitFieldNames ? '' : 'timeRead', protoName: 'timeRead')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BackupNovelHistory clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BackupNovelHistory copyWith(void Function(BackupNovelHistory) updates) =>
      super.copyWith((message) => updates(message as BackupNovelHistory))
          as BackupNovelHistory;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupNovelHistory create() => BackupNovelHistory._();
  @$core.override
  BackupNovelHistory createEmptyInstance() => create();
  static $pb.PbList<BackupNovelHistory> createRepeated() =>
      $pb.PbList<BackupNovelHistory>();
  @$core.pragma('dart2js:noInline')
  static BackupNovelHistory getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupNovelHistory>(create);
  static BackupNovelHistory? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get chapterUrl => $_getSZ(0);
  @$pb.TagNumber(1)
  set chapterUrl($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasChapterUrl() => $_has(0);
  @$pb.TagNumber(1)
  void clearChapterUrl() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get lastRead => $_getI64(1);
  @$pb.TagNumber(2)
  set lastRead($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasLastRead() => $_has(1);
  @$pb.TagNumber(2)
  void clearLastRead() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get timeRead => $_getI64(2);
  @$pb.TagNumber(3)
  set timeRead($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasTimeRead() => $_has(2);
  @$pb.TagNumber(3)
  void clearTimeRead() => $_clearField(3);
}

class BackupNovelCategory extends $pb.GeneratedMessage {
  factory BackupNovelCategory({
    $core.String? id,
    $core.String? name,
    $fixnum.Int64? order,
    $fixnum.Int64? flags,
  }) {
    final result = create();
    if (id != null) result.id = id;
    if (name != null) result.name = name;
    if (order != null) result.order = order;
    if (flags != null) result.flags = flags;
    return result;
  }

  BackupNovelCategory._();

  factory BackupNovelCategory.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory BackupNovelCategory.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupNovelCategory',
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'id')
    ..aOS(2, _omitFieldNames ? '' : 'name')
    ..aInt64(3, _omitFieldNames ? '' : 'order')
    ..aInt64(4, _omitFieldNames ? '' : 'flags')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BackupNovelCategory clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BackupNovelCategory copyWith(void Function(BackupNovelCategory) updates) =>
      super.copyWith((message) => updates(message as BackupNovelCategory))
          as BackupNovelCategory;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupNovelCategory create() => BackupNovelCategory._();
  @$core.override
  BackupNovelCategory createEmptyInstance() => create();
  static $pb.PbList<BackupNovelCategory> createRepeated() =>
      $pb.PbList<BackupNovelCategory>();
  @$core.pragma('dart2js:noInline')
  static BackupNovelCategory getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupNovelCategory>(create);
  static BackupNovelCategory? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get id => $_getSZ(0);
  @$pb.TagNumber(1)
  set id($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasId() => $_has(0);
  @$pb.TagNumber(1)
  void clearId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get name => $_getSZ(1);
  @$pb.TagNumber(2)
  set name($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasName() => $_has(1);
  @$pb.TagNumber(2)
  void clearName() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get order => $_getI64(2);
  @$pb.TagNumber(3)
  set order($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasOrder() => $_has(2);
  @$pb.TagNumber(3)
  void clearOrder() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get flags => $_getI64(3);
  @$pb.TagNumber(4)
  set flags($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasFlags() => $_has(3);
  @$pb.TagNumber(4)
  void clearFlags() => $_clearField(4);
}

class BackupNovelStat extends $pb.GeneratedMessage {
  factory BackupNovelStat({
    $core.String? dateKey,
    $core.int? charactersRead,
    $core.double? readingTime,
    $core.int? minReadingSpeed,
    $core.int? altMinReadingSpeed,
    $core.int? lastReadingSpeed,
    $core.int? maxReadingSpeed,
    $fixnum.Int64? lastStatisticModified,
  }) {
    final result = create();
    if (dateKey != null) result.dateKey = dateKey;
    if (charactersRead != null) result.charactersRead = charactersRead;
    if (readingTime != null) result.readingTime = readingTime;
    if (minReadingSpeed != null) result.minReadingSpeed = minReadingSpeed;
    if (altMinReadingSpeed != null)
      result.altMinReadingSpeed = altMinReadingSpeed;
    if (lastReadingSpeed != null) result.lastReadingSpeed = lastReadingSpeed;
    if (maxReadingSpeed != null) result.maxReadingSpeed = maxReadingSpeed;
    if (lastStatisticModified != null)
      result.lastStatisticModified = lastStatisticModified;
    return result;
  }

  BackupNovelStat._();

  factory BackupNovelStat.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory BackupNovelStat.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupNovelStat',
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'dateKey', protoName: 'dateKey')
    ..aI(2, _omitFieldNames ? '' : 'charactersRead',
        protoName: 'charactersRead')
    ..aD(3, _omitFieldNames ? '' : 'readingTime', protoName: 'readingTime')
    ..aI(4, _omitFieldNames ? '' : 'minReadingSpeed',
        protoName: 'minReadingSpeed')
    ..aI(5, _omitFieldNames ? '' : 'altMinReadingSpeed',
        protoName: 'altMinReadingSpeed')
    ..aI(6, _omitFieldNames ? '' : 'lastReadingSpeed',
        protoName: 'lastReadingSpeed')
    ..aI(7, _omitFieldNames ? '' : 'maxReadingSpeed',
        protoName: 'maxReadingSpeed')
    ..aInt64(8, _omitFieldNames ? '' : 'lastStatisticModified',
        protoName: 'lastStatisticModified')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BackupNovelStat clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BackupNovelStat copyWith(void Function(BackupNovelStat) updates) =>
      super.copyWith((message) => updates(message as BackupNovelStat))
          as BackupNovelStat;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupNovelStat create() => BackupNovelStat._();
  @$core.override
  BackupNovelStat createEmptyInstance() => create();
  static $pb.PbList<BackupNovelStat> createRepeated() =>
      $pb.PbList<BackupNovelStat>();
  @$core.pragma('dart2js:noInline')
  static BackupNovelStat getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupNovelStat>(create);
  static BackupNovelStat? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get dateKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set dateKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDateKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearDateKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get charactersRead => $_getIZ(1);
  @$pb.TagNumber(2)
  set charactersRead($core.int value) => $_setSignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasCharactersRead() => $_has(1);
  @$pb.TagNumber(2)
  void clearCharactersRead() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.double get readingTime => $_getN(2);
  @$pb.TagNumber(3)
  set readingTime($core.double value) => $_setDouble(2, value);
  @$pb.TagNumber(3)
  $core.bool hasReadingTime() => $_has(2);
  @$pb.TagNumber(3)
  void clearReadingTime() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.int get minReadingSpeed => $_getIZ(3);
  @$pb.TagNumber(4)
  set minReadingSpeed($core.int value) => $_setSignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasMinReadingSpeed() => $_has(3);
  @$pb.TagNumber(4)
  void clearMinReadingSpeed() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.int get altMinReadingSpeed => $_getIZ(4);
  @$pb.TagNumber(5)
  set altMinReadingSpeed($core.int value) => $_setSignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasAltMinReadingSpeed() => $_has(4);
  @$pb.TagNumber(5)
  void clearAltMinReadingSpeed() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.int get lastReadingSpeed => $_getIZ(5);
  @$pb.TagNumber(6)
  set lastReadingSpeed($core.int value) => $_setSignedInt32(5, value);
  @$pb.TagNumber(6)
  $core.bool hasLastReadingSpeed() => $_has(5);
  @$pb.TagNumber(6)
  void clearLastReadingSpeed() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.int get maxReadingSpeed => $_getIZ(6);
  @$pb.TagNumber(7)
  set maxReadingSpeed($core.int value) => $_setSignedInt32(6, value);
  @$pb.TagNumber(7)
  $core.bool hasMaxReadingSpeed() => $_has(6);
  @$pb.TagNumber(7)
  void clearMaxReadingSpeed() => $_clearField(7);

  @$pb.TagNumber(8)
  $fixnum.Int64 get lastStatisticModified => $_getI64(7);
  @$pb.TagNumber(8)
  set lastStatisticModified($fixnum.Int64 value) => $_setInt64(7, value);
  @$pb.TagNumber(8)
  $core.bool hasLastStatisticModified() => $_has(7);
  @$pb.TagNumber(8)
  void clearLastStatisticModified() => $_clearField(8);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
