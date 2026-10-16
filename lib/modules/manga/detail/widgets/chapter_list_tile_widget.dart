import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/modules/widgets/custom_extended_image_provider.dart';
import 'package:mangayomi/modules/widgets/progress_center.dart';
import 'package:mangayomi/modules/novel/novel_reader_progress.dart';
import 'package:mangayomi/modules/novel/novel_reader_view.dart';
import 'package:mangayomi/utils/constant.dart';
import 'package:marquee/marquee.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/services/epub_chapter_metadata.dart';
import 'package:mangayomi/utils/chapter_recognition.dart';
import 'package:mangayomi/utils/date.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';
import 'package:mangayomi/utils/extensions/chapter_extensions.dart';
import 'package:mangayomi/utils/extensions/string_extensions.dart';
import 'package:mangayomi/utils/platform_utils.dart';
import 'package:mangayomi/modules/manga/detail/providers/state_providers.dart';
import 'package:mangayomi/modules/manga/download/download_page_widget.dart';
import 'package:mangayomi/modules/manga/download/providers/download_provider.dart';
import 'package:mangayomi/modules/more/settings/reader/providers/reader_state_provider.dart';
import 'package:mangayomi/repositories/chapter_repository.dart';
import 'package:mangayomi/repositories/download_repository.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

class ChapterListTileWidget extends ConsumerWidget {
  final Chapter chapter;
  final Manga manga;
  final List<Chapter> chapterList;
  final List<Chapter> allChapters;
  final bool sourceExist;
  final int displayMode;
  const ChapterListTileWidget({
    required this.chapterList,
    required this.chapter,
    required this.manga,
    required this.allChapters,
    required this.sourceExist,
    required this.displayMode,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = l10nLocalizations(context)!;
    final isLongPressed = ref.watch(isLongPressedStateProvider);
    final swipeStartAction = ref.watch(chapterSwipeStartActionStateProvider);
    final swipeEndAction = ref.watch(chapterSwipeEndActionStateProvider);
    final dismissDirection =
        isLongPressed ||
            (swipeStartAction == ChapterSwipeAction.disabled &&
                swipeEndAction == ChapterSwipeAction.disabled)
        ? DismissDirection.none
        : swipeStartAction == ChapterSwipeAction.disabled
        ? DismissDirection.endToStart
        : swipeEndAction == ChapterSwipeAction.disabled
        ? DismissDirection.startToEnd
        : DismissDirection.horizontal;
    final isEpubShortcut = isEpubNavigationChapter(chapter);
    final epubCharacterStart = epubChapterCharacterStart(chapter);
    final displayTitle = displayMode == SortChapter.chapterNumberDisplay
        ? _chapterNumberTitle(
            chapterLabel: l10n.chapter,
            episodeLabel: l10n.episode,
          )
        : chapter.name!;
    return Dismissible(
      key: ValueKey('chapter_swipe_${chapter.id}'),
      direction: dismissDirection,
      confirmDismiss: (direction) async {
        final action = direction == DismissDirection.startToEnd
            ? swipeStartAction
            : swipeEndAction;
        await _performSwipeAction(action, context, ref);
        return false; // Don't dismiss, snap back
      },
      background: _buildSwipeBackground(
        swipeStartAction,
        context,
        Alignment.centerLeft,
      ),
      secondaryBackground: _buildSwipeBackground(
        swipeEndAction,
        context,
        Alignment.centerRight,
      ),
      child: Material(
        color: chapterList.contains(chapter)
            ? context.primaryColor.withValues(alpha: 0.4)
            : Colors.transparent,
        child: GestureDetector(
          onLongPress: () => _handleInteraction(ref),
          onSecondaryTap: () => _handleInteraction(ref),
          child: ListTile(
            contentPadding: EdgeInsets.symmetric(horizontal: 15),
            minLeadingWidth: 0,
            horizontalTitleGap: 13,
            leading: Container(
              width: 2,
              height: 40,
              decoration: BoxDecoration(
                color: chapter.isRead!
                    ? Colors.grey.withValues(alpha: 0.3)
                    : context.primaryColor,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            tileColor: (chapter.isFiller ?? false)
                ? context.primaryColor.withValues(alpha: 0.15)
                : null,
            textColor: chapter.isRead!
                ? context.isLight
                      ? Colors.black.withValues(alpha: 0.4)
                      : Colors.white.withValues(alpha: 0.3)
                : null,
            selectedColor: chapter.isRead!
                ? Colors.white.withValues(alpha: 0.3)
                : Colors.white,
            onTap: () async => _handleInteraction(ref, context),
            title: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (chapter.thumbnailUrl != null)
                  _thumbnailPreview(context, chapter.thumbnailUrl),
                chapter.isBookmarked!
                    ? Icon(
                        Icons.bookmark,
                        size: 16,
                        color: context.primaryColor,
                      )
                    : SizedBox.shrink(),
                chapter.description != null && !isManagedEpubChapter(chapter)
                    ? Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildTitle(displayTitle, context),
                            Text(
                              chapter.description!,
                              style: const TextStyle(fontSize: 11),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      )
                    : Flexible(child: _buildTitle(displayTitle, context)),
              ],
            ),
            subtitle: Row(
              children: [
                if (chapter.isFiller ?? false)
                  Row(
                    children: [
                      Icon(Icons.label, size: 16, color: context.primaryColor),
                      Text(
                        " Filler ",
                        style: TextStyle(
                          fontSize: 11,
                          color: context.primaryColor,
                        ),
                      ),
                    ],
                  ),
                if (!isEpubNavigationChapter(chapter) &&
                    (manga.isLocalArchive ?? false) == false)
                  Text(
                    chapter.dateUpload == null || chapter.dateUpload!.isEmpty
                        ? ""
                        : dateFormat(
                            chapter.dateUpload!,
                            ref: ref,
                            context: context,
                          ),
                    style: const TextStyle(fontSize: 11),
                  ),
                if (!chapter.isRead!)
                  if (chapter.lastPageRead!.isNotEmpty &&
                      chapter.lastPageRead != "1")
                    Row(
                      children: [
                        const Text(' • '),
                        Text(
                          isEpubNavigationChapter(chapter)
                              ? formatNovelProgressPercentage(
                                  double.tryParse(chapter.lastPageRead!) ?? 0,
                                )
                              : manga.itemType == ItemType.anime
                              ? l10n.episode_progress(
                                  Duration(
                                    milliseconds: int.parse(
                                      chapter.lastPageRead!,
                                    ),
                                  ).toString().substringBefore("."),
                                )
                              : l10n.page(
                                  manga.itemType == ItemType.manga
                                      ? chapter.lastPageRead!
                                      : formatNovelProgressPercentage(
                                          double.tryParse(
                                                chapter.lastPageRead!,
                                              ) ??
                                              0,
                                        ),
                                ),
                          style: TextStyle(
                            fontSize: 11,
                            color: context.isLight
                                ? Colors.black.withValues(alpha: 0.4)
                                : Colors.white.withValues(alpha: 0.3),
                          ),
                        ),
                      ],
                    ),
                if (chapter.scanlator?.isNotEmpty ?? false)
                  Row(
                    children: [
                      const Text(' • '),
                      Text(
                        chapter.scanlator!,
                        style: TextStyle(
                          fontSize: 11,
                          color: chapter.isRead!
                              ? context.isLight
                                    ? Colors.black.withValues(alpha: 0.4)
                                    : Colors.white.withValues(alpha: 0.3)
                              : null,
                        ),
                      ),
                    ],
                  ),
                if (chapter.downloadSize != null)
                  Row(
                    children: [
                      const Text(' • '),
                      Text(
                        chapter.downloadSize!,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.isLight
                              ? Colors.black.withValues(alpha: 0.4)
                              : Colors.white.withValues(alpha: 0.3),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            trailing: isEpubShortcut
                ? Text(
                    epubCharacterStart?.toString() ?? '...',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  )
                : isTv || !sourceExist || (manga.isLocalArchive ?? false)
                ? null
                : ChapterPageDownload(chapter: chapter),
          ),
        ),
      ),
    );
  }

  String _chapterNumberTitle({
    required String chapterLabel,
    required String episodeLabel,
  }) {
    final manga = chapter.manga.value;
    final label = manga?.itemType == ItemType.anime
        ? episodeLabel
        : chapterLabel;
    final capitalized = label.isEmpty
        ? label
        : '${label[0].toUpperCase()}${label.substring(1)}';
    return chapterNumberDisplayTitle(
      sourceTitle: chapter.name ?? '',
      mangaTitle: manga?.name ?? '',
      numberLabel: capitalized,
      sourceChapterNumber: chapter.chapterNumber,
    );
  }

  void _handleInteraction(WidgetRef ref, [BuildContext? context]) {
    final isLongPressed = ref.read(isLongPressedStateProvider);
    if (isLongPressed) {
      // Shift-click range selection on desktop
      if (HardwareKeyboard.instance.isShiftPressed) {
        ref
            .read(chaptersListStateProvider.notifier)
            .selectRange(chapter, allChapters);
      } else {
        ref.read(chaptersListStateProvider.notifier).update(chapter);
      }
    } else {
      if (context != null) {
        final chapterId = chapter.id;
        if (chapterId != null && isEpubNavigationChapter(chapter)) {
          final resumesSavedPosition = chapter.lastPageRead?.isNotEmpty == true;
          context.push(
            '/novelReaderView',
            extra: NovelReaderRouteArgs(
              chapterId: chapterId,
              initialEpubSpineIndex: resumesSavedPosition
                  ? null
                  : epubChapterSpineIndex(chapter),
            ),
          );
        } else {
          chapter.pushToReaderView(context, ignoreIsRead: true);
        }
      } else {
        ref.read(chaptersListStateProvider.notifier).update(chapter);
        ref.read(isLongPressedStateProvider.notifier).update(!isLongPressed);
      }
    }
  }

  Widget _buildTitle(String text, BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Make sure that (constraints.maxWidth - (35 + 5)) is strictly positive.
        final double availableWidth = constraints.maxWidth - (35 + 5);
        final textPainter = TextPainter(
          text: TextSpan(text: text, style: const TextStyle(fontSize: 13)),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: availableWidth > 0 ? availableWidth : 1.0); // - Download icon size (download_page_widget.dart, Widget Build SizedBox width: 35)

        final isOverflowing = textPainter.didExceedMaxLines;

        if (isOverflowing) {
          return SizedBox(
            height: 20,
            child: MediaQuery.disableAnimationsOf(context)
                ? Text(
                    text,
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  )
                : Marquee(
                    text: text,
                    style: const TextStyle(fontSize: 13),
                    blankSpace: 40.0,
                    velocity: 30.0,
                    pauseAfterRound: const Duration(seconds: 1),
                    startPadding: 10.0,
                  ),
          );
        } else {
          return Text(
            text,
            style: const TextStyle(fontSize: 13),
            overflow: TextOverflow.ellipsis,
          );
        }
      },
    );
  }

  Widget _thumbnailPreview(BuildContext context, String? imageUrl) {
    final imageProvider = CustomExtendedNetworkImageProvider(
      toImgUrl(imageUrl ?? ""),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
      child: GestureDetector(
        onTap: () {
          _openImage(context, imageProvider);
        },
        child: SizedBox(
          width: 50,
          height: 65,
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

  Future<void> _performSwipeAction(
    ChapterSwipeAction action,
    BuildContext context,
    WidgetRef ref,
  ) async {
    switch (action) {
      case ChapterSwipeAction.toggleBookmark:
        final chap = chapter;
        chap.isBookmarked = !chap.isBookmarked!;
        chapterRepository.save(chap);
        break;
      case ChapterSwipeAction.toggleRead:
        final chap = chapter;
        chap.isRead = !chap.isRead!;
        if (!chap.isRead!) {
          chap.lastPageRead = "1";
        }
        chapterRepository.save(chap);
        break;
      case ChapterSwipeAction.download:
        final download = downloadRepository.getByChapterId(chapter.id);
        if (download != null && download.isDownload == true) {
          await chapter.deleteDownloadedFiles();
        } else {
          if (!isDownloadScheduled(chapter.id)) {
            await downloadRepository.enqueue(chapter);
            if (ref.context.mounted) {
              ref.invalidate(downloadChapterProvider(chapter: chapter));
              ref.read(downloadChapterProvider(chapter: chapter));
            }
          }
        }
        break;
      case ChapterSwipeAction.disabled:
        break;
    }
  }

  Widget _buildSwipeBackground(
    ChapterSwipeAction action,
    BuildContext context,
    Alignment alignment,
  ) {
    if (action == ChapterSwipeAction.disabled) {
      return const SizedBox.shrink();
    }
    Color color;
    IconData icon;
    switch (action) {
      case ChapterSwipeAction.toggleBookmark:
        color = context.primaryColor;
        icon = chapter.isBookmarked!
            ? Icons.bookmark_remove
            : Icons.bookmark_add;
        break;
      case ChapterSwipeAction.toggleRead:
        color = chapter.isRead! ? Colors.grey : Colors.green;
        icon = chapter.isRead! ? Icons.remove_done_sharp : Icons.done_all;
        break;
      case ChapterSwipeAction.download:
        final download = downloadRepository.getByChapterId(chapter.id);
        final isDownloaded = download != null && download.isDownload == true;
        color = isDownloaded ? Colors.red : context.primaryColor;
        icon = isDownloaded ? Icons.delete_outline : Icons.download;
        break;
      case ChapterSwipeAction.disabled:
        return const SizedBox.shrink();
    }

    return Container(
      color: color,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Icon(icon, color: Colors.white),
    );
  }

  void _openImage(BuildContext context, ImageProvider imageProvider) {
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
            ],
          ),
        );
      },
    );
  }
}
