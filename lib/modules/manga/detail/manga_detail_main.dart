import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/manga/detail/manga_details_view.dart';
import 'package:mangayomi/modules/manga/detail/providers/state_providers.dart';
import 'package:mangayomi/modules/manga/detail/providers/update_manga_detail_providers.dart';
import 'package:mangayomi/modules/manga/detail/providers/isar_providers.dart';
import 'package:mangayomi/modules/manga/detail/widgets/manga_chapter_file_drop_target.dart';
import 'package:mangayomi/modules/library/providers/local_archive.dart';
import 'package:mangayomi/modules/widgets/desktop_back_navigation_handler.dart';
import 'package:mangayomi/modules/widgets/error_text.dart';
import 'package:mangayomi/modules/widgets/progress_center.dart';
import 'package:mangayomi/utils/source_lookup.dart';

class MangaReaderDetail extends ConsumerStatefulWidget {
  final int mangaId;
  const MangaReaderDetail({super.key, required this.mangaId});

  @override
  ConsumerState<MangaReaderDetail> createState() => _MangaReaderDetailState();
}

class _MangaReaderDetailState extends ConsumerState<MangaReaderDetail> {
  bool _backNavigationInProgress = false;

  void _goBack() {
    if (_backNavigationInProgress) return;
    _backNavigationInProgress = true;
    ref.read(isLongPressedStateProvider.notifier).update(false);
    ref.read(chaptersListStateProvider.notifier).clear();
    Navigator.of(context).pop();
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Wait for the widget tree to settle before loading detail
    await WidgetsBinding.instance.endOfFrame;
    await ref.read(
      updateMangaDetailProvider(mangaId: widget.mangaId, isInit: true).future,
    );
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  bool _isLoading = true;
  @override
  Widget build(BuildContext context) {
    final manga = ref.watch(
      getMangaDetailStreamProvider(mangaId: widget.mangaId),
    );
    return Scaffold(
      body: manga.when(
        data: (manga) {
          final currentManga = manga;
          if (currentManga == null) return const ProgressCenter();
          // Language filters only hide Browse rows. Installed sources remain
          // available to refresh items already in the library.
          final detail = StreamBuilder(
            stream: isar.sources
                .filter()
                .idIsNotNull()
                .and()
                .isAddedEqualTo(true)
                .watch(fireImmediately: true),
            builder: (context, snapshot) {
              final resolvedSource = snapshot.hasData
                  ? findSourceFromList(
                      snapshot.data!,
                      lang: currentManga.lang!,
                      name: currentManga.source!,
                      sourceId: currentManga.sourceId,
                      installedOnly: true,
                    )
                  : null;
              final sourceExist = resolvedSource != null;
              return RefreshIndicator(
                onRefresh: () async {
                  if (sourceExist && !_isLoading) {
                    await ref.read(
                      updateMangaDetailProvider(
                        mangaId: currentManga.id,
                        isInit: false,
                      ).future,
                    );
                  }
                },
                child: Stack(
                  children: [
                    MangaDetailsView(
                      manga: currentManga,
                      source: resolvedSource,
                      sourceExist: sourceExist,
                      checkForUpdate: (value) async {
                        if (!_isLoading) {
                          setState(() {
                            _isLoading = true;
                          });
                          if (sourceExist) {
                            await ref.read(
                              updateMangaDetailProvider(
                                mangaId: currentManga.id,
                                isInit: false,
                              ).future,
                            );
                          }
                          if (mounted) {
                            setState(() {
                              _isLoading = false;
                            });
                          }
                        }
                      },
                    ),
                    if (_isLoading)
                      const Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: Padding(
                          padding: EdgeInsets.only(top: 40),
                          child: Center(child: RefreshProgressIndicator()),
                        ),
                      ),
                  ],
                ),
              );
            },
          );
          final mediaDetail = currentManga.itemType == ItemType.manga
              ? MangaChapterFileDropTarget(
                  manga: currentManga,
                  onImport: (filePaths) => ref.read(
                    importArchivesFromPathsProvider(
                      itemType: ItemType.manga,
                      currentManga,
                      filePaths: filePaths,
                      init: false,
                      splitChapters: false,
                    ).future,
                  ),
                  child: detail,
                )
              : detail;
          return DesktopBackNavigationScope(
            onBack: _goBack,
            child: Focus(autofocus: true, child: mediaDetail),
          );
        },
        error: (Object error, StackTrace stackTrace) {
          return ErrorText(error);
        },
        loading: () {
          return const ProgressCenter();
        },
      ),
    );
  }
}
