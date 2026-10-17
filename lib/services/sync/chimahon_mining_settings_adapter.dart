import 'dart:convert';

import 'package:mangayomi/eval/mihon/bridge_protocol.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupPreference.pb.dart';
import 'package:mangayomi/services/hoshidicts/dictionary_storage.dart';
import 'package:mangayomi/services/mining/anki_markers.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';
import 'package:mangayomi/services/mining/dictionary_profile.dart';
import 'package:mangayomi/services/sync/chimahon_preferences.dart';

String? exportChimahonOcrEngine(OcrEnginePreference engine) => switch (engine) {
  OcrEnginePreference.googleLens => 'cloud',
  OcrEnginePreference.appleVision || OcrEnginePreference.screenAi => 'local',
  OcrEnginePreference.automatic ||
  OcrEnginePreference.hayai ||
  OcrEnginePreference.mokuroOnly => null,
};

OcrEnginePreference? importChimahonOcrEngine(
  Object? engine, {
  required OcrHostPlatform platform,
}) => switch (engine) {
  'cloud' => OcrEnginePreference.googleLens,
  // Chimahon 2.4 added Paddle as a second on-device engine. Mangatan's
  // closest equivalent is the same platform engine `local` selects.
  'local' || 'paddle' => localOcrEngineForPlatform(platform),
  _ => null,
};

class ChimahonMiningSettingsProjection {
  ChimahonMiningSettingsProjection({
    required Iterable<BackupPreference> preferences,
    required Iterable<String> unrepresentableKeys,
  }) : preferences = List.unmodifiable(preferences),
       unrepresentableKeys = Set.unmodifiable(unrepresentableKeys);

  final List<BackupPreference> preferences;
  final Set<String> unrepresentableKeys;
}

/// Bridges settings Mangatan already supports. Unsupported Chimahon keys stay
/// in the deferred protobuf payload and are therefore not lost on round-trip.
class ChimahonMiningSettingsAdapter {
  const ChimahonMiningSettingsAdapter({
    this.codec = const ChimahonPreferenceCodec(),
    this.ocrHostPlatform,
  });

  final ChimahonPreferenceCodec codec;
  final OcrHostPlatform? ocrHostPlatform;

  Future<List<BackupPreference>> export({
    DictionaryStorage? dictionaryStorage,
    Set<String> portableSourceIds = const {},
    bool readOnly = false,
  }) async => (await project(
    dictionaryStorage: dictionaryStorage,
    portableSourceIds: portableSourceIds,
    readOnly: readOnly,
  )).preferences;

  Future<ChimahonMiningSettingsProjection> project({
    DictionaryStorage? dictionaryStorage,
    Set<String> portableSourceIds = const {},
    bool readOnly = false,
  }) async {
    final miningSnapshot = readOnly
        ? await MiningPreferences.readOnlySnapshot()
        : null;
    final popup = await MiningPreferences.getDictionaryPopupPreferences(
      readOnly: readOnly,
      snapshot: miningSnapshot,
    );
    final profiles = await MiningPreferences.getDictionaryProfiles(
      readOnly: readOnly,
      snapshot: miningSnapshot,
    );
    final active = await MiningPreferences.getActiveDictionaryProfile(
      readOnly: readOnly,
      snapshot: miningSnapshot,
    );
    final storage = dictionaryStorage ?? DictionaryStorage.instance;
    final installed = readOnly
        ? await storage.installedReadOnly()
        : await storage.installed();
    final installedNames = installed
        .map((dictionary) => dictionary.name)
        .toList();
    final overrides = await MiningPreferences.getDictionaryProfileOverrides(
      readOnly: readOnly,
      snapshot: miningSnapshot,
    );
    final ocrEngine = await MiningPreferences.getOcrEngine(
      readOnly: readOnly,
      snapshot: miningSnapshot,
    );
    final ocrOverlayEnabled = await MiningPreferences.getOcrOverlayEnabled(
      readOnly: readOnly,
      snapshot: miningSnapshot,
    );
    final ocrOutlineVisible = await MiningPreferences.getOcrOutlineVisible(
      readOnly: readOnly,
      snapshot: miningSnapshot,
    );
    final ocrBackgroundOpacity =
        await MiningPreferences.getOcrBackgroundOpacity(
          readOnly: readOnly,
          snapshot: miningSnapshot,
        );
    final ocrBoxScaleX = await MiningPreferences.getOcrBoxScaleX(
      readOnly: readOnly,
      snapshot: miningSnapshot,
    );
    final ocrBoxScaleY = await MiningPreferences.getOcrBoxScaleY(
      readOnly: readOnly,
      snapshot: miningSnapshot,
    );
    final jimakuApiKey = await MiningPreferences.getJimakuApiKey(
      readOnly: readOnly,
      snapshot: miningSnapshot,
    );
    final ocrEngineWire = _exportOcrEngine(ocrEngine);
    final chimahonProfiles = [
      for (final profile in profiles)
        _exportProfile(
          profile,
          dictionaryOrder: profile.dictionaryOrder.isEmpty
              ? installedNames
              : profile.dictionaryOrder,
        ),
    ];

    final preferences = [
      codec.encode(
        'pref_anki_profiles',
        jsonEncode(
          chimahonProfiles.map((profile) => profile.toJson()).toList(),
        ),
      ),
      codec.encode('pref_active_profile_id', active.id),
      codec.encode(
        'pref_dictionary_order',
        (active.dictionaryOrder.isEmpty
                ? installedNames
                : active.dictionaryOrder)
            .join(','),
      ),
      codec.encode('pref_dictionary_popup_width', popup.width.round()),
      codec.encode('pref_dictionary_popup_height', popup.height.round()),
      codec.encode('pref_dictionary_font_size', popup.fontSize.round()),
      codec.encode('pref_dictionary_theme_mode', _exportTheme(popup.theme)),
      codec.encode('pref_dictionary_eink_mode', popup.eInkMode),
      codec.encode(
        'pref_dictionary_paginated_scrolling',
        popup.paginatedScrolling,
      ),
      codec.encode('pref_dictionary_custom_css', popup.customCss),
      codec.encode(
        'pref_dict_show_frequency_harmonic',
        popup.showFrequencyHarmonic,
      ),
      codec.encode(
        'pref_dict_show_frequency_average',
        popup.showFrequencyAverage,
      ),
      codec.encode('pref_dict_show_pitch_number', popup.showPitchNumber),
      codec.encode('pref_dict_show_pitch_text', popup.showPitchText),
      if (jimakuApiKey.isNotEmpty)
        codec.encode('pref_jimaku_api_key', jimakuApiKey),
      if (ocrEngineWire != null) codec.encode('pref_ocr_engine', ocrEngineWire),
      codec.encode('reader_ocr_overlay_enabled', ocrOverlayEnabled),
      codec.encode('reader_ocr_outline_visible', ocrOutlineVisible),
      codec.encode('pref_ocr_box_opacity', ocrBackgroundOpacity),
      codec.encode('pref_ocr_box_scale_x', ocrBoxScaleX),
      codec.encode('pref_ocr_box_scale_y', ocrBoxScaleY),
      if ((ocrBoxScaleX - ocrBoxScaleY).abs() < 0.000001)
        codec.encode('pref_ocr_box_scale', ocrBoxScaleX),
      for (final override in overrides.entries)
        if (_isPortableOverride(override.key, portableSourceIds))
          codec.encode(override.key, override.value),
    ];
    final unrepresentableKeys = <String>{
      if (ocrEngineWire == null) 'pref_ocr_engine',
      if ((ocrBoxScaleX - ocrBoxScaleY).abs() >= 0.000001) 'pref_ocr_box_scale',
    };
    return ChimahonMiningSettingsProjection(
      preferences: preferences,
      unrepresentableKeys: unrepresentableKeys,
    );
  }

  Future<void> import(
    Iterable<BackupPreference> preferences, {
    DictionaryStorage? dictionaryStorage,
    Set<String> portableSourceIds = const {},
    Set<String> preserveLocalKeys = const {},
  }) async {
    final payload = ChimahonSettingsPayload.fromBackup(
      preferences.where(
        (preference) => !preserveLocalKeys.contains(preference.key),
      ),
      codec: codec,
    );
    final localProfiles = {
      for (final profile in await MiningPreferences.getDictionaryProfiles())
        profile.id: profile,
    };
    final importedProfiles = payload.languageProfiles
        .map(
          (profile) =>
              _importProfile(profile, local: localProfiles[profile.id]),
        )
        .where((profile) => profile.id.isNotEmpty)
        .toList(growable: false);
    if (importedProfiles.isNotEmpty) {
      await MiningPreferences.setDictionaryProfiles(
        importedProfiles,
        activeId: payload.activeProfileId,
      );
    }
    // A normal Mihon backup can omit app preferences entirely. Treat the
    // dynamic override keys as an authoritative snapshot only when the
    // Chimahon profile payload itself is present.
    if (payload.preferences.containsKey('pref_anki_profiles')) {
      final currentOverrides =
          await MiningPreferences.getDictionaryProfileOverrides();
      final localOnlyOverrides = {
        for (final entry in currentOverrides.entries)
          if (!_isPortableOverride(entry.key, portableSourceIds))
            entry.key: entry.value,
      };
      final importedPortableOverrides = {
        for (final entry in payload.dictionaryProfileOverrides.entries)
          if (_isPortableOverride(entry.key, portableSourceIds))
            entry.key: entry.value,
      };
      await MiningPreferences.setDictionaryProfileOverrides({
        ...localOnlyOverrides,
        ...importedPortableOverrides,
      });
    }
    final profile = payload.activeLanguageProfile;
    if (profile != null) {
      final current = await MiningPreferences.getAnkiProfile();
      await MiningPreferences.setAnkiProfile(
        current.copyWith(
          ankiEnabled: profile.ankiEnabled,
          deckName: profile.ankiDeck,
          modelName: profile.ankiModel,
          tags: profile.ankiTags
              .split(RegExp(r'[\s,]+'))
              .where((tag) => tag.isNotEmpty)
              .toList(),
          duplicateCheck: profile.ankiDuplicateCheck,
          duplicateScope: current.duplicateScope == 'decks'
              ? 'decks'
              : profile.ankiDuplicateScope,
          syncOnCreate: profile.ankiSyncOnCreate,
          fieldMap: profile.ankiFieldMap,
        ),
      );
      if (profile.dictionaryOrder.isNotEmpty) {
        await (dictionaryStorage ?? DictionaryStorage.instance).reorder(
          profile.dictionaryOrder,
        );
      }
    }

    await _setNumber(
      payload['pref_dictionary_popup_width'],
      MiningPreferences.setDictionaryPopupWidth,
    );
    await _setNumber(
      payload['pref_dictionary_popup_height'],
      MiningPreferences.setDictionaryPopupHeight,
    );
    await _setNumber(
      payload['pref_dictionary_font_size'],
      MiningPreferences.setDictionaryFontSize,
    );
    await _setBool(
      payload['pref_dictionary_eink_mode'],
      MiningPreferences.setDictionaryEInkMode,
    );
    await _setBool(
      payload['pref_dictionary_paginated_scrolling'],
      MiningPreferences.setDictionaryPaginatedScrolling,
    );
    await _setString(
      payload['pref_dictionary_custom_css'],
      MiningPreferences.setDictionaryCustomCss,
    );
    await _setBool(
      payload['pref_dict_show_frequency_harmonic'],
      MiningPreferences.setShowFrequencyHarmonic,
    );
    await _setBool(
      payload['pref_dict_show_frequency_average'],
      MiningPreferences.setShowFrequencyAverage,
    );
    await _setBool(
      payload['pref_dict_show_pitch_number'],
      MiningPreferences.setShowPitchNumber,
    );
    await _setBool(
      payload['pref_dict_show_pitch_text'],
      MiningPreferences.setShowPitchText,
    );
    await _setString(
      payload['pref_jimaku_api_key'],
      MiningPreferences.setJimakuApiKey,
    );

    final theme = payload['pref_dictionary_theme_mode'];
    if (theme is String) {
      final importedTheme = _importTheme(theme);
      if (importedTheme != null) {
        await MiningPreferences.setDictionaryTheme(importedTheme);
      }
    }

    final ocrEngine = _importOcrEngine(payload['pref_ocr_engine']);
    if (ocrEngine != null) {
      await MiningPreferences.setOcrEngine(ocrEngine);
    }
    await _setBool(
      payload['reader_ocr_overlay_enabled'],
      MiningPreferences.setOcrOverlayEnabled,
    );
    await _setBool(
      payload['reader_ocr_outline_visible'],
      MiningPreferences.setOcrOutlineVisible,
    );
    await _setBoundedNumber(
      payload['pref_ocr_box_opacity'],
      minimum: 0,
      maximum: 1,
      setter: MiningPreferences.setOcrBackgroundOpacity,
    );

    final legacyScale = _boundedNumber(
      payload['pref_ocr_box_scale'],
      minimum: 0.8,
      maximum: 1.5,
    );
    final scaleX =
        _boundedNumber(
          payload['pref_ocr_box_scale_x'],
          minimum: 0.8,
          maximum: 1.5,
        ) ??
        legacyScale;
    final scaleY =
        _boundedNumber(
          payload['pref_ocr_box_scale_y'],
          minimum: 0.8,
          maximum: 1.5,
        ) ??
        legacyScale;
    if (scaleX != null) await MiningPreferences.setOcrBoxScaleX(scaleX);
    if (scaleY != null) await MiningPreferences.setOcrBoxScaleY(scaleY);
  }

  bool _isPortableOverride(String key, Set<String> portableSourceIds) {
    if (key.startsWith(
      MiningPreferences.dictionaryProfileNovelOverridePrefix,
    )) {
      return true;
    }
    final sourcePrefix =
        MiningPreferences.dictionaryProfileSourceOverridePrefix;
    return key.startsWith(sourcePrefix) &&
        portableSourceIds.contains(key.substring(sourcePrefix.length));
  }

  Future<void> _setNumber(
    Object? value,
    Future<void> Function(double) setter,
  ) => value is num ? setter(value.toDouble()) : Future.value();

  Future<void> _setBoundedNumber(
    Object? value, {
    required double minimum,
    required double maximum,
    required Future<void> Function(double) setter,
  }) {
    final number = _boundedNumber(value, minimum: minimum, maximum: maximum);
    return number == null ? Future.value() : setter(number);
  }

  double? _boundedNumber(
    Object? value, {
    required double minimum,
    required double maximum,
  }) {
    if (value is! num) return null;
    final number = value.toDouble();
    if (!number.isFinite || number < minimum || number > maximum) return null;
    return number;
  }

  Future<void> _setBool(Object? value, Future<void> Function(bool) setter) =>
      value is bool ? setter(value) : Future.value();

  Future<void> _setString(
    Object? value,
    Future<void> Function(String) setter,
  ) => value is String ? setter(value) : Future.value();

  String _exportTheme(DictionaryThemePreference theme) => switch (theme) {
    DictionaryThemePreference.system => 'system',
    DictionaryThemePreference.light => 'light',
    DictionaryThemePreference.dark => 'dark',
    DictionaryThemePreference.black => 'pure_black',
  };

  DictionaryThemePreference? _importTheme(String theme) => switch (theme) {
    'system' => DictionaryThemePreference.system,
    'light' => DictionaryThemePreference.light,
    'dark' => DictionaryThemePreference.dark,
    'pure_black' => DictionaryThemePreference.black,
    _ => null,
  };

  String? _exportOcrEngine(OcrEnginePreference engine) =>
      exportChimahonOcrEngine(engine);

  OcrEnginePreference? _importOcrEngine(Object? engine) =>
      importChimahonOcrEngine(
        engine,
        platform: ocrHostPlatform ?? currentOcrHostPlatform,
      );

  ChimahonLanguageProfile _exportProfile(
    DictionaryProfile profile, {
    required List<String> dictionaryOrder,
  }) {
    final anki = profile.anki;
    return ChimahonLanguageProfile(
      id: profile.id,
      name: profile.name,
      ankiEnabled: anki.ankiEnabled,
      ankiDeck: anki.deckName,
      ankiModel: anki.modelName,
      ankiFieldMap: anki.fieldMap,
      ankiTags: anki.tags.join(' '),
      ankiDuplicateCheck: anki.duplicateCheck,
      ankiDuplicateScope: anki.duplicateScope == 'decks'
          ? 'deck'
          : anki.duplicateScope,
      ankiDuplicateAction: profile.duplicateAction,
      ankiCropMode: profile.cropMode,
      ankiSyncOnCreate: anki.syncOnCreate,
      dictionaryOrder: dictionaryOrder,
      enabledDictionaries: profile.enabledDictionaries,
      dictionaryCollapseMode: profile.dictionaryCollapseMode,
      dictionaryDisplayModes: profile.dictionaryDisplayModes,
      languageCode: profile.languageCode,
    );
  }

  DictionaryProfile _importProfile(
    ChimahonLanguageProfile profile, {
    DictionaryProfile? local,
  }) {
    final localAnki = local?.anki ?? const AnkiMiningProfile();
    return DictionaryProfile(
      id: profile.id,
      name: profile.name,
      languageCode: profile.languageCode,
      anki: localAnki.copyWith(
        ankiEnabled: profile.ankiEnabled,
        deckName: profile.ankiDeck,
        modelName: profile.ankiModel,
        tags: profile.ankiTags
            .split(RegExp(r'[\s,]+'))
            .where((tag) => tag.isNotEmpty)
            .toList(),
        duplicateCheck: profile.ankiDuplicateCheck,
        duplicateScope: localAnki.duplicateScope == 'decks'
            ? 'decks'
            : profile.ankiDuplicateScope,
        syncOnCreate: profile.ankiSyncOnCreate,
        fieldMap: profile.ankiFieldMap,
      ),
      dictionaryOrder: profile.dictionaryOrder,
      enabledDictionaries: profile.enabledDictionaries,
      dictionaryCollapseMode: profile.dictionaryCollapseMode,
      dictionaryDisplayModes: profile.dictionaryDisplayModes,
      duplicateAction: profile.ankiDuplicateAction,
      cropMode: profile.ankiCropMode,
    );
  }
}

/// Native Mihon source IDs are stable across Mangatan and Chimahon. Other
/// source IDs are local Isar identities and must remain local-only.
Set<String> chimahonPortableSourceOverrideIds(Iterable<Source> sources) => {
  for (final source in sources)
    if (mihonSourceMetadata(source)?.sourceId case final sourceId?)
      if (int.tryParse(sourceId) != null) sourceId,
};
