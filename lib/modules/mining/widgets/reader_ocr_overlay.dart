import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/manga/reader/u_chap_data_preload.dart';
import 'package:mangayomi/modules/mining/reader_lookup_trigger.dart';
import 'package:mangayomi/modules/mining/widgets/dictionary_lookup_popup.dart';
import 'package:mangayomi/services/mining/dictionary_profile.dart';
import 'package:mangayomi/services/mining/dictionary_profile_resolver.dart';
import 'package:mangayomi/services/mining/generated_ocr.dart';
import 'package:mangayomi/services/mining/mining_models.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';
import 'package:mangayomi/services/mining/mokuro_extension_ocr.dart';
import 'package:mangayomi/services/mining/mokuro_parser.dart';
import 'package:mangayomi/services/mining/mokuro_sidecar.dart';
import 'package:mangayomi/services/mining/ocr_models.dart';
import 'package:mangayomi/services/mining/ocr_block_reading.dart';
import 'package:mangayomi/services/mining/profile_ocr_language.dart';
import 'package:mangayomi/utils/extensions/others.dart';
import 'package:mangayomi/utils/log/logger.dart';

class ReaderOcrState {
  ReaderOcrState._();

  static final enabled = ValueNotifier<bool>(true);
  static final boxOpacity = ValueNotifier<double>(
    MiningPreferences.defaultOcrBackgroundOpacity,
  );
  static final activeTextOpacity = ValueNotifier<double>(
    MiningPreferences.defaultOcrTextOpacity,
  );
  static final activeBackgroundOpacity = ValueNotifier<double>(
    MiningPreferences.defaultActiveOcrBackgroundOpacity,
  );
  static final outlineVisible = ValueNotifier<bool>(false);
  static final lookupOnHover = ValueNotifier<bool>(false);
  static final engine = ValueNotifier<OcrEnginePreference>(
    OcrEnginePreference.automatic,
  );
  static final scanTrigger = ValueNotifier<OcrScanTrigger>(
    OcrScanTrigger.automatic,
  );
  static final parallelOcrLimit = ValueNotifier<int>(1);
  static bool _initialized = false;
  static Future<void>? _initializing;
  static final Set<ReaderOcrController> _controllers = {};
  static final progress = ValueNotifier<ReaderOcrProgress?>(null);
  static DictionaryPopupHandle? _hoverPopup;
  static Timer? _hoverDismissTimer;
  static String? _hoverLookupKey;
  static bool _hoveringPopup = false;
  static int _hoverGeneration = 0;
  static int _scanGeneration = 0;
  static int _mokuroWebsiteLoads = 0;
  static bool _usingMokuroWebsiteData = false;
  static int _paintGeneration = 0;
  static bool _popupWasVisibleOnPointerDown = false;
  static Offset? _lastPointerPosition;
  static bool _middleLookupActive = false;
  static List<UChapDataPreload> _lastScanPages = const [];
  static int _lastStartIndex = 0;
  static Future<void> Function(UChapDataPreload)? _lastPreparePage;
  static String? _activeScanKey;
  static Future<void>? _activeScan;
  static String? _completedScanKey;

  static Future<void> initialize() async {
    if (_initialized) return;
    if (_initializing != null) return _initializing;
    _initializing = _loadPreferences();
    return _initializing;
  }

  static Future<void> _loadPreferences() async {
    try {
      final values = await Future.wait<dynamic>([
        MiningPreferences.getOcrOverlayEnabled(),
        MiningPreferences.getOcrBoxOpacity(),
        MiningPreferences.getOcrTextOpacity(),
        MiningPreferences.getActiveOcrBackgroundOpacity(),
        MiningPreferences.getOcrOutlineVisible(),
        MiningPreferences.getOcrLookupOnHover(),
        MiningPreferences.getOcrEngine(),
        MiningPreferences.getParallelOcrLimit(),
        MiningPreferences.getOcrScanTrigger(),
        ReaderLookupTriggerState.initialize(),
      ]);
      enabled.value = values[0] as bool;
      boxOpacity.value = values[1] as double;
      activeTextOpacity.value = values[2] as double;
      activeBackgroundOpacity.value = values[3] as double;
      outlineVisible.value = values[4] as bool;
      lookupOnHover.value = values[5] as bool;
      engine.value = values[6] as OcrEnginePreference;
      parallelOcrLimit.value = values[7] as int;
      scanTrigger.value = values[8] as OcrScanTrigger;
      _initialized = true;
    } finally {
      _initializing = null;
    }
  }

  static Future<void> setEnabled(bool value) async {
    // Like the other setters, let the stored preferences load first so they
    // cannot overwrite this change when they arrive.
    await initialize();
    enabled.value = value;
    await MiningPreferences.setOcrOverlayEnabled(value);
    if (!value) {
      _dismissHoverPopup();
      cancelScan(clearLast: false);
    } else if (_lastScanPages.isNotEmpty) {
      unawaited(
        scanChapter(
          _lastScanPages,
          startIndex: _lastStartIndex,
          preparePage: _lastPreparePage,
        ),
      );
    }
  }

  static Future<void> toggle() async {
    await initialize();
    await setEnabled(!enabled.value);
  }

  /// Handles a tap on the reader's OCR toolbar button, honoring the configured
  /// [scanTrigger]. In automatic mode it toggles the overlay; in manual mode it
  /// reveals the overlay if needed and scans the current page on demand
  /// (issue #35).
  static Future<void> handleOcrButton() async {
    await initialize();
    switch (readerOcrButtonAction(
      trigger: scanTrigger.value,
      enabled: enabled.value,
    )) {
      case ReaderOcrButtonAction.toggleOverlay:
        await toggle();
      case ReaderOcrButtonAction.enableAndScan:
        await setEnabled(true);
        await scanCurrentPageManually();
      case ReaderOcrButtonAction.scan:
        await scanCurrentPageManually();
    }
  }

  static Future<void> setBoxOpacity(double value) async {
    await initialize();
    final clamped = value.clamp(0.0, 1.0).toDouble();
    boxOpacity.value = clamped;
    await MiningPreferences.setOcrBoxOpacity(clamped);
  }

  static Future<void> setActiveTextOpacity(double value) async {
    await initialize();
    final clamped = value.clamp(0.0, 1.0).toDouble();
    activeTextOpacity.value = clamped;
    await MiningPreferences.setOcrTextOpacity(clamped);
  }

  static Future<void> setActiveBackgroundOpacity(double value) async {
    await initialize();
    final clamped = value.clamp(0.0, 1.0).toDouble();
    activeBackgroundOpacity.value = clamped;
    await MiningPreferences.setActiveOcrBackgroundOpacity(clamped);
  }

  static Future<void> setOutlineVisible(bool value) async {
    await initialize();
    outlineVisible.value = value;
    await MiningPreferences.setOcrOutlineVisible(value);
  }

  static Future<void> setLookupOnHover(bool value) async {
    await initialize();
    lookupOnHover.value = value;
    await MiningPreferences.setOcrLookupOnHover(value);
    if (!value) _dismissHoverPopup();
  }

  static Future<void> setEngine(OcrEnginePreference value) async {
    await initialize();
    if (engine.value == value) return;
    engine.value = value;
    await MiningPreferences.setOcrEngine(value);
    _completedScanKey = null;
    cancelScan(clearLast: false);
    for (final controller in _controllers.toList()) {
      controller._resetPage();
    }
    if (enabled.value && _lastScanPages.isNotEmpty) {
      unawaited(
        scanChapter(
          _lastScanPages,
          startIndex: _lastStartIndex,
          preparePage: _lastPreparePage,
        ),
      );
    }
  }

  static Future<void> setParallelOcrLimit(int value) async {
    await initialize();
    final clamped = value.clamp(1, 4);
    parallelOcrLimit.value = clamped;
    await MiningPreferences.setParallelOcrLimit(clamped);
  }

  static Future<void> setScanTrigger(OcrScanTrigger value) async {
    await initialize();
    if (scanTrigger.value == value) return;
    scanTrigger.value = value;
    await MiningPreferences.setOcrScanTrigger(value);
    // Switching back to automatic scans any pending chapter immediately;
    // switching to manual leaves already-scanned pages untouched and simply
    // stops future background scans.
    if (value == OcrScanTrigger.automatic &&
        enabled.value &&
        _lastScanPages.isNotEmpty) {
      unawaited(
        scanChapter(
          _lastScanPages,
          startIndex: _lastStartIndex,
          preparePage: _lastPreparePage,
        ),
      );
    }
  }

  static bool handlePointerUp(Offset globalPosition) {
    final popupWasVisible = _popupWasVisibleOnPointerDown;
    _popupWasVisibleOnPointerDown = false;
    if (!enabled.value) return false;
    if (dismissActiveLookupAt(globalPosition)) return true;
    if (!lookupOnHover.value && _heldLookupActive) {
      unawaited(handleHover(globalPosition));
      return true;
    }
    if (lookupOnHover.value) {
      if (!popupWasVisible) return false;
      _dismissHoverPopup();
      clearActive();
      return true;
    }
    final hit = _bestGlobalHit(globalPosition);
    if (hit == null) {
      clearActive();
      final dismissedPopup = DictionaryLookupPopup.dismissActive();
      return readerOcrShouldConsumeMissedTap(
        popupWasVisibleOnPointerDown: popupWasVisible,
        dismissedPopup: dismissedPopup,
      );
    }
    _activateGlobalHit(hit);
    unawaited(hit.controller._activateHit(hit.context, hit.tapHit));
    return true;
  }

  /// Dismisses the popup only when [globalPosition] is the active OCR hit.
  static bool dismissActiveLookupAt(Offset globalPosition) {
    if (!enabled.value) return false;
    final hit = _bestGlobalHit(globalPosition);
    if (hit == null ||
        !readerOcrShouldDismissRepeatedLookup(
          popupVisible: DictionaryLookupPopup.isActive,
          triggeredByHover: false,
          sameBlock: identical(hit.controller._activeBlock, hit.tapHit.block),
          activeOffset: hit.controller._activeOffset,
          hitOffset: hit.tapHit.rawOffset,
        )) {
      return false;
    }
    return dismissActiveLookup();
  }

  /// Dismisses the active reader lookup without changing the scan trigger.
  static bool dismissActiveLookup() {
    if (!DictionaryLookupPopup.isActive) return false;
    _dismissHoverPopup();
    clearActive();
    return true;
  }

  static void handlePointerDown(Offset globalPosition) {
    _lastPointerPosition = globalPosition;
    _popupWasVisibleOnPointerDown = DictionaryLookupPopup.isActive;
  }

  static void handlePointerCancel() {
    _popupWasVisibleOnPointerDown = false;
    _middleLookupActive = false;
  }

  static bool handleMiddleLookupStart(Offset globalPosition, int buttons) {
    if (!enabled.value ||
        buttons != kMiddleMouseButton ||
        lookupOnHover.value ||
        ReaderLookupTriggerState.trigger.value !=
            DictionaryLookupTrigger.middleClick) {
      return false;
    }
    _middleLookupActive = true;
    _lastPointerPosition = globalPosition;
    unawaited(handleHover(globalPosition));
    return true;
  }

  static void handleMiddleLookupMove(Offset globalPosition) {
    if (!_middleLookupActive) return;
    unawaited(handleHover(globalPosition));
  }

  static void handleMiddleLookupEnd() {
    _middleLookupActive = false;
  }

  static Future<bool> handleHover(Offset globalPosition) async {
    _lastPointerPosition = globalPosition;
    if (!enabled.value) return false;
    final hoverLookupActive = _hoverLookupActive;
    final hit = _bestGlobalHit(globalPosition);
    if (hit == null) {
      if (_heldLookupActive) {
        _dismissHoverPopup();
        clearActive();
      } else if (hoverLookupActive) {
        _scheduleHoverDismiss();
      } else {
        clearActive();
      }
      return false;
    }
    _activateGlobalHit(hit);
    if (!hoverLookupActive) {
      hit.controller._revealHit(hit.tapHit);
      hit.controller._prefetchHit(hit.tapHit);
      return true;
    }
    _hoverDismissTimer?.cancel();
    return hit.controller._activateHit(
      hit.context,
      hit.tapHit,
      triggeredByHover: true,
    );
  }

  static void handleHoverExit() {
    _lastPointerPosition = null;
    if (_hoverLookupActive) {
      _scheduleHoverDismiss();
    } else {
      clearActive();
    }
  }

  static bool handleLookupTriggerKey(KeyEvent event) {
    if (!readerLookupTriggerMatchesKey(
      ReaderLookupTriggerState.trigger.value,
      event,
    )) {
      return false;
    }
    if (event is KeyUpEvent) {
      return true;
    }
    if (!enabled.value || lookupOnHover.value) return false;
    final position = _lastPointerPosition;
    if (position != null) {
      unawaited(handleHover(position));
    } else {
      _dismissHoverPopup();
      clearActive();
    }
    return true;
  }

  static bool get _heldLookupActive {
    return _middleLookupActive ||
        (ReaderLookupTriggerState.trigger.value ==
                DictionaryLookupTrigger.shift &&
            HardwareKeyboard.instance.isShiftPressed);
  }

  static bool get _hoverLookupActive {
    return lookupOnHover.value || _heldLookupActive;
  }

  static _GlobalOcrHit? _bestGlobalHit(Offset globalPosition) {
    final hits = <_GlobalOcrHit>[];
    for (final controller in _controllers.toList()) {
      final hit = controller._hitTestGlobal(globalPosition);
      if (hit != null) hits.add(hit);
    }
    if (hits.isEmpty) return null;
    hits.sort((a, b) {
      final areaCompare = a.globalBlockRectArea.compareTo(
        b.globalBlockRectArea,
      );
      if (areaCompare != 0) return areaCompare;
      return b.controller._paintOrder.compareTo(a.controller._paintOrder);
    });
    return hits.first;
  }

  static void _activateGlobalHit(_GlobalOcrHit hit) {
    for (final controller in _controllers.toList()) {
      if (!identical(controller, hit.controller)) {
        controller._clearActive();
      }
    }
  }

  static int? _beginHoverLookup(String key) {
    if (_hoverLookupKey == key) return null;
    _hoverLookupKey = key;
    _hoverDismissTimer?.cancel();
    return ++_hoverGeneration;
  }

  static bool _isCurrentHoverLookup(int generation, String key) {
    return _hoverGeneration == generation && _hoverLookupKey == key;
  }

  static void _setHoverPopup(
    DictionaryPopupHandle? handle,
    int generation,
    String key,
  ) {
    if (!_isCurrentHoverLookup(generation, key)) {
      handle?.dismiss();
      return;
    }
    _hoverPopup = handle;
  }

  static void _setHoveringPopup(bool value) {
    _hoveringPopup = value;
    if (value) {
      _hoverDismissTimer?.cancel();
    } else {
      _scheduleHoverDismiss();
    }
  }

  static void _scheduleHoverDismiss() {
    _hoverDismissTimer?.cancel();
    _hoverDismissTimer = Timer(const Duration(milliseconds: 250), () {
      if (_hoveringPopup) return;
      _dismissHoverPopup();
      clearActive();
    });
  }

  static void _dismissHoverPopup() {
    _hoverDismissTimer?.cancel();
    _hoverDismissTimer = null;
    _hoverLookupKey = null;
    _hoverGeneration++;
    _hoveringPopup = false;
    _hoverPopup?.dismiss();
    _hoverPopup = null;
    // The stored handle can be stale or not assigned yet while lookup results
    // are loading. Dismiss the shared host as well to cancel those requests.
    DictionaryLookupPopup.dismissActive();
  }

  static void clearActive() {
    for (final controller in _controllers.toList()) {
      controller._clearActive();
    }
  }

  static Future<void> scanChapter(
    List<UChapDataPreload> pages, {
    int startIndex = 0,
    Future<void> Function(UChapDataPreload)? preparePage,
    bool manual = false,
  }) async {
    _lastScanPages = pages;
    _lastStartIndex = startIndex;
    _lastPreparePage = preparePage;
    await initialize();
    if (!enabled.value) return;
    // Manual trigger mode keeps OCR idle until the reader explicitly requests a
    // scan, so it does not run constantly in the background (issue #35). The
    // pending pages are still recorded above so a later manual request can scan
    // them.
    if (!readerOcrShouldAutoScan(
      trigger: scanTrigger.value,
      manualRequest: manual,
    )) {
      return;
    }
    final scanPages = pages.where((page) => !page.isTransitionPage).toList();
    if (scanPages.isEmpty) return;
    final scanKey = readerOcrChapterScanKey(scanPages);
    final activeScan = _activeScan;
    if (!readerOcrShouldStartChapterScan(
      scanKey: scanKey,
      activeScanKey: _activeScanKey,
      completedScanKey: _completedScanKey,
    )) {
      if (activeScan != null && _activeScanKey == scanKey) {
        return activeScan;
      }
      return;
    }
    final generation = ++_scanGeneration;
    _usingMokuroWebsiteData = false;
    final start = startIndex.clamp(0, scanPages.length - 1);
    final ordered = [
      ...scanPages.sublist(start),
      ...scanPages.sublist(0, start),
    ];
    late final Future<void> scan;
    scan =
        _runChapterScan(
          ordered,
          generation: generation,
          scanKey: scanKey,
          preparePage: preparePage,
        ).whenComplete(() {
          if (identical(_activeScan, scan)) {
            _activeScan = null;
            _activeScanKey = null;
          }
        });
    _activeScanKey = scanKey;
    _activeScan = scan;
    return scan;
  }

  /// Runs OCR for the current page in response to an explicit user request.
  ///
  /// Used by the manual OCR trigger (issue #35): when [scanTrigger] is
  /// [OcrScanTrigger.manual] the reader does not auto-scan, so tapping the OCR
  /// button scans only the page currently shown — not the whole chapter — so
  /// OCR runs on demand for the current page instead of constantly in the
  /// background. Does nothing when no chapter has been opened yet, the overlay
  /// is disabled, or the current page has no scannable content.
  static Future<void> scanCurrentPageManually() async {
    await initialize();
    if (!enabled.value || _lastScanPages.isEmpty) return;
    final page = readerOcrCurrentScanPage(
      _lastScanPages,
      startIndex: _lastStartIndex,
    );
    if (page == null) return;
    // Allow the current page to be scanned again even if it was already marked
    // complete or is being tracked as active from a previous request.
    _completedScanKey = null;
    return scanChapter([page], preparePage: _lastPreparePage, manual: true);
  }

  static Future<void> _runChapterScan(
    List<UChapDataPreload> ordered, {
    required int generation,
    required String scanKey,
    Future<void> Function(UChapDataPreload)? preparePage,
  }) async {
    progress.value = _scanProgress(completed: 0, total: ordered.length);
    final batchSize = parallelOcrLimit.value.clamp(1, 4);
    for (var index = 0; index < ordered.length; index += batchSize) {
      if (generation != _scanGeneration || !enabled.value) return;
      final end = math.min(index + batchSize, ordered.length);
      await Future.wait(
        ordered.sublist(index, end).map((page) async {
          try {
            await preparePage?.call(page);
            await ReaderOcrController._preload(page);
          } catch (error) {
            AppLogger.log(
              'Reader OCR page ${page.pageIndex} failed: $error',
              logLevel: LogLevel.warning,
            );
          }
        }),
      );
      if (generation == _scanGeneration) {
        progress.value = _scanProgress(completed: end, total: ordered.length);
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (generation == _scanGeneration) {
      _completedScanKey = scanKey;
      progress.value = null;
    }
  }

  /// Preloads OCR for multiple chapter page lists using the same cache as the
  /// reader. Chapters are processed concurrently up to the configured limit,
  /// while pages within each chapter remain ordered to avoid request bursts.
  static Future<void> preOcrChapters(
    List<List<UChapDataPreload>> chapters, {
    void Function(int chapterIndex, int completed, int total)?
    onChapterProgress,
  }) async {
    await initialize();
    final queues = chapters
        .map(
          (pages) => pages
              .where((page) => !page.isTransitionPage)
              .toList(growable: false),
        )
        .where((pages) => pages.isNotEmpty)
        .toList(growable: false);
    if (queues.isEmpty) return;
    final generation = ++_scanGeneration;
    _activeScan = null;
    _activeScanKey = null;
    _usingMokuroWebsiteData = false;
    final total = queues.fold<int>(0, (sum, pages) => sum + pages.length);
    var completed = 0;
    var nextChapter = 0;
    var failedPages = 0;
    progress.value = _scanProgress(completed: 0, total: total);

    Future<void> worker() async {
      while (generation == _scanGeneration) {
        final chapterIndex = nextChapter++;
        if (chapterIndex >= queues.length) return;
        final chapterPages = queues[chapterIndex];
        var chapterCompleted = 0;
        for (final page in chapterPages) {
          if (generation != _scanGeneration) return;
          try {
            await ReaderOcrController._preload(page);
          } catch (error) {
            failedPages++;
            AppLogger.log(
              'Pre-OCR page ${page.pageIndex} failed: $error',
              logLevel: LogLevel.warning,
            );
          }
          if (generation == _scanGeneration) {
            completed++;
            chapterCompleted++;
            progress.value = _scanProgress(completed: completed, total: total);
            onChapterProgress?.call(
              chapterIndex,
              chapterCompleted,
              chapterPages.length,
            );
          }
        }
      }
    }

    final workerCount = math.min(parallelOcrLimit.value, queues.length);
    await Future.wait(List.generate(workerCount, (_) => worker()));
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (generation == _scanGeneration) progress.value = null;
    final unprocessedPages = math.max(0, total - completed);
    final totalFailures = failedPages + unprocessedPages;
    if (totalFailures > 0) {
      throw OcrPreloadException(failedPages: totalFailures, totalPages: total);
    }
  }

  static void cancelScan({bool clearLast = true}) {
    _scanGeneration++;
    progress.value = null;
    _activeScan = null;
    _activeScanKey = null;
    if (clearLast) {
      _lastScanPages = const [];
      _lastPreparePage = null;
      _completedScanKey = null;
    }
  }

  static ReaderOcrProgress _scanProgress({
    required int completed,
    required int total,
  }) => ReaderOcrProgress(
    completed: completed,
    total: total,
    stage: _progressStage,
  );

  static ReaderOcrProgressStage get _progressStage {
    if (_mokuroWebsiteLoads > 0) {
      return ReaderOcrProgressStage.loadingMokuro;
    }
    if (_usingMokuroWebsiteData) return ReaderOcrProgressStage.mokuro;
    return ReaderOcrProgressStage.recognizing;
  }

  static void _setMokuroWebsiteLoading(bool loading) {
    _mokuroWebsiteLoads = math.max(0, _mokuroWebsiteLoads + (loading ? 1 : -1));
    final current = progress.value;
    if (current == null) return;
    _refreshProgressStage();
  }

  static void _setUsingMokuroWebsiteData() {
    _usingMokuroWebsiteData = true;
    _refreshProgressStage();
  }

  static void _refreshProgressStage() {
    final stage = _progressStage;
    final current = progress.value;
    if (current == null) return;
    if (current.stage == stage) return;
    progress.value = ReaderOcrProgress(
      completed: current.completed,
      total: current.total,
      stage: stage,
    );
  }

  /// Recognized character count for [data], for reading statistics.
  ///
  /// This only consults the OCR cache: a page whose recognition has not
  /// finished contributes zero characters rather than blocking a page turn or
  /// triggering OCR the reader did not ask for. Chimahon behaves the same way
  /// (`getCachedOcrBlocks`), so an un-OCRed page counts time but no characters.
  static Future<int> cachedCharacterCount(UChapDataPreload data) async {
    for (final controller in _controllers) {
      if (!identical(controller.data, data)) continue;
      final page = controller._page;
      if (page == null) return 0;
      return page.blocks.fold<int>(0, (sum, block) => sum + block.text.length);
    }
    return 0;
  }
}

class OcrPreloadException implements Exception {
  const OcrPreloadException({
    required this.failedPages,
    required this.totalPages,
  });

  final int failedPages;
  final int totalPages;

  @override
  String toString() =>
      'OCR failed for $failedPages of $totalPages page${totalPages == 1 ? '' : 's'}';
}

@visibleForTesting
String readerOcrChapterScanKey(List<UChapDataPreload> pages) => jsonEncode([
  for (final page in pages)
    [
      page.chapter?.id,
      page.index,
      page.pageIndex,
      page.pageUrl?.url,
      page.directory?.path,
      page.localArtifactPath,
    ],
]);

@visibleForTesting
bool readerOcrShouldStartChapterScan({
  required String scanKey,
  String? activeScanKey,
  String? completedScanKey,
}) => activeScanKey != scanKey && completedScanKey != scanKey;

/// Decides whether a chapter OCR scan should run given the configured
/// [trigger] and whether this scan was explicitly [manualRequest]ed.
///
/// In [OcrScanTrigger.automatic] mode OCR always runs (the historical
/// behavior). In [OcrScanTrigger.manual] mode background scans are suppressed
/// so OCR does not run constantly; it runs only when the reader explicitly
/// requests it. See issue #35.
@visibleForTesting
bool readerOcrShouldAutoScan({
  required OcrScanTrigger trigger,
  required bool manualRequest,
}) => trigger == OcrScanTrigger.automatic || manualRequest;

/// What the reader's OCR toolbar button should do when tapped.
enum ReaderOcrButtonAction {
  /// Show or hide the OCR overlay (automatic trigger behavior).
  toggleOverlay,

  /// Reveal the overlay and immediately scan the current page (manual trigger,
  /// overlay currently hidden).
  enableAndScan,

  /// Scan the current page without changing overlay visibility (manual trigger,
  /// overlay already shown).
  scan,
}

/// Chooses the OCR toolbar button behavior for the current [trigger] and
/// overlay [enabled] state. In automatic mode the button keeps toggling the
/// overlay; in manual mode it launches OCR for the current page on demand so
/// OCR does not run constantly in the background (issue #35).
@visibleForTesting
ReaderOcrButtonAction readerOcrButtonAction({
  required OcrScanTrigger trigger,
  required bool enabled,
}) {
  if (trigger == OcrScanTrigger.automatic) {
    return ReaderOcrButtonAction.toggleOverlay;
  }
  return enabled
      ? ReaderOcrButtonAction.scan
      : ReaderOcrButtonAction.enableAndScan;
}

/// Selects the single page a manual OCR request should scan.
///
/// Issue #35 asks for on-click OCR of the *current page* rather than a
/// whole-chapter background scan, so a manual request must OCR exactly the page
/// the reader is currently showing (identified by [startIndex] within
/// [pages]). Transition pages carry no OCR content, so if the current page is a
/// transition page the nearest following real page (wrapping to earlier pages)
/// is chosen instead. Returns `null` when there is no scannable page.
@visibleForTesting
UChapDataPreload? readerOcrCurrentScanPage(
  List<UChapDataPreload> pages, {
  int startIndex = 0,
}) {
  if (pages.isEmpty) return null;
  final start = startIndex.clamp(0, pages.length - 1).toInt();
  for (var offset = 0; offset < pages.length; offset++) {
    final page = pages[(start + offset) % pages.length];
    if (!page.isTransitionPage) return page;
  }
  return null;
}

enum ReaderOcrProgressStage { recognizing, loadingMokuro, mokuro }

class ReaderOcrProgress {
  const ReaderOcrProgress({
    required this.completed,
    required this.total,
    this.stage = ReaderOcrProgressStage.recognizing,
  });
  final int completed;
  final int total;
  final ReaderOcrProgressStage stage;
}

class ReaderOcrProgressHud extends StatelessWidget {
  const ReaderOcrProgressHud({super.key, this.top = 12});

  final double top;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ReaderOcrProgress?>(
      valueListenable: ReaderOcrState.progress,
      builder: (context, progress, _) {
        if (progress == null) return const SizedBox.shrink();
        return AnimatedPositioned(
          top: top,
          right: 12,
          duration: const Duration(milliseconds: 300),
          curve: Curves.ease,
          child: Material(
            color: Theme.of(context).colorScheme.surface.withValues(alpha: .92),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(switch (progress.stage) {
                    ReaderOcrProgressStage.loadingMokuro => 'Loading Mokuro',
                    ReaderOcrProgressStage.mokuro =>
                      'Mokuro ${progress.completed}/${progress.total}',
                    ReaderOcrProgressStage.recognizing =>
                      'OCR ${progress.completed}/${progress.total}',
                  }),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class ReaderOcrController extends ChangeNotifier {
  ReaderOcrController(this.data, {required this.imageKey}) {
    ReaderOcrState.enabled.addListener(_enabledChanged);
    ReaderOcrState.boxOpacity.addListener(_appearanceChanged);
    ReaderOcrState.activeTextOpacity.addListener(_appearanceChanged);
    ReaderOcrState.activeBackgroundOpacity.addListener(_appearanceChanged);
    ReaderOcrState.outlineVisible.addListener(_appearanceChanged);
    ReaderOcrState._controllers.add(this);
    unawaited(ReaderOcrState.initialize());
  }

  // Most recently used OCR results, oldest first. Pages are small (text and
  // boxes), but a long session would otherwise keep every page it ever read.
  static final Map<String, Future<_ReaderOcrPage>> _cache = {};
  static const _maxCachedPages = 500;

  final UChapDataPreload data;
  final GlobalKey imageKey;
  _ReaderOcrPage? _page;
  Rect? _imageRect;
  List<_PaintedOcrBlock> _paintedBlocks = const [];
  OcrTextBlock? _activeBlock;
  int _activeOffset = -1;
  int _matchLength = 0;
  int _paintOrder = 0;
  Color _highlightColor = const Color(0xff8ab4f8);
  Color _outlineColor = const Color(0xff8ab4f8);
  bool _loading = false;
  bool _disposed = false;
  String? _prefetchedLookupKey;

  bool get enabled => ReaderOcrState.enabled.value;

  void _resetPage() {
    _page = null;
    _paintedBlocks = const [];
    _activeBlock = null;
    _activeOffset = -1;
    _prefetchedLookupKey = null;
    if (!_disposed) {
      notifyListeners();
      unawaited(load());
    }
  }

  void updateTheme(Color primary) {
    _highlightColor = primary;
    _outlineColor = primary;
  }

  Future<void> load() async {
    if (!enabled || _loading || _page != null || data.isTransitionPage) return;
    _loading = true;
    notifyListeners();
    try {
      final page = await _preload(data);
      if (!_disposed) {
        _page = page;
        notifyListeners();
      }
    } catch (error) {
      AppLogger.log('Reader OCR failed: $error', logLevel: LogLevel.warning);
    } finally {
      _loading = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  static Future<_ReaderOcrPage> _preload(UChapDataPreload data) async {
    final manga = data.chapter?.manga.value;
    final source = manga?.sourceId == null
        ? null
        : isar.sources.getSync(manga!.sourceId!);
    final sourceLanguage = DictionaryProfileResolver.sourceLanguageForSource(
      source,
      fallback: manga?.lang ?? '',
    );
    final values = await Future.wait<dynamic>([
      MiningPreferences.getOcrEngine(),
      MiningPreferences.getMokuroWebsiteOcrEnabled(),
      DictionaryProfileResolver.resolve(
        mangaId: manga?.id,
        sourceId: DictionaryProfileResolver.overrideIdForSource(source),
        sourceLanguage: sourceLanguage,
      ),
    ]);
    final engine = values[0] as OcrEnginePreference;
    final useMokuroWebsiteOcr = values[1] as bool;
    final profile = values[2] as DictionaryProfile;
    final sourceName = source?.name ?? manga?.source ?? '';
    final language = profileOcrLanguage(profile.languageCode);
    final ocrAllowed = isProfileOcrAllowed(
      sourceLanguage: sourceLanguage,
      profileLanguage: profile.languageCode,
    );
    final key =
        '${data.pageUrl?.url ?? data.directory?.path ?? ''}:'
        '${data.chapter?.id}:${data.index}:${data.pageIndex}:'
        '${engine.name}:$useMokuroWebsiteOcr:$sourceName:'
        '$language:$ocrAllowed';
    // Re-insert on every use so eviction drops the least recently read page.
    final pending =
        _cache.remove(key) ??
        _recognize(
          data,
          engine: engine,
          sourceName: sourceName,
          useMokuroWebsiteOcr: useMokuroWebsiteOcr,
          language: language,
          ocrAllowed: ocrAllowed,
        );
    _cache[key] = pending;
    while (_cache.length > _maxCachedPages) {
      _cache.remove(_cache.keys.first);
    }
    try {
      final page = await pending;
      if (page.usesMokuroWebsiteData) {
        ReaderOcrState._setUsingMokuroWebsiteData();
      }
      return page;
    } catch (_) {
      if (identical(_cache[key], pending)) _cache.remove(key);
      rethrow;
    }
  }

  void paint(
    Canvas canvas,
    Rect imageRect,
    ui.Image image,
    Paint paint, {
    Rect? hitTestImageRect,
  }) {
    final hitImageRect = hitTestImageRect ?? imageRect;
    _imageRect = hitImageRect;
    _paintOrder = ++ReaderOcrState._paintGeneration;
    final page = _page;
    if (!enabled || page == null) {
      _paintedBlocks = const [];
      return;
    }
    final paintedBlocks = <_PaintedOcrBlock>[];
    final boxOpacity = ReaderOcrState.boxOpacity.value;
    final activeTextOpacity = ReaderOcrState.activeTextOpacity.value;
    final activeBackgroundOpacity =
        ReaderOcrState.activeBackgroundOpacity.value;
    final outlineVisible = ReaderOcrState.outlineVisible.value;
    for (final block in page.blocks) {
      final rect = _blockRect(block, imageRect, page.boxScaleX, page.boxScaleY);
      if (rect.isEmpty) continue;
      final hitRect = _blockRect(
        block,
        hitImageRect,
        page.boxScaleX,
        page.boxScaleY,
      );
      final active = identical(block, _activeBlock);
      final lineBoxes = _lineBoxes(
        block,
        imageRect,
        page.boxScaleX,
        page.boxScaleY,
      );
      final hitLineBoxes = _lineBoxes(
        block,
        hitImageRect,
        page.boxScaleX,
        page.boxScaleY,
      );
      paintedBlocks.add(
        _PaintedOcrBlock(block: block, rect: hitRect, lineBoxes: hitLineBoxes),
      );
      if (lineBoxes.isEmpty) {
        _paintOcrBox(
          canvas: canvas,
          rect: rect,
          text: orderedBlockSentence(block),
          vertical: block.vertical,
          active: active,
          boxOpacity: boxOpacity,
          activeTextOpacity: activeTextOpacity,
          activeBackgroundOpacity: activeBackgroundOpacity,
          highlight: active
              ? _lineHighlightFor(
                  lineStart: 0,
                  lineLength: orderedBlockSentence(block).length,
                  rect: rect,
                  vertical: block.vertical,
                )
              : null,
        );
        if (outlineVisible) {
          _paintOcrOutline(canvas, rect, active: active);
        }
        continue;
      }

      var lineStart = 0;
      for (final lineBox in lineBoxes) {
        final lineLength = lineBox.text.length;
        _paintOcrBox(
          canvas: canvas,
          rect: lineBox.rect,
          text: lineBox.text,
          vertical: lineBox.vertical,
          active: active,
          boxOpacity: boxOpacity,
          activeTextOpacity: activeTextOpacity,
          activeBackgroundOpacity: activeBackgroundOpacity,
          rotation: lineBox.rotation,
          highlight: active
              ? _lineHighlightFor(
                  lineStart: lineStart,
                  lineLength: lineLength,
                  rect: lineBox.rect,
                  vertical: lineBox.vertical,
                )
              : null,
        );
        lineStart += lineLength;
      }
      if (outlineVisible) {
        _paintOcrOutline(canvas, rect, active: active);
      }
    }
    _paintedBlocks = paintedBlocks;
  }

  Future<bool> handleTap(BuildContext context, Offset localPosition) async {
    final hit = _hitTestLocal(localPosition);
    if (hit == null) return false;
    return _activateHit(context, hit);
  }

  Future<bool> handleGlobalTap(Offset globalPosition) async {
    final hit = _hitTestGlobal(globalPosition);
    if (hit == null) return false;
    return _activateHit(hit.context, hit.tapHit);
  }

  _OcrTapHit? _hitTestLocal(Offset localPosition) {
    final imageRect = _imageRect;
    if (!enabled || imageRect == null || imageRect.isEmpty) return null;
    final hitSlop = _hitSlopFor(imageRect);
    if (!imageRect.inflate(hitSlop).contains(localPosition)) return null;
    for (final painted in _paintedBlocks.reversed) {
      final hit = _hitTestPaintedBlock(
        painted,
        localPosition,
        blockRect: painted.rect,
        hitSlop: 0,
      );
      if (hit != null) return hit;
    }
    return null;
  }

  _GlobalOcrHit? _hitTestGlobal(Offset globalPosition) {
    final context = imageKey.currentContext;
    final box = context?.findRenderObject() as RenderBox?;
    final imageRect = _imageRect;
    if (!enabled ||
        context == null ||
        box == null ||
        !box.attached ||
        !box.hasSize ||
        imageRect == null ||
        imageRect.isEmpty) {
      return null;
    }

    final imageGlobalRect = _localRectToGlobal(box, imageRect);
    final hitSlop = _hitSlopFor(imageGlobalRect);
    if (!imageGlobalRect.inflate(hitSlop).contains(globalPosition)) {
      return null;
    }

    // Route taps through the same painted rectangles users see. In double-page
    // and zoomed layouts, recomputing a separate local hit region can drift.
    for (final painted in _paintedBlocks.reversed) {
      final blockGlobalRect = _localRectToGlobal(box, painted.rect);
      final hit = _hitTestPaintedBlock(
        painted,
        globalPosition,
        blockRect: blockGlobalRect,
        blockRectIsGlobal: true,
        lineRectMapper: (rect) => _localRectToGlobal(box, rect),
        hitSlop: 0,
      );
      if (hit != null) {
        return _GlobalOcrHit(
          controller: this,
          context: context,
          tapHit: hit,
          globalBlockRect: blockGlobalRect,
        );
      }
    }
    return null;
  }

  _OcrTapHit? _hitTestPaintedBlock(
    _PaintedOcrBlock painted,
    Offset position, {
    required Rect blockRect,
    bool blockRectIsGlobal = false,
    Rect Function(Rect rect)? lineRectMapper,
    required double hitSlop,
  }) {
    var lineStart = 0;
    for (final lineBox in painted.lineBoxes) {
      final lineRect = lineRectMapper?.call(lineBox.rect) ?? lineBox.rect;
      if (lineRect.inflate(hitSlop).contains(position)) {
        final rawOffset = _characterOffsetForLine(
          lineBox,
          position - lineRect.topLeft,
          lineRect.size,
          lineStart,
        );
        return _OcrTapHit(
          block: painted.block,
          rawOffset: rawOffset,
          blockRect: blockRect,
          blockRectIsGlobal: blockRectIsGlobal,
          vertical: lineBox.vertical,
        );
      }
      lineStart += lineBox.text.length;
    }

    if (!blockRect.inflate(hitSlop).contains(position)) return null;
    return _OcrTapHit(
      block: painted.block,
      rawOffset: _characterOffset(
        painted.block,
        position - blockRect.topLeft,
        blockRect.size,
      ),
      blockRect: blockRect,
      blockRectIsGlobal: blockRectIsGlobal,
      vertical: painted.block.vertical,
    );
  }

  void _revealHit(_OcrTapHit hit) {
    if (identical(_activeBlock, hit.block)) return;
    _activeBlock = hit.block;
    _activeOffset = -1;
    _matchLength = 0;
    notifyListeners();
  }

  void _prefetchHit(_OcrTapHit hit) {
    final ordered = orderedBlockSentence(hit.block);
    if (ordered.isEmpty) return;
    final orderedOffset = toOrderedOffset(
      hit.block,
      hit.rawOffset,
    ).clamp(0, ordered.length - 1);
    if (!_isLookupStartChar(ordered[orderedOffset])) return;
    final lookup = _extractOcrLookupString(ordered, orderedOffset);
    if (lookup.isEmpty) return;
    final key = '${identityHashCode(hit.block)}:$orderedOffset:$lookup';
    if (_prefetchedLookupKey == key) return;
    _prefetchedLookupKey = key;
    unawaited(
      DictionaryLookupPopup.lookup(
        lookup,
        miningContext: Future.value(_miningContext(ordered)),
      ).then<void>(
        (_) {},
        onError: (_) {
          if (_prefetchedLookupKey == key) _prefetchedLookupKey = null;
        },
      ),
    );
  }

  MiningContext _miningContext(String sentence) {
    final manga = data.chapter?.manga.value;
    final source = manga?.sourceId == null
        ? null
        : isar.sources.getSync(manga!.sourceId!);
    return MiningContext(
      mediaType: MiningMediaType.manga,
      mangaId: manga?.id,
      sourceId: DictionaryProfileResolver.overrideIdForSource(source),
      sourceLanguage: DictionaryProfileResolver.sourceLanguageForSource(
        source,
        fallback: manga?.lang ?? '',
      ),
      sourceTitle: manga?.name ?? data.mangaName ?? '',
      chapterTitle: data.chapter?.name ?? '',
      sentence: sentence,
      pageIndex: data.pageIndex,
      sourceUri: Uri.tryParse(data.pageUrl?.url ?? ''),
      imageBytesLoader: () async => data.cropImage ?? await data.getImageBytes,
    );
  }

  int _characterOffsetForLine(
    _OcrLineBox lineBox,
    Offset local,
    Size size,
    int lineStart,
  ) {
    final line = lineBox.text;
    final char = lineBox.vertical
        ? (local.dy / math.max(1, size.height / math.max(1, line.length)))
              .floor()
              .clamp(0, math.max(0, line.length - 1))
        : (local.dx / math.max(1, size.width / math.max(1, line.length)))
              .floor()
              .clamp(0, math.max(0, line.length - 1));
    return lineStart + char.toInt();
  }

  Future<bool> _activateHit(
    BuildContext context,
    _OcrTapHit hit, {
    bool triggeredByHover = false,
  }) async {
    final block = hit.block;
    final rawOffset = hit.rawOffset;
    if (readerOcrShouldDismissRepeatedLookup(
      popupVisible: DictionaryLookupPopup.isActive,
      triggeredByHover: triggeredByHover,
      sameBlock: identical(_activeBlock, block),
      activeOffset: _activeOffset,
      hitOffset: rawOffset,
    )) {
      _clearActive();
      DictionaryLookupPopup.dismissActive();
      return true;
    }
    final ordered = orderedBlockSentence(block);
    if (ordered.isEmpty) return true;
    final orderedOffset = toOrderedOffset(
      block,
      rawOffset,
    ).clamp(0, ordered.length - 1);
    if (!_isLookupStartChar(ordered[orderedOffset])) {
      if (triggeredByHover) {
        ReaderOcrState._dismissHoverPopup();
      } else if (!ReaderOcrState.dismissActiveLookup()) {
        _activeBlock = block;
        _activeOffset = rawOffset;
        _matchLength = 0;
        notifyListeners();
      }
      return true;
    }
    final lookup = _extractOcrLookupString(ordered, orderedOffset);
    if (lookup.isEmpty) {
      if (triggeredByHover) {
        ReaderOcrState._dismissHoverPopup();
      } else {
        ReaderOcrState.dismissActiveLookup();
      }
      return true;
    }
    final hoverKey = triggeredByHover
        ? '${identityHashCode(this)}:${identityHashCode(block)}:'
              '$orderedOffset:$lookup'
        : null;
    final hoverGeneration = hoverKey == null
        ? null
        : ReaderOcrState._beginHoverLookup(hoverKey);
    if (triggeredByHover && hoverGeneration == null) return true;
    _activeBlock = block;
    _activeOffset = rawOffset;
    _matchLength = 0;
    notifyListeners();
    if (!context.mounted) {
      if (triggeredByHover) ReaderOcrState._dismissHoverPopup();
      return true;
    }

    final anchor = hit.blockRectIsGlobal
        ? hit.blockRect
        : _localAnchorFor(context, hit.blockRect);
    if (triggeredByHover &&
        !ReaderOcrState._isCurrentHoverLookup(hoverGeneration!, hoverKey!)) {
      return true;
    }
    final handle = await DictionaryLookupPopup.show(
      context: context,
      anchor: anchor,
      text: lookup,
      miningContext: _miningContext(ordered),
      placement: hit.vertical
          ? DictionaryPopupPlacement.leftOrRight
          : DictionaryPopupPlacement.aboveOrBelow,
      onMatchChanged: (length) {
        _matchLength = math.max(0, length);
        if (!_disposed) notifyListeners();
      },
      dismissOnOutsideTap: !triggeredByHover,
      onHoverChanged: triggeredByHover
          ? ReaderOcrState._setHoveringPopup
          : null,
    );
    if (triggeredByHover) {
      ReaderOcrState._setHoverPopup(handle, hoverGeneration!, hoverKey!);
    }
    return true;
  }

  Rect _localRectToGlobal(RenderBox box, Rect rect) {
    final points = [
      box.localToGlobal(rect.topLeft),
      box.localToGlobal(rect.topRight),
      box.localToGlobal(rect.bottomLeft),
      box.localToGlobal(rect.bottomRight),
    ];
    return Rect.fromLTRB(
      points.map((point) => point.dx).reduce(math.min),
      points.map((point) => point.dy).reduce(math.min),
      points.map((point) => point.dx).reduce(math.max),
      points.map((point) => point.dy).reduce(math.max),
    );
  }

  double _hitSlopFor(Rect rect) =>
      math.max(8.0, math.max(rect.width, rect.height) * 0.002);

  Rect _localAnchorFor(BuildContext context, Rect rect) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return rect;
    return _localRectToGlobal(box, rect);
  }

  void _enabledChanged() {
    if (enabled) load();
    if (!_disposed) notifyListeners();
  }

  void _appearanceChanged() {
    if (!_disposed) notifyListeners();
  }

  void _clearActive() {
    if (_activeBlock == null && _activeOffset < 0 && _matchLength == 0) {
      return;
    }
    _activeBlock = null;
    _activeOffset = -1;
    _matchLength = 0;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ReaderOcrState.enabled.removeListener(_enabledChanged);
    ReaderOcrState.boxOpacity.removeListener(_appearanceChanged);
    ReaderOcrState.activeTextOpacity.removeListener(_appearanceChanged);
    ReaderOcrState.activeBackgroundOpacity.removeListener(_appearanceChanged);
    ReaderOcrState.outlineVisible.removeListener(_appearanceChanged);
    ReaderOcrState._controllers.remove(this);
    super.dispose();
  }

  static Future<void> _backfillMokuroSidecar(
    UChapDataPreload data, {
    required String sourceName,
  }) async {
    final path = data.localArtifactPath;
    if (path == null || path.trim().isEmpty) return;
    final type = await FileSystemEntity.type(path);
    final FileSystemEntity? artifact = switch (type) {
      FileSystemEntityType.file => File(path),
      FileSystemEntityType.directory => Directory(path),
      _ => null,
    };
    if (artifact == null) return;

    final store = MokuroSidecarStore();
    try {
      await store.ensureDownloaded(
        sourceName: sourceName,
        chapterUrl: data.chapter?.url ?? '',
        artifact: artifact,
      );
    } finally {
      store.close();
    }
  }

  static Future<_ReaderOcrPage> _recognize(
    UChapDataPreload data, {
    required OcrEnginePreference engine,
    required String sourceName,
    required bool useMokuroWebsiteOcr,
    required String language,
    required bool ocrAllowed,
  }) async {
    final values = await Future.wait<dynamic>([
      MiningPreferences.getOcrBoxScaleX(),
      MiningPreferences.getOcrBoxScaleY(),
    ]);
    final boxScaleX = values[0] as double;
    final boxScaleY = values[1] as double;

    if (!ocrAllowed) {
      return _ReaderOcrPage(
        blocks: const [],
        boxScaleX: boxScaleX,
        boxScaleY: boxScaleY,
      );
    }

    const parser = MokuroParser();
    if (engine != OcrEnginePreference.googleLens &&
        engine != OcrEnginePreference.screenAi &&
        engine != OcrEnginePreference.appleVision) {
      final volume = await parser.findForReaderPage(data);
      final mokuroPage = volume == null
          ? null
          : parser.resolvePage(volume, data: data);
      if (mokuroPage != null) {
        final blocks = parser.convertPage(mokuroPage);
        if (blocks.isNotEmpty || engine == OcrEnginePreference.mokuroOnly) {
          return _ReaderOcrPage(
            blocks: blocks,
            boxScaleX: boxScaleX,
            boxScaleY: boxScaleY,
          );
        }
      }
    }

    if (useMokuroWebsiteOcr &&
        engine != OcrEnginePreference.googleLens &&
        engine != OcrEnginePreference.screenAi &&
        engine != OcrEnginePreference.appleVision) {
      final client = MokuroExtensionOcrClient();
      try {
        final volume = await client.fetchVolume(
          sourceName: sourceName,
          chapterUrl: data.chapter?.url ?? '',
          onLoadingChanged: ReaderOcrState._setMokuroWebsiteLoading,
        );
        if (volume != null) {
          await _backfillMokuroSidecar(data, sourceName: sourceName);
        }
        final mokuroPage = volume == null
            ? null
            : parser.resolvePage(volume, data: data);
        if (mokuroPage != null) {
          return _ReaderOcrPage(
            blocks: parser.convertPage(mokuroPage),
            boxScaleX: boxScaleX,
            boxScaleY: boxScaleY,
            usesMokuroWebsiteData: true,
          );
        }
      } finally {
        client.close();
      }
    }

    if (engine == OcrEnginePreference.mokuroOnly) {
      return _ReaderOcrPage(
        blocks: const [],
        boxScaleX: boxScaleX,
        boxScaleY: boxScaleY,
      );
    }

    Uint8List? bytes = data.cropImage ?? await data.getImageBytes;
    for (var retry = 0; bytes == null && retry < 3; retry++) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      bytes = data.cropImage ?? await data.getImageBytes;
    }
    if (bytes == null) throw StateError('Page image is not cached yet');
    final result = await recognizeGeneratedOcr(
      bytes,
      engine: engine,
      language: language,
    );
    return _ReaderOcrPage(
      blocks: result.blocks,
      boxScaleX: boxScaleX,
      boxScaleY: boxScaleY,
    );
  }

  Rect _blockRect(
    OcrTextBlock block,
    Rect imageRect,
    double scaleX,
    double scaleY,
  ) {
    return readerOcrScaledBlockRect(
      xmin: block.xmin,
      ymin: block.ymin,
      xmax: block.xmax,
      ymax: block.ymax,
      imageRect: imageRect,
      scaleX: scaleX,
      scaleY: scaleY,
    );
  }

  void _paintOcrBox({
    required Canvas canvas,
    required Rect rect,
    required String text,
    required bool vertical,
    required bool active,
    required double boxOpacity,
    required double activeTextOpacity,
    required double activeBackgroundOpacity,
    Rect? highlight,
    double rotation = 0,
  }) {
    if (text.isEmpty) return;
    final contentOpacity = readerOcrContentOpacities(
      boxOpacity: boxOpacity,
      activeTextOpacity: activeTextOpacity,
      activeBackgroundOpacity: activeBackgroundOpacity,
      active: active,
    );
    canvas.save();
    if (rotation.abs() > 0.01) {
      canvas.translate(rect.center.dx, rect.center.dy);
      canvas.rotate(rotation * math.pi / 180);
      canvas.translate(-rect.center.dx, -rect.center.dy);
    }
    if (contentOpacity.background > 0) {
      canvas.drawRect(
        rect,
        Paint()
          ..color = Colors.white.withValues(alpha: contentOpacity.background),
      );
    }
    // Lookup highlighting stays independent so 0% resembles native selection
    // drawn directly over the source image.
    if (highlight != null && !highlight.isEmpty) {
      canvas.drawRect(
        highlight.intersect(rect),
        Paint()..color = _highlightColor.withValues(alpha: 0.45),
      );
    }
    if (contentOpacity.text > 0) {
      if (vertical) {
        _paintVerticalText(canvas, rect, text, contentOpacity.text);
      } else {
        _paintHorizontalText(canvas, rect, text, contentOpacity.text);
      }
    }
    canvas.restore();
  }

  void _paintOcrOutline(Canvas canvas, Rect rect, {required bool active}) {
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 2 : 1.5
        ..color = _outlineColor.withValues(alpha: active ? 1.0 : 0.70),
    );
  }

  void _paintHorizontalText(
    Canvas canvas,
    Rect rect,
    String text,
    double alpha,
  ) {
    // Wrap the text to the box width instead of forcing a single line. A wide
    // or merged panel (issue #39) then keeps a readable font by wrapping rather
    // than shrinking the whole line to fit the box's aspect ratio.
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.black.withValues(alpha: alpha),
          fontSize: 20,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: math.max(1, rect.width));
    final scale = readerOcrHorizontalTextScale(
      rect: rect.size,
      wrappedTextSize: Size(painter.width, painter.height),
    );
    canvas.save();
    canvas.clipRect(rect);
    canvas.translate(
      rect.center.dx - painter.width * scale / 2,
      rect.center.dy - painter.height * scale / 2,
    );
    canvas.scale(scale);
    painter.paint(canvas, Offset.zero);
    canvas.restore();
  }

  void _paintVerticalText(Canvas canvas, Rect rect, String text, double alpha) {
    final rowHeight = rect.height / math.max(1, text.length);
    final fontSize = readerOcrVerticalFontSize(
      boxWidth: rect.width,
      boxHeight: rect.height,
      glyphCount: text.length,
    );
    canvas.save();
    canvas.clipRect(rect);
    for (var index = 0; index < text.length; index++) {
      final painter = TextPainter(
        maxLines: 1,
        text: TextSpan(
          text: text[index],
          style: TextStyle(
            color: Colors.black.withValues(alpha: alpha),
            fontSize: fontSize,
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout();
      painter.paint(
        canvas,
        Offset(
          rect.center.dx - painter.width / 2,
          rect.top + rowHeight * (index + 0.5) - painter.height / 2,
        ),
      );
    }
    canvas.restore();
  }

  Rect? _lineHighlightFor({
    required int lineStart,
    required int lineLength,
    required Rect rect,
    required bool vertical,
  }) {
    if (_matchLength <= 0 || _activeOffset < 0 || lineLength <= 0) {
      return null;
    }
    final start = _activeOffset;
    final end = _activeOffset + _matchLength;
    final lineEnd = lineStart + lineLength;
    if (start >= lineEnd || end <= lineStart) return null;
    final overlapStart = math.max(start, lineStart) - lineStart;
    final overlapEnd = math.min(end, lineEnd) - lineStart;
    if (vertical) {
      final cellHeight = rect.height / lineLength;
      return Rect.fromLTWH(
        rect.left,
        rect.top + overlapStart * cellHeight,
        rect.width,
        math.max(1, (overlapEnd - overlapStart) * cellHeight),
      );
    }
    final cellWidth = rect.width / lineLength;
    return Rect.fromLTWH(
      rect.left + overlapStart * cellWidth,
      rect.top,
      math.max(1, (overlapEnd - overlapStart) * cellWidth),
      rect.height,
    );
  }

  List<_OcrLineBox> _lineBoxes(
    OcrTextBlock block,
    Rect imageRect,
    double scaleX,
    double scaleY,
  ) {
    if (block.lineGeometries.length != block.lines.length) return const [];
    final boxes = <_OcrLineBox>[];
    for (var index = 0; index < block.lines.length; index++) {
      final line = block.lines[index];
      if (line.trim().isEmpty) continue;
      final geo = block.lineGeometries[index];
      final rect = _normalizedRect(
        imageRect,
        geo.xmin,
        geo.ymin,
        geo.xmax,
        geo.ymax,
        scaleX,
        scaleY,
      );
      if (rect.isEmpty) continue;
      boxes.add(
        _OcrLineBox(
          text: line,
          rect: rect,
          vertical: block.vertical || _looksVertical(geo),
          rotation: geo.rotation,
        ),
      );
    }
    return boxes;
  }

  Rect _normalizedRect(
    Rect imageRect,
    double xmin,
    double ymin,
    double xmax,
    double ymax,
    double scaleX,
    double scaleY,
  ) {
    final center = Offset(
      imageRect.left + (xmin + xmax) * imageRect.width / 2,
      imageRect.top + (ymin + ymax) * imageRect.height / 2,
    );
    final size = Size(
      (xmax - xmin) * imageRect.width * scaleX,
      (ymax - ymin) * imageRect.height * scaleY,
    );
    return Rect.fromCenter(
      center: center,
      width: size.width,
      height: size.height,
    ).intersect(imageRect);
  }
}

class _ReaderOcrPage {
  const _ReaderOcrPage({
    required this.blocks,
    required this.boxScaleX,
    required this.boxScaleY,
    this.usesMokuroWebsiteData = false,
  });

  final List<OcrTextBlock> blocks;
  final double boxScaleX;
  final double boxScaleY;
  final bool usesMokuroWebsiteData;
}

int _characterOffset(OcrTextBlock block, Offset local, Size size) {
  if (block.lines.isEmpty) return 0;
  if (block.vertical) {
    final column =
        ((size.width - local.dx) / math.max(1, size.width / block.lines.length))
            .floor()
            .clamp(0, block.lines.length - 1);
    final line = block.lines[column];
    final character =
        (local.dy / math.max(1, size.height / math.max(1, line.length)))
            .floor()
            .clamp(0, math.max(0, line.length - 1));
    return (block.lines
                .take(column)
                .fold<int>(0, (sum, value) => sum + value.length) +
            character)
        .toInt();
  }
  final row = (local.dy / math.max(1, size.height / block.lines.length))
      .floor()
      .clamp(0, block.lines.length - 1);
  final line = block.lines[row];
  final character =
      (local.dx / math.max(1, size.width / math.max(1, line.length)))
          .floor()
          .clamp(0, math.max(0, line.length - 1));
  return (block.lines
              .take(row)
              .fold<int>(0, (sum, value) => sum + value.length) +
          character)
      .toInt();
}

String _extractOcrLookupString(String text, int start) {
  final buffer = StringBuffer();
  for (var index = start; index < text.length && buffer.length < 80; index++) {
    if (!_isLookupStartChar(text[index])) break;
    buffer.write(text[index]);
  }
  return buffer.toString();
}

bool _isLookupStartChar(String char) {
  if (char.trim().isEmpty) return false;
  final code = char.runes.first;
  if ((code >= 0x21 && code <= 0x2f) ||
      (code >= 0x3a && code <= 0x40) ||
      (code >= 0x5b && code <= 0x60) ||
      (code >= 0x7b && code <= 0x7e)) {
    return false;
  }
  if ((code >= 0x3000 && code <= 0x303f) ||
      (code >= 0xff01 && code <= 0xff0f) ||
      (code >= 0xff1a && code <= 0xff20) ||
      (code >= 0xff3b && code <= 0xff40) ||
      (code >= 0xff5b && code <= 0xff65)) {
    return false;
  }
  return true;
}

bool _looksVertical(OcrLineGeometry geo) {
  final width = geo.xmax - geo.xmin;
  if (width <= 0) return false;
  return (geo.ymax - geo.ymin) / width > 1.2;
}

Rect readerOcrHitTestImageRect({
  required Rect paintedImageRect,
  required Size renderBoxSize,
  required bool normalizePaintCoordinates,
}) {
  if (!normalizePaintCoordinates) return paintedImageRect;
  return Alignment.center.inscribe(
    paintedImageRect.size,
    Offset.zero & renderBoxSize,
  );
}

@visibleForTesting
bool readerOcrShouldConsumeMissedTap({
  required bool popupWasVisibleOnPointerDown,
  required bool dismissedPopup,
}) => popupWasVisibleOnPointerDown || dismissedPopup;

@visibleForTesting
bool readerOcrShouldDismissRepeatedLookup({
  required bool popupVisible,
  required bool triggeredByHover,
  required bool sameBlock,
  required int activeOffset,
  required int hitOffset,
}) =>
    popupVisible && !triggeredByHover && sameBlock && activeOffset == hitOffset;

/// Chooses the paint scale for wrapped horizontal OCR text.
///
/// Regression guard for issue #39 ("Merged text becomes too small"). The text
/// is laid out wrapped to the box width by the caller, so a wide/large panel no
/// longer forces a single long line. This helper therefore only ever shrinks
/// the wrapped block when it still overflows the box, and never enlarges past
/// its natural size. Text that already fits renders at scale 1.0 instead of
/// being blown up or collapsed to fit the box's aspect ratio.
@visibleForTesting
double readerOcrHorizontalTextScale({
  required Size rect,
  required Size wrappedTextSize,
}) {
  final scale = math.min(
    rect.width / math.max(1, wrappedTextSize.width),
    rect.height / math.max(1, wrappedTextSize.height),
  );
  if (scale.isNaN || scale <= 0) return 1.0;
  return math.min(1.0, scale);
}

/// Font size for a vertical (top-to-bottom) OCR line so its glyph column
/// always fits inside its box.
///
/// Fixes issue #49: the previous implementation applied a hard `8.0` px floor
/// after fitting to the box, so on small boxes (common on mobile) the stacked
/// glyphs — `fontSize * glyphCount` — exceeded the box height and clipped off
/// the bottom characters. The size now tracks the smaller of the per-row height
/// and the box width and is clamped so the whole column stays inside the box in
/// both dimensions; a floor is only applied when it does not force overflow.
@visibleForTesting
double readerOcrVerticalFontSize({
  required double boxWidth,
  required double boxHeight,
  required int glyphCount,
}) {
  if (glyphCount <= 0 || boxWidth <= 0 || boxHeight <= 0) return 0.0;
  final rowHeight = boxHeight / glyphCount;
  // Track the tighter of the two axes: a glyph must fit both the per-character
  // row height and the box width.
  var fontSize = math.min(boxWidth * 0.95, rowHeight * 0.95);
  // Only raise toward a comfortable minimum when doing so still keeps the whole
  // column inside the box; never let the floor reintroduce clipping.
  const desiredMin = 8.0;
  final maxFit = math.min(rowHeight, boxWidth);
  if (fontSize < desiredMin) {
    fontSize = math.min(desiredMin, maxFit);
  }
  return fontSize;
}

@visibleForTesting
({double background, double text}) readerOcrContentOpacities({
  required double boxOpacity,
  double activeTextOpacity = 1.0,
  double activeBackgroundOpacity = 0.7,
  required bool active,
}) {
  final opacity = boxOpacity.clamp(0.0, 1.0).toDouble();
  if (active) {
    return (
      background: activeBackgroundOpacity.clamp(0.0, 1.0).toDouble(),
      text: activeTextOpacity.clamp(0.0, 1.0).toDouble(),
    );
  }
  // Passive OCR is a hit target, not a permanent replacement for the page
  // artwork. Coupling its text to the passive box opacity keeps both hidden at
  // the default 0% until the user activates a block. Active blocks use their
  // independent appearance settings above.
  return (background: opacity, text: opacity);
}

/// Maps a block's normalized OCR coordinates onto [imageRect], scaling the box
/// about its center by [scaleX]/[scaleY] before clamping it to the image.
///
/// Enlarging the box (scale > 1) is how the reader gives clipped OCR text more
/// room so a larger fitted font no longer overflows the bubble (issue #26);
/// the result is intersected with [imageRect] so an enlarged box never spills
/// past the page edges.
@visibleForTesting
Rect readerOcrScaledBlockRect({
  required double xmin,
  required double ymin,
  required double xmax,
  required double ymax,
  required Rect imageRect,
  required double scaleX,
  required double scaleY,
}) {
  final center = Offset(
    imageRect.left + (xmin + xmax) * imageRect.width / 2,
    imageRect.top + (ymin + ymax) * imageRect.height / 2,
  );
  final size = Size(
    (xmax - xmin) * imageRect.width * scaleX,
    (ymax - ymin) * imageRect.height * scaleY,
  );
  return Rect.fromCenter(
    center: center,
    width: size.width,
    height: size.height,
  ).intersect(imageRect);
}

class _OcrLineBox {
  const _OcrLineBox({
    required this.text,
    required this.rect,
    required this.vertical,
    required this.rotation,
  });

  final String text;
  final Rect rect;
  final bool vertical;
  final double rotation;
}

class _PaintedOcrBlock {
  const _PaintedOcrBlock({
    required this.block,
    required this.rect,
    required this.lineBoxes,
  });

  final OcrTextBlock block;
  final Rect rect;
  final List<_OcrLineBox> lineBoxes;
}

class _OcrTapHit {
  const _OcrTapHit({
    required this.block,
    required this.rawOffset,
    required this.blockRect,
    required this.vertical,
    this.blockRectIsGlobal = false,
  });

  final OcrTextBlock block;
  final int rawOffset;
  final Rect blockRect;
  final bool vertical;
  final bool blockRectIsGlobal;
}

class _GlobalOcrHit {
  const _GlobalOcrHit({
    required this.controller,
    required this.context,
    required this.tapHit,
    required this.globalBlockRect,
  });

  final ReaderOcrController controller;
  final BuildContext context;
  final _OcrTapHit tapHit;
  final Rect globalBlockRect;

  double get globalBlockRectArea =>
      globalBlockRect.width.abs() * globalBlockRect.height.abs();
}
