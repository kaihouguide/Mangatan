import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/modules/mining/widgets/hoshi_dictionary_popup.dart';
import 'package:mangayomi/services/mining/dictionary_profile.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';
import 'package:mangayomi/src/rust/api/hoshidicts.dart';

void main() {
  test('dictionary popup preferences compare by their rendered values', () {
    const preferences = DictionaryPopupPreferences(
      width: 430,
      height: 360,
      fontSize: 14,
      theme: DictionaryThemePreference.system,
      eInkMode: false,
      paginatedScrolling: false,
      customCss: '',
      showFrequencyHarmonic: false,
      showFrequencyAverage: false,
      showPitchNumber: true,
      showPitchText: true,
    );

    expect(preferences, preferences.copyWith());
    expect(preferences, isNot(preferences.copyWith(fontSize: 15)));
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  test('converts lookup results to Hoshi popup entry schema', () {
    final result = HoshiLookupResult(
      matched: '食べた',
      deinflected: '食べる',
      trace: const [
        HoshiTransformGroup(name: 'past', description: 'past tense'),
      ],
      preprocessorSteps: 0,
      term: HoshiTermResult(
        expression: '食べる',
        reading: 'たべる',
        rules: 'v1 vt',
        score: 1,
        glossaries: const [
          HoshiGlossaryEntry(
            dictName: 'JMdict',
            glossary: 'to eat',
            definitionTags: 'v1 vt',
            termTags: 'ichi1',
          ),
        ],
        frequencies: const [
          HoshiFrequencyEntry(
            dictName: 'Jiten',
            frequencies: [HoshiFrequency(value: 120, displayValue: '120')],
          ),
        ],
        pitches: [
          HoshiPitchEntry(
            dictName: 'NHK',
            pitchPositions: Int32List.fromList([2, 2]),
            transcriptions: const ['heiban', 'heiban'],
          ),
        ],
      ),
    );

    final entry = hoshiPopupEntry(result);

    expect(entry['expression'], '食べる');
    expect(entry['rules'], ['v1', 'vt']);
    expect(entry['deinflectionTrace'], [
      {'name': 'past', 'description': 'past tense'},
    ]);
    expect((entry['glossaries'] as List).single, {
      'dictionary': 'JMdict',
      'content': 'to eat',
      'definitionTags': 'v1 vt',
      'termTags': 'ichi1',
    });
    expect(((entry['pitches'] as List).single as Map)['pitchPositions'], [2]);
  });

  test('builds the browser document around Hoshi renderer assets', () {
    const preferences = DictionaryPopupPreferences(
      width: 540,
      height: 450,
      fontSize: 15,
      theme: DictionaryThemePreference.dark,
      eInkMode: false,
      paginatedScrolling: false,
      customCss: '.entry { outline: none; }',
      showFrequencyHarmonic: true,
      showFrequencyAverage: false,
      showPitchNumber: true,
      showPitchText: true,
    );

    final html = buildHoshiPopupHtml(
      popupCss: '/* upstream popup css */',
      popupJs: 'window.renderPopup = function() {};',
      selectionJs: 'window.hoshiSelection = {};',
      audioPreferences: AnkiAudioPreferences.defaults,
      allowDuplicates: false,
      preferences: preferences,
      theme: ThemeData.dark(),
      dark: true,
    );

    expect(html, contains('color-scheme: dark'));
    expect(html, contains('/* upstream popup css */'));
    expect(html, contains('window.renderPopup = function() {};'));
    expect(html, contains('window.hoshiSelection = {};'));
    expect(html, contains('window.dictionaryCollapseMode = "expand_all"'));
    expect(html, contains('window.harmonicFrequency = true'));
    expect(hoshiPopupMaxResults, 3);
    expect(hoshiPopupScanLength, 24);
    expect(html, contains('window.scanLength = 24;'));
    expect(
      html,
      contains(
        'window.audioSources = ["JapanesePod101","Jisho.org","LanguagePod101"];',
      ),
    );
    expect(html, contains('window.needsAudio = true;'));
    expect(html, contains('flutter_inappwebview.callHandler'));
    expect(html, contains('getTermAudioSources'));
    expect(html, contains('playWordAudio'));
    expect(html, contains('"kanjiLookup"'));
    expect(html, contains("'duplicateCheck'"));
    expect(html, contains('"duplicateNotes"'));
    expect(html, contains('"browseNotes"'));
    expect(html, contains('window.allowDupes = false;'));
    expect(html, contains('.plus-line'));
    expect(html, contains('.duplicate-icon'));
    expect(html, contains('.duplicate-line'));
    expect(
      html,
      contains(
        '.button-slot[data-state="duplicate"] .duplicate-icon { display: block; }',
      ),
    );
    expect(html, contains('.audio-speaker-body'));
    expect(html, isNot(contains('audio-icon { transform:')));
    expect(html, isNot(contains('\\229E')));
    expect(html, isNot(contains('\u{1F50A}')));
  });

  test('injects the exact dictionary profile into the popup document', () {
    const profile = DictionaryProfile(
      id: 'zh-learning',
      name: 'Traditional Chinese',
      languageCode: 'zh-Hant',
      dictionaryOrder: ['Frequency', 'Terms'],
      dictionaryCollapseMode: 'custom',
      dictionaryDisplayModes: {
        'Terms': 'always_collapsed',
        'Frequency': 'always_expanded',
      },
    );
    const preferences = DictionaryPopupPreferences(
      width: 540,
      height: 450,
      fontSize: 15,
      theme: DictionaryThemePreference.light,
      eInkMode: false,
      paginatedScrolling: false,
      customCss: '',
      showFrequencyHarmonic: true,
      showFrequencyAverage: false,
      showPitchNumber: true,
      showPitchText: true,
    );

    final html = buildHoshiPopupHtml(
      popupCss: '',
      popupJs: '',
      selectionJs: '',
      audioPreferences: AnkiAudioPreferences.defaults,
      allowDuplicates: false,
      profile: profile,
      preferences: preferences,
      theme: ThemeData.light(),
      dark: false,
    );

    expect(html, contains('<html lang="zh-Hant"'));
    expect(html, contains('window.dictionaryCollapseMode = "custom";'));
    expect(
      html,
      contains(
        'window.dictionaryDisplayModes = '
        '{"Terms":"always_collapsed","Frequency":"always_expanded"};',
      ),
    );
    expect(html, contains('window.dictionaryOrder = ["Frequency","Terms"];'));
  });

  test('injects enabled audio preferences into popup document', () {
    const preferences = DictionaryPopupPreferences(
      width: 540,
      height: 450,
      fontSize: 15,
      theme: DictionaryThemePreference.light,
      eInkMode: false,
      paginatedScrolling: false,
      customCss: '',
      showFrequencyHarmonic: true,
      showFrequencyAverage: false,
      showPitchNumber: true,
      showPitchText: true,
    );

    final html = buildHoshiPopupHtml(
      popupCss: '/* upstream popup css */',
      popupJs: 'window.renderPopup = function() {};',
      selectionJs: 'window.hoshiSelection = {};',
      audioPreferences: const AnkiAudioPreferences(
        enabled: true,
        sourceType: AnkiAudioSourceType.customJson,
        url: 'http://localhost:5050/?term={term}&reading={reading}',
        timeout: Duration(seconds: 5),
        language: 'ja',
      ),
      allowDuplicates: true,
      preferences: preferences,
      theme: ThemeData.light(),
      dark: false,
    );

    expect(html, contains('window.audioSources = ["Custom URL (JSON)"];'));
    expect(html, contains('window.audioSourceType = "customJson";'));
    expect(html, contains('window.needsAudio = true;'));
    expect(html, contains('window.allowDupes = true;'));
    expect(
      html,
      contains("showAudioSourceMenu(Number(slot.dataset.entryIndex)"),
    );
  });

  test('resets popup state when replacing lookup results', () {
    expect(
      hoshiReplaceRenderScriptForEntries(const []),
      contains('window.resetHoshiAudioCaches?.();'),
    );
    expect(
      hoshiReplaceRenderScriptForEntries(const []),
      contains('window.resetHoshiNavigation?.();'),
    );
    expect(
      hoshiReplaceRenderScriptForEntries(const []),
      contains('window.resetHoshiDictionaryStyles?.();'),
    );
    expect(
      hoshiReplaceRenderScriptForEntries(const []),
      contains('window.getSelection?.()?.removeAllRanges?.();'),
    );
    expect(
      hoshiReplaceRenderScriptForEntries(const []),
      contains('window.scrollTo(0, 0);'),
    );
  });

  test(
    'embeds dictionary images when WebView custom schemes are unavailable',
    () async {
      final result = HoshiLookupResult(
        matched: 'コンビニ',
        deinflected: 'コンビニ',
        trace: const [],
        preprocessorSteps: 0,
        term: const HoshiTermResult(
          expression: 'コンビニ',
          reading: '',
          rules: '',
          score: 1,
          glossaries: [
            HoshiGlossaryEntry(
              dictName: '深辞海',
              glossary:
                  '{"type":"structured-content","content":{"tag":"img","path":"yomitan_images/3494.jpg"}}',
              definitionTags: '',
              termTags: '',
            ),
          ],
          frequencies: [],
          pitches: [],
        ),
      );

      final media = await hoshiPopupMediaDataUris([result], (
        dictionary,
        path,
      ) async {
        expect(dictionary, '深辞海');
        expect(path, 'yomitan_images/3494.jpg');
        return Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);
      });

      expect(
        media['深辞海']?['yomitan_images/3494.jpg'],
        'data:image/jpeg;base64,/9j/2Q==',
      );
      final script = hoshiReplaceRenderScriptForEntries(
        hoshiPopupEntries([result]),
        mediaDataUris: media,
      );
      expect(script, contains('window.hoshiDictionaryMedia'));
      expect(script, contains('data:image/jpeg;base64,/9j/2Q=='));
    },
  );

  test('requests missing dictionary images through the host media bridge', () {
    final script = File('assets/hoshi_popup/popup.js').readAsStringSync();

    expect(
      script,
      contains('webkit.messageHandlers.dictionaryMedia.postMessage'),
    );
    expect(script, contains('window.hoshiDictionaryMedia[dictionary][path]'));
    expect(script, contains('img.src = imageUrl'));
  });

  test('superseded async renders cannot append stale dictionary entries', () {
    final script = File('assets/hoshi_popup/popup.js').readAsStringSync();

    expect(
      script,
      contains('const renderToken = window.__mangayomiHoshiRenderToken;'),
    );
    expect(
      script,
      contains(
        'const isCurrentRender = () => renderToken === '
        'window.__mangayomiHoshiRenderToken;',
      ),
    );
    expect(
      RegExp(r'if \(!isCurrentRender\(\)\) return;').allMatches(script),
      hasLength(greaterThanOrEqualTo(6)),
    );
  });

  test('navigates from term headwords to Yomitan Kanji entries', () {
    final script = File('assets/hoshi_popup/popup.js').readAsStringSync();
    final styles = File('assets/hoshi_popup/popup.css').readAsStringSync();

    expect(
      script,
      contains('webkit.messageHandlers.kanjiLookup.postMessage(character)'),
    );
    expect(script, contains("entry.type === 'mangatan-yomitan-kanji-v1'"));
    expect(script, contains('...(entry.stats?.class || [])'));
    expect(script, contains('...(entry.stats?.code || [])'));
    expect(script, contains('...(entry.stats?.index || [])'));
    expect(script, contains("createKanjiStatGroup('Statistics', statistics)"));
    expect(script, contains('kanji-readings-chinese'));
    expect(script, contains('kanji-readings-japanese'));
    expect(styles, contains('.kanji-reading-list'));
    expect(styles, contains('@media (max-width: 360px)'));
  });

  test('supports Chimahon-style keyboard and volume-key popup paging', () {
    final script = File('assets/hoshi_popup/popup.js').readAsStringSync();

    expect(script, contains('AudioVolumeDown: 0.8'));
    expect(script, contains('AudioVolumeUp: -0.8'));
    expect(script, contains('PageDown: 0.8'));
    expect(script, contains('scrollingElement.scrollBy'));
    expect(script, contains("event.key === 'Home' ? 0"));
  });

  test('uses the theme foreground for frequency and pitch accent tags', () {
    const preferences = DictionaryPopupPreferences(
      width: 540,
      height: 450,
      fontSize: 15,
      theme: DictionaryThemePreference.light,
      eInkMode: false,
      paginatedScrolling: false,
      customCss: '',
      showFrequencyHarmonic: true,
      showFrequencyAverage: false,
      showPitchNumber: true,
      showPitchText: true,
    );

    final html = buildHoshiPopupHtml(
      popupCss: '/* upstream popup css */',
      popupJs: 'window.renderPopup = function() {};',
      selectionJs: 'window.hoshiSelection = {};',
      audioPreferences: AnkiAudioPreferences.defaults,
      allowDuplicates: false,
      preferences: preferences,
      theme: ThemeData.light(),
      dark: false,
    );
    final globalColorRule = html.indexOf('.entry, .entry *');
    final tagRowColorRule = html.indexOf('.tag-row, .tag-row *');
    final labelColorRule = html.indexOf(
      '.frequency-dict-label, .pitch-dict-label { color: var(--on-primary); }',
    );

    expect(html, contains('--on-primary: #ffffff;'));
    expect(labelColorRule, isNonNegative);
    expect(labelColorRule, greaterThan(globalColorRule));
    expect(labelColorRule, greaterThan(tagRowColorRule));
  });

  test('keeps sepia dark accent tags legible', () {
    const preferences = DictionaryPopupPreferences(
      width: 540,
      height: 450,
      fontSize: 15,
      theme: DictionaryThemePreference.dark,
      eInkMode: false,
      paginatedScrolling: false,
      customCss: '',
      showFrequencyHarmonic: true,
      showFrequencyAverage: false,
      showPitchNumber: true,
      showPitchText: true,
    );
    final theme = ThemeData.dark().copyWith(
      colorScheme: ThemeData.dark().colorScheme.copyWith(
        primary: const Color(0xfff1e8d9),
        onPrimary: const Color(0xff332d22),
      ),
    );

    final html = buildHoshiPopupHtml(
      popupCss: '/* upstream popup css */',
      popupJs: 'window.renderPopup = function() {};',
      selectionJs: 'window.hoshiSelection = {};',
      audioPreferences: AnkiAudioPreferences.defaults,
      allowDuplicates: false,
      preferences: preferences,
      theme: theme,
      dark: true,
    );

    expect(html, contains('--freq-tag-color: #f1e8d9;'));
    expect(html, contains('--pitch-tag-color: #f1e8d9;'));
    expect(html, contains('--on-primary: #332d22;'));
  });

  test('keeps the description overlay readable in a light popup', () {
    const preferences = DictionaryPopupPreferences(
      width: 540,
      height: 450,
      fontSize: 15,
      theme: DictionaryThemePreference.light,
      eInkMode: false,
      paginatedScrolling: false,
      customCss: '',
      showFrequencyHarmonic: true,
      showFrequencyAverage: false,
      showPitchNumber: true,
      showPitchText: true,
    );

    final html = buildHoshiPopupHtml(
      popupCss:
          '@media (prefers-color-scheme: dark) { .overlay { background: #222; } }',
      popupJs: 'window.renderPopup = function() {};',
      selectionJs: 'window.hoshiSelection = {};',
      audioPreferences: AnkiAudioPreferences.defaults,
      allowDuplicates: false,
      preferences: preferences,
      theme: ThemeData.light(),
      dark: false,
    );
    final upstreamDarkOverlay = html.indexOf('.overlay { background: #222; }');
    final themedOverlay = html.indexOf(
      'background: var(--background-color-dark1);',
    );

    expect(upstreamDarkOverlay, isNonNegative);
    expect(themedOverlay, greaterThan(upstreamDarkOverlay));
    expect(
      html,
      contains(
        '.overlay-content, .overlay-close { color: var(--text-color); }',
      ),
    );
  });

  test('bundles the upstream Hoshi renderer and license', () async {
    final popup = await rootBundle.loadString('assets/hoshi_popup/popup.js');
    final css = await rootBundle.loadString('assets/hoshi_popup/popup.css');
    final license = await rootBundle.loadString('assets/hoshi_popup/LICENSE');

    expect(popup, contains('window.renderPopup = function()'));
    expect(popup, contains('SPDX-License-Identifier: GPL-3.0-or-later'));
    expect(popup, contains('plus-icon'));
    expect(popup, contains('M10 3h3v17h-3zM3 10h17v3H3z'));
    expect(popup, contains('duplicate-icon'));
    expect(popup, contains('M4 4h16v16H4zM12 7v10M7 12h10'));
    expect(popup, contains('audio-speaker-body'));
    expect(popup, contains('M3 9v6h4l5 4V5L7 9H3z'));
    expect(popup, contains('window.resetHoshiAudioCaches = resetAudioCaches'));
    expect(
      popup,
      contains('window.resetHoshiDictionaryStyles = resetDictionaryStyles'),
    );
    expect(popup, contains('function installScopedDictionaryStyle'));
    expect(popup, contains('scopeDictionaryStyleRules(style.sheet.cssRules'));
    expect(popup, contains('Array.isArray(node.value)'));
    expect(popup, isNot(contains('[data-dictionary="\${dictName}"] {')));
    expect(popup, contains('window.resetHoshiNavigation = () =>'));
    expect(popup, contains('window.navigateBack = () =>'));
    expect(popup, contains('window.navigateForward = () =>'));
    expect(popup, contains('navigationChanged.postMessage'));
    expect(
      popup,
      contains('window.hoshiDictionaryMedia?.[dictionary]?.[path]'),
    );
    expect(popup, contains("node.type === 'image' || node.tag === 'img'"));
    expect(popup, contains('function hasPopupTextSelection()'));
    expect(popup, contains('function rememberPopupTextSelection()'));
    expect(popup, contains('function browseEntryNotes(entryIndex)'));
    expect(
      popup,
      contains('async function refreshEntryAnkiState(entryIndex, expression)'),
    );
    expect(
      popup,
      contains(
        'const refreshAnkiState = () => '
        'refreshEntryAnkiState(entryIndex, expression);',
      ),
    );
    expect(popup, contains('await refreshAnkiState();'));
    expect(popup, contains("browseSlot.dataset.noteIds = ids.join(' ');"));
    expect(popup, contains('browseSlot.hidden = ids.length === 0;'));
    expect(popup, contains("? 'Add duplicate card' : 'Add card'"));
    expect(popup, contains('allowDuplicate,'));
    expect(
      css,
      contains(
        'Arial, "Noto Sans JP", "Noto Sans CJK JP", "Meiryo", sans-serif',
      ),
    );
    expect(
      popup,
      contains(
        "document.addEventListener('selectionchange', rememberPopupTextSelection);",
      ),
    );
    expect(
      popup,
      contains(
        'const selectedText = rememberPopupTextSelection() || lastSelection;',
      ),
    );
    expect(popup, contains('if (hasPopupTextSelection())'));
    expect(popup, contains('const audioKey = audioCacheKey(entry);'));
    expect(popup, contains('audioUrls[audioKey]'));
    expect(popup, contains('for (const source of sources)'));
    expect(popup, contains('!await playWordAudio(source.url)'));
    expect(popup, isNot(contains('audioUrls[idx]')));
    expect(popup, isNot(contains('audioUrls[entryIndex]')));
    expect(css, contains('.glossary-group'));
    expect(css, contains('.glossary-content .gloss-sc-summary::marker'));
    expect(css, contains('.pronunciation-mora'));
    expect(css, contains('--danger-color-lightest: #4a2020;'));
    expect(
      css,
      contains('.gloss-image-link[data-path^="gaiji/bs"] .gloss-image'),
    );
    expect(
      css,
      contains(
        '.gloss-image-link[data-path^="gaiji/bs"]>.gloss-image-container',
      ),
    );
    expect(css, contains('width: 15em !important;'));
    expect(license, contains('GNU GENERAL PUBLIC LICENSE'));
  });
}
