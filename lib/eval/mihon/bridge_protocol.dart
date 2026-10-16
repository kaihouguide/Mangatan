import 'dart:convert';

import 'package:mangayomi/eval/model/source_preference.dart';
import 'package:mangayomi/models/source.dart';

const mihonBridgeContextKey = '__mangatan_bridge_context__';

/// Controls how preference snapshots sent to the JVM bridge are applied.
///
/// Normal requests only bootstrap keys missing from the bridge's persistent
/// store. An explicit Chimahon restore uses [replacePresent] so values carried
/// by the remote store replace stale bridge values without deleting unknown
/// extension-owned keys.
enum MihonPreferenceApplyMode { bootstrap, replacePresent }

/// Mihon catalogue sources use one-based page numbers.
int mihonCataloguePage(int page) => page < 1 ? 1 : page;

class MihonSourceDescriptor {
  const MihonSourceDescriptor({
    required this.id,
    required this.name,
    required this.lang,
    required this.baseUrl,
  });

  final String id;
  final String name;
  final String lang;
  final String baseUrl;

  factory MihonSourceDescriptor.fromJson(Map<String, dynamic> json) =>
      MihonSourceDescriptor(
        id: json['id'].toString(),
        name: json['name']?.toString() ?? '',
        lang: json['lang']?.toString() ?? 'all',
        baseUrl: json['baseUrl']?.toString() ?? '',
      );
}

enum MihonExtensionItemType { manga, anime }

class MihonExtensionDescriptor {
  const MihonExtensionDescriptor({
    required this.packageName,
    required this.name,
    required this.versionName,
    required this.versionCode,
    required this.lang,
    required this.isNsfw,
    required this.itemType,
    required this.sources,
  });

  final String packageName;
  final String name;
  final String versionName;
  final int versionCode;
  final String lang;
  final bool isNsfw;
  final MihonExtensionItemType itemType;
  final List<MihonSourceDescriptor> sources;

  factory MihonExtensionDescriptor.fromJson(Map<String, dynamic> json) {
    final packageName = json['packageName']?.toString().trim() ?? '';
    final rawSources = json['sources'];
    final sources = (rawSources is List ? rawSources : const [])
        .whereType<Map>()
        .where((source) => source['id'] != null)
        .map(
          (source) => MihonSourceDescriptor.fromJson(
            source.map((key, value) => MapEntry(key.toString(), value)),
          ),
        )
        .toList(growable: false);
    final itemType = switch (json['itemType']?.toString()) {
      'manga' => MihonExtensionItemType.manga,
      'anime' => MihonExtensionItemType.anime,
      final value => throw FormatException(
        'Unsupported Mihon extension type: ${value ?? 'missing'}',
      ),
    };

    if (packageName.isEmpty) {
      throw const FormatException('Mihon extension package name is missing.');
    }
    if (sources.isEmpty) {
      throw const FormatException('The Mihon extension exposes no sources.');
    }

    return MihonExtensionDescriptor(
      packageName: packageName,
      name: json['name']?.toString().trim().isNotEmpty == true
          ? json['name'].toString().trim()
          : packageName,
      versionName: json['versionName']?.toString().trim() ?? '',
      versionCode: switch (json['versionCode']) {
        final int value => value,
        final value => int.tryParse(value?.toString() ?? '') ?? 0,
      },
      lang: json['lang']?.toString() ?? '',
      isNsfw: json['isNsfw'] == true,
      itemType: itemType,
      sources: sources,
    );
  }
}

class MihonSourceMetadata {
  const MihonSourceMetadata({
    required this.sourceId,
    required this.packageName,
    this.factoryAvailable = true,
    this.extensionName,
    this.packageLang,
  });

  final String sourceId;
  final String packageName;
  final bool factoryAvailable;
  final String? extensionName;
  final String? packageLang;

  Map<String, dynamic> toJson() => {
    'mihonSourceId': sourceId,
    'mihonPackage': packageName,
    'mihonFactoryAvailable': factoryAvailable,
    if (extensionName != null) 'mihonExtensionName': extensionName,
    if (packageLang != null) 'mihonPackageLang': packageLang,
  };

  static MihonSourceMetadata? fromAdditionalParams(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      final data = jsonDecode(value) as Map<String, dynamic>;
      final sourceId = data['mihonSourceId']?.toString();
      final packageName = data['mihonPackage']?.toString();
      if (sourceId == null || sourceId.isEmpty) return null;
      return MihonSourceMetadata(
        sourceId: sourceId,
        packageName: packageName ?? '',
        factoryAvailable: data['mihonFactoryAvailable'] as bool? ?? true,
        extensionName: data['mihonExtensionName']?.toString(),
        packageLang: data['mihonPackageLang']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }
}

String encodeMihonSourceMetadata({
  required Object sourceId,
  required String packageName,
  bool factoryAvailable = true,
  String? extensionName,
  String? packageLang,
}) => jsonEncode(
  MihonSourceMetadata(
    sourceId: sourceId.toString(),
    packageName: packageName,
    factoryAvailable: factoryAvailable,
    extensionName: extensionName,
    packageLang: packageLang,
  ).toJson(),
);

int mihonLocalSourceId(Object sourceId) =>
    'mihon-${sourceId.toString()}'.hashCode;

MihonSourceMetadata? mihonSourceMetadata(Source source) =>
    MihonSourceMetadata.fromAdditionalParams(source.additionalParams);

String mihonExtensionGroupKey(Source source) {
  final metadata = mihonSourceMetadata(source);
  final repoUrl = source.repo?.jsonUrl ?? '';
  final package = metadata?.packageName ?? '';
  return '$repoUrl\u0000$package\u0000${source.sourceCodeUrl ?? ''}';
}

bool belongsToSameMihonExtension(Source first, Source second) {
  if (first.sourceCodeLanguage != SourceCodeLanguage.mihon ||
      second.sourceCodeLanguage != SourceCodeLanguage.mihon) {
    return first.id == second.id;
  }
  return mihonExtensionGroupKey(first) == mihonExtensionGroupKey(second);
}

bool isLocallyImportedMihonExtension(Source source) =>
    source.sourceCodeLanguage == SourceCodeLanguage.mihon &&
    Uri.tryParse(source.sourceCodeUrl ?? '')?.scheme == 'mihon-apk';

List<Map<String, dynamic>> mihonPreferencePayload(
  Source source,
  Iterable<SourcePreference> preferences, {
  String? changedPreferenceKey,
  MihonPreferenceApplyMode applyMode = MihonPreferenceApplyMode.bootstrap,
}) {
  final payload = preferences
      .map((preference) => preference.toJson())
      .toList(growable: true);
  final metadata = mihonSourceMetadata(source);
  payload.add({
    'key': mihonBridgeContextKey,
    if (metadata != null) 'sourceId': metadata.sourceId,
    'changedPreferenceKey': ?changedPreferenceKey,
    if (applyMode == MihonPreferenceApplyMode.replacePresent)
      'preferenceApplyMode': 'replace-present',
  });
  return payload;
}

List<SourcePreference> mergeMihonPreferenceValues(
  Iterable<SourcePreference> fresh,
  Iterable<SourcePreference> previous, {
  Set<String> preserveFreshKeys = const {},
}) {
  final previousByKey = {
    for (final preference in previous)
      if (preference.key != null) preference.key!: preference,
  };

  return fresh.map((preference) {
    if (preserveFreshKeys.contains(preference.key)) return preference;
    final oldPreference = previousByKey[preference.key];
    if (oldPreference == null) return preference;

    if (preference.editTextPreference != null &&
        oldPreference.editTextPreference != null) {
      preference.editTextPreference!.value =
          oldPreference.editTextPreference!.value;
      preference.editTextPreference!.text =
          oldPreference.editTextPreference!.text;
    } else if (preference.checkBoxPreference != null &&
        oldPreference.checkBoxPreference != null) {
      preference.checkBoxPreference!.value =
          oldPreference.checkBoxPreference!.value;
    } else if (preference.switchPreferenceCompat != null &&
        oldPreference.switchPreferenceCompat != null) {
      preference.switchPreferenceCompat!.value =
          oldPreference.switchPreferenceCompat!.value;
    } else if (preference.multiSelectListPreference != null &&
        oldPreference.multiSelectListPreference != null) {
      preference.multiSelectListPreference!.values =
          oldPreference.multiSelectListPreference!.values;
    } else if (preference.listPreference != null &&
        oldPreference.listPreference != null) {
      _mergeListPreferenceValue(
        preference.listPreference!,
        oldPreference.listPreference!,
      );
    }
    return preference;
  }).toList();
}

void _mergeListPreferenceValue(ListPreference fresh, ListPreference previous) {
  final oldIndex = previous.valueIndex;
  final oldValues = previous.entryValues ?? const <String>[];
  if (oldIndex == null || oldIndex < 0 || oldIndex >= oldValues.length) return;

  final selectedValue = oldValues[oldIndex];
  final freshIndex = fresh.entryValues?.indexOf(selectedValue) ?? -1;
  if (freshIndex >= 0) fresh.valueIndex = freshIndex;
}
