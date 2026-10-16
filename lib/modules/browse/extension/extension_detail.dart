import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/eval/model/m_bridge.dart';
import 'package:mangayomi/eval/model/source_preference.dart';
import 'package:mangayomi/eval/mihon/bridge_protocol.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/changed.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/browse/extension/providers/extension_preferences_providers.dart';
import 'package:mangayomi/modules/browse/extension/extension_package.dart';
import 'package:mangayomi/modules/browse/extension/widgets/source_preference_widget.dart';
import 'package:mangayomi/modules/browse/widgets/source_extension_icon.dart';
import 'package:mangayomi/modules/mining/widgets/dictionary_profile_override_dialog.dart';
import 'package:mangayomi/modules/more/settings/browse/providers/browse_state_provider.dart';
import 'package:mangayomi/modules/more/settings/sync/providers/sync_providers.dart';
import 'package:mangayomi/modules/widgets/desktop_back_navigation_handler.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/services/get_source_preference.dart';
import 'package:mangayomi/services/fetch_sources_list.dart';
import 'package:mangayomi/services/http/m_client.dart';
import 'package:mangayomi/services/m_extension_server.dart';
import 'package:mangayomi/services/mihon_source_preferences.dart';
import 'package:mangayomi/services/mining/dictionary_profile.dart';
import 'package:mangayomi/services/mining/dictionary_profile_resolver.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';
import 'package:mangayomi/services/reconcile_mihon_sources.dart';
import 'package:mangayomi/services/uninstall_extension.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';
import 'package:mangayomi/utils/language.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:isar_community/isar.dart';

class ExtensionDetail extends ConsumerStatefulWidget {
  final Source source;
  const ExtensionDetail({super.key, required this.source});

  @override
  ConsumerState<ExtensionDetail> createState() => _ExtensionDetailState();
}

class _ExtensionDetailState extends ConsumerState<ExtensionDetail> {
  late Source source;
  late List<Source> _packageSources;
  List<SourcePreference>? sourcePreference;
  bool _isRefreshingPreferences = false;
  String _dictionaryProfileLabel = 'Loading…';

  String? get _dictionaryProfileSourceId =>
      DictionaryProfileResolver.overrideIdForSource(source);

  String get _extensionName {
    final name = mihonSourceMetadata(source)?.extensionName;
    return name?.isNotEmpty == true ? name! : source.name ?? '';
  }

  String get _extensionLang {
    final lang = mihonSourceMetadata(source)?.packageLang;
    return lang?.isNotEmpty == true ? lang! : source.lang ?? '';
  }

  List<SourcePreference>? _loadSourcePreferences(Source selectedSource) {
    try {
      if (selectedSource.sourceCodeLanguage == SourceCodeLanguage.mihon &&
          selectedSource.preferenceList != null) {
        return decodeMihonSourcePreferences(selectedSource.preferenceList);
      }
      return getSourcePreference(source: selectedSource)
          .map((e) => getSourcePreferenceEntry(e.key!, selectedSource.id!))
          .toList();
    } catch (e) {
      return null;
    }
  }

  List<Source> _loadPackageSources(Source selectedSource) {
    return extensionSettingsSources(
      selectedSource,
      isar.sources.filter().idIsNotNull().findAllSync(),
    );
  }

  @override
  void initState() {
    super.initState();
    source = isar.sources.getSync(widget.source.id!)!;
    _packageSources = _loadPackageSources(source);
    sourcePreference = _loadSourcePreferences(source);
    unawaited(_loadDictionaryProfileLabel());
    if (source.sourceCodeLanguage == SourceCodeLanguage.mihon) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _refreshMihonPreferences();
      });
    }
  }

  Future<void> _selectSourceSettings(int? sourceId) async {
    if (sourceId == null || sourceId == source.id) return;
    final selectedSource = isar.sources.getSync(sourceId);
    if (selectedSource == null) return;

    setState(() {
      source = selectedSource;
      sourcePreference = _loadSourcePreferences(selectedSource);
      _dictionaryProfileLabel = 'Loading…';
    });
    await _loadDictionaryProfileLabel();
    await _refreshMihonPreferences();
  }

  Future<void> _loadDictionaryProfileLabel() async {
    final sourceId = _dictionaryProfileSourceId;
    if (sourceId == null) return;
    final values = await Future.wait<dynamic>([
      MiningPreferences.getDictionaryProfiles(),
      MiningPreferences.getDictionaryProfileOverride(
        DictionaryProfileResolver.sourceOverrideKey(sourceId),
      ),
      DictionaryProfileResolver.resolve(
        sourceLanguage: DictionaryProfileResolver.sourceLanguageForSource(
          source,
        ),
      ),
    ]);
    if (!mounted) return;
    final profiles = values[0] as List<DictionaryProfile>;
    final overrideId = values[1] as String;
    final autoProfile = values[2] as DictionaryProfile;
    final overrideProfile = profiles
        .where((profile) => profile.id == overrideId)
        .firstOrNull;
    setState(() {
      _dictionaryProfileLabel =
          overrideProfile?.name ?? 'Auto (${autoProfile.name})';
    });
  }

  Future<void> _selectDictionaryProfile() async {
    final sourceId = _dictionaryProfileSourceId;
    if (sourceId == null) return;
    final changed = await showDictionaryProfileOverrideDialog(
      context: context,
      overrideKey: DictionaryProfileResolver.sourceOverrideKey(sourceId),
      autoProfile: DictionaryProfileResolver.resolve(
        sourceLanguage: DictionaryProfileResolver.sourceLanguageForSource(
          source,
        ),
      ),
      title: 'Dictionary profile for this source',
    );
    if (changed) await _loadDictionaryProfileLabel();
  }

  Future<void> _refreshMihonPreferences({
    SourcePreference? changedPreference,
  }) async {
    if (_isRefreshingPreferences ||
        source.sourceCodeLanguage != SourceCodeLanguage.mihon ||
        source.sourceCode?.isEmpty != false) {
      return;
    }

    setState(() => _isRefreshingPreferences = true);
    final previous = sourcePreference ?? const <SourcePreference>[];
    final client = MClient.init(reqcopyWith: {'useDartHttpClient': true});
    try {
      await MExtensionServerPlatform(ref).startServer();
      if (!mounted) return;
      final proxyServer = ref.read(androidProxyServerStateProvider);
      var fresh = await fetchPreferencesDalvik(
        client,
        source,
        proxyServer,
        preferences: previous,
        changedPreferenceKey: changedPreference?.key,
      );
      var appliedPreferences = previous;
      final changedKey = changedPreference?.key;
      if (fresh != null && changedKey != null) {
        appliedPreferences = mergeMihonPreferenceValues(
          fresh,
          previous,
          preserveFreshKeys: {changedKey},
        );
      }

      if (fresh == null && changedPreference != null) {
        fresh = await fetchPreferencesDalvik(
          client,
          source,
          proxyServer,
          preferences: appliedPreferences,
        );
      }

      if (fresh == null) return;
      var merged = mergeMihonPreferenceValues(fresh, appliedPreferences);
      source.preferenceList = jsonEncode(
        merged.map((preference) => preference.toJson()).toList(),
      );
      if (changedKey != null) {
        final acceptedPreference = merged
            .where((preference) => preference.key == changedKey)
            .firstOrNull;
        if (acceptedPreference != null) {
          setPreferenceSetting(acceptedPreference, source);
        }
      }
      await isar.writeTxn(() => isar.sources.put(source));
      final descriptors = await fetchMihonSourceDescriptors(
        client,
        source,
        proxyServer,
        preferences: merged,
      );
      if (descriptors != null) {
        await reconcileMihonFactorySources(source, descriptors);
        final canonical = isar.sources.getSync(source.id!);
        if (canonical != null) {
          source = canonical;
          _packageSources = _loadPackageSources(canonical);
          merged = mergeMihonPreferenceValues(
            decodeMihonSourcePreferences(canonical.preferenceList),
            merged,
          );
        }
      }

      // Factory extensions can cache their server address and credentials in
      // each child instance. Source discovery above recreates those children;
      // preference screens fetched before that point would keep polling the
      // stale instance and never expose asynchronously loaded values such as
      // Jellyfin libraries.
      if (changedPreference?.editTextPreference != null) {
        for (final delay in const [
          Duration.zero,
          Duration(milliseconds: 750),
          Duration(milliseconds: 1500),
        ]) {
          if (delay > Duration.zero) await Future<void>.delayed(delay);
          final refreshed = await fetchPreferencesDalvik(
            client,
            source,
            proxyServer,
            preferences: merged,
          );
          if (refreshed != null) {
            merged = mergeMihonPreferenceValues(refreshed, merged);
          }
        }
        source.preferenceList = jsonEncode(
          merged.map((preference) => preference.toJson()).toList(),
        );
        await isar.writeTxn(() => isar.sources.put(source));
      }
      if (mounted) setState(() => sourcePreference = merged);
    } finally {
      if (mounted) setState(() => _isRefreshingPreferences = false);
    }
  }

  Future<void> _launchInBrowser(Uri url) async {
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw 'Could not launch $url';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nLocalizations(context)!;
    void goBack() => Navigator.pop(context, source);

    final page = Scaffold(
      appBar: AppBar(
        title: Text(l10n.extension_detail),
        leading: BackButton(onPressed: goBack),
        actions: [
          if (source.sourceCodeLanguage == SourceCodeLanguage.mihon)
            IconButton(
              tooltip: l10n.refresh,
              onPressed: _isRefreshingPreferences
                  ? null
                  : _refreshMihonPreferences,
              icon: const Icon(Icons.refresh),
            ),
          if (source.repo?.website != null)
            IconButton(
              onPressed: () {
                _launchInBrowser(Uri.parse(source.repo!.website!));
              },
              icon: Icon(Icons.open_in_new_outlined),
            ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).secondaryHeaderColor.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SourceExtensionIcon(
                  source: widget.source,
                  size: 140,
                  fallbackIcon: Icons.source_outlined,
                  fallbackIconSize: 140,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _extensionName,
                style: const TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Container(
                decoration: BoxDecoration(
                  color: context.primaryColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        children: [
                          Text(
                            widget.source.version!,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            l10n.version,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                      Column(
                        children: [
                          Text(
                            completeLanguageName(_extensionLang),
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            l10n.language,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_packageSources.length > 1)
              ListTile(
                leading: const Icon(Icons.source_outlined),
                title: const Text('Source settings'),
                subtitle: Text(source.name ?? ''),
                trailing: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: source.id,
                    onChanged: _isRefreshingPreferences
                        ? null
                        : _selectSourceSettings,
                    items: _packageSources
                        .map(
                          (packageSource) => DropdownMenuItem<int>(
                            value: packageSource.id,
                            child: Text(packageSource.name ?? ''),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
            if (_dictionaryProfileSourceId != null)
              ListTile(
                leading: const Icon(Icons.menu_book_outlined),
                title: const Text('Dictionary profile'),
                subtitle: Text(_dictionaryProfileLabel),
                trailing: const Icon(Icons.arrow_drop_down),
                onTap: _selectDictionaryProfile,
              ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: SizedBox(
                width: context.width(1),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.all(0),
                    backgroundColor: Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5),
                    ),
                    elevation: 0,
                    shadowColor: Colors.transparent,
                  ),
                  onPressed: () async {
                    final res = await context.push(
                      '/codeEditor',
                      extra: source.id,
                    );
                    if (res != null && mounted) {
                      setState(() {
                        source = res as Source;
                        sourcePreference = getSourcePreference(source: source)
                            .map(
                              (e) =>
                                  getSourcePreferenceEntry(e.key!, source.id!),
                            )
                            .toList();
                      });
                    }
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Text(
                          l10n.edit_code,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const Icon(Icons.code),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: SizedBox(
                width: context.width(1),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.all(0),
                    backgroundColor: Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5),
                    ),
                    elevation: 0,
                    shadowColor: Colors.transparent,
                  ),
                  onPressed: () async {
                    MClient.deleteAllCookies(source.baseUrl ?? "");
                    botToast("Cookies deleted!");
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      "Delete all cookies",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: SizedBox(
                width: context.width(1),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.all(0),
                    side: BorderSide(color: context.primaryColor, width: 0.3),
                    backgroundColor: Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5),
                    ),
                    elevation: 0,
                    shadowColor: Colors.transparent,
                  ),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (ctx) {
                        return AlertDialog(
                          title: Text(_extensionName),
                          content: Text(
                            l10n.uninstall_extension(_extensionName),
                          ),
                          actions: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton(
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                  },
                                  child: Text(l10n.cancel),
                                ),
                                const SizedBox(width: 15),
                                TextButton(
                                  onPressed: () {
                                    final result = uninstallExtension(source);
                                    for (final sourceId
                                        in result.removedObsoleteSourceIds) {
                                      ref
                                          .read(
                                            synchingProvider(
                                              syncId: 1,
                                            ).notifier,
                                          )
                                          .addChangedPart(
                                            ActionType.removeExtension,
                                            sourceId,
                                            "{}",
                                            false,
                                          );
                                    }

                                    Navigator.pop(ctx);
                                    Navigator.pop(context);
                                  },
                                  child: Text(l10n.ok),
                                ),
                              ],
                            ),
                          ],
                        );
                      },
                    );
                  },
                  child: Text(
                    l10n.uninstall,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
            if (sourcePreference != null)
              SourcePreferenceWidget(
                key: ValueKey(source.id),
                sourcePreference: sourcePreference!,
                source: source,
                isRefreshing: _isRefreshingPreferences,
                onPreferenceChanged: (preference) =>
                    _refreshMihonPreferences(changedPreference: preference),
              ),
          ],
        ),
      ),
    );
    return DesktopBackNavigationScope(
      onBack: goBack,
      child: Focus(autofocus: true, child: page),
    );
  }
}
