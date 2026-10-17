import 'package:mangayomi/modules/main_view/providers/tv_mode_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/repositories/category_repository.dart';
import 'package:mangayomi/models/category.dart';
import 'package:mangayomi/models/changed.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/modules/more/categories/providers/isar_providers.dart';
import 'package:mangayomi/modules/more/categories/widgets/custom_textfield.dart';
import 'package:mangayomi/modules/more/settings/reader/providers/reader_state_provider.dart';
import 'package:mangayomi/modules/more/settings/sync/providers/sync_providers.dart';
import 'package:mangayomi/modules/widgets/progress_center.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/services/category_service.dart';
import 'package:mangayomi/utils/item_type_filters.dart';
import 'package:mangayomi/utils/item_type_localization.dart';

class CategoriesScreen extends ConsumerStatefulWidget {
  final (bool, ItemType) data;
  const CategoriesScreen({required this.data, super.key});

  @override
  ConsumerState<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends ConsumerState<CategoriesScreen>
    with TickerProviderStateMixin {
  late TabController _tabBarController;
  late final List<ItemType> _visibleTabTypes;
  @override
  void initState() {
    super.initState();
    var types = hiddenItemTypes(ref.read(hideItemsStateProvider));
    // Anime-only layout: only manage anime categories.
    if (ref.read(animeOnlyTvModeProvider)) {
      types = types.where((t) => t == ItemType.anime).toList();
    }
    _visibleTabTypes = types;
    _tabBarController = TabController(
      length: _visibleTabTypes.length,
      vsync: this,
    );
    final initialIndex = _visibleTabTypes.indexOf(widget.data.$2);
    if (initialIndex >= 0) _tabBarController.animateTo(initialIndex);
  }

  @override
  void dispose() {
    _tabBarController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_visibleTabTypes.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(context.l10n.categories)),
        body: Center(child: Text(context.l10n.empty_placeholder)),
      );
    }
    final l10n = l10nLocalizations(context)!;
    return DefaultTabController(
      animationDuration: Duration.zero,
      length: _visibleTabTypes.length,
      child: Scaffold(
        appBar: AppBar(
          elevation: 0,
          backgroundColor: Colors.transparent,
          title: Text(
            widget.data.$1 ? l10n.edit_categories : l10n.categories,
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
          bottom: TabBar(
            indicatorSize: TabBarIndicatorSize.label,
            controller: _tabBarController,
            tabs: _visibleTabTypes.map((type) {
              return Tab(text: type.localized(l10n));
            }).toList(),
          ),
        ),
        body: TabBarView(
          controller: _tabBarController,
          children: _visibleTabTypes.map((type) {
            return CategoriesTab(itemType: type);
          }).toList(),
        ),
      ),
    );
  }
}

class CategoriesTab extends ConsumerStatefulWidget {
  final ItemType itemType;
  const CategoriesTab({required this.itemType, super.key});

  @override
  ConsumerState<CategoriesTab> createState() => _CategoriesTabState();
}

class _CategoriesTabState extends ConsumerState<CategoriesTab> {
  List<Category> _entries = [];

  @override
  Widget build(BuildContext context) {
    final l10n = l10nLocalizations(context)!;
    final categories = ref.watch(
      getMangaCategorieStreamProvider(itemType: widget.itemType),
    );
    return Scaffold(
      body: categories.when(
        data: (data) {
          if (data.isEmpty) {
            _entries = [];
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  l10n.edit_categories_description,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          _entries = CategoryService.ordered(data);

          return ReorderableListView.builder(
            buildDefaultDragHandles: false,
            itemCount: _entries.length,
            padding: const EdgeInsets.only(bottom: 100),
            onReorderItem: (int oldIndex, int newIndex) async {
              final item = _entries.removeAt(oldIndex);
              _entries.insert(newIndex, item);
              final now = DateTime.now().millisecondsSinceEpoch;
              for (int i = 0; i < _entries.length; i++) {
                _entries[i].pos = i;
                _entries[i].updatedAt = now;
              }
              setState(() {});
              await categoryRepository.putAll(_entries);
            },
            itemBuilder: (context, index) {
              final category = _entries[index];
              return _buildCategoryCard(context, category, index);
            },
          );
        },
        error: (Object error, StackTrace stackTrace) {
          _entries = [];
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                l10n.edit_categories_description,
                textAlign: TextAlign.center,
              ),
            ),
          );
        },
        loading: () {
          return const ProgressCenter();
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          bool isExist = false;
          final controller = TextEditingController();
          showDialog(
            context: context,
            builder: (context) {
              return SizedBox(
                child: StatefulBuilder(
                  builder: (context, setState) {
                    return AlertDialog(
                      title: Text(l10n.add_category),
                      content: CustomTextFormField(
                        controller: controller,
                        entries: _entries,
                        context: context,
                        exist: (value) {
                          setState(() {
                            isExist = value;
                          });
                        },
                        isExist: isExist,
                        val: (val) {},
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
                              onPressed:
                                  controller.text.trim().isEmpty || isExist
                                  ? null
                                  : () async {
                                      final category = Category(
                                        forItemType: widget.itemType,
                                        name: controller.text.trim(),
                                        pos: _nextPosition(),
                                        hide: false,
                                        shouldUpdate: true,
                                        updatedAt: DateTime.now()
                                            .millisecondsSinceEpoch,
                                      );
                                      // create() would replace pos with the id.
                                      await categoryRepository.writeTransaction(
                                        () => categoryRepository.putSync(
                                          category,
                                        ),
                                      );

                                      if (context.mounted) {
                                        Navigator.pop(context);
                                      }
                                    },
                              child: Text(
                                l10n.add,
                                style: TextStyle(
                                  color:
                                      controller.text.trim().isEmpty || isExist
                                      ? Theme.of(context).primaryColor
                                            .withValues(alpha: 0.2)
                                      : null,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              );
            },
          );
        },
        label: Row(
          children: [
            const Icon(Icons.add),
            const SizedBox(width: 10),
            Text(l10n.add),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryCard(
    BuildContext context,
    Category category,
    int index,
  ) {
    final l10n = l10nLocalizations(context)!;
    return Padding(
      key: Key('category_${category.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Card(
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Icon(Icons.drag_handle),
              ),
            ),
            Expanded(
              child: Column(
                children: [
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      elevation: 0,
                      shadowColor: Colors.transparent,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.only(
                          bottomLeft: Radius.circular(0),
                          bottomRight: Radius.circular(0),
                          topRight: Radius.circular(10),
                          topLeft: Radius.circular(10),
                        ),
                      ),
                    ),
                    onPressed: () {
                      _renameCategory(category);
                    },
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Icon(Icons.label_outline_rounded),
                        const SizedBox(width: 10),
                        Expanded(child: Text(category.name!)),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        onPressed: () {
                          _renameCategory(category);
                        },
                        icon: const Icon(Icons.mode_edit_outline_outlined),
                      ),
                      SizedBox(width: 10),
                      IconButton(
                        onPressed: () async {
                          category.shouldUpdate =
                              !(category.shouldUpdate ?? true);
                          await categoryRepository.save(category);
                        },
                        icon: Icon(
                          category.shouldUpdate ?? true
                              ? Icons.update_outlined
                              : Icons.update_disabled_outlined,
                        ),
                      ),
                      if (widget.itemType != ItemType.novel) ...[
                        SizedBox(width: 10),
                        IconButton(
                          onPressed: () async {
                            category.hide = !(category.hide ?? false);
                            await categoryRepository.save(category);
                          },
                          icon: Icon(
                            !(category.hide ?? false)
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ],
                      SizedBox(width: 10),
                      IconButton(
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (context) {
                              return StatefulBuilder(
                                builder: (context, setState) {
                                  return AlertDialog(
                                    title: Text(l10n.delete_category),
                                    content: Text(
                                      l10n.delete_category_msg(category.name!),
                                    ),
                                    actions: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.end,
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
                                              await _removeCategory(
                                                category,
                                                context,
                                              );
                                            },
                                            child: Text(l10n.ok),
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
                        icon: const Icon(Icons.delete_outlined),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  int _nextPosition() => _entries.isEmpty
      ? 0
      : _entries.map((e) => e.pos ?? 0).reduce((a, b) => a > b ? a : b) + 1;

  Future<void> _removeCategory(Category category, BuildContext context) async {
    await removeCategoryForItemType(category, widget.itemType);

    await ref
        .read(synchingProvider(syncId: 1).notifier)
        .addChangedPartAsync(
          ActionType.removeCategory,
          category.id,
          "{}",
          true,
          clientId: category.clientId,
        );
    if (context.mounted) {
      Navigator.pop(context);
    }
  }

  void _renameCategory(Category category) {
    bool isExist = false;
    final controller = TextEditingController(text: category.name);
    bool sameName() =>
        CategoryService.normalizeName(controller.text) ==
        CategoryService.normalizeName(category.name ?? '');
    bool isSameName = sameName();
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            final l10n = l10nLocalizations(context);
            return AlertDialog(
              title: Text(l10n!.rename_category),
              content: CustomTextFormField(
                controller: controller,
                entries: _entries,
                context: context,
                exist: (value) {
                  setState(() {
                    isExist = value;
                  });
                },
                isExist: isExist,
                name: category.name!,
                val: (val) {
                  setState(() {
                    isSameName = sameName();
                  });
                },
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
                      onPressed:
                          controller.text.trim().isEmpty ||
                              isExist ||
                              isSameName
                          ? null
                          : () async {
                              category.name = controller.text.trim();
                              await categoryRepository.save(category);
                              if (context.mounted) {
                                Navigator.pop(context);
                              }
                            },
                      child: Text(
                        l10n.ok,
                        style: TextStyle(
                          color:
                              controller.text.trim().isEmpty ||
                                  isExist ||
                                  isSameName
                              ? Theme.of(context).primaryColor
                                    .withValues(alpha: 0.2)
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Deletes [category], removes it from items of [itemType], and closes the
/// gap it leaves in that type's category order.
@visibleForTesting
Future<void> removeCategoryForItemType(Category category, ItemType itemType) =>
    categoryRepository.writeTransactionAsync(() async {
      final items = await isar.mangas
          .filter()
          .categoriesElementEqualTo(category.id!)
          .and()
          .itemTypeEqualTo(itemType)
          .findAll();
      for (final item in items) {
        CategoryService.removeMembership(item, category.id!);
      }
      await isar.mangas.putAll(items);
      await isar.categorys.delete(category.id!);
      await isar.categorys.putAll(
        CategoryService.normalizePositions(
          await isar.categorys.filter().forItemTypeEqualTo(itemType).findAll(),
        ),
      );
    });
