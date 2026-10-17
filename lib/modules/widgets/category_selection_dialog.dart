import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/modules/library/providers/library_state_provider.dart';
import 'package:mangayomi/modules/manga/detail/providers/state_providers.dart';
import 'package:mangayomi/modules/manga/detail/widgets/chapter_filter_list_tile_widget.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/services/category_service.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:mangayomi/repositories/category_repository.dart';
import 'package:mangayomi/repositories/manga_repository.dart';

void showCategorySelectionDialog({
  required BuildContext context,
  required WidgetRef ref,
  required ItemType itemType,
  Manga? singleManga,
  List<Manga>? bulkMangas,
}) {
  assert(
    (singleManga != null) ^ (bulkMangas != null),
    "Provide either singleManga or bulkMangas, not both.",
  );
  final l10n = l10nLocalizations(context)!;
  final bool isBulk = bulkMangas != null;
  final bool isLibraryVisible = !isBulk && singleManga!.isVisibleInLibrary;
  List<int> categoryIds = [];
  if (!isBulk) {
    categoryIds = List<int>.from(singleManga?.categories ?? []);
  }
  final bulkOverrides = <int, bool>{};
  showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        elevation: 8,
        child: Container(
          width: context.width(0.85),
          constraints: BoxConstraints(maxHeight: context.height(0.75)),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                context.primaryColor.withValues(alpha: 0.05),
                Colors.transparent,
              ],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: context.primaryColor.withValues(alpha: 0.2),
                      width: 1,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: context.primaryColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.category_rounded,
                        color: context.primaryColor,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        l10n.set_categories,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: context.primaryColor,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(
                        Icons.close_rounded,
                        color: context.primaryColor.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              // Content
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: StreamBuilder(
                    stream: categoryRepository.watchByItemType(itemType),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData || snapshot.data!.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.category_outlined,
                                size: 64,
                                color: Theme.of(context).colorScheme.onSurface
                                    .withValues(alpha: 0.5),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                l10n.library_no_category_exist,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.7),
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                        );
                      }
                      final entries = (snapshot.data!
                        ..sort((a, b) => (a.pos ?? 0).compareTo(b.pos ?? 0)));
                      if (entries.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.category_outlined,
                                size: 64,
                                color: Theme.of(context).colorScheme.onSurface
                                    .withValues(alpha: 0.5),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                l10n.library_no_category_exist,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.7),
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                        );
                      }
                      return SuperListView.builder(
                        shrinkWrap: true,
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final category = entries[index];
                          final state = isBulk
                              ? (bulkOverrides.containsKey(category.id)
                                    ? (bulkOverrides[category.id]! ? 1 : 0)
                                    : CategoryService.membershipState(
                                        bulkMangas,
                                        category.id!,
                                      ))
                              : (categoryIds.contains(category.id) ? 1 : 0);
                          if (!isBulk) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: ListTileChapterFilter(
                                label: category.name!,
                                onTap: () {
                                  setState(() {
                                    state == 1
                                        ? categoryIds.remove(category.id)
                                        : categoryIds.add(category.id!);
                                  });
                                },
                                type: state,
                              ),
                            );
                          }
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: ListTileChapterFilter(
                              label: category.name!,
                              type: state,
                              onTap: () {
                                setState(() {
                                  bulkOverrides[category.id!] = state != 1;
                                });
                              },
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
              // Actions
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: context.primaryColor.withValues(alpha: 0.1),
                      width: 1,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.edit_rounded, size: 18),
                      label: Text(l10n.edit),
                      style: TextButton.styleFrom(
                        foregroundColor: context.primaryColor,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      onPressed: () {
                        context.push("/categories", extra: (true, itemType));
                        Navigator.pop(context);
                      },
                    ),
                    Row(
                      children: [
                        TextButton(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                          onPressed: () => Navigator.pop(context),
                          child: Text(l10n.cancel),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: context.primaryColor,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: () {
                            if (isBulk) {
                              final now = DateTime.now().millisecondsSinceEpoch;
                              for (final manga in bulkMangas) {
                                final categories = List<int>.from(
                                  manga.categories ?? const [],
                                );
                                for (final entry in bulkOverrides.entries) {
                                  if (entry.value) {
                                    if (!categories.contains(entry.key)) {
                                      categories.add(entry.key);
                                    }
                                  } else {
                                    categories.remove(entry.key);
                                  }
                                }
                                manga
                                  ..categories = (categories..sort())
                                  ..updatedAt = now;
                              }
                              mangaRepository.putAll(bulkMangas);
                              ref
                                  .read(mangasListStateProvider.notifier)
                                  .clear();
                              ref
                                  .read(isLongPressedStateProvider.notifier)
                                  .update(false);
                            } else {
                              if (!isLibraryVisible) {
                                singleManga!.favorite = true;
                                singleManga.dateAdded =
                                    DateTime.now().millisecondsSinceEpoch;
                              }
                              singleManga
                                ..categories = categoryIds
                                ..updatedAt =
                                    DateTime.now().millisecondsSinceEpoch;
                              mangaRepository.save(singleManga);
                            }
                            if (context.mounted) Navigator.pop(context);
                          },
                          child: Text(l10n.ok),
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
  );
}
