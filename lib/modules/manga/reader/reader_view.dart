import 'dart:async';
import 'dart:io';

import 'package:photo_view/photo_view.dart';
import 'package:mangayomi/modules/widgets/error_state.dart';
import 'package:mangayomi/services/downloaded_chapter.dart';
import 'package:mangayomi/modules/manga/archive_reader/providers/archive_reader_providers.dart';
import 'package:mangayomi/modules/library/providers/file_scanner.dart';
import 'package:mangayomi/utils/platform_utils.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/modules/anime/widgets/desktop.dart';
import 'package:mangayomi/modules/manga/reader/mixins/reader_gestures.dart';
import 'package:mangayomi/modules/manga/reader/reader_eink_state.dart';
import 'package:mangayomi/modules/manga/reader/providers/crop_borders_provider.dart';
import 'package:mangayomi/modules/manga/reader/services/page_navigation_service.dart';
import 'package:mangayomi/modules/manga/reader/utils/double_page_layout.dart';
import 'package:mangayomi/modules/manga/reader/utils/reader_pointer_signals.dart';
import 'package:mangayomi/modules/manga/reader/mixins/reader_memory_management.dart';
import 'package:mangayomi/modules/manga/reader/widgets/double_page_view.dart';
import 'package:mangayomi/modules/manga/reader/widgets/reader_app_bar.dart';
import 'package:mangayomi/modules/manga/reader/widgets/reader_bottom_bar.dart';
import 'package:mangayomi/modules/manga/reader/widgets/reader_gesture_handler.dart';
import 'package:mangayomi/modules/manga/reader/widgets/reader_settings_modal.dart';
import 'package:mangayomi/modules/manga/reader/widgets/auto_scroll_button.dart';
import 'package:mangayomi/modules/manga/reader/widgets/page_indicator.dart';
import 'package:mangayomi/modules/manga/reader/widgets/image_actions_dialog.dart';
import 'package:mangayomi/modules/manga/reader/u_chap_data_preload.dart';
import 'package:mangayomi/modules/mining/widgets/reader_ocr_overlay.dart';
import 'package:mangayomi/modules/more/statistics/widgets/manga_stats_sheet.dart';
import 'package:mangayomi/services/statistics/manga_statistics_tracker.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';
import 'package:mangayomi/modules/more/settings/reader/providers/reader_state_provider.dart';
import 'package:mangayomi/utils/extensions/others.dart';
import 'package:mangayomi/utils/riverpod.dart';
import 'package:mangayomi/modules/manga/reader/providers/push_router.dart';
import 'package:mangayomi/services/get_chapter_pages.dart';
import 'package:mangayomi/services/chapter_cache.dart';
import 'package:mangayomi/repositories/chapter_repository.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';
import 'package:mangayomi/modules/manga/reader/providers/reader_controller_provider.dart';
import 'package:mangayomi/modules/more/settings/reader/reader_screen.dart';
import 'package:mangayomi/modules/manga/reader/providers/manga_reader_provider.dart';
import 'package:mangayomi/modules/manga/reader/image_view_webtoon.dart';
import 'package:mangayomi/modules/widgets/progress_center.dart';
import 'package:mangayomi/utils/system_ui.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

const _macosPagedWheelChannel = MethodChannel(
  'com.mangatan.reader/paged_wheel',
);

class MangaReaderView extends ConsumerStatefulWidget {
  final int chapterId;
  const MangaReaderView({super.key, required this.chapterId});

  @override
  ConsumerState<MangaReaderView> createState() => _MangaReaderViewState();
}

class _MangaReaderViewState extends ConsumerState<MangaReaderView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.invalidate(mangaReaderProvider(widget.chapterId));
    });
  }

  @override
  Widget build(BuildContext context) {
    final chapterData = ref.watch(mangaReaderProvider(widget.chapterId));

    return chapterData.when(
      loading: () => scaffoldWith(context, const ProgressCenter()),
      error: (error, _) {
        if (chapterData.isRefreshing || chapterData.isReloading) {
          return scaffoldWith(context, const ProgressCenter());
        }
        return scaffoldWith(
          context,
          ErrorState(
            detail: error.toString(),
            onRetry: () async {
              final chapter = await chapterRepository.findById(
                widget.chapterId,
              );
              if (!mounted) return;
              if (chapter != null) {
                await ChapterCache().remove(chapter);
                if (!mounted) return;
                ref.invalidate(getChapterPagesProvider(chapter: chapter));
              }
              ref.invalidate(mangaReaderProvider(widget.chapterId));
            },
          ),
        );
      },
      data: (data) {
        final chapter = data.chapter;
        final model = data.pages;

        if (model.pageUrls.isEmpty &&
            !(chapter.manga.value?.isLocalArchive ?? false)) {
          return scaffoldWith(
            context,
            const Center(child: Text('Error: no pages available')),
            restoreUi: true,
          );
        }

        return MangaChapterPageGallery(
          key: ObjectKey(model),
          chapter: chapter,
          chapterUrlModel: model,
        );
      },
    );
  }

  Widget scaffoldWith(
    BuildContext context,
    Widget body, {
    bool restoreUi = false,
  }) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(''),
        leading: BackButton(
          onPressed: () {
            if (restoreUi) {
              restoreSystemUI();
            }
            Navigator.of(context).pop();
          },
        ),
      ),
      body: body,
    );
  }
}

class MangaChapterPageGalleryState {
  static void setNavigatingToChapter() {
    _MangaChapterPageGalleryState._isNavigatingToChapter = true;
  }
}

class MangaChapterPageGallery extends ConsumerStatefulWidget {
  const MangaChapterPageGallery({
    super.key,
    required this.chapter,
    required this.chapterUrlModel,
  });
  final GetChapterPagesModel chapterUrlModel;

  final Chapter chapter;

  @override
  ConsumerState createState() {
    return _MangaChapterPageGalleryState();
  }
}

class _MangaChapterPageGalleryState
    extends ConsumerState<MangaChapterPageGallery>
    with
        TickerProviderStateMixin,
        WidgetsBindingObserver,
        ReaderMemoryManagement,
        PageNavigationMixin {
  late AnimationController _scaleAnimationController;
  late Animation<double> _animation;
  late VoidCallback _scaleAnimationListener;

  late ReaderController _readerController = ref.read(
    readerControllerProvider(chapter: chapter).notifier,
  );

  final ValueNotifier<bool> _isScrolling = ValueNotifier(false);
  Timer? _scrollIdleTimer;
  final Stopwatch _readingStopwatch = Stopwatch();
  final String _macosPagedWheelOwner = UniqueKey().toString();

  /// Chimahon-compatible immersion statistics for this reading session.
  late final MangaStatisticsTracker _statsTracker = MangaStatisticsTracker(
    mangaId: chapter.manga.value?.id ?? 0,
  );

  /// Rebuilt whenever the sheet is open so its live session values update.
  final ValueNotifier<int> _statsSheetRevision = ValueNotifier(0);

  /// Flag to prevent fullscreen from being disabled when navigating between
  /// chapters via pushReplacement. The old widget's dispose runs after the new
  /// widget is created, which would clobber the new reader's fullscreen state.
  static bool _isNavigatingToChapter = false;
  bool _backNavigationInProgress = false;

  @override
  void dispose() {
    ReaderEInkState.enabled.removeListener(_eInkChanged);
    _setMacosPagedWheelMode(false);
    WidgetsBinding.instance.removeObserver(this);
    _readingStopwatch.stop();
    _rebuildDetail.close();
    _animation.removeListener(_scaleAnimationListener);
    _scaleAnimationController.dispose();
    _failedToLoadImage.dispose();
    _autoScroll.value = false;
    _autoScroll.dispose();
    _autoScrollPage.dispose();
    _currentPageDisplayIndex.dispose();
    _scrollIdleTimer?.cancel();
    _isScrolling.dispose();
    _keyboardFocusNode.dispose();
    _itemPositionsListener.itemPositions.removeListener(_readProgressListener);
    _photoViewController.dispose();
    _photoViewScaleStateController.dispose();
    _extendedController.dispose();
    clearGestureDetailsCache();
    if (_isNavigatingToChapter) {
      _isNavigatingToChapter = false;
    } else if (isDesktop) {
      setFullScreen(value: false);
    } else {
      restoreSystemUI();
    }
    discordRpc?.showIdleText();
    final actualIdx = _pageViewToActualIndexSync(_currentIndex!);
    final index = pages[actualIdx].index;
    if (index != null) {
      // Persist the final page before starting the asynchronous history write.
      // Isar does not allow this synchronous write to overlap that transaction.
      _readerController.setPageIndex(
        _isDoublePageActiveSync ? index : _geCurrentIndex(index),
        true,
        _chapterUrlModel.pageUrls,
      );
    }
    unawaited(
      _readerController.setHistoryUpdate(
        elapsedSeconds: _readingStopwatch.elapsed.inSeconds,
      ),
    );
    disposePreloadManager();
    // Attribute the page still on screen before the OCR cache goes away.
    unawaited(
      _statsTracker.flush(
        charactersForPage: _charactersForPageIndex,
        incognito: _statsIncognito,
      ),
    );
    _statsSheetRevision.dispose();
    ReaderOcrState.cancelScan();
    _readerController.keepAliveLink?.close();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _readingStopwatch.stop();
      final actualIdx = _pageViewToActualIndex(_currentIndex!);
      final index = pages[actualIdx].index;
      if (index != null) {
        _readerController.setPageIndex(
          _isDoublePageActive ? index : _geCurrentIndex(index),
          true,
          _chapterUrlModel.pageUrls,
        );
      }
    } else if (state == AppLifecycleState.resumed) {
      _readingStopwatch.start();
    }
  }

  late final _autoScroll = ValueNotifier(
    _readerController.autoScrollValues().$1,
  );
  late final _autoScrollPage = ValueNotifier(_autoScroll.value);
  late GetChapterPagesModel _chapterUrlModel = widget.chapterUrlModel;

  late Chapter chapter = widget.chapter;

  final _failedToLoadImage = ValueNotifier<bool>(false);

  late final int _initialActualIndex = _readerController.getPageIndex();
  late final PageMode _initialPageMode = _readerController.getPageMode();
  late final ReaderMode _initialReaderMode = _readerController.getReaderMode();
  late final ReadingDirection _initialReadingDirection = _readerController
      .getReadingDirection();
  late int? _currentIndex =
      _initialPageMode.isDoublePage &&
          !_initialReaderMode.isHorizontalContinuous
      ? actualIndexToDoublePageView(_initialActualIndex, _initialPageMode)
      : _initialActualIndex;
  late final ValueNotifier<int> _currentPageDisplayIndex = ValueNotifier(
    _initialActualIndex,
  );

  late final ItemScrollController _itemScrollController =
      ItemScrollController();
  final ScrollOffsetController _pageOffsetController = ScrollOffsetController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();

  final StreamController<double> _rebuildDetail =
      StreamController<double>.broadcast();
  @override
  void initState() {
    super.initState();
    ReaderEInkState.enabled.addListener(_eInkChanged);
    unawaited(ReaderEInkState.initialize());
    _readingStopwatch.start();
    _scaleAnimationController = AnimationController(
      duration: _doubleTapAnimationDuration(),
      vsync: this,
    );
    _animation = Tween(begin: 1.0, end: 2.0).animate(
      CurvedAnimation(curve: Curves.ease, parent: _scaleAnimationController),
    );
    _scaleAnimationListener = () =>
        _photoViewController.scale = _animation.value;
    _animation.addListener(_scaleAnimationListener);
    _itemPositionsListener.itemPositions.addListener(_readProgressListener);
    initPageNavigation(
      itemScrollController: _itemScrollController,
      extendedController: _extendedController,
    );
    _initCurrentIndex();
    discordRpc?.showChapterDetails(ref, chapter);
    WidgetsBinding.instance.addObserver(this);
    _initWakelock();
  }

  void _eInkChanged() {
    if (mounted) setState(() {});
  }

  void _initWakelock() {
    final keepOn = isar.settings.getSync(227)!.keepScreenOnReader ?? true;
    if (keepOn) {
      WakelockPlus.enable();
    }
  }

  void _refreshMihonChapterPages() {
    if (!mounted) return;
    final chapterId = chapter.id;
    if (chapterId == null) return;
    _failedToLoadImage.value = false;
    ref.invalidate(getChapterPagesProvider(chapter: chapter));
    ref.invalidate(mangaReaderProvider(chapterId));
  }

  // final double _horizontalScaleValue = 1.0;
  bool _isNextChapterPreloading = false;
  int _prefetchSessionId = 0;
  // bool _isPrevChapterPreloading = false;

  /// Guard flag: suppresses [_readProgressListener] during scroll position
  /// adjustment after prepending previous-chapter pages.
  final bool _isAdjustingScroll = false; // TODO. The variable is never changed

  late int pagePreloadAmount = ref.read(pagePreloadAmountStateProvider);
  late bool _isBookmarked = _readerController.getChapterBookmarked();

  bool _isLastPageTransition = false;
  final _currentReaderMode = StateProvider<ReaderMode?>(() => null);
  final _currentReadingDirection = StateProvider<ReadingDirection?>(() => null);
  PageMode? _pageMode;
  bool _isView = false;
  final _keyboardFocusNode = FocusNode();

  /// Cached reader mode to safely access in dispose without ref.read()
  ReaderMode? _cachedReaderMode;
  Alignment _scalePosition = Alignment.center;
  final PhotoViewController _photoViewController = PhotoViewController();
  final PhotoViewScaleStateController _photoViewScaleStateController =
      PhotoViewScaleStateController();
  final List<int> _cropBorderCheckList = [];

  late final _extendedController = PageController(initialPage: _currentIndex!);
  final Map<int, GlobalKey<DoublePageViewState>> _pagedViewKeys = {};

  double get pixelRatio => View.of(context).devicePixelRatio;

  Size get size => View.of(context).physicalSize / pixelRatio;
  Alignment _computeAlignmentByTapOffset(Offset offset) {
    return Alignment(
      (offset.dx - size.width / 2) / (size.width / 2),
      (offset.dy - size.height / 2) / (size.height / 2),
    );
  }

  Axis _scrollDirection = Axis.vertical;
  bool _isReverseHorizontal = false;

  Color _backgroundColor(BuildContext context) => ReaderEInkState.enabled.value
      ? Colors.white
      : Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.9);

  Future<void> _setFullScreen({bool? value}) async {
    final target =
        value ??
        (isDesktop
            ? !await windowManager.isFullScreen()
            : !ref.read(fullScreenReaderStateProvider));
    if (isDesktop) {
      await setFullScreen(value: target);
    } else if (target) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    } else {
      restoreSystemUI();
    }
    ref.read(fullScreenReaderStateProvider.notifier).set(target);
  }

  /// Goes to either next or previous chapter
  ///
  /// The [next] parameter determines the navigation direction:
  /// - `true` -> navigate to next chapter
  /// - `false` -> navigate to previous chapter
  ///
  /// If the reader is already at the first or last chapter (depending on
  /// the direction), the method returns without navigating.
  void _goToChapter(bool next) {
    if (next && !_readerController.hasNextChapter) return;
    if (!next && !_readerController.hasPreviousChapter) return;
    _isNavigatingToChapter = true;
    pushReplacementMangaReaderView(
      context: context,
      chapter: next
          ? _readerController.getNextChapter()
          : _readerController.getPrevChapter(),
    );
  }

  Future<void> _showPagePreviews() async {
    final chapterPages = pages
        .where(
          (page) => page.chapter?.id == chapter.id && !page.isTransitionPage,
        )
        .toList(growable: false);
    if (chapterPages.isEmpty || !mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.72,
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 150,
              childAspectRatio: 0.68,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: chapterPages.length,
            itemBuilder: (context, index) {
              final page = chapterPages[index];
              return InkWell(
                onTap: () {
                  Navigator.pop(sheetContext);
                  var target = page.pageIndex ?? index;
                  if (_isDoublePageActive) {
                    target = _actualToPageViewIndex(target);
                  }
                  navigationService.jumpToPage(
                    index: target,
                    readerMode: ref.read(_currentReaderMode)!,
                  );
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainer,
                        border: Border.all(
                          color: Theme.of(context).dividerColor,
                        ),
                      ),
                      child: Image(
                        image: page.getImageProvider(ref, true),
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.broken_image_outlined),
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        width: double.infinity,
                        color: Colors.black.withValues(alpha: 0.68),
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(
                          '${index + 1}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final configuredBackgroundColor = ref.watch(backgroundColorStateProvider);
    final backgroundColor = ReaderEInkState.enabled.value
        ? BackgroundColor.white
        : configuredBackgroundColor;
    final fullScreenReader = ref.watch(fullScreenReaderStateProvider);
    final readerMode = ref.watch(_currentReaderMode);
    final readingDirection = ref.watch(_currentReadingDirection);
    if (readerMode == null || readingDirection == null) {
      return const SizedBox.shrink();
    }
    final bool isHorizontalContinuous = readerMode.isHorizontalContinuous;
    final ocrProgressTop = _isView
        ? ReaderAppBar.visibleHeight(fullScreenReader: fullScreenReader) + 12
        : 12.0;

    return ReaderKeyboardHandler(
      onPreviousPage: () => _handlePageNavigation(forward: false),
      onNextPage: () => _handlePageNavigation(forward: true),
      onBack: () => _goBack(context),
      onFullScreen: () => _setFullScreen(),
      onNextChapter: () => _goToChapter(true),
      onPreviousChapter: () => _goToChapter(false),
      onLookupTrigger: ReaderOcrState.handleLookupTriggerKey,
    ).wrapWithKeyboardListener(
      isReverseHorizontal: _isReverseHorizontal,
      focusNode: _keyboardFocusNode,
      child: NotificationListener<UserScrollNotification>(
        onNotification: (notification) {
          if (notification.direction == ScrollDirection.idle) {
            if (_isView) {
              _isViewFunction();
            }
          }

          return true;
        },
        child: Material(
          child: SafeArea(
            top: !fullScreenReader,
            bottom: false,
            child: ValueListenableBuilder(
              valueListenable: _failedToLoadImage,
              builder: (context, failedToLoadImage, child) {
                final readerStack = Stack(
                  children: [
                    readerMode.isContinuous
                        ? ImageViewWebtoon(
                            pages: pages,
                            itemScrollController: _itemScrollController,
                            scrollOffsetController: _pageOffsetController,
                            itemPositionsListener: _itemPositionsListener,
                            scrollDirection: isHorizontalContinuous
                                ? Axis.horizontal
                                : Axis.vertical,
                            minCacheExtent: isHorizontalContinuous
                                ? pagePreloadAmount * context.width(1)
                                : pagePreloadAmount * context.height(1),
                            initialScrollIndex: _currentIndex!,
                            physics: const ClampingScrollPhysics(),
                            onLongPressData: (data) => ImageActionsDialog.show(
                              context: context,
                              data: data,
                              manga: widget.chapter.manga.value!,
                              chapterName: widget.chapter.name!,
                            ),
                            onFailedToLoadImage: (value) {
                              // TODO: Handle failed image loading
                              // if (_failedToLoadImage.value != value &&
                              //     context.mounted) {
                              //   _failedToLoadImage.value = value;
                              // }
                            },
                            backgroundColor: backgroundColor,
                            isDoublePageMode:
                                (_pageMode?.isDoublePage ?? false) &&
                                !isHorizontalContinuous,
                            pageMode: _pageMode ?? PageMode.onePage,
                            isHorizontalContinuous: isHorizontalContinuous,
                            readerMode: ref.watch(_currentReaderMode)!,
                            readingDirection: readingDirection,
                            photoViewController: _photoViewController,
                            photoViewScaleStateController:
                                _photoViewScaleStateController,
                            scalePosition: _scalePosition,
                            onDoubleTapDown: (offset) => _toggleScale(offset),
                            onDoubleTap: () {},
                            webtoonSidePadding: ref.watch(
                              webtoonSidePaddingStateProvider,
                            ),
                            showPageGaps: ref.watch(showPageGapsStateProvider),
                            reverse:
                                isHorizontalContinuous &&
                                readingDirection.isRtl,
                            isScrolling: _isScrolling,
                            onRefreshMihonPages: _refreshMihonChapterPages,
                          )
                        : Material(
                            color: getBackgroundColor(backgroundColor),
                            shadowColor: getBackgroundColor(backgroundColor),
                            child: PageView.builder(
                              controller: _extendedController,
                              scrollDirection: _scrollDirection,
                              reverse:
                                  readerMode.isHorizontalPaged &&
                                  readingDirection.isRtl,
                              physics: const ClampingScrollPhysics(),
                              itemBuilder: (context, index) =>
                                  _buildPagedPhotoView(index, backgroundColor),
                              itemCount: _pageViewPageCount,
                              onPageChanged: _onPageChanged,
                            ),
                          ),
                    Consumer(
                      builder: (context, ref, child) {
                        final usePageTapZones = ref.watch(
                          usePageTapZonesStateProvider,
                        );
                        final navigationLayout = ref.watch(
                          readerNavigationLayoutStateProvider,
                        );
                        return ReaderGestureHandler(
                          usePageTapZones: usePageTapZones,
                          navigationLayout: navigationLayout,
                          isRTL: _isReverseHorizontal,
                          hasImageError: failedToLoadImage,
                          isContinuousMode: readerMode.isContinuous,
                          onToggleUI: _isViewFunction,
                          onPreviousPage: () =>
                              _handlePageNavigation(forward: false),
                          onNextPage: () =>
                              _handlePageNavigation(forward: true),
                          onDoubleTapDown: (position) => _toggleScale(position),
                          onDoubleTap: () {},
                          onSecondaryTapDown: (position) =>
                              _toggleScale(position),
                          onSecondaryTap: () {},
                        );
                      },
                    ),
                    ReaderAppBar(
                      chapter: chapter,
                      mangaName: _readerController.getMangaName(),
                      chapterTitle: _readerController.getChapterTitle(),
                      isVisible: _isView,
                      isBookmarked: _isBookmarked,
                      backgroundColor: _backgroundColor,
                      onBackPressed: () => Navigator.pop(context),
                      onBookmarkPressed: () {
                        _readerController.setChapterBookmarked();
                        setState(() {
                          _isBookmarked = !_isBookmarked;
                        });
                      },
                      onOcrPressed: _showCurrentPageOcr,
                      onStatsPressed: _showStatsSheet,
                      onWebViewPressed:
                          (chapter.manga.value!.isLocalArchive ?? false) ==
                              false
                          ? () async {
                              final data = await buildWebViewData(ref, chapter);
                              if (data == null || !context.mounted) return;
                              context.push("/mangawebview", extra: data);
                            }
                          : null,
                    ),
                    ReaderOcrProgressHud(top: ocrProgressTop),
                    ReaderBottomBar(
                      chapter: chapter,
                      isVisible: _isView,
                      hasPreviousChapter: _readerController.hasPreviousChapter,
                      hasNextChapter: _readerController.hasNextChapter,
                      onPreviousChapter: () => _goToChapter(false),
                      onNextChapter: () => _goToChapter(true),
                      onSliderChanged: (value, ref) {
                        _currentPageDisplayIndex.value = value;
                        ref
                            .read(currentIndexProvider(chapter).notifier)
                            .setCurrentIndex(value);
                      },
                      onSliderChangeEnd: (value) {
                        try {
                          final page = pages.firstWhere(
                            (element) =>
                                element.chapter == chapter &&
                                element.index == value,
                          );
                          int jumpIndex = page.pageIndex!;
                          // In double page mode, convert array index to page view index
                          if (_isDoublePageActive) {
                            jumpIndex = _actualToPageViewIndex(jumpIndex);
                          }
                          navigationService.jumpToPage(
                            index: jumpIndex,
                            readerMode: ref.read(_currentReaderMode)!,
                          );
                        } catch (_) {}
                      },
                      onReaderModeChanged: (mode, ref) {
                        ref.read(_currentReaderMode.notifier).state = mode;
                        _setReaderMode(mode, ref);
                      },
                      onReadingDirectionChanged: (direction, ref) {
                        ref.read(_currentReadingDirection.notifier).state =
                            direction;
                        _setReadingDirection(direction, ref);
                      },
                      onPageModeToggle: () async {
                        final readerMode = ref.read(_currentReaderMode);
                        if (!(readerMode?.isHorizontalContinuous ?? false)) {
                          // Get the actual page index being viewed
                          final actualIdx = _pageViewToActualIndex(
                            _currentIndex!,
                          );
                          final newPageMode = _nextPageMode(_pageMode);
                          final targetIndex = newPageMode.isDoublePage
                              ? _actualToViewIndexForMode(
                                  actualIdx,
                                  readerMode: readerMode!,
                                  pageMode: newPageMode,
                                )
                              : actualIdx;
                          _readerController.setPageMode(newPageMode);
                          navigationService.jumpToPage(
                            index: targetIndex,
                            readerMode: ref.read(_currentReaderMode)!,
                          );
                          if (mounted) {
                            setState(() {
                              _pageMode = newPageMode;
                            });
                          }
                        }
                      },
                      onSettingsPressed: () => ReaderSettingsModal.show(
                        context: context,
                        vsync: this,
                        currentReaderModeProvider: _currentReaderMode,
                        currentReadingDirectionProvider:
                            _currentReadingDirection,
                        autoScroll: _autoScroll,
                        autoScrollPage: _autoScrollPage,
                        pageOffset: _pageOffset,
                        onAutoPageScroll: _autoPagescroll,
                        onReaderModeChanged: (mode, widgetRef) {
                          widgetRef.read(_currentReaderMode.notifier).state =
                              mode;
                          _setReaderMode(mode, widgetRef);
                        },
                        onReadingDirectionChanged: (direction, widgetRef) {
                          widgetRef
                                  .read(_currentReadingDirection.notifier)
                                  .state =
                              direction;
                          _setReadingDirection(direction, widgetRef);
                        },
                        onAutoScrollSave: (enabled, offset) {
                          _readerController.setAutoScroll(enabled, offset);
                        },
                        onFullScreenToggle: () {
                          final fullScreen = ref.read(
                            fullScreenReaderStateProvider,
                          );
                          _setFullScreen(value: !fullScreen);
                        },
                      ),
                      onPagePreviewsPressed: _showPagePreviews,
                      currentReaderModeProvider: _currentReaderMode,
                      currentReadingDirectionProvider: _currentReadingDirection,
                      currentPageListenable: _currentPageDisplayIndex,
                      currentPageMode: _pageMode,
                      isReverseHorizontal: _isReverseHorizontal,
                      totalPages: _readerController.getPageLength(
                        _chapterUrlModel.pageUrls,
                      ),
                      currentIndexLabel: _currentIndexLabel,
                      backgroundColor: _backgroundColor,
                    ),
                    PageIndicator(
                      isUiVisible: _isView,
                      currentPageListenable: _currentPageDisplayIndex,
                      totalPages: _readerController.getPageLength(
                        _chapterUrlModel.pageUrls,
                      ),
                      formatCurrentIndex: _currentIndexLabel,
                    ),
                    ReaderAutoScrollButton(
                      isContinuousMode: readerMode.isContinuous,
                      isUiVisible: _isView,
                      autoScrollPage: _autoScrollPage,
                      autoScroll: _autoScroll,
                      onToggle: () {
                        _autoPagescroll();
                        _autoScroll.value = !_autoScroll.value;
                      },
                    ),
                  ],
                );
                return readerMode.isContinuous
                    ? readerStack
                    : ReaderPointerSignalInterceptor(
                        onPointerSignal: _handlePagedPointerSignal,
                        child: readerStack,
                      );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPagedPhotoView(int index, BackgroundColor backgroundColor) {
    final pageList = _usesTransitionAwarePagedSpreads
        ? _pagedSpreadIndices(_pageMode ?? PageMode.doublePage)[index]
              .map(
                (actualIndex) =>
                    actualIndex == null ? null : pages[actualIndex],
              )
              .toList()
        : <UChapDataPreload?>[pages[index]];

    return DoublePageView.paged(
      key: _pagedViewKeys.putIfAbsent(
        index,
        () => GlobalKey<DoublePageViewState>(),
      ),
      pages: pageList,
      readingDirection:
          ref.read(_currentReadingDirection) ?? ReadingDirection.leftToRight,
      backgroundColor: backgroundColor,
      onFailedToLoadImage: (val) {
        if (_failedToLoadImage.value != val && mounted) {
          _failedToLoadImage.value = val;
        }
      },
      onRefreshMihonPages: _refreshMihonChapterPages,
      onLongPressData: (data) {
        ImageActionsDialog.show(
          context: context,
          data: data,
          manga: widget.chapter.manga.value!,
          chapterName: widget.chapter.name!,
        );
      },
    );
  }

  Future<void> _handlePageNavigation({required bool forward}) async {
    final readerMode = ref.read(_currentReaderMode);
    final animatePageTransitions = ref.read(
      animatePageTransitionsStateProvider,
    );
    if (readerMode == null || _currentIndex == null) return;

    if (readerMode.isContinuous) {
      final isHorizontal = readerMode.isHorizontalContinuous;
      final viewportSize = MediaQuery.sizeOf(context);
      final dimension = isHorizontal ? viewportSize.width : viewportSize.height;
      final offset = dimension * 0.60 * (forward ? 1 : -1);
      final duration = animatePageTransitions
          ? const Duration(milliseconds: 160)
          : const Duration(milliseconds: 10);
      _pageOffsetController.animateScroll(
        offset: offset,
        duration: duration,
        curve: Curves.easeInOut,
      );
      return;
    }

    if (await MiningPreferences.getPanelNavigationEnabled()) {
      final viewIndex = _extendedController.hasClients
          ? (_extendedController.page?.round() ?? _currentIndex ?? 0)
          : (_currentIndex ?? 0);
      try {
        final handled = await _pagedViewKeys[viewIndex]?.currentState
            ?.navigatePanel(forward: forward);
        if (handled ?? false) return;
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Panel detection failed: $error')),
          );
        }
      }
    }

    if (forward) {
      navigationService.nextPage(
        readerMode: readerMode,
        currentIndex: _currentIndex!,
        maxPages: _pageViewPageCount,
        animate: animatePageTransitions,
      );
    } else {
      navigationService.previousPage(
        readerMode: readerMode,
        currentIndex: _currentIndex!,
        animate: animatePageTransitions,
      );
    }
  }

  void _handlePagedPointerSignal(PointerSignalEvent event) {
    final viewIndex = _extendedController.hasClients
        ? (_extendedController.page?.round() ?? _currentIndex ?? 0)
        : (_currentIndex ?? 0);
    final zoomState = _pagedViewKeys[viewIndex]?.currentState;
    if (zoomState?.registerModifierWheelZoom(event) ?? false) {
      return;
    }

    registerPagedReaderWheelScroll(
      event,
      onPreviousPage: () => _handlePagedWheelNavigation(forward: false),
      onNextPage: () => _handlePagedWheelNavigation(forward: true),
    );
  }

  void _handlePagedWheelNavigation({required bool forward}) {
    final readerMode = ref.read(_currentReaderMode);
    if (readerMode == null || readerMode.isContinuous) return;

    final currentIndex = _extendedController.hasClients
        ? (_extendedController.page?.round() ?? _currentIndex ?? 0)
        : (_currentIndex ?? 0);
    final targetIndex = (currentIndex + (forward ? 1 : -1)).clamp(
      0,
      _pageViewPageCount - 1,
    );
    if (targetIndex == currentIndex) return;

    // Wheel notches are discrete input. Jumping avoids an in-flight page
    // animation consuming subsequent rapid notches.
    navigationService.jumpToPage(index: targetIndex, readerMode: readerMode);
  }

  Duration? _doubleTapAnimationDuration() {
    int doubleTapAnimationValue = isar.settings
        .getSync(227)!
        .doubleTapAnimationSpeed!;
    if (doubleTapAnimationValue == 0) {
      return const Duration(milliseconds: 10);
    } else if (doubleTapAnimationValue == 1) {
      return const Duration(milliseconds: 800);
    }
    return const Duration(milliseconds: 200);
  }

  void _readProgressListener() async {
    if (_isAdjustingScroll) return;
    final itemPositions = _itemPositionsListener.itemPositions.value;
    if (itemPositions.isEmpty) return;
    final previousIndex = _currentIndex;
    _currentIndex = itemPositions.first.index;
    final pageChanged = previousIndex != _currentIndex;
    if (!_isScrolling.value) _isScrolling.value = true;
    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) _isScrolling.value = false;
    });
    final currentReaderMode = ref.read(_currentReaderMode);
    final pagesLength =
        ((_pageMode?.isDoublePage ?? false) &&
            !(currentReaderMode?.isHorizontalContinuous ?? false))
        ? _pagedSpreadIndices(_pageMode!).length
        : pages.length;
    if (_currentIndex! >= 0 && _currentIndex! < pagesLength) {
      final actualIndex = _pageViewToActualIndex(_currentIndex!);
      if (actualIndex < 0 || actualIndex >= pages.length) return;
      if (_readerController.chapter.id != pages[actualIndex].chapter!.id) {
        if (mounted) {
          setState(() {
            _readerController = ref.read(
              readerControllerProvider(chapter: pages[actualIndex].chapter!)
                  .notifier,
            );

            chapter = pages[actualIndex].chapter!;
            final chapterUrlModel = pages[actualIndex].chapterUrlModel;

            if (chapterUrlModel != null) {
              _chapterUrlModel = chapterUrlModel;
            }

            _isBookmarked = _readerController.getChapterBookmarked();
          });
        }
      }

      // ── Next-chapter preloading: trigger when near the end ──
      final lastActualIndex = _pageViewToActualIndex(itemPositions.last.index);
      final distToEnd = pages.length - 1 - lastActualIndex;
      if (distToEnd <= pagePreloadAmount && !_isLastPageTransition) {
        _triggerNextChapterPreload();
      }

      // // ── Previous-chapter preloading: trigger when near the start ──
      // if (itemPositions.first.index <= pagePreloadAmount) {
      //   _triggerPrevChapterPreload();
      // }

      final idx = pages[actualIndex].index;
      if (idx != null) {
        _currentPageDisplayIndex.value = idx;
        _readerController.setPageIndex(
          _isDoublePageActive ? idx : _geCurrentIndex(idx),
          false,
          _chapterUrlModel.pageUrls,
        );
        ref.read(currentIndexProvider(chapter).notifier).setCurrentIndex(idx);
      }
      if (pageChanged) await _handleEvictionsAndPrefetch();
    }
  }

  void _addLastPageTransition(Chapter chap) {
    if (_isLastPageTransition) return;
    try {
      if (!mounted || pageCount == 0) return;
      if (pages.last.isLastChapter ?? false) return;

      final added = addLastChapterTransition(chap);
      if (added && mounted) {
        setState(() {
          _isLastPageTransition = true;
        });
      }
    } catch (_) {}
  }

  void _preloadNextChapter(GetChapterPagesModel chapterData, Chapter chap) {
    try {
      if (chapterData.uChapDataPreload.isEmpty || !mounted) return;

      final firstChapter = chapterData.uChapDataPreload.first.chapter;
      if (firstChapter == null) return;

      // Use mixin's method for memory-bounded preloading with auto-eviction
      preloadNextChapter(chapterData, chap)
          .then((success) {
            if (success && mounted) {
              setState(() {});
            }
          })
          // Preloading is opportunistic; the chapter loads normally on entry.
          .catchError((_) {});
    } catch (_) {}
  }

  // bidirectional proactive chapter preloading ──

  /// Proactively starts loading both adjacent chapters at reader init.
  void _proactivePreload() {
    _triggerNextChapterPreload();
    // _triggerPrevChapterPreload();
  }

  /// Fires off next-chapter page fetching if not already in progress.
  void _triggerNextChapterPreload() async {
    if (_isNextChapterPreloading || _isLastPageTransition) return;
    _isNextChapterPreloading = true;
    try {
      if (!mounted) {
        _isNextChapterPreloading = false;
        return;
      }
      final nextChapter = _readerController.getNextChapter();
      if (isChapterLoaded(nextChapter)) {
        _isNextChapterPreloading = false;
        return;
      }
      final value = await ref.read(
        getChapterPagesProvider(chapter: nextChapter).future,
      );
      if (mounted) {
        _preloadNextChapter(value, chapter);
      }
      _isNextChapterPreloading = false;
    } on RangeError {
      _isNextChapterPreloading = false;
      _addLastPageTransition(chapter);
    } catch (_) {
      _isNextChapterPreloading = false;
    }
  }
  // TODO: Need more optimization
  // /// Fires off previous-chapter page fetching and prepends pages.
  // void _triggerPrevChapterPreload() async {
  //   if (_isPrevChapterPreloading) return;
  //   _isPrevChapterPreloading = true;
  //   try {
  //     if (!mounted) return;
  //     final prevChapter = _readerController.getPrevChapter();
  //     if (isChapterLoaded(prevChapter)) {
  //       _isPrevChapterPreloading = false;
  //       return;
  //     }
  //     final value = await ref.read(
  //       getChapterPagesProvider(chapter: prevChapter).future,
  //     );
  //     if (mounted) {
  //       _handlePrevChapterPrepended(value, chapter);
  //     }
  //   } on RangeError {
  //     // No previous chapter — nothing to prepend
  //   } catch (_) {}
  //   _isPrevChapterPreloading = false;
  // }

  // /// Prepends previous-chapter pages and adjusts scroll position to avoid jump.
  // void _handlePrevChapterPrepended(
  //   GetChapterPagesModel chapterData,
  //   Chapter chap,
  // ) {
  //   try {
  //     if (chapterData.uChapDataPreload.isEmpty || !mounted) return;

  //     // Record the CURRENT visible top index BEFORE prepending
  //     final currentVisibleItems = _itemPositionsListener.itemPositions.value;
  //     final oldTopIndex = currentVisibleItems.isNotEmpty
  //         ? currentVisibleItems.first.index
  //         : _currentIndex ?? 0;

  //     preloadPreviousChapter(chapterData, chap).then((prependCount) {
  //       if (prependCount > 0 && mounted) {
  //         _isAdjustingScroll = true;

  //         // New index = old visible index + how many items we just prepended
  //         final newIndex = oldTopIndex + prependCount;

  //         // In double page mode, _currentIndex stores the page view index,
  //         // so convert the prepended page count to page view units.
  //         if (_isDoublePageActive) {
  //           // Recompute the page view index from the new actual index.
  //           final oldActual = _pageViewToActualIndex(oldTopIndex);
  //           final newActual = oldActual + prependCount;
  //           _currentIndex = _actualToPageViewIndex(newActual);
  //         } else {
  //           _currentIndex = newIndex;
  //         }
  //         setState(() {});
  //         WidgetsBinding.instance.addPostFrameCallback((_) {
  //           if (mounted) {
  //             if (_isContinuousMode()) {
  //               _itemScrollController.jumpTo(index: newIndex);
  //             } else if (_extendedController.hasClients) {
  //               _extendedController.jumpToPage(_currentIndex!);
  //             }
  //             _isAdjustingScroll = false;
  //           }
  //         });
  //       }
  //     });
  //   } catch (_) {}
  // }

  Future<void> _showCurrentPageOcr() async {
    await ReaderOcrState.handleOcrButton();
  }

  /// Opens the immersion statistics sheet for this manga.
  Future<void> _showStatsSheet() async {
    final estimate = await _statsEstimate();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => ValueListenableBuilder<int>(
        valueListenable: _statsSheetRevision,
        builder: (context, _, _) => MangaStatsSheet(
          mangaId: chapter.manga.value?.id ?? 0,
          session: _statsTracker.session,
          estimate: estimate,
          onToggleTracking: () {
            _statsTracker.toggleTracking();
            _statsSheetRevision.value++;
          },
        ),
      ),
    );
  }

  /// Projects time-to-finish from the session's reading speed.
  ///
  /// Remaining characters are estimated from the already-OCRed pages' average
  /// rather than measured, because pages ahead have not been recognized yet.
  Future<MangaStatsEstimate> _statsEstimate() async {
    final speed = _statsTracker.session.charactersPerHour;
    if (speed <= 0) return const MangaStatsEstimate();

    final actualIndex = _pageViewToActualIndex(_currentIndex ?? 0);
    final chapterPages = pages
        .where((page) => page.chapter?.id == chapter.id)
        .toList();
    var recognizedPages = 0;
    var recognizedCharacters = 0;
    for (final page in chapterPages) {
      final characters = await ReaderOcrState.cachedCharacterCount(page);
      if (characters > 0) {
        recognizedPages++;
        recognizedCharacters += characters;
      }
    }
    // With nothing recognized there is no basis for a per-page estimate.
    if (recognizedPages == 0) return const MangaStatsEstimate();
    final averagePerPage = recognizedCharacters / recognizedPages;

    final chapterRemainingPages =
        (chapterPages.length - _chapterPageOffset(actualIndex) - 1)
            .clamp(0, chapterPages.length)
            .toInt();
    final bookRemainingPages = (pages.length - actualIndex - 1)
        .clamp(0, pages.length)
        .toInt();
    final chapterCharacters = (averagePerPage * chapterRemainingPages).round();
    final bookCharacters = (averagePerPage * bookRemainingPages).round();

    return MangaStatsEstimate(
      remainingChapterCharacters: chapterCharacters,
      remainingBookCharacters: bookCharacters,
      remainingChapterSeconds: MangaStatsEstimate.secondsRemaining(
        chapterCharacters,
        speed,
      ),
      remainingBookSeconds: MangaStatsEstimate.secondsRemaining(
        bookCharacters,
        speed,
      ),
    );
  }

  /// Index of [actualIndex] within its own chapter's pages.
  int _chapterPageOffset(int actualIndex) {
    var offset = 0;
    for (var i = 0; i < actualIndex && i < pages.length; i++) {
      if (pages[i].chapter?.id == chapter.id) offset++;
    }
    return offset;
  }

  void _initCurrentIndex() async {
    if (ref.read(cropBordersStateProvider)) _processCropBorders();
    final readerMode = _readerController.getReaderMode();
    _currentPageDisplayIndex.value = _readerController.getPageIndex();

    // Initialize the preload manager with bounded memory (from ReaderMemoryManagement mixin)
    initializePreloadManager(
      _chapterUrlModel,
      onPagesUpdated: () {
        if (mounted) {
          setState(() {});
          if (ref.read(cropBordersStateProvider)) _processCropBorders();
        }
      },
    );

    _scanCurrentChapterOcr(actualIndex: _readerController.getPageIndex());

    // Kick off ordered prefetch before the first frame so lower-indexed pages
    // win the HTTP race against the simultaneous widget-driven loads.
    _prefetchPagesInOrder(); // intentionally not awaited

    // proactively start loading adjacent chapters in background
    _proactivePreload();

    await _readerController.setHistoryUpdate();
    // Use post-frame callback instead of Future.delayed(1ms) timing hack
    await Future(() {});
    final fullScreenReader = ref.watch(fullScreenReaderStateProvider);
    if (fullScreenReader) {
      if (isDesktop) {
        await setFullScreen(value: true);
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
      }
    }
    ref.read(_currentReaderMode.notifier).state = readerMode;
    ref.read(_currentReadingDirection.notifier).state =
        _initialReadingDirection;
    _isReverseHorizontal = _initialReadingDirection.isRtl;
    if (mounted) {
      setState(() {
        _pageMode = _readerController.getPageMode();
      });
    }
    _setReaderMode(readerMode, ref, persist: false);

    if (!readerMode.isVerticalContinuous) {
      _autoScroll.value = false;
    }
    _autoPagescroll();
    if (_readerController.getPageLength(_chapterUrlModel.pageUrls) == 1 &&
        (readerMode.isHorizontalPaged ||
            readerMode == ReaderMode.verticalPaged)) {
      _onPageChanged(0);
    }
  }

  void _scanCurrentChapterOcr({int? actualIndex}) {
    if (!mounted || pages.isEmpty) return;
    final startActualIndex =
        (actualIndex ?? _pageViewToActualIndex(_currentIndex ?? 0))
            .clamp(0, pages.length - 1)
            .toInt();
    final startPage = pages[startActualIndex];
    final chapterPages = pages
        .where((page) => page.chapter?.id == chapter.id)
        .toList();
    if (chapterPages.isEmpty) return;
    var startIndex = chapterPages.indexWhere(
      (page) =>
          identical(page, startPage) ||
          (page.pageIndex != null && page.pageIndex == startPage.pageIndex),
    );
    if (startIndex < 0) startIndex = 0;
    unawaited(
      ReaderOcrState.scanChapter(
        chapterPages,
        startIndex: startIndex,
        preparePage: (page) async {
          if (!mounted) return;
          await precacheImage(page.getImageProvider(ref, true), context);
        },
      ),
    );
  }

  /// Warms Flutter's [ImageCache] in page order before the widget tree renders.
  ///
  /// [ScrollablePositionedList] builds all items within [minCacheExtent] in a
  /// single frame, firing every network request simultaneously, which means
  /// pages complete in arbitrary (server-response) order.  By resolving each
  /// provider sequentially here — starting before that first frame — we seed
  /// the cache so that earlier pages win the HTTP race: lower-indexed pages
  /// start their requests first and are therefore ready sooner.
  ///
  /// For pages already within the cache extent the widget will attach to the
  /// already-pending Future (Flutter deduplicates by provider key), so no
  /// extra requests are made.  Pages beyond the cache extent are fetched
  /// strictly one at a time in reading order, so the reader never sees a
  /// later page appear before an earlier one.
  ///
  /// This is fully async — [await] inside a fire-and-forget call — so the
  /// UI stays interactive throughout.
  Future<void> _checkAndReloadEvictedPages(Chapter currentChapter) async {
    if (!preloadManager.isChapterEvicted(currentChapter)) return;

    final chapterId = currentChapter.id;
    bool needsReload = false;
    for (final page in pages) {
      if (page.chapter?.id == chapterId &&
          !page.isTransitionPage &&
          page.isLocale == true &&
          page.archiveImage == null &&
          page.localImagePath == null) {
        needsReload = true;
        break;
      }
    }

    if (needsReload) {
      final isLocalArchive = (currentChapter.archivePath ?? '').isNotEmpty;
      final archivePath = isLocalArchive
          ? await resolveLocalArchivePath(currentChapter.archivePath!)
          : (await findDownloadedChapter(currentChapter))?.archive?.path;

      if (archivePath != null && await File(archivePath).exists()) {
        try {
          final local = await ref.read(
            getArchiveDataFromFileProvider(archivePath).future,
          );
          final images = local.images ?? [];
          int imgIdx = 0;
          for (final page in pages) {
            if (page.chapter?.id == currentChapter.id &&
                !page.isTransitionPage) {
              if (imgIdx < images.length) {
                page.archiveImage = images[imgIdx].image;
              }
              imgIdx++;
            }
          }
          preloadManager.markChapterAsLoaded(currentChapter);
          if (mounted) {
            setState(() {});
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint('Error reloading evicted chapter pages: $e');
          }
        }
      }
    }
  }

  Future<void> _prefetchPagesInOrder() async {
    final sessionId = ++_prefetchSessionId;
    final startIdx = _pageViewToActualIndex(_currentIndex ?? 0)
        .clamp(0, pages.length - 1);

    final preloadAmount = ref.read(pagePreloadAmountStateProvider);
    final forwardLimit = (startIdx + preloadAmount).clamp(0, pages.length - 1);
    final backwardLimit = (startIdx - 2).clamp(0, pages.length - 1);

    final indices = [
      for (var i = startIdx; i <= forwardLimit; i++) i,
      for (var i = startIdx - 1; i >= backwardLimit; i--) i,
    ];

    final queue = List<int>.from(indices);

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        if (sessionId != _prefetchSessionId || !mounted) return;
        final i = queue.removeAt(0);
        final page = pages[i];
        if (page.isTransitionPage) continue;
        try {
          await precacheImage(page.getImageProvider(ref, true), context);
        } catch (_) {
          // Swallow errors: network failures, widget disposal, etc.
        }
      }
    }

    await Future.wait([worker(), worker(), worker()]);
  }

  Future<void> _onPageChanged(int index) async {
    // In non-continuous double page mode, convert page view index to actual
    // pages array index for correct lookups.
    final int actualIndex = _pageViewToActualIndex(index);
    final int prevActualIndex = _pageViewToActualIndex(_currentIndex!);
    final cropBorders = ref.watch(cropBordersStateProvider);
    if (cropBorders) {
      _processCropBordersByIndex(actualIndex);
    }
    final idx = pages[prevActualIndex].index;
    if (idx != null) {
      _readerController.setPageIndex(
        _isDoublePageActive ? idx : _geCurrentIndex(idx),
        false,
        _chapterUrlModel.pageUrls,
      );
    }
    if (_readerController.chapter.id != pages[actualIndex].chapter!.id) {
      if (mounted) {
        setState(() {
          _readerController = ref.read(
            readerControllerProvider(chapter: pages[actualIndex].chapter!)
                .notifier,
          );
          chapter = pages[actualIndex].chapter!;
          final chapterUrlModel = pages[actualIndex].chapterUrlModel;
          if (chapterUrlModel != null) {
            _chapterUrlModel = chapterUrlModel;
          }
          _isBookmarked = _readerController.getChapterBookmarked();
        });
      }
    }
    // Reset zoom of the previous page so user can swipe back freely (#443).
    clearGestureDetailsCache();
    _currentIndex = index;
    if (pages[actualIndex].index != null) {
      _currentPageDisplayIndex.value = pages[actualIndex].index!;
      ref
          .read(currentIndexProvider(chapter).notifier)
          .setCurrentIndex(pages[actualIndex].index!);
    }

    // ── Next-chapter preloading: trigger when near the end ──
    final distToEnd = pages.length - 1 - actualIndex;
    if (distToEnd <= pagePreloadAmount && !_isLastPageTransition) {
      _triggerNextChapterPreload();
    }

    // // ── Previous-chapter preloading: trigger when near the start ──
    // if (actualIndex <= pagePreloadAmount) {
    //   _triggerPrevChapterPreload();
    // }

    await _handleEvictionsAndPrefetch();
    _scanCurrentChapterOcr(actualIndex: actualIndex);
    unawaited(_trackStatsForPage(actualIndex));
  }

  Future<void> _handleEvictionsAndPrefetch() async {
    await _checkAndReloadEvictedPages(chapter);

    final evictedIndices = preloadManager.evictOldChapters(chapter);
    for (final evictedIdx in evictedIndices) {
      _cropBorderCheckList.remove(evictedIdx);
    }

    _prefetchPagesInOrder();
  }

  /// Records the page just left into immersion statistics.
  Future<void> _trackStatsForPage(int actualIndex) async {
    await _statsTracker.onPageChanged(
      pageIndex: actualIndex,
      charactersForPage: _charactersForPageIndex,
      incognito: _statsIncognito,
    );
    if (mounted) _statsSheetRevision.value++;
  }

  /// OCR character count for a page, or zero if it has not been recognized.
  Future<int> _charactersForPageIndex(int actualIndex) async {
    if (actualIndex < 0 || actualIndex >= pages.length) return 0;
    return ReaderOcrState.cachedCharacterCount(pages[actualIndex]);
  }

  bool get _statsIncognito =>
      isar.settings.getSync(227)?.incognitoMode ?? false;

  late final _pageOffset = ValueNotifier(
    _readerController.autoScrollValues().$2,
  );

  void _autoPagescroll() async {
    if (_isContinuousMode()) {
      for (int i = 0; i < 1; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (!_autoScroll.value) {
          return;
        }
        _pageOffsetController.animateScroll(
          offset: _pageOffset.value,
          duration: const Duration(milliseconds: 100),
        );
      }
      _autoPagescroll();
    }
  }

  void _toggleScale(Offset tapPosition) {
    if (mounted) {
      setState(() {
        if (_scaleAnimationController.isAnimating) {
          return;
        }

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
  }

  void _setReaderMode(
    ReaderMode value,
    WidgetRef ref, {
    bool persist = true,
  }) async {
    _setMacosPagedWheelMode(!value.isContinuous);
    if (!value.isVerticalContinuous) {
      _autoScroll.value = false;
    } else if (_autoScrollPage.value) {
      _autoPagescroll();
      _autoScroll.value = true;
    }

    _failedToLoadImage.value = false;
    if (persist) _readerController.setReaderMode(value);

    // Cache the reader mode for safe access in dispose
    _cachedReaderMode = value;

    final actualIndex = _pageViewToActualIndex(_currentIndex!);
    ref.read(_currentReaderMode.notifier).state = value;
    if (!mounted) return;
    setState(() {
      if (value == ReaderMode.verticalPaged) {
        _scrollDirection = Axis.vertical;
      } else if (value.isHorizontalPaged) {
        _scrollDirection = Axis.horizontal;
      }
    });
    // Wait for the next frame so the scroll view rebuilds
    await WidgetsBinding.instance.endOfFrame;
    final viewIndex = _actualToViewIndexForMode(
      actualIndex,
      readerMode: value,
      pageMode: _pageMode,
    );
    _currentIndex = viewIndex;

    if (value == ReaderMode.verticalPaged || value.isHorizontalPaged) {
      _extendedController.jumpToPage(viewIndex);
    } else {
      _itemScrollController.scrollTo(
        index: viewIndex,
        duration: const Duration(milliseconds: 1),
        curve: Curves.ease,
      );
    }
    _scanCurrentChapterOcr(actualIndex: actualIndex);
  }

  void _setReadingDirection(ReadingDirection value, WidgetRef ref) async {
    final readerMode = ref.read(_currentReaderMode);
    if (readerMode == null) return;

    final actualIndex = _pageViewToActualIndex(_currentIndex!);
    _readerController.setReadingDirection(value);
    ref.read(_currentReadingDirection.notifier).state = value;
    if (!mounted) return;
    setState(() {
      _isReverseHorizontal = value.isRtl;
    });

    await WidgetsBinding.instance.endOfFrame;
    final viewIndex = _actualToViewIndexForMode(
      actualIndex,
      readerMode: readerMode,
      pageMode: _pageMode,
    );
    _currentIndex = viewIndex;
    if (readerMode == ReaderMode.verticalPaged ||
        readerMode.isHorizontalPaged) {
      _extendedController.jumpToPage(viewIndex);
    } else {
      _itemScrollController.jumpTo(index: viewIndex);
    }
    _scanCurrentChapterOcr(actualIndex: actualIndex);
  }

  void _setMacosPagedWheelMode(bool enabled) {
    if (!Platform.isMacOS) return;
    unawaited(
      _macosPagedWheelChannel
          .invokeMethod<void>('setPagedReaderWheelMode', {
            'owner': _macosPagedWheelOwner,
            'enabled': enabled,
          })
          .catchError((_) {}),
    );
  }

  void _processCropBordersByIndex(int index) async {
    if (!_cropBorderCheckList.contains(index)) {
      _cropBorderCheckList.add(index);
      if (!mounted) return;
      final value = await ref.read(
        cropBordersProvider(data: pages[index], cropBorder: true).future,
      );
      if (mounted) {
        updatePageCropImage(index, value);
      }
    }
  }

  bool _isCropBordersProcessing = false;
  void _processCropBorders() async {
    if (_isCropBordersProcessing ||
        _cropBorderCheckList.length == pages.length) {
      return;
    }
    _isCropBordersProcessing = true;

    try {
      for (var i = 0; i < pages.length; i++) {
        if (!_cropBorderCheckList.contains(i)) {
          _cropBorderCheckList.add(i);
          if (!mounted) return;
          final value = await ref.read(
            cropBordersProvider(data: pages[i], cropBorder: true).future,
          );
          if (mounted) {
            updatePageCropImage(i, value);
          }
        }
      }
    } finally {
      _isCropBordersProcessing = false;
    }
  }

  void _goBack(BuildContext context) {
    if (_backNavigationInProgress) return;
    _backNavigationInProgress = true;
    restoreSystemUI();
    Navigator.pop(context);
  }

  void _isViewFunction() {
    final fullScreenReader = ref.watch(fullScreenReaderStateProvider);
    if (context.mounted) {
      setState(() {
        _isView = !_isView;
      });
    }
    if (fullScreenReader) {
      if (_isView) {
        restoreSystemUI();
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
      }
    }
  }

  PageMode _nextPageMode(PageMode? current) {
    return switch (current) {
      PageMode.onePage || null => PageMode.doublePage,
      PageMode.doublePage => PageMode.doublePageCover,
      PageMode.doublePageCover => PageMode.onePage,
    };
  }

  String _currentIndexLabel(int index) {
    final pageMode = _pageMode ?? PageMode.onePage;
    if (!pageMode.isDoublePage) {
      return "${index + 1}";
    }
    int pageLength = _readerController.getPageLength(_chapterUrlModel.pageUrls);
    return doublePageActualIndexLabel(index, pageLength, pageMode);
  }

  int _geCurrentIndex(int index) {
    return index;
  }

  /// Whether double page mode is active (continuous or paged).
  /// Horizontal continuous mode does NOT use double page layout.
  /// Uses ref.read() so cannot be called during dispose.
  bool get _isDoublePageActive =>
      (_pageMode?.isDoublePage ?? false) &&
      !(ref.read(_currentReaderMode)?.isHorizontalContinuous ?? false);

  /// Safe version of _isDoublePageActive that uses cached reader mode.
  /// Safe to call during dispose without Riverpod assertion errors.
  bool get _isDoublePageActiveSync =>
      (_pageMode?.isDoublePage ?? false) &&
      !(_cachedReaderMode?.isHorizontalContinuous ?? false);

  bool get _usesTransitionAwarePagedSpreads => _isDoublePageActive;

  bool get _usesTransitionAwarePagedSpreadsSync => _isDoublePageActiveSync;

  List<List<int?>> _pagedSpreadIndices(PageMode pageMode) {
    return transitionAwareDoublePageSpreadIndices(
      pages.length,
      pageMode,
      isTransitionPage: (index) => pages[index].isTransitionPage,
    );
  }

  /// Converts a page view index (from ExtendedPageController) to the actual
  /// index in the [pages] array for double page mode.
  int _pageViewToActualIndex(int pageViewIndex) {
    if (!_isDoublePageActive) return pageViewIndex;
    if (_usesTransitionAwarePagedSpreads) {
      final spreads = _pagedSpreadIndices(_pageMode ?? PageMode.doublePage);
      if (spreads.isEmpty) return 0;
      return spreads[pageViewIndex.clamp(0, spreads.length - 1)].first!;
    }
    return doublePageViewToActualIndex(
      pageViewIndex,
      pages.length,
      _pageMode ?? PageMode.doublePage,
    );
  }

  /// Safe version that uses cached reader mode for use in dispose.
  int _pageViewToActualIndexSync(int pageViewIndex) {
    if (!_isDoublePageActiveSync) return pageViewIndex;
    if (_usesTransitionAwarePagedSpreadsSync) {
      final spreads = _pagedSpreadIndices(_pageMode ?? PageMode.doublePage);
      if (spreads.isEmpty) return 0;
      return spreads[pageViewIndex.clamp(0, spreads.length - 1)].first!;
    }
    return doublePageViewToActualIndex(
      pageViewIndex,
      pages.length,
      _pageMode ?? PageMode.doublePage,
    );
  }

  /// Converts an actual [pages] array index to a page view index
  /// for double page mode.
  int _actualToPageViewIndex(int actualIndex) {
    if (!_isDoublePageActive) return actualIndex;
    if (_usesTransitionAwarePagedSpreads) {
      final spreads = _pagedSpreadIndices(_pageMode ?? PageMode.doublePage);
      final viewIndex = spreads.indexWhere(
        (spread) => spread.contains(actualIndex),
      );
      return viewIndex < 0 ? 0 : viewIndex;
    }
    return actualIndexToDoublePageView(
      actualIndex,
      _pageMode ?? PageMode.doublePage,
    );
  }

  int _actualToViewIndexForMode(
    int actualIndex, {
    required ReaderMode readerMode,
    required PageMode? pageMode,
  }) {
    if (pages.isEmpty) return 0;
    final isDoublePage =
        (pageMode?.isDoublePage ?? false) && !readerMode.isHorizontalContinuous;
    if (!isDoublePage) return actualIndex.clamp(0, pages.length - 1).toInt();
    final spreads = _pagedSpreadIndices(pageMode!);
    if (spreads.isEmpty) return 0;
    final viewIndex = spreads.indexWhere(
      (spread) => spread.contains(actualIndex),
    );
    return (viewIndex < 0 ? 0 : viewIndex).clamp(0, spreads.length - 1).toInt();
  }

  /// Total page count as seen by the page view controller.
  /// In double page mode, each page view entry maps to a spread.
  int get _pageViewPageCount {
    if (!_isDoublePageActive) return pages.length;
    final pageMode = _pageMode ?? PageMode.doublePage;
    if (_usesTransitionAwarePagedSpreads) {
      return _pagedSpreadIndices(pageMode).length;
    }
    return doublePageViewCount(pages.length, pageMode);
  }

  bool _isContinuousMode([ReaderMode? mode]) {
    final readerMode = mode ?? ref.read(_currentReaderMode);
    return readerMode!.isContinuous;
  }
}
