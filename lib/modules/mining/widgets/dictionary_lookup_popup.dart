import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mangayomi/eval/model/m_bridge.dart';
import 'package:mangayomi/modules/mining/widgets/dictionary_glossary.dart';
import 'package:mangayomi/modules/mining/widgets/hoshi_dictionary_popup.dart';
import 'package:mangayomi/services/hoshidicts/hoshidicts_backend.dart';
import 'package:mangayomi/services/mining/anki_card_builder.dart';
import 'package:mangayomi/services/mining/anki_connect_service.dart';
import 'package:mangayomi/services/mining/anki_mobile_service.dart';
import 'package:mangayomi/services/mining/dictionary_profile.dart';
import 'package:mangayomi/services/mining/dictionary_profile_resolver.dart';
import 'package:mangayomi/services/mining/mining_models.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';
import 'package:mangayomi/services/statistics/anki_stats_recorder.dart';
import 'package:mangayomi/src/rust/api/hoshidicts.dart';

class DictionaryPopupHandle {
  const DictionaryPopupHandle({required this.dismiss, required this.dismissed});

  final VoidCallback dismiss;
  final Future<void> dismissed;
}

@visibleForTesting
bool dictionaryPopupUsesNativeRenderer(TargetPlatform platform) =>
    platform == TargetPlatform.linux;

Widget _dictionaryPopupRenderer({
  Key? key,
  required String text,
  required FutureOr<MiningContext?> miningContext,
  required DictionaryProfile? profile,
  required Future<List<HoshiLookupResult>>? initialResults,
  required DictionaryPopupPreferences preferences,
  required ValueChanged<int> onMatchChanged,
  required VoidCallback onDismiss,
  HoshiDictionaryPopupController? controller,
  FutureOr<int> Function(HoshiDictionaryTextSelection selection)?
  onTextSelected,
  VoidCallback? onTapOutside,
}) {
  if (!dictionaryPopupUsesNativeRenderer(defaultTargetPlatform)) {
    return HoshiDictionaryPopup(
      key: key,
      controller: controller,
      text: text,
      profile: profile,
      miningContext: miningContext,
      initialResults: initialResults,
      preferences: preferences,
      onMatchChanged: onMatchChanged,
      onDismiss: onDismiss,
      onTextSelected: onTextSelected,
      onTapOutside: onTapOutside,
    );
  }

  Widget buildNative(MiningContext context) => DictionaryLookupResultsView(
    key: key,
    text: text,
    miningContext: context,
    profile: profile,
    initialResults: initialResults,
    preferences: preferences,
    onMatchChanged: onMatchChanged,
    compact: true,
    maxResults: hoshiPopupMaxResults,
    scanLength: hoshiPopupScanLength,
  );

  if (miningContext is MiningContext) return buildNative(miningContext);
  return FutureBuilder<MiningContext?>(
    future: Future<MiningContext?>.value(miningContext),
    builder: (context, snapshot) {
      final resolved = snapshot.data;
      if (resolved == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return buildNative(resolved);
    },
  );
}

/// A lookup Future coupled to the exact profile that produced it.
///
/// Keeping these together prevents an override change between hover-prefetch
/// and presentation from combining one profile's results with another
/// profile's styles, media, or Anki settings.
class DictionaryLookupPrefetch {
  const DictionaryLookupPrefetch._({
    required this.text,
    required this.profile,
    required this.results,
  });

  final String text;
  final Future<DictionaryProfile> profile;
  final Future<List<HoshiLookupResult>> results;
}

/// Keeps the root-overlay dictionary popup scoped to the current app route.
///
/// The popup host is intentionally persistent so its WebView can stay warm,
/// but a visible or pending presentation must not follow the user onto a new
/// route.
class DictionaryPopupDismissNavigatorObserver extends NavigatorObserver {
  DictionaryPopupDismissNavigatorObserver({VoidCallback? onNavigation})
    : _onNavigation =
          onNavigation ??
          (() {
            DictionaryLookupPopup.dismissActive();
          });

  final VoidCallback _onNavigation;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _onNavigation();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _onNavigation();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _onNavigation();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _onNavigation();
  }
}

enum DictionaryPopupPlacement { aboveOrBelow, leftOrRight }

@visibleForTesting
enum DictionaryPopupPresentationDecision { present, empty, stale }

/// Orders asynchronous popup lookups before they are allowed to become
/// visible. The latest lookup wins even when older requests finish later.
@visibleForTesting
class DictionaryPopupPresentationGate {
  int _generation = 0;

  int begin() => ++_generation;

  void cancel() => _generation++;

  bool isCurrent(int generation) => generation == _generation;

  Future<DictionaryPopupPresentationDecision> resolve<T>({
    required int generation,
    required Future<List<T>> results,
  }) async {
    try {
      final resolved = await results;
      if (!isCurrent(generation)) {
        return DictionaryPopupPresentationDecision.stale;
      }
      return resolved.isEmpty
          ? DictionaryPopupPresentationDecision.empty
          : DictionaryPopupPresentationDecision.present;
    } catch (_) {
      // Lookup failures have a retryable error state in HoshiDictionaryPopup.
      // Only successful empty lookups should suppress the popup.
      return isCurrent(generation)
          ? DictionaryPopupPresentationDecision.present
          : DictionaryPopupPresentationDecision.stale;
    }
  }
}

final _dictionaryPopupHost = _DictionaryPopupHostController();

class _DictionaryPopupHostController {
  final key = GlobalKey<_DictionaryPopupOverlayHostState>();
  final _presentationGate = DictionaryPopupPresentationGate();
  OverlayEntry? _entry;
  Future<void>? _initializing;

  Future<void> prewarm(BuildContext context) async {
    await _ensure(context);
    await _refreshPreferences();
  }

  Future<void> _refreshPreferences() async {
    final preferences = await MiningPreferences.getDictionaryPopupPreferences();
    key.currentState?.updatePreferences(preferences);
  }

  Future<void> prepare({
    required BuildContext context,
    required String text,
    required Future<List<HoshiLookupResult>> initialResults,
    required DictionaryProfile profile,
  }) async {
    await _ensure(context);
    await _refreshPreferences();
    if (!context.mounted) return;
    key.currentState?.prepare(
      text: text,
      initialResults: initialResults,
      profile: profile,
    );
  }

  bool dismissActive() {
    _presentationGate.cancel();
    final state = key.currentState;
    if (state == null || !state.isVisible) return false;
    state.dismiss();
    return true;
  }

  bool get isActive => key.currentState?.isVisible ?? false;

  Future<void> _ensure(BuildContext context) {
    if (_entry != null && key.currentState != null) return Future.value();
    final initializing = _initializing;
    if (initializing != null) return initializing;
    // The host lives in the root overlay. If that overlay was rebuilt, the
    // old entry is no longer mounted and must be recreated, or every later
    // lookup would wait on a host that never appears. A freshly inserted
    // entry is mounted by the time its initialization completes.
    if (_entry != null && !_entry!.mounted) _entry = null;
    if (_entry != null) return WidgetsBinding.instance.endOfFrame;
    return _initializing = _initialize(context);
  }

  Future<void> _initialize(BuildContext context) async {
    try {
      final preferences =
          await MiningPreferences.getDictionaryPopupPreferences();
      if (!context.mounted || _entry != null) return;
      final overlay = Overlay.of(context, rootOverlay: true);
      _entry = OverlayEntry(
        builder: (_) =>
            _DictionaryPopupOverlayHost(key: key, preferences: preferences),
      );
      overlay.insert(_entry!);
      await WidgetsBinding.instance.endOfFrame;
    } finally {
      // A reader can close while preferences are loading. Do not leave a
      // completed initialization future cached forever with no overlay entry;
      // the next reader must be able to retry the warm-up.
      _initializing = null;
    }
  }

  Future<DictionaryPopupHandle?> show({
    required BuildContext context,
    required Rect anchor,
    required String text,
    required FutureOr<MiningContext> miningContext,
    DictionaryLookupPrefetch? prefetch,
    required DictionaryPopupPlacement placement,
    bool dismissOnOutsideTap = true,
    ValueChanged<int>? onMatchChanged,
    ValueChanged<bool>? onHoverChanged,
  }) async {
    final generation = _presentationGate.begin();
    final resolvedMiningContext = await Future<MiningContext>.value(
      miningContext,
    );
    if (!_presentationGate.isCurrent(generation) || !context.mounted) {
      return null;
    }
    final compatiblePrefetch = prefetch?.text == text.trim() ? prefetch : null;
    final profile = compatiblePrefetch == null
        ? await DictionaryProfileResolver.resolveMiningContext(
            resolvedMiningContext,
          )
        : await compatiblePrefetch.profile;
    if (!_presentationGate.isCurrent(generation) || !context.mounted) {
      return null;
    }
    final results =
        compatiblePrefetch?.results ??
        HoshidictsLookupBackend.instance.lookup(
          text,
          maxResults: hoshiPopupMaxResults,
          scanLength: hoshiPopupScanLength,
          profile: profile,
        );
    final miningContextFuture = Future<MiningContext?>.value(
      resolvedMiningContext,
    );
    await _ensure(context);
    await _refreshPreferences();
    if (!_presentationGate.isCurrent(generation) || !context.mounted) {
      return null;
    }
    final existingState = key.currentState;

    // Hide an older result immediately, then give the persistent WebView the
    // new request off-screen while the lookup and host initialization overlap.
    // Reusing the exact Future also preserves EPUB/subtitle prefetch caches.
    existingState?.dismiss();
    existingState?.prepare(
      text: text,
      initialResults: results,
      profile: profile,
    );
    final decisionFuture = _presentationGate.resolve(
      generation: generation,
      results: results,
    );

    if (existingState == null) {
      key.currentState?.prepare(
        text: text,
        initialResults: results,
        profile: profile,
      );
    }
    final decision = await decisionFuture;
    if (decision != DictionaryPopupPresentationDecision.present ||
        !_presentationGate.isCurrent(generation)) {
      return null;
    }

    DictionaryPopupHandle? present() {
      if (!context.mounted) return null;
      return key.currentState?.present(
        screen: MediaQuery.sizeOf(context),
        anchor: anchor,
        text: text,
        miningContext: miningContextFuture,
        initialResults: results,
        profile: profile,
        placement: placement,
        dismissOnOutsideTap: dismissOnOutsideTap,
        onMatchChanged: onMatchChanged,
        onHoverChanged: onHoverChanged,
      );
    }

    // A prefetched result can already be rendered by the hidden host, so reveal
    // it without rebuilding the WebView or starting another lookup.
    final currentHandle = present();
    if (currentHandle != null) return currentHandle;
    await WidgetsBinding.instance.endOfFrame;
    if (!_presentationGate.isCurrent(generation)) return null;
    return present();
  }
}

class _DictionaryPopupRequest {
  const _DictionaryPopupRequest({
    required this.text,
    required this.miningContext,
    required this.initialResults,
    required this.profile,
    required this.onMatchChanged,
    required this.onHoverChanged,
  });

  final String text;
  final Future<MiningContext?> miningContext;
  final Future<List<HoshiLookupResult>> initialResults;
  final DictionaryProfile? profile;
  final ValueChanged<int>? onMatchChanged;
  final ValueChanged<bool>? onHoverChanged;
}

class _DictionaryChildPopup {
  _DictionaryChildPopup({
    required this.id,
    required this.request,
    required this.rect,
  });

  final int id;
  final _DictionaryPopupRequest request;
  final Rect rect;
  final controller = HoshiDictionaryPopupController();
}

class _DictionaryPopupOverlayHost extends StatefulWidget {
  const _DictionaryPopupOverlayHost({super.key, required this.preferences});

  final DictionaryPopupPreferences preferences;

  @override
  State<_DictionaryPopupOverlayHost> createState() =>
      _DictionaryPopupOverlayHostState();
}

class _DictionaryPopupOverlayHostState
    extends State<_DictionaryPopupOverlayHost> {
  static final _warmRequest = _DictionaryPopupRequest(
    text: '',
    miningContext: Future<MiningContext?>.value(null),
    initialResults: Future<List<HoshiLookupResult>>.value(const []),
    profile: null,
    onMatchChanged: null,
    onHoverChanged: null,
  );

  _DictionaryPopupRequest _request = _warmRequest;
  late DictionaryPopupPreferences _preferences = widget.preferences;
  Completer<void>? _dismissed;
  bool _visible = false;
  late double _left;
  double _top = 0;
  late double _width;
  late double _height;
  bool _dismissOnOutsideTap = true;
  bool _reportedHovered = false;
  int _presentationGeneration = 0;
  int? _pendingOutsidePointer;
  int? _pendingOutsideGeneration;
  final _rootController = HoshiDictionaryPopupController();
  final List<_DictionaryChildPopup> _children = [];
  int _nextChildId = 0;
  int _childLookupGeneration = 0;

  bool get isVisible => _visible;

  void updatePreferences(DictionaryPopupPreferences preferences) {
    if (_preferences == preferences) return;
    setState(() {
      _preferences = preferences;
      if (!_visible) {
        _width = preferences.width;
        _height = preferences.height;
        _left = -_width - 100;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _width = widget.preferences.width;
    _height = widget.preferences.height;
    _left = -_width - 100;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handleGlobalPointer);
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
  }

  Rect get _popupBounds => Rect.fromLTWH(_left, _top, _width, _height);

  Iterable<Rect> get _visiblePopupBounds sync* {
    yield _popupBounds;
    for (final child in _children) {
      yield child.rect;
    }
  }

  void _handleGlobalPointer(PointerEvent event) {
    if (event is PointerHoverEvent && _visible) {
      // A native desktop WebView can swallow MouseRegion exit notifications.
      // Flutter receives pointer events again as soon as the cursor returns
      // to the surrounding reader, so use the global route as a fallback.
      _reportHover(
        _visiblePopupBounds.any((bounds) => bounds.contains(event.position)),
      );
    }
    if (event is PointerDownEvent) {
      if (_visiblePopupBounds.any(
        (bounds) => bounds.contains(event.position),
      )) {
        return;
      }
      if (!dictionaryPopupShouldDismissForPointer(
        visible: _visible,
        dismissOnOutsideTap: _dismissOnOutsideTap,
        popupBounds: _popupBounds,
        position: event.position,
        buttons: event.buttons,
      )) {
        return;
      }
      _pendingOutsidePointer = event.pointer;
      _pendingOutsideGeneration = _presentationGeneration;
      return;
    }
    if (event.pointer != _pendingOutsidePointer) return;
    if (event is PointerCancelEvent) {
      _clearPendingOutsideDismissal();
      return;
    }
    if (event is! PointerUpEvent) return;
    final generation = _pendingOutsideGeneration;
    _clearPendingOutsideDismissal();
    if (generation == null) return;

    // Reader lookups are recognized on pointer-up. Give that callback a
    // chance to replace the request before dismissing so successive clicks
    // update the warm popup in place instead of closing and reopening it.
    scheduleMicrotask(() {
      if (!mounted ||
          !dictionaryPopupShouldCommitOutsideDismissal(
            visible: _visible,
            startedGeneration: generation,
            currentGeneration: _presentationGeneration,
          )) {
        return;
      }
      dismiss();
    });
  }

  void _clearPendingOutsideDismissal() {
    _pendingOutsidePointer = null;
    _pendingOutsideGeneration = null;
  }

  void _reportHover(bool hovered) {
    if (!_visible || _reportedHovered == hovered) return;
    _reportedHovered = hovered;
    _request.onHoverChanged?.call(hovered);
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (!_visible || event is! KeyDownEvent) return false;
    if (!dictionaryPopupIsDismissKey(event.logicalKey)) return false;
    if (_children.isNotEmpty) {
      _dismissChild(_children.length - 1);
      return true;
    }
    dismiss();
    return true;
  }

  DictionaryPopupHandle present({
    required Size screen,
    required Rect anchor,
    required String text,
    required Future<MiningContext?> miningContext,
    required Future<List<HoshiLookupResult>> initialResults,
    required DictionaryProfile profile,
    required DictionaryPopupPlacement placement,
    required bool dismissOnOutsideTap,
    ValueChanged<int>? onMatchChanged,
    ValueChanged<bool>? onHoverChanged,
  }) {
    _clearPendingOutsideDismissal();
    final generation = ++_presentationGeneration;
    _completeDismissal();
    final popupRect = dictionaryPopupRect(
      screen: screen,
      anchor: anchor,
      preferredSize: Size(_preferences.width, _preferences.height),
      placement: placement,
    );
    final completer = Completer<void>();
    setState(() {
      _children.clear();
      _childLookupGeneration++;
      _request = _DictionaryPopupRequest(
        text: text,
        miningContext: miningContext,
        initialResults: initialResults,
        profile: profile,
        onMatchChanged: onMatchChanged,
        onHoverChanged: onHoverChanged,
      );
      _dismissed = completer;
      _visible = true;
      _reportedHovered = false;
      _dismissOnOutsideTap = dismissOnOutsideTap;
      _left = popupRect.left;
      _top = popupRect.top;
      _width = popupRect.width;
      _height = popupRect.height;
    });
    return DictionaryPopupHandle(
      dismiss: () => dismiss(expectedGeneration: generation),
      dismissed: completer.future,
    );
  }

  void prepare({
    required String text,
    required Future<List<HoshiLookupResult>> initialResults,
    required DictionaryProfile profile,
  }) {
    final query = text.trim();
    if (_visible || query.isEmpty) return;
    if (_request.text == query &&
        identical(_request.initialResults, initialResults)) {
      return;
    }
    setState(() {
      _request = _DictionaryPopupRequest(
        text: query,
        miningContext: Future<MiningContext?>.value(null),
        initialResults: initialResults,
        profile: profile,
        onMatchChanged: null,
        onHoverChanged: null,
      );
    });
  }

  void dismiss({int? expectedGeneration}) {
    if (!dictionaryPopupCanDismissGeneration(
      expectedGeneration: expectedGeneration,
      currentGeneration: _presentationGeneration,
    )) {
      return;
    }
    _clearPendingOutsideDismissal();
    _presentationGeneration++;
    if (!_visible) {
      _completeDismissal();
      return;
    }
    // Keep the last request mounted so the WebView, rendered definitions, and
    // lookup state survive dismissal and can be reused across reader bubbles.
    setState(() {
      _visible = false;
      _reportedHovered = false;
      _children.clear();
      _childLookupGeneration++;
      _dismissOnOutsideTap = true;
      _left = -_width - 100;
      _top = 0;
    });
    _completeDismissal();
  }

  void _completeDismissal() {
    final completer = _dismissed;
    _dismissed = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  Future<int> _openChild({
    required int parentIndex,
    required Rect parentRect,
    required HoshiDictionaryTextSelection selection,
  }) async {
    final query = selection.text.trim();
    if (query.isEmpty) return 0;
    unawaited(MiningPreferences.recordDictionaryLookup(query));
    final generation = ++_childLookupGeneration;
    final resultsFuture = DictionaryLookupPopup.lookup(
      query,
      profile: _request.profile,
    );
    final results = await resultsFuture;
    if (!mounted || generation != _childLookupGeneration || results.isEmpty) {
      return 0;
    }
    final matched = results.first.matched.length;
    final anchor = dictionaryPopupChildAnchor(
      parentRect: parentRect,
      localSelectionRect: selection.rect,
    );
    final screen = MediaQuery.sizeOf(context);
    final rect = dictionaryPopupRect(
      screen: screen,
      anchor: anchor,
      preferredSize: Size(_preferences.width, _preferences.height),
    );
    final child = _DictionaryChildPopup(
      id: ++_nextChildId,
      rect: rect,
      request: _DictionaryPopupRequest(
        text: query,
        miningContext: _request.miningContext,
        initialResults: resultsFuture,
        profile: _request.profile,
        onMatchChanged: null,
        onHoverChanged: _request.onHoverChanged,
      ),
    );
    setState(() {
      final keep = parentIndex + 1;
      if (_children.length > keep) {
        _children.removeRange(keep, _children.length);
      }
      _children.add(child);
    });
    return matched;
  }

  void _closeChildrenAfter(int parentIndex) {
    final keep = parentIndex + 1;
    if (_children.length <= keep) return;
    _childLookupGeneration++;
    setState(() => _children.removeRange(keep, _children.length));
  }

  void _dismissChild(int index) {
    if (index < 0 || index >= _children.length) return;
    _childLookupGeneration++;
    if (index == 0) {
      unawaited(_rootController.clearSelection());
    } else {
      unawaited(_children[index - 1].controller.clearSelection());
    }
    setState(() => _children.removeRange(index, _children.length));
  }

  @override
  Widget build(BuildContext context) {
    final request = _request;
    final presentationGeneration = _presentationGeneration;
    final popupTheme = _popupTheme(Theme.of(context), _preferences.theme);
    return Stack(
      children: [
        Positioned(
          left: _left,
          top: _top,
          width: _width,
          height: _height,
          child: Offstage(
            offstage: !_visible,
            child: IgnorePointer(
              ignoring: !_visible,
              child: MouseRegion(
                onEnter: (_) => _reportHover(true),
                onExit: (_) => _reportHover(false),
                child: Theme(
                  data: popupTheme.copyWith(
                    textTheme: popupTheme.textTheme.apply(
                      fontSizeFactor: _preferences.fontSize / 14,
                    ),
                  ),
                  child: Material(
                    elevation: _visible && !_preferences.eInkMode ? 12 : 0,
                    clipBehavior: Clip.antiAlias,
                    borderRadius: BorderRadius.circular(
                      _preferences.eInkMode ? 0 : 8,
                    ),
                    color: popupTheme.colorScheme.surface,
                    child: _dictionaryPopupRenderer(
                      controller: _rootController,
                      text: request.text,
                      profile: request.profile,
                      miningContext: request.miningContext,
                      initialResults: request.initialResults,
                      preferences: _preferences,
                      onMatchChanged: (count) {
                        if (_visible &&
                            presentationGeneration == _presentationGeneration &&
                            identical(request, _request)) {
                          request.onMatchChanged?.call(count);
                        }
                      },
                      onDismiss: () =>
                          dismiss(expectedGeneration: presentationGeneration),
                      onTextSelected: (selection) => _openChild(
                        parentIndex: -1,
                        parentRect: _popupBounds,
                        selection: selection,
                      ),
                      onTapOutside: () => _closeChildrenAfter(-1),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        for (final indexed in _children.indexed)
          Positioned(
            key: ValueKey('dictionary-child-popup-${indexed.$2.id}'),
            left: indexed.$2.rect.left,
            top: indexed.$2.rect.top,
            width: indexed.$2.rect.width,
            height: indexed.$2.rect.height,
            child: MouseRegion(
              onEnter: (_) => _reportHover(true),
              onExit: (_) => _reportHover(false),
              child: Theme(
                data: popupTheme.copyWith(
                  textTheme: popupTheme.textTheme.apply(
                    fontSizeFactor: _preferences.fontSize / 14,
                  ),
                ),
                child: Material(
                  elevation: _preferences.eInkMode ? 0 : 12,
                  clipBehavior: Clip.antiAlias,
                  borderRadius: BorderRadius.circular(
                    _preferences.eInkMode ? 0 : 8,
                  ),
                  color: popupTheme.colorScheme.surface,
                  child: _dictionaryPopupRenderer(
                    controller: indexed.$2.controller,
                    text: indexed.$2.request.text,
                    profile: indexed.$2.request.profile,
                    miningContext: indexed.$2.request.miningContext,
                    initialResults: indexed.$2.request.initialResults,
                    preferences: _preferences,
                    onMatchChanged: (_) {},
                    onDismiss: () => _dismissChild(indexed.$1),
                    onTextSelected: (selection) => _openChild(
                      parentIndex: indexed.$1,
                      parentRect: indexed.$2.rect,
                      selection: selection,
                    ),
                    onTapOutside: () => _closeChildrenAfter(indexed.$1),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(
      _handleGlobalPointer,
    );
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    _completeDismissal();
    super.dispose();
  }
}

class DictionaryLookupPopup extends StatelessWidget {
  const DictionaryLookupPopup({
    super.key,
    required this.text,
    required this.miningContext,
    required this.onMatchChanged,
    required this.onClose,
    required this.preferences,
  });

  final String text;
  final MiningContext miningContext;
  final ValueChanged<int> onMatchChanged;
  final VoidCallback onClose;
  final DictionaryPopupPreferences preferences;

  static Future<DictionaryPopupHandle?> show({
    required BuildContext context,
    required Rect anchor,
    required String text,
    required FutureOr<MiningContext> miningContext,
    DictionaryLookupPrefetch? prefetch,
    DictionaryPopupPlacement placement = DictionaryPopupPlacement.aboveOrBelow,
    bool dismissOnOutsideTap = true,
    ValueChanged<int>? onMatchChanged,
    ValueChanged<bool>? onHoverChanged,
  }) async {
    final lookupText = text.trim();
    if (lookupText.isEmpty) return null;
    unawaited(MiningPreferences.recordDictionaryLookup(lookupText));
    return _dictionaryPopupHost.show(
      context: context,
      anchor: anchor,
      text: lookupText,
      miningContext: miningContext,
      prefetch: prefetch,
      placement: placement,
      dismissOnOutsideTap: dismissOnOutsideTap,
      onMatchChanged: onMatchChanged,
      onHoverChanged: onHoverChanged,
    );
  }

  static Future<void> prewarm(BuildContext context) =>
      _dictionaryPopupHost.prewarm(context);

  /// Resolves and renders the latest hovered word while the persistent popup
  /// remains off-screen. Showing the same request can then reuse both the
  /// lookup Future and the already-warm WebView document.
  static Future<void> prepare({
    required BuildContext context,
    required String text,
    required DictionaryLookupPrefetch prefetch,
  }) async {
    if (prefetch.text != text.trim()) return;
    final profile = await prefetch.profile;
    if (!context.mounted) return;
    return _dictionaryPopupHost.prepare(
      context: context,
      text: text,
      initialResults: prefetch.results,
      profile: profile,
    );
  }

  /// Dismisses the active popup without affecting the current app route.
  /// Returns whether a popup consumed the back action.
  static bool dismissActive() => _dictionaryPopupHost.dismissActive();

  static bool get isActive => _dictionaryPopupHost.isActive;

  static Future<List<HoshiLookupResult>> lookup(
    String text, {
    FutureOr<MiningContext?> miningContext,
    DictionaryProfile? profile,
  }) async {
    return prefetch(
      text,
      miningContext: miningContext,
      profile: profile,
    ).results;
  }

  static DictionaryLookupPrefetch prefetch(
    String text, {
    FutureOr<MiningContext?> miningContext,
    DictionaryProfile? profile,
  }) {
    final query = text.trim();
    final profileFuture = profile == null
        ? Future<MiningContext?>.value(
            miningContext,
          ).then(DictionaryProfileResolver.resolveMiningContext)
        : Future<DictionaryProfile>.value(profile);
    final results = query.isEmpty
        ? Future<List<HoshiLookupResult>>.value(const [])
        : profileFuture.then(
            (resolvedProfile) => HoshidictsLookupBackend.instance.lookup(
              query,
              maxResults: hoshiPopupMaxResults,
              scanLength: hoshiPopupScanLength,
              profile: resolvedProfile,
            ),
          );
    return DictionaryLookupPrefetch._(
      text: query,
      profile: profileFuture,
      results: results,
    );
  }

  @override
  Widget build(BuildContext context) {
    final baseTheme = Theme.of(context);
    final popupTheme = _popupTheme(baseTheme, preferences.theme);
    return Theme(
      data: popupTheme.copyWith(
        textTheme: popupTheme.textTheme.apply(
          fontSizeFactor: preferences.fontSize / 14,
        ),
      ),
      child: Material(
        elevation: preferences.eInkMode ? 0 : 12,
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(preferences.eInkMode ? 0 : 8),
        color: popupTheme.colorScheme.surface,
        child: _dictionaryPopupRenderer(
          text: text,
          miningContext: miningContext,
          profile: null,
          initialResults: null,
          preferences: preferences,
          onMatchChanged: onMatchChanged,
          onDismiss: onClose,
        ),
      ),
    );
  }
}

@visibleForTesting
bool dictionaryPopupIsDismissKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.escape ||
    key == LogicalKeyboardKey.backspace ||
    key == LogicalKeyboardKey.browserBack;

@visibleForTesting
bool dictionaryPopupShouldDismissForPointer({
  required bool visible,
  required bool dismissOnOutsideTap,
  required Rect popupBounds,
  required Offset position,
  required int buttons,
}) {
  if (!visible || !dismissOnOutsideTap) return false;
  // Mouse navigation buttons are handled by the app-level back listener so
  // it can consume the route pop when a dictionary popup is active.
  if (buttons & (kBackMouseButton | kForwardMouseButton) != 0) return false;
  return !popupBounds.contains(position);
}

@visibleForTesting
bool dictionaryPopupShouldCommitOutsideDismissal({
  required bool visible,
  required int startedGeneration,
  required int currentGeneration,
}) => visible && startedGeneration == currentGeneration;

@visibleForTesting
bool dictionaryPopupCanDismissGeneration({
  required int? expectedGeneration,
  required int currentGeneration,
}) => expectedGeneration == null || expectedGeneration == currentGeneration;

@visibleForTesting
Rect dictionaryPopupRect({
  required Size screen,
  required Rect anchor,
  required Size preferredSize,
  DictionaryPopupPlacement placement = DictionaryPopupPlacement.aboveOrBelow,
}) {
  const margin = 12.0;
  const gap = 8.0;
  final availableWidth = math.max(0.0, screen.width - margin * 2);
  final availableHeight = math.max(0.0, screen.height - margin * 2);
  var width = math.min(preferredSize.width, availableWidth);
  var height = math.min(preferredSize.height, availableHeight);

  if (placement == DictionaryPopupPlacement.aboveOrBelow) {
    final spaceAbove = math.max(0.0, anchor.top - gap - margin);
    final spaceBelow = math.max(
      0.0,
      screen.height - margin - anchor.bottom - gap,
    );
    // Hoshi shrinks to the larger free side before choosing it. Clamping a
    // full-height popup after placement can otherwise cover the looked-up
    // word when neither side has enough room.
    height = math.min(height, math.max(spaceAbove, spaceBelow));
    final left = (anchor.center.dx - width / 2)
        .clamp(margin, math.max(margin, screen.width - width - margin))
        .toDouble();
    final below = anchor.bottom + gap;
    final top = spaceBelow >= height
        ? below
        : math.max(margin, anchor.top - height - gap);
    return Rect.fromLTWH(left, top, width, height);
  }

  // Match Yomitan's vertical-text policy: Japanese vertical text prefers the
  // right, falls back to the side with less overflow, and shrinks only when
  // neither side can contain the preferred width.
  final before = math.min(screen.width - margin, anchor.left - gap);
  final after = math.max(margin, anchor.right + gap);
  final spaceBefore = math.max(0.0, before - margin);
  final spaceAfter = math.max(0.0, screen.width - margin - after);
  final placeRight = spaceAfter >= width
      ? true
      : spaceBefore >= width
      ? false
      : spaceAfter > spaceBefore;
  width = math.min(width, placeRight ? spaceAfter : spaceBefore);
  final left = placeRight ? after : before - width;
  final top = anchor.top
      .clamp(margin, math.max(margin, screen.height - height - margin))
      .toDouble();
  return Rect.fromLTWH(left, top, width, height);
}

@visibleForTesting
Rect dictionaryPopupChildAnchor({
  required Rect parentRect,
  required Rect localSelectionRect,
}) => localSelectionRect.shift(parentRect.topLeft);

class DictionaryLookupResultsView extends StatefulWidget {
  const DictionaryLookupResultsView({
    super.key,
    required this.text,
    required this.miningContext,
    this.profile,
    this.initialResults,
    this.preferences,
    this.onMatchChanged,
    this.physics,
    this.padding = EdgeInsets.zero,
    this.compact = false,
    this.showAnkiButton = true,
    this.shrinkWrap = false,
    this.maxResults = 10,
    this.scanLength = hoshiPopupScanLength,
  });

  final String text;
  final MiningContext miningContext;
  final DictionaryProfile? profile;
  final Future<List<HoshiLookupResult>>? initialResults;
  final DictionaryPopupPreferences? preferences;
  final ValueChanged<int>? onMatchChanged;
  final ScrollPhysics? physics;
  final EdgeInsets padding;
  final bool compact;
  final bool showAnkiButton;
  final bool shrinkWrap;
  final int maxResults;
  final int scanLength;

  @override
  State<DictionaryLookupResultsView> createState() =>
      _DictionaryLookupResultsViewState();
}

bool _sameDictionaryProfileContext(MiningContext left, MiningContext right) =>
    left.mangaId == right.mangaId &&
    left.sourceId == right.sourceId &&
    left.sourceLanguage == right.sourceLanguage &&
    left.novelId == right.novelId;

class _DictionaryLookupResultsViewState
    extends State<DictionaryLookupResultsView> {
  late Future<_LookupPayload> _future = _lookup();
  bool _exporting = false;
  AnkiExportJobController? _activeExportJob;
  StreamSubscription<AnkiExportJobState>? _exportJobSubscription;

  @override
  void dispose() {
    _exportJobSubscription?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DictionaryLookupResultsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.profile != widget.profile ||
        oldWidget.initialResults != widget.initialResults ||
        oldWidget.maxResults != widget.maxResults ||
        oldWidget.scanLength != widget.scanLength ||
        oldWidget.preferences != widget.preferences ||
        !_sameDictionaryProfileContext(
          oldWidget.miningContext,
          widget.miningContext,
        )) {
      _future = _lookup();
    }
  }

  Future<_LookupPayload> _lookup() async {
    final profile =
        widget.profile ??
        await DictionaryProfileResolver.resolveMiningContext(
          widget.miningContext,
        );
    final preferences =
        widget.preferences ??
        await MiningPreferences.getDictionaryPopupPreferences();
    final lookupText = widget.text.trim();
    if (lookupText.isEmpty) {
      return _LookupPayload.empty(preferences, profile);
    }
    final values = await Future.wait<dynamic>([
      widget.initialResults ??
          HoshidictsLookupBackend.instance.lookup(
            lookupText,
            maxResults: widget.maxResults,
            scanLength: widget.scanLength,
            profile: profile,
          ),
      HoshidictsLookupBackend.instance
          .getStyles(profile: profile)
          .catchError((_) => <HoshiDictionaryStyle>[]),
    ]);
    final results = values[0] as List<HoshiLookupResult>;
    if (results.isNotEmpty) {
      widget.onMatchChanged?.call(results.first.matched.length);
    }
    final styles = values[1] as List<HoshiDictionaryStyle>;
    return _LookupPayload(
      results: results,
      styles: {for (final style in styles) style.dictName: style.styles},
      preferences: preferences,
      profile: profile,
    );
  }

  Future<void> _export(
    HoshiLookupResult result,
    DictionaryProfile dictionaryProfile,
  ) async {
    setState(() => _exporting = true);
    try {
      final profile = dictionaryProfile.anki;
      if (!profile.ankiEnabled) {
        botToast('Anki export is disabled in Dictionary settings', second: 4);
        return;
      }
      final preferredMode = await MiningPreferences.getAnkiIntegrationMode();
      final integrationMode = effectiveAnkiIntegrationMode(
        preferredMode: preferredMode,
        isIOS: defaultTargetPlatform == TargetPlatform.iOS,
      );
      if (integrationMode == AnkiIntegrationMode.ankiMobile) {
        final draft = await const AnkiCardBuilder().build(
          result: result,
          context: widget.miningContext,
          profile: profile,
          screenshotMode:
              dictionaryProfile.screenshotMode ==
                  AnkiScreenshotMode.noScreenshot
              ? AnkiScreenshotMode.noScreenshot
              : AnkiScreenshotMode.full,
        );
        await AnkiMobileService().exportDraft(
          draft,
          allowDuplicate:
              !profile.duplicateCheck ||
              dictionaryProfile.duplicateAction == 'allow',
        );
      } else {
        final pending = await const AnkiCardBuilder().buildPending(
          result: result,
          context: widget.miningContext,
          profile: profile,
          screenshotMode: dictionaryProfile.screenshotMode,
        );
        _activeExportJob = pending.jobController;
        await _exportJobSubscription?.cancel();
        _exportJobSubscription = _activeExportJob?.states.listen((_) {
          if (mounted) setState(() {});
        });
        final export =
            await AnkiConnectService(
              endpoint: await MiningPreferences.getAnkiEndpoint(),
            ).exportPending(
              pending,
              duplicateCheck: profile.duplicateCheck,
              allowDuplicate: dictionaryProfile.duplicateAction == 'allow',
              duplicateScope: profile.duplicateScope,
              duplicateDeckNames: profile.duplicateDeckNames,
              checkAllModels: profile.checkAllModels,
              syncOnCreate: profile.syncOnCreate,
            );
        final warning = export.warnings.isEmpty
            ? ''
            : '\n${export.warnings.join('\n')}';
        botToast('Added to Anki (#${export.noteId})$warning', second: 5);
      }
      await AnkiStatsRecorder.recordCard(
        context: widget.miningContext,
        profile: dictionaryProfile,
      );
    } on AnkiDuplicateException {
      botToast('Already in Anki', second: 3);
    } on AnkiExportCancelledException {
      botToast('Anki export cancelled', second: 2);
    } catch (error) {
      botToast('Anki export failed: $error', second: 5);
    } finally {
      await _exportJobSubscription?.cancel();
      _exportJobSubscription = null;
      _activeExportJob = null;
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_LookupPayload>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _EmptyLookupState(text: 'Lookup failed: ${snapshot.error}');
        }
        final payload = snapshot.data;
        if (payload == null) {
          return const _EmptyLookupState(text: 'No dictionary results found.');
        }
        final results = payload.results;
        if (widget.text.trim().isEmpty) {
          return const _EmptyLookupState(text: 'Enter text to look up.');
        }
        if (results.isEmpty) {
          return const _EmptyLookupState(text: 'No dictionary results found.');
        }
        return ListView.separated(
          physics: widget.shrinkWrap
              ? const NeverScrollableScrollPhysics()
              : widget.physics,
          primary: widget.shrinkWrap ? false : null,
          shrinkWrap: widget.shrinkWrap,
          padding: widget.padding,
          itemCount: results.length,
          separatorBuilder: (_, _) =>
              Divider(height: 1, color: Theme.of(context).dividerColor),
          itemBuilder: (context, index) {
            final result = results[index];
            return _LookupResultTile(
              result: result,
              profile: payload.profile,
              preferences: payload.preferences,
              styles: payload.styles,
              exporting: _exporting,
              cancellable: _activeExportJob?.canCancel ?? false,
              showAnkiButton: widget.showAnkiButton,
              compact: widget.compact,
              onExport: () => _export(result, payload.profile),
              onCancel: () => _activeExportJob?.cancel(),
            );
          },
        );
      },
    );
  }
}

class _LookupResultTile extends StatelessWidget {
  const _LookupResultTile({
    required this.result,
    required this.profile,
    required this.preferences,
    required this.styles,
    required this.exporting,
    required this.cancellable,
    required this.showAnkiButton,
    required this.compact,
    required this.onExport,
    required this.onCancel,
  });

  final HoshiLookupResult result;
  final DictionaryProfile profile;
  final DictionaryPopupPreferences preferences;
  final Map<String, String> styles;
  final bool exporting;
  final bool cancellable;
  final bool showAnkiButton;
  final bool compact;
  final VoidCallback onExport;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final term = result.term;
    final glossaryGroups = _groupGlossariesByDictionary(term.glossaries);
    final expandedDictionaries = initiallyExpandedDictionaries(
      profile: profile,
      dictionaries: glossaryGroups.map((group) => group.dictionaryName),
    );
    final senseTermTags = _uniqueTags(
      term.glossaries.expand((entry) => _splitTags(entry.termTags)),
    ).toSet();
    final rules = _splitTags(term.rules);
    final globalRules = [
      for (final rule in rules)
        if (!senseTermTags.contains(rule)) rule,
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(10, compact ? 8 : 12, 6, compact ? 8 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _LookupEntryMarker(result: result),
              const SizedBox(width: 6),
              Expanded(
                child: _TermHeading(
                  term: term,
                  result: result,
                  compact: compact,
                ),
              ),
              if (showAnkiButton)
                IconButton(
                  tooltip: cancellable ? 'Cancel preparation' : 'Add to Anki',
                  onPressed: exporting
                      ? (cancellable ? onCancel : null)
                      : onExport,
                  visualDensity: VisualDensity.compact,
                  icon: cancellable
                      ? const Icon(Icons.close, size: 20)
                      : exporting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.note_add_outlined, size: 20),
                ),
            ],
          ),
          if (globalRules.isNotEmpty) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 22),
              child: Wrap(
                spacing: 5,
                runSpacing: 5,
                children: [
                  for (final rule in globalRules)
                    _LookupChip(label: rule, kind: _ChipKind.rule),
                ],
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.only(left: 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DeinflectionTrace(result: result),
                SizedBox(height: compact ? 5 : 8),
                if (term.frequencies.isNotEmpty || term.pitches.isNotEmpty) ...[
                  _FrequencyAndPitchBlock(term: term, preferences: preferences),
                  SizedBox(height: compact ? 6 : 9),
                ],
                for (final group in glossaryGroups)
                  _DictionaryGlossaryGroup(
                    // A fresh lookup must reapply the configured collapse
                    // policy instead of retaining the user's toggle from the
                    // previous result with the same dictionary name.
                    key: ValueKey((group.dictionaryName, result)),
                    group: group,
                    profile: profile,
                    initiallyExpanded: expandedDictionaries.contains(
                      group.dictionaryName,
                    ),
                    styles: styles,
                    preferences: preferences,
                    compact: compact,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DictionaryGlossaryGroup extends StatefulWidget {
  const _DictionaryGlossaryGroup({
    super.key,
    required this.group,
    required this.profile,
    required this.initiallyExpanded,
    required this.styles,
    required this.preferences,
    required this.compact,
  });

  final _GlossaryGroup group;
  final DictionaryProfile profile;
  final bool initiallyExpanded;
  final Map<String, String> styles;
  final DictionaryPopupPreferences preferences;
  final bool compact;

  @override
  State<_DictionaryGlossaryGroup> createState() =>
      _DictionaryGlossaryGroupState();
}

class _DictionaryGlossaryGroupState extends State<_DictionaryGlossaryGroup> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  void didUpdateWidget(covariant _DictionaryGlossaryGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group.dictionaryName != widget.group.dictionaryName ||
        oldWidget.initiallyExpanded != widget.initiallyExpanded) {
      _expanded = widget.initiallyExpanded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final group = widget.group;
    final termTags = _uniqueTags(
      group.entries.expand((entry) => _splitTags(entry.termTags)),
    );
    final hasMultipleSenses = group.entries.length > 1;
    final dictionaryName = group.dictionaryName.trim().isEmpty
        ? 'Dictionary'
        : group.dictionaryName.trim();

    return Container(
      margin: EdgeInsets.only(bottom: widget.compact ? 6 : 9),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.72),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 5, 8, 4),
              child: Row(
                children: [
                  Icon(
                    _expanded ? Icons.arrow_drop_down : Icons.arrow_right,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Text(
                      dictionaryName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: EdgeInsets.fromLTRB(
                widget.compact ? 9 : 11,
                2,
                widget.compact ? 9 : 11,
                widget.compact ? 7 : 10,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (termTags.isNotEmpty) ...[
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final tag in termTags)
                          _LookupChip(label: tag, kind: _ChipKind.tag),
                      ],
                    ),
                    const SizedBox(height: 5),
                  ],
                  for (final indexed in group.entries.indexed)
                    _GlossarySense(
                      index: indexed.$1 + 1,
                      showIndex: hasMultipleSenses,
                      glossary: indexed.$2,
                      profile: widget.profile,
                      styles: widget.styles,
                      preferences: widget.preferences,
                      compact: widget.compact,
                      hiddenTermTags: termTags.toSet(),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _LookupEntryMarker extends StatelessWidget {
  const _LookupEntryMarker({required this.result});

  final HoshiLookupResult result;

  @override
  Widget build(BuildContext context) {
    final hasTransform =
        result.trace.isNotEmpty ||
        (result.matched.trim().isNotEmpty &&
            result.deinflected.trim().isNotEmpty &&
            result.matched.trim() != result.deinflected.trim());
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Icon(
        hasTransform ? Icons.arrow_right : Icons.circle,
        size: hasTransform ? 18 : 6,
        color: hasTransform
            ? Theme.of(context).colorScheme.primary
            : Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(alpha: 0.55),
      ),
    );
  }
}

class _TermHeading extends StatelessWidget {
  const _TermHeading({
    required this.term,
    required this.result,
    required this.compact,
  });

  final HoshiTermResult term;
  final HoshiLookupResult result;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final reading = term.reading.trim();
    final showReading = reading.isNotEmpty && reading != term.expression;
    final titleStyle = compact
        ? Theme.of(context).textTheme.headlineSmall
        : Theme.of(context).textTheme.headlineMedium;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showReading)
          Text(
            reading,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              height: 1,
            ),
          ),
        Text(
          term.expression,
          style: titleStyle?.copyWith(
            fontWeight: FontWeight.w400,
            height: 1.05,
          ),
        ),
      ],
    );
  }
}

class _DeinflectionTrace extends StatelessWidget {
  const _DeinflectionTrace({required this.result});

  final HoshiLookupResult result;

  @override
  Widget build(BuildContext context) {
    final deinflected = result.deinflected.trim();
    final matched = result.matched.trim();
    final hasProcess =
        deinflected.isNotEmpty && matched.isNotEmpty && deinflected != matched;
    if (!hasProcess && result.trace.isEmpty && result.preprocessorSteps == 0) {
      return const SizedBox.shrink();
    }
    final processText = hasProcess ? '$matched -> $deinflected' : '';
    final traceLabels = [
      for (final group in result.trace)
        if (group.name.trim().isNotEmpty) group.name.trim(),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Tooltip(
        message: [
          if (processText.isNotEmpty) processText,
          for (final group in result.trace)
            if (group.description.trim().isNotEmpty)
              '${group.name}: ${group.description}',
        ].join('\n'),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              Icons.extension_outlined,
              size: 15,
              color: Colors.lightGreenAccent.shade400,
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Wrap(
                spacing: 5,
                runSpacing: 5,
                children: [
                  if (traceLabels.isEmpty && processText.isNotEmpty)
                    _LookupChip(label: processText, kind: _ChipKind.trace),
                  for (final label in traceLabels)
                    _LookupChip(label: label, kind: _ChipKind.trace),
                  if (result.preprocessorSteps > 0)
                    _LookupChip(
                      label: '${result.preprocessorSteps} preprocess',
                      kind: _ChipKind.trace,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlossarySense extends StatelessWidget {
  const _GlossarySense({
    required this.index,
    required this.showIndex,
    required this.glossary,
    required this.profile,
    required this.styles,
    required this.preferences,
    required this.compact,
    required this.hiddenTermTags,
  });

  final int index;
  final bool showIndex;
  final HoshiGlossaryEntry glossary;
  final DictionaryProfile profile;
  final Map<String, String> styles;
  final DictionaryPopupPreferences preferences;
  final bool compact;
  final Set<String> hiddenTermTags;

  @override
  Widget build(BuildContext context) {
    final seen = <String>{...hiddenTermTags};
    final termTags = _splitTags(
      glossary.termTags,
    ).where((tag) => seen.add(tag)).toList();
    final definitionTags = _splitTags(
      glossary.definitionTags,
    ).where((tag) => tag != index.toString() && seen.add(tag)).toList();
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 8 : 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: showIndex ? 30 : 12,
            child: showIndex
                ? Text(
                    '$index.',
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 5,
                  runSpacing: 5,
                  children: [
                    for (final tag in termTags)
                      _LookupChip(label: tag, kind: _ChipKind.tag),
                    for (final tag in definitionTags)
                      _LookupChip(label: tag, kind: _ChipKind.definition),
                  ],
                ),
                if (termTags.isNotEmpty || definitionTags.isNotEmpty)
                  const SizedBox(height: 4),
                DictionaryGlossary(
                  rawGlossary: glossary.glossary,
                  dictionaryName: glossary.dictName,
                  profile: profile,
                  dictionaryCss: styles[glossary.dictName] ?? '',
                  customCss: preferences.customCss,
                  fontSize: preferences.fontSize,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FrequencyAndPitchBlock extends StatelessWidget {
  const _FrequencyAndPitchBlock({
    required this.term,
    required this.preferences,
  });

  final HoshiTermResult term;
  final DictionaryPopupPreferences preferences;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 5,
      runSpacing: 5,
      children: [
        if (preferences.showFrequencyHarmonic && term.frequencies.isNotEmpty)
          _LookupChip(
            label:
                'harmonic ${_frequencyHarmonic(term.frequencies).toStringAsFixed(1)}',
            kind: _ChipKind.frequency,
          ),
        if (preferences.showFrequencyAverage && term.frequencies.isNotEmpty)
          _LookupChip(
            label:
                'average ${_frequencyAverage(term.frequencies).toStringAsFixed(1)}',
            kind: _ChipKind.frequency,
          ),
        for (final frequency in term.frequencies.take(6))
          _LookupChip(
            label: _frequencyEntryText(frequency),
            kind: _ChipKind.frequency,
          ),
        if (preferences.showPitchNumber || preferences.showPitchText)
          for (final pitch in term.pitches)
            _LookupChip(
              label: [
                pitch.dictName,
                if (preferences.showPitchNumber)
                  pitch.pitchPositions.join(', '),
                if (preferences.showPitchText) pitch.transcriptions.join(', '),
              ].where((value) => value.trim().isNotEmpty).join(' - '),
              kind: _ChipKind.pitch,
            ),
      ],
    );
  }
}

class _LookupChip extends StatelessWidget {
  const _LookupChip({required this.label, required this.kind});

  final String label;
  final _ChipKind kind;

  @override
  Widget build(BuildContext context) {
    final colors = _chipColors(context, kind);
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: colors.$1,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colors.$2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _EmptyLookupState extends StatelessWidget {
  const _EmptyLookupState({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
      child: Center(child: Text(text, textAlign: TextAlign.center)),
    );
  }
}

class _LookupPayload {
  const _LookupPayload({
    required this.results,
    required this.styles,
    required this.preferences,
    required this.profile,
  });

  factory _LookupPayload.empty(
    DictionaryPopupPreferences preferences,
    DictionaryProfile profile,
  ) {
    return _LookupPayload(
      results: const [],
      styles: const {},
      preferences: preferences,
      profile: profile,
    );
  }

  final List<HoshiLookupResult> results;
  final Map<String, String> styles;
  final DictionaryPopupPreferences preferences;
  final DictionaryProfile profile;
}

class _GlossaryGroup {
  const _GlossaryGroup({required this.dictionaryName, required this.entries});

  final String dictionaryName;
  final List<HoshiGlossaryEntry> entries;
}

@visibleForTesting
Set<String> initiallyExpandedDictionaries({
  required DictionaryProfile profile,
  required Iterable<String> dictionaries,
}) {
  final available = dictionaries.toSet();
  final ordered = <String>[
    for (final name in profile.dictionaryOrder)
      if (available.remove(name)) name,
    ...available,
  ];
  return switch (profile.dictionaryCollapseMode) {
    'collapse_all' => <String>{},
    'expand_first_available' => ordered.isEmpty ? <String>{} : {ordered.first},
    'custom' => _customExpandedDictionaries(
      ordered,
      profile.dictionaryDisplayModes,
    ),
    _ => ordered.toSet(),
  };
}

Set<String> _customExpandedDictionaries(
  List<String> ordered,
  Map<String, String> displayModes,
) {
  final expanded = <String>{};
  var contentOpened = false;
  for (final name in ordered) {
    final mode = displayModes[name] ?? 'fallback';
    if (mode == 'always_collapsed') continue;
    if (mode == 'always_expanded' || !contentOpened) {
      expanded.add(name);
      contentOpened = true;
    }
  }
  return expanded;
}

List<_GlossaryGroup> _groupGlossariesByDictionary(
  List<HoshiGlossaryEntry> glossaries,
) {
  final grouped = <String, List<HoshiGlossaryEntry>>{};
  for (final glossary in glossaries) {
    grouped.putIfAbsent(glossary.dictName, () => []).add(glossary);
  }
  return [
    for (final entry in grouped.entries)
      _GlossaryGroup(dictionaryName: entry.key, entries: entry.value),
  ];
}

enum _ChipKind { tag, rule, definition, dictionary, trace, frequency, pitch }

ThemeData _popupTheme(
  ThemeData baseTheme,
  DictionaryThemePreference preference,
) {
  final baseScheme = baseTheme.colorScheme;
  final light = ThemeData.light().copyWith(
    colorScheme: ColorScheme.light(
      primary: baseScheme.primary,
      primaryContainer: baseScheme.primaryContainer,
      onPrimaryContainer: baseScheme.onPrimaryContainer,
      secondaryContainer: baseScheme.secondaryContainer,
      onSecondaryContainer: baseScheme.onSecondaryContainer,
      tertiaryContainer: baseScheme.tertiaryContainer,
      onTertiaryContainer: baseScheme.onTertiaryContainer,
      errorContainer: baseScheme.errorContainer,
      onErrorContainer: baseScheme.onErrorContainer,
    ),
  );
  final dark = ThemeData.dark().copyWith(
    colorScheme: ColorScheme.dark(
      surface: const Color(0xff1f1f1f),
      surfaceContainerHighest: const Color(0xff303134),
      onSurface: const Color(0xfff1f3f4),
      onSurfaceVariant: const Color(0xffbdc1c6),
      primary: baseScheme.primary,
      primaryContainer: baseScheme.primaryContainer,
      onPrimaryContainer: baseScheme.onPrimaryContainer,
      secondaryContainer: baseScheme.secondaryContainer,
      onSecondaryContainer: baseScheme.onSecondaryContainer,
      tertiaryContainer: baseScheme.tertiaryContainer,
      onTertiaryContainer: baseScheme.onTertiaryContainer,
      errorContainer: baseScheme.errorContainer,
      onErrorContainer: baseScheme.onErrorContainer,
    ),
    dividerColor: const Color(0xff343536),
    scaffoldBackgroundColor: const Color(0xff1f1f1f),
  );
  return switch (preference) {
    DictionaryThemePreference.light =>
      baseTheme.brightness == Brightness.light ? baseTheme : light,
    DictionaryThemePreference.dark => dark,
    DictionaryThemePreference.black => dark.copyWith(
      colorScheme: dark.colorScheme.copyWith(surface: Colors.black),
      scaffoldBackgroundColor: Colors.black,
    ),
    DictionaryThemePreference.system => baseTheme,
  };
}

(Color, Color) _chipColors(BuildContext context, _ChipKind kind) {
  final scheme = Theme.of(context).colorScheme;
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (kind) {
    _ChipKind.dictionary => (const Color(0xff9c59d1), Colors.white),
    _ChipKind.tag => (const Color(0xff2f8fbd), Colors.white),
    _ChipKind.rule => (
      dark ? const Color(0xff5f6368) : scheme.secondaryContainer,
      dark ? Colors.white : scheme.onSecondaryContainer,
    ),
    _ChipKind.definition => (
      dark ? const Color(0xff5f6368) : scheme.tertiaryContainer,
      dark ? Colors.white : scheme.onTertiaryContainer,
    ),
    _ChipKind.trace => (
      dark ? const Color(0xff3c4043) : scheme.surfaceContainerHighest,
      dark ? const Color(0xffe8eaed) : scheme.onSurfaceVariant,
    ),
    _ChipKind.frequency => (
      dark ? const Color(0xff3c4043) : scheme.primaryContainer,
      dark ? const Color(0xffe8eaed) : scheme.onPrimaryContainer,
    ),
    _ChipKind.pitch => (scheme.errorContainer, scheme.onErrorContainer),
  };
}

List<String> _splitTags(String value) {
  return _uniqueTags(
    value
        .split(RegExp(r'[\s,;]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty),
  );
}

List<String> _uniqueTags(Iterable<String> values) {
  final seen = <String>{};
  final result = <String>[];
  for (final value in values) {
    if (seen.add(value)) result.add(value);
  }
  return result;
}

String _frequencyEntryText(HoshiFrequencyEntry entry) {
  final values = entry.frequencies
      .map((frequency) {
        return frequency.displayValue.trim().isEmpty
            ? frequency.value.toString()
            : frequency.displayValue;
      })
      .where((value) => value.trim().isNotEmpty)
      .join(', ');
  if (values.isEmpty) return entry.dictName;
  return '${entry.dictName}: $values';
}

List<int> _frequencyValues(List<HoshiFrequencyEntry> entries) => entries
    .expand((entry) => entry.frequencies)
    .map((frequency) => frequency.value)
    .where((value) => value > 0)
    .toSet()
    .toList();

double _frequencyHarmonic(List<HoshiFrequencyEntry> entries) {
  final values = _frequencyValues(entries);
  if (values.isEmpty) return 0;
  return values.length /
      values.fold<double>(0, (sum, value) => sum + 1 / value);
}

double _frequencyAverage(List<HoshiFrequencyEntry> entries) {
  final values = _frequencyValues(entries);
  if (values.isEmpty) return 0;
  return values.reduce((a, b) => a + b) / values.length;
}
