import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/l10n/generated/app_localizations.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/download.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/modules/manga/detail/resume_chapter.dart';
import 'package:mangayomi/modules/manga/detail/widgets/chapter_filter_list_tile_widget.dart';
import 'package:mangayomi/modules/manga/detail/widgets/chapter_sort_list_tile_widget.dart';
import 'package:mangayomi/modules/widgets/bottom_text_widget.dart';
import 'package:mangayomi/modules/widgets/cover_view_widget.dart';
import 'package:mangayomi/modules/widgets/custom_draggable_tabbar.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/repositories/history_repository.dart';
import 'package:mangayomi/repositories/manga_repository.dart';
import 'package:mangayomi/services/anime_seasons.dart';
import 'package:mangayomi/utils/cached_network.dart';
import 'package:mangayomi/utils/constant.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';
import 'package:mangayomi/utils/extensions/chapter_extensions.dart';
import 'package:mangayomi/utils/extensions/manga_extensions.dart';
import 'package:mangayomi/utils/headers.dart';

/// The seasons of a series, or the series a season belongs to, laid out the
/// way Anikku and Animiru do: a cover grid (or list) with unseen and download
/// badges, a continue-watching button, and a filter/sort/display sheet.
class AnimeSeasonList extends ConsumerStatefulWidget {
  const AnimeSeasonList({super.key, required this.anime});

  final Manga anime;

  @override
  ConsumerState<AnimeSeasonList> createState() => _AnimeSeasonListState();
}

class _AnimeSeasonListState extends ConsumerState<AnimeSeasonList>
    with TickerProviderStateMixin {
  final _subscriptions = <StreamSubscription<void>>[];
  Timer? _reloadTimer;
  var _generation = 0;

  int? _storedFlags;
  Manga? _parent;
  List<AnimeSeasonEntry>? _entries;

  int get _flags => AnimeSeasonFlags.effective(_storedFlags);

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(AnimeSeasonList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.anime;
    final anime = widget.anime;
    if (old.id != anime.id ||
        old.link != anime.link ||
        old.animeParentUrl != anime.animeParentUrl ||
        old.hasSeasons != anime.hasSeasons) {
      _unsubscribe();
      _entries = null;
      _parent = null;
      _subscribe();
    }
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  void _subscribe() {
    final anime = widget.anime;
    _storedFlags = anime.seasonFlags;
    final id = anime.id;
    if (id != null) {
      _subscriptions.add(
        isar.mangas.watchObject(id).listen((current) {
          if (!mounted || current == null) return;
          if (current.seasonFlags != _storedFlags) {
            setState(() => _storedFlags = current.seasonFlags);
          }
        }),
      );
    }
    final link = anime.link;
    if (anime.hasSeasons && link != null) {
      // Only this series' seasons and their episodes can change what is shown,
      // so watching the whole anime table would rebuild on every playback save
      // of any title. Download progress ticks often, hence the debounce.
      _subscriptions
        ..add(_seasonQuery(link).watchLazy().listen((_) => _scheduleReload()))
        ..add(
          isar.chapters
              .filter()
              .manga((q) => q.animeParentUrlEqualTo(link))
              .watchLazy()
              .listen((_) => _scheduleReload()),
        )
        ..add(isar.downloads.watchLazy().listen((_) => _scheduleReload()));
    }
    _reload();
  }

  void _unsubscribe() {
    _reloadTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _generation++;
  }

  QueryBuilder<Manga, Manga, QAfterFilterCondition> _seasonQuery(String link) =>
      isar.mangas
          .filter()
          .itemTypeEqualTo(ItemType.anime)
          .animeParentUrlEqualTo(link);

  void _scheduleReload() {
    _reloadTimer?.cancel();
    _reloadTimer = Timer(const Duration(milliseconds: 250), _reload);
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    final anime = widget.anime;

    Manga? parent;
    final parentUrl = anime.animeParentUrl;
    if (parentUrl != null) {
      parent =
          (await isar.mangas
                  .filter()
                  .itemTypeEqualTo(ItemType.anime)
                  .linkEqualTo(parentUrl)
                  .findAll())
              .where((candidate) => sameAnimeSource(candidate, anime))
              .firstOrNull;
    }

    final entries = <AnimeSeasonEntry>[];
    final link = anime.link;
    if (anime.hasSeasons && link != null) {
      final seasons = (await _seasonQuery(
        link,
      ).findAll()).where((season) => sameAnimeSource(season, anime)).toList();
      final stats = await Future.wait(seasons.map(_loadStats));
      for (final (index, season) in seasons.indexed) {
        entries.add((season: season, stats: stats[index]));
      }
    }

    if (!mounted || generation != _generation) return;
    setState(() {
      _parent = parent;
      _entries = entries;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nLocalizations(context)!;
    final entries = _entries;
    final flags = _flags;
    final visible = entries == null
        ? const <AnimeSeasonEntry>[]
        : filterAndSortAnimeSeasons(entries, flags);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_parent != null) _ParentTile(parent: _parent!),
        if (widget.anime.hasSeasons) ...[
          _header(context, l10n, entries?.length),
          if (entries == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (visible.isEmpty && entries.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                l10n.no_seasons_match_filters,
                textAlign: TextAlign.center,
              ),
            )
          else
            _seasons(context, l10n, visible, flags),
        ],
      ],
    );
  }

  Widget _header(BuildContext context, AppLocalizations l10n, int? count) {
    final filtered = AnimeSeasonFlags.hasActiveFilters(_flags);
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              count == null ? l10n.seasons : l10n.season_count(count),
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          IconButton(
            tooltip: l10n.filter,
            icon: Icon(
              Icons.filter_list,
              color: filtered ? context.primaryColor : null,
            ),
            onPressed: () => _showSettings(context, l10n),
          ),
        ],
      ),
    );
  }

  Widget _seasons(
    BuildContext context,
    AppLocalizations l10n,
    List<AnimeSeasonEntry> visible,
    int flags,
  ) {
    final mode = AnimeSeasonFlags.displayMode(flags);
    if (mode == AnimeSeasonDisplayMode.list) {
      return Column(
        children: [
          for (final entry in visible)
            _SeasonListTile(
              key: ValueKey(entry.season.id),
              entry: entry,
              flags: flags,
              onOpen: () => _open(entry.season),
              onContinue: () => _continueWatching(entry.season),
            ),
        ],
      );
    }
    final columns = AnimeSeasonFlags.gridSize(flags);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      gridDelegate: columns > 0
          ? SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              childAspectRatio: _aspectRatio(mode),
            )
          : SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 160,
              childAspectRatio: _aspectRatio(mode),
            ),
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final entry = visible[index];
        return _SeasonGridItem(
          key: ValueKey(entry.season.id),
          entry: entry,
          flags: flags,
          onOpen: () => _open(entry.season),
          onContinue: () => _continueWatching(entry.season),
        );
      },
    );
  }

  double _aspectRatio(AnimeSeasonDisplayMode mode) =>
      mode == AnimeSeasonDisplayMode.comfortableGrid ? 0.55 : 0.68;

  void _open(Manga season) {
    final id = season.id;
    if (id != null) context.push('/manga-reader/detail', extra: id);
  }

  /// Plays the season's next unwatched episode, resuming from its history.
  Future<void> _continueWatching(Manga season) async {
    final id = season.id;
    if (id == null) return;
    final current = await mangaRepository.findByIdAsync(id);
    if (current == null || !mounted) return;
    final history = historyRepository.getAllByMangaId(id);
    Chapter? historyChapter;
    if (history.isNotEmpty) {
      history.first.chapter.loadSync();
      historyChapter = history.first.chapter.value;
    }
    final episode = selectResumeChapter(
      current.getChapterListForReading(),
      historyChapter: historyChapter,
    );
    if (episode == null || !mounted) {
      _open(season);
      return;
    }
    await episode.pushToReaderView(context, ignoreIsRead: true);
  }

  Future<void> _setFlags(int Function(int flags) change) async {
    final id = widget.anime.id;
    if (id == null) return;
    final next = change(_flags);
    setState(() => _storedFlags = next);
    await mangaRepository.writeTransaction(() {
      final current = isar.mangas.getSync(id);
      if (current == null) return;
      current
        ..seasonFlags = next
        ..updatedAt = DateTime.now().millisecondsSinceEpoch;
      isar.mangas.putSync(current);
    });
  }

  void _showSettings(BuildContext context, AppLocalizations l10n) {
    customDraggableTabBar(
      tabs: [
        Tab(text: l10n.filter),
        Tab(text: l10n.sort),
        Tab(text: l10n.display),
      ],
      children: [
        _FlagsBuilder(
          animeId: widget.anime.id!,
          builder: (flags) => _filterPage(l10n, flags),
        ),
        _FlagsBuilder(
          animeId: widget.anime.id!,
          builder: (flags) => _sortPage(l10n, flags),
        ),
        _FlagsBuilder(
          animeId: widget.anime.id!,
          builder: (flags) => _displayPage(context, l10n, flags),
        ),
      ],
      context: context,
      vsync: this,
    );
  }

  Widget _filterPage(AppLocalizations l10n, int flags) {
    Widget item(String label, int include, int exclude) {
      final state = AnimeSeasonFlags.filter(flags, include, exclude);
      return ListTileChapterFilter(
        label: label,
        type: state.index,
        onTap: () => _setFlags(
          (flags) => AnimeSeasonFlags.withFilter(
            flags,
            include,
            exclude,
            AnimeSeasonFilter.values[(state.index + 1) % 3],
          ),
        ),
      );
    }

    return Column(
      children: [
        item(
          l10n.downloaded,
          AnimeSeasonFlags.showDownloaded,
          AnimeSeasonFlags.showNotDownloaded,
        ),
        item(
          l10n.unwatched,
          AnimeSeasonFlags.showUnseen,
          AnimeSeasonFlags.showSeen,
        ),
        item(
          l10n.started,
          AnimeSeasonFlags.showStarted,
          AnimeSeasonFlags.showNotStarted,
        ),
        item(
          l10n.completed,
          AnimeSeasonFlags.showCompleted,
          AnimeSeasonFlags.showNotCompleted,
        ),
        item(
          l10n.bookmarked,
          AnimeSeasonFlags.showBookmarked,
          AnimeSeasonFlags.showNotBookmarked,
        ),
        item(
          l10n.filler,
          AnimeSeasonFlags.showFillermarked,
          AnimeSeasonFlags.showNotFillermarked,
        ),
      ],
    );
  }

  Widget _sortPage(AppLocalizations l10n, int flags) {
    final sorts = [
      (l10n.by_source, AnimeSeasonFlags.sortSource),
      (l10n.season_number, AnimeSeasonFlags.sortSeasonNumber),
      (l10n.by_upload_date, AnimeSeasonFlags.sortUploadDate),
      (l10n.alphabetically, AnimeSeasonFlags.sortAlphabetical),
      (l10n.unwatched_count, AnimeSeasonFlags.sortUnseen),
      (l10n.last_watched, AnimeSeasonFlags.sortLastSeen),
      (l10n.episode_fetch_date, AnimeSeasonFlags.sortFetchDate),
    ];
    return Column(
      children: [
        for (final (label, sort) in sorts)
          ListTileChapterSort(
            label: label,
            reverse: AnimeSeasonFlags.isAscending(flags),
            showLeading: AnimeSeasonFlags.sortMode(flags) == sort,
            onTap: () => _setFlags(
              (flags) => AnimeSeasonFlags.withSortOrFlip(flags, sort),
            ),
          ),
      ],
    );
  }

  Widget _displayPage(BuildContext context, AppLocalizations l10n, int flags) {
    final mode = AnimeSeasonFlags.displayMode(flags);
    final modes = [
      (l10n.compact_grid, AnimeSeasonDisplayMode.compactGrid),
      (l10n.comfortable_grid, AnimeSeasonDisplayMode.comfortableGrid),
      (l10n.cover_only_grid, AnimeSeasonDisplayMode.coverOnlyGrid),
      (l10n.list, AnimeSeasonDisplayMode.list),
    ];
    Widget overlay(String label, int mask) => SwitchListTile(
      dense: true,
      title: Text(label),
      value: AnimeSeasonFlags.isSet(flags, mask),
      onChanged: (enabled) =>
          _setFlags((flags) => AnimeSeasonFlags.withBit(flags, mask, enabled)),
    );
    final size = AnimeSeasonFlags.gridSize(flags);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(l10n.display_mode),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            children: [
              for (final (label, value) in modes)
                ChoiceChip(
                  label: Text(label),
                  selected: mode == value,
                  onSelected: (_) => _setFlags(
                    (flags) => AnimeSeasonFlags.withDisplayMode(flags, value),
                  ),
                ),
            ],
          ),
        ),
        if (mode != AnimeSeasonDisplayMode.list)
          ListTile(
            dense: true,
            title: Text(l10n.grid_size),
            subtitle: Slider(
              value: size.toDouble(),
              max: 10,
              divisions: 10,
              label: size == 0 ? 'Auto' : '$size',
              onChanged: (value) => _setFlags(
                (flags) => AnimeSeasonFlags.withGridSize(flags, value.round()),
              ),
            ),
          ),
        _SectionTitle(l10n.season_title),
        RadioGroup<bool>(
          groupValue: AnimeSeasonFlags.isSet(
            flags,
            AnimeSeasonFlags.displayModeNumber,
          ),
          onChanged: (byNumber) => _setFlags(
            (flags) => AnimeSeasonFlags.withBit(
              flags,
              AnimeSeasonFlags.displayModeNumber,
              byNumber ?? false,
            ),
          ),
          child: Column(
            children: [
              RadioListTile<bool>(
                dense: true,
                value: false,
                title: Text(l10n.source_title),
              ),
              RadioListTile<bool>(
                dense: true,
                value: true,
                title: Text(l10n.season_number),
              ),
            ],
          ),
        ),
        _SectionTitle(l10n.badges),
        overlay(
          l10n.downloaded_episodes,
          AnimeSeasonFlags.overlayDownloadedMask,
        ),
        overlay(l10n.unwatched_episodes, AnimeSeasonFlags.overlayUnseenMask),
        overlay(l10n.local_source, AnimeSeasonFlags.overlayLocalMask),
        overlay(l10n.language, AnimeSeasonFlags.overlayLanguageMask),
        overlay(
          l10n.show_continue_watching_buttons,
          AnimeSeasonFlags.overlayContinueMask,
        ),
      ],
    );
  }
}

Future<AnimeSeasonStats> _loadStats(Manga season) async {
  final id = season.id;
  if (id == null) return const AnimeSeasonStats();
  QueryBuilder<Chapter, Chapter, QAfterFilterCondition> episodes() =>
      isar.chapters.filter().mangaIdEqualTo(id);
  final (uploads, total, seen, bookmarks, fillers, downloads) = await (
    episodes().dateUploadProperty().findAll(),
    episodes().count(),
    episodes().isReadEqualTo(true).count(),
    episodes().isBookmarkedEqualTo(true).count(),
    episodes().isFillerEqualTo(true).count(),
    isar.downloads
        .filter()
        .isDownloadEqualTo(true)
        .chapter((q) => q.mangaIdEqualTo(id))
        .count(),
  ).wait;
  return AnimeSeasonStats(
    totalCount: total,
    seenCount: seen,
    bookmarkCount: bookmarks,
    fillermarkCount: fillers,
    downloadCount: downloads,
    latestUpload: uploads.map(_uploadMillis).fold(0, (a, b) => a > b ? a : b),
    fetchedAt: season.lastUpdate ?? 0,
    lastSeen: season.lastRead ?? 0,
  );
}

int _uploadMillis(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return 0;
  return int.tryParse(value) ??
      DateTime.tryParse(value)?.millisecondsSinceEpoch ??
      0;
}

String _seasonTitle(AppLocalizations l10n, Manga season, int flags) =>
    AnimeSeasonFlags.isSet(flags, AnimeSeasonFlags.displayModeNumber)
    ? l10n.season_n(animeSeasonNumberLabel(season.seasonNumber))
    : season.name ?? '';

bool _showsContinue(AnimeSeasonEntry entry, int flags) =>
    AnimeSeasonFlags.isSet(flags, AnimeSeasonFlags.overlayContinueMask) &&
    entry.stats.unseenCount > 0;

class _SeasonCover {
  static ImageProvider? of(WidgetRef ref, Manga season) {
    final custom = season.customCoverImage;
    if (custom != null) return MemoryImage(custom as Uint8List);
    final url = season.customCoverFromTracker ?? season.imageUrl;
    if (url == null || url.isEmpty) return null;
    return coverProvider(
      toImgUrl(url),
      headers: ref.watch(
        headersProvider(
          source: season.source ?? '',
          lang: season.lang ?? '',
          sourceId: season.sourceId,
        ),
      ),
      cacheMaxAge: const Duration(days: 7),
    );
  }
}

class _SeasonGridItem extends ConsumerWidget {
  const _SeasonGridItem({
    super.key,
    required this.entry,
    required this.flags,
    required this.onOpen,
    required this.onContinue,
  });

  final AnimeSeasonEntry entry;
  final int flags;
  final VoidCallback onOpen;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = l10nLocalizations(context)!;
    final mode = AnimeSeasonFlags.displayMode(flags);
    final comfortable = mode == AnimeSeasonDisplayMode.comfortableGrid;
    final title = _seasonTitle(l10n, entry.season, flags);
    final stats = entry.stats;
    return CoverViewWidget(
      isComfortableGrid: comfortable,
      image: _SeasonCover.of(ref, entry.season),
      progress: stats.totalCount == 0 ? 0 : stats.seenCount / stats.totalCount,
      onTap: onOpen,
      onLongPress: onOpen,
      bottomTextWidget: BottomTextWidget(
        text: title,
        maxLines: 2,
        isComfortableGrid: comfortable,
      ),
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: _SeasonBadges(entry: entry, flags: flags),
          ),
        ),
        if (mode == AnimeSeasonDisplayMode.compactGrid)
          BottomTextWidget(text: title, maxLines: 2),
        if (_showsContinue(entry, flags))
          Positioned(
            right: 4,
            bottom: mode == AnimeSeasonDisplayMode.compactGrid ? 36 : 4,
            child: _ContinueButton(onPressed: onContinue),
          ),
      ],
    );
  }
}

class _SeasonListTile extends ConsumerWidget {
  const _SeasonListTile({
    super.key,
    required this.entry,
    required this.flags,
    required this.onOpen,
    required this.onContinue,
  });

  final AnimeSeasonEntry entry;
  final int flags;
  final VoidCallback onOpen;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = l10nLocalizations(context)!;
    final image = _SeasonCover.of(ref, entry.season);
    final stats = entry.stats;
    return ListTile(
      onTap: onOpen,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 40,
          height: 56,
          child: image == null
              ? ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.video_library_outlined),
                )
              : Image(image: image, fit: BoxFit.cover),
        ),
      ),
      title: Text(
        _seasonTitle(l10n, entry.season, flags),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: stats.totalCount == 0
          ? null
          : Text('${stats.seenCount}/${l10n.n_episodes(stats.totalCount)}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SeasonBadges(entry: entry, flags: flags),
          if (_showsContinue(entry, flags))
            _ContinueButton(onPressed: onContinue),
        ],
      ),
    );
  }
}

class _SeasonBadges extends StatelessWidget {
  const _SeasonBadges({required this.entry, required this.flags});

  final AnimeSeasonEntry entry;
  final int flags;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final season = entry.season;
    final stats = entry.stats;
    final start = <Widget>[
      if (AnimeSeasonFlags.isSet(
            flags,
            AnimeSeasonFlags.overlayDownloadedMask,
          ) &&
          stats.downloadCount > 0)
        _Badge(
          text: '${stats.downloadCount}',
          background: scheme.tertiary,
          foreground: scheme.onTertiary,
        ),
      if (AnimeSeasonFlags.isSet(flags, AnimeSeasonFlags.overlayUnseenMask) &&
          stats.unseenCount > 0)
        _Badge(
          text: '${stats.unseenCount}',
          background: scheme.primary,
          foreground: scheme.onPrimary,
        ),
    ];
    final end = <Widget>[
      if (AnimeSeasonFlags.isSet(flags, AnimeSeasonFlags.overlayLocalMask) &&
          season.isLocalArchive == true)
        _Badge(
          icon: Icons.folder_outlined,
          background: scheme.secondary,
          foreground: scheme.onSecondary,
        )
      else if (AnimeSeasonFlags.isSet(
            flags,
            AnimeSeasonFlags.overlayLanguageMask,
          ) &&
          (season.lang?.isNotEmpty ?? false))
        _Badge(
          text: season.lang!.toUpperCase(),
          background: scheme.secondary,
          foreground: scheme.onSecondary,
        ),
    ];
    if (start.isEmpty && end.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ...start,
        if (start.isNotEmpty && end.isNotEmpty) const SizedBox(width: 4),
        ...end,
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    this.text,
    this.icon,
    required this.background,
    required this.foreground,
  });

  final String? text;
  final IconData? icon;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(4),
    ),
    child: icon != null
        ? Icon(icon, size: 14, color: foreground)
        : Text(
            text!,
            style: TextStyle(
              color: foreground,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
  );
}

class _ContinueButton extends StatelessWidget {
  const _ContinueButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer.withValues(alpha: 0.9),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            Icons.play_arrow,
            size: 18,
            color: scheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}

class _ParentTile extends ConsumerWidget {
  const _ParentTile({required this.parent});

  final Manga parent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final image = _SeasonCover.of(ref, parent);
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 40,
          height: 56,
          child: image == null
              ? const Icon(Icons.tv)
              : Image(image: image, fit: BoxFit.cover),
        ),
      ),
      title: Text(parent.name ?? ''),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        final id = parent.id;
        if (id != null) context.push('/manga-reader/detail', extra: id);
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(color: context.primaryColor),
    ),
  );
}

/// Rebuilds one settings page whenever the anime's season flags change, since
/// the draggable sheet's pages are built once when it opens.
class _FlagsBuilder extends StatelessWidget {
  const _FlagsBuilder({required this.animeId, required this.builder});

  final int animeId;
  final Widget Function(int flags) builder;

  @override
  Widget build(BuildContext context) => StreamBuilder<Manga?>(
    stream: isar.mangas.watchObject(animeId, fireImmediately: true),
    builder: (context, snapshot) =>
        builder(AnimeSeasonFlags.effective(snapshot.data?.seasonFlags)),
  );
}
