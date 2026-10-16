import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/repositories/source_repository.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/modules/browse/widgets/source_extension_icon.dart';
import 'package:mangayomi/modules/mining/widgets/dictionary_profile_override_dialog.dart';
import 'package:mangayomi/modules/widgets/tv_row_button.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/services/mining/dictionary_profile_resolver.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';
import 'package:mangayomi/utils/item_type_localization.dart';
import 'package:mangayomi/utils/language.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';

class SourceListTile extends StatelessWidget {
  final ItemType itemType;
  final Source source;

  bool get isLocal => source.name == "local" && source.lang == "";

  const SourceListTile({
    super.key,
    required this.source,
    required this.itemType,
  });

  @override
  Widget build(BuildContext context) {
    final dictionaryProfileSourceId =
        DictionaryProfileResolver.overrideIdForSource(source);
    return Consumer(
      builder: (context, ref, child) => ListTile(
        onTap: () {
          if (!isLocal) {
            final sources = isar.sources
                .filter()
                .idIsNotNull()
                .and()
                .itemTypeEqualTo(itemType)
                .findAllSync();
            isar.writeTxnSync(() {
              for (var src in sources) {
                isar.sources.putSync(
                  src
                    ..lastUsed = src.id == source.id ? true : false
                    ..updatedAt = DateTime.now().millisecondsSinceEpoch,
                );
              }
            });
          }
          context.push('/mangaHome', extra: (source, false));
        },
        leading: Container(
          height: 37,
          width: 37,
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).secondaryHeaderColor.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(5),
          ),
          child: SourceExtensionIcon(source: source, size: 37),
        ),
        subtitle: Row(
          children: [
            Text(
              completeLanguageName(source.lang!.toLowerCase()),
              style: const TextStyle(fontWeight: FontWeight.w300, fontSize: 12),
            ),
            if (source.isNsfw ?? false)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    "NSFW",
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
          ],
        ),
        title: Text(
          !isLocal
              ? source.name!
              : "${context.l10n.local_source} ${source.itemType.localized(context.l10n)}",
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Consumer(
              builder: (context, ref, child) {
                // final supportsLatest =  ref.watch(supportsLatestProvider(source: source));
                // if (supportsLatest) {
                return TextButton(
                  style: const ButtonStyle(
                    padding: WidgetStatePropertyAll(EdgeInsets.all(10)),
                  ),
                  onPressed: () =>
                      context.push('/mangaHome', extra: (source, true)),
                  child: Text(context.l10n.latest),
                );
                // }
                // return const SizedBox.shrink();
              },
            ),
            const SizedBox(width: 10),
            if (!isLocal) ...[
              if (dictionaryProfileSourceId != null)
                IconButton(
                  tooltip: 'Set dictionary profile',
                  onPressed: () async {
                    await showDictionaryProfileOverrideDialog(
                      context: context,
                      overrideKey: DictionaryProfileResolver.sourceOverrideKey(
                        dictionaryProfileSourceId,
                      ),
                      autoProfile: DictionaryProfileResolver.resolve(
                        sourceLanguage:
                            DictionaryProfileResolver.sourceLanguageForSource(
                              source,
                            ),
                      ),
                      title: 'Dictionary profile for this source',
                    );
                  },
                  icon: const Icon(Icons.menu_book_outlined),
                ),
              IconButton(
                padding: const EdgeInsets.all(0),
                onPressed: () {
                  isar.writeTxnSync(
                    () => isar.sources.putSync(
                      source
                        ..isPinned = !source.isPinned!
                        ..updatedAt = DateTime.now().millisecondsSinceEpoch,
                    ),
                  );
                },
                icon: Icon(
                  Icons.push_pin_outlined,
                  color: source.isPinned! ? context.primaryColor : null,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// D-pad-friendly source row used by the Android TV source browser.
class TvSourceRow extends StatelessWidget {
  final Source source;
  final ItemType itemType;
  final FocusNode? sourceNode;
  final FocusNode? latestNode;
  final FocusNode? pinNode;

  const TvSourceRow({
    super.key,
    required this.source,
    required this.itemType,
    this.sourceNode,
    this.latestNode,
    this.pinNode,
  });

  bool get isLocal => source.name == "local" && source.lang == "";

  void _openPopular(BuildContext context) {
    if (!isLocal) {
      final sources = isar.sources
          .filter()
          .idIsNotNull()
          .and()
          .itemTypeEqualTo(itemType)
          .findAllSync();
      isar.writeTxnSync(() {
        for (final src in sources) {
          isar.sources.putSync(
            src
              ..lastUsed = src.id == source.id
              ..updatedAt = DateTime.now().millisecondsSinceEpoch,
          );
        }
      });
    }
    context.push('/mangaHome', extra: (source, false));
  }

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, child) => TvListRow(
        children: [
          Expanded(
            child: TvRowButton(
              focusNode: sourceNode,
              onTap: () => _openPopular(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Container(
                      height: 37,
                      width: 37,
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).secondaryHeaderColor.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: SourceExtensionIcon(source: source, size: 37),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            !isLocal
                                ? source.name!
                                : "${context.l10n.local_source} ${source.itemType.localized(context.l10n)}",
                            style: const TextStyle(fontSize: 16),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Row(
                            children: [
                              Text(
                                completeLanguageName(
                                  source.lang!.toLowerCase(),
                                ),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w300,
                                  fontSize: 12,
                                ),
                              ),
                              if (source.isNsfw ?? false)
                                Padding(
                                  padding: const EdgeInsets.only(left: 4),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.red.withValues(alpha: 0.8),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      "NSFW",
                                      style: TextStyle(
                                        fontSize: 8,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          TvRowButton(
            focusNode: latestNode,
            onTap: () => context.push('/mangaHome', extra: (source, true)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Text(
                context.l10n.latest,
                style: TextStyle(color: context.primaryColor),
              ),
            ),
          ),
          if (!isLocal) ...[
            const SizedBox(width: 6),
            TvRowButton(
              focusNode: pinNode,
              onTap: () {
                sourceRepository.save(source..isPinned = !source.isPinned!);
              },
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Icon(
                  Icons.push_pin_outlined,
                  color: source.isPinned! ? context.primaryColor : null,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
