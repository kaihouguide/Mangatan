import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mangayomi/modules/mining/widgets/ocr_processing_queue_sheet.dart';
import 'package:mangayomi/modules/mining/widgets/reader_ocr_overlay.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';
import 'package:mangayomi/services/mining/ocr_processing_queue.dart';
import 'package:mangayomi/services/mining/anime_text_detection_service.dart';
import 'package:mangayomi/services/reader/panel_detection_service.dart';

class OcrSettingsScreen extends StatefulWidget {
  const OcrSettingsScreen({super.key});

  @override
  State<OcrSettingsScreen> createState() => _OcrSettingsScreenState();
}

class _OcrSettingsScreenState extends State<OcrSettingsScreen> {
  bool _loading = true;
  bool _enabled = true;
  bool _mokuro = true;
  bool _outline = false;
  bool _hover = false;
  bool _panelNavigation = false;
  bool _animeTextEnabled = false;
  double _passiveBackground = MiningPreferences.defaultOcrBackgroundOpacity;
  double _activeText = MiningPreferences.defaultOcrTextOpacity;
  double _activeBackground =
      MiningPreferences.defaultActiveOcrBackgroundOpacity;
  double _scaleX = 1;
  double _scaleY = 1;
  int _parallel = 1;
  OcrEnginePreference _engine = OcrEnginePreference.automatic;
  OcrScanTrigger _scanTrigger = OcrScanTrigger.automatic;
  final _hayaiEndpoint = TextEditingController();
  final _hayaiApiKey = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _loadValues();
    } catch (error) {
      // Keep the page usable with its defaults rather than spinning forever.
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load OCR settings: $error')),
      );
    }
  }

  Future<void> _loadValues() async {
    await ReaderOcrState.initialize();
    final values = await Future.wait<dynamic>([
      MiningPreferences.getMokuroWebsiteOcrEnabled(),
      MiningPreferences.getOcrBoxScaleX(),
      MiningPreferences.getOcrBoxScaleY(),
      MiningPreferences.getPanelNavigationEnabled(),
      PanelDetectionService.instance.isModelReady(),
      MiningPreferences.getAnimeTextDetectionEnabled(),
      AnimeTextDetectionService.instance.isModelReady(),
      MiningPreferences.getHayaiOcrEndpoint(),
      MiningPreferences.getHayaiOcrApiKey(),
    ]);
    if (!mounted) return;
    setState(() {
      _enabled = ReaderOcrState.enabled.value;
      _engine = ReaderOcrState.engine.value;
      _parallel = ReaderOcrState.parallelOcrLimit.value;
      _scanTrigger = ReaderOcrState.scanTrigger.value;
      _passiveBackground = ReaderOcrState.boxOpacity.value;
      _activeText = ReaderOcrState.activeTextOpacity.value;
      _activeBackground = ReaderOcrState.activeBackgroundOpacity.value;
      _outline = ReaderOcrState.outlineVisible.value;
      _hover = ReaderOcrState.lookupOnHover.value;
      _mokuro = values[0] as bool;
      _scaleX = values[1] as double;
      _scaleY = values[2] as double;
      _panelNavigation = values[3] as bool;
      _animeTextEnabled = values[5] as bool;
      _hayaiEndpoint.text = (values[7] as Uri).toString();
      _hayaiApiKey.text = values[8] as String;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _hayaiEndpoint.dispose();
    _hayaiApiKey.dispose();
    super.dispose();
  }

  Future<void> _importAnimeTextModel() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['tflite'],
    );
    final selected = result.singleOrNull?.path;
    if (selected == null) return;
    try {
      await AnimeTextDetectionService.instance.importModel(File(selected));
      await MiningPreferences.setAnimeTextDetectionEnabled(true);
      if (mounted) setState(() => _animeTextEnabled = true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not import AnimeText model: $error')),
      );
    }
  }

  Future<void> _setAnimeTextEnabled(bool enabled) async {
    if (enabled && !await AnimeTextDetectionService.instance.isModelReady()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Import the AnimeText LiteRT model first'),
          ),
        );
      }
      return;
    }
    await MiningPreferences.setAnimeTextDetectionEnabled(enabled);
    if (mounted) setState(() => _animeTextEnabled = enabled);
  }

  Future<void> _saveHayaiEndpoint(String raw) async {
    final endpoint = Uri.tryParse(raw.trim());
    if (endpoint == null || !endpoint.hasScheme || endpoint.host.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a valid Hayai server URL')),
        );
      }
      return;
    }
    await MiningPreferences.setHayaiOcrEndpoint(endpoint);
  }

  Future<void> _setPanelNavigation(bool enabled) async {
    setState(() => _panelNavigation = enabled);
    await MiningPreferences.setPanelNavigationEnabled(enabled);
    if (!enabled) return;
    try {
      await PanelDetectionService.instance.ensureModel();
    } catch (error) {
      await MiningPreferences.setPanelNavigationEnabled(false);
      if (!mounted) return;
      setState(() => _panelNavigation = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not prepare panel detector: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OCR & panel navigation')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const _SectionHeader('Recognition engine'),
                SwitchListTile(
                  secondary: const Icon(Icons.document_scanner_outlined),
                  title: const Text('Show OCR in reader'),
                  subtitle: const Text('Recognize text on manga pages'),
                  value: _enabled,
                  onChanged: (value) {
                    setState(() => _enabled = value);
                    unawaited(ReaderOcrState.setEnabled(value));
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DropdownButtonFormField<OcrEnginePreference>(
                    initialValue: _engine,
                    decoration: const InputDecoration(labelText: 'OCR engine'),
                    items: [
                      for (final engine in availableOcrEngines())
                        DropdownMenuItem(
                          value: engine,
                          child: Text(ocrEngineLabel(engine)),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _engine = value);
                      unawaited(ReaderOcrState.setEngine(value));
                    },
                  ),
                ),
                if (_engine == OcrEnginePreference.hayai)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: TextField(
                      controller: _hayaiEndpoint,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Hayai OCR server',
                        hintText: 'http://127.0.0.1:8766',
                        helperText: 'Mangatan appends /v1/ocr. Use the computer LAN address from iOS.',
                      ),
                      onSubmitted: (value) =>
                          unawaited(_saveHayaiEndpoint(value)),
                      onTapOutside: (_) =>
                          unawaited(_saveHayaiEndpoint(_hayaiEndpoint.text)),
                    ),
                  ),
                if (_engine == OcrEnginePreference.hayai)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: TextField(
                      controller: _hayaiApiKey,
                      obscureText: true,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Hayai server API key (optional)',
                      ),
                      onSubmitted: (value) =>
                          unawaited(MiningPreferences.setHayaiOcrApiKey(value)),
                      onTapOutside: (_) => unawaited(
                        MiningPreferences.setHayaiOcrApiKey(_hayaiApiKey.text),
                      ),
                    ),
                  ),
                ListTile(
                  leading: const Icon(Icons.account_tree_outlined),
                  title: const Text('Parallel OCR tasks'),
                  subtitle: const Text('Higher values use more power'),
                  trailing: DropdownButton<int>(
                    value: _parallel,
                    items: [
                      for (var value = 1; value <= 4; value++)
                        DropdownMenuItem(value: value, child: Text('$value')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _parallel = value);
                      unawaited(ReaderOcrState.setParallelOcrLimit(value));
                    },
                  ),
                ),
                const _SectionHeader('AnimeText detection'),
                SwitchListTile(
                  secondary: const Icon(Icons.text_fields_outlined),
                  title: const Text('Detect text boxes before OCR'),
                  subtitle: Text(
                    _engine == OcrEnginePreference.hayai
                        ? 'Required by Hayai because it recognizes crops, not full pages'
                        : 'Crop detected regions before sending them to the selected OCR engine',
                  ),
                  value:
                      _engine == OcrEnginePreference.hayai || _animeTextEnabled,
                  onChanged: _engine == OcrEnginePreference.hayai
                      ? null
                      : (value) => unawaited(_setAnimeTextEnabled(value)),
                ),
                ValueListenableBuilder<AnimeTextModelStatus>(
                  valueListenable: AnimeTextDetectionService.instance.status,
                  builder: (context, status, _) => ListTile(
                    leading: const Icon(Icons.center_focus_strong_outlined),
                    title: const Text('AnimeText YOLO12n LiteRT model'),
                    subtitle: Text(switch (status) {
                      AnimeTextModelStatus.missing =>
                        'Prepare the model once, then import its .tflite file',
                      AnimeTextModelStatus.importing => 'Importing…',
                      AnimeTextModelStatus.ready => 'Ready for offline use',
                      AnimeTextModelStatus.error =>
                        'Unsupported or damaged model',
                    }),
                    trailing: status == AnimeTextModelStatus.ready
                        ? TextButton(
                            onPressed: () async {
                              await AnimeTextDetectionService.instance
                                  .deleteModel();
                              await MiningPreferences.setAnimeTextDetectionEnabled(
                                false,
                              );
                              if (mounted) {
                                setState(() => _animeTextEnabled = false);
                              }
                            },
                            child: const Text('Remove'),
                          )
                        : TextButton(
                            onPressed: status == AnimeTextModelStatus.importing
                                ? null
                                : _importAnimeTextModel,
                            child: const Text('Import'),
                          ),
                  ),
                ),
                const ListTile(
                  leading: Icon(Icons.download_outlined),
                  title: Text('Prepare AnimeText on a desktop'),
                  subtitle: Text(
                    'Hugging Face requires account access for the checkpoint. Run hf auth login, then run tool/export_animetext_litert.py and import the result here.',
                  ),
                ),
                const _SectionHeader('OCR boxes'),
                _OcrSlider(
                  title: 'Passive background opacity',
                  value: _passiveBackground,
                  onChanged: (value) {
                    setState(() => _passiveBackground = value);
                    unawaited(ReaderOcrState.setBoxOpacity(value));
                  },
                ),
                _OcrSlider(
                  title: 'Active text opacity',
                  value: _activeText,
                  onChanged: (value) {
                    setState(() => _activeText = value);
                    unawaited(ReaderOcrState.setActiveTextOpacity(value));
                  },
                ),
                _OcrSlider(
                  title: 'Active background opacity',
                  value: _activeBackground,
                  onChanged: (value) {
                    setState(() => _activeBackground = value);
                    unawaited(ReaderOcrState.setActiveBackgroundOpacity(value));
                  },
                ),
                _OcrSlider(
                  title: 'Box width',
                  value: _scaleX,
                  min: .8,
                  max: 1.5,
                  divisions: 14,
                  onChanged: (value) {
                    setState(() => _scaleX = value);
                    unawaited(MiningPreferences.setOcrBoxScaleX(value));
                  },
                ),
                _OcrSlider(
                  title: 'Box height',
                  value: _scaleY,
                  min: .8,
                  max: 1.5,
                  divisions: 14,
                  onChanged: (value) {
                    setState(() => _scaleY = value);
                    unawaited(MiningPreferences.setOcrBoxScaleY(value));
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.border_style_outlined),
                  title: const Text('Show box outlines'),
                  value: _outline,
                  onChanged: (value) {
                    setState(() => _outline = value);
                    unawaited(ReaderOcrState.setOutlineVisible(value));
                  },
                ),
                const _SectionHeader('Behavior'),
                ListTile(
                  leading: const Icon(Icons.touch_app_outlined),
                  title: const Text('Recognition trigger'),
                  trailing: DropdownButton<OcrScanTrigger>(
                    value: _scanTrigger,
                    items: const [
                      DropdownMenuItem(
                        value: OcrScanTrigger.automatic,
                        child: Text('Automatic'),
                      ),
                      DropdownMenuItem(
                        value: OcrScanTrigger.manual,
                        child: Text('On tap'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _scanTrigger = value);
                      unawaited(ReaderOcrState.setScanTrigger(value));
                    },
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.cloud_download_outlined),
                  title: const Text('Use Mokuro website OCR'),
                  subtitle: const Text('Prefer saved OCR when available'),
                  value: _mokuro,
                  onChanged: (value) {
                    setState(() => _mokuro = value);
                    unawaited(
                      MiningPreferences.setMokuroWebsiteOcrEnabled(value),
                    );
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.mouse_outlined),
                  title: const Text('Lookup text on hover'),
                  subtitle: const Text('Available on desktop pointer devices'),
                  value: _hover,
                  onChanged: (value) {
                    setState(() => _hover = value);
                    unawaited(ReaderOcrState.setLookupOnHover(value));
                  },
                ),
                const _SectionHeader('AI panel navigation'),
                SwitchListTile(
                  secondary: const Icon(Icons.view_quilt_outlined),
                  title: const Text('Panel-by-panel navigation'),
                  subtitle: const Text(
                    'Use on-device LiteRT panel and speech-bubble detection in paged reading modes',
                  ),
                  value: _panelNavigation,
                  onChanged: (value) => unawaited(_setPanelNavigation(value)),
                ),
                ValueListenableBuilder<PanelModelStatus>(
                  valueListenable: PanelDetectionService.instance.status,
                  builder: (context, status, _) => ListTile(
                    leading: const Icon(Icons.memory_outlined),
                    title: const Text('Panel detection model'),
                    subtitle: Text(switch (status) {
                      PanelModelStatus.missing => 'Not downloaded',
                      PanelModelStatus.downloading => 'Downloading…',
                      PanelModelStatus.ready => 'Ready for offline use',
                      PanelModelStatus.error => 'Download failed',
                    }),
                    trailing: status == PanelModelStatus.ready
                        ? TextButton(
                            onPressed: () async {
                              await PanelDetectionService.instance
                                  .deleteModel();
                              await MiningPreferences.setPanelNavigationEnabled(
                                false,
                              );
                              if (mounted) {
                                setState(() => _panelNavigation = false);
                              }
                            },
                            child: const Text('Remove'),
                          )
                        : null,
                  ),
                ),
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('Runs locally after the first download'),
                  subtitle: Text(
                    'The Apache-2.0 YOLO detector is shared across iOS, Android, macOS, Windows, and Linux. No page images are uploaded.',
                  ),
                ),
                const _SectionHeader('Processing queue'),
                ValueListenableBuilder<List<OcrQueueEntry>>(
                  valueListenable:
                      OcrProcessingQueueController.instance.entries,
                  builder: (context, entries, _) {
                    final failed = entries
                        .where((entry) => entry.status == OcrQueueStatus.error)
                        .length;
                    return ListTile(
                      leading: const Icon(Icons.playlist_add_check_outlined),
                      title: const Text('OCR processing queue'),
                      subtitle: Text(
                        failed > 0
                            ? '$failed failed · tap a chapter to retry'
                            : '${entries.length} chapter${entries.length == 1 ? '' : 's'}',
                      ),
                      onTap: () => showOcrProcessingQueueSheet(context),
                    );
                  },
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
    child: Text(title, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _OcrSlider extends StatelessWidget {
  const _OcrSlider({
    required this.title,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions = 20,
  });

  final String title;
  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final int divisions;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(title),
    subtitle: Slider(
      value: value.clamp(min, max),
      min: min,
      max: max,
      divisions: divisions,
      label: '${(value * 100).round()}%',
      onChanged: onChanged,
    ),
    trailing: SizedBox(
      width: 48,
      child: Text('${(value * 100).round()}%', textAlign: TextAlign.end),
    ),
  );
}
