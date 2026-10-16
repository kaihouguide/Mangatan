// This is a generated file - do not edit.
//
// Generated from BackupNovel.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use backupNovelDescriptor instead')
const BackupNovel$json = {
  '1': 'BackupNovel',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 9, '10': 'id'},
    {'1': 'title', '3': 2, '4': 1, '5': 9, '10': 'title'},
    {'1': 'author', '3': 3, '4': 1, '5': 9, '9': 0, '10': 'author', '17': true},
    {'1': 'cover', '3': 4, '4': 1, '5': 9, '9': 1, '10': 'cover', '17': true},
    {'1': 'chapterIndex', '3': 5, '4': 1, '5': 5, '10': 'chapterIndex'},
    {'1': 'progress', '3': 6, '4': 1, '5': 1, '10': 'progress'},
    {'1': 'characterCount', '3': 7, '4': 1, '5': 5, '10': 'characterCount'},
    {'1': 'lastModified', '3': 8, '4': 1, '5': 3, '10': 'lastModified'},
    {
      '1': 'stats',
      '3': 9,
      '4': 3,
      '5': 11,
      '6': '.BackupNovelStat',
      '10': 'stats'
    },
    {'1': 'categoryIds', '3': 10, '4': 3, '5': 9, '10': 'categoryIds'},
    {'1': 'lang', '3': 11, '4': 1, '5': 9, '9': 2, '10': 'lang', '17': true},
    {
      '1': 'chapters',
      '3': 12,
      '4': 3,
      '5': 11,
      '6': '.BackupChapter',
      '10': 'chapters'
    },
    {
      '1': 'history',
      '3': 13,
      '4': 3,
      '5': 11,
      '6': '.BackupNovelHistory',
      '10': 'history'
    },
  ],
  '8': [
    {'1': '_author'},
    {'1': '_cover'},
    {'1': '_lang'},
  ],
};

/// Descriptor for `BackupNovel`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupNovelDescriptor = $convert.base64Decode(
    'CgtCYWNrdXBOb3ZlbBIOCgJpZBgBIAEoCVICaWQSFAoFdGl0bGUYAiABKAlSBXRpdGxlEhsKBm'
    'F1dGhvchgDIAEoCUgAUgZhdXRob3KIAQESGQoFY292ZXIYBCABKAlIAVIFY292ZXKIAQESIgoM'
    'Y2hhcHRlckluZGV4GAUgASgFUgxjaGFwdGVySW5kZXgSGgoIcHJvZ3Jlc3MYBiABKAFSCHByb2'
    'dyZXNzEiYKDmNoYXJhY3RlckNvdW50GAcgASgFUg5jaGFyYWN0ZXJDb3VudBIiCgxsYXN0TW9k'
    'aWZpZWQYCCABKANSDGxhc3RNb2RpZmllZBImCgVzdGF0cxgJIAMoCzIQLkJhY2t1cE5vdmVsU3'
    'RhdFIFc3RhdHMSIAoLY2F0ZWdvcnlJZHMYCiADKAlSC2NhdGVnb3J5SWRzEhcKBGxhbmcYCyAB'
    'KAlIAlIEbGFuZ4gBARIqCghjaGFwdGVycxgMIAMoCzIOLkJhY2t1cENoYXB0ZXJSCGNoYXB0ZX'
    'JzEi0KB2hpc3RvcnkYDSADKAsyEy5CYWNrdXBOb3ZlbEhpc3RvcnlSB2hpc3RvcnlCCQoHX2F1'
    'dGhvckIICgZfY292ZXJCBwoFX2xhbmc=');

@$core.Deprecated('Use backupNovelHistoryDescriptor instead')
const BackupNovelHistory$json = {
  '1': 'BackupNovelHistory',
  '2': [
    {'1': 'chapterUrl', '3': 1, '4': 1, '5': 9, '10': 'chapterUrl'},
    {'1': 'lastRead', '3': 2, '4': 1, '5': 3, '10': 'lastRead'},
    {'1': 'timeRead', '3': 3, '4': 1, '5': 3, '10': 'timeRead'},
  ],
};

/// Descriptor for `BackupNovelHistory`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupNovelHistoryDescriptor = $convert.base64Decode(
    'ChJCYWNrdXBOb3ZlbEhpc3RvcnkSHgoKY2hhcHRlclVybBgBIAEoCVIKY2hhcHRlclVybBIaCg'
    'hsYXN0UmVhZBgCIAEoA1IIbGFzdFJlYWQSGgoIdGltZVJlYWQYAyABKANSCHRpbWVSZWFk');

@$core.Deprecated('Use backupNovelCategoryDescriptor instead')
const BackupNovelCategory$json = {
  '1': 'BackupNovelCategory',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 9, '10': 'id'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {'1': 'order', '3': 3, '4': 1, '5': 3, '10': 'order'},
    {'1': 'flags', '3': 4, '4': 1, '5': 3, '10': 'flags'},
  ],
};

/// Descriptor for `BackupNovelCategory`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupNovelCategoryDescriptor = $convert.base64Decode(
    'ChNCYWNrdXBOb3ZlbENhdGVnb3J5Eg4KAmlkGAEgASgJUgJpZBISCgRuYW1lGAIgASgJUgRuYW'
    '1lEhQKBW9yZGVyGAMgASgDUgVvcmRlchIUCgVmbGFncxgEIAEoA1IFZmxhZ3M=');

@$core.Deprecated('Use backupNovelStatDescriptor instead')
const BackupNovelStat$json = {
  '1': 'BackupNovelStat',
  '2': [
    {'1': 'dateKey', '3': 1, '4': 1, '5': 9, '10': 'dateKey'},
    {'1': 'charactersRead', '3': 2, '4': 1, '5': 5, '10': 'charactersRead'},
    {'1': 'readingTime', '3': 3, '4': 1, '5': 1, '10': 'readingTime'},
    {'1': 'minReadingSpeed', '3': 4, '4': 1, '5': 5, '10': 'minReadingSpeed'},
    {
      '1': 'altMinReadingSpeed',
      '3': 5,
      '4': 1,
      '5': 5,
      '10': 'altMinReadingSpeed'
    },
    {'1': 'lastReadingSpeed', '3': 6, '4': 1, '5': 5, '10': 'lastReadingSpeed'},
    {'1': 'maxReadingSpeed', '3': 7, '4': 1, '5': 5, '10': 'maxReadingSpeed'},
    {
      '1': 'lastStatisticModified',
      '3': 8,
      '4': 1,
      '5': 3,
      '10': 'lastStatisticModified'
    },
  ],
};

/// Descriptor for `BackupNovelStat`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupNovelStatDescriptor = $convert.base64Decode(
    'Cg9CYWNrdXBOb3ZlbFN0YXQSGAoHZGF0ZUtleRgBIAEoCVIHZGF0ZUtleRImCg5jaGFyYWN0ZX'
    'JzUmVhZBgCIAEoBVIOY2hhcmFjdGVyc1JlYWQSIAoLcmVhZGluZ1RpbWUYAyABKAFSC3JlYWRp'
    'bmdUaW1lEigKD21pblJlYWRpbmdTcGVlZBgEIAEoBVIPbWluUmVhZGluZ1NwZWVkEi4KEmFsdE'
    '1pblJlYWRpbmdTcGVlZBgFIAEoBVISYWx0TWluUmVhZGluZ1NwZWVkEioKEGxhc3RSZWFkaW5n'
    'U3BlZWQYBiABKAVSEGxhc3RSZWFkaW5nU3BlZWQSKAoPbWF4UmVhZGluZ1NwZWVkGAcgASgFUg'
    '9tYXhSZWFkaW5nU3BlZWQSNAoVbGFzdFN0YXRpc3RpY01vZGlmaWVkGAggASgDUhVsYXN0U3Rh'
    'dGlzdGljTW9kaWZpZWQ=');
