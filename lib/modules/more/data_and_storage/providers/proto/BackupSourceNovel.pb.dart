// This is a generated file - do not edit.
//
// Generated from BackupSourceNovel.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

/// Chimahon 2.4 favorites from novel extensions (BackupMihon field 702).
/// Mangatan only reads their identity; the field itself stays an unmodelled
/// pass-through on the wire, so only the fields read here are declared.
class BackupSourceNovel extends $pb.GeneratedMessage {
  factory BackupSourceNovel({
    $fixnum.Int64? source,
    $core.String? url,
    $core.String? title,
    $core.String? author,
  }) {
    final result = create();
    if (source != null) result.source = source;
    if (url != null) result.url = url;
    if (title != null) result.title = title;
    if (author != null) result.author = author;
    return result;
  }

  BackupSourceNovel._();

  factory BackupSourceNovel.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory BackupSourceNovel.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupSourceNovel',
      createEmptyInstance: create)
    ..aInt64(1, _omitFieldNames ? '' : 'source')
    ..aOS(2, _omitFieldNames ? '' : 'url')
    ..aOS(3, _omitFieldNames ? '' : 'title')
    ..aOS(5, _omitFieldNames ? '' : 'author')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BackupSourceNovel clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BackupSourceNovel copyWith(void Function(BackupSourceNovel) updates) =>
      super.copyWith((message) => updates(message as BackupSourceNovel))
          as BackupSourceNovel;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupSourceNovel create() => BackupSourceNovel._();
  @$core.override
  BackupSourceNovel createEmptyInstance() => create();
  static $pb.PbList<BackupSourceNovel> createRepeated() =>
      $pb.PbList<BackupSourceNovel>();
  @$core.pragma('dart2js:noInline')
  static BackupSourceNovel getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupSourceNovel>(create);
  static BackupSourceNovel? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get source => $_getI64(0);
  @$pb.TagNumber(1)
  set source($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSource() => $_has(0);
  @$pb.TagNumber(1)
  void clearSource() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get url => $_getSZ(1);
  @$pb.TagNumber(2)
  set url($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasUrl() => $_has(1);
  @$pb.TagNumber(2)
  void clearUrl() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get title => $_getSZ(2);
  @$pb.TagNumber(3)
  set title($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasTitle() => $_has(2);
  @$pb.TagNumber(3)
  void clearTitle() => $_clearField(3);

  @$pb.TagNumber(5)
  $core.String get author => $_getSZ(3);
  @$pb.TagNumber(5)
  set author($core.String value) => $_setString(3, value);
  @$pb.TagNumber(5)
  $core.bool hasAuthor() => $_has(3);
  @$pb.TagNumber(5)
  void clearAuthor() => $_clearField(5);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
