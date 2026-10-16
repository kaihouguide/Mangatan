import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:extended_image/extended_image.dart';
import 'package:mangayomi/modules/manga/reader/providers/reader_controller_provider.dart';
import 'package:mangayomi/modules/manga/reader/u_chap_data_preload.dart';
import 'package:mangayomi/modules/manga/reader/widgets/color_filter_widget.dart';
import 'package:mangayomi/modules/mining/widgets/reader_ocr_overlay.dart';
import 'package:mangayomi/modules/more/settings/reader/providers/reader_state_provider.dart';
import 'package:mangayomi/utils/extensions/others.dart';

class ImageViewPaged extends ConsumerStatefulWidget {
  final UChapDataPreload data;
  final Function(UChapDataPreload data) onLongPressData;
  final Widget? Function(ExtendedImageState state) loadStateChanged;
  final Function(ExtendedImageGestureState state)? onDoubleTap;
  final GestureConfig Function(ExtendedImageState state)?
  initGestureConfigHandler;
  final bool normalizeOcrPaintCoordinates;
  final bool enableGestures;
  const ImageViewPaged({
    super.key,
    required this.data,
    required this.onLongPressData,
    required this.loadStateChanged,
    this.onDoubleTap,
    this.initGestureConfigHandler,
    this.normalizeOcrPaintCoordinates = false,
    this.enableGestures = true,
  });

  @override
  ConsumerState<ImageViewPaged> createState() => _ImageViewPagedState();
}

class _ImageViewPagedState extends ConsumerState<ImageViewPaged> {
  final GlobalKey _imageKey = GlobalKey();
  late ReaderOcrController _ocr = ReaderOcrController(
    widget.data,
    imageKey: _imageKey,
  )..addListener(_repaint);

  void _repaint() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _imageKey.currentContext?.findRenderObject()?.markNeedsPaint();
    });
  }

  @override
  void didUpdateWidget(covariant ImageViewPaged oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.data, widget.data)) {
      _ocr
        ..removeListener(_repaint)
        ..dispose();
      _ocr = ReaderOcrController(widget.data, imageKey: _imageKey)
        ..addListener(_repaint);
    }
  }

  @override
  void dispose() {
    _ocr
      ..removeListener(_repaint)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _ocr.updateTheme(Theme.of(context).colorScheme.primary);
    final scaleType = ref.watch(scaleTypeStateProvider);
    final image = widget.data.getImageProvider(ref, true);
    final (colorBlendMode, color) = chapterColorFIlterValues(context, ref);
    final needsScaleOverride =
        widget.enableGestures &&
        (scaleType == ScaleType.fitWidth || scaleType == ScaleType.fitHeight);
    final effectiveFit = needsScaleOverride
        ? BoxFit.contain
        : getBoxFit(scaleType);

    GestureConfig Function(ExtendedImageState)? effectiveGestureHandler;
    if (!widget.enableGestures) {
      effectiveGestureHandler = null;
    } else if (needsScaleOverride) {
      effectiveGestureHandler = (ExtendedImageState state) {
        final base = widget.initGestureConfigHandler?.call(state);
        double initScale = base?.initialScale ?? 1.0;
        InitialAlignment alignment =
            base?.initialAlignment ?? InitialAlignment.center;
        final info = state.extendedImageInfo;
        if (info != null) {
          final imgW = info.image.width.toDouble();
          final imgH = info.image.height.toDouble();
          final viewSize = MediaQuery.of(context).size;
          final viewAspect = viewSize.width / viewSize.height;
          final imgAspect = imgW / imgH;
          if (scaleType == ScaleType.fitWidth && imgAspect < viewAspect) {
            initScale = viewAspect / imgAspect;
            alignment = InitialAlignment.topCenter;
          } else if (scaleType == ScaleType.fitHeight &&
              imgAspect > viewAspect) {
            initScale = imgAspect / viewAspect;
            alignment = InitialAlignment.centerLeft;
          }
        }
        return GestureConfig(
          minScale: base?.minScale ?? 0.8,
          speed: base?.speed ?? 1,
          initialScale: initScale,
          initialAlignment: alignment,
          inertialSpeed: base?.inertialSpeed ?? 200,
          inPageView: base?.inPageView ?? true,
          maxScale: base?.maxScale ?? 8,
          animationMinScale: base?.animationMinScale,
          animationMaxScale: base?.animationMaxScale ?? 8,
          cacheGesture: base?.cacheGesture ?? true,
          hitTestBehavior: base?.hitTestBehavior ?? HitTestBehavior.translucent,
          reverseMousePointerScrollDirection:
              base?.reverseMousePointerScrollDirection ?? true,
        );
      };
    } else {
      effectiveGestureHandler = widget.initGestureConfigHandler;
    }

    Rect? ocrHitTestImageRect(Rect paintedRect) {
      if (!widget.normalizeOcrPaintCoordinates) return null;
      final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return null;
      return readerOcrHitTestImageRect(
        paintedImageRect: paintedRect,
        renderBoxSize: box.size,
        normalizePaintCoordinates: true,
      );
    }

    return applyReaderColorFilter(
      GestureDetector(
        onLongPress: () => widget.onLongPressData.call(widget.data),
        child: ExtendedImage(
          key: _imageKey,
          image: image,
          colorBlendMode: colorBlendMode,
          color: color,
          fit: effectiveFit,
          filterQuality: FilterQuality.medium,
          mode: widget.enableGestures
              ? ExtendedImageMode.gesture
              : ExtendedImageMode.none,
          handleLoadingProgress: true,
          loadStateChanged: (state) {
            if (state.extendedImageLoadState == LoadState.completed) {
              // ExtendedImage invokes this callback while it is building.
              // Starting OCR synchronously notifies this widget that loading
              // began, which would call setState during that same build.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _ocr.load();
              });
            }
            return widget.loadStateChanged(state);
          },
          initGestureConfigHandler: effectiveGestureHandler,
          onDoubleTap: widget.enableGestures ? widget.onDoubleTap : null,
          afterPaintImage: (canvas, rect, image, paint) {
            _ocr.paint(
              canvas,
              rect,
              image,
              paint,
              hitTestImageRect: ocrHitTestImageRect(rect),
            );
          },
        ),
      ),
      ref,
    );
  }
}
