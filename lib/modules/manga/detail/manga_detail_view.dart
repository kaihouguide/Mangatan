import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mangayomi/modules/manga/detail/tv/tv_anime_detail_view.dart';
import 'package:mangayomi/utils/platform_utils.dart';
import 'package:mangayomi/modules/manga/detail/widgets/anime_season_list.dart';

import 'package:mangayomi/services/download_manager/next_downloads.dart';

import 'package:draggable_menu/draggable_menu.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/eval/model/m_bridge.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/category.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/epub_book_progress.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/models/track.dart';
import 'package:mangayomi/models/track_preference.dart';
import 'package:mangayomi/models/track_search.dart';
import 'package:mangayomi/modules/library/library_screen.dart';
import 'package:mangayomi/modules/library/providers/library_filter_provider.dart';
import 'package:mangayomi/modules/library/providers/local_archive.dart';
import 'package:mangayomi/modules/manga/detail/providers/track_state_providers.dart';
import 'package:mangayomi/modules/manga/detail/widgets/tracker_search_widget.dart';
import 'package:mangayomi/modules/manga/detail/widgets/tracker_widget.dart';
import 'package:mangayomi/utils/chapter_recognition.dart';
import 'package:mangayomi/utils/extensions/manga_extensions.dart';
import 'package:mangayomi/utils/extensions/chapter_extensions.dart';
import 'package:mangayomi/modules/more/providers/algorithm_weights_state_provider.dart';
import 'package:mangayomi/modules/more/settings/appearance/providers/pure_black_dark_mode_state_provider.dart';
import 'package:mangayomi/modules/more/settings/track/widgets/track_listile.dart';
import 'package:mangayomi/modules/tracker_library/tracker_library_screen.dart';
import 'package:mangayomi/modules/widgets/bottom_select_bar.dart';
import 'package:mangayomi/modules/widgets/category_selection_dialog.dart';
import 'package:mangayomi/modules/widgets/custom_draggable_tabbar.dart';
import 'package:mangayomi/modules/widgets/custom_extended_image_provider.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/providers/storage_provider.dart';
import 'package:mangayomi/services/http/m_client.dart';
import 'package:mangayomi/services/get_chapter_pages.dart';
import 'package:mangayomi/services/mining/dictionary_profile_resolver.dart';
import 'package:mangayomi/modules/mining/widgets/reader_ocr_overlay.dart';
import 'package:mangayomi/modules/mining/widgets/ocr_processing_queue_sheet.dart';
import 'package:mangayomi/services/mining/ocr_processing_queue.dart';
import 'package:mangayomi/services/sync/chimahon_local_chapter_overlay_service.dart';
import 'package:mangayomi/services/sync/chimahon_local_chapter_policy.dart';
import 'package:mangayomi/services/sync/chimahon_novel_progress_adapter.dart';
import 'package:mangayomi/services/webview_url.dart';
import 'package:mangayomi/utils/riverpod.dart';
import 'package:mangayomi/utils/share.dart';
import 'package:mangayomi/utils/utils.dart';
import 'package:mangayomi/utils/cached_network.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';
import 'package:mangayomi/utils/extensions/others.dart';
import 'package:mangayomi/utils/global_style.dart';
import 'package:mangayomi/utils/headers.dart';
import 'package:mangayomi/modules/manga/detail/providers/isar_providers.dart';
import 'package:mangayomi/modules/manga/detail/providers/state_providers.dart';
import 'package:mangayomi/modules/manga/detail/chapter_bulk_actions.dart';
import 'package:mangayomi/modules/manga/detail/widgets/readmore.dart';
import 'package:mangayomi/modules/manga/detail/widgets/chapter_filter_list_tile_widget.dart';
import 'package:mangayomi/modules/manga/detail/widgets/chapter_list_tile_widget.dart';
import 'package:mangayomi/modules/manga/detail/widgets/chapter_sort_list_tile_widget.dart';
import 'package:mangayomi/modules/manga/download/providers/download_provider.dart';
import 'package:mangayomi/modules/mining/widgets/dictionary_profile_override_dialog.dart';
import 'package:mangayomi/modules/widgets/error_text.dart';
import 'package:mangayomi/modules/widgets/progress_center.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:share_plus/share_plus.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../../utils/constant.dart';

import 'package:path/path.dart' as p;
import 'package:isar_community/isar.dart';
import 'package:mangayomi/repositories/chapter_repository.dart';
import 'package:mangayomi/repositories/download_repository.dart';
import 'package:mangayomi/repositories/manga_repository.dart';
import 'package:mangayomi/repositories/track_repository.dart';
import 'package:mangayomi/utils/manga_cover_actions.dart';
import 'package:mangayomi/repositories/db_write_queue.dart';

class MangaDetailView extends ConsumerStatefulWidget {
  final Function(bool) isExtended;
  final Widget? titleDescription;
  final List<Color>? backButtonColors;
  final Widget? action;
  final Manga? manga;
  final bool sourceExist;
  final Function(bool) checkForUpdate;
  final ItemType itemType;

  const MangaDetailView({
    super.key,
    required this.isExtended,
    this.titleDescription,
    this.backButtonColors,
    this.action,
    required this.sourceExist,
    required this.manga,
    required this.checkForUpdate,
    required this.itemType,
  });

  @override
  ConsumerState<MangaDetailView> createState() => _MangaDetailViewState();
}

/// One action in the compact detail-page action strip.
class _DetailAction {
  const _DetailAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
}

/// Upstream's 0.9.2 action strip, retained alongside Mangatan's customized
/// detail page and tracker controls.
class _DetailActions extends ConsumerWidget {
  const _DetailActions({required this.manga});

  final Manga manga;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = l10nLocalizations(context)!;
    final recommendations = _DetailAction(
      icon: Icons.auto_awesome_outlined,
      label: l10n.recommendations,
      onPressed: () => context.push(
        '/recommendations',
        extra: (
          manga.name,
          manga.itemType,
          ref.read(algorithmWeightsStateProvider),
        ),
      ),
    );
    final related = _DetailAction(
      icon: Icons.account_tree_outlined,
      label: l10n.related_titles,
      onPressed: () =>
          context.push('/related', extra: (manga.name!, manga.itemType)),
    );

    if (manga.itemType != ItemType.anime) {
      return _strip(context, [recommendations, related]);
    }

    final watchOrder = _DetailAction(
      icon: Icons.format_list_numbered_outlined,
      label: l10n.watch_order,
      onPressed: () => context.push('/watchOrder', extra: (manga.name, null)),
    );
    return StreamBuilder<List<Track>>(
      stream: trackRepository.watchByMangaId(manga.id!),
      builder: (context, snapshot) {
        final tracks = snapshot.data ?? const <Track>[];
        final syncId = tracks.firstOrNull?.syncId;
        final supported =
            syncId == TrackerProviders.myAnimeList.syncId ||
            syncId == TrackerProviders.anilist.syncId;
        return _strip(context, [
          recommendations,
          related,
          watchOrder,
          if (tracks.isNotEmpty && supported)
            _DetailAction(
              icon: Icons.playlist_play_outlined,
              label: l10n.sequels,
              onPressed: () => context.push(
                '/watchOrder',
                extra: (manga.name, tracks.firstOrNull),
              ),
            ),
        ]);
      },
    );
  }

  Widget _strip(BuildContext context, List<_DetailAction> actions) {
    final outline = context.primaryColor.withValues(alpha: 0.35);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: outline),
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0)
                  VerticalDivider(width: 1, thickness: 1, color: outline),
                Expanded(child: _segment(context, actions[i])),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _segment(BuildContext context, _DetailAction action) {
    final accent = context.primaryColor;
    return InkWell(
      onTap: action.onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(action.icon, size: 20, color: accent),
            const SizedBox(height: 5),
            Text(
              action.label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MangaDetailViewState extends ConsumerState<MangaDetailView>
    with TickerProviderStateMixin {
  List<EpubBookProgress> _localNovelProgresses() {
    final mangaId = widget.manga?.id;
    if (mangaId == null || !isLocalArchive) return const [];
    return isar.epubBookProgress.filter().mangaIdEqualTo(mangaId).findAllSync();
  }

  Future<EpubBookProgress?> _selectLocalNovel(
    List<EpubBookProgress> books,
  ) async {
    if (books.length == 1) return books.first;
    if (books.isEmpty || !mounted) return null;
    return showDialog<EpubBookProgress>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Choose a book'),
        children: [
          for (final book in books)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, book),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(book.title),
                subtitle: book.author?.trim().isNotEmpty == true
                    ? Text(book.author!)
                    : null,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _setDictionaryProfile() async {
    final manga = widget.manga!;
    final mangaId = manga.id;
    if (mangaId == null) return;

    final localNovels = _localNovelProgresses();
    if (localNovels.isNotEmpty) {
      final localNovel = await _selectLocalNovel(localNovels);
      if (localNovel == null) return;
      const adapter = ChimahonNovelProgressAdapter();
      final novelId = adapter.stableLocalIdOrNull(localNovel);
      if (novelId == null || !mounted) return;
      await showDictionaryProfileOverrideDialog(
        context: context,
        overrideKey: DictionaryProfileResolver.novelOverrideKey(novelId),
        autoProfile: DictionaryProfileResolver.resolve(
          sourceLanguage: (localNovel.lang ?? '').trim().toLowerCase(),
        ),
        title: 'Dictionary profile for ${localNovel.title}',
      );
      return;
    }

    final source = manga.lang == null || manga.source == null
        ? null
        : getSource(manga.lang!, manga.source!, manga.sourceId);
    if (!mounted) return;
    await showDictionaryProfileOverrideDialog(
      context: context,
      overrideKey: DictionaryProfileResolver.mangaOverrideKey(mangaId),
      autoProfile: DictionaryProfileResolver.resolve(
        sourceId: DictionaryProfileResolver.overrideIdForSource(source),
        sourceLanguage: DictionaryProfileResolver.sourceLanguageForSource(
          source,
          fallback: manga.lang ?? '',
        ),
      ),
      title: 'Dictionary profile for this entry',
    );
  }

  Future<void> _preOcrSelectedChapters(List<Chapter> chapters) async {
    if (chapters.isEmpty) return;
    final container = ProviderScope.containerOf(context, listen: false);
    await ReaderOcrState.setEnabled(true);
    OcrProcessingQueueController.instance.enqueue(
      chapters.map(
        (chapter) => OcrQueueRequest(
          id: 'chapter:${chapter.id ?? identityHashCode(chapter)}',
          title: widget.manga!.name ?? 'Manga',
          subtitle: chapter.name ?? 'Chapter',
          operation: (onProgress) async {
            final result = await container.read(
              getChapterPagesProvider(chapter: chapter).future,
            );
            final pages = result.uChapDataPreload;
            if (pages.isEmpty) {
              throw StateError('No chapter pages were available for OCR');
            }
            await ReaderOcrState.preOcrChapters(
              [pages],
              onChapterProgress: (_, completed, total) {
                onProgress(completed, total);
              },
            );
          },
        ),
      ),
    );
    if (mounted) await showOcrProcessingQueueSheet(context);
  }

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController()
      ..addListener(() {
        ref.read(offetProvider.notifier).state = _scrollController.offset;
      });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// One-time notice (per screen open) when some chapters have no
  /// detectable number — sort/dedup can't place them reliably.
  void _notifyUnrecognizedChapterNumbers() {
    if (_shownUnrecognizedNotice) return;
    final count = widget.manga!.unrecognizedChapterNumberCount();
    if (count == 0) return;
    _shownUnrecognizedNotice = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final l10n = l10nLocalizations(context)!;
      botToast(l10n.unrecognized_chapter_numbers(count), second: 5);
    });
  }

  final offetProvider = StateProvider(() => 0.0);
  bool _expanded = false;
  bool _shownUnrecognizedNotice = false;
  late final ScrollController _scrollController;
  late final isLocalArchive = widget.manga!.isLocalArchive ?? false;

  @override
  Widget build(BuildContext context) {
    // On Android TV, anime gets a dedicated d-pad split detail (info left,
    // episodes or seasons right). Manga/novel and phones/desktop keep the
    // classic detail.
    if (isTv && widget.itemType == ItemType.anime) {
      return TvAnimeDetailView(manga: widget.manga!);
    }
    // Watch all sort/filter providers so the list rebuilds whenever
    // the user changes settings in _showDraggableMenu().
    ref.watch(scanlatorsFilterStateProvider(widget.manga!));
    ref.watch(sortChapterStateProvider(mangaId: widget.manga!.id!));
    ref.watch(chapterFilterUnreadStateProvider(mangaId: widget.manga!.id!));
    ref.watch(chapterFilterBookmarkedStateProvider(mangaId: widget.manga!.id!));
    ref.watch(chapterFilterDownloadedStateProvider(mangaId: widget.manga!.id!));
    final chapters = ref.watch(
      getChaptersStreamProvider(mangaId: widget.manga!.id!),
    );
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) return;
        // Reset chapter selection so the top/bottom bars don't bleed into the library screen
        ref.read(isLongPressedStateProvider.notifier).update(false);
        ref.read(chaptersListStateProvider.notifier).clear();
      },
      child: NotificationListener<UserScrollNotification>(
        onNotification: (notification) {
          if (notification.direction == ScrollDirection.forward) {
            widget.isExtended(true);
          }
          if (notification.direction == ScrollDirection.reverse) {
            widget.isExtended(false);
          }
          return true;
        },
        child: chapters.when(
          data: (chapterRows) {
            final chapters = widget.manga!.getSortedFilteredChapters(
              sourceChapters: chapterRows,
            );
            _notifyUnrecognizedChapterNumbers();
            return _buildWidget(chapters: chapters);
          },
          error: (Object error, StackTrace stackTrace) {
            return ErrorText(error);
          },
          loading: () {
            return _buildWidget(chapters: const <Chapter>[]);
          },
        ),
      ),
    );
  }

  Future<void> _downloadChaptersWithDestination(
    BuildContext context,
    List<Chapter> chapters,
  ) async {
    final chaptersToDownload = chapters.where((chapter) {
      final entry = downloadRepository.getByChapterId(chapter.id);
      return entry == null || !entry.isDownload!;
    }).toList();
    if (chaptersToDownload.isEmpty) return;

    for (final chapter in chaptersToDownload) {
      await downloadRepository.enqueue(chapter);
    }
    if (!mounted) return;
    ref.invalidate(processDownloadsProvider());
    ref.read(processDownloadsProvider());
  }

  Widget _buildWidget({required List<Chapter> chapters}) {
    final chapterList = ref.watch(chaptersListStateProvider);
    final isLongPressed = ref.watch(isLongPressedStateProvider);
    final chapterDisplayMode = ref
        .watch(sortChapterStateProvider(mangaId: widget.manga!.id!))
        .displayMode;
    final checkCategoryList = isar.categorys
        .filter()
        .idIsNotNull()
        .and()
        .forItemTypeEqualTo(widget.manga!.itemType)
        .isNotEmptySync();
    final seasonOverview = widget.manga!.hasSeasons;
    return Stack(
      children: [
        Consumer(
          builder: (context, ref, child) {
            return Positioned(
              top: 0,
              child: ref.watch(offetProvider) == 0.0
                  ? Stack(
                      children: [
                        widget.manga!.customCoverImage != null
                            ? Image.memory(
                                widget.manga!.customCoverImage as Uint8List,
                                width: context.width(1),
                                height: 300,
                                fit: BoxFit.cover,
                              )
                            : cachedNetworkImage(
                                headers: widget.manga!.isLocalArchive!
                                    ? null
                                    : ref.watch(
                                        headersProvider(
                                          source: widget.manga!.source!,
                                          lang: widget.manga!.lang!,
                                          sourceId: widget.manga!.sourceId,
                                        ),
                                      ),
                                imageUrl: toImgUrl(
                                  widget.manga!.customCoverFromTracker ??
                                      widget.manga!.imageUrl ??
                                      "",
                                ),
                                width: context.width(1),
                                height: 300,
                                fit: BoxFit.cover,
                              ),
                        Stack(
                          children: [
                            Column(
                              children: [
                                Container(
                                  width: context.width(1),
                                  height: AppBar().preferredSize.height,
                                  color: context.isTablet
                                      ? Theme.of(context)
                                            .scaffoldBackgroundColor
                                      : Theme.of(context)
                                            .scaffoldBackgroundColor
                                            .withValues(alpha: 0.9),
                                ),
                                Container(
                                  width: context.width(1),
                                  height: 465,
                                  color: context.isTablet
                                      ? Theme.of(context)
                                            .scaffoldBackgroundColor
                                      : Theme.of(context)
                                            .scaffoldBackgroundColor
                                            .withValues(alpha: 0.9),
                                ),
                              ],
                            ),
                            Positioned(
                              bottom: 0,
                              child: Container(
                                width: context.width(1),
                                height: 100,
                                color: Theme.of(context)
                                    .scaffoldBackgroundColor,
                              ),
                            ),
                          ],
                        ),
                      ],
                    )
                  : Container(),
            );
          },
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          extendBodyBehindAppBar: true,
          appBar: PreferredSize(
            preferredSize: Size.fromHeight(AppBar().preferredSize.height),
            child: Consumer(
              builder: (context, ref, child) {
                final l10n = l10nLocalizations(context)!;
                final isNotFiltering = ref.watch(
                  chapterFilterResultStateProvider(manga: widget.manga!),
                );
                return isLongPressed
                    ? Container(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        child: AppBar(
                          title: Text(chapterList.length.toString()),
                          backgroundColor: context.primaryColor.withValues(
                            alpha: 0.2,
                          ),
                          leading: IconButton(
                            onPressed: () {
                              ref
                                  .read(chaptersListStateProvider.notifier)
                                  .clear();

                              ref
                                  .read(isLongPressedStateProvider.notifier)
                                  .update(!isLongPressed);
                            },
                            icon: const Icon(Icons.clear),
                          ),
                          actions: [
                            IconButton(
                              onPressed: () {
                                for (var chapter in chapters) {
                                  ref
                                      .read(chaptersListStateProvider.notifier)
                                      .selectAll(chapter);
                                }
                              },
                              icon: const Icon(Icons.select_all),
                            ),
                            IconButton(
                              onPressed: () {
                                if (chapters.length == chapterList.length) {
                                  for (var chapter in chapters) {
                                    ref
                                        .read(
                                          chaptersListStateProvider.notifier,
                                        )
                                        .selectSome(chapter);
                                  }
                                  ref
                                      .read(isLongPressedStateProvider.notifier)
                                      .update(false);
                                } else {
                                  for (var chapter in chapters) {
                                    ref
                                        .read(
                                          chaptersListStateProvider.notifier,
                                        )
                                        .selectSome(chapter);
                                  }
                                }
                              },
                              icon: const Icon(Icons.flip_to_back_rounded),
                            ),
                          ],
                        ),
                      )
                    : AppBar(
                        title: ref.watch(offetProvider) > 200
                            ? Text(
                                widget.manga!.name!,
                                style: const TextStyle(fontSize: 17),
                              )
                            : null,
                        backgroundColor: ref.watch(offetProvider) == 0.0
                            ? Colors.transparent
                            : Theme.of(context).scaffoldBackgroundColor,
                        actions: [
                          if (!isLocalArchive) ...[
                            PopupMenuButton(
                              popUpAnimationStyle: popupAnimationStyle,
                              icon: const Icon(Icons.download_outlined),
                              tooltip: l10n.download,
                              itemBuilder: (context) {
                                return [
                                  PopupMenuItem<int>(
                                    value: 0,
                                    child: Text(
                                      widget.itemType != ItemType.anime
                                          ? context.l10n.next_chapter
                                          : context.l10n.next_episode,
                                    ),
                                  ),
                                  PopupMenuItem<int>(
                                    value: 1,
                                    child: Text(
                                      widget.itemType != ItemType.anime
                                          ? context.l10n.next_5_chapters
                                          : context.l10n.next_5_episodes,
                                    ),
                                  ),
                                  PopupMenuItem<int>(
                                    value: 2,
                                    child: Text(
                                      widget.itemType != ItemType.anime
                                          ? context.l10n.next_10_chapters
                                          : context.l10n.next_10_episodes,
                                    ),
                                  ),
                                  PopupMenuItem<int>(
                                    value: 3,
                                    child: Text(
                                      widget.itemType != ItemType.anime
                                          ? context.l10n.next_25_chapters
                                          : context.l10n.next_25_episodes,
                                    ),
                                  ),
                                  PopupMenuItem<int>(
                                    value: 4,
                                    child: Text(
                                      widget.itemType != ItemType.anime
                                          ? context.l10n.unread
                                          : context.l10n.unwatched,
                                    ),
                                  ),
                                  PopupMenuItem<int>(
                                    value: 5,
                                    child: Text(
                                      widget.itemType != ItemType.anime
                                          ? context.l10n.all_chapters
                                          : context.l10n.all_episodes,
                                    ),
                                  ),
                                ];
                              },
                              onSelected: (value) async {
                                final chapters = widget.manga!
                                    .getFilteredChapters();
                                final selected = value <= 3
                                    ? selectNextDownloads(
                                        chapters,
                                        count: [1, 5, 10, 25][value],
                                        downloads: downloadRepository.getAll(),
                                      )
                                    : chapters
                                          .where(
                                            (chapter) =>
                                                value == 5 ||
                                                chapter.isRead != true,
                                          )
                                          .toList();
                                await _downloadChaptersWithDestination(
                                  context,
                                  selected,
                                );
                              },
                            ),
                          ],
                          IconButton(
                            splashRadius: 20,
                            onPressed: () {
                              _showDraggableMenu();
                            },
                            icon: Icon(
                              Icons.filter_list_sharp,
                              color: isNotFiltering ? null : Colors.yellow,
                            ),
                          ),
                          PopupMenuButton(
                            popUpAnimationStyle: popupAnimationStyle,
                            itemBuilder: (context) {
                              return [
                                if (!isLocalArchive)
                                  PopupMenuItem<int>(
                                    value: 0,
                                    child: Text(l10n.refresh),
                                  ),
                                if (widget.manga!.isVisibleInLibrary &&
                                    checkCategoryList)
                                  PopupMenuItem<int>(
                                    value: 1,
                                    child: Text(l10n.set_categories),
                                  ),
                                if (widget.manga!.isVisibleInLibrary ||
                                    _localNovelProgresses().isNotEmpty)
                                  const PopupMenuItem<int>(
                                    value: 7,
                                    child: Text('Set dictionary profile'),
                                  ),
                                if (!isLocalArchive)
                                  PopupMenuItem<int>(
                                    value: 2,
                                    child: Text(l10n.share),
                                  ),
                                PopupMenuItem<int>(
                                  value: 3,
                                  child: Text(l10n.migrate),
                                ),
                                PopupMenuItem<int>(
                                  value: 6,
                                  child: const Text('Mass migration'),
                                ),
                                if (!isLocalArchive)
                                  PopupMenuItem<int>(
                                    value: 4,
                                    child: Text(l10n.extension_settings),
                                  ),
                                PopupMenuItem<int>(
                                  value: 5,
                                  child: Text(l10n.export_metadata),
                                ),
                              ];
                            },
                            onSelected: (value) async {
                              switch (value) {
                                case 0:
                                  widget.checkForUpdate(true);
                                  break;
                                case 1:
                                  showCategorySelectionDialog(
                                    context: context,
                                    ref: ref,
                                    itemType: widget.manga!.itemType,
                                    singleManga: widget.manga!,
                                  );
                                  break;
                                case 2:
                                  final source = getSource(
                                    widget.manga!.lang!,
                                    widget.manga!.source!,
                                    widget.manga!.sourceId,
                                  );
                                  if (source == null) return;
                                  final url = await getMangaWebViewUrl(
                                    ref,
                                    source: source,
                                    manga: widget.manga!,
                                  );
                                  if (!context.mounted) return;
                                  final box =
                                      context.findRenderObject() as RenderBox?;
                                  SharePlus.instance.share(
                                    ShareParams(
                                      text: url,
                                      sharePositionOrigin:
                                          box!.localToGlobal(Offset.zero) &
                                          box.size,
                                    ),
                                  );
                                  break;
                                case 3:
                                  context.push("/migrate", extra: widget.manga);
                                  break;
                                case 4:
                                  final source = getSource(
                                    widget.manga!.lang!,
                                    widget.manga!.source!,
                                    widget.manga!.sourceId,
                                  );
                                  if (source == null) return;
                                  context.push(
                                    '/extension_detail',
                                    extra: source,
                                  );
                                  break;
                                case 5:
                                  try {
                                    final result =
                                        await FilePicker.getDirectoryPath();
                                    if (result != null) {
                                      final client = MClient.init();
                                      final coverFile = File(
                                        p.join(result, "cover.jpg"),
                                      );
                                      final metadataFile = File(
                                        p.join(result, "metadata.json"),
                                      );
                                      final headers =
                                          widget.manga!.isLocalArchive!
                                          ? null
                                          : ref.read(
                                              headersProvider(
                                                source: widget.manga!.source!,
                                                lang: widget.manga!.lang!,
                                                sourceId:
                                                    widget.manga!.sourceId,
                                              ),
                                            );
                                      final imageUrl = toImgUrl(
                                        widget.manga!.customCoverFromTracker ??
                                            widget.manga!.imageUrl ??
                                            "",
                                      );
                                      final res = await client.get(
                                        Uri.parse(imageUrl),
                                        headers: headers,
                                      );
                                      await coverFile.writeAsBytes(
                                        res.bodyBytes,
                                      );
                                      await metadataFile.writeAsString(
                                        jsonEncode({
                                          "name": widget.manga!.name,
                                          "description":
                                              widget.manga!.description,
                                          "artist": widget.manga!.artist,
                                          "author": widget.manga!.author,
                                          "genre": widget.manga!.genre,
                                          "status": widget.manga!.status.index,
                                        }),
                                      );
                                      botToast(l10n.exported);
                                    }
                                  } catch (e) {
                                    botToast("Failed to export metadata: $e");
                                  }
                                  break;
                                case 6:
                                  context.push(
                                    "/massMigration",
                                    extra: widget.manga,
                                  );
                                  break;
                                case 7:
                                  await _setDictionaryProfile();
                                  break;
                              }
                            },
                          ),
                        ],
                      );
              },
            ),
          ),
          body: SafeArea(
            child: Row(
              children: [
                if (context.isTablet || seasonOverview)
                  SizedBox(
                    width: seasonOverview
                        ? context.width(1)
                        : context.width(0.5),
                    height: context.height(1),
                    child: SingleChildScrollView(
                      physics: seasonOverview
                          ? const AlwaysScrollableScrollPhysics()
                          : null,
                      child: _bodyContainer(chapterLength: chapters.length),
                    ),
                  ),
                Expanded(
                  child: seasonOverview
                      ? const SizedBox.shrink()
                      : Scrollbar(
                          interactive: true,
                          thickness: 12,
                          radius: const Radius.circular(10),
                          controller: _scrollController,
                          child: CustomScrollView(
                            controller: _scrollController,
                            slivers: [
                              SliverPadding(
                                padding: const EdgeInsets.only(
                                  top: 0,
                                  bottom: 60,
                                ),
                                sliver: SuperSliverList.builder(
                                  itemCount: chapters.length + 1,
                                  itemBuilder: (context, index) {
                                    final l10n = l10nLocalizations(context)!;
                                    int finalIndex = index - 1;
                                    if (index == 0) {
                                      return context.isTablet
                                          ? Column(
                                              children: [
                                                Padding(
                                                  padding: const EdgeInsets.all(
                                                    8.0,
                                                  ),
                                                  child: Row(
                                                    mainAxisAlignment:
                                                        isLocalArchive
                                                        ? MainAxisAlignment
                                                              .spaceBetween
                                                        : MainAxisAlignment
                                                              .start,
                                                    children: [
                                                      Container(
                                                        height: chapters.isEmpty
                                                            ? context.height(1)
                                                            : null,
                                                        color: Theme.of(
                                                          context,
                                                        ).scaffoldBackgroundColor,
                                                        child: Padding(
                                                          padding:
                                                              const EdgeInsets.symmetric(
                                                                horizontal: 8,
                                                              ),
                                                          child: Column(
                                                            crossAxisAlignment:
                                                                CrossAxisAlignment
                                                                    .start,
                                                            mainAxisSize:
                                                                MainAxisSize
                                                                    .min,
                                                            children: [
                                                              Text(
                                                                widget.manga!.itemType !=
                                                                        ItemType
                                                                            .anime
                                                                    ? l10n.n_chapters(
                                                                        chapters
                                                                            .length,
                                                                      )
                                                                    : l10n.n_episodes(
                                                                        chapters
                                                                            .length,
                                                                      ),
                                                                style: const TextStyle(
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold,
                                                                ),
                                                              ),
                                                              Builder(
                                                                builder: (context) {
                                                                  final missing =
                                                                      widget
                                                                          .manga!
                                                                          .missingChapterCount();
                                                                  if (missing <=
                                                                      0) {
                                                                    return const SizedBox.shrink();
                                                                  }
                                                                  return Text(
                                                                    widget.manga!.itemType !=
                                                                            ItemType.anime
                                                                        ? l10n.missing_chapters(
                                                                            missing,
                                                                          )
                                                                        : l10n.missing_episodes(
                                                                            missing,
                                                                          ),
                                                                    style: TextStyle(
                                                                      fontSize:
                                                                          12,
                                                                      color: Colors
                                                                          .red[400],
                                                                    ),
                                                                  );
                                                                },
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                      if (isLocalArchive)
                                                        ElevatedButton.icon(
                                                          style: ElevatedButton.styleFrom(
                                                            padding:
                                                                const EdgeInsets.all(
                                                                  5,
                                                                ),
                                                            shape: RoundedRectangleBorder(
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    5,
                                                                  ),
                                                            ),
                                                          ),
                                                          icon: Icon(
                                                            Icons.add,
                                                            color: context
                                                                .secondaryColor,
                                                          ),
                                                          label: Text(
                                                            widget
                                                                        .manga!
                                                                        .itemType !=
                                                                    ItemType
                                                                        .anime
                                                                ? l10n.add_chapters
                                                                : l10n.add_episodes,
                                                            style: TextStyle(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .bold,
                                                              color: context
                                                                  .secondaryColor,
                                                            ),
                                                          ),
                                                          onPressed: () async {
                                                            final manga =
                                                                widget.manga;
                                                            if (manga!.source ==
                                                                "torrent") {
                                                              addTorrent(
                                                                context,
                                                                manga: manga,
                                                              );
                                                            } else {
                                                              try {
                                                                await ref.read(
                                                                  importArchivesFromFileProvider(
                                                                    itemType: manga
                                                                        .itemType,
                                                                    manga,
                                                                    init: false,
                                                                    splitChapters:
                                                                        false,
                                                                  ).future,
                                                                );
                                                              } catch (error) {
                                                                botToast(
                                                                  'Import failed: $error',
                                                                );
                                                              }
                                                            }
                                                          },
                                                        ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            )
                                          : _bodyContainer(
                                              chapterLength: chapters.length,
                                            );
                                    }
                                    return ChapterListTileWidget(
                                      chapter: chapters[finalIndex],
                                      manga: widget.manga!,
                                      chapterList: chapterList,
                                      allChapters: chapters,
                                      sourceExist: widget.sourceExist,
                                      displayMode:
                                          chapterDisplayMode ??
                                          SortChapter.sourceTitleDisplay,
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: Builder(
            builder: (context) {
              final chap = ref.watch(chaptersListStateProvider);
              bool getLength1 = chap.length == 1;
              bool checkFirstBookmarked =
                  chap.isNotEmpty && chap.first.isBookmarked! && getLength1;
              final markSelectedAsRead = bulkChapterTargetReadState(chap);
              final l10n = l10nLocalizations(context)!;
              final color = Theme.of(context).textTheme.bodyLarge!.color!;
              final downloadedIds =
                  ref.watch(downloadedChapterIdsProvider).asData?.value ??
                  const <int>{};
              final isDownloaded = chap
                  .where((c) => downloadedIds.contains(c.id))
                  .toSet();
              const localChapterPolicy = ChimahonLocalChapterPolicy();
              final selectedLocalOverlayChapters = isLocalArchive
                  ? const <Chapter>{}
                  : chap.where(localChapterPolicy.isDeviceLocal).toSet();
              return BottomSelectBar(
                isVisible: isLongPressed,
                actions: [
                  BottomSelectButton(
                    icon: Icon(
                      checkFirstBookmarked
                          ? Icons.bookmark_remove_outlined
                          : Icons.bookmark_add_outlined,
                      color: color,
                    ),
                    onPressed: () {
                      final chapters = ref.watch(chaptersListStateProvider);
                      final List<Chapter> updatedChapters = [];
                      final now = DateTime.now().millisecondsSinceEpoch;
                      for (var chapter in chapters) {
                        chapter.isBookmarked = !chapter.isBookmarked!;
                        chapter.updatedAt = now;
                        chapter.manga.value = widget.manga;
                        updatedChapters.add(chapter);
                      }
                      chapterRepository.putAll(updatedChapters);
                      ref
                          .read(isLongPressedStateProvider.notifier)
                          .update(false);
                      ref.read(chaptersListStateProvider.notifier).clear();
                    },
                  ),
                  BottomSelectButton(
                    icon: Icon(
                      !markSelectedAsRead
                          ? Icons.remove_done_sharp
                          : Icons.done_all_sharp,
                      color: color,
                    ),
                    onPressed: () {
                      final chapters = ref.watch(chaptersListStateProvider);
                      final List<Chapter> updatedChapters = [];
                      final now = DateTime.now().millisecondsSinceEpoch;
                      Chapter? highestChapter;
                      int highestNum = -1;
                      final recognition = ChapterRecognition();
                      final mangaTitle = widget.manga!.name ?? '';
                      for (var chapter in chapters) {
                        chapter.isRead = markSelectedAsRead;
                        if (!chapter.isRead!) chapter.lastPageRead = "1";
                        chapter.updatedAt = now;
                        chapter.manga.value = widget.manga;
                        updatedChapters.add(chapter);
                        if (chapter.isRead!) {
                          final num = recognition.parseEpisodeNumber(
                            mangaTitle,
                            chapter.name ?? '',
                          );
                          if (num > highestNum) {
                            highestNum = num;
                            highestChapter = chapter;
                          }
                        }
                      }
                      highestChapter?.updateTrackChapterRead(ref);
                      chapterRepository.putAllWithManga(
                        updatedChapters,
                        widget.manga!,
                      );
                      ref
                          .read(isLongPressedStateProvider.notifier)
                          .update(false);
                      ref.read(chaptersListStateProvider.notifier).clear();
                    },
                  ),
                  if (widget.itemType == ItemType.manga)
                    BottomSelectButton(
                      icon: Icon(Icons.document_scanner_outlined, color: color),
                      onPressed: () {
                        final selected = List<Chapter>.of(
                          ref.read(chaptersListStateProvider),
                        );
                        ref
                            .read(isLongPressedStateProvider.notifier)
                            .update(false);
                        ref.read(chaptersListStateProvider.notifier).clear();
                        unawaited(_preOcrSelectedChapters(selected));
                      },
                    ),
                  if (getLength1)
                    BottomSelectButton(
                      icon: Stack(
                        children: [
                          Icon(Icons.done_outlined, color: color),
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: Icon(
                              Icons.arrow_downward_outlined,
                              size: 11,
                              color: color,
                            ),
                          ),
                        ],
                      ),
                      onPressed: () {
                        int index = chapters.indexOf(chap.first);
                        final List<Chapter> updatedChapters = [];
                        final now = DateTime.now().millisecondsSinceEpoch;
                        chapters[index + 1].updateTrackChapterRead(ref);
                        for (var i = index + 1; i < chapters.length; i++) {
                          final chapter = chapters[i];
                          if (!chapter.isRead!) {
                            chapter.isRead = true;
                            chapter.lastPageRead = "1";
                            chapter.updatedAt = now;
                            chapter.manga.value = widget.manga;
                            updatedChapters.add(chapter);
                          }
                        }
                        chapterRepository.putAllWithManga(
                          updatedChapters,
                          widget.manga!,
                        );
                        ref
                            .read(isLongPressedStateProvider.notifier)
                            .update(false);
                        ref.read(chaptersListStateProvider.notifier).clear();
                      },
                    ),
                  // If not local archive and not downloaded, show download button
                  if (!isLocalArchive &&
                      isDownloaded.isEmpty &&
                      selectedLocalOverlayChapters.isEmpty)
                    BottomSelectButton(
                      icon: Icon(Icons.download_outlined, color: color),
                      onPressed: () async {
                        await _downloadChaptersWithDestination(
                          context,
                          ref.read(chaptersListStateProvider).toList(),
                        );
                        if (!mounted) return;
                        ref
                            .read(isLongPressedStateProvider.notifier)
                            .update(false);
                        ref.read(chaptersListStateProvider.notifier).clear();
                      },
                    ),
                  // Device-local overlay rows are files, not downloads, but
                  // must still be explicitly removable from a source title.
                  if (isLocalArchive ||
                      isDownloaded.isNotEmpty ||
                      selectedLocalOverlayChapters.isNotEmpty)
                    BottomSelectButton(
                      icon: Icon(Icons.delete_outline_outlined, color: color),
                      onPressed: () {
                        final selectedChapters = ref.watch(
                          chaptersListStateProvider,
                        );
                        final totalChapters = widget.manga!.chapters.length;
                        final isLastChapters =
                            selectedChapters.length == totalChapters;
                        final isAnime = widget.itemType == ItemType.anime;
                        final entryType = isAnime ? l10n.episode : l10n.chapter;
                        final pluralEntryType = isAnime
                            ? l10n.episodes
                            : l10n.chapters;
                        final mediaType = isAnime ? l10n.anime : l10n.manga;
                        final warningMessage = l10n.last_entry_delete_warning(
                          totalChapters,
                          entryType,
                          pluralEntryType,
                          mediaType,
                        );
                        showDialog(
                          context: context,
                          builder: (context) {
                            return AlertDialog(
                              title: Text(l10n.delete_chapters),
                              content: isLocalArchive && isLastChapters
                                  ? Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Icon(
                                          Icons.warning_amber_rounded,
                                          color: Colors.orange,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            warningMessage,
                                            style: TextStyle(color: Colors.red),
                                          ),
                                        ),
                                      ],
                                    )
                                  : null,
                              actions: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    TextButton(
                                      onPressed: () {
                                        Navigator.pop(context);
                                      },
                                      child: Text(l10n.cancel),
                                    ),
                                    const SizedBox(width: 15),
                                    TextButton(
                                      onPressed: () async {
                                        final navigator = Navigator.of(context);
                                        if (isLocalArchive) {
                                          await dbWriteQueue.run(
                                            () => isar.writeTxn(() async {
                                              final idsToDelete =
                                                  selectedChapters
                                                      .map((c) => c.id!)
                                                      .toList();
                                              await isar.chapters.deleteAll(
                                                idsToDelete,
                                              );
                                            }),
                                          );
                                        } else if (selectedLocalOverlayChapters
                                            .isNotEmpty) {
                                          final result =
                                              await const ChimahonLocalChapterOverlayService()
                                                  .deleteSelected(
                                                    database: isar,
                                                    manga: widget.manga!,
                                                    selectedChapters:
                                                        selectedLocalOverlayChapters,
                                                  );
                                          if (result.failed.isNotEmpty) {
                                            botToast(
                                              'Could not delete ${result.failed.length} local chapter file(s).',
                                            );
                                          }
                                        }
                                        final localOverlayIds =
                                            selectedLocalOverlayChapters
                                                .map((chapter) => chapter.id)
                                                .toSet();
                                        for (final chapter
                                            in isDownloaded.where(
                                              (chapter) => !localOverlayIds
                                                  .contains(chapter.id),
                                            )) {
                                          await chapter.deleteDownloadedFiles();
                                        }
                                        if (!mounted) return;
                                        ref
                                            .read(
                                              isLongPressedStateProvider
                                                  .notifier,
                                            )
                                            .update(false);
                                        ref
                                            .read(
                                              chaptersListStateProvider
                                                  .notifier,
                                            )
                                            .clear();
                                        navigator.pop();
                                        if (isLocalArchive && isLastChapters) {
                                          navigator.pop();
                                          Future.delayed(
                                            const Duration(milliseconds: 350),
                                            () {
                                              mangaRepository.delete(
                                                widget.manga!.id!,
                                              );
                                            },
                                          );
                                        }
                                      },
                                      child: Text(l10n.delete),
                                    ),
                                  ],
                                ),
                              ],
                            );
                          },
                        );
                      },
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  void _showDraggableMenu() {
    final scanlators = ref.watch(scanlatorsFilterStateProvider(widget.manga!));
    final l10n = l10nLocalizations(context)!;
    customDraggableTabBar(
      tabs: [
        Tab(text: l10n.filter),
        Tab(text: l10n.sort),
        Tab(text: l10n.display),
      ],
      children: [
        Column(
          children: [
            if (!isLocalArchive)
              Consumer(
                builder: (context, ref, child) => ListTileChapterFilter(
                  label: l10n.downloaded,
                  type: ref.watch(
                    chapterFilterDownloadedStateProvider(
                      mangaId: widget.manga!.id!,
                    ),
                  ),
                  onTap: () {
                    ref
                        .read(
                          chapterFilterDownloadedStateProvider(
                            mangaId: widget.manga!.id!,
                          ).notifier,
                        )
                        .update();
                  },
                ),
              ),
            Consumer(
              builder: (context, ref, child) => ListTileChapterFilter(
                label: widget.itemType != ItemType.anime
                    ? l10n.unread
                    : l10n.unwatched,
                type: ref.watch(
                  chapterFilterUnreadStateProvider(mangaId: widget.manga!.id!),
                ),
                onTap: () {
                  ref
                      .read(
                        chapterFilterUnreadStateProvider(
                          mangaId: widget.manga!.id!,
                        ).notifier,
                      )
                      .update();
                },
              ),
            ),
            Consumer(
              builder: (context, ref, child) => ListTileChapterFilter(
                label: l10n.bookmarked,
                type: ref.watch(
                  chapterFilterBookmarkedStateProvider(
                    mangaId: widget.manga!.id!,
                  ),
                ),
                onTap: () {
                  ref
                      .read(
                        chapterFilterBookmarkedStateProvider(
                          mangaId: widget.manga!.id!,
                        ).notifier,
                      )
                      .update();
                },
              ),
            ),
            if (scanlators.$1.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (context) {
                              return Consumer(
                                builder: (context, ref, child) {
                                  final scanlators = ref.watch(
                                    scanlatorsFilterStateProvider(
                                      widget.manga!,
                                    ),
                                  );
                                  return AlertDialog(
                                    title: Text(l10n.filter_scanlator_groups),
                                    content: SizedBox(
                                      width: context.width(0.8),
                                      child: SuperListView.builder(
                                        shrinkWrap: true,
                                        itemCount: scanlators.$1.length,
                                        itemBuilder: (context, index) {
                                          return ListTileChapterFilter(
                                            label: scanlators.$1[index],
                                            type:
                                                scanlators.$3.contains(
                                                  scanlators.$1[index],
                                                )
                                                ? 2
                                                : 0,
                                            onTap: () {
                                              ref
                                                  .read(
                                                    scanlatorsFilterStateProvider(
                                                      widget.manga!,
                                                    ).notifier,
                                                  )
                                                  .setFilteredList(
                                                    scanlators.$1[index],
                                                  );
                                            },
                                          );
                                        },
                                      ),
                                    ),
                                    actions: [
                                      Column(
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Row(
                                                  children: [
                                                    TextButton(
                                                      onPressed: () {
                                                        ref
                                                            .read(
                                                              scanlatorsFilterStateProvider(
                                                                widget.manga!,
                                                              ).notifier,
                                                            )
                                                            .set([]);
                                                        Navigator.pop(context);
                                                      },
                                                      child: Text(
                                                        l10n.reset,
                                                        style: TextStyle(
                                                          color: context
                                                              .primaryColor,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment
                                                        .spaceBetween,
                                                children: [
                                                  TextButton(
                                                    onPressed: () async {
                                                      Navigator.pop(context);
                                                    },
                                                    child: Text(
                                                      l10n.cancel,
                                                      style: TextStyle(
                                                        color: context
                                                            .primaryColor,
                                                      ),
                                                    ),
                                                  ),
                                                  TextButton(
                                                    onPressed: () {
                                                      ref
                                                          .read(
                                                            scanlatorsFilterStateProvider(
                                                              widget.manga!,
                                                            ).notifier,
                                                          )
                                                          .set(scanlators.$3);
                                                      Navigator.pop(context);
                                                    },
                                                    child: Text(
                                                      l10n.filter,
                                                      style: TextStyle(
                                                        color: context
                                                            .primaryColor,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ],
                                  );
                                },
                              );
                            },
                          );
                        },
                        child: Text(l10n.filter_scanlator_groups),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        Consumer(
          builder: (context, ref, chil) {
            final reverse = ref
                .read(
                  sortChapterStateProvider(mangaId: widget.manga!.id!).notifier,
                )
                .isReverse();
            final scanlators = ref.watch(
              scanlatorsFilterStateProvider(widget.manga!),
            );
            final reverseChapter = ref.watch(
              sortChapterStateProvider(mangaId: widget.manga!.id!),
            );
            return Column(
              children: [
                if (scanlators.$1.isNotEmpty)
                  ListTileChapterSort(
                    label: _getSortNameByIndex(0, context),
                    reverse: reverse,
                    onTap: () {
                      ref
                          .read(
                            sortChapterStateProvider(mangaId: widget.manga!.id!)
                                .notifier,
                          )
                          .set(0);
                    },
                    showLeading: reverseChapter.index == 0,
                  ),
                for (var i = 1; i < 4; i++)
                  ListTileChapterSort(
                    label: _getSortNameByIndex(i, context),
                    reverse: reverse,
                    onTap: () {
                      ref
                          .read(
                            sortChapterStateProvider(mangaId: widget.manga!.id!)
                                .notifier,
                          )
                          .set(i);
                    },
                    showLeading: reverseChapter.index == i,
                  ),
              ],
            );
          },
        ),
        Consumer(
          builder: (context, ref, child) {
            final displayMode = ref
                .watch(sortChapterStateProvider(mangaId: widget.manga!.id!))
                .displayMode;
            return RadioGroup<int>(
              groupValue: displayMode ?? SortChapter.sourceTitleDisplay,
              onChanged: (value) {
                if (value == null) return;
                ref
                    .read(
                      sortChapterStateProvider(mangaId: widget.manga!.id!)
                          .notifier,
                    )
                    .setDisplayMode(value);
              },
              child: Column(
                children: [
                  RadioListTile<int>(
                    dense: true,
                    title: Text(l10n.source_title),
                    value: SortChapter.sourceTitleDisplay,
                  ),
                  RadioListTile<int>(
                    dense: true,
                    title: Text(
                      widget.itemType != ItemType.anime
                          ? l10n.chapter_number
                          : l10n.episode_number,
                    ),
                    value: SortChapter.chapterNumberDisplay,
                  ),
                ],
              ),
            );
          },
        ),
      ],
      context: context,
      vsync: this,
    );
  }

  String _getSortNameByIndex(int index, BuildContext context) {
    final l10n = l10nLocalizations(context)!;
    if (index == 0) {
      return l10n.by_scanlator;
    } else if (index == 1) {
      return widget.itemType != ItemType.anime
          ? l10n.by_chapter_number
          : l10n.by_episode_number;
    } else if (index == 2) {
      return l10n.by_upload_date;
    }
    return l10n.by_name;
  }

  Widget _bodyContainer({required int chapterLength}) {
    final l10n = l10nLocalizations(context)!;
    return Stack(
      children: [
        Container(
          height: 300,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Theme.of(context).scaffoldBackgroundColor
                    .withValues(alpha: 0.05),
                Theme.of(context).scaffoldBackgroundColor,
              ],
              stops: const [0, .3],
            ),
          ),
        ),
        Column(
          children: [
            Stack(
              children: [
                SizedBox(
                  width: context.width(1),
                  child: Row(
                    children: [
                      _coverCard(),
                      Expanded(child: _titles()),
                    ],
                  ),
                ),
                if (isLocalArchive)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: IconButton(
                      onPressed: () {
                        _editLocalArchiveInfos();
                      },
                      icon: const CircleAvatar(
                        child: Icon(Icons.edit_outlined),
                      ),
                    ),
                  ),
              ],
            ),
            _actionFavouriteAndWebview(),
            Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.manga!.description != null)
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: ReadMoreWidget(
                        text: widget.manga!.description!,
                        onChanged: (value) {
                          setState(() {
                            _expanded = value;
                          });
                        },
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: widget.manga!.genre!.isEmpty
                        ? const SizedBox(height: 30)
                        : _expanded || context.isTablet
                        ? Wrap(
                            children: [
                              for (
                                var i = 0;
                                i < widget.manga!.genre!.length;
                                i++
                              )
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 2,
                                    right: 2,
                                    bottom: 5,
                                  ),
                                  child: SizedBox(
                                    height: 30,
                                    child: PopupMenuButton(
                                      popUpAnimationStyle: popupAnimationStyle,
                                      itemBuilder: (context) {
                                        return [
                                          // 48 rather than 40: these are the
                                          // only two menu rows in the app that
                                          // set their own height, and 40 is
                                          // under the minimum target on both
                                          // Material and Apple.
                                          PopupMenuItem<int>(
                                            height: 48,
                                            value: 0,
                                            child: Text(
                                              context.l10n.genre_search_library,
                                            ),
                                          ),
                                          PopupMenuItem<int>(
                                            height: 48,
                                            value: 1,
                                            child: Text(
                                              context.l10n.genre_search_source,
                                            ),
                                          ),
                                        ];
                                      },
                                      onSelected: (value) async {
                                        final source = getSource(
                                          widget.manga!.lang!,
                                          widget.manga!.source!,
                                          widget.manga!.sourceId,
                                        );
                                        if (source == null) {
                                          botToast(l10n.source_not_added);
                                          return;
                                        }
                                        if (value == 0) {
                                          final genre = widget.manga!.genre![i];
                                          switch (widget.manga!.itemType) {
                                            case ItemType.manga:
                                              context.pushReplacement(
                                                '/MangaLibrary',
                                                extra: genre,
                                              );
                                              break;
                                            case ItemType.anime:
                                              context.pushReplacement(
                                                '/AnimeLibrary',
                                                extra: genre,
                                              );
                                              break;
                                            case ItemType.novel:
                                              context.pushReplacement(
                                                '/NovelLibrary',
                                                extra: genre,
                                              );
                                              break;
                                          }
                                        } else {
                                          context.pushReplacement(
                                            '/mangaHome',
                                            extra: (source, false),
                                          );
                                        }
                                      },
                                      child: ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                          elevation: 0,
                                          backgroundColor: Colors.grey
                                              .withValues(alpha: 0.2),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              5,
                                            ),
                                          ),
                                        ),
                                        onPressed: null,
                                        child: Text(
                                          widget.manga!.genre![i],
                                          style: TextStyle(
                                            // 11 is the chip step. 11.5 is not
                                            // on the scale and renders
                                            // inconsistently across platforms.
                                            fontSize: 11,
                                            // The theme already answers this;
                                            // picking black or white by hand
                                            // ignores the palette.
                                            color: context.textColor,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          )
                        : SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.start,
                              children: [
                                for (
                                  var i = 0;
                                  i < widget.manga!.genre!.length;
                                  i++
                                )
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      left: 2,
                                      right: 2,
                                      bottom: 5,
                                    ),
                                    child: SizedBox(
                                      height: 30,
                                      child: ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                          elevation: 0,
                                          backgroundColor: Colors.grey
                                              .withValues(alpha: 0.2),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              5,
                                            ),
                                          ),
                                        ),
                                        onPressed: () {},
                                        child: Text(
                                          widget.manga!.genre![i],
                                          style: TextStyle(
                                            // 11 is the chip step. 11.5 is not
                                            // on the scale and renders
                                            // inconsistently across platforms.
                                            fontSize: 11,
                                            // The theme already answers this;
                                            // picking black or white by hand
                                            // ignores the palette.
                                            color: context.textColor,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                  ),
                  const SizedBox(height: 15),
                  _DetailActions(manga: widget.manga!),
                  const SizedBox(height: 15),
                  if (!context.isTablet)
                    Column(
                      children: [
                        //Description
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Row(
                            mainAxisAlignment: isLocalArchive
                                ? MainAxisAlignment.spaceBetween
                                : MainAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      widget.manga!.itemType != ItemType.anime
                                          ? l10n.n_chapters(chapterLength)
                                          : l10n.n_episodes(chapterLength),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Builder(
                                      builder: (context) {
                                        final missing = widget.manga!
                                            .missingChapterCount();
                                        if (missing <= 0) {
                                          return const SizedBox.shrink();
                                        }
                                        return Text(
                                          widget.manga!.itemType !=
                                                  ItemType.anime
                                              ? l10n.missing_chapters(missing)
                                              : l10n.missing_episodes(missing),
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.red[400],
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ),
                              if (isLocalArchive)
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.all(5),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                  ),
                                  icon: Icon(
                                    Icons.add,
                                    color: context.secondaryColor,
                                  ),
                                  label: Text(
                                    widget.manga!.itemType != ItemType.anime
                                        ? l10n.add_chapters
                                        : l10n.add_episodes,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: context.secondaryColor,
                                    ),
                                  ),
                                  onPressed: () async {
                                    final manga = widget.manga;
                                    if (manga!.source == "torrent") {
                                      addTorrent(context, manga: manga);
                                    } else {
                                      try {
                                        await ref.read(
                                          importArchivesFromFileProvider(
                                            itemType: manga.itemType,
                                            manga,
                                            init: false,
                                            splitChapters: false,
                                          ).future,
                                        );
                                      } catch (error) {
                                        botToast('Import failed: $error');
                                      }
                                    }
                                  },
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            if (widget.manga!.hasSeasons ||
                widget.manga!.animeParentUrl != null)
              AnimeSeasonList(anime: widget.manga!),
            if (chapterLength == 0 && !widget.manga!.hasSeasons)
              Container(
                width: context.width(1),
                height: context.height(1),
                color: Theme.of(context).scaffoldBackgroundColor,
              ),
          ],
        ),
      ],
    );
  }

  Widget _coverCard() {
    final imageProvider = widget.manga!.customCoverImage != null
        ? MemoryImage(widget.manga!.customCoverImage as Uint8List)
              as ImageProvider
        : CustomExtendedNetworkImageProvider(
            toImgUrl(
              widget.manga!.customCoverFromTracker ??
                  widget.manga!.imageUrl ??
                  "",
            ),
            headers: widget.manga!.isLocalArchive!
                ? null
                : ref.watch(
                    headersProvider(
                      source: widget.manga!.source!,
                      lang: widget.manga!.lang!,
                      sourceId: widget.manga!.sourceId,
                    ),
                  ),
          );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 20),
      child: GestureDetector(
        onTap: () {
          _openImage(imageProvider);
        },
        child: SizedBox(
          width: 65 * 1.5,
          height: 65 * 2.3,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(5)),
              image: DecorationImage(image: imageProvider, fit: BoxFit.cover),
            ),
          ),
        ),
      ),
    );
  }

  Widget _titles() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SelectableText(
          widget.manga!.name!,
          style: const TextStyle(fontSize: 20),
        ),
        widget.titleDescription!,
      ],
    );
  }

  Widget _actionFavouriteAndWebview() {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: widget.action!),
          if (!isLocalArchive) Expanded(child: _smartUpdateDays()),
          _action(),
          if (!isLocalArchive)
            Expanded(
              child: SizedBox(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                    elevation: 0,
                  ),
                  onPressed: () async {
                    final manga = widget.manga!;

                    final source = getSource(
                      widget.manga!.lang!,
                      widget.manga!.source!,
                      widget.manga!.sourceId,
                    );
                    if (source == null) return;
                    final url = await getMangaWebViewUrl(
                      ref,
                      source: source,
                      manga: manga,
                    );
                    if (!mounted) return;

                    Map<String, dynamic> data = {
                      'url': url,
                      'sourceId': source.id.toString(),
                      'title': manga.name!,
                    };
                    context.push("/mangawebview", extra: data);
                  },
                  child: Column(
                    children: [
                      Icon(
                        Icons.public,
                        size: 20,
                        color: context.secondaryColor,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        context.l10n.webview,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.secondaryColor,
                        ),
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

  Widget _smartUpdateDays() {
    return SizedBox(
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          elevation: 0,
        ),
        onPressed: () =>
            context.push("/calendarScreen", extra: widget.manga!.itemType),
        child: Column(
          children: [
            Icon(
              Icons.hourglass_empty,
              size: 20,
              color: context.secondaryColor,
            ),
            const SizedBox(height: 4),
            Text(
              widget.manga?.smartUpdateDays != null
                  ? context.l10n.n_days(widget.manga!.smartUpdateDays!)
                  : "N/A",
              style: TextStyle(fontSize: 11, color: context.secondaryColor),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// Tracker button
  Widget _action() {
    return StreamBuilder(
      stream: trackRepository.watchAllWithSyncId(),
      builder: (context, snapshot) {
        List<TrackPreference>? entries = snapshot.hasData ? snapshot.data! : [];
        if (entries.isEmpty) {
          return SizedBox.shrink();
        }
        return Expanded(
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              elevation: 0,
            ),
            onPressed: () {
              _trackingDraggableMenu(entries);
            },
            child: StreamBuilder(
              stream: trackRepository.watchByMangaId(widget.manga!.id!),
              builder: (context, snapshot) {
                final l10n = l10nLocalizations(context)!;
                List<Track>? trackRes = snapshot.hasData ? snapshot.data : [];
                bool isNotEmpty = trackRes!.isNotEmpty;
                Color color = isNotEmpty
                    ? context.primaryColor
                    : context.secondaryColor;
                return Column(
                  children: [
                    Icon(
                      isNotEmpty ? Icons.done_rounded : Icons.sync_outlined,
                      size: 20,
                      color: color,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isNotEmpty
                          ? trackRes.length == 1
                                ? l10n.one_tracker
                                : l10n.n_tracker(trackRes.length)
                          : l10n.tracking,
                      style: TextStyle(fontSize: 11, color: color),
                      textAlign: TextAlign.center,
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  void _openImage(ImageProvider imageProvider) {
    showDialog(
      context: context,
      builder: (context) {
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: PhotoViewGallery.builder(
                  backgroundDecoration: const BoxDecoration(
                    color: Colors.transparent,
                  ),
                  itemCount: 1,
                  builder: (context, index) {
                    return PhotoViewGalleryPageOptions(
                      imageProvider: imageProvider,
                      minScale: PhotoViewComputedScale.contained,
                      maxScale: 2.0,
                    );
                  },
                  loadingBuilder: (context, event) {
                    return const ProgressCenter();
                  },
                ),
              ),
              Positioned(
                bottom: 0,
                right: 0,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: StreamBuilder(
                        stream: trackRepository.watchAllWithSyncId(),
                        builder: (context, snapshot) {
                          List<TrackPreference>? entries = snapshot.hasData
                              ? snapshot.data!
                              : [];
                          if (entries.isEmpty) {
                            return Container();
                          }
                          return Column(
                            children: entries
                                .map(
                                  (e) => Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: MaterialButton(
                                      padding: const EdgeInsets.all(0),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      onPressed: () async {
                                        final trackSearch =
                                            await trackersSearchDraggableMenu(
                                              context,
                                              itemType: widget.manga!.itemType,
                                              track: Track(
                                                status: TrackStatus.planToRead,
                                                syncId: e.syncId!,
                                                title: widget.manga!.name!,
                                              ),
                                            ) as TrackSearch?;
                                        if (trackSearch != null) {
                                          mangaRepository.save(
                                            widget.manga!
                                              ..customCoverImage = null
                                              ..customCoverFromTracker =
                                                  trackSearch.coverUrl,
                                          );
                                          if (context.mounted) {
                                            Navigator.pop(context);
                                            botToast(
                                              context.l10n.cover_updated,
                                              second: 3,
                                            );
                                          }
                                        }
                                      },
                                      child: Container(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                          color: trackInfos(e.syncId!).$3,
                                        ),
                                        width: 45,
                                        height: 50,
                                        child: Image.asset(
                                          trackInfos(e.syncId!).$1,
                                          height: 30,
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                          );
                        },
                      ),
                    ),
                    SizedBox(
                      width: context.width(1),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(20),
                                color: context.isLight
                                    ? Colors.white
                                    : Colors.black,
                              ),
                              child: GestureDetector(
                                onTap: () {
                                  Navigator.pop(context);
                                },
                                child: const Padding(
                                  padding: EdgeInsets.all(8.0),
                                  child: Icon(Icons.close),
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(20),
                                color: context.isLight
                                    ? Colors.white
                                    : Colors.black,
                              ),
                              child: Row(
                                children: [
                                  GestureDetector(
                                    onTap: () async {
                                      final bytes = await imageProvider
                                          .getBytes(context);
                                      if (bytes != null) {
                                        await shareOrCopy(
                                          ShareParams(
                                            files: [
                                              XFile.fromData(
                                                bytes,
                                                name: widget.manga!.name,
                                                mimeType: 'image/png',
                                              ),
                                            ],
                                          ),
                                          fallbackName: widget.manga!.name,
                                        );
                                      }
                                    },
                                    child: const Padding(
                                      padding: EdgeInsets.all(8.0),
                                      child: Icon(Icons.share),
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () async {
                                      final dir = await StorageProvider()
                                          .getGalleryDirectory();
                                      if (context.mounted) {
                                        final bytes = await imageProvider
                                            .getBytes(context);
                                        if (bytes != null && context.mounted) {
                                          final file = File(
                                            p.join(
                                              dir!.path,
                                              "${widget.manga!.name}.png",
                                            ),
                                          );
                                          file.writeAsBytesSync(bytes);
                                          botToast(
                                            context.l10n.cover_saved,
                                            second: 3,
                                          );
                                        }
                                      }
                                    },
                                    child: const Padding(
                                      padding: EdgeInsets.all(8.0),
                                      child: Icon(Icons.save_outlined),
                                    ),
                                  ),
                                  PopupMenuButton(
                                    popUpAnimationStyle: popupAnimationStyle,
                                    itemBuilder: (context) {
                                      return [
                                        if (widget.manga!.customCoverImage !=
                                                null ||
                                            widget
                                                    .manga!
                                                    .customCoverFromTracker !=
                                                null)
                                          PopupMenuItem<int>(
                                            value: 0,
                                            child: Text(context.l10n.delete),
                                          ),
                                        PopupMenuItem<int>(
                                          value: 1,
                                          child: Text(context.l10n.edit),
                                        ),
                                      ];
                                    },
                                    onSelected: (value) async {
                                      final manga = widget.manga!;
                                      if (value == 0) {
                                        mangaRepository.save(
                                          manga
                                            ..customCoverImage = null
                                            ..customCoverFromTracker = null,
                                        );
                                        Navigator.pop(context);
                                      } else if (value == 1) {
                                        final file = await FilePicker.pickFile(
                                          type: FileType.image,
                                        );
                                        if (file?.path != null &&
                                            context.mounted) {
                                          final bytes = File(file!.path!)
                                              .readAsBytesSync();
                                          await applyMangaCover(
                                            context,
                                            manga,
                                            bytes,
                                          );
                                        }
                                        if (context.mounted) {
                                          Navigator.pop(context);
                                        }
                                      }
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.all(8.0),
                                      child: Icon(
                                        Icons.edit_outlined,
                                        color: !context.isLight
                                            ? Colors.white
                                            : Colors.black,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _editLocalArchiveInfos() {
    final l10n = l10nLocalizations(context)!;
    TextEditingController? name = TextEditingController(
      text: widget.manga!.name!,
    );
    TextEditingController? description = TextEditingController(
      text: widget.manga!.description!,
    );
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(l10n.edit),
          content: SizedBox(
            height: 200,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 15),
                        child: Text(l10n.name),
                      ),
                      TextFormField(controller: name),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 15),
                        child: Text(l10n.description),
                      ),
                      TextFormField(controller: description),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                  },
                  child: Text(l10n.cancel),
                ),
                const SizedBox(width: 15),
                TextButton(
                  onPressed: () {
                    final manga = widget.manga!;
                    manga.description = description.text;
                    manga.updateDisplayTitle(name.text);
                    mangaRepository.save(manga);
                    Navigator.pop(context);
                  },
                  child: Text(l10n.edit),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _trackingDraggableMenu(List<TrackPreference>? entries) {
    DraggableMenu.open(
      context,
      Consumer(
        builder: (context, ref, _) {
          final isPureBlack = ref.watch(pureBlackDarkModeStateProvider);
          final theme = Theme.of(context);
          final bgColor = context.isLight || !isPureBlack
              ? theme.scaffoldBackgroundColor.withValues(alpha: 0.9)
              : theme.cardColor;

          return DraggableMenu(
            ui: ClassicDraggableMenu(
              radius: 20,
              barItem: Container(),
              color: theme.scaffoldBackgroundColor,
            ),
            allowToShrink: true,
            child: Material(
              color: bgColor,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: SuperListView.separated(
                  padding: const EdgeInsets.all(0),
                  itemCount: entries!.length,
                  primary: false,
                  shrinkWrap: true,
                  itemBuilder: (context, index) {
                    return StreamBuilder(
                      stream: isar.tracks
                          .filter()
                          .idIsNotNull()
                          .syncIdEqualTo(entries[index].syncId)
                          .mangaIdEqualTo(widget.manga!.id!)
                          .watch(fireImmediately: true),
                      builder: (context, snapshot) {
                        List<Track>? trackRes = snapshot.hasData
                            ? snapshot.data
                            : [];
                        return trackRes!.isNotEmpty
                            ? TrackerWidget(
                                mangaId: widget.manga!.id!,
                                syncId: entries[index].syncId!,
                                trackRes: trackRes.first,
                                itemType: widget.manga!.itemType,
                              )
                            : TrackListile(
                                text: l10nLocalizations(context)!.add_tracker,
                                onTap: () async {
                                  final trackSearch =
                                      await trackersSearchDraggableMenu(
                                        context,
                                        itemType: widget.manga!.itemType,
                                        track: Track(
                                          status: TrackStatus.planToRead,
                                          syncId: entries[index].syncId!,
                                          title: widget.manga!.name!,
                                        ),
                                      ) as TrackSearch?;
                                  if (trackSearch != null) {
                                    await ref
                                        .read(
                                          trackStateProvider(
                                            track: null,
                                            itemType: widget.manga!.itemType,
                                            widgetRef: ref,
                                          ).notifier,
                                        )
                                        .setTrackSearch(
                                          trackSearch,
                                          widget.manga!.id!,
                                          entries[index].syncId!,
                                        );
                                  }
                                },
                                id: entries[index].syncId!,
                                entries: const [],
                              );
                      },
                    );
                  },
                  separatorBuilder: (BuildContext context, int index) {
                    return const Divider();
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
