import 'package:extended_image/extended_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:mangayomi/eval/mihon/image_proxy.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/modules/manga/reader/image_view_paged.dart';
import 'package:mangayomi/modules/manga/reader/utils/reader_colors.dart';
import 'package:mangayomi/modules/manga/reader/utils/reader_pointer_signals.dart';
import 'package:mangayomi/modules/manga/reader/u_chap_data_preload.dart';
import 'package:mangayomi/modules/manga/reader/widgets/circular_progress_indicator_animate_rotate.dart';
import 'package:mangayomi/modules/manga/reader/widgets/transition_view_paged.dart';
import 'package:mangayomi/modules/manga/reader/widgets/transition_view_vertical.dart';
import 'package:mangayomi/modules/more/settings/reader/reader_screen.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/services/reader/panel_detection_service.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';
import 'package:mangayomi/utils/extensions/others.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'dart:async';
import 'package:mangayomi/repositories/settings_repository.dart';

/// Unified double page view for both paged and continuous reading modes.
///
/// This replaces both `DoubleColummView` and `DoubleColummVerticalView`
/// to eliminate code duplication (previously ~80% identical code).
class DoublePageView extends StatefulWidget {
  /// The two pages to display side by side.
  final List<UChapDataPreload?> pages;

  /// Callback when an image is long-pressed.
  final Function(UChapDataPreload data)? onLongPressData;

  /// Background color setting.
  final BackgroundColor backgroundColor;

  /// Callback for image load failure state.
  final Function(bool)? onFailedToLoadImage;
  final VoidCallback? onRefreshMihonPages;

  /// Whether to use the paged mode (with PhotoView zoom) or vertical mode.
  ///
  /// - `true`: Paged mode with pinch-to-zoom support (uses PhotoViewGallery)
  /// - `false`: Vertical/Continuous mode (simple Column layout)
  final bool isPagedMode;

  /// Whether to add top padding for the first page (vertical mode only).
  final bool addTopPadding;

  /// Controls the left-to-right order of pages within a spread.
  final ReadingDirection readingDirection;

  const DoublePageView({
    super.key,
    required this.pages,
    required this.backgroundColor,
    this.onLongPressData,
    this.onFailedToLoadImage,
    this.onRefreshMihonPages,
    this.isPagedMode = true,
    this.addTopPadding = true,
    this.readingDirection = ReadingDirection.leftToRight,
  });

  /// Creates a paged mode double page view.
  const DoublePageView.paged({
    super.key,
    required this.pages,
    required this.backgroundColor,
    this.onLongPressData,
    this.onFailedToLoadImage,
    this.onRefreshMihonPages,
    this.readingDirection = ReadingDirection.leftToRight,
  }) : isPagedMode = true,
       addTopPadding = false;

  /// Creates a vertical/continuous mode double page view.
  const DoublePageView.vertical({
    super.key,
    required this.pages,
    required this.backgroundColor,
    this.onLongPressData,
    this.onFailedToLoadImage,
    this.onRefreshMihonPages,
    this.addTopPadding = true,
    this.readingDirection = ReadingDirection.leftToRight,
  }) : isPagedMode = false;

  @override
  State<DoublePageView> createState() => DoublePageViewState();
}

class DoublePageViewState extends State<DoublePageView>
    with TickerProviderStateMixin {
  // Controllers for paged mode zoom
  late AnimationController _scaleAnimationController;
  late Animation<double> _animation;
  late VoidCallback _animationListener;
  Alignment _scalePosition = Alignment.center;
  final PhotoViewController _photoViewController = PhotoViewController();
  final PhotoViewScaleStateController _photoViewScaleStateController =
      PhotoViewScaleStateController();
  List<Rect>? _panelStops;
  int _panelStopIndex = -1;
  Future<List<Rect>>? _panelDetection;

  Duration _doubleTapAnimationDuration() {
    final doubleTapAnimationValue =
        settingsRepository.current.doubleTapAnimationSpeed ?? 1;
    return switch (doubleTapAnimationValue) {
      0 => const Duration(milliseconds: 10),
      1 => const Duration(milliseconds: 800),
      _ => const Duration(milliseconds: 200),
    };
  }

  double get pixelRatio => View.of(context).devicePixelRatio;
  Size get size => View.of(context).physicalSize / pixelRatio;

  Alignment _computeAlignmentByTapOffset(Offset offset) {
    return Alignment(
      (offset.dx - size.width / 2) / (size.width / 2),
      (offset.dy - size.height / 2) / (size.height / 2),
    );
  }

  @override
  void initState() {
    super.initState();
    if (widget.isPagedMode) {
      _scaleAnimationController = AnimationController(vsync: this);
      _animation = Tween(begin: 1.0, end: 2.0).animate(
        CurvedAnimation(curve: Curves.ease, parent: _scaleAnimationController),
      );
      _animationListener = () {
        _photoViewController.scale = _animation.value;
      };
      _animation.addListener(_animationListener);
    }
  }

  @override
  void dispose() {
    if (widget.isPagedMode) {
      _animation.removeListener(_animationListener);
      _scaleAnimationController.dispose();
      _photoViewController.dispose();
      _photoViewScaleStateController.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DoublePageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_samePages(oldWidget.pages, widget.pages)) {
      _panelStops = null;
      _panelDetection = null;
      _panelStopIndex = -1;
    }
  }

  bool _samePages(List<UChapDataPreload?> a, List<UChapDataPreload?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  /// Focuses the next or previous detected panel. Returns false only when the
  /// reader should leave this page/spread.
  Future<bool> navigatePanel({required bool forward}) async {
    if (!widget.isPagedMode || !mounted) return false;
    final stops = _panelStops ??= await (_panelDetection ??= _detectPanels());
    if (!mounted || stops.isEmpty) return false;
    final target = forward
        ? _panelStopIndex + 1
        : (_panelStopIndex < 0 ? stops.length - 1 : _panelStopIndex - 1);
    if (target < 0 || target >= stops.length) {
      _panelStopIndex = -1;
      _photoViewScaleStateController.reset();
      return false;
    }
    _panelStopIndex = target;
    _focusPanel(stops[target]);
    return true;
  }

  Future<List<Rect>> _detectPanels() async {
    final pageData = widget.readingDirection.isRtl
        ? widget.pages.reversed.whereType<UChapDataPreload>().toList()
        : widget.pages.whereType<UChapDataPreload>().toList();
    final stops = <Rect>[];
    for (var pageIndex = 0; pageIndex < pageData.length; pageIndex++) {
      final bytes = await pageData[pageIndex].getImageBytes;
      if (bytes == null) continue;
      final detections = await PanelDetectionService.instance.detect(bytes);
      if (widget.readingDirection.isRtl) {
        detections.sort((a, b) {
          final rowDelta = a.rect.top - b.rect.top;
          if (rowDelta.abs() > .08) return rowDelta.sign.toInt();
          return b.rect.right.compareTo(a.rect.right);
        });
      }
      for (final detection in detections) {
        final rect = detection.rect;
        stops.add(
          Rect.fromLTRB(
            (pageIndex + rect.left) / pageData.length,
            rect.top,
            (pageIndex + rect.right) / pageData.length,
            rect.bottom,
          ),
        );
      }
    }
    return stops;
  }

  void _focusPanel(Rect panel) {
    final viewport = context.size ?? MediaQuery.sizeOf(context);
    final scale =
        (0.95 / panel.width < 0.95 / panel.height
                ? 0.95 / panel.width
                : 0.95 / panel.height)
            .clamp(1.0, 8.0)
            .toDouble();
    _photoViewController.value = PhotoViewControllerValue(
      position: Offset(
        (.5 - panel.center.dx) * viewport.width * scale,
        (.5 - panel.center.dy) * viewport.height * scale,
      ),
      scale: scale,
      rotation: 0,
      rotationFocusPoint: null,
    );
  }

  void _toggleScale(Offset tapPosition) {
    if (!widget.isPagedMode || !mounted) return;

    setState(() {
      if (_scaleAnimationController.isAnimating) return;
      _scaleAnimationController.duration = _doubleTapAnimationDuration();

      if (_photoViewController.scale == 1.0) {
        _scalePosition = _computeAlignmentByTapOffset(tapPosition);

        if (_scaleAnimationController.isCompleted) {
          _scaleAnimationController.reset();
        }

        _scaleAnimationController.forward();
        return;
      }

      if (_photoViewController.scale == 2.0) {
        _scaleAnimationController.reverse();
        return;
      }

      _photoViewScaleStateController.reset();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Check for transition pages
    if (_isTransitionPage()) {
      return _buildTransitionPage();
    }

    return widget.isPagedMode ? _buildPagedMode() : _buildVerticalMode();
  }

  bool _isTransitionPage() {
    return (widget.pages.isNotEmpty &&
            (widget.pages[0]?.isTransitionPage ?? false)) ||
        (widget.pages.length > 1 &&
            (widget.pages[1]?.isTransitionPage ?? false));
  }

  Widget _buildTransitionPage() {
    final transitionPage = widget.pages.firstWhere(
      (p) => p?.isTransitionPage ?? false,
      orElse: () => null,
    );

    if (transitionPage == null) return const SizedBox.shrink();

    return widget.isPagedMode
        ? TransitionViewPaged(data: transitionPage)
        : TransitionViewVertical(data: transitionPage);
  }

  Widget _buildPagedMode() {
    return LayoutBuilder(
      builder: (zoomContext, _) => PhotoViewGallery.builder(
        backgroundDecoration: const BoxDecoration(color: Colors.transparent),
        itemCount: 1,
        builder: (context, _) {
          return PhotoViewGalleryPageOptions.customChild(
            controller: _photoViewController,
            scaleStateController: _photoViewScaleStateController,
            basePosition: _scalePosition,
            minScale: readerMinimumZoomScale,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerSignal: (event) =>
                  registerModifierWheelZoom(event, zoomContext: zoomContext),
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onDoubleTapDown: (details) =>
                    _toggleScale(details.globalPosition),
                onDoubleTap: () {},
                child: _buildPageRow(),
              ),
            ),
          );
        },
      ),
    );
  }

  bool registerModifierWheelZoom(
    PointerSignalEvent event, {
    BuildContext? zoomContext,
  }) {
    return registerReaderModifierWheelZoom(
      event,
      zoomContext: zoomContext ?? context,
      photoViewController: _photoViewController,
      basePosition: _scalePosition,
    );
  }

  Widget _buildVerticalMode() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Add top padding for first page
        if (widget.addTopPadding && widget.pages[0]?.index == 0)
          SizedBox(height: MediaQuery.of(context).padding.top),
        _buildPageRow(),
      ],
    );
  }

  Widget _buildPageRow() {
    final pages = widget.readingDirection.isRtl
        ? widget.pages.reversed
        : widget.pages;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final page in pages)
          if (page != null) Flexible(child: _buildPageImage(page)),
      ],
    );
  }

  Widget _buildPageImage(UChapDataPreload pageData) {
    final l10n = l10nLocalizations(context)!;
    final onLongPress = widget.onLongPressData ?? (_) {};

    return ImageViewPaged(
      data: pageData,
      enableGestures: false,
      normalizeOcrPaintCoordinates: true,
      loadStateChanged: (state) {
        switch (state.extendedImageLoadState) {
          case LoadState.loading:
            return _buildLoadingState(state);
          case LoadState.completed:
            return _buildCompletedState(state);
          case LoadState.failed:
            return _buildFailedState(state, l10n, pageData);
        }
      },
      onLongPressData: onLongPress,
    );
  }

  Widget _buildLoadingState(ExtendedImageState state) {
    final loadingProgress = state.loadingProgress;
    final progress = loadingProgress?.expectedTotalBytes != null
        ? loadingProgress!.cumulativeBytesLoaded /
              loadingProgress.expectedTotalBytes!
        : 0.0;

    return Container(
      color: getBackgroundColor(widget.backgroundColor),
      height: context.height(0.8),
      child: CircularProgressIndicatorAnimateRotate(progress: progress),
    );
  }

  Widget? _buildCompletedState(ExtendedImageState state) {
    widget.onFailedToLoadImage?.call(false);
    return null;
  }

  Widget _buildFailedState(
    ExtendedImageState state,
    dynamic l10n,
    UChapDataPreload pageData,
  ) {
    widget.onFailedToLoadImage?.call(true);
    final backgroundColor =
        getBackgroundColor(widget.backgroundColor) ??
        Theme.of(context).scaffoldBackgroundColor;

    return Container(
      color: backgroundColor,
      height: context.height(0.8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            l10n.image_loading_error,
            style: TextStyle(
              color: readerErrorForegroundColor(backgroundColor),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: _buildRetryButton(state, l10n, pageData),
          ),
        ],
      ),
    );
  }

  Widget _buildRetryButton(
    ExtendedImageState state,
    dynamic l10n,
    UChapDataPreload pageData,
  ) {
    void retry() {
      widget.onFailedToLoadImage?.call(false);
      final url = pageData.pageUrl?.url;
      if (url != null &&
          isTransientMihonImageUrl(url) &&
          widget.onRefreshMihonPages != null) {
        widget.onRefreshMihonPages!();
        return;
      }
      state.reLoadImage();
    }

    return GestureDetector(
      onLongPress: retry,
      onTap: retry,
      child: Container(
        decoration: BoxDecoration(
          color: context.primaryColor,
          borderRadius: BorderRadius.circular(30),
        ),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Text(
          l10n.retry,
          style: TextStyle(color: Theme.of(context).colorScheme.onPrimary),
        ),
      ),
    );
  }
}
