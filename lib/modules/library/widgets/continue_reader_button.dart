import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/eval/model/m_bridge.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/epub_book_progress.dart';
import 'package:mangayomi/models/history.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/modules/library/providers/local_archive.dart';
import 'package:mangayomi/modules/more/providers/incognito_mode_state_provider.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';
import 'package:mangayomi/utils/extensions/chapter_extensions.dart';
import 'package:mangayomi/services/epub_chapter_metadata.dart';
import 'package:mangayomi/services/sync/chimahon_novel_materializer.dart';

class ContinueReaderButton extends ConsumerWidget {
  final Manga entry;

  const ContinueReaderButton({super.key, required this.entry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder(
      stream: isar.historys
          .filter()
          .mangaIdEqualTo(entry.id!)
          .watch(fireImmediately: true),
      builder: (context, snapshot) => GestureDetector(
        onTap: () async {
          final isMissingEpub =
              entry.itemType == ItemType.novel &&
              entry.isLocalArchive == true &&
              isar.epubBookProgress
                  .filter()
                  .mangaIdEqualTo(entry.id!)
                  .archivePathEqualTo('')
                  .isNotEmptySync();
          if (isMissingEpub) {
            botToast(chimahonMissingEpubGuidance, second: 4);
            try {
              await ref.read(
                importArchivesFromFileProvider(
                  itemType: ItemType.novel,
                  entry,
                  init: false,
                  splitChapters: false,
                ).future,
              );
            } catch (error) {
              botToast('Import failed: $error');
            }
            return;
          }
          if (isLocalEpubManga(entry)) {
            await repairLocalEpubChapterMetadata(entry);
            final shortcuts = epubNavigationChaptersInSpineOrder(
              isar.chapters.filter().mangaIdEqualTo(entry.id).findAllSync(),
            );
            if (context.mounted && shortcuts.isNotEmpty) {
              shortcuts.first.pushToReaderView(context);
            }
            return;
          }
          final incognitoMode = ref.read(incognitoModeStateProvider);
          if (snapshot.hasData && snapshot.data!.isNotEmpty && !incognitoMode) {
            snapshot.data!.first.chapter.value!.pushToReaderView(context);
          } else {
            // A title whose chapters were never fetched has nothing to open.
            userFacingChapters(entry).firstOrNull?.pushToReaderView(context);
          }
        },
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            color: context.primaryColor.withValues(alpha: 0.9),
          ),
          child: const Padding(
            padding: EdgeInsets.all(7),
            child: Icon(Icons.play_arrow, size: 19, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
