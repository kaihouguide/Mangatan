import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/utils/utils.dart';

Future<void> pushMangaReaderView({
  required BuildContext context,
  required Chapter chapter,
}) async {
  // Do not gate library reading on the Browse language visibility filter.
  // Prefer the source ID: a Mihon factory source's name follows its
  // preferences (Jellyfin's custom label), so an entry saved while the label
  // was not yet applied carries a name no installed source has any more.
  final manga = chapter.manga.value!;
  final sourceExist =
      (manga.sourceId != null &&
          getSource(
                manga.lang!,
                manga.source!,
                manga.sourceId,
                installedOnly: true,
              ) !=
              null) ||
      isar.sources
          .filter()
          .langContains(manga.lang!, caseSensitive: false)
          .and()
          .nameContains(manga.source!, caseSensitive: false)
          .and()
          .idIsNotNull()
          .and()
          .isAddedEqualTo(true)
          .findAllSync()
          .isNotEmpty;
  if (sourceExist || chapter.manga.value!.isLocalArchive!) {
    switch (chapter.manga.value!.itemType) {
      case ItemType.manga:
        await context.push('/mangaReaderView', extra: chapter.id!);
        break;
      case ItemType.anime:
        await context.push('/animePlayerView', extra: chapter.id!);
        break;
      case ItemType.novel:
        await context.push('/novelReaderView', extra: chapter.id!);
        break;
    }
  }
}

void pushReplacementMangaReaderView({
  required BuildContext context,
  required Chapter chapter,
}) {
  switch (chapter.manga.value!.itemType) {
    case ItemType.manga:
      context.pushReplacement('/mangaReaderView', extra: chapter.id!);
      break;
    case ItemType.anime:
      context.pushReplacement('/animePlayerView', extra: chapter.id!);
      break;
    case ItemType.novel:
      context.pushReplacement('/novelReaderView', extra: chapter.id!);
      break;
  }
}
