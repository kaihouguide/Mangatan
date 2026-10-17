import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/epub_book_progress.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/mining/reader_lookup_trigger.dart';
import 'package:mangayomi/modules/mining/widgets/dictionary_lookup_popup.dart';
import 'package:mangayomi/modules/novel/widgets/novel_dictionary_selection.dart';
import 'package:mangayomi/services/epub_reader_asset_server.dart';
import 'package:mangayomi/services/epub_chapter_metadata.dart';
import 'package:mangayomi/services/get_html_content.dart';
import 'package:mangayomi/services/mining/mining_models.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';
import 'package:mangayomi/services/mining/dictionary_profile_resolver.dart';
import 'package:mangayomi/services/sync/chimahon_novel_progress_adapter.dart';
import 'package:mangayomi/src/rust/api/epub.dart';
import 'package:mangayomi/utils/platform_utils.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// The reading surface used for a local EPUB chapter.
///
/// The paged layouts intentionally follow the same approach as Hoshi Reader:
/// CSS columns create one viewport-sized page at a time while the WebView
/// owns the page axis.  Keeping this separate from the Flutter chrome means
/// dictionary selection keeps working in every layout.
enum EpubReadingLayout {
  horizontalContinuous,
  horizontalPaged,
  verticalPaged,
  verticalContinuous;

  String get documentValue => switch (this) {
    EpubReadingLayout.horizontalContinuous => 'horizontal-scroll',
    EpubReadingLayout.horizontalPaged => 'horizontal-pages',
    EpubReadingLayout.verticalPaged => 'vertical-pages',
    EpubReadingLayout.verticalContinuous => 'vertical-scroll',
  };

  bool get isPaged =>
      this == EpubReadingLayout.horizontalPaged ||
      this == EpubReadingLayout.verticalPaged;

  bool get isVerticalWriting =>
      this == EpubReadingLayout.verticalPaged ||
      this == EpubReadingLayout.verticalContinuous;

  bool get usesHorizontalScroll =>
      this == EpubReadingLayout.horizontalPaged ||
      this == EpubReadingLayout.verticalContinuous;

  String get label => switch (this) {
    EpubReadingLayout.horizontalContinuous => 'Horizontal continuous',
    EpubReadingLayout.horizontalPaged => 'Horizontal paged',
    EpubReadingLayout.verticalPaged => 'Vertical paged',
    EpubReadingLayout.verticalContinuous => 'Vertical continuous',
  };

  static EpubReadingLayout fromAxes({
    required bool vertical,
    required bool paged,
  }) => switch ((vertical, paged)) {
    (false, false) => EpubReadingLayout.horizontalContinuous,
    (false, true) => EpubReadingLayout.horizontalPaged,
    (true, true) => EpubReadingLayout.verticalPaged,
    (true, false) => EpubReadingLayout.verticalContinuous,
  };
}

/// Controller for the browser-DOM EPUB surface.
///
/// The public API intentionally mirrors the Hoshi Reader bridge: callers ask
/// for reader operations instead of manipulating WebView state directly.
class TtsuEpubReaderController {
  InAppWebViewController? _webView;

  void attach(InAppWebViewController controller) => _webView = controller;

  void detach(InAppWebViewController controller) {
    if (identical(_webView, controller)) _webView = null;
  }

  Future<bool?> scrollBy(double logicalPixels) async {
    final webView = _webView;
    if (webView == null) return null;
    final value = await webView.evaluateJavascript(
      source: 'window.mangatanReader?.scrollByPixels($logicalPixels);',
    );
    return _javascriptNullableBool(value);
  }

  /// Returns `false` once the reader is already at the beginning/end of the
  /// chapter. The Flutter shell then performs the chapter transition.
  Future<bool?> scrollPage(int direction) async {
    final webView = _webView;
    if (webView == null) return null;
    final value = await webView.evaluateJavascript(
      source: 'window.mangatanReader?.scrollPage(${direction.sign});',
    );
    return _javascriptNullableBool(value);
  }

  Future<void> jumpToFraction(double fraction) async {
    final safeFraction = fraction.clamp(0.0, 1.0);
    await _webView?.evaluateJavascript(
      source: 'window.mangatanReader?.jumpToFraction($safeFraction);',
    );
  }

  Future<void> jumpToFragment(String fragment) async {
    final literal = jsonEncode(fragment);
    await _webView?.evaluateJavascript(
      source: 'window.mangatanReader?.jumpToFragment($literal);',
    );
  }

  Future<void> jumpToEpubSpine(
    int spineIndex, {
    bool isolateChapter = true,
  }) async {
    await _webView?.evaluateJavascript(
      source:
          'window.mangatanReader?.jumpToLogicalSpine($spineIndex, $isolateChapter);',
    );
  }

  Future<void> clearLogicalChapterIsolation() async {
    await _webView?.evaluateJavascript(
      source: 'window.mangatanReader?.clearLogicalTarget?.();',
    );
  }

  Future<bool?> jumpToAdjacentChapter(int direction) async {
    final value = await _webView?.evaluateJavascript(
      source:
          'window.mangatanReader?.jumpToAdjacentChapter(${direction.sign});',
    );
    return _javascriptNullableBool(value);
  }

  Future<void> jumpToBookmark(int chapterIndex, double progress) async {
    final safeProgress = progress.clamp(0.0, 1.0);
    await _webView?.evaluateJavascript(
      source:
          'window.mangatanReader?.jumpToBookmark($chapterIndex, $safeProgress);',
    );
  }

  Future<void> restorePreviewPosition({
    required int spineIndex,
    required int chapterIndex,
    required double chapterProgress,
  }) async {
    final safeProgress = chapterProgress.clamp(0.0, 1.0);
    await _webView?.evaluateJavascript(
      source:
          'window.mangatanReader?.restorePreviewPosition($spineIndex, $chapterIndex, $safeProgress);',
    );
  }

  Future<double> fraction() async {
    final value = await _webView?.evaluateJavascript(
      source: 'window.mangatanReader?.fraction() ?? 0;',
    );
    return _javascriptNumber(value);
  }

  Future<EpubReaderProgressSnapshot?> currentProgressSnapshot() async {
    final value = await _webView?.evaluateJavascript(
      source: 'JSON.stringify(window.mangatanReader?.metrics?.() ?? null);',
    );
    if (value is! String || value.isEmpty || value == 'null') return null;
    dynamic decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    return EpubReaderProgressSnapshot(
      offset: _javascriptNumber(decoded['offset']),
      maxOffset: _javascriptNumber(decoded['max']),
      chapterIndex: _javascriptNumber(decoded['chapterIndex']).toInt(),
      chapterProgress: _javascriptNumber(decoded['chapterProgress']),
      characterCount: _javascriptNumber(decoded['characterCount']).toInt(),
      spineIndex: _javascriptNumber(decoded['spineIndex']).toInt(),
    );
  }

  Future<bool?> setShiftLookupActive(bool active) async {
    final webView = _webView;
    if (webView == null) return null;
    final value = await webView.evaluateJavascript(
      source:
          'Boolean(window.mangatanReader?.setShiftLookupActive?.($active));',
    );
    return _javascriptNullableBool(value);
  }
}

class EpubReaderProgressSnapshot {
  const EpubReaderProgressSnapshot({
    required this.offset,
    required this.maxOffset,
    required this.chapterIndex,
    required this.chapterProgress,
    required this.characterCount,
    required this.spineIndex,
  });

  final double offset;
  final double maxOffset;
  final int chapterIndex;
  final double chapterProgress;
  final int characterCount;
  final int spineIndex;
}

/// Hoshi-style EPUB reader.
///
/// EPUB documents are materialized into a short-lived private directory. The
/// reader uses a loopback HTTP origin on Windows and a file URL elsewhere.
/// This avoids WebView2's small `NavigateToString` limit, preserves
/// chapter-relative CSS/images, and prevents a large image from turning the
/// reader into an empty surface.
class TtsuEpubReader extends StatefulWidget {
  const TtsuEpubReader({
    super.key,
    required this.controller,
    required this.chapter,
    required this.html,
    required this.book,
    required this.backgroundColor,
    required this.textColor,
    required this.fontSize,
    required this.lineHeight,
    required this.padding,
    required this.textAlign,
    required this.initialProgress,
    this.initialChapterIndex,
    this.initialChapterProgress,
    this.initialSpineIndex,
    this.previewSpineIndex,
    required this.tapToScroll,
    required this.paragraphSpacing,
    this.layout = EpubReadingLayout.horizontalContinuous,
    required this.onProgress,
    required this.onReaderTap,
    required this.onBackRequested,
    required this.onChapterRequested,
    required this.onChapterLinkRequested,
  });

  final TtsuEpubReaderController controller;
  final Chapter chapter;
  final String html;
  final EpubNovel book;
  final String backgroundColor;
  final String textColor;
  final double fontSize;
  final double lineHeight;
  final double padding;
  final String textAlign;
  final double initialProgress;
  final int? initialChapterIndex;
  final double? initialChapterProgress;
  final int? initialSpineIndex;
  final int? previewSpineIndex;
  final bool tapToScroll;
  final double paragraphSpacing;
  final EpubReadingLayout layout;
  final void Function(
    double offset,
    double maxOffset,
    int chapterIndex,
    double chapterProgress,
    int characterCount,
    int spineIndex,
  )
  onProgress;
  final void Function(Offset position, Size viewport) onReaderTap;
  final VoidCallback onBackRequested;
  final void Function(int direction) onChapterRequested;
  final void Function(String chapterId) onChapterLinkRequested;

  @override
  State<TtsuEpubReader> createState() => _TtsuEpubReaderState();
}

class _TtsuEpubReaderState extends State<TtsuEpubReader> {
  final GlobalKey _webViewKey = GlobalKey();
  InAppWebViewController? _webView;
  _EpubRenderBundle? _bundle;
  File? _documentFile;
  int _generation = 0;
  bool _isPreparing = true;
  bool _isReady = false;
  bool _showFallback = false;
  String? _failure;
  double? _restoreAfterReload;
  EpubReaderProgressSnapshot? _previewRestoreAfterReload;
  int _documentRevision = 0;
  int _dictionaryGeneration = 0;
  // Keeps cold opens covered until the generated document has applied its
  // exact bookmark or requested spine and reported the settled location.
  bool _initialLocationPending = true;
  String? _prefetchedLookupText;
  DictionaryLookupPrefetch? _prefetchedLookup;
  DictionaryLookupTrigger _lookupTrigger = DictionaryLookupTrigger.leftClick;
  bool _additionalLeftClick = false;

  String? get _chapterHref {
    if (isEpubNavigationChapter(widget.chapter)) return null;
    final chapterId = widget.chapter.url;
    if (chapterId == null || chapterId.isEmpty) return null;
    for (final epubChapter in widget.book.chapters) {
      if (epubChapter.path == chapterId ||
          _normalizeEpubPath(epubChapter.href) ==
              _normalizeEpubPath(chapterId)) {
        return epubChapter.href;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    ReaderLookupTriggerState.trigger.addListener(
      _handleLookupPreferencesChanged,
    );
    ReaderLookupTriggerState.additionalLeftClick.addListener(
      _handleLookupPreferencesChanged,
    );
    unawaited(_prepareBundle());
  }

  void _handleLookupPreferencesChanged() {
    final trigger = ReaderLookupTriggerState.trigger.value;
    final additionalLeftClick =
        ReaderLookupTriggerState.additionalLeftClick.value;
    if (trigger == _lookupTrigger &&
        additionalLeftClick == _additionalLeftClick) {
      return;
    }
    _lookupTrigger = trigger;
    _additionalLeftClick = additionalLeftClick;
    if (_bundle != null && !_isPreparing) {
      unawaited(_reloadAtCurrentPosition());
    }
  }

  @override
  void didUpdateWidget(covariant TtsuEpubReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sourceChanged =
        oldWidget.chapter.id != widget.chapter.id ||
        oldWidget.html != widget.html ||
        oldWidget.book != widget.book;
    if (sourceChanged) {
      unawaited(_prepareBundle());
      return;
    }

    final appearanceChanged =
        oldWidget.backgroundColor != widget.backgroundColor ||
        oldWidget.textColor != widget.textColor ||
        oldWidget.fontSize != widget.fontSize ||
        oldWidget.lineHeight != widget.lineHeight ||
        oldWidget.padding != widget.padding ||
        oldWidget.textAlign != widget.textAlign ||
        oldWidget.tapToScroll != widget.tapToScroll ||
        oldWidget.paragraphSpacing != widget.paragraphSpacing ||
        oldWidget.layout != widget.layout;
    if (appearanceChanged) unawaited(_reloadAtCurrentPosition());
  }

  Future<void> _prepareBundle() async {
    final generation = ++_generation;
    if (mounted) {
      setState(() {
        _isPreparing = true;
        _isReady = false;
        _showFallback = false;
        _failure = null;
        _documentFile = null;
      });
    }

    _EpubRenderBundle? bundle;
    try {
      await ReaderLookupTriggerState.initialize();
      _lookupTrigger = ReaderLookupTriggerState.trigger.value;
      _additionalLeftClick = ReaderLookupTriggerState.additionalLeftClick.value;
      bundle = await _EpubRenderBundle.create(
        book: widget.book,
        chapterHref: _chapterHref,
      );
      final document = await bundle.writeDocument(
        _buildDocument(resourceUrlFor: bundle.relativeUrlFor),
        revision: generation,
      );
      if (!mounted || generation != _generation) {
        await bundle.dispose();
        return;
      }

      final previous = _bundle;
      setState(() {
        _bundle = bundle;
        _documentFile = document;
        _documentRevision = generation;
        _isPreparing = false;
      });
      if (previous != null) unawaited(previous.dispose());
    } catch (error) {
      await bundle?.dispose();
      if (!mounted || generation != _generation) return;
      setState(() {
        _isPreparing = false;
        _showFallback = true;
        _failure = error.toString();
      });
    }
  }

  Future<void> _reloadAtCurrentPosition() async {
    final bundle = _bundle;
    if (bundle == null) return;
    final generation = ++_generation;
    final previewSnapshot = widget.previewSpineIndex == null
        ? null
        : await widget.controller.currentProgressSnapshot();
    final previousProgress = await widget.controller.fraction();
    if (!mounted || generation != _generation) return;
    _restoreAfterReload = previousProgress;
    _previewRestoreAfterReload = previewSnapshot;
    try {
      final document = await bundle.writeDocument(
        _buildDocument(),
        revision: generation,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _isReady = false;
        _showFallback = false;
        _failure = null;
        _documentFile = document;
        _documentRevision = generation;
      });
    } catch (error) {
      _fail(generation, error.toString());
    }
  }

  String _buildDocument({
    String? Function(EpubResource resource)? resourceUrlFor,
  }) => buildTtsuEpubDocument(
    html: widget.html,
    book: widget.book,
    title: widget.chapter.name ?? widget.book.name,
    backgroundColor: widget.backgroundColor,
    textColor: widget.textColor,
    fontSize: widget.fontSize,
    lineHeight: widget.lineHeight,
    padding: widget.padding,
    textAlign: widget.textAlign,
    initialProgress: _restoreAfterReload ?? widget.initialProgress,
    initialChapterIndex: _initialLocationPending
        ? widget.initialChapterIndex
        : null,
    initialChapterProgress: _initialLocationPending
        ? widget.initialChapterProgress
        : null,
    initialSpineIndex: _initialLocationPending
        ? widget.initialSpineIndex
        : null,
    tapToScroll: widget.tapToScroll,
    paragraphSpacing: widget.paragraphSpacing,
    layout: widget.layout,
    lookupTrigger: _lookupTrigger,
    additionalLeftClick: isDesktop && _additionalLeftClick,
    chapterHref: _chapterHref,
    resourceUrlFor: resourceUrlFor ?? _bundle?.relativeUrlFor,
  );

  @override
  void dispose() {
    ReaderLookupTriggerState.trigger.removeListener(
      _handleLookupPreferencesChanged,
    );
    ReaderLookupTriggerState.additionalLeftClick.removeListener(
      _handleLookupPreferencesChanged,
    );
    final controller = _webView;
    if (controller != null) widget.controller.detach(controller);
    final bundle = _bundle;
    if (bundle != null) unawaited(bundle.dispose());
    super.dispose();
  }

  void _registerHandlers(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'readerProgress',
      callback: (arguments) {
        final data = _firstMap(arguments);
        if (data == null || !mounted) return;
        final offset = _javascriptNumber(data['offset']);
        final maxOffset = _javascriptNumber(data['max']);
        widget.onProgress(
          offset,
          maxOffset,
          _javascriptNumber(data['chapterIndex']).toInt(),
          _javascriptNumber(data['chapterProgress']),
          _javascriptNumber(data['characterCount']).toInt(),
          _javascriptNumber(data['spineIndex']).toInt(),
        );
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'readerReady',
      callback: (_) {
        if (!mounted) return;
        final previewRestore = _previewRestoreAfterReload;
        _previewRestoreAfterReload = null;
        _restoreAfterReload = null;
        setState(() {
          _isReady = true;
          _initialLocationPending = false;
          _showFallback = false;
          _failure = null;
        });
        if (previewRestore != null && widget.previewSpineIndex != null) {
          unawaited(
            widget.controller.restorePreviewPosition(
              spineIndex: widget.previewSpineIndex!,
              chapterIndex: previewRestore.chapterIndex,
              chapterProgress: previewRestore.chapterProgress,
            ),
          );
        }
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'readerTap',
      callback: (arguments) {
        final data = _firstMap(arguments);
        if (data == null || !mounted) return;
        widget.onReaderTap(
          Offset(_javascriptNumber(data['x']), _javascriptNumber(data['y'])),
          Size(
            _javascriptNumber(data['width']),
            _javascriptNumber(data['height']),
          ),
        );
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'readerBack',
      callback: (_) {
        if (mounted) widget.onBackRequested();
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'readerChapter',
      callback: (arguments) {
        final direction = _javascriptNumber(arguments.firstOrNull).toInt();
        if (direction != 0 && mounted) widget.onChapterRequested(direction);
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'readerPrefetch',
      callback: (arguments) {
        final data = _firstMap(arguments);
        final text = data?['text']?.toString().trim() ?? '';
        if (text.isEmpty || text == _prefetchedLookupText) return false;
        final miningContext = _dictionaryMiningContext(text);
        final prefetch = DictionaryLookupPopup.prefetch(
          text,
          miningContext: miningContext,
        );
        _prefetchedLookupText = text;
        _prefetchedLookup = prefetch;
        unawaited(
          DictionaryLookupPopup.prepare(
            context: context,
            text: text,
            prefetch: prefetch,
          ),
        );
        unawaited(
          prefetch.results.then<void>(
            (_) {},
            onError: (_) {
              if (_prefetchedLookupText == text) {
                _prefetchedLookupText = null;
                _prefetchedLookup = null;
              }
            },
          ),
        );
        return true;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'readerDictionary',
      callback: (arguments) async {
        final data = _firstMap(arguments);
        if (data != null) await _showDictionary(data);
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'readerDismissDictionary',
      callback: (_) {
        _dictionaryGeneration++;
        return DictionaryLookupPopup.dismissActive();
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'readerLink',
      callback: (arguments) async {
        final href = arguments.firstOrNull?.toString().trim() ?? '';
        if (href.isNotEmpty) await _handleLink(href);
      },
    );
  }

  Map<dynamic, dynamic>? _firstMap(List<dynamic> arguments) {
    final first = arguments.firstOrNull;
    return first is Map ? first : null;
  }

  Future<void> _showDictionary(Map<dynamic, dynamic> data) async {
    final text = data['text']?.toString().trim() ?? '';
    if (text.isEmpty || !mounted) return;
    final lookupToken = data['lookupToken'] == null
        ? null
        : _javascriptNumber(data['lookupToken']).toInt();
    final lookupTokenLiteral = lookupToken?.toString() ?? 'null';
    final generation = ++_dictionaryGeneration;

    final box = _webViewKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final localAnchor = Rect.fromLTRB(
      _javascriptNumber(data['left'], fallback: box.size.width / 2),
      _javascriptNumber(data['top'], fallback: box.size.height / 2),
      _javascriptNumber(data['right'], fallback: box.size.width / 2),
      _javascriptNumber(data['bottom'], fallback: box.size.height / 2),
    );
    final anchor = Rect.fromPoints(
      box.localToGlobal(localAnchor.topLeft),
      box.localToGlobal(localAnchor.bottomRight),
    );
    final sentence = data['sentence']?.toString().trim();
    final prefetchedLookup = text == _prefetchedLookupText
        ? _prefetchedLookup
        : null;

    final handle = await DictionaryLookupPopup.show(
      context: context,
      anchor: anchor,
      text: text,
      prefetch: prefetchedLookup,
      placement: widget.layout.isVerticalWriting
          ? DictionaryPopupPlacement.leftOrRight
          : DictionaryPopupPlacement.aboveOrBelow,
      miningContext: _dictionaryMiningContext(
        sentence?.isNotEmpty == true ? sentence! : text,
      ),
      onMatchChanged: (length) {
        if (!mounted ||
            generation != _dictionaryGeneration ||
            lookupToken == null) {
          return;
        }
        final visibleLength = length < 1 ? 1 : length;
        unawaited(
          _webView?.evaluateJavascript(
            source:
                'window.mangatanReader?.highlightMatch($visibleLength, $lookupTokenLiteral);',
          ),
        );
      },
    );
    if (handle == null) {
      if (generation == _dictionaryGeneration) {
        await _webView?.evaluateJavascript(
          source: 'window.mangatanReader?.clearLookup($lookupTokenLiteral);',
        );
      }
      return;
    }
    unawaited(
      handle.dismissed.then((_) async {
        if (!mounted || generation != _dictionaryGeneration) return;
        await _webView?.evaluateJavascript(
          source: 'window.mangatanReader?.clearLookup($lookupTokenLiteral);',
        );
      }),
    );
  }

  MiningContext _dictionaryMiningContext(String sentence) {
    final manga = widget.chapter.manga.value;
    final source = manga?.sourceId == null
        ? null
        : isar.sources.getSync(manga!.sourceId!);
    final archivePath = widget.chapter.archivePath ?? '';
    final progress = manga?.id == null || archivePath.isEmpty
        ? null
        : isar.epubBookProgress
              .filter()
              .mangaIdEqualTo(manga!.id!)
              .archivePathEqualTo(archivePath)
              .findFirstSync();
    final isLocalNovel = archivePath.isNotEmpty;
    return MiningContext(
      mediaType: MiningMediaType.novel,
      mangaId: isLocalNovel ? null : manga?.id,
      sourceId: isLocalNovel
          ? null
          : DictionaryProfileResolver.overrideIdForSource(source),
      sourceLanguage: isLocalNovel
          ? progress?.lang ?? widget.book.language ?? ''
          : DictionaryProfileResolver.sourceLanguageForSource(
              source,
              fallback: manga?.lang ?? '',
            ),
      novelId: isLocalNovel
          ? const ChimahonNovelProgressAdapter().stableLocalIdOrNull(
              progress,
              fallbackTitle: widget.book.name,
              fallbackAuthor: widget.book.author,
            )
          : null,
      sourceTitle: manga?.name ?? widget.book.name,
      chapterTitle: widget.chapter.name ?? '',
      sentence: sentence,
      sourceUri: Uri.tryParse(widget.chapter.archivePath ?? ''),
    );
  }

  Future<void> _handleLink(String href) async {
    final trimmed = href.trim();
    if (trimmed.startsWith('#')) {
      await widget.controller.jumpToFragment(trimmed.substring(1));
      return;
    }

    final absolute = Uri.tryParse(trimmed);
    if (absolute != null &&
        (absolute.scheme == 'http' || absolute.scheme == 'https')) {
      await launchUrl(absolute, mode: LaunchMode.externalApplication);
      return;
    }

    final parts = trimmed.split('#');
    final target = _resolveEpubPath(parts.first, _chapterHref);
    for (final epubChapter in widget.book.chapters) {
      if (_normalizeEpubPath(epubChapter.href) == target) {
        widget.onChapterLinkRequested(epubChapter.path);
        return;
      }
    }
  }

  Future<void> _verifyLoadedDocument(
    InAppWebViewController controller,
    String documentIdentity,
  ) async {
    // A page can finish navigating while its fonts/images are still changing
    // layout. Only the DOM readiness signal may uncover a cold open; body text
    // alone would expose the document before its exact location is restored.
    // Renderable content remains a fallback for later settings reloads.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted || documentIdentity != _documentIdentity) return;
    try {
      final readerReady = await controller.evaluateJavascript(
        source: 'Boolean(window.mangatanReader?.isReady?.());',
      );
      if (_javascriptBool(readerReady)) {
        if (mounted && (!_isReady || _initialLocationPending)) {
          setState(() {
            _isReady = true;
            _initialLocationPending = false;
          });
        }
        return;
      }
      final hasRenderableContent = await controller.evaluateJavascript(
        source: 'Boolean(document.body?.innerText?.trim()?.length || document.images?.length);',
      );
      if (_javascriptBool(hasRenderableContent)) {
        if (!_initialLocationPending && !_isReady && mounted) {
          setState(() => _isReady = true);
        }
      } else {
        _fail(
          _generation,
          'The EPUB document did not contain renderable content.',
        );
      }
    } catch (error) {
      _fail(_generation, error.toString());
    }
  }

  void _fail(int generation, String message) {
    if (!mounted || generation != _generation) return;
    setState(() {
      _isReady = false;
      _showFallback = true;
      _failure = message;
    });
  }

  String get _documentIdentity =>
      '${_documentFile?.path ?? ''}#$_documentRevision';

  @override
  Widget build(BuildContext context) {
    final documentFile = _documentFile;
    if (_showFallback) {
      return _EpubFallback(
        chapter: widget.chapter,
        html: widget.html,
        book: widget.book,
        chapterHref: _chapterHref,
        backgroundColor: _color(
          widget.backgroundColor,
          const Color(0xFF292832),
        ),
        textColor: _color(widget.textColor, Colors.white),
        padding: widget.padding,
        error: _failure,
        onRetry: _prepareBundle,
      );
    }
    if (_isPreparing || documentFile == null) {
      return ColoredBox(
        color: _color(widget.backgroundColor, const Color(0xFF292832)),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    // A revision query gives each settings reload a new platform-view identity
    // while the physical chapter remains at its canonical EPUB-relative path.
    final documentUri = _bundle!.documentUri(
      documentFile,
      revision: _documentRevision,
    );
    final documentIdentity = _documentIdentity;
    return Stack(
      children: [
        ColoredBox(
          color: _color(widget.backgroundColor, const Color(0xFF292832)),
          child: SizedBox.expand(
            key: _webViewKey,
            child: InAppWebView(
              key: ValueKey(documentUri.toString()),
              webViewEnvironment: webViewEnvironment,
              initialUrlRequest: URLRequest(
                url: WebUri(documentUri.toString()),
              ),
              initialSettings: InAppWebViewSettings(
                transparentBackground: true,
                underPageBackgroundColor: _color(
                  widget.backgroundColor,
                  const Color(0xFF292832),
                ),
                supportZoom: false,
                horizontalScrollBarEnabled: false,
                verticalScrollBarEnabled: !widget.layout.usesHorizontalScroll,
                disableHorizontalScroll: !widget.layout.usesHorizontalScroll,
                disableVerticalScroll: widget.layout.usesHorizontalScroll,
                isInspectable: kDebugMode,
                allowFileAccessFromFileURLs: !Platform.isWindows,
                allowUniversalAccessFromFileURLs: false,
              ),
              onWebViewCreated: (controller) {
                _webView = controller;
                widget.controller.attach(controller);
                _registerHandlers(controller);
              },
              onLoadStop: (controller, _) {
                unawaited(_verifyLoadedDocument(controller, documentIdentity));
              },
              onReceivedError: (_, request, error) {
                if (request.isForMainFrame != false &&
                    documentIdentity == _documentIdentity) {
                  _fail(_generation, 'WebView error: ${error.description}');
                }
              },
              onReceivedHttpError: (_, request, response) {
                if (request.isForMainFrame != false &&
                    documentIdentity == _documentIdentity) {
                  _fail(
                    _generation,
                    'WebView HTTP error ${response.statusCode ?? ''}: ${response.reasonPhrase ?? ''}',
                  );
                }
              },
              shouldOverrideUrlLoading: (_, navigationAction) async {
                final url = navigationAction.request.url;
                if (url == null) return NavigationActionPolicy.CANCEL;
                final uri = Uri.tryParse(url.toString());
                if (uri != null && _sameReaderDocument(uri, documentUri)) {
                  // WebView2 describes a cancelled initial navigation as a
                  // stopped connection. Permit only this generated chapter
                  // document; EPUB links still use the JS bridge.
                  return NavigationActionPolicy.ALLOW;
                }
                if (uri != null &&
                    (uri.scheme == 'http' || uri.scheme == 'https')) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
                // EPUB links are handled by the DOM bridge. Never let a link
                // replace the controlled reader document with a blank page.
                return NavigationActionPolicy.CANCEL;
              },
            ),
          ),
        ),
        if (_initialLocationPending)
          Positioned.fill(
            child: AbsorbPointer(
              child: ColoredBox(
                color: _color(widget.backgroundColor, const Color(0xFF292832)),
                child: const Center(child: CircularProgressIndicator()),
              ),
            ),
          )
        else if (!_isReady)
          const Positioned.fill(
            child: IgnorePointer(
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }
}

class _EpubFallback extends StatelessWidget {
  const _EpubFallback({
    required this.chapter,
    required this.html,
    required this.book,
    required this.chapterHref,
    required this.backgroundColor,
    required this.textColor,
    required this.padding,
    required this.error,
    required this.onRetry,
  });

  final Chapter chapter;
  final String html;
  final EpubNovel book;
  final String? chapterHref;
  final Color backgroundColor;
  final Color textColor;
  final double padding;
  final String? error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final paddingPixels = MediaQuery.sizeOf(context).height * padding / 100;
    return ColoredBox(
      color: backgroundColor,
      child: Column(
        children: [
          Material(
            color: backgroundColor,
            child: ListTile(
              leading: const Icon(Icons.warning_amber_rounded),
              title: const Text('Using the compatible EPUB renderer'),
              subtitle: error == null ? null : Text(error!, maxLines: 2),
              trailing: IconButton(
                tooltip: 'Retry browser reader',
                icon: const Icon(Icons.refresh),
                onPressed: () => unawaited(onRetry()),
              ),
            ),
          ),
          Expanded(
            child: NovelDictionarySelection(
              chapter: chapter,
              child: SingleChildScrollView(
                padding: EdgeInsets.all(paddingPixels),
                child: Html(
                  data: buildReaderHtml(html),
                  style: {
                    'body': Style(color: textColor, margin: Margins.zero),
                  },
                  extensions: [
                    TagExtension(
                      tagsToExtend: {'img', 'source'},
                      builder: (extensionContext) {
                        final node = extensionContext.node;
                        if (node is! dom.Element) {
                          return const SizedBox.shrink();
                        }
                        return _fallbackImage(node) ??
                            const Icon(Icons.broken_image_outlined);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget? _fallbackImage(dom.Element element) {
    final attribute = _imageSourceAttribute(element);
    final source = attribute == null ? null : element.attributes[attribute];
    if (source == null || _isExternalResource(source)) return null;
    final image = _findImage(book.images, source, chapterHref: chapterHref);
    if (image == null) return null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Image.memory(
        image.content,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
      ),
    );
  }
}

class _EpubRenderBundle {
  _EpubRenderBundle._(this.root, this._resourceUrls, this._assetServer);

  final Directory root;
  final Map<String, String> _resourceUrls;
  final EpubReaderAssetServer? _assetServer;

  static Future<_EpubRenderBundle> create({
    required EpubNovel book,
    required String? chapterHref,
  }) async {
    final temporary = await getTemporaryDirectory();
    final base = await Directory(p.join(temporary.path, 'mangatan-epub-reader'))
        .create(recursive: true);
    final root = await base.createTemp('book-');
    final resources = <EpubResource>[...book.images, ...book.stylesheets];
    final urls = <String, String>{};

    try {
      for (final resource in resources) {
        final relative = _safeArchivePath(resource.name);
        if (relative == null || urls.containsKey(_resourceKey(resource))) {
          continue;
        }
        final target = File(p.joinAll([root.path, ...relative.split('/')]));
        await target.parent.create(recursive: true);
        await target.writeAsBytes(
          _resourceBytesForReader(resource),
          flush: false,
        );
        urls[_resourceKey(resource)] = _relativeUrl(relative, chapterHref);
      }
      final assetServer = Platform.isWindows
          ? await EpubReaderAssetServer.start(root)
          : null;
      return _EpubRenderBundle._(root, urls, assetServer);
    } catch (_) {
      try {
        await root.delete(recursive: true);
      } catch (_) {
        // Best effort cleanup of a partially materialized private session.
      }
      rethrow;
    }
  }

  String? relativeUrlFor(EpubResource resource) =>
      _resourceUrls[_resourceKey(resource)];

  Uri documentUri(File document, {required int revision}) {
    final query = {'mangatan-reader-revision': '$revision'};
    return _assetServer?.uriFor(document, queryParameters: query) ??
        Uri.file(document.path).replace(queryParameters: query);
  }

  Future<File> writeDocument(String document, {required int revision}) async {
    final href = renderedEpubDocumentHref(document, revision);
    final target = File(p.joinAll([root.path, ...href.split('/')]));
    await target.parent.create(recursive: true);
    await target.writeAsString(document, flush: false);
    return target;
  }

  Future<void> dispose() async {
    await _assetServer?.close();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

/// Returns the file-session path for a generated reader document.
///
/// Loading the shell with the source `.xhtml` suffix makes WebView2 parse it
/// as strict XML. A sibling `.html` path keeps the source directory as the
/// relative base while forcing HTML5 parsing.
@visibleForTesting
String renderedEpubDocumentHref(String document, int revision) {
  final sourceHref =
      _safeArchivePath(_documentHrefFromDocument(document)) ?? 'reader.xhtml';
  final sourceDirectory = p.posix.dirname(sourceHref);
  final fileName = '.mangatan-reader-$revision.html';
  return sourceDirectory == '.'
      ? fileName
      : p.posix.join(sourceDirectory, fileName);
}

/// Builds a script-sanitized, resource-aware reader document.
///
/// Tests use the default data-URL fallback. The live reader passes a resource
/// resolver and therefore writes no large binary payload into the HTML string.
@visibleForTesting
String buildTtsuEpubDocument({
  required String html,
  required EpubNovel book,
  required String title,
  required String backgroundColor,
  required String textColor,
  required double fontSize,
  required double lineHeight,
  required double padding,
  required String textAlign,
  required double initialProgress,
  int? initialChapterIndex,
  double? initialChapterProgress,
  int? initialSpineIndex,
  required bool tapToScroll,
  double paragraphSpacing = 0,
  EpubReadingLayout layout = EpubReadingLayout.horizontalContinuous,
  DictionaryLookupTrigger lookupTrigger = DictionaryLookupTrigger.leftClick,
  bool additionalLeftClick = false,
  String? chapterHref,
  String? Function(EpubResource resource)? resourceUrlFor,
}) {
  final document = html_parser.parse(html);
  _sanitizeEpubDocument(document);
  _rewriteEpubResourceUrls(
    document,
    book.images,
    chapterHref: chapterHref,
    resourceUrlFor: resourceUrlFor,
  );
  _markFullPageMediaCandidates(document);

  final content = document.body?.innerHtml ?? html;
  final links = _preservedStylesheetLinks(
    document,
    book.stylesheets,
    chapterHref,
    resourceUrlFor,
  );
  final safeTitle = const HtmlEscape().convert(title);
  final background = _safeCssColor(backgroundColor, '#292832');
  final foreground = _safeCssColor(textColor, '#ffffff');
  final align = const {'left', 'right', 'center', 'justify'}.contains(textAlign)
      ? textAlign
      : 'left';
  final progress = initialProgress.clamp(0.0, 1.0);
  final initialChapterIndexValue = initialChapterIndex?.toString() ?? 'null';
  final initialChapterProgressValue = initialChapterProgress == null
      ? 'null'
      : initialChapterProgress.clamp(0.0, 1.0).toString();
  final initialSpineIndexValue = initialSpineIndex?.toString() ?? 'null';
  final tapZones = tapToScroll ? 'true' : 'false';
  final safeParagraphSpacing = paragraphSpacing
      .clamp(0.0, 2.0)
      .toStringAsFixed(2);
  final documentHref = _safeArchivePath(chapterHref ?? '') ?? 'reader.xhtml';
  final layoutValue = layout.documentValue;
  final pageMode = layout.isPaged;
  final verticalWriting = layout.isVerticalWriting;
  final lookupTriggerValue = jsonEncode(lookupTrigger.name);
  final additionalLeftClickValue = additionalLeftClick ? 'true' : 'false';
  final pageGap = (padding * 2).toStringAsFixed(1);

  return '''<!doctype html>
<html lang="ja" data-mangatan-reader-href="$documentHref" data-mangatan-reader-layout="$layoutValue">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
  <title>$safeTitle</title>
  $links
  <style>
    :root {
      color-scheme: light dark;
      --reader-bg: $background;
      --reader-fg: $foreground;
      --reader-padding: ${padding}vh;
      --reader-page-gap: ${pageGap}vh;
    }
    html, body {
      margin: 0;
      min-height: 100%;
      background: var(--reader-bg) !important;
      color: var(--reader-fg) !important;
    }
    html { overflow-x: hidden; scroll-behavior: auto; }
    body {
      box-sizing: border-box;
      padding: var(--reader-padding);
      font-family: "Yu Mincho", "Noto Serif CJK JP", "Meiryo", serif !important;
      font-size: ${fontSize}px !important;
      line-height: $lineHeight !important;
      text-align: $align !important;
      overflow-wrap: anywhere;
      -webkit-text-size-adjust: 100%;
      user-select: text;
    }
    #reader-content {
      max-width: 72rem;
      min-height: calc(100vh - ${padding * 2}vh);
      margin: 0 auto;
      color: inherit !important;
    }
    #reader-content::selection,
    #reader-content *::selection {
      color: inherit;
      background: rgba(138, 180, 248, .62);
    }
    ::highlight(hoshi-selection) {
      color: inherit;
      background: rgba(160, 160, 160, .4) !important;
    }
    #reader-content p {
      margin-block-start: 0 !important;
      margin-block-end: ${safeParagraphSpacing}em !important;
    }
    #reader-content ruby { ruby-position: over; }
    #reader-content rt { font-size: 0.55em; user-select: none; }
    #reader-content img, #reader-content svg {
      display: block;
      max-width: 100%;
      height: auto;
      margin: 1em auto;
      break-inside: avoid;
      -webkit-column-break-inside: avoid;
      object-fit: contain;
    }
    #reader-content table { max-width: 100%; border-collapse: collapse; overflow-wrap: normal; break-inside: avoid; }
    #reader-content td, #reader-content th { border: 1px solid rgba(127,127,127,.45); padding: .4em; }
    #reader-content a { color: #64a8ff; cursor: pointer; }
    #reader-content [hidden] { display: block !important; }
    #reader-content .mangatan-hidden-style { display: initial !important; visibility: visible !important; opacity: 1 !important; }
    #reader-content .mangatan-logical-marker {
      display: block;
      width: 0;
      height: 0;
      overflow: hidden;
    }

    /* Use an explicit viewport instead of document.body. WebView2 and
       WKWebView disagree about which document node accepts programmatic
       page offsets, while an overflow container behaves consistently. */
    html[data-mangatan-reader-layout="horizontal-pages"],
    html[data-mangatan-reader-layout="horizontal-pages"] body,
    html[data-mangatan-reader-layout="vertical-pages"],
    html[data-mangatan-reader-layout="vertical-pages"] body,
    html[data-mangatan-reader-layout="vertical-scroll"],
    html[data-mangatan-reader-layout="vertical-scroll"] body {
      height: 100vh !important;
      width: 100vw !important;
      min-height: 0 !important;
      overflow: hidden !important;
    }
    html[data-mangatan-reader-layout="horizontal-pages"] body,
    html[data-mangatan-reader-layout="vertical-pages"] body,
    html[data-mangatan-reader-layout="vertical-scroll"] body {
      padding: 0 !important;
      box-sizing: border-box !important;
    }
    html[data-mangatan-reader-layout="horizontal-pages"] #reader-content,
    html[data-mangatan-reader-layout="vertical-pages"] #reader-content,
    html[data-mangatan-reader-layout="vertical-scroll"] #reader-content {
      width: 100vw !important;
      height: 100vh !important;
      min-height: 0 !important;
      max-width: none !important;
      margin: 0 !important;
      padding: var(--reader-padding) !important;
      box-sizing: border-box !important;
      column-fill: auto !important;
      overflow: auto !important;
      overscroll-behavior: contain;
      scrollbar-width: none;
    }
    html[data-mangatan-reader-layout="horizontal-pages"] #reader-content::-webkit-scrollbar,
    html[data-mangatan-reader-layout="vertical-pages"] #reader-content::-webkit-scrollbar,
    html[data-mangatan-reader-layout="vertical-scroll"] #reader-content::-webkit-scrollbar {
      display: none;
    }
    html[data-mangatan-reader-layout="horizontal-pages"] #reader-content *,
    html[data-mangatan-reader-layout="vertical-pages"] #reader-content *,
    html[data-mangatan-reader-layout="vertical-scroll"] #reader-content * {
      column-count: auto !important;
      -webkit-column-count: auto !important;
    }
    html[data-mangatan-reader-layout="horizontal-pages"] #reader-content {
      column-width: calc(100vw - ${padding * 2}vh) !important;
      column-gap: ${padding * 2}vh !important;
    }
    html[data-mangatan-reader-layout="horizontal-pages"] .mangatan-logical-section,
    html[data-mangatan-reader-layout="vertical-pages"] .mangatan-logical-section {
      break-after: column;
      -webkit-column-break-after: always;
    }
    html[data-mangatan-reader-layout="horizontal-pages"] .mangatan-logical-section:not(:first-child),
    html[data-mangatan-reader-layout="vertical-pages"] .mangatan-logical-section:not(:first-child) {
      break-before: column;
      -webkit-column-break-before: always;
    }
    html[data-mangatan-reader-layout="horizontal-pages"] #reader-content p,
    html[data-mangatan-reader-layout="vertical-pages"] #reader-content p {
      break-inside: avoid;
      -webkit-column-break-inside: avoid;
    }
    html[data-mangatan-reader-layout="horizontal-pages"] .mangatan-full-page-media,
    html[data-mangatan-reader-layout="vertical-pages"] .mangatan-full-page-media {
      display: flex !important;
      align-items: center !important;
      justify-content: center !important;
      box-sizing: border-box !important;
      width: calc(100vw - ${padding * 2}vh) !important;
      height: calc(100vh - ${padding * 2}vh) !important;
      margin: 0 !important;
      padding: 0 !important;
      overflow: hidden !important;
      break-before: column !important;
      break-after: column !important;
      break-inside: avoid !important;
      -webkit-column-break-before: always !important;
      -webkit-column-break-after: always !important;
      -webkit-column-break-inside: avoid !important;
    }
    html[data-mangatan-reader-layout="horizontal-pages"] .mangatan-full-page-media img,
    html[data-mangatan-reader-layout="horizontal-pages"] .mangatan-full-page-media svg,
    html[data-mangatan-reader-layout="vertical-pages"] .mangatan-full-page-media img,
    html[data-mangatan-reader-layout="vertical-pages"] .mangatan-full-page-media svg {
      width: 100% !important;
      height: 100% !important;
      max-width: 100% !important;
      max-height: 100% !important;
      margin: auto !important;
      padding: 0 !important;
      object-fit: contain !important;
    }
    html[data-mangatan-reader-layout="horizontal-pages"] .mangatan-full-page-media-wrapper,
    html[data-mangatan-reader-layout="vertical-pages"] .mangatan-full-page-media-wrapper {
      display: flex !important;
      align-items: center !important;
      justify-content: center !important;
      box-sizing: border-box !important;
      width: 100% !important;
      height: 100% !important;
      max-width: none !important;
      max-height: none !important;
      margin: 0 !important;
      padding: 0 !important;
      overflow: visible !important;
      float: none !important;
      transform: none !important;
    }
    html[data-mangatan-reader-layout="vertical-pages"] #reader-content {
      writing-mode: vertical-rl !important;
      text-orientation: mixed;
      column-width: calc(100vh - ${padding * 2}vh) !important;
      /* Column width + gap must equal one physical viewport. Any mismatch
         accumulates on every page and eventually seeks into blank columns. */
      column-gap: ${padding * 2}vh !important;
    }
    html[data-mangatan-reader-layout="vertical-pages"] #reader-content img,
    html[data-mangatan-reader-layout="vertical-pages"] #reader-content svg,
    html[data-mangatan-reader-layout="vertical-scroll"] #reader-content img,
    html[data-mangatan-reader-layout="vertical-scroll"] #reader-content svg {
      max-width: calc(100vw - ${padding * 2}vh);
      max-height: calc(100vh - ${padding * 2}vh - ${fontSize}px);
      margin: 0 auto !important;
    }
    html[data-mangatan-reader-layout="vertical-scroll"] #reader-content {
      writing-mode: vertical-rl !important;
      text-orientation: mixed;
      overflow-x: auto !important;
      overflow-y: hidden !important;
      column-width: auto !important;
      column-gap: normal !important;
    }
    html[data-mangatan-reader-layout="horizontal-scroll"] .mangatan-logical-target {
      min-height: 100vh;
    }
    html[data-mangatan-reader-layout="vertical-scroll"] .mangatan-logical-target {
      min-width: 100vw;
    }
    #dictionary-action {
      position: fixed; z-index: 2147483647; display: none; transform: translate(-50%, -100%);
      border: 0; border-radius: 999px; padding: 8px 14px; color: white; background: #1769c2;
      font: 600 13px system-ui, sans-serif; box-shadow: 0 4px 16px rgba(0,0,0,.35); cursor: pointer;
    }
  </style>
</head>
<body>
  <main id="reader-content">$content</main>
  <button id="dictionary-action" type="button">Dictionary</button>
  <script>
    (() => {
      const initialProgress = $progress;
      const initialChapterIndex = $initialChapterIndexValue;
      const initialChapterProgress = $initialChapterProgressValue;
      const initialSpineIndex = $initialSpineIndexValue;
      const tapZones = $tapZones;
      const pageMode = $pageMode;
      const verticalWriting = $verticalWriting;
      const continuousVertical = verticalWriting && !pageMode;
      const lookupTrigger = $lookupTriggerValue;
      const additionalLeftClick = $additionalLeftClickValue;
      const leftClickLookupEnabled = (event) =>
        lookupTrigger === 'leftClick' ||
        (additionalLeftClick &&
          (!event.pointerType || event.pointerType === 'mouse'));
      const content = document.getElementById('reader-content');
      const action = document.getElementById('dictionary-action');
      let progressFrame = 0;
      let selected = null;
      let ready = false;
      let activeLookup = null;
      let nextLookupToken = 0;
      let prefetchTimer = 0;
      let lastPrefetchedText = '';
      let lookupHighlight = false;
      let lastPointerX = null;
      let lastPointerY = null;
      let shiftLookupActive = false;
      let middleLookupActive = false;
      let lastHeldLookupKey = null;
      let nextTextNodeId = 0;
      const textNodeIds = new WeakMap();
      let measuredPageMax = null;

      const call = (name, payload) => {
        if (window.flutter_inappwebview?.callHandler) {
          window.flutter_inappwebview.callHandler(name, payload);
        }
      };
      const scrollElement = () => (pageMode || continuousVertical)
        ? content
        : (document.scrollingElement || document.documentElement || document.body);
      const continuousVerticalContext = () => {
        const max = Math.max(0, content.scrollWidth - content.clientWidth);
        return {
          root: content,
          axis: 'x',
          pageSize: content.clientWidth,
          max,
          offset: Math.min(max, Math.abs(content.scrollLeft)),
        };
      };
      const rawPageContext = () => {
        const root = content;
        const xMax = Math.max(0, root.scrollWidth - root.clientWidth);
        const yMax = Math.max(0, root.scrollHeight - root.clientHeight);
        // Chromium/WebView2 lays out this vertical multicolumn flow on the Y
        // axis. Incidental X overflow from a cover or publisher stylesheet is
        // not a page axis and must never win this choice.
        const axis = verticalWriting
          ? 'y'
          : (xMax > 0 ? 'x' : 'y');
        const pageSize = axis === 'x' ? root.clientWidth : root.clientHeight;
        const max = axis === 'x' ? xMax : yMax;
        const offset = axis === 'x'
          ? Math.min(max, Math.abs(root.scrollLeft))
          : Math.min(max, root.scrollTop);
        return { root, axis, pageSize, max, offset };
      };
      const pageContext = () => {
        const raw = rawPageContext();
        const max = measuredPageMax == null
          ? raw.max
          : Math.min(raw.max, measuredPageMax);
        return { ...raw, max, offset: Math.min(max, raw.offset) };
      };
      const setPageOffset = (context, value) => {
        const target = Math.max(0, Math.min(context.max, Number(value) || 0));
        if (context.axis === 'y') {
          context.root.scrollTop = target;
          return Math.min(context.max, context.root.scrollTop);
        }
        if (verticalWriting) {
          // Chromium uses negative scrollLeft for vertical-rl while WebKit can
          // expose a positive model. Try the authored direction first, then
          // fall back and always report the observed value.
          context.root.scrollLeft = -target;
          if (Math.abs(Math.abs(context.root.scrollLeft) - target) > 1) {
            context.root.scrollLeft = target;
          }
          return Math.min(context.max, Math.abs(context.root.scrollLeft));
        }
        context.root.scrollLeft = target;
        return Math.min(context.max, context.root.scrollLeft);
      };
      const alignToPage = (context, anchor) => {
        if (context.pageSize <= 0) return 0;
        return Math.min(
          context.max,
          Math.floor(Math.max(0, anchor) / context.pageSize) * context.pageSize,
        );
      };
      const measureLastContentPage = () => {
        if (!pageMode) return 0;
        const context = rawPageContext();
        if (context.pageSize <= 0 || context.max <= 0) return 0;
        let lastEnd = 0;
        const includeRect = (rect) => {
          if (!rect || rect.width <= 0 || rect.height <= 0) return;
          const end = context.axis === 'y'
            ? rect.bottom + context.offset
            : rect.right + context.offset;
          if (Number.isFinite(end)) lastEnd = Math.max(lastEnd, end);
        };
        const textWalker = document.createTreeWalker(
          content,
          NodeFilter.SHOW_TEXT,
          {
            acceptNode: (node) => (node.textContent || '').trim()
              ? NodeFilter.FILTER_ACCEPT
              : NodeFilter.FILTER_REJECT,
          },
        );
        while (textWalker.nextNode()) {
          const range = document.createRange();
          range.selectNodeContents(textWalker.currentNode);
          for (const rect of range.getClientRects()) includeRect(rect);
          range.detach?.();
        }
        for (const element of content.querySelectorAll(
          'img, svg, video, canvas, table, hr',
        )) {
          for (const rect of element.getClientRects()) includeRect(rect);
        }
        if (lastEnd <= 0) return 0;
        const lastPage = Math.floor(
          Math.max(0, lastEnd - 1) / context.pageSize,
        ) * context.pageSize;
        return Math.min(context.max, lastPage);
      };
      const calculateProgress = () => {
        if (continuousVertical) {
          const context = continuousVerticalContext();
          return context.max > 0 ? context.offset / context.max : 0;
        }
        if (!pageMode) {
          const root = scrollElement();
          const max = Math.max(0, root.scrollHeight - window.innerHeight);
          return max > 0 ? (root.scrollTop || window.scrollY || 0) / max : 0;
        }
        const context = pageContext();
        return context.max > 0 ? context.offset / context.max : 0;
      };
      const readerLocationContext = () => {
        if (pageMode) return pageContext();
        if (continuousVertical) return continuousVerticalContext();
        const root = scrollElement();
        const max = Math.max(0, root.scrollHeight - window.innerHeight);
        return {
          root,
          axis: 'y',
          pageSize: window.innerHeight,
          max,
          offset: root.scrollTop || window.scrollY || 0,
        };
      };
      const sectionStart = (section, context) => {
        const rect = section.getBoundingClientRect();
        if (context.axis === 'y') return rect.top + context.offset;
        if (verticalWriting) {
          return window.innerWidth - rect.right + context.offset;
        }
        return rect.left + context.offset;
      };
      const epubSections = () => Array.from(
        content.querySelectorAll('section[data-mangatan-chapter-index]'),
      );
      const allEpubSections = () => Array.from(
        content.querySelectorAll('section[data-mangatan-spine-index]'),
      );
      const navigationSections = () => Array.from(
        content.querySelectorAll(
          'section[data-mangatan-navigation="true"]',
        ),
      );
      const logicalSections = () => Array.from(
        content.querySelectorAll('article[data-mangatan-navigation-spine]'),
      );
      const clearLogicalTarget = () => {
        for (const section of logicalSections()) {
          section.classList.remove('mangatan-logical-target');
        }
      };
      const chimahonCountChars = (text) => Array.from(
        String(text || '').replace(
          /[^0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚａ-ｚｦ-ﾝ${r'\p'}{Radical}${r'\p'}{Unified_Ideograph}${r'\p'}{Script=Hangul}]+/gimu,
          '',
        ),
      ).length;
      const chimahonTextWalker = (section) => document.createTreeWalker(
        section,
        NodeFilter.SHOW_TEXT,
        {
          acceptNode: (node) => node.parentElement?.closest?.('rt, rp')
            ? NodeFilter.FILTER_REJECT
            : NodeFilter.FILTER_ACCEPT,
        },
      );
      const chimahonContinuousProgress = (section) => {
        const walker = chimahonTextWalker(section);
        let total = 0;
        let explored = 0;
        let node;
        while ((node = walker.nextNode())) {
          const length = chimahonCountChars(node.textContent);
          total += length;
          if (!length) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          const rect = range.getBoundingClientRect();
          range.detach?.();
          if (verticalWriting
              ? rect.left > window.innerWidth
              : rect.bottom < 0) {
            explored += length;
          }
        }
        return {
          explored,
          progress: total > 0 ? explored / total : 0,
        };
      };
      const jumpToChimahonProgress = (section, progress) => {
        const p = Math.max(0, Math.min(1, Number(progress) || 0));
        const walker = chimahonTextWalker(section);
        let total = 0;
        let node;
        while ((node = walker.nextNode())) {
          total += chimahonCountChars(node.textContent);
        }
        if (total <= 0) return jumpToFragment(section.id);
        const targetCount = Math.ceil(total * p);
        let running = 0;
        let targetNode = null;
        walker.currentNode = section;
        while ((node = walker.nextNode())) {
          running += chimahonCountChars(node.textContent);
          targetNode = node;
          if (running > targetCount) break;
        }
        const element = targetNode?.parentElement || section;
        element.scrollIntoView({
          block: p >= .999999 ? 'end' : 'start',
          inline: 'start',
          behavior: 'auto',
        });
        queueReport();
        return true;
      };
      const locationMetrics = () => {
        const context = readerLocationContext();
        const sections = epubSections();
        const allSections = allEpubSections();
        if (!sections.length) {
          return {
            chapterIndex: 0,
            chapterProgress: calculateProgress(),
            characterCount: 0,
            spineIndex: 0,
          };
        }
        const starts = sections.map((section) => sectionStart(section, context));
        let index = 0;
        for (let i = 0; i < starts.length; i += 1) {
          if (starts[i] <= context.offset + 1) index = i;
          else break;
        }
        const section = sections[index];
        const start = starts[index];
        const end = index + 1 < starts.length
          ? starts[index + 1]
          : Math.max(start + 1, context.max + context.pageSize);
        const geometricProgress = Math.max(
          0,
          Math.min(1, (context.offset - start) / Math.max(1, end - start)),
        );
        const continuousProgress = !pageMode
          ? chimahonContinuousProgress(section)
          : null;
        const chapterProgress = continuousProgress?.progress ?? geometricProgress;
        const characterStart = Number(
          section.dataset.mangatanCharacterStart || 0,
        );
        const characterLength = Number(
          section.dataset.mangatanCharacterCount || 0,
        );
        let physicalSection = allSections[0] || section;
        for (const candidate of allSections) {
          if (sectionStart(candidate, context) <= context.offset + 1) {
            physicalSection = candidate;
          } else {
            break;
          }
        }
        return {
          chapterIndex: Number(section.dataset.mangatanChapterIndex || index),
          chapterProgress,
          characterCount: characterStart + Math.floor(characterLength * chapterProgress),
          spineIndex: Number(physicalSection.dataset.mangatanSpineIndex || 0),
        };
      };
      const metrics = () => {
        const root = scrollElement();
        const location = locationMetrics();
        if (pageMode) {
          return { offset: calculateProgress(), max: 1, ...location };
        }
        if (continuousVertical) {
          const context = continuousVerticalContext();
          return { offset: context.offset, max: context.max, ...location };
        }
        const max = Math.max(0, root.scrollHeight - window.innerHeight);
        return { offset: root.scrollTop || window.scrollY || 0, max, ...location };
      };
      const report = () => { progressFrame = 0; call('readerProgress', metrics()); };
      const queueReport = () => { if (!progressFrame) progressFrame = requestAnimationFrame(report); };
      const fraction = () => calculateProgress();
      const setOffset = (value, behavior = 'auto') => {
        const root = scrollElement();
        if (pageMode) return setPageOffset(pageContext(), value);
        if (continuousVertical) {
          return setPageOffset(continuousVerticalContext(), value);
        }
        const max = Math.max(0, root.scrollHeight - window.innerHeight);
        const target = Math.max(0, Math.min(max, Number(value) || 0));
        root.scrollTo({ top: target, behavior });
        return target;
      };
      const restoreProgress = async (value) => {
        const progress = Math.max(0, Math.min(1, Number(value) || 0));
        await (document.fonts?.ready || Promise.resolve());
        if (continuousVertical) {
          const context = continuousVerticalContext();
          setPageOffset(context, progress * context.max);
          queueReport();
          return;
        }
        if (!pageMode) {
          const root = scrollElement();
          setOffset(progress * Math.max(0, root.scrollHeight - window.innerHeight));
          queueReport();
          return;
        }
        const context = pageContext();
        if (context.pageSize <= 0 || progress <= 0) {
          setPageOffset(context, 0);
          queueReport();
          return;
        }
        if (progress >= .99) {
          const target = setPageOffset(context, context.max);
          requestAnimationFrame(() => setPageOffset(pageContext(), target));
          queueReport();
          return;
        }
        const target = setPageOffset(
          context,
          alignToPage(context, progress * context.max),
        );
        requestAnimationFrame(() => setPageOffset(pageContext(), target));
        requestAnimationFrame(() => requestAnimationFrame(queueReport));
      };
      const jumpToFraction = (value) => restoreProgress(value);
      const jumpToAbsolute = (value) => {
        const context = readerLocationContext();
        const target = Math.max(0, Math.min(context.max, Number(value) || 0));
        if (pageMode && context.pageSize > 0) {
          setPageOffset(context, alignToPage(context, target));
        } else {
          setPageOffset(context, target);
        }
        queueReport();
      };
      const jumpToBookmark = (chapterIndex, progress, clearIsolation = true) => {
        if (clearIsolation) clearLogicalTarget();
        const context = readerLocationContext();
        const sections = epubSections();
        if (!sections.length) return false;
        const index = Math.max(
          0,
          Math.min(sections.length - 1, Number(chapterIndex) || 0),
        );
        if (!pageMode) {
          return jumpToChimahonProgress(sections[index], progress);
        }
        const starts = sections.map((section) => sectionStart(section, context));
        const start = starts[index] || 0;
        const end = index + 1 < starts.length
          ? starts[index + 1]
          : Math.max(start + 1, context.max + context.pageSize);
        jumpToAbsolute(start + Math.max(0, Math.min(1, Number(progress) || 0)) * (end - start));
        return true;
      };
      const jumpToAdjacentChapter = (direction) => {
        const context = readerLocationContext();
        const sections = navigationSections();
        if (!sections.length) return false;
        const starts = sections.map((section) => sectionStart(section, context));
        const sign = Math.sign(Number(direction) || 0);
        let target = -1;
        if (sign > 0) {
          target = starts.findIndex((start) => start > context.offset + 1);
        } else if (sign < 0) {
          for (let i = starts.length - 1; i >= 0; i -= 1) {
            if (starts[i] < context.offset - 1) { target = i; break; }
          }
        }
        if (target < 0) return false;
        const spineIndex = Number(
          sections[target].dataset.mangatanSpineIndex || 0,
        );
        jumpToLogicalSpine(spineIndex, false);
        return true;
      };
      const jumpToFragment = async (fragment) => {
        const id = String(fragment || '').replace(/^#/, '');
        const target = id && (document.getElementById(id) || document.getElementsByName(id)[0]);
        if (!target) return false;
        await (document.fonts?.ready || Promise.resolve());
        if (continuousVertical) {
          const context = continuousVerticalContext();
          const rect = target.getClientRects()[0] || target.getBoundingClientRect();
          setPageOffset(
            context,
            window.innerWidth - rect.right + context.offset,
          );
        } else if (!pageMode) {
          target.scrollIntoView({ block: 'start', behavior: 'auto' });
        } else {
          const context = pageContext();
          const rect = target.getClientRects()[0] || target.getBoundingClientRect();
          const absolute = context.axis === 'y'
            ? rect.top + context.offset
            : verticalWriting
              ? window.innerWidth - rect.right + context.offset
              : rect.left + context.offset;
          const offset = setPageOffset(context, alignToPage(context, absolute));
          requestAnimationFrame(() => setPageOffset(pageContext(), offset));
        }
        queueReport();
        return true;
      };
      const jumpToLogicalSpine = async (spineIndex, isolateChapter = true) => {
        const wanted = Number(spineIndex);
        const physical = content.querySelector(
          'section[data-mangatan-spine-index="' + wanted + '"]',
        );
        const target = logicalSections().find(
          (section) => Number(section.dataset.mangatanNavigationSpine) === wanted,
        ) || physical?.closest('.mangatan-logical-section');
        if (!target) return false;
        clearLogicalTarget();
        if (!pageMode && isolateChapter) {
          target.classList.add('mangatan-logical-target');
        }
        await (document.fonts?.ready || Promise.resolve());
        const place = () => {
          const context = readerLocationContext();
          const marker = target.querySelector('.mangatan-logical-marker') || target;
          const absolute = sectionStart(marker, context);
          if (pageMode) {
            setPageOffset(context, alignToPage(context, absolute));
          } else {
            setPageOffset(context, absolute);
          }
        };
        place();
        requestAnimationFrame(() => {
          place();
          requestAnimationFrame(() => {
            place();
            queueReport();
          });
        });
        return true;
      };
      const restorePreviewPosition = async (
        spineIndex,
        chapterIndex,
        chapterProgress,
      ) => {
        await jumpToLogicalSpine(spineIndex, true);
        return jumpToBookmark(chapterIndex, chapterProgress, false);
      };
      const scrollByPixels = (value) => {
        const before = pageMode ? pageContext().offset : metrics().offset;
        const after = setOffset(before + (Number(value) || 0), 'auto');
        queueReport();
        return Math.abs(after - before) > 1;
      };
      const scrollPage = (direction) => {
        clearLookup();
        if (!pageMode) {
          const before = metrics().offset;
          const viewport = continuousVertical
            ? window.innerWidth
            : window.innerHeight;
          setOffset(before + (Number(direction) || 0) * viewport * .88);
          const moved = Math.abs(metrics().offset - before) > 1;
          queueReport();
          return moved;
        }
        const context = pageContext();
        if (context.pageSize <= 0) return false;
        const sign = Math.sign(Number(direction) || 0);
        if (!sign) return false;
        if (sign > 0 && context.offset >= context.max - 1) return false;
        if (sign < 0 && context.offset <= 1) return false;
        const target = sign > 0
          ? Math.min(
              context.max,
              (Math.floor(context.offset / context.pageSize) + 1) * context.pageSize,
            )
          : Math.max(
              0,
              Math.floor(Math.max(0, context.offset - 1) / context.pageSize) * context.pageSize,
            );
        const actual = setPageOffset(context, target);
        requestAnimationFrame(() => setPageOffset(pageContext(), actual));
        const moved = Math.abs(actual - context.offset) > 1;
        queueReport();
        return moved;
      };
      const isIgnored = (node) => {
        const element = node?.nodeType === Node.TEXT_NODE ? node.parentElement : node;
        return !!element?.closest?.('rt, rp, script, style, textarea');
      };
      const walker = (root = content) => document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
        acceptNode: (node) => isIgnored(node) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT,
      });
      const isLookupChar = (character) => /[\\p{Script=Hiragana}\\p{Script=Katakana}\\p{Script=Han}\\p{Script=Hangul}A-Za-z0-9々〆ヶー]/u.test(character || '');
      const sentenceBoundary = (character) => /[。！？!?\\n\\r]/u.test(character || '');
      const textContainer = (node) => node?.parentElement?.closest?.('p, li, blockquote, td, th, figcaption, .glossary-content') || content;
      const caretAt = (x, y) => {
        if (document.caretPositionFromPoint) {
          const position = document.caretPositionFromPoint(x, y);
          return position ? { node: position.offsetNode, offset: position.offset } : null;
        }
        const range = document.caretRangeFromPoint?.(x, y);
        return range ? { node: range.startContainer, offset: range.startOffset } : null;
      };
      const rangeContainsPoint = (range, x, y) => {
        const rects = Array.from(range.getClientRects());
        return rects.some((rect) => x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom);
      };
      const characterAt = (x, y) => {
        const hit = caretAt(x, y);
        if (!hit || hit.node?.nodeType !== Node.TEXT_NODE || isIgnored(hit.node)) return null;
        const value = hit.node.textContent || '';
        for (let offset of [hit.offset, hit.offset - 1, hit.offset + 1]) {
          if (offset > 0 && offset < value.length) {
            const code = value.charCodeAt(offset);
            if (code >= 0xdc00 && code <= 0xdfff) offset -= 1;
          }
          if (offset < 0 || offset >= value.length) continue;
          const character = String.fromCodePoint(value.codePointAt(offset));
          if (!isLookupChar(character)) continue;
          const range = document.createRange();
          range.setStart(hit.node, offset);
          range.setEnd(hit.node, offset + character.length);
          if (rangeContainsPoint(range, x, y)) return { node: hit.node, offset };
        }
        return null;
      };
      const sentenceFor = (startNode, startOffset) => {
        const before = []; const after = [];
        let node = startNode; let offset = startOffset;
        const tree = walker(textContainer(startNode)); tree.currentNode = node;
        while (node) {
          const value = node.textContent || ''; let found = -1;
          for (let index = Math.min(offset - 1, value.length - 1); index >= 0; index--) {
            if (sentenceBoundary(value[index])) { found = index; break; }
          }
          before.push(value.slice(found + 1, offset));
          if (found >= 0) break;
          node = tree.previousNode(); offset = node ? (node.textContent || '').length : 0;
        }
        node = startNode; offset = startOffset; tree.currentNode = node;
        while (node) {
          const value = node.textContent || ''; let end = value.length;
          for (let index = offset; index < value.length; index++) {
            if (sentenceBoundary(value[index])) { end = index + 1; break; }
          }
          after.push(value.slice(offset, end));
          if (end < value.length) break;
          node = tree.nextNode(); offset = 0;
        }
        return (before.reverse().join('') + after.join('')).trim();
      };
      const scanLookup = (startNode, startOffset) => {
        const tree = walker(textContainer(startNode));
        tree.currentNode = startNode;
        let node = startNode;
        let offset = startOffset;
        let text = '';
        let length = 0;
        const ranges = [];
        while (node && length < 32) {
          const value = node.textContent || '';
          const start = offset;
          while (offset < value.length && length < 32) {
            const character = String.fromCodePoint(value.codePointAt(offset));
            if (!isLookupChar(character)) {
              if (offset > start) ranges.push({ node, start, end: offset });
              return { text, ranges };
            }
            text += character;
            length += 1;
            offset += character.length;
          }
          if (offset > start) ranges.push({ node, start, end: offset });
          if (offset < value.length || length >= 32) break;
          node = tree.nextNode();
          offset = 0;
        }
        return { text, ranges };
      };
      const prefetchAt = (x, y) => {
        const hit = characterAt(x, y);
        if (!hit) return;
        const text = scanLookup(hit.node, hit.offset).text;
        if (!text || text === lastPrefetchedText) return;
        lastPrefetchedText = text;
        call('readerPrefetch', { text });
      };
      const highlightMatch = (count, expectedToken) => {
        if (!activeLookup || activeLookup.token !== Number(expectedToken)) return false;
        let remaining = Math.max(1, Number(count) || 1);
        const ranges = [];
        for (const source of activeLookup.ranges) {
          let offset = source.start;
          while (offset < source.end && remaining > 0) {
            const character = String.fromCodePoint(source.node.textContent.codePointAt(offset));
            const end = offset + character.length;
            const range = document.createRange();
            range.setStart(source.node, offset);
            range.setEnd(source.node, end);
            ranges.push(range);
            offset = end;
            remaining -= 1;
          }
          if (remaining <= 0) break;
        }
        if (!ranges.length || typeof Highlight === 'undefined' || !CSS.highlights) return false;
        lookupHighlight = true;
        selected = null;
        action.style.display = 'none';
        window.getSelection()?.removeAllRanges();
        CSS.highlights.set('hoshi-selection', new Highlight(...ranges));
        return true;
      };
      const lookupAt = (x, y, existingHit = null) => {
        const hit = existingHit || characterAt(x, y);
        if (!hit) return null;
        const scan = scanLookup(hit.node, hit.offset);
        const query = scan.text;
        if (!query) return null;
        const lookupToken = ++nextLookupToken;
        activeLookup = {
          ranges: scan.ranges,
          token: lookupToken,
          originNode: hit.node,
          originOffset: hit.offset,
        };
        const range = document.createRange();
        const character = String.fromCodePoint(hit.node.textContent.codePointAt(hit.offset));
        range.setStart(hit.node, hit.offset);
        range.setEnd(hit.node, hit.offset + character.length);
        const rects = Array.from(range.getClientRects());
        const rect = rects.find((candidate) =>
          x >= candidate.left && x <= candidate.right &&
          y >= candidate.top && y <= candidate.bottom
        ) || range.getBoundingClientRect();
        return { text: query, sentence: sentenceFor(hit.node, hit.offset), left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom, lookupToken };
      };
      const hideAction = () => { action.style.display = 'none'; selected = null; };
      const selectionText = (selection) => {
        if (!selection?.rangeCount) return '';
        const fragment = selection.getRangeAt(0).cloneContents();
        fragment.querySelectorAll?.('rt, rp, script, style').forEach((element) => element.remove());
        return (fragment.textContent || '').trim();
      };
      const updateSelection = () => {
        if (lookupHighlight) { action.style.display = 'none'; selected = null; return; }
        const selection = window.getSelection(); const text = selectionText(selection);
        if (!text || !selection.rangeCount) { hideAction(); return; }
        const range = selection.getRangeAt(0);
        const rect = range.getBoundingClientRect();
        if (!rect || (!rect.width && !rect.height)) { hideAction(); return; }
        selected = {
          text,
          sentence: range.startContainer?.nodeType === Node.TEXT_NODE
            ? sentenceFor(range.startContainer, range.startOffset)
            : text,
          left: rect.left,
          right: rect.right,
          bottom: rect.bottom,
        };
        action.style.left = Math.max(56, Math.min(window.innerWidth - 56, rect.left + rect.width / 2)) + 'px';
        action.style.top = Math.max(42, rect.top - 8) + 'px'; action.style.display = 'block';
      };
      const clearLookup = (expectedToken) => {
        if (expectedToken != null && activeLookup?.token !== Number(expectedToken)) return false;
        lookupHighlight = false;
        activeLookup = null;
        window.getSelection()?.removeAllRanges();
        CSS.highlights?.get('hoshi-selection')?.clear();
        CSS.highlights?.delete('hoshi-selection');
        hideAction();
        return true;
      };
      const clearSelection = () => clearLookup();
      const triggerLookupAt = (x, y, hit = null) => {
        if (!Number.isFinite(x) || !Number.isFinite(y)) return false;
        hideAction();
        const lookup = lookupAt(x, y, hit);
        if (!lookup) { clearLookup(); return false; }
        call('readerDictionary', lookup);
        return true;
      };
      const pointsAtActiveLookup = (x, y) => {
        if (!activeLookup || !Number.isFinite(x) || !Number.isFinite(y)) {
          return false;
        }
        const hit = characterAt(x, y);
        return hit != null &&
          activeLookup.originNode === hit.node &&
          activeLookup.originOffset === hit.offset;
      };
      const dismissReaderDictionary = () => {
        call('readerDismissDictionary');
        clearLookup();
      };
      const triggerHeldLookupAt = (x, y) => {
        if (!Number.isFinite(x) || !Number.isFinite(y)) {
          lastHeldLookupKey = null;
          clearLookup();
          call('readerDismissDictionary');
          return false;
        }
        const hit = characterAt(x, y);
        if (!hit) {
          lastHeldLookupKey = null;
          clearLookup();
          call('readerDismissDictionary');
          return false;
        }
        let nodeId = textNodeIds.get(hit.node);
        if (nodeId == null) {
          nodeId = ++nextTextNodeId;
          textNodeIds.set(hit.node, nodeId);
        }
        const key = nodeId + ':' + hit.offset;
        if (key === lastHeldLookupKey) return true;
        lastHeldLookupKey = key;
        const triggered = triggerLookupAt(x, y, hit);
        if (!triggered) call('readerDismissDictionary');
        return triggered;
      };
      const setShiftLookupActive = (active) => {
        if (lookupTrigger !== 'shift') return false;
        const wasActive = shiftLookupActive;
        shiftLookupActive = Boolean(active);
        if (!shiftLookupActive) { lastHeldLookupKey = null; return true; }
        if (wasActive) return true;
        lastHeldLookupKey = null;
        return triggerHeldLookupAt(lastPointerX, lastPointerY);
      };
      window.mangatanReader = {
        fraction,
        calculateProgress,
        restoreProgress,
        jumpToFraction,
        jumpToBookmark,
        restorePreviewPosition,
        jumpToAdjacentChapter,
        jumpToFragment,
        jumpToLogicalSpine,
        clearLogicalTarget,
        metrics,
        scrollByPixels,
        scrollPage,
        highlightMatch,
        clearLookup,
        clearSelection,
        setShiftLookupActive,
        isReady: () => ready,
      };

      window.addEventListener('scroll', queueReport, { passive: true });
      scrollElement().addEventListener('scroll', queueReport, { passive: true });
      let resizeTimer = 0;
      window.addEventListener('resize', () => {
        const savedFraction = fraction();
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(() => restoreProgress(savedFraction), 80);
      }, { passive: true });
      document.addEventListener('selectionchange', () => setTimeout(updateSelection, 0));
      document.addEventListener('mouseup', () => setTimeout(updateSelection, 0));
      document.addEventListener('touchend', () => setTimeout(updateSelection, 0), { passive: true });
      action.addEventListener('click', (event) => { event.preventDefault(); event.stopPropagation(); if (selected) call('readerDictionary', selected); });
      document.addEventListener('pointermove', (event) => {
        if (event.pointerType && event.pointerType !== 'mouse') return;
        const x = event.clientX; const y = event.clientY;
        lastPointerX = x; lastPointerY = y;
        clearTimeout(prefetchTimer);
        prefetchTimer = setTimeout(() => prefetchAt(x, y), 70);
        const shiftScan = lookupTrigger === 'shift' &&
          (event.shiftKey || shiftLookupActive);
        const middleScan = lookupTrigger === 'middleClick' && middleLookupActive;
        if (shiftScan || middleScan) {
          triggerHeldLookupAt(x, y);
        }
      }, { passive: true });
      document.addEventListener('pointerdown', (event) => {
        if (event.button === 3) {
          event.preventDefault();
          event.stopPropagation();
          call('readerBack');
          return;
        }
        if (lookupTrigger === 'middleClick' && event.button === 1) {
          event.preventDefault();
          middleLookupActive = true;
          lastHeldLookupKey = null;
          if (event.target !== action && !selectionText(window.getSelection())) {
            triggerHeldLookupAt(event.clientX, event.clientY);
          }
        }
        if (!event.pointerType || event.pointerType === 'mouse') {
          lastPointerX = event.clientX; lastPointerY = event.clientY;
        }
        prefetchAt(event.clientX, event.clientY);
      }, { passive: false });
      document.addEventListener('pointerup', (event) => {
        if (lookupTrigger !== 'middleClick' || !middleLookupActive) return;
        event.preventDefault();
        event.stopPropagation();
        middleLookupActive = false;
        lastHeldLookupKey = null;
      });
      document.addEventListener('pointercancel', () => {
        middleLookupActive = false;
        lastHeldLookupKey = null;
      });
      document.addEventListener('auxclick', (event) => {
        if (event.button === 3) {
          event.preventDefault();
          event.stopPropagation();
          return;
        }
        if (lookupTrigger !== 'middleClick' || event.button !== 1) return;
        event.preventDefault();
        event.stopPropagation();
        middleLookupActive = false;
      }, true);
      document.addEventListener('click', (event) => {
        if (event.target === action) return;
        const selection = window.getSelection(); if (selectionText(selection)) return;
        const link = event.target.closest?.('a[href]');
        if (link) { event.preventDefault(); clearLookup(); const href = link.getAttribute('href') || ''; if (href.startsWith('#')) jumpToFragment(href); else call('readerLink', href); return; }
        const hadActiveLookup = activeLookup != null;
        if (leftClickLookupEnabled(event)) {
          if (pointsAtActiveLookup(event.clientX, event.clientY)) {
            dismissReaderDictionary();
            return;
          }
          const triggered = lookupTrigger === 'shift' &&
              (event.shiftKey || shiftLookupActive)
            ? triggerHeldLookupAt(event.clientX, event.clientY)
            : triggerLookupAt(event.clientX, event.clientY);
          if (triggered) return;
        }
        if (hadActiveLookup) {
          dismissReaderDictionary();
          return;
        }
        clearLookup();
        call('readerTap', { x: event.clientX, y: event.clientY, width: window.innerWidth, height: window.innerHeight, tapZones });
      });
      let pageSnapTimer = 0;
      document.addEventListener('wheel', (event) => {
        if (pageMode) {
          // Match the manga reader: every unmodified wheel signal is one
          // discrete page turn, even when several arrive before a frame.
          if (event.ctrlKey || event.metaKey) return;
          const pageDelta = event.deltaY !== 0 ? event.deltaY : event.deltaX;
          if (pageDelta === 0) return;
          event.preventDefault();
          scrollPage(pageDelta > 0 ? 1 : -1);
          return;
        }
        const rawDelta = Math.abs(event.deltaY) >= Math.abs(event.deltaX)
          ? event.deltaY
          : event.deltaX;
        const delta = rawDelta * (event.deltaMode === 1
          ? 18
          : event.deltaMode === 2
            ? (continuousVertical ? window.innerWidth : window.innerHeight)
            : 1);
        if (Math.abs(delta) < 1) return;
        // Explicitly bridge high-resolution trackpad wheels into the reader's
        // logical axis. WebView2 otherwise drops vertical two-finger deltas
        // when the EPUB itself scrolls horizontally.
        event.preventDefault();
        if (scrollByPixels(delta)) {
          return;
        }
        // A trackpad gesture must never turn into a chapter change merely
        // because the current layout has not finished measuring its extent.
      }, { passive: false });
      const touchCenter = (touches) => {
        if (!touches || touches.length < 2) return null;
        return {
          x: (touches[0].clientX + touches[1].clientX) / 2,
          y: (touches[0].clientY + touches[1].clientY) / 2,
        };
      };
      let twoFingerPan = null;
      document.addEventListener('touchstart', (event) => {
        const center = touchCenter(event.touches);
        if (!center) return;
        clearLookup();
        twoFingerPan = { ...center };
      }, { passive: true });
      document.addEventListener('touchmove', (event) => {
        if (!twoFingerPan) return;
        const center = touchCenter(event.touches);
        if (!center) return;
        const dx = twoFingerPan.x - center.x;
        const dy = twoFingerPan.y - center.y;
        const delta = Math.abs(dy) >= Math.abs(dx) ? dy : dx;
        twoFingerPan.x = center.x;
        twoFingerPan.y = center.y;
        if (Math.abs(delta) < .25) return;
        event.preventDefault();
        scrollByPixels(delta);
      }, { passive: false });
      const finishTwoFingerPan = (event) => {
        if (event.touches?.length >= 2) return;
        twoFingerPan = null;
      };
      document.addEventListener('touchend', finishTwoFingerPan, { passive: true });
      document.addEventListener('touchcancel', () => { twoFingerPan = null; }, { passive: true });
      content.addEventListener('scroll', () => {
        queueReport();
        if (!pageMode) return;
        clearTimeout(pageSnapTimer);
        pageSnapTimer = setTimeout(() => {
          const context = pageContext();
          if (context.pageSize <= 0) return;
          const target = context.offset >= context.max - 1
            ? context.max
            : Math.min(
                context.max,
                Math.round(context.offset / context.pageSize) * context.pageSize,
              );
          setPageOffset(context, target);
          queueReport();
        }, 120);
      }, { passive: true });
      document.addEventListener('keydown', (event) => {
        if (event.key === 'Escape' ||
            event.key === 'Backspace' ||
            event.key === 'BrowserBack') {
          event.preventDefault();
          event.stopPropagation();
          call('readerBack');
          return;
        }
        if (lookupTrigger === 'shift' && event.key === 'Shift' && !event.repeat) {
          event.preventDefault();
          event.stopPropagation();
          setShiftLookupActive(true);
          return;
        }
        if (event.key === 'PageDown') {
          event.preventDefault();
          if (!scrollPage(1)) call('readerChapter', 1);
        }
        if (event.key === 'PageUp') {
          event.preventDefault();
          if (!scrollPage(-1)) call('readerChapter', -1);
        }
        if ((pageMode || continuousVertical) &&
            (event.key === 'ArrowLeft' || event.key === 'ArrowRight')) {
          event.preventDefault();
          const forward = verticalWriting
            ? event.key === 'ArrowLeft'
            : event.key === 'ArrowRight';
          const direction = forward ? 1 : -1;
          if (!scrollPage(direction)) call('readerChapter', direction);
        }
        if (event.key.toLowerCase() === 'n') call('readerChapter', 1);
        if (event.key.toLowerCase() === 'm') call('readerChapter', -1);
      });
      document.addEventListener('keyup', (event) => {
        if (lookupTrigger !== 'shift' || event.key !== 'Shift') return;
        setShiftLookupActive(false);
      });
      window.addEventListener('blur', () => {
        shiftLookupActive = false;
        middleLookupActive = false;
        lastHeldLookupKey = null;
      });

      // Hoshi normalizes ruby base text before retaining DOM ranges. This
      // keeps lookup ranges stable while excluding furigana from scans.
      content.querySelectorAll('ruby').forEach((ruby) => {
        Array.from(ruby.childNodes).forEach((node) => {
          if (node.nodeType !== Node.TEXT_NODE) return;
          if ((node.textContent || '').trim()) {
            const span = document.createElement('span');
            span.textContent = node.textContent;
            node.replaceWith(span);
          } else {
            node.remove();
          }
        });
      });

      const classifyFullPageMedia = () => {
        if (!pageMode) return;
        for (const candidate of content.querySelectorAll(
          '[data-mangatan-full-page-candidate]',
        )) {
          const media = candidate.matches('img, svg')
            ? candidate
            : candidate.querySelector('img, svg');
          if (!media) continue;
          let width = 0;
          let height = 0;
          if (media.tagName.toLowerCase() === 'img') {
            width = media.naturalWidth;
            height = media.naturalHeight;
          } else {
            const viewBox = media.viewBox?.baseVal;
            width = viewBox?.width || media.width?.baseVal?.value || 0;
            height = viewBox?.height || media.height?.baseVal?.value || 0;
          }
          const rendered = media.getBoundingClientRect();
          width ||= rendered.width;
          height ||= rendered.height;
          if (width >= 300 || height >= 300) {
            candidate.classList.add('mangatan-full-page-media');
            let wrapper = media.parentElement;
            while (wrapper && wrapper !== candidate) {
              wrapper.classList.add('mangatan-full-page-media-wrapper');
              wrapper = wrapper.parentElement;
            }
          }
        }
      };

      if (pageMode && !verticalWriting) {
        const spacer = document.createElement('div');
        spacer.setAttribute('aria-hidden', 'true');
        spacer.style.display = 'block';
        spacer.style.breakInside = 'avoid';
        spacer.style.height = '100%';
        spacer.style.width = '${padding}vh';
        content.appendChild(spacer);
      }

      for (const image of document.images) image.addEventListener('error', () => image.classList.add('mangatan-hidden-style'), { once: true });
      const imagesReady = Promise.all(Array.from(document.images).map((image) => image.complete ? Promise.resolve() : new Promise((resolve) => { image.addEventListener('load', resolve, { once: true }); image.addEventListener('error', resolve, { once: true }); })));
      imagesReady
        .then(() => classifyFullPageMedia())
        .then(() => new Promise((resolve) => setTimeout(resolve, 50)))
        .then(() => document.fonts?.ready)
        .then(() => {
          measuredPageMax = measureLastContentPage();
        })
        .then(() => restoreProgress(initialProgress))
        .then(async () => {
          let positionedExactly = false;
          if (initialSpineIndex !== null) {
            await jumpToLogicalSpine(initialSpineIndex);
            positionedExactly = true;
          } else if (
            initialChapterIndex !== null &&
            initialChapterProgress !== null
          ) {
            await jumpToBookmark(
              initialChapterIndex,
              initialChapterProgress,
            );
            positionedExactly = true;
          }
          if (positionedExactly) {
            await new Promise((resolve) => requestAnimationFrame(
              () => requestAnimationFrame(resolve),
            ));
          }
        })
        .catch((error) => {
          console.error('Mangatan EPUB initialization failed', error);
        })
        .then(() => requestAnimationFrame(() => requestAnimationFrame(() => {
          ready = true;
          queueReport();
          call('readerReady', { textLength: (content.innerText || '').trim().length, metrics: metrics() });
        })));
    })();
  </script>
</body>
</html>''';
}

/// Marks structurally standalone media for size classification in the reader.
///
/// EPUBs commonly wrap full-page illustrations in several empty `div`, `p`,
/// or `span` elements. Promote the outermost media-only wrapper so its margins
/// cannot leave text in the same column. Text-bearing wrappers, headings,
/// gaiji, and explicitly small media stay in the normal text flow.
void _markFullPageMediaCandidates(dom.Document document) {
  final body = document.body;
  if (body == null) return;

  final media = <dom.Element>[
    ...body.querySelectorAll('img'),
    ...body
        .querySelectorAll('svg')
        .where((element) => element.querySelector('image') != null),
  ];
  for (final element in media) {
    if (_hasInlineMediaSignal(element) || _hasSmallAuthoredDimension(element)) {
      continue;
    }

    dom.Element candidate = element;
    dom.Element? parent = element.parent;
    var hasInlineContext = false;
    while (parent != null && parent != body && !_isReaderSection(parent)) {
      if (_isHeading(parent) || _hasInlineMediaSignal(parent)) {
        hasInlineContext = true;
        break;
      }
      if (_containsOnlyMediaBranch(parent, candidate)) {
        candidate = parent;
        parent = parent.parent;
        continue;
      }
      if (_hasMeaningfulTextOutside(parent, candidate) ||
          _hasOtherMediaOutside(parent, candidate)) {
        hasInlineContext = true;
      }
      break;
    }
    if (parent != null &&
        _inlineMediaContextElements.contains(candidate.localName) &&
        _hasInlineSiblingContent(parent, candidate)) {
      hasInlineContext = true;
    }
    if (!hasInlineContext) {
      candidate.attributes['data-mangatan-full-page-candidate'] = 'true';
    }
  }
}

bool _isReaderSection(dom.Element element) =>
    (element.localName == 'section' &&
        element.attributes.containsKey('data-mangatan-spine-index')) ||
    element.classes.contains('mangatan-logical-section');

bool _isHeading(dom.Element element) =>
    const {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}.contains(element.localName);

bool _hasInlineMediaSignal(dom.Element element) {
  final classNames = element.classes.join(' ').toLowerCase();
  if (RegExp(
    r'(^|[\s_-])(gaiji(?:-line)?|inline(?:-img|-image)?|emoji|illus(?:tration)?|float[-_]?img|decorat(?:ive|ion)?)([\s_-]|$)',
  ).hasMatch(classNames)) {
    return true;
  }
  return element.attributes.entries.any((attribute) {
    final name = attribute.key.toString().toLowerCase();
    return name.endsWith('type') &&
        attribute.value.toLowerCase().contains('illustration');
  });
}

bool _hasSmallAuthoredDimension(dom.Element element) =>
    const ['width', 'height'].any((name) {
      final value = element.attributes[name];
      if (value == null) return false;
      final match = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*(?:px)?\s*$')
          .firstMatch(value);
      final dimension = double.tryParse(match?.group(1) ?? '');
      return dimension != null && dimension < 300;
    });

bool _containsOnlyMediaBranch(dom.Element container, dom.Element branch) {
  if (_hasMeaningfulTextOutside(container, branch)) return false;
  final otherMedia = <dom.Element>[
    ...container.querySelectorAll('img'),
    ...container
        .querySelectorAll('svg')
        .where((element) => element.querySelector('image') != null),
  ];
  return otherMedia.every(
    (element) => identical(element, branch) || branch.contains(element),
  );
}

bool _hasOtherMediaOutside(dom.Element container, dom.Element branch) {
  final media = <dom.Element>[
    ...container.querySelectorAll('img'),
    ...container
        .querySelectorAll('svg')
        .where((element) => element.querySelector('image') != null),
  ];
  return media.any(
    (element) => !identical(element, branch) && !branch.contains(element),
  );
}

const _inlineMediaContextElements = {
  'a',
  'b',
  'bdi',
  'bdo',
  'cite',
  'code',
  'data',
  'em',
  'i',
  'img',
  'label',
  'mark',
  'q',
  'ruby',
  's',
  'small',
  'span',
  'strong',
  'sub',
  'sup',
  'svg',
  'time',
  'u',
  'var',
};

bool _hasInlineSiblingContent(dom.Element container, dom.Element branch) {
  return container.nodes.any((node) {
    if (identical(node, branch)) return false;
    if (node is dom.Text) return node.data.trim().isNotEmpty;
    return node is dom.Element &&
        _inlineMediaContextElements.contains(node.localName) &&
        node.text.trim().isNotEmpty;
  });
}

bool _hasMeaningfulTextOutside(dom.Node node, dom.Element excludedBranch) {
  if (identical(node, excludedBranch)) return false;
  if (node is dom.Text) return node.data.trim().isNotEmpty;
  return node.nodes.any(
    (child) => _hasMeaningfulTextOutside(child, excludedBranch),
  );
}

void _sanitizeEpubDocument(dom.Document document) {
  document
      .querySelectorAll(
        'script, style, iframe, object, embed, base, meta[http-equiv]',
      )
      .forEach((element) => element.remove());
  for (final element in document.querySelectorAll('*')) {
    // Foreign-content attributes such as SVG's `xlink:href` are keyed by
    // [dom.AttributeName], so look them up by the original key.
    for (final key in element.attributes.keys.toList()) {
      final lower = (key is dom.AttributeName ? key.name : key.toString())
          .toLowerCase();
      final value = element.attributes[key] ?? '';
      if (lower.startsWith('on') || lower == 'srcdoc' || _isScriptUrl(value)) {
        element.attributes.remove(key);
        continue;
      }
      if (lower == 'style') {
        final sanitized = _sanitizeEpubStylesheet(value);
        if (sanitized.trim().isEmpty) {
          element.attributes.remove(key);
        } else {
          element.attributes[key] = sanitized;
        }
      }
    }
  }
}

/// Matches URLs that run script when followed. The reader's click handler
/// does not catch every navigation (an active selection, SVG `xlink:href`,
/// form actions), so these never reach the page. Browsers ignore ASCII
/// whitespace and control characters inside a scheme, hence the stripping.
bool _isScriptUrl(String value) {
  final scheme = value.replaceAll(RegExp(r'[\x00-\x20]'), '').toLowerCase();
  return scheme.startsWith('javascript:') ||
      scheme.startsWith('vbscript:') ||
      scheme.startsWith('data:text/html');
}

/// Publisher CSS is valuable for typography and images, but real EPUBs also
/// routinely ship rules intended for a specific reader shell (including
/// `display:none` on the entire document). Keep local layout/font rules while
/// removing declarations that can turn a valid chapter into a blank reader.
List<int> _resourceBytesForReader(EpubResource resource) {
  if (!resource.name.toLowerCase().endsWith('.css')) return resource.content;
  final stylesheet = utf8.decode(resource.content, allowMalformed: true);
  return utf8.encode(_sanitizeEpubStylesheet(stylesheet));
}

String _sanitizeEpubStylesheet(String stylesheet) => stylesheet
    .replaceAll(
      RegExp(
        r'''@import\s+(?:url\(\s*)?['"]?(?:https?:|//|javascript:)[^;]*;?''',
        caseSensitive: false,
      ),
      '',
    )
    .replaceAll(
      RegExp(r'''url\(\s*['"]?\s*javascript:[^)]*\)''', caseSensitive: false),
      'url()',
    )
    .replaceAll(RegExp(r'expression\s*\([^)]*\)', caseSensitive: false), '')
    .replaceAll(
      RegExp(
        r'(?:display\s*:\s*none|visibility\s*:\s*hidden|content-visibility\s*:\s*hidden|opacity\s*:\s*0(?:\.0*)?)(?:\s*!important)?\s*;?',
        caseSensitive: false,
      ),
      '',
    );

void _rewriteEpubResourceUrls(
  dom.Document document,
  List<EpubResource> images, {
  required String? chapterHref,
  required String? Function(EpubResource resource)? resourceUrlFor,
}) {
  for (final element in document.querySelectorAll('img, image')) {
    final attribute = _imageSourceAttribute(element);
    if (attribute == null) continue;
    final source = element.attributes[attribute];
    if (source == null || _isExternalResource(source)) continue;
    final resource = _findImage(images, source, chapterHref: chapterHref);
    if (resource == null) continue;
    final url = resourceUrlFor?.call(resource);
    element.attributes[attribute] =
        url ??
        'data:${_mimeType(resource.name)};base64,${base64Encode(resource.content)}';
  }
}

Object? _imageSourceAttribute(dom.Element element) {
  if (element.attributes.containsKey('src')) return 'src';
  if (element.attributes.containsKey('href')) return 'href';
  for (final attribute in element.attributes.keys) {
    if (attribute is dom.AttributeName &&
        attribute.prefix == 'xlink' &&
        attribute.name == 'href') {
      return attribute;
    }
  }
  return null;
}

String _preservedStylesheetLinks(
  dom.Document document,
  List<EpubResource> stylesheets,
  String? chapterHref,
  String? Function(EpubResource resource)? resourceUrlFor,
) {
  final links = <String>[];
  for (final link in document.querySelectorAll('link[rel]')) {
    final rel = link.attributes['rel']?.toLowerCase() ?? '';
    final href = link.attributes['href'];
    if (!rel.contains('stylesheet') ||
        href == null ||
        _isExternalResource(href)) {
      continue;
    }
    final normalized = _resolveEpubPath(href, chapterHref);
    final stylesheet = stylesheets
        .where((resource) => _normalizeEpubPath(resource.name) == normalized)
        .firstOrNull;
    if (stylesheet != null) {
      final localHref = resourceUrlFor?.call(stylesheet) ?? href;
      links.add(
        '<link rel="stylesheet" href="${_escapeHtmlAttribute(localHref)}">',
      );
    }
  }
  return links.join('\n  ');
}

EpubResource? _findImage(
  List<EpubResource> images,
  String source, {
  String? chapterHref,
}) {
  final resolved = _resolveEpubPath(source, chapterHref);
  for (final image in images) {
    if (_normalizeEpubPath(image.name) == resolved) return image;
  }
  final fileName = resolved.split('/').last.toLowerCase();
  for (final image in images) {
    final name = _normalizeEpubPath(image.name).toLowerCase();
    if (name.endsWith('/$fileName') || name == fileName) return image;
  }
  return null;
}

String _resolveEpubPath(String source, String? chapterHref) {
  final clean = _normalizeEpubPath(source);
  if (chapterHref == null || chapterHref.isEmpty || clean.startsWith('/')) {
    return clean.replaceFirst(RegExp(r'^/+'), '');
  }
  return _normalizeEpubPath(p.posix.join(p.posix.dirname(chapterHref), clean));
}

String _normalizeEpubPath(String value) {
  final beforeFragment = value
      .split('#')
      .first
      .split('?')
      .first
      .replaceAll('\\', '/');
  try {
    final decoded = Uri.decodeComponent(beforeFragment);
    return p.posix.normalize(decoded).replaceFirst(RegExp(r'^\./'), '');
  } catch (_) {
    return p.posix.normalize(beforeFragment).replaceFirst(RegExp(r'^\./'), '');
  }
}

String? _safeArchivePath(String value) {
  final normalized = _normalizeEpubPath(value);
  if (normalized.isEmpty ||
      normalized == '.' ||
      normalized.startsWith('../') ||
      normalized.contains('/../')) {
    return null;
  }
  return normalized;
}

String _relativeUrl(String target, String? from) {
  final base = from == null || from.isEmpty ? '.' : p.posix.dirname(from);
  final relative = p.posix.relative(target, from: base);
  return relative.split('/').map(Uri.encodeComponent).join('/');
}

String _resourceKey(EpubResource resource) =>
    _normalizeEpubPath(resource.name).toLowerCase();

String _documentHrefFromDocument(String document) {
  final match = RegExp(r'data-mangatan-reader-href="([^"]+)"')
      .firstMatch(document);
  return match?.group(1) ?? '';
}

bool _isExternalResource(String source) {
  final trimmed = source.trim().toLowerCase();
  return trimmed.startsWith('data:') ||
      trimmed.startsWith('http://') ||
      trimmed.startsWith('https://') ||
      trimmed.startsWith('javascript:') ||
      trimmed.startsWith('file:');
}

bool _sameLocalFile(Uri first, Uri second) {
  try {
    final firstPath = first.toFilePath(windows: Platform.isWindows);
    final secondPath = second.toFilePath(windows: Platform.isWindows);
    return p.equals(p.normalize(firstPath), p.normalize(secondPath));
  } catch (_) {
    return first.replace(query: '', fragment: '') ==
        second.replace(query: '', fragment: '');
  }
}

bool _sameReaderDocument(Uri first, Uri second) {
  if (first.scheme == 'file' && second.scheme == 'file') {
    return _sameLocalFile(first, second);
  }
  return first.scheme == second.scheme &&
      first.host == second.host &&
      first.port == second.port &&
      first.path == second.path;
}

String _escapeHtmlAttribute(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;');

double _javascriptNumber(Object? value, {double fallback = 0}) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}

bool _javascriptBool(Object? value) =>
    value == true || value?.toString().toLowerCase() == 'true';

bool? _javascriptNullableBool(Object? value) {
  if (value == true || value?.toString().toLowerCase() == 'true') return true;
  if (value == false || value?.toString().toLowerCase() == 'false') {
    return false;
  }
  return null;
}

Color _color(String value, Color fallback) {
  final normalized = value.trim().replaceFirst('#', '');
  final parsed = int.tryParse(
    normalized.length == 6 ? 'FF$normalized' : normalized,
    radix: 16,
  );
  return parsed == null ? fallback : Color(parsed);
}

String _safeCssColor(String value, String fallback) =>
    RegExp(r'^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$').hasMatch(value.trim())
    ? value.trim()
    : fallback;

String _mimeType(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.avif')) return 'image/avif';
  if (lower.endsWith('.heic')) return 'image/heic';
  if (lower.endsWith('.heif')) return 'image/heif';
  if (lower.endsWith('.jxl')) return 'image/jxl';
  if (lower.endsWith('.svg')) return 'image/svg+xml';
  return 'image/jpeg';
}
