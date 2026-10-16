import 'package:flutter/foundation.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';

class SubtitleRegexFilterOptions {
  const SubtitleRegexFilterOptions({
    this.removeSpeakerNames = false,
    this.mergeMultiline = false,
    this.removeBracketedText = false,
    this.removeUppercaseLines = false,
    this.removeMusicSymbols = false,
    this.removeCurlyBracedText = false,
    this.customRegexEnabled = false,
    this.customRegexPattern = '',
  });

  final bool removeSpeakerNames;
  final bool mergeMultiline;
  final bool removeBracketedText;
  final bool removeUppercaseLines;
  final bool removeMusicSymbols;
  final bool removeCurlyBracedText;
  final bool customRegexEnabled;
  final String customRegexPattern;

  bool get enabled =>
      removeSpeakerNames ||
      mergeMultiline ||
      removeBracketedText ||
      removeUppercaseLines ||
      removeMusicSymbols ||
      removeCurlyBracedText ||
      (customRegexEnabled && customRegexPattern.trim().isNotEmpty);

  SubtitleRegexFilterOptions copyWith({
    bool? removeSpeakerNames,
    bool? mergeMultiline,
    bool? removeBracketedText,
    bool? removeUppercaseLines,
    bool? removeMusicSymbols,
    bool? removeCurlyBracedText,
    bool? customRegexEnabled,
    String? customRegexPattern,
  }) => SubtitleRegexFilterOptions(
    removeSpeakerNames: removeSpeakerNames ?? this.removeSpeakerNames,
    mergeMultiline: mergeMultiline ?? this.mergeMultiline,
    removeBracketedText: removeBracketedText ?? this.removeBracketedText,
    removeUppercaseLines: removeUppercaseLines ?? this.removeUppercaseLines,
    removeMusicSymbols: removeMusicSymbols ?? this.removeMusicSymbols,
    removeCurlyBracedText: removeCurlyBracedText ?? this.removeCurlyBracedText,
    customRegexEnabled: customRegexEnabled ?? this.customRegexEnabled,
    customRegexPattern: customRegexPattern ?? this.customRegexPattern,
  );

  factory SubtitleRegexFilterOptions.fromJson(Map<String, dynamic> json) =>
      SubtitleRegexFilterOptions(
        removeSpeakerNames: json['removeSpeakerNames'] == true,
        mergeMultiline: json['mergeMultiline'] == true,
        removeBracketedText: json['removeBracketedText'] == true,
        removeUppercaseLines: json['removeUppercaseLines'] == true,
        removeMusicSymbols: json['removeMusicSymbols'] == true,
        removeCurlyBracedText: json['removeCurlyBracedText'] == true,
        customRegexEnabled: json['customRegexEnabled'] == true,
        customRegexPattern: json['customRegexPattern']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => {
    'removeSpeakerNames': removeSpeakerNames,
    'mergeMultiline': mergeMultiline,
    'removeBracketedText': removeBracketedText,
    'removeUppercaseLines': removeUppercaseLines,
    'removeMusicSymbols': removeMusicSymbols,
    'removeCurlyBracedText': removeCurlyBracedText,
    'customRegexEnabled': customRegexEnabled,
    'customRegexPattern': customRegexPattern,
  };
}

class SubtitleRegexFilterState {
  SubtitleRegexFilterState._();

  static final options = ValueNotifier(const SubtitleRegexFilterOptions());
  static bool _initialized = false;
  static Future<void>? _initializing;

  static Future<void> initialize() async {
    if (_initialized) return;
    if (_initializing != null) return _initializing;
    final operation = _load();
    _initializing = operation;
    try {
      await operation;
    } finally {
      _initializing = null;
    }
  }

  static Future<void> _load() async {
    options.value = SubtitleRegexFilterOptions.fromJson(
      await MiningPreferences.getSubtitleRegexFilters(),
    );
    _initialized = true;
  }

  static Future<void> set(SubtitleRegexFilterOptions value) async {
    options.value = value;
    _initialized = true;
    await MiningPreferences.setSubtitleRegexFilters(value.toJson());
  }
}

final _speakerNamePattern = RegExp(
  r'^(\s*(?:[-–—―－]\s*)?)[(（][^()（）\r\n]{1,48}[)）]\s*:?\s*',
  multiLine: true,
);
final _bracketedTextPattern = RegExp(r'\[[^\[\]\n]*\]');
final _curlyBracedTextPattern = RegExp(r'\{[^{}\n]*\}');
final _musicSymbolPattern = RegExp(r'[♪♫♬♩♭♯#~〜～]+');
final _lineBreakPattern = RegExp(r'\r?\n');
final _inlineWhitespacePattern = RegExp(r'[ \t]+');
final _subtitlePunctuationPattern = RegExp(
  r'[\[\]{}()♪♫♬♩♭♯#~〜～:;,.!?…\-–—―－]',
);

// Subtitles are filtered on every rebuild; keep the user's pattern compiled.
String? _customPatternSource;
RegExp? _customPattern;

RegExp? _compiledCustomPattern(String source) {
  if (source != _customPatternSource) {
    _customPatternSource = source;
    try {
      _customPattern = RegExp(source, multiLine: true);
    } on FormatException {
      // Preserve subtitles when a custom pattern is temporarily invalid.
      _customPattern = null;
    }
  }
  return _customPattern;
}

String applySubtitleRegexFilters(
  String input,
  SubtitleRegexFilterOptions options,
) {
  if (!options.enabled) return input;
  var result = input;
  if (options.removeSpeakerNames) {
    result = result.replaceAllMapped(
      _speakerNamePattern,
      (match) => match.group(1) ?? '',
    );
  }
  if (options.removeBracketedText) {
    result = result.replaceAll(_bracketedTextPattern, '');
  }
  if (options.removeCurlyBracedText) {
    result = result.replaceAll(_curlyBracedTextPattern, '');
  }
  if (options.removeMusicSymbols) {
    result = result.replaceAll(_musicSymbolPattern, '');
  }
  if (options.customRegexEnabled &&
      options.customRegexPattern.trim().isNotEmpty) {
    final customPattern = _compiledCustomPattern(options.customRegexPattern);
    if (customPattern != null) {
      result = result.replaceAll(customPattern, '');
    }
  }
  final lines = result
      .split(_lineBreakPattern)
      .map((line) => line.trim().replaceAll(_inlineWhitespacePattern, ' '))
      .where(
        (line) =>
            line.isNotEmpty &&
            (!options.removeUppercaseLines || !_isAllUppercase(line)),
      )
      .where((line) => line.runes.any(_isLetterOrDigit))
      .toList(growable: false);
  return lines.join(options.mergeMultiline ? ' ' : '\n');
}

bool _isAllUppercase(String line) {
  final letters = line.runes
      .map(String.fromCharCode)
      .where((character) => character.toUpperCase() != character.toLowerCase())
      .toList(growable: false);
  return letters.isNotEmpty &&
      letters.every((character) => character == character.toUpperCase());
}

bool _isLetterOrDigit(int rune) {
  final character = String.fromCharCode(rune);
  if (rune >= 0x30 && rune <= 0x39) return true;
  if (character.toUpperCase() != character.toLowerCase()) return true;
  return rune > 0x7f &&
      character.trim().isNotEmpty &&
      !_subtitlePunctuationPattern.hasMatch(character);
}
