import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mangayomi/eval/model/m_bridge.dart';
import 'package:mangayomi/modules/more/settings/dictionary/dictionary_settings_section.dart';
import 'package:mangayomi/modules/more/settings/dictionary/widgets/edit_text_dialog.dart';
import 'package:mangayomi/modules/mining/reader_lookup_trigger.dart';
import 'package:mangayomi/modules/mining/widgets/dictionary_lookup_history_sheet.dart';
import 'package:mangayomi/modules/mining/widgets/mining_lookup_sheet.dart';
import 'package:mangayomi/modules/mining/widgets/ocr_processing_queue_sheet.dart';
import 'package:mangayomi/services/hoshidicts/dictionary_languages.dart';
import 'package:mangayomi/services/hoshidicts/dictionary_storage.dart';
import 'package:mangayomi/services/hoshidicts/hoshidicts_backend.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';
import 'package:mangayomi/modules/mining/widgets/reader_ocr_overlay.dart';
import 'package:mangayomi/services/mining/anki_connect_service.dart';
import 'package:mangayomi/services/mining/anki_mobile_service.dart';
import 'package:mangayomi/services/mining/anki_markers.dart';
import 'package:mangayomi/services/mining/dictionary_update_service.dart';
import 'package:mangayomi/services/mining/dictionary_profile.dart';
import 'package:mangayomi/services/mining/mining_models.dart';
import 'package:mangayomi/services/mining/ocr_processing_queue.dart';
import 'package:mangayomi/services/mining/screen_ai_component_manager.dart';
import 'package:mangayomi/services/mining/screen_ai_ocr.dart';
import 'package:mangayomi/utils/platform_utils.dart';
import 'package:path/path.dart' as p;

class DictionaryScreen extends StatefulWidget {
  const DictionaryScreen({
    super.key,
    this.section = DictionarySettingsSection.dictionariesAndAudio,
  });

  final DictionarySettingsSection section;

  @override
  State<DictionaryScreen> createState() => _DictionaryScreenState();
}

@visibleForTesting
List<String> dictionaryZipPaths(Iterable<String> paths) => paths
    .where((path) => path.toLowerCase().endsWith('.zip'))
    .toList(growable: false);

class DictionaryZipDropTarget extends StatefulWidget {
  const DictionaryZipDropTarget({
    super.key,
    required this.enabled,
    required this.onImport,
    required this.child,
  });

  final bool enabled;
  final Future<void> Function(List<String> paths) onImport;
  final Widget child;

  @override
  State<DictionaryZipDropTarget> createState() =>
      _DictionaryZipDropTargetState();
}

class _DictionaryZipDropTargetState extends State<DictionaryZipDropTarget> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    if (!isDesktop) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    return DropTarget(
      enable: widget.enabled,
      onDragEntered: (_) {
        if (widget.enabled) setState(() => _dragging = true);
      },
      onDragExited: (_) {
        if (_dragging) setState(() => _dragging = false);
      },
      onDragDone: (details) async {
        final paths = dictionaryZipPaths(
          details.files.whereType<DropItemFile>().map((file) => file.path),
        );
        if (mounted) setState(() => _dragging = false);
        if (paths.isEmpty) {
          botToast('Drop one or more Yomitan ZIP files.');
          return;
        }
        await widget.onImport(paths);
      },
      child: AnimatedContainer(
        key: const ValueKey('dictionary-zip-drop-highlight'),
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: _dragging
              ? scheme.primaryContainer.withValues(alpha: 0.55)
              : Colors.transparent,
          border: _dragging
              ? Border.all(color: scheme.primary, width: 2)
              : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: widget.child,
      ),
    );
  }
}

class _DictionaryScreenState extends State<DictionaryScreen> {
  List<InstalledDictionary> _dictionaries = const [];
  List<DictionaryProfile> _profiles = const [];
  DictionaryProfile _activeProfile = const DictionaryProfile(
    id: 'mangatan-default',
    name: 'Default',
  );
  OcrEnginePreference _engine = OcrEnginePreference.automatic;
  int _parallelOcrLimit = 1;
  bool _mokuroWebsiteOcrEnabled = true;
  String _dictionaryLanguage = 'ja';
  double _backgroundOpacity = MiningPreferences.defaultOcrBackgroundOpacity;
  double _boxScale = 1;
  double _boxScaleY = 1;
  bool _outlineVisible = true;
  bool _lookupOnHover = false;
  DictionaryLookupTrigger _lookupTrigger = DictionaryLookupTrigger.leftClick;
  bool _additionalLeftClick = false;
  bool _overlayEnabled = true;
  bool _screenAiAvailable = false;
  bool _screenAiManaged = false;
  bool _screenAiBusy = false;
  double? _screenAiProgress;
  bool _loading = true;
  bool _importing = false;
  bool _checkingDictionaryUpdates = false;
  bool _dictionaryAutoUpdate = false;
  int _dictionaryAutoUpdateHours = 24;
  Map<String, DictionaryUpdateInfo> _dictionaryUpdates = const {};
  late DictionaryPopupPreferences _popupPreferences;
  AnkiMiningProfile _ankiProfile = const AnkiMiningProfile();
  AnkiAudioPreferences _ankiAudioPreferences = AnkiAudioPreferences.defaults;
  Uri _ankiEndpoint = Uri.parse('http://127.0.0.1:8765');
  AnkiIntegrationMode _ankiIntegrationMode = AnkiIntegrationMode.ankiMobile;
  int? _ankiVersion;
  List<String> _ankiDecks = const [];
  List<String> _ankiModels = const [];
  List<String> _ankiFields = const [];
  Map<String, List<String>> _ankiMobileFieldsByModel = const {};
  String? _ankiError;
  bool _ankiRefreshing = false;

  bool get _isIOS => defaultTargetPlatform == TargetPlatform.iOS;

  bool get _usesAnkiMobile =>
      effectiveAnkiIntegrationMode(
        preferredMode: _ankiIntegrationMode,
        isIOS: _isIOS,
      ) ==
      AnkiIntegrationMode.ankiMobile;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final values = await Future.wait<dynamic>([
      DictionaryStorage.instance.installed(),
      MiningPreferences.getOcrEngine(),
      MiningPreferences.getOcrBackgroundOpacity(),
      MiningPreferences.getOcrBoxScaleX(),
      MiningPreferences.getOcrBoxScaleY(),
      MiningPreferences.getOcrOutlineVisible(),
      MiningPreferences.getOcrLookupOnHover(),
      MiningPreferences.getOcrOverlayEnabled(),
      MiningPreferences.getDictionaryPopupPreferences(),
      MiningPreferences.getAnkiProfile(),
      MiningPreferences.getAnkiAudioPreferences(),
      MiningPreferences.getAnkiEndpoint(),
      ScreenAiOcrClient.isAvailable(),
      MiningPreferences.getDictionaryLookupTrigger(),
      MiningPreferences.getDictionaryAdditionalLeftClick(),
      MiningPreferences.getDictionaryLanguage(),
      MiningPreferences.getDictionaryProfiles(),
      MiningPreferences.getActiveDictionaryProfile(),
      MiningPreferences.getMokuroWebsiteOcrEnabled(),
      MiningPreferences.getAnkiIntegrationMode(),
      MiningPreferences.getDictionaryAutoUpdateEnabled(),
      MiningPreferences.getDictionaryAutoUpdateIntervalHours(),
      MiningPreferences.getParallelOcrLimit(),
    ]);
    if (!mounted) return;
    final managedScreenAi =
        await ScreenAiComponentManager.installedComponentDirectory() != null;
    if (!mounted) return;
    setState(() {
      _profiles = values[16] as List<DictionaryProfile>;
      _activeProfile = values[17] as DictionaryProfile;
      _mokuroWebsiteOcrEnabled = values[18] as bool;
      _dictionaries = _orderDictionaries(
        values[0] as List<InstalledDictionary>,
        _activeProfile.dictionaryOrder,
      );
      _engine = values[1] as OcrEnginePreference;
      _backgroundOpacity = values[2] as double;
      _boxScale = values[3] as double;
      _boxScaleY = values[4] as double;
      _outlineVisible = values[5] as bool;
      _lookupOnHover = values[6] as bool;
      _overlayEnabled = values[7] as bool;
      _popupPreferences = values[8] as DictionaryPopupPreferences;
      _ankiProfile = values[9] as AnkiMiningProfile;
      _ankiAudioPreferences = values[10] as AnkiAudioPreferences;
      _ankiEndpoint = values[11] as Uri;
      _screenAiAvailable = values[12] as bool;
      _screenAiManaged = managedScreenAi;
      _lookupTrigger = values[13] as DictionaryLookupTrigger;
      _additionalLeftClick = values[14] as bool;
      _dictionaryLanguage = values[15] as String;
      _ankiIntegrationMode = values[19] as AnkiIntegrationMode;
      _dictionaryAutoUpdate = values[20] as bool;
      _dictionaryAutoUpdateHours = values[21] as int;
      _parallelOcrLimit = values[22] as int;
      _loading = false;
    });
    if (widget.section == DictionarySettingsSection.anki && !_usesAnkiMobile) {
      unawaited(_refreshAnki(silent: true));
    }
  }

  Future<void> _installScreenAi() async {
    setState(() {
      _screenAiBusy = true;
      _screenAiProgress = 0;
    });
    try {
      await ScreenAiComponentManager.install(
        onProgress: (received, total) {
          if (!mounted) return;
          setState(
            () => _screenAiProgress = total > 0 ? received / total : null,
          );
        },
      );
      if (!mounted) return;
      setState(() {
        _screenAiAvailable = true;
        _screenAiManaged = true;
      });
      botToast('ScreenAI ${ScreenAiComponentManager.version} installed.');
    } catch (error) {
      if (mounted) botToast('ScreenAI installation failed: $error', second: 6);
    } finally {
      if (mounted) {
        setState(() {
          _screenAiBusy = false;
          _screenAiProgress = null;
        });
      }
    }
  }

  Future<void> _removeScreenAi() async {
    setState(() => _screenAiBusy = true);
    try {
      await ScreenAiComponentManager.remove();
      final available = await ScreenAiOcrClient.isAvailable();
      if (!mounted) return;
      setState(() {
        _screenAiManaged = false;
        _screenAiAvailable = available;
      });
      botToast('Mangatan-managed ScreenAI files removed.');
    } catch (error) {
      if (mounted) {
        botToast(
          'Could not remove ScreenAI while it is in use. Restart Mangatan '
          'and try again. ($error)',
          second: 6,
        );
      }
    } finally {
      if (mounted) setState(() => _screenAiBusy = false);
    }
  }

  Future<void> _importDictionary() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
      final paths = result.map((file) => file.path).nonNulls.toList();
      await _importDictionaryPaths(paths);
    } catch (error) {
      if (!mounted) return;
      botToast(
        defaultTargetPlatform == TargetPlatform.linux
            ? 'Could not open the file picker. Start a D-Bus session and an '
                  'xdg-desktop-portal backend, or drag dictionary ZIP files '
                  'onto this page. ($error)'
            : 'Could not open the file picker: $error',
        second: 7,
      );
    }
  }

  Future<void> _importDictionaryPaths(List<String> paths) async {
    if (paths.isEmpty || !mounted || _importing) return;
    setState(() => _importing = true);
    try {
      final root = await DictionaryStorage.instance.rootDirectory;
      final importedNames = <String>[];
      final failedImports = <String>[];
      final batchImport = paths.length > 1;
      for (final path in paths) {
        try {
          final imported = await HoshidictsLookupBackend.instance
              .importDictionary(
                zipPath: path,
                outputDir: root.path,
                lowRam: batchImport,
              );
          if (!imported.success) {
            failedImports.add(
              '${p.basename(path)}: ${imported.errors.join('; ')}',
            );
            continue;
          }
          await DictionaryStorage.instance.recordImport(
            name: imported.title,
            termCount: imported.termCount,
            frequencyCount: imported.freqCount,
            pitchCount: imported.pitchCount,
            kanjiCount: imported.kanjiCount,
          );
          importedNames.add(imported.title);
        } catch (error) {
          failedImports.add('${p.basename(path)}: $error');
        }
      }
      var updatedProfile = _activeProfile;
      for (final name in importedNames) {
        updatedProfile = updatedProfile.withInstalledDictionary(name);
      }
      if (!identical(updatedProfile, _activeProfile)) {
        await _updateActiveProfile(updatedProfile);
      }
      if (importedNames.isNotEmpty) {
        await HoshidictsLookupBackend.instance.reloadFromStorage();
      }
      await _load();
      if (failedImports.isEmpty) {
        botToast('Imported ${importedNames.join(', ')}', second: 4);
      } else if (importedNames.isEmpty) {
        botToast(
          'Dictionary import failed: ${failedImports.join(' | ')}',
          second: 7,
        );
      } else {
        botToast(
          'Imported ${importedNames.join(', ')}. Failed: '
          '${failedImports.join(' | ')}',
          second: 7,
        );
      }
    } catch (error) {
      botToast('Dictionary import failed: $error', second: 5);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _deleteDictionary(InstalledDictionary dictionary) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove dictionary?'),
        content: Text(dictionary.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await DictionaryStorage.instance.delete(dictionary.name);
    await _updateActiveProfile(
      _activeProfile.withoutDictionary(dictionary.name),
    );
    await HoshidictsLookupBackend.instance.reloadFromStorage();
    await _load();
  }

  Future<void> _renameDictionary(InstalledDictionary dictionary) async {
    final value = await _editText(
      title: 'Rename dictionary',
      value: dictionary.displayName,
      hint: dictionary.name,
    );
    if (value == null || value.trim().isEmpty) return;
    try {
      await DictionaryStorage.instance.renameDisplayName(
        dictionary.name,
        value,
      );
      await _load();
    } catch (error) {
      botToast('Could not rename dictionary: $error', second: 5);
    }
  }

  Future<void> _checkDictionaryUpdates() async {
    if (_checkingDictionaryUpdates) return;
    setState(() => _checkingDictionaryUpdates = true);
    try {
      final results = await DictionaryUpdateService.instance.checkAll();
      if (!mounted) return;
      setState(() {
        _dictionaryUpdates = {
          for (final result in results) result.dictionary.name: result,
        };
      });
      final available = results.where((result) => result.hasUpdate).length;
      final failures = results.where((result) => result.error != null).length;
      botToast(
        available > 0
            ? '$available dictionary update${available == 1 ? '' : 's'} available'
            : failures > 0
            ? 'Update check completed with $failures error${failures == 1 ? '' : 's'}'
            : 'All dictionaries are up to date',
        second: 4,
      );
    } finally {
      if (mounted) setState(() => _checkingDictionaryUpdates = false);
    }
  }

  Future<void> _applyDictionaryUpdate(DictionaryUpdateInfo update) async {
    setState(() => _importing = true);
    try {
      final installed = await DictionaryUpdateService.instance.apply(update);
      await _load();
      botToast(
        'Updated ${installed.displayName}'
        '${installed.revision == null ? '' : ' to ${installed.revision}'}',
        second: 5,
      );
    } catch (error) {
      botToast('Dictionary update failed: $error', second: 6);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _saveDictionaryOrder(
    List<InstalledDictionary> dictionaries,
  ) async {
    final previous = _dictionaries;
    setState(() => _dictionaries = dictionaries);
    try {
      await _updateActiveProfile(
        _activeProfile.copyWith(
          dictionaryOrder: dictionaries
              .map((dictionary) => dictionary.name)
              .toList(),
        ),
      );
      await HoshidictsLookupBackend.instance.reloadFromStorage();
    } catch (error) {
      if (!mounted) return;
      setState(() => _dictionaries = previous);
      botToast('Could not reorder dictionaries: $error', second: 5);
    }
  }

  void _reorderDictionaries(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    final dictionaries = [..._dictionaries];
    final moved = dictionaries.removeAt(oldIndex);
    dictionaries.insert(newIndex, moved);
    unawaited(_saveDictionaryOrder(dictionaries));
  }

  Future<void> _moveDictionary(int index, int offset) async {
    final target = index + offset;
    if (target < 0 || target >= _dictionaries.length || target == index) {
      return;
    }
    final dictionaries = [..._dictionaries];
    final moved = dictionaries.removeAt(index);
    dictionaries.insert(target, moved);
    await _saveDictionaryOrder(dictionaries);
  }

  Future<String?> _editText({
    required String title,
    required String value,
    String? hint,
    int maxLines = 1,
  }) {
    return showEditTextDialog(
      context: context,
      title: title,
      initialValue: value,
      hint: hint,
      maxLines: maxLines,
    );
  }

  Future<void> _saveAnki(AnkiMiningProfile profile) async {
    if (!mounted) return;
    final activeProfile = _activeProfile.copyWith(anki: profile);
    setState(() {
      _ankiProfile = profile;
      _activeProfile = activeProfile;
      _profiles = [
        for (final item in _profiles)
          item.id == activeProfile.id ? activeProfile : item,
      ];
    });
    await MiningPreferences.setAnkiProfile(profile);
  }

  List<InstalledDictionary> _orderDictionaries(
    List<InstalledDictionary> dictionaries,
    List<String> order,
  ) {
    if (order.isEmpty) return dictionaries;
    final byName = {
      for (final dictionary in dictionaries) dictionary.name: dictionary,
    };
    return [for (final name in order) ?byName.remove(name), ...byName.values];
  }

  Future<void> _updateActiveProfile(DictionaryProfile profile) async {
    await MiningPreferences.updateDictionaryProfile(profile);
    if (!mounted) return;
    setState(() {
      _activeProfile = profile;
      _profiles = [
        for (final item in _profiles) item.id == profile.id ? profile : item,
      ];
    });
  }

  Future<void> _activateProfile(DictionaryProfile profile) async {
    if (profile.id == _activeProfile.id) return;
    await MiningPreferences.setActiveDictionaryProfile(profile.id);
    HoshidictsLookupBackend.instance.clearSession();
    await _load();
  }

  Future<void> _createProfile() async {
    final name = await _editText(
      title: 'New profile',
      value: '${_activeProfile.name} copy',
      hint: 'Profile name',
    );
    if (name == null || name.trim().isEmpty) return;
    final profile = _activeProfile.copyWith(
      id: 'profile-${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim(),
    );
    await MiningPreferences.addDictionaryProfile(profile);
    HoshidictsLookupBackend.instance.clearSession();
    await _load();
  }

  Future<void> _renameActiveProfile() async {
    final name = await _editText(
      title: 'Rename profile',
      value: _activeProfile.name,
      hint: 'Profile name',
    );
    if (name == null || name.trim().isEmpty) return;
    await _updateActiveProfile(_activeProfile.copyWith(name: name.trim()));
  }

  Future<void> _deleteActiveProfile() async {
    if (_profiles.length <= 1) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete profile?'),
        content: Text(_activeProfile.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await MiningPreferences.deleteDictionaryProfile(_activeProfile.id);
    HoshidictsLookupBackend.instance.clearSession();
    await _load();
  }

  Future<void> _toggleDictionary(String name, bool enabled) async {
    var enabledNames = _activeProfile.enabledDictionaries.isEmpty
        ? _dictionaries.map((dictionary) => dictionary.name).toSet()
        : {..._activeProfile.enabledDictionaries};
    enabled ? enabledNames.add(name) : enabledNames.remove(name);
    if (enabledNames.length == _dictionaries.length) enabledNames = {};
    await _updateActiveProfile(
      _activeProfile.copyWith(enabledDictionaries: enabledNames),
    );
    await HoshidictsLookupBackend.instance.reloadFromStorage();
  }

  Future<void> _saveAnkiAudio(AnkiAudioPreferences preferences) async {
    setState(() => _ankiAudioPreferences = preferences);
    await MiningPreferences.setAnkiAudioPreferences(preferences);
  }

  Future<void> _saveAnkiAudioSources(List<AnkiAudioSource> sources) async {
    final first = sources.firstOrNull;
    await _saveAnkiAudio(
      _ankiAudioPreferences.copyWith(
        sources: List.unmodifiable(sources),
        sourceType: first?.type ?? _ankiAudioPreferences.sourceType,
        url: first?.url ?? '',
      ),
    );
  }

  bool _usesDefaultAudioSources(String language) {
    final current = _ankiAudioPreferences.effectiveSources;
    final defaults = AnkiAudioPreferences.defaultSourcesForLanguage(language);
    if (current.length != defaults.length) return false;
    for (var index = 0; index < current.length; index++) {
      if (current[index].type != defaults[index].type ||
          current[index].url != defaults[index].url) {
        return false;
      }
    }
    return true;
  }

  Future<void> _addAnkiAudioSource() async {
    final configuredTypes = _ankiAudioPreferences.effectiveSources
        .where((source) => !source.isCustom)
        .map((source) => source.type)
        .toSet();
    final type = await showDialog<AnkiAudioSourceType>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Add audio source'),
        children: [
          for (final sourceType in AnkiAudioSourceType.values)
            if ((_ankiAudioPreferences.language == 'ja' ||
                    (sourceType != AnkiAudioSourceType.japanesePod101 &&
                        sourceType != AnkiAudioSourceType.jisho)) &&
                (sourceType == AnkiAudioSourceType.customUrl ||
                    sourceType == AnkiAudioSourceType.customJson ||
                    !configuredTypes.contains(sourceType)))
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, sourceType),
                child: Text(AnkiAudioSource(type: sourceType).displayName),
              ),
        ],
      ),
    );
    if (type == null) return;
    var source = AnkiAudioSource(type: type);
    if (source.isCustom) {
      final url = await _editText(
        title: source.displayName,
        value: '',
        hint: type == AnkiAudioSourceType.customJson
            ? AnkiAudioPreferences.defaultUrl
            : 'https://example.com/{term}.mp3',
        maxLines: 3,
      );
      if (url == null || Uri.tryParse(url.trim())?.hasScheme != true) return;
      source = source.copyWith(url: url.trim());
    }
    await _saveAnkiAudioSources([
      ..._ankiAudioPreferences.effectiveSources,
      source,
    ]);
  }

  Future<void> _editAnkiAudioSource(int index) async {
    final sources = [..._ankiAudioPreferences.effectiveSources];
    if (index < 0 || index >= sources.length || !sources[index].isCustom) {
      return;
    }
    final source = sources[index];
    final url = await _editText(
      title: source.displayName,
      value: source.url,
      hint: source.type == AnkiAudioSourceType.customJson
          ? AnkiAudioPreferences.defaultUrl
          : 'https://example.com/{term}.mp3',
      maxLines: 3,
    );
    if (url == null || Uri.tryParse(url.trim())?.hasScheme != true) return;
    sources[index] = source.copyWith(url: url.trim());
    await _saveAnkiAudioSources(sources);
  }

  Future<void> _moveAnkiAudioSource(int index, int offset) async {
    final sources = [..._ankiAudioPreferences.effectiveSources];
    final destination = index + offset;
    if (index < 0 ||
        index >= sources.length ||
        destination < 0 ||
        destination >= sources.length) {
      return;
    }
    final source = sources.removeAt(index);
    sources.insert(destination, source);
    await _saveAnkiAudioSources(sources);
  }

  Future<void> _removeAnkiAudioSource(int index) async {
    final sources = [..._ankiAudioPreferences.effectiveSources];
    if (index < 0 || index >= sources.length) return;
    sources.removeAt(index);
    await _saveAnkiAudioSources(sources);
  }

  Future<void> _refreshAnki({bool silent = false}) async {
    if (_ankiRefreshing) return;
    setState(() {
      _ankiRefreshing = true;
      _ankiError = null;
    });
    try {
      if (_usesAnkiMobile) {
        final info = await AnkiMobileService().fetchInfo();
        final models = info.noteTypes
            .map((noteType) => noteType.name)
            .toList(growable: false);
        // A fresh AnkiMobile profile can report no note types or decks yet.
        // Keep the saved names then, as the AnkiConnect path does.
        final selectedModel =
            models.contains(_ankiProfile.modelName) || models.isEmpty
            ? _ankiProfile.modelName
            : models.first;
        final fields = info.fieldsByNoteType[selectedModel] ?? const <String>[];
        final isLapis = _isLapisLike(selectedModel, fields);
        final needsLapisMigration = isLapis && _needsLapisMigration();
        final selectedDeck =
            info.decks.contains(_ankiProfile.deckName) || info.decks.isEmpty
            ? _ankiProfile.deckName
            : info.decks.first;
        final configurationChanged =
            selectedDeck != _ankiProfile.deckName ||
            selectedModel != _ankiProfile.modelName;
        final profile =
            configurationChanged ||
                (fields.isNotEmpty &&
                    (!_fieldMapMatches(fields) || needsLapisMigration))
            ? _ankiProfile.copyWith(
                deckName: selectedDeck,
                modelName: selectedModel,
                fieldMap: fields.isEmpty
                    ? _ankiProfile.fieldMap
                    : _autoMapFields(
                        fields,
                        needsLapisMigration ? const {} : _ankiProfile.fieldMap,
                        isLapis: isLapis,
                      ),
              )
            : _ankiProfile;
        if (!mounted) return;
        if (!identical(profile, _ankiProfile)) await _saveAnki(profile);
        if (!mounted) return;
        setState(() {
          _ankiProfile = profile;
          _ankiVersion = 0;
          _ankiDecks = info.decks;
          _ankiModels = models;
          _ankiMobileFieldsByModel = info.fieldsByNoteType;
          _ankiFields = fields;
        });
        if (!silent) {
          botToast('Connected to AnkiMobile', second: 3);
        }
        return;
      }
      final service = AnkiConnectService(endpoint: _ankiEndpoint);
      final version = await service.version();
      final decks = await service.deckNames();
      final models = await service.modelNames();
      final selectedModel = _ankiProfile.modelName.trim().isNotEmpty
          ? _ankiProfile.modelName
          : (models.isEmpty ? '' : models.first);
      final fields = selectedModel.trim().isEmpty
          ? <String>[]
          : await service.modelFieldNames(selectedModel);
      final isLapis = _isLapisLike(selectedModel, fields);
      final needsLapisMigration = isLapis && _needsLapisMigration();
      final profile =
          fields.isNotEmpty &&
              (!_fieldMapMatches(fields) || needsLapisMigration)
          ? _ankiProfile.copyWith(
              fieldMap: _autoMapFields(
                fields,
                needsLapisMigration ? const {} : _ankiProfile.fieldMap,
                isLapis: isLapis,
              ),
            )
          : _ankiProfile;
      if (!mounted) return;
      if (!identical(profile, _ankiProfile)) await _saveAnki(profile);
      if (!mounted) return;
      setState(() {
        _ankiProfile = profile;
        _ankiVersion = version;
        _ankiDecks = decks;
        _ankiModels = models;
        _ankiFields = fields;
        _ankiMobileFieldsByModel = const {};
      });
      if (!silent) botToast('Connected to AnkiConnect v$version', second: 3);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _ankiVersion = null;
        _ankiDecks = const [];
        _ankiModels = const [];
        _ankiFields = const [];
        _ankiError = error.toString();
      });
      if (!silent) {
        botToast(
          '${_usesAnkiMobile ? 'AnkiMobile' : 'AnkiConnect'} failed: $error',
          second: 5,
        );
      }
    } finally {
      if (mounted) setState(() => _ankiRefreshing = false);
    }
  }

  Future<void> _setAnkiIntegrationMode(AnkiIntegrationMode mode) async {
    if (mode == _ankiIntegrationMode) return;
    setState(() {
      _ankiIntegrationMode = mode;
      _ankiVersion = null;
      _ankiDecks = const [];
      _ankiModels = const [];
      _ankiFields = const [];
      _ankiMobileFieldsByModel = const {};
      _ankiError = null;
    });
    await MiningPreferences.setAnkiIntegrationMode(mode);
  }

  Future<void> _selectAnkiModel(String modelName) async {
    var fields = <String>[];
    if (_usesAnkiMobile) {
      fields = _ankiMobileFieldsByModel[modelName] ?? const [];
    } else {
      try {
        fields = await AnkiConnectService(
          endpoint: _ankiEndpoint,
        ).modelFieldNames(modelName);
      } catch (error) {
        botToast('Could not fetch fields: $error', second: 5);
      }
    }
    final isLapis = _isLapisLike(modelName, fields);
    final profile = _ankiProfile.copyWith(
      modelName: modelName,
      fieldMap: _autoMapFields(
        fields,
        isLapis ? const {} : _ankiProfile.fieldMap,
        isLapis: isLapis,
      ),
    );
    if (!mounted) return;
    setState(() => _ankiFields = fields);
    await _saveAnki(profile);
  }

  Map<String, String> _autoMapFields(
    List<String> fields,
    Map<String, String> current, {
    bool isLapis = false,
  }) {
    if (fields.isEmpty) return current;
    return {
      for (final indexed in fields.indexed)
        indexed.$2:
            current[indexed.$2] ??
            AnkiMarker.autoDetectTemplate(
              indexed.$2,
              indexed.$1,
              isLapis: isLapis,
            ) ??
            '',
    };
  }

  bool _fieldMapMatches(List<String> fields) {
    final fieldSet = fields.toSet();
    return _ankiProfile.fieldMap.keys.any(fieldSet.contains);
  }

  bool _isLapisLike(String modelName, List<String> fields) {
    final names = fields.map((field) => field.toLowerCase()).toSet();
    return modelName.toLowerCase().contains('lapis') ||
        names.containsAll({'expression', 'maindefinition', 'sentence'});
  }

  bool _needsLapisMigration() {
    final map = _ankiProfile.fieldMap;
    return map['ExpressionFurigana'] == AnkiMarker.furigana ||
        map['DefinitionPicture'] == AnkiMarker.screenshot ||
        map['IsWordAndSentenceCard'] != 'x';
  }

  Future<void> _editAnkiFieldMap() async {
    final fields = _ankiFields.isNotEmpty
        ? _ankiFields
        : _ankiProfile.fieldMap.keys.toList();
    if (fields.isEmpty) {
      botToast('Connect to Anki first to fetch note fields', second: 4);
      return;
    }
    final dictionaryTemplates =
        AnkiMarker.singleGlossaryTemplatesForDictionaries(
          _dictionaries
              .where((dictionary) => dictionary.hasTerms)
              .map((dictionary) => dictionary.name),
        );
    final isLapis = _isLapisLike(_ankiProfile.modelName, fields);
    var map = _autoMapFields(fields, _ankiProfile.fieldMap, isLapis: isLapis);
    final saved = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Anki field templates'),
              content: SizedBox(
                width: 560,
                height: 520,
                child: ListView.separated(
                  itemCount: fields.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final field = fields[index];
                    final value = map[field] ?? '';
                    return _AnkiFieldTemplatePicker(
                      fieldName: field,
                      value: value,
                      dynamicTemplates: dictionaryTemplates,
                      onChanged: (next) {
                        setDialogState(() => map = {...map, field: next});
                      },
                      onEditCustom: () async {
                        final next = await _editText(
                          title: field,
                          value: value,
                          hint: AnkiMarker.expression,
                          maxLines: 4,
                        );
                        if (next == null) return;
                        setDialogState(() => map = {...map, field: next});
                      },
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    setDialogState(
                      () => map = _autoMapFields(
                        fields,
                        const {},
                        isLapis: isLapis,
                      ),
                    );
                  },
                  child: const Text('Auto map'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, map),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
    if (saved == null) return;
    await _saveAnki(_ankiProfile.copyWith(fieldMap: saved));
  }

  Future<void> _editAnkiDuplicateDecks() async {
    final available = <String>{
      _ankiProfile.deckName,
      ..._ankiDecks,
      ..._ankiProfile.duplicateDeckNames,
    }.where((deck) => deck.trim().isNotEmpty).toList()..sort();
    if (_ankiDecks.isEmpty) {
      final raw = await _editText(
        title: 'Decks to check for duplicates',
        value: _ankiProfile.duplicateDeckNames.join(', '),
        hint: 'Japanese::Mining, Japanese::Archive',
        maxLines: 4,
      );
      if (raw == null) return;
      final decks = <String>{
        _ankiProfile.deckName,
        ...raw
            .split(RegExp(r'[,\n]+'))
            .map((deck) => deck.trim())
            .where((deck) => deck.isNotEmpty),
      }.toList();
      await _saveAnki(_ankiProfile.copyWith(duplicateDeckNames: decks));
      return;
    }

    var selected = <String>{
      _ankiProfile.deckName,
      ..._ankiProfile.duplicateDeckNames,
    };
    final saved = await showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Decks to check'),
          content: SizedBox(
            width: 480,
            height: 420,
            child: ListView.builder(
              itemCount: available.length,
              itemBuilder: (context, index) {
                final deck = available[index];
                final isDestination = deck == _ankiProfile.deckName;
                return CheckboxListTile(
                  value: selected.contains(deck),
                  title: Text(deck),
                  subtitle: isDestination
                      ? const Text('Destination deck (always checked)')
                      : null,
                  onChanged: isDestination
                      ? null
                      : (checked) {
                          setDialogState(() {
                            selected = {...selected};
                            if (checked == true) {
                              selected.add(deck);
                            } else {
                              selected.remove(deck);
                            }
                          });
                        },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected.toList()),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == null) return;
    await _saveAnki(_ankiProfile.copyWith(duplicateDeckNames: saved));
  }

  List<Widget> _childrenForSection(List<Widget> children) {
    // Keep one source of truth for the existing controls while presenting
    // Chimahon's Dictionary, Popup, and Anki pages as separate routes.
    final visibleGroups = switch (widget.section) {
      DictionarySettingsSection.dictionariesAndAudio => {
        _DictionarySettingsGroup.profiles,
        _DictionarySettingsGroup.dictionaries,
      },
      DictionarySettingsSection.dictionaryPopup => {
        _DictionarySettingsGroup.popup,
      },
      DictionarySettingsSection.anki => {
        _DictionarySettingsGroup.profiles,
        _DictionarySettingsGroup.anki,
      },
    };
    var currentGroup = _DictionarySettingsGroup.profiles;
    final visibleChildren = <Widget>[];
    for (final child in children) {
      if (child is _DictionarySettingsGroupMarker) {
        currentGroup = child.group;
      } else if (visibleGroups.contains(currentGroup)) {
        visibleChildren.add(child);
      }
    }
    if (visibleChildren.isNotEmpty && visibleChildren.first is Divider) {
      visibleChildren.removeAt(0);
    }
    return visibleChildren;
  }

  Widget _dictionaryLanguagePreference() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: DropdownButtonFormField<String>(
        initialValue: _dictionaryLanguage,
        decoration: const InputDecoration(
          labelText: 'Dictionary language',
          helperText: 'Controls word parsing and deinflection during lookup',
          prefixIcon: Icon(Icons.translate),
        ),
        items: [
          const DropdownMenuItem(
            value: '',
            child: Text('Any (not matched automatically)'),
          ),
          if (_dictionaryLanguage.isNotEmpty &&
              !dictionaryLanguages.any(
                (language) => language.code == _dictionaryLanguage,
              ))
            DropdownMenuItem(
              value: _dictionaryLanguage,
              child: Text(_dictionaryLanguage),
            ),
          for (final language in dictionaryLanguages)
            DropdownMenuItem(value: language.code, child: Text(language.name)),
        ],
        onChanged: (value) async {
          if (value == null) return;
          setState(() => _dictionaryLanguage = value);
          await _updateActiveProfile(
            _activeProfile.copyWith(languageCode: value),
          );
          HoshidictsLookupBackend.instance.invalidateLookups();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final collapseMode =
        const {
          'expand_all',
          'expand_first_available',
          'collapse_all',
          'custom',
        }.contains(_activeProfile.dictionaryCollapseMode)
        ? _activeProfile.dictionaryCollapseMode
        : 'expand_all';
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.section.title),
        actions: [
          IconButton(
            tooltip: 'Lookup history',
            onPressed: () => DictionaryLookupHistorySheet.show(
              context: context,
              onSelected: (query) =>
                  MiningLookupSheet.show(context: context, text: query),
            ),
            icon: const Icon(Icons.history),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: _childrenForSection([
                const _DictionarySettingsGroupMarker(
                  _DictionarySettingsGroup.profiles,
                ),
                const _SectionHeader('Profiles'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 8, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final profile in _profiles) ...[
                                ChoiceChip(
                                  label: Text(profile.name),
                                  selected: profile.id == _activeProfile.id,
                                  onSelected: (_) => _activateProfile(profile),
                                ),
                                const SizedBox(width: 8),
                              ],
                              ActionChip(
                                avatar: const Icon(Icons.add, size: 18),
                                label: const Text('Clone'),
                                onPressed: _createProfile,
                              ),
                            ],
                          ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Profile actions',
                        onSelected: (action) {
                          if (action == 'rename') _renameActiveProfile();
                          if (action == 'delete') _deleteActiveProfile();
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'rename',
                            child: ListTile(
                              leading: Icon(Icons.edit_outlined),
                              title: Text('Rename'),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            enabled: _profiles.length > 1,
                            child: const ListTile(
                              leading: Icon(Icons.delete_outline),
                              title: Text('Delete'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text('Active: ${_activeProfile.name}'),
                  subtitle: const Text(
                    'Language, dictionary priority, enabled dictionaries, and Anki settings are saved per profile.',
                  ),
                ),
                _dictionaryLanguagePreference(),
                const _DictionarySettingsGroupMarker(
                  _DictionarySettingsGroup.dictionaries,
                ),
                const Divider(height: 24),
                const _SectionHeader('Dictionaries'),
                SwitchListTile(
                  secondary: const Icon(Icons.sync),
                  title: const Text('Update dictionaries automatically'),
                  subtitle: Text(
                    'Check every $_dictionaryAutoUpdateHours hours while the app is running',
                  ),
                  value: _dictionaryAutoUpdate,
                  onChanged: (value) {
                    setState(() => _dictionaryAutoUpdate = value);
                    MiningPreferences.setDictionaryAutoUpdateEnabled(value);
                  },
                ),
                if (_dictionaryAutoUpdate)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: DropdownButtonFormField<int>(
                      initialValue: _dictionaryAutoUpdateHours,
                      decoration: const InputDecoration(
                        labelText: 'Update check interval',
                        prefixIcon: Icon(Icons.schedule),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 6,
                          child: Text('Every 6 hours'),
                        ),
                        DropdownMenuItem(
                          value: 12,
                          child: Text('Every 12 hours'),
                        ),
                        DropdownMenuItem(value: 24, child: Text('Daily')),
                        DropdownMenuItem(
                          value: 72,
                          child: Text('Every 3 days'),
                        ),
                        DropdownMenuItem(value: 168, child: Text('Weekly')),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => _dictionaryAutoUpdateHours = value);
                        MiningPreferences.setDictionaryAutoUpdateIntervalHours(
                          value,
                        );
                      },
                    ),
                  ),
                ListTile(
                  leading: const Icon(Icons.system_update_alt),
                  title: const Text('Check for dictionary updates'),
                  subtitle: const Text(
                    'Uses update information embedded by compatible Yomitan dictionaries',
                  ),
                  trailing: _checkingDictionaryUpdates
                      ? const SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  onTap: _checkingDictionaryUpdates
                      ? null
                      : _checkDictionaryUpdates,
                ),
                DictionaryZipDropTarget(
                  enabled: !_importing,
                  onImport: _importDictionaryPaths,
                  child: ListTile(
                    leading: const Icon(Icons.archive_outlined),
                    title: const Text('Import Yomitan dictionary'),
                    subtitle: const Text(
                      'Select or drop Yomitan-format ZIP files',
                    ),
                    trailing: _importing
                        ? const SizedBox.square(
                            dimension: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add),
                    onTap: _importing ? null : _importDictionary,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: DropdownButtonFormField<String>(
                    initialValue: collapseMode,
                    decoration: const InputDecoration(
                      labelText: 'Dictionary collapse mode',
                      prefixIcon: Icon(Icons.unfold_less),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'expand_all',
                        child: Text('Expand all dictionaries'),
                      ),
                      DropdownMenuItem(
                        value: 'expand_first_available',
                        child: Text('Expand first available dictionary'),
                      ),
                      DropdownMenuItem(
                        value: 'collapse_all',
                        child: Text('Collapse all dictionaries'),
                      ),
                      DropdownMenuItem(value: 'custom', child: Text('Custom')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      _updateActiveProfile(
                        _activeProfile.copyWith(dictionaryCollapseMode: value),
                      );
                    },
                  ),
                ),
                if (_dictionaries.isEmpty)
                  const ListTile(
                    leading: Icon(Icons.menu_book_outlined),
                    title: Text('No dictionaries installed'),
                    subtitle: Text(
                      'Import at least one term dictionary for native lookup.',
                    ),
                  )
                else
                  ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    itemCount: _dictionaries.length,
                    onReorderItem: _reorderDictionaries,
                    itemBuilder: (context, index) {
                      final dictionary = _dictionaries[index];
                      return _DictionaryListTile(
                        key: ValueKey(dictionary.name),
                        dictionary: dictionary,
                        index: index,
                        canMoveUp: index > 0,
                        canMoveDown: index < _dictionaries.length - 1,
                        enabled: _activeProfile.isDictionaryEnabled(
                          dictionary.name,
                        ),
                        displayMode: collapseMode == 'custom'
                            ? _activeProfile.dictionaryDisplayModes[dictionary
                                      .name] ??
                                  'fallback'
                            : null,
                        onEnabledChanged: (enabled) =>
                            _toggleDictionary(dictionary.name, enabled),
                        onDisplayModeChanged: (mode) => _updateActiveProfile(
                          _activeProfile.copyWith(
                            dictionaryDisplayModes: {
                              ..._activeProfile.dictionaryDisplayModes,
                              dictionary.name: mode,
                            },
                          ),
                        ),
                        onMoveUp: () => _moveDictionary(index, -1),
                        onMoveDown: () => _moveDictionary(index, 1),
                        update: _dictionaryUpdates[dictionary.name],
                        onRename: () => _renameDictionary(dictionary),
                        onUpdate: () {
                          final update = _dictionaryUpdates[dictionary.name];
                          if (update != null) {
                            _applyDictionaryUpdate(update);
                          }
                        },
                        onDelete: () => _deleteDictionary(dictionary),
                      );
                    },
                  ),
                const _DictionarySettingsGroupMarker(
                  _DictionarySettingsGroup.popup,
                ),
                const Divider(height: 24),
                const _SectionHeader('Layout'),
                _SliderSetting(
                  title: 'Popup width',
                  value: _popupPreferences.width,
                  min: 280,
                  max: 720,
                  divisions: 22,
                  label: '${_popupPreferences.width.round()} px',
                  onChanged: (value) {
                    setState(() {
                      _popupPreferences = _popupPreferences.copyWith(
                        width: value,
                      );
                    });
                    MiningPreferences.setDictionaryPopupWidth(value);
                  },
                ),
                _SliderSetting(
                  title: 'Popup height',
                  value: _popupPreferences.height,
                  min: 240,
                  max: 720,
                  divisions: 24,
                  label: '${_popupPreferences.height.round()} px',
                  onChanged: (value) {
                    setState(() {
                      _popupPreferences = _popupPreferences.copyWith(
                        height: value,
                      );
                    });
                    MiningPreferences.setDictionaryPopupHeight(value);
                  },
                ),
                const Divider(height: 24),
                const _SectionHeader('Typography'),
                _SliderSetting(
                  title: 'Dictionary font size',
                  value: _popupPreferences.fontSize,
                  min: 11,
                  max: 24,
                  divisions: 13,
                  label: '${_popupPreferences.fontSize.round()} px',
                  onChanged: (value) {
                    setState(() {
                      _popupPreferences = _popupPreferences.copyWith(
                        fontSize: value,
                      );
                    });
                    MiningPreferences.setDictionaryFontSize(value);
                  },
                ),
                const Divider(height: 24),
                const _SectionHeader('Theme'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DropdownButtonFormField<DictionaryThemePreference>(
                    initialValue: _popupPreferences.theme,
                    decoration: const InputDecoration(
                      labelText: 'Dictionary theme',
                      prefixIcon: Icon(Icons.contrast),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: DictionaryThemePreference.system,
                        child: Text('System'),
                      ),
                      DropdownMenuItem(
                        value: DictionaryThemePreference.light,
                        child: Text('Light'),
                      ),
                      DropdownMenuItem(
                        value: DictionaryThemePreference.dark,
                        child: Text('Dark'),
                      ),
                      DropdownMenuItem(
                        value: DictionaryThemePreference.black,
                        child: Text('Pure black'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _popupPreferences = _popupPreferences.copyWith(
                          theme: value,
                        );
                      });
                      MiningPreferences.setDictionaryTheme(value);
                    },
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.format_paint_outlined),
                  title: const Text('E-Ink mode'),
                  subtitle: const Text(
                    'Removes popup shadows and rounded corners',
                  ),
                  value: _popupPreferences.eInkMode,
                  onChanged: (value) {
                    setState(() {
                      _popupPreferences = _popupPreferences.copyWith(
                        eInkMode: value,
                      );
                    });
                    MiningPreferences.setDictionaryEInkMode(value);
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.view_carousel_outlined),
                  title: const Text('Paginated scrolling'),
                  value: _popupPreferences.paginatedScrolling,
                  onChanged: (value) {
                    setState(() {
                      _popupPreferences = _popupPreferences.copyWith(
                        paginatedScrolling: value,
                      );
                    });
                    MiningPreferences.setDictionaryPaginatedScrolling(value);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.css_outlined),
                  title: const Text('Custom CSS'),
                  subtitle: Text(
                    _popupPreferences.customCss.trim().isEmpty
                        ? 'Add CSS after dictionary styles'
                        : 'Custom CSS configured',
                  ),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () async {
                    final value = await _editText(
                      title: 'Custom dictionary CSS',
                      value: _popupPreferences.customCss,
                      hint: '.gloss-sc-li { color: red; }',
                      maxLines: 12,
                    );
                    if (value == null || !mounted) return;
                    setState(() {
                      _popupPreferences = _popupPreferences.copyWith(
                        customCss: value,
                      );
                    });
                    await MiningPreferences.setDictionaryCustomCss(value);
                  },
                ),
                const Divider(height: 24),
                const _SectionHeader('Content'),
                SwitchListTile(
                  title: const Text('Show harmonic frequency'),
                  value: _popupPreferences.showFrequencyHarmonic,
                  onChanged: (value) {
                    setState(() {
                      _popupPreferences = _popupPreferences.copyWith(
                        showFrequencyHarmonic: value,
                      );
                    });
                    MiningPreferences.setShowFrequencyHarmonic(value);
                  },
                ),
                SwitchListTile(
                  title: const Text('Show average frequency'),
                  value: _popupPreferences.showFrequencyAverage,
                  onChanged: (value) {
                    setState(() {
                      _popupPreferences = _popupPreferences.copyWith(
                        showFrequencyAverage: value,
                      );
                    });
                    MiningPreferences.setShowFrequencyAverage(value);
                  },
                ),
                SwitchListTile(
                  title: const Text('Show pitch positions'),
                  value: _popupPreferences.showPitchNumber,
                  onChanged: (value) {
                    setState(() {
                      _popupPreferences = _popupPreferences.copyWith(
                        showPitchNumber: value,
                      );
                    });
                    MiningPreferences.setShowPitchNumber(value);
                  },
                ),
                SwitchListTile(
                  title: const Text('Show pitch transcriptions'),
                  value: _popupPreferences.showPitchText,
                  onChanged: (value) {
                    setState(() {
                      _popupPreferences = _popupPreferences.copyWith(
                        showPitchText: value,
                      );
                    });
                    MiningPreferences.setShowPitchText(value);
                  },
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DropdownButtonFormField<DictionaryLookupTrigger>(
                    initialValue: _lookupTrigger,
                    decoration: const InputDecoration(
                      labelText: 'Lookup trigger',
                      helperText:
                          'Used in manga and EPUB readers when hover lookup is off',
                      prefixIcon: Icon(Icons.mouse_outlined),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: DictionaryLookupTrigger.leftClick,
                        child: Text('Left click'),
                      ),
                      DropdownMenuItem(
                        value: DictionaryLookupTrigger.shift,
                        child: Text('Hold Shift'),
                      ),
                      DropdownMenuItem(
                        value: DictionaryLookupTrigger.middleClick,
                        child: Text('Hold middle click'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _lookupTrigger = value);
                      unawaited(ReaderLookupTriggerState.setTrigger(value));
                    },
                  ),
                ),
                if (isDesktop)
                  SwitchListTile(
                    secondary: const Icon(Icons.ads_click_outlined),
                    title: const Text('Also allow left click'),
                    subtitle: Text(
                      _lookupTrigger == DictionaryLookupTrigger.leftClick
                          ? 'Left click is already the selected lookup trigger'
                          : 'Use left click in addition to the selected trigger',
                    ),
                    value:
                        _lookupTrigger == DictionaryLookupTrigger.leftClick ||
                        _additionalLeftClick,
                    onChanged:
                        _lookupTrigger == DictionaryLookupTrigger.leftClick
                        ? null
                        : (value) {
                            setState(() => _additionalLeftClick = value);
                            unawaited(
                              ReaderLookupTriggerState.setAdditionalLeftClick(
                                value,
                              ),
                            );
                          },
                  ),
                const Divider(height: 24),
                const _SectionHeader('OCR'),
                SwitchListTile(
                  secondary: const Icon(Icons.document_scanner_outlined),
                  title: const Text('Show OCR in reader'),
                  subtitle: const Text(
                    'Recognize pages automatically as they load',
                  ),
                  value: _overlayEnabled,
                  onChanged: (value) {
                    setState(() => _overlayEnabled = value);
                    ReaderOcrState.setEnabled(value);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DropdownButtonFormField<OcrEnginePreference>(
                    initialValue: _engine,
                    decoration: const InputDecoration(
                      labelText: 'OCR engine',
                      prefixIcon: Icon(Icons.document_scanner_outlined),
                    ),
                    items: [
                      for (final engine in availableOcrEngines())
                        DropdownMenuItem(
                          value: engine,
                          child: Text(ocrEngineLabel(engine)),
                        ),
                    ],
                    onChanged: (value) async {
                      if (value == null) return;
                      setState(() => _engine = value);
                      await ReaderOcrState.setEngine(value);
                    },
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.account_tree_outlined),
                  title: const Text('Parallel OCR tasks'),
                  subtitle: Text(
                    _parallelOcrLimit == 1
                        ? '1 task (recommended for battery and stability)'
                        : '$_parallelOcrLimit tasks may use more power or trigger online rate limits',
                  ),
                  trailing: DropdownButton<int>(
                    value: _parallelOcrLimit,
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('1')),
                      DropdownMenuItem(value: 2, child: Text('2')),
                      DropdownMenuItem(value: 3, child: Text('3')),
                      DropdownMenuItem(value: 4, child: Text('4')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _parallelOcrLimit = value);
                      unawaited(ReaderOcrState.setParallelOcrLimit(value));
                    },
                  ),
                ),
                ValueListenableBuilder<List<OcrQueueEntry>>(
                  valueListenable:
                      OcrProcessingQueueController.instance.entries,
                  builder: (context, entries, _) {
                    final failed = entries
                        .where((entry) => entry.status == OcrQueueStatus.error)
                        .length;
                    final processing = entries
                        .where(
                          (entry) =>
                              entry.status == OcrQueueStatus.pending ||
                              entry.status == OcrQueueStatus.processing,
                        )
                        .length;
                    return ListTile(
                      leading: const Icon(
                        Icons.playlist_add_check_circle_outlined,
                      ),
                      title: const Text('OCR processing queue'),
                      subtitle: Text(
                        failed > 0
                            ? '$failed failed · tap a chapter to retry'
                            : processing > 0
                            ? '$processing chapter${processing == 1 ? '' : 's'} processing'
                            : entries.isEmpty
                            ? 'No queued chapters'
                            : '${entries.length} finished chapter${entries.length == 1 ? '' : 's'}',
                      ),
                      onTap: () => showOcrProcessingQueueSheet(context),
                    );
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.cloud_download_outlined),
                  title: const Text('Use Mokuro website OCR'),
                  subtitle: const Text(
                    'For the Mokuro extension, prefer the website\'s saved '
                    'OCR instead of generating it on the fly',
                  ),
                  value: _mokuroWebsiteOcrEnabled,
                  onChanged: (value) async {
                    setState(() => _mokuroWebsiteOcrEnabled = value);
                    await MiningPreferences.setMokuroWebsiteOcrEnabled(value);
                  },
                ),
                if (currentOcrHostPlatform == OcrHostPlatform.apple)
                  const ListTile(
                    leading: Icon(Icons.offline_bolt_outlined),
                    title: Text('Apple Vision OCR'),
                    subtitle: Text(
                      'Runs privately on device. Supported languages depend on the OS version.',
                    ),
                  ),
                if (currentOcrHostPlatform == OcrHostPlatform.windows)
                  ListTile(
                    leading: Icon(
                      _screenAiAvailable
                          ? Icons.offline_bolt_outlined
                          : Icons.download_for_offline_outlined,
                    ),
                    title: const Text('ScreenAI OCR'),
                    subtitle: Text(
                      _screenAiBusy
                          ? _screenAiProgress == null
                                ? 'Managing local ScreenAI files…'
                                : 'Downloading ${(_screenAiProgress! * 100).clamp(0, 100).toStringAsFixed(0)}%'
                          : _screenAiManaged
                          ? 'Version ${ScreenAiComponentManager.version} is managed by Mangatan and runs on device.'
                          : _screenAiAvailable
                          ? 'Chrome/Edge ScreenAI component detected. Runs on device.'
                          : 'Not installed. Download the 72 MB on-device OCR component, or use Automatic/Google Lens.',
                    ),
                    trailing: _screenAiBusy
                        ? SizedBox.square(
                            dimension: 24,
                            child: CircularProgressIndicator(
                              value: _screenAiProgress,
                              strokeWidth: 2,
                            ),
                          )
                        : _screenAiManaged
                        ? IconButton(
                            tooltip: 'Remove managed ScreenAI files',
                            onPressed: _removeScreenAi,
                            icon: const Icon(Icons.delete_outline),
                          )
                        : _screenAiAvailable
                        ? null
                        : TextButton.icon(
                            onPressed: _installScreenAi,
                            icon: const Icon(Icons.download),
                            label: const Text('Download'),
                          ),
                  ),
                const ListTile(
                  leading: Icon(Icons.translate),
                  title: Text('OCR language follows the dictionary profile'),
                  subtitle: Text(
                    'The profile resolved for the current entry or source '
                    'selects the OCR language.',
                  ),
                ),
                const SizedBox(height: 8),
                _SliderSetting(
                  title: 'OCR text box opacity',
                  description:
                      '0% keeps the current transparent background; raise it for a more opaque white text box.',
                  value: _backgroundOpacity,
                  min: 0,
                  max: 1,
                  divisions: 20,
                  label: '${(_backgroundOpacity * 100).round()}%',
                  onChanged: (value) {
                    setState(() => _backgroundOpacity = value);
                    unawaited(ReaderOcrState.setBoxOpacity(value));
                  },
                ),
                _SliderSetting(
                  title: 'OCR box width',
                  value: _boxScale,
                  min: 0.8,
                  max: 1.5,
                  divisions: 14,
                  label: '${(_boxScale * 100).round()}%',
                  onChanged: (value) {
                    setState(() => _boxScale = value);
                    MiningPreferences.setOcrBoxScaleX(value);
                  },
                ),
                _SliderSetting(
                  title: 'OCR box height',
                  value: _boxScaleY,
                  min: 0.8,
                  max: 1.5,
                  divisions: 14,
                  label: '${(_boxScaleY * 100).round()}%',
                  onChanged: (value) {
                    setState(() => _boxScaleY = value);
                    MiningPreferences.setOcrBoxScaleY(value);
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.border_style),
                  title: const Text('Show OCR box outlines'),
                  value: _outlineVisible,
                  onChanged: (value) {
                    setState(() => _outlineVisible = value);
                    unawaited(ReaderOcrState.setOutlineVisible(value));
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.mouse),
                  title: const Text('Lookup OCR text on hover'),
                  subtitle: const Text(
                    'Open dictionary popups by hovering OCR text instead of tapping it',
                  ),
                  value: _lookupOnHover,
                  onChanged: (value) {
                    setState(() => _lookupOnHover = value);
                    unawaited(ReaderOcrState.setLookupOnHover(value));
                  },
                ),
                const ListTile(
                  leading: Icon(Icons.cloud_outlined),
                  title: Text('Google Lens OCR'),
                  subtitle: Text(
                    'Uses Chromium’s Lens endpoint. Page images are sent to Google when this engine runs.',
                  ),
                ),
                const _DictionarySettingsGroupMarker(
                  _DictionarySettingsGroup.anki,
                ),
                const Divider(height: 24),
                const _SectionHeader('Anki'),
                if (_isIOS) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: DropdownButtonFormField<AnkiIntegrationMode>(
                      key: ValueKey(_ankiIntegrationMode),
                      initialValue: _ankiIntegrationMode,
                      decoration: const InputDecoration(
                        labelText: 'iOS Anki integration',
                        prefixIcon: Icon(Icons.swap_horiz_outlined),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: AnkiIntegrationMode.ankiMobile,
                          child: Text('AnkiMobile'),
                        ),
                        DropdownMenuItem(
                          value: AnkiIntegrationMode.ankiConnect,
                          child: Text('AnkiConnect'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          _setAnkiIntegrationMode(value);
                        }
                      },
                    ),
                  ),
                  ListTile(
                    leading: Icon(
                      _usesAnkiMobile
                          ? Icons.phone_iphone_outlined
                          : Icons.lan_outlined,
                    ),
                    title: Text(
                      _usesAnkiMobile
                          ? 'Use AnkiMobile on this iPhone'
                          : 'Use an AnkiConnect server',
                    ),
                    subtitle: Text(
                      _usesAnkiMobile
                          ? 'Opens AnkiMobile through its iOS callback API when you mine a card.'
                          : 'Connects over HTTP to Anki running on a reachable computer. Use its LAN address, not 127.0.0.1.',
                    ),
                  ),
                ],
                SwitchListTile(
                  secondary: const Icon(Icons.note_add_outlined),
                  title: const Text('Enable Anki export'),
                  value: _ankiProfile.ankiEnabled,
                  onChanged: (value) =>
                      _saveAnki(_ankiProfile.copyWith(ankiEnabled: value)),
                ),
                const _SectionHeader('Anki audio'),
                SwitchListTile(
                  secondary: const Icon(Icons.volume_up_outlined),
                  title: const Text('Add word audio'),
                  subtitle: const Text(
                    'Fills {word-audio} with the first audio source match',
                  ),
                  value: _ankiAudioPreferences.enabled,
                  onChanged: (value) => _saveAnkiAudio(
                    _ankiAudioPreferences.copyWith(enabled: value),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DropdownButtonFormField<AnkiSentenceAudioFormat>(
                    initialValue: _ankiProfile.sentenceAudioFormat,
                    decoration: const InputDecoration(
                      labelText: 'Sentence audio format',
                      prefixIcon: Icon(Icons.record_voice_over_outlined),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: AnkiSentenceAudioFormat.mp3,
                        child: Text('MP3'),
                      ),
                      DropdownMenuItem(
                        value: AnkiSentenceAudioFormat.opus,
                        child: Text('Opus'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      _saveAnki(
                        _ankiProfile.copyWith(sentenceAudioFormat: value),
                      );
                    },
                  ),
                ),
                for (final indexed
                    in _ankiAudioPreferences.effectiveSources.indexed)
                  ListTile(
                    leading: CircleAvatar(
                      radius: 14,
                      child: Text('${indexed.$1 + 1}'),
                    ),
                    title: Text(indexed.$2.displayName),
                    subtitle: Text(
                      indexed.$2.isCustom
                          ? indexed.$2.url
                          : 'Built in • first available audio wins',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: indexed.$2.isCustom
                        ? () => _editAnkiAudioSource(indexed.$1)
                        : null,
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) {
                        switch (action) {
                          case 'up':
                            _moveAnkiAudioSource(indexed.$1, -1);
                          case 'down':
                            _moveAnkiAudioSource(indexed.$1, 1);
                          case 'edit':
                            _editAnkiAudioSource(indexed.$1);
                          case 'remove':
                            _removeAnkiAudioSource(indexed.$1);
                        }
                      },
                      itemBuilder: (context) => [
                        if (indexed.$1 > 0)
                          const PopupMenuItem(
                            value: 'up',
                            child: Text('Move up'),
                          ),
                        if (indexed.$1 <
                            _ankiAudioPreferences.effectiveSources.length - 1)
                          const PopupMenuItem(
                            value: 'down',
                            child: Text('Move down'),
                          ),
                        if (indexed.$2.isCustom)
                          const PopupMenuItem(
                            value: 'edit',
                            child: Text('Edit URL'),
                          ),
                        const PopupMenuItem(
                          value: 'remove',
                          child: Text('Remove'),
                        ),
                      ],
                    ),
                  ),
                ListTile(
                  leading: const Icon(Icons.add_link_outlined),
                  title: const Text('Add audio source'),
                  subtitle: const Text('Sources are tried from top to bottom'),
                  onTap: _addAnkiAudioSource,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DropdownButtonFormField<String>(
                    initialValue: _ankiAudioPreferences.language,
                    decoration: const InputDecoration(
                      labelText: 'Audio language',
                      prefixIcon: Icon(Icons.language_outlined),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'ja', child: Text('Japanese')),
                      DropdownMenuItem(value: 'en', child: Text('English')),
                      DropdownMenuItem(value: 'zh', child: Text('Chinese')),
                      DropdownMenuItem(value: 'ko', child: Text('Korean')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      final wasUsingDefaults = _usesDefaultAudioSources(
                        _ankiAudioPreferences.language,
                      );
                      _saveAnkiAudio(
                        _ankiAudioPreferences.copyWith(
                          language: value,
                          sources: wasUsingDefaults
                              ? AnkiAudioPreferences.defaultSourcesForLanguage(
                                  value,
                                )
                              : _ankiAudioPreferences.effectiveSources,
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                _SliderSetting(
                  title: 'Audio timeout',
                  value: _ankiAudioPreferences.timeout.inMilliseconds
                      .toDouble(),
                  min: 1000,
                  max: 15000,
                  divisions: 14,
                  label:
                      '${(_ankiAudioPreferences.timeout.inMilliseconds / 1000).round()} s',
                  onChanged: (value) {
                    _saveAnkiAudio(
                      _ankiAudioPreferences.copyWith(
                        timeout: Duration(milliseconds: value.round()),
                      ),
                    );
                  },
                ),
                const Divider(height: 24),
                if (!_usesAnkiMobile)
                  ListTile(
                    leading: const Icon(Icons.link),
                    title: const Text('AnkiConnect address'),
                    subtitle: Text(_ankiEndpoint.toString()),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () async {
                      final value = await _editText(
                        title: 'AnkiConnect address',
                        value: _ankiEndpoint.toString(),
                        hint: 'http://127.0.0.1:8765',
                      );
                      final endpoint = value == null
                          ? null
                          : Uri.tryParse(value.trim());
                      if (endpoint == null ||
                          !const {'http', 'https'}.contains(endpoint.scheme) ||
                          endpoint.host.isEmpty) {
                        botToast(
                          'Enter a complete http:// or https:// AnkiConnect address',
                          second: 4,
                        );
                        return;
                      }
                      if (!mounted) return;
                      setState(() => _ankiEndpoint = endpoint);
                      await MiningPreferences.setAnkiEndpoint(endpoint);
                      await _refreshAnki();
                    },
                  ),
                ListTile(
                  leading: Icon(
                    _ankiVersion == null
                        ? Icons.cloud_off_outlined
                        : Icons.check_circle_outline,
                  ),
                  title: Text(
                    _ankiVersion == null
                        ? '${_usesAnkiMobile ? 'AnkiMobile' : 'AnkiConnect'} not connected'
                        : _usesAnkiMobile
                        ? 'AnkiMobile ready'
                        : 'AnkiConnect v$_ankiVersion',
                  ),
                  subtitle: Text(
                    _ankiError ??
                        (_ankiFields.isEmpty
                            ? _usesAnkiMobile
                                  ? 'Tap Refresh to open AnkiMobile and approve access to decks and note types.'
                                  : 'Refresh to fetch decks, note types, and fields.'
                            : '${_ankiDecks.length} decks, ${_ankiModels.length} note types, ${_ankiFields.length} fields fetched.'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: _ankiRefreshing
                      ? const SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          tooltip: 'Refresh from Anki',
                          onPressed: () => _refreshAnki(),
                          icon: const Icon(Icons.refresh),
                        ),
                ),
                if (_ankiDecks.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: _ankiDecks.contains(_ankiProfile.deckName)
                          ? _ankiProfile.deckName
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Deck',
                        prefixIcon: Icon(Icons.style_outlined),
                      ),
                      hint: Text(
                        _ankiProfile.deckName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      items: [
                        for (final deck in _ankiDecks)
                          DropdownMenuItem(
                            value: deck,
                            child: Text(
                              deck,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        _saveAnki(_ankiProfile.copyWith(deckName: value));
                      },
                    ),
                  )
                else
                  ListTile(
                    leading: const Icon(Icons.style_outlined),
                    title: const Text('Deck'),
                    subtitle: Text(_ankiProfile.deckName),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () async {
                      final value = await _editText(
                        title: 'Anki deck',
                        value: _ankiProfile.deckName,
                      );
                      if (value?.trim().isEmpty ?? true) return;
                      await _saveAnki(
                        _ankiProfile.copyWith(deckName: value!.trim()),
                      );
                    },
                  ),
                const SizedBox(height: 12),
                if (_ankiModels.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: _ankiModels.contains(_ankiProfile.modelName)
                          ? _ankiProfile.modelName
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Note type',
                        prefixIcon: Icon(Icons.view_agenda_outlined),
                      ),
                      hint: Text(
                        _ankiProfile.modelName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      items: [
                        for (final model in _ankiModels)
                          DropdownMenuItem(
                            value: model,
                            child: Text(
                              model,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        _selectAnkiModel(value);
                      },
                    ),
                  )
                else
                  ListTile(
                    leading: const Icon(Icons.view_agenda_outlined),
                    title: const Text('Note type'),
                    subtitle: Text(_ankiProfile.modelName),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () async {
                      final value = await _editText(
                        title: 'Anki note type',
                        value: _ankiProfile.modelName,
                      );
                      if (value?.trim().isEmpty ?? true) return;
                      await _saveAnki(
                        _ankiProfile.copyWith(modelName: value!.trim()),
                      );
                      await _refreshAnki(silent: true);
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.sell_outlined),
                  title: const Text('Default tags'),
                  subtitle: Text(_ankiProfile.tags.join(' ')),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () async {
                    final value = await _editText(
                      title: 'Default tags',
                      value: _ankiProfile.tags.join(' '),
                      hint: 'mangatan manga',
                    );
                    if (value == null) return;
                    await _saveAnki(
                      _ankiProfile.copyWith(
                        tags: value
                            .split(RegExp(r'[\s,]+'))
                            .where((tag) => tag.isNotEmpty)
                            .toList(),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.data_object),
                  title: const Text('Field templates'),
                  subtitle: Text(
                    _ankiFields.isEmpty
                        ? '${_ankiProfile.fieldMap.length} fields configured'
                        : '${_ankiFields.length} fetched fields, ${_ankiProfile.fieldMap.length} mapped',
                  ),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: _editAnkiFieldMap,
                ),
                SwitchListTile(
                  title: const Text('Check for duplicates'),
                  subtitle: Text(
                    _usesAnkiMobile
                        ? 'Let AnkiMobile apply the note type\'s duplicate rule when adding'
                        : 'Use Anki\'s note-model duplicate rules before adding',
                  ),
                  value: _ankiProfile.duplicateCheck,
                  onChanged: (value) =>
                      _saveAnki(_ankiProfile.copyWith(duplicateCheck: value)),
                ),
                if (_ankiProfile.duplicateCheck) ...[
                  SwitchListTile(
                    title: const Text('Allow duplicates'),
                    subtitle: Text(
                      _usesAnkiMobile
                          ? 'Allow AnkiMobile to add a card whose first field already matches'
                          : 'Show duplicate state but keep the add button enabled',
                    ),
                    value: _activeProfile.duplicateAction == 'allow',
                    onChanged: (value) => _updateActiveProfile(
                      _activeProfile.copyWith(
                        anki: _ankiProfile,
                        duplicateAction: value ? 'allow' : 'prevent',
                      ),
                    ),
                  ),
                  if (!_usesAnkiMobile)
                    ListTile(
                      leading: const Icon(Icons.filter_alt_outlined),
                      title: const Text('Duplicate scope'),
                      subtitle: Text(switch (_ankiProfile.duplicateScope) {
                        'collection' => 'Entire collection',
                        'deckroot' => 'Deck root and child decks',
                        'decks' => 'Selected list of decks',
                        _ => 'Destination deck',
                      }),
                      trailing: DropdownButton<String>(
                        value:
                            const {
                              'collection',
                              'deck',
                              'deckroot',
                              'decks',
                            }.contains(_ankiProfile.duplicateScope)
                            ? _ankiProfile.duplicateScope
                            : 'deck',
                        items: const [
                          DropdownMenuItem(
                            value: 'collection',
                            child: Text('Collection'),
                          ),
                          DropdownMenuItem(value: 'deck', child: Text('Deck')),
                          DropdownMenuItem(
                            value: 'deckroot',
                            child: Text('Deck root'),
                          ),
                          DropdownMenuItem(
                            value: 'decks',
                            child: Text('Custom decks'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            _saveAnki(
                              _ankiProfile.copyWith(duplicateScope: value),
                            );
                          }
                        },
                      ),
                    ),
                  if (!_usesAnkiMobile &&
                      _ankiProfile.duplicateScope == 'decks')
                    ListTile(
                      leading: const Icon(Icons.library_books_outlined),
                      title: const Text('Decks to check'),
                      subtitle: Text(
                        <String>{
                          _ankiProfile.deckName,
                          ..._ankiProfile.duplicateDeckNames,
                        }.join(', '),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: _editAnkiDuplicateDecks,
                    ),
                  if (_usesAnkiMobile)
                    const ListTile(
                      leading: Icon(Icons.library_books_outlined),
                      title: Text('Duplicate decks'),
                      subtitle: Text(
                        'AnkiMobile checks the first field across all decks that use the selected note type. Its callback API cannot limit the check to a custom deck list.',
                      ),
                    ),
                  if (!_usesAnkiMobile)
                    SwitchListTile(
                      title: const Text('Check all note types'),
                      subtitle: const Text(
                        'Match the first field across every Anki model',
                      ),
                      value: _ankiProfile.checkAllModels,
                      onChanged: (value) => _saveAnki(
                        _ankiProfile.copyWith(checkAllModels: value),
                      ),
                    ),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DropdownButtonFormField<AnkiScreenshotMode>(
                    initialValue: _activeProfile.screenshotMode,
                    decoration: const InputDecoration(
                      labelText: 'Screenshot',
                      prefixIcon: Icon(Icons.photo_camera_outlined),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: AnkiScreenshotMode.full,
                        child: Text('Full image'),
                      ),
                      DropdownMenuItem(
                        value: AnkiScreenshotMode.crop,
                        child: Text('Crop manga image'),
                      ),
                      DropdownMenuItem(
                        value: AnkiScreenshotMode.noScreenshot,
                        child: Text('No screenshot'),
                      ),
                      DropdownMenuItem(
                        value: AnkiScreenshotMode.animatedScene,
                        child: Text('Animated scene (desktop only)'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      _updateActiveProfile(
                        _activeProfile.copyWith(cropMode: value.wireValue),
                      );
                    },
                  ),
                ),
                if (_usesAnkiMobile)
                  const ListTile(
                    leading: Icon(Icons.sync_outlined),
                    title: Text('Sync in AnkiMobile'),
                    subtitle: Text(
                      'Mangatan returns after adding; use AnkiMobile\'s normal automatic or manual sync.',
                    ),
                  )
                else
                  SwitchListTile(
                    title: const Text('Sync after adding a note'),
                    value: _ankiProfile.syncOnCreate,
                    onChanged: (value) =>
                        _saveAnki(_ankiProfile.copyWith(syncOnCreate: value)),
                  ),
                const SizedBox(height: 24),
              ]),
            ),
    );
  }
}

enum _DictionarySettingsGroup { profiles, dictionaries, popup, anki }

class _DictionarySettingsGroupMarker extends StatelessWidget {
  const _DictionarySettingsGroupMarker(this.group);

  final _DictionarySettingsGroup group;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _DictionaryListTile extends StatelessWidget {
  const _DictionaryListTile({
    super.key,
    required this.dictionary,
    required this.index,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.enabled,
    required this.displayMode,
    required this.onEnabledChanged,
    required this.onDisplayModeChanged,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.update,
    required this.onRename,
    required this.onUpdate,
    required this.onDelete,
  });

  final InstalledDictionary dictionary;
  final int index;
  final bool canMoveUp;
  final bool canMoveDown;
  final bool enabled;
  final String? displayMode;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<String> onDisplayModeChanged;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final DictionaryUpdateInfo? update;
  final VoidCallback onRename;
  final VoidCallback onUpdate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final details = [
      if (dictionary.hasTerms) 'Terms',
      if (dictionary.hasFrequencies) 'Frequency',
      if (dictionary.hasPitch) 'Pitch',
      if (dictionary.hasKanji) 'Kanji',
      if (dictionary.revision?.isNotEmpty == true)
        'Revision ${dictionary.revision}',
      if (update?.hasUpdate == true)
        'Update ${update!.latestRevision} available',
      if (update?.error != null) 'Update check failed',
    ];
    return ListTile(
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ReorderableDragStartListener(
            index: index,
            child: const Tooltip(
              message: 'Drag to reorder dictionary',
              child: Icon(Icons.drag_indicator),
            ),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.menu_book_outlined),
        ],
      ),
      title: Text(
        dictionary.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        details.isEmpty ? 'No lookup data' : details.join(' • '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (displayMode != null)
            PopupMenuButton<String>(
              tooltip: 'Dictionary display mode',
              initialValue: displayMode,
              onSelected: onDisplayModeChanged,
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'always_expanded',
                  child: Text('Always expanded'),
                ),
                PopupMenuItem(value: 'fallback', child: Text('Fallback')),
                PopupMenuItem(
                  value: 'always_collapsed',
                  child: Text('Always collapsed'),
                ),
              ],
              icon: Icon(
                displayMode == 'always_expanded'
                    ? Icons.unfold_more
                    : displayMode == 'always_collapsed'
                    ? Icons.unfold_less
                    : Icons.low_priority,
              ),
            ),
          Switch(value: enabled, onChanged: onEnabledChanged),
          PopupMenuButton<String>(
            tooltip: 'Dictionary actions',
            onSelected: (action) {
              switch (action) {
                case 'update':
                  onUpdate();
                  break;
                case 'rename':
                  onRename();
                  break;
                case 'up':
                  onMoveUp();
                  break;
                case 'down':
                  onMoveDown();
                  break;
                case 'delete':
                  onDelete();
                  break;
              }
            },
            itemBuilder: (context) => [
              if (update?.hasUpdate == true)
                const PopupMenuItem(
                  value: 'update',
                  child: ListTile(
                    leading: Icon(Icons.system_update_alt),
                    title: Text('Update'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              const PopupMenuItem(
                value: 'rename',
                child: ListTile(
                  leading: Icon(Icons.edit_outlined),
                  title: Text('Rename'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'up',
                enabled: canMoveUp,
                child: const ListTile(
                  leading: Icon(Icons.keyboard_arrow_up),
                  title: Text('Move up'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'down',
                enabled: canMoveDown,
                child: const ListTile(
                  leading: Icon(Icons.keyboard_arrow_down),
                  title: Text('Move down'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  leading: Icon(Icons.delete_outline),
                  title: Text('Remove'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AnkiFieldTemplatePicker extends StatelessWidget {
  const _AnkiFieldTemplatePicker({
    required this.fieldName,
    required this.value,
    required this.dynamicTemplates,
    required this.onChanged,
    required this.onEditCustom,
  });

  final String fieldName;
  final String value;
  final Map<String, String> dynamicTemplates;
  final ValueChanged<String> onChanged;
  final VoidCallback onEditCustom;

  @override
  Widget build(BuildContext context) {
    final templates = <String, String>{
      'Leave empty': '',
      ...AnkiMarker.standardTemplates,
      ...dynamicTemplates,
    };
    final isStandard = templates.containsValue(value);
    final items = <DropdownMenuItem<String>>[
      if (!isStandard && value.trim().isNotEmpty)
        DropdownMenuItem(value: value, child: Text('Custom: $value')),
      for (final entry in templates.entries)
        DropdownMenuItem(value: entry.value, child: Text(entry.key)),
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              fieldName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: value,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Template'),
            items: items,
            onChanged: (next) {
              if (next != null) onChanged(next);
            },
          ),
        ),
        IconButton(
          tooltip: 'Edit custom template',
          onPressed: onEditCustom,
          icon: const Icon(Icons.edit_outlined),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;

  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}

class _SliderSetting extends StatelessWidget {
  final String title;
  final String? description;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final ValueChanged<double> onChanged;

  const _SliderSetting({
    required this.title,
    this.description,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (description != null) ...[
            const SizedBox(height: 4),
            Text(description!),
          ],
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: label,
            onChanged: onChanged,
          ),
        ],
      ),
      trailing: SizedBox(
        width: 48,
        child: Text(label, textAlign: TextAlign.end),
      ),
    );
  }
}
