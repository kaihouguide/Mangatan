import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangayomi/eval/model/m_manga.dart';
import 'package:mangayomi/modules/manga/detail/widgets/custom_floating_action_btn.dart';
import 'package:mangayomi/modules/manga/detail/resume_chapter.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/widgets/category_selection_dialog.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/repositories/category_repository.dart';
import 'package:mangayomi/repositories/history_repository.dart';
import 'package:mangayomi/repositories/manga_repository.dart';
import 'package:mangayomi/repositories/source_repository.dart';
import 'package:mangayomi/services/get_detail.dart';
import 'package:mangayomi/modules/mass_migration/services/mass_migration_service.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';
import 'package:mangayomi/utils/constant.dart';
import 'package:mangayomi/utils/error_toast.dart';
import 'package:mangayomi/modules/manga/detail/manga_detail_view.dart';
import 'package:mangayomi/modules/manga/detail/providers/state_providers.dart';
import 'package:mangayomi/modules/more/providers/incognito_mode_state_provider.dart';
import 'package:mangayomi/utils/extensions/chapter_extensions.dart';
import 'package:mangayomi/utils/extensions/manga_extensions.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/history.dart';
import 'package:mangayomi/modules/manga/detail/providers/isar_providers.dart';

String mangaDetailValueOrFallback(String? value, String fallback) =>
    value == null || value.isEmpty ? fallback : value;

enum _DuplicateLibraryAction { addAnyway, migrate }

class MangaDetailsView extends ConsumerStatefulWidget {
  final Manga manga;
  final Source? source;
  final bool sourceExist;
  final Function(bool) checkForUpdate;
  const MangaDetailsView({
    super.key,
    required this.sourceExist,
    required this.manga,
    this.source,
    required this.checkForUpdate,
  });

  @override
  ConsumerState<MangaDetailsView> createState() => _MangaDetailsViewState();
}

class _MangaDetailsViewState extends ConsumerState<MangaDetailsView> {
  // One subscription for the page's lifetime; recreating the stream on every
  // rebuild made the button fall back to "Watch" until history re-emitted.
  late final Stream<List<History>> _history = historyRepository.watchByMangaId(
    widget.manga.id!,
  );

  /// "Add to library" entry point: checks whether this exact title is
  /// already favorited under a different source first, so the same manga
  /// can't end up as two separate library entries by accident. Only warns —
  /// the underlying add still runs unchanged when there's no duplicate, or
  /// once the user picks Add Anyway.
  Future<void> _onAddToLibraryPressed(BuildContext context) async {
    final model = widget.manga;
    final duplicates = (await mangaRepository.findFavoritesByItemTypeAndName(
      model.itemType,
      model.name,
    )).where((m) => m.id != model.id).toList();

    if (duplicates.isNotEmpty) {
      final oldManga = duplicates.first;
      final oldSource = oldManga.sourceId != null
          ? sourceRepository.getById(oldManga.sourceId!)
          : null;
      if (!context.mounted) return;
      final action = await _showAlreadyInLibraryDialog(
        context,
        model,
        oldSource?.name ?? '',
      );
      if (action == null) return;
      if (!context.mounted) return;
      if (action == _DuplicateLibraryAction.migrate) {
        await _migrateExistingToThisSource(context, oldManga, model);
        return;
      }
      // addAnyway falls through to the normal add below.
    }
    if (context.mounted) await _addToLibrary(context, model);
  }

  Future<void> _addToLibrary(BuildContext context, Manga model) async {
    final checkCategoryList = categoryRepository.isNotEmptyByItemType(
      model.itemType,
    );
    if (checkCategoryList) {
      showCategorySelectionDialog(
        context: context,
        ref: ref,
        itemType: model.itemType,
        singleManga: model,
      );
    } else {
      // put, not save: updateFavorite already set the sync clock's updatedAt.
      model.updateFavorite(true);
      model.dateAdded = DateTime.now().millisecondsSinceEpoch;
      await mangaRepository.put(model);
    }
  }

  Future<_DuplicateLibraryAction?> _showAlreadyInLibraryDialog(
    BuildContext context,
    Manga model,
    String oldSourceName,
  ) {
    final l10n = l10nLocalizations(context)!;
    return showDialog<_DuplicateLibraryAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(model.name ?? ''),
        content: Text(l10n.already_in_library(oldSourceName, model.name ?? '')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, _DuplicateLibraryAction.addAnyway),
            child: Text(l10n.add_anyway),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, _DuplicateLibraryAction.migrate),
            child: Text(l10n.migrate),
          ),
        ],
      ),
    );
  }

  /// Rewrites [oldManga] (the existing library entry) to track this source
  /// instead, folding in its chapters/progress via the same path the manual
  /// Migrate screen uses, then drops [newManga] — the row for the page
  /// currently open — since its data is now redundant with the migrated
  /// [oldManga].
  Future<void> _migrateExistingToThisSource(
    BuildContext context,
    Manga oldManga,
    Manga newManga,
  ) async {
    if (newManga.sourceId == null || newManga.link == null) return;
    final destinationSource = sourceRepository.getById(newManga.sourceId!);
    if (destinationSource == null) return;

    final selectedManga = MManga(
      name: newManga.name,
      link: newManga.link,
      imageUrl: newManga.imageUrl,
    );
    try {
      final preview = await ref.read(
        getDetailProvider(
          url: newManga.link!,
          source: destinationSource,
        ).future,
      );
      await migrateLibraryItem(
        ref: ref,
        oldManga: oldManga,
        selectedManga: selectedManga,
        preview: preview,
        destinationSource: destinationSource,
      );
      await mangaRepository.deleteLibrarySourceGroup([newManga]);
    } catch (error, stack) {
      toastError(error, stack: stack, source: 'library-duplicate-migrate');
      return;
    }
    if (context.mounted) Navigator.pop(context);
  }

  Size measureText(String text, TextStyle style) {
    final TextPainter textPainter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    return textPainter.size;
  }

  double calculateDynamicButtonWidth(
    String text,
    TextStyle textStyle,
    double padding,
  ) {
    final textSize = measureText(text, textStyle);
    return textSize.width + padding;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nLocalizations(context)!;
    bool? isLocalArchive = widget.manga.isLocalArchive ?? false;
    final sourceName = mangaDetailValueOrFallback(
      widget.source?.name ?? widget.manga.source,
      l10n.unknown,
    );
    final sourceLanguage = mangaDetailValueOrFallback(
      widget.source?.lang ?? widget.manga.lang,
      l10n.unknown,
    );
    return Scaffold(
      floatingActionButton: Consumer(
        builder: (context, ref, child) {
          if (ref.watch(isLongPressedStateProvider)) return Container();
          // Read this title's own episodes. A shared "current chapter list"
          // would be overwritten by any other detail page still open below
          // this one, such as the series page behind a season.
          final rows =
              ref
                  .watch(getChaptersStreamProvider(mangaId: widget.manga.id!))
                  .value ??
              const <Chapter>[];
          final chaptersList = widget.manga.getSortedFilteredChapters(
            sourceChapters: rows,
          );
          final isExtended = ref.watch(isExtendedStateProvider);
          if (!chaptersList.any((element) => element.isRead != true)) {
            return Container();
          }
          return StreamBuilder<List<History>>(
            stream: _history,
            builder: (context, snapshot) {
              String buttonLabel = widget.manga.itemType != ItemType.anime
                  ? l10n.read
                  : l10n.watch;
              Chapter? historyChapter;
              final incognitoMode = ref.watch(incognitoModeStateProvider);
              final entries = snapshot.data ?? const <History>[];
              if (entries.isNotEmpty && !incognitoMode) {
                historyChapter = entries.last.chapter.value;
                buttonLabel = l10n.resume;
              }
              final chapter = selectResumeChapter(
                widget.manga.getChapterListForReading(
                  sourceChapters: chaptersList,
                ),
                historyChapter: historyChapter,
              );
              return CustomFloatingActionBtn(
                isExtended: !isExtended,
                label: buttonLabel,
                onPressed: () {
                  chapter?.pushToReaderView(context);
                },
              );
            },
          );
        },
      ),
      body: MangaDetailView(
        titleDescription: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Icon(Icons.person_outline, size: 14),
                const SizedBox(width: 4),
                Text(
                  mangaDetailValueOrFallback(widget.manga.author, l10n.unknown),
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ],
            ),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Icon(getMangaStatusIcon(widget.manga.status), size: 14),
                const SizedBox(width: 4),
                Text(getMangaStatusName(widget.manga.status, context)),
                if (!isLocalArchive) const Text(' • '),
                if (!isLocalArchive) Text(sourceName),
                if (!isLocalArchive) Text(' (${sourceLanguage.toUpperCase()})'),
                if (!isLocalArchive && !widget.sourceExist)
                  const Padding(
                    padding: EdgeInsets.all(3),
                    child: Icon(
                      Icons.warning_amber,
                      color: Colors.deepOrangeAccent,
                      size: 14,
                    ),
                  ),
              ],
            ),
          ],
        ),
        action: widget.manga.favorite!
            ? SizedBox(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                    elevation: 0,
                  ),
                  onPressed: () async {
                    final model = widget.manga;
                    model.updateFavorite(false);
                    model.dateAdded = 0;
                    await mangaRepository.put(model);
                  },
                  child: Column(
                    children: [
                      const Icon(Icons.favorite, size: 20),
                      const SizedBox(height: 4),
                      Text(
                        l10n.in_library,
                        style: const TextStyle(fontSize: 11),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              )
            : ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                  elevation: 0,
                ),
                onPressed: () => _onAddToLibraryPressed(context),
                child: Column(
                  children: [
                    Icon(
                      Icons.favorite_border_rounded,
                      size: 20,
                      color: context.secondaryColor,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.add_to_library,
                      style: TextStyle(
                        color: context.secondaryColor,
                        fontSize: 11,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
        manga: widget.manga,
        isExtended: (value) {
          ref.read(isExtendedStateProvider.notifier).update(value);
        },
        sourceExist: widget.sourceExist,
        checkForUpdate: widget.checkForUpdate,
        itemType: widget.manga.itemType,
      ),
    );
  }
}
