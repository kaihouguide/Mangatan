import 'package:flutter/material.dart';
import 'package:mangayomi/utils/platform_utils.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangayomi/eval/model/m_bridge.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/repositories/source_repository.dart';
import 'package:mangayomi/modules/more/settings/browse/providers/browse_state_provider.dart';
import 'package:mangayomi/modules/widgets/progress_center.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/services/fetch_item_sources.dart';
import 'package:mangayomi/utils/cached_network.dart';
import 'package:mangayomi/utils/error_toast.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mangayomi/l10n/generated/app_localizations.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/repositories/db_write_queue.dart';

class SourceRepositories extends ConsumerStatefulWidget {
  final ItemType itemType;
  const SourceRepositories({required this.itemType, super.key});

  @override
  ConsumerState<SourceRepositories> createState() => _SourceRepositoriesState();
}

class _SourceRepositoriesState extends ConsumerState<SourceRepositories> {
  final urlRegex = RegExp(
    r'^(https?:\/\/)?([\da-z\.-]+)\.([a-z\.]{2,6})([\/\w \.-]*)*\/?$',
  );
  List<Repo> _entries = [];
  bool isRefreshing = false;

  Future<void> _launchInBrowser(Uri url) async {
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw 'Could not launch $url';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nLocalizations(context)!;
    final repositories = ref.watch(
      extensionsRepoStateProvider(widget.itemType),
    );
    final data = AsyncValue.data(repositories);
    return Scaffold(
      appBar: AppBar(
        title: switch (widget.itemType) {
          ItemType.manga => Text(l10n.manage_manga_repo_urls),
          ItemType.anime => Text(l10n.manage_anime_repo_urls),
          _ => Text(l10n.manage_novel_repo_urls),
        },
        actions: [
          isRefreshing
              ? const Padding(
                  padding: EdgeInsets.all(20.0),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                )
              : Padding(
                  padding: EdgeInsets.all(8.0),
                  child: IconButton(
                    splashRadius: 20,
                    onPressed: () async {
                      setState(() {
                        isRefreshing = true;
                      });
                      final result = await ref.refresh(
                        fetchItemSourcesListProvider(
                          id: null,
                          reFresh: true,
                          itemType: widget.itemType,
                        ).future,
                      );
                      setState(() {
                        isRefreshing = false;
                      });
                      return result;
                    },
                    icon: Icon(
                      Icons.refresh,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ),
        ],
      ),
      body: data.when(
        data: (data) {
          if (data.isEmpty) {
            _entries = [];
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  l10n.empty_extensions_repo,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          _entries = data;

          return SuperListView.builder(
            itemCount: _entries.length,
            itemBuilder: (context, index) {
              final repo = _entries[index];
              final isHidden = repo.hidden ?? false;
              final repoAvatar = urlRegex
                  .firstMatch(repo.jsonUrl ?? "")
                  ?.group(4)
                  ?.split("/")
                  .elementAtOrNull(1);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Column(
                      children: [
                        Opacity(
                          opacity: isHidden ? 0.3 : 1,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              if (repoAvatar != null)
                                Padding(
                                  padding: EdgeInsets.all(8.0),
                                  child: cachedNetworkImage(
                                    imageUrl:
                                        "https://github.com/$repoAvatar.png?size=64",
                                    fit: BoxFit.contain,
                                    width: 64,
                                    height: 64,
                                    errorWidget: const Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 15,
                                      ),
                                      child: Icon(Icons.label_outline_rounded),
                                    ),
                                    useCustomNetworkImage: false,
                                  ),
                                ),
                              if (repoAvatar == null)
                                const Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 15,
                                  ),
                                  child: Icon(Icons.label_outline_rounded),
                                ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  (repo.name != null &&
                                          repo.name!.isNotEmpty &&
                                          !repo.name!.endsWith('.json'))
                                      ? repo.name!
                                      : (repo.jsonUrl != null
                                            ? (repo.jsonUrl!
                                                      .replaceAll(
                                                        RegExp(
                                                          r'/[^/]+\.json$',
                                                        ),
                                                        '',
                                                      )
                                                      .split('/')
                                                      .where(
                                                        (s) => s.isNotEmpty,
                                                      )
                                                      .lastOrNull ??
                                                  repo.jsonUrl!)
                                            : "Invalid source - remove it"),
                                  style: TextStyle(
                                    decoration: isHidden
                                        ? TextDecoration.lineThrough
                                        : TextDecoration.none,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (repo.website != null)
                              IconButton(
                                onPressed: () {
                                  _launchInBrowser(Uri.parse(repo.website!));
                                },
                                icon: Icon(Icons.open_in_new_outlined),
                              ),
                            SizedBox(width: 10),
                            IconButton(
                              onPressed: () async {
                                if (repo.jsonUrl != null) {
                                  await Clipboard.setData(
                                    ClipboardData(text: repo.jsonUrl!),
                                  );
                                }
                              },
                              icon: const Icon(Icons.content_copy),
                            ),
                            SizedBox(width: 10),
                            IconButton(
                              onPressed: () => ref
                                  .read(
                                    extensionsRepoStateProvider(widget.itemType)
                                        .notifier,
                                  )
                                  .setVisibility(repo, !isHidden),
                              icon: Stack(
                                children: [
                                  const Icon(Icons.remove_red_eye_outlined),
                                  if (isHidden)
                                    Positioned(
                                      right: 8,
                                      child: Transform.scale(
                                        scaleX: 2.5,
                                        child: const Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              '\\',
                                              style: TextStyle(fontSize: 17),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            SizedBox(width: 10),
                            IconButton(
                              onPressed: () =>
                                  _showRemoveRepoDialog(context, index),
                              icon: const Icon(Icons.delete_outlined),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
        error: (Object error, StackTrace stackTrace) {
          _entries = [];
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                l10n.empty_extensions_repo,
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
        onPressed: () => _showAddRepoDialog(context),
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

  /// #774: when a repo is removed, drop its *not-installed* sources so they
  /// don't linger as placeholders with a dead install button. Installed
  /// sources (non-empty [Source.sourceCode]) are kept so users don't lose them.
  Future<void> _removeOrphanSources(Repo removedRepo) async {
    final repoUrl = removedRepo.jsonUrl;
    if (repoUrl == null) return;
    final orphanIds = sourceRepository
        .getByItemType(widget.itemType)
        .where(
          (s) => s.repo?.jsonUrl == repoUrl && (s.sourceCode?.isEmpty ?? true),
        )
        .map((s) => s.id!)
        .toList();
    if (orphanIds.isNotEmpty) {
      await dbWriteQueue.run(
        () => isar.writeTxn(() => isar.sources.deleteAll(orphanIds)),
      );
    }
  }

  void _showRemoveRepoDialog(BuildContext context, int index) {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            final l10n = context.l10n;
            return AlertDialog(
              title: Text(l10n.remove_extensions_repo),
              content: Text(l10n.remove_extensions_repo),
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
                        final removedRepo = _entries[index];
                        final mangaRepos = ref
                            .read(extensionsRepoStateProvider(widget.itemType))
                            .toList();
                        mangaRepos.removeWhere((url) => url == removedRepo);
                        await ref
                            .read(
                              extensionsRepoStateProvider(widget.itemType)
                                  .notifier,
                            )
                            .set(mangaRepos);
                        await _removeOrphanSources(removedRepo);
                        if (context.mounted) {
                          Navigator.pop(context);
                        }
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
  }

  /// Why [input] cannot be added, or null when it can. Index files and base
  /// URLs are both accepted: [getRepoInfos] probes the usual index names.
  String? _repoUrlError(String input, AppLocalizations l10n) {
    final text = input.trim();
    if (text.isEmpty) return l10n.url_cannot_be_empty;
    final uri = Uri.tryParse(text);
    if (uri == null ||
        !uri.isAbsolute ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return l10n.invalid_url_format;
    }
    final alreadyExists = _entries.any(
      (repo) => _sameRepoUrl(repo.jsonUrl, text),
    );
    return alreadyExists ? l10n.repo_already_exists : null;
  }

  /// Repository URLs match ignoring case, surrounding spaces and one trailing
  /// slash.
  static bool _sameRepoUrl(String? a, String? b) {
    String? normalize(String? url) {
      final clean = url?.trim().toLowerCase();
      if (clean == null || clean.isEmpty) return null;
      return clean.endsWith('/') ? clean.substring(0, clean.length - 1) : clean;
    }

    final first = normalize(a);
    return first != null && first == normalize(b);
  }

  void _showAddRepoDialog(BuildContext context) {
    bool isLoading = false;
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return SizedBox(
          child: StatefulBuilder(
            builder: (context, setState) {
              final l10n = context.l10n;
              return AlertDialog(
                title: Text(l10n.add_extensions_repo),
                content: TextFormField(
                  controller: controller,
                  // On Android TV, don't autofocus: it instantly pops the
                  // full-screen leanback keyboard over the dialog before the
                  // user can even see the Cancel/Add buttons. Let them navigate
                  // to the field and open the keyboard with select instead.
                  // Phones keep autofocus for the usual ready-to-type flow.
                  autofocus: !isTv,
                  keyboardType: TextInputType.url,
                  onChanged: (value) => setState(() {}),
                  validator: (value) => _repoUrlError(value ?? '', l10n),
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  decoration: InputDecoration(
                    hintText: l10n.url_must_end_with_dot_json_or_dot_pb,
                    filled: false,
                    contentPadding: const EdgeInsets.all(12),
                    enabledBorder: OutlineInputBorder(
                      borderSide: const BorderSide(width: 0.4),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: const BorderSide(),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(5),
                      borderSide: const BorderSide(),
                    ),
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
                      StatefulBuilder(
                        builder: (context, setState) {
                          final text = controller.text.trim();
                          final isValid = _repoUrlError(text, l10n) == null;
                          return TextButton(
                            onPressed: !isValid
                                ? null
                                : () async {
                                    setState(() => isLoading = true);
                                    try {
                                      final repoNotifier = ref.read(
                                        extensionsRepoStateProvider(
                                          widget.itemType,
                                        ).notifier,
                                      );
                                      final currentRepos = ref.read(
                                        extensionsRepoStateProvider(
                                          widget.itemType,
                                        ),
                                      );
                                      final repo = await ref.read(
                                        getRepoInfosProvider(jsonUrl: text)
                                            .future,
                                      );
                                      if (repo == null) {
                                        if (context.mounted) {
                                          setState(() => isLoading = false);
                                        }
                                        botToast(l10n.unsupported_repo);
                                        return;
                                      }
                                      // The typed URL may be a base URL
                                      // that resolved to an index file.
                                      final isDuplicate = currentRepos.any(
                                        (r) =>
                                            r == repo ||
                                            _sameRepoUrl(r.jsonUrl, text) ||
                                            _sameRepoUrl(
                                              r.jsonUrl,
                                              repo.jsonUrl,
                                            ),
                                      );
                                      if (isDuplicate) {
                                        if (context.mounted) {
                                          setState(() => isLoading = false);
                                        }
                                        botToast(l10n.repo_already_exists);
                                        return;
                                      }
                                      await repoNotifier.set([
                                        ...currentRepos,
                                        repo,
                                      ]);
                                      botToast(l10n.repo_added);
                                    } catch (e, s) {
                                      if (context.mounted) {
                                        setState(() => isLoading = false);
                                      }
                                      toastError(
                                        e,
                                        stack: s,
                                        source: 'sourceRepositories',
                                      );
                                      return;
                                    }

                                    if (context.mounted) {
                                      Navigator.pop(context);
                                    }
                                  },
                            child: isLoading
                                ? SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(),
                                  )
                                // The disabled button already dims itself.
                                : Text(l10n.add),
                          );
                        },
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
  }
}
