import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangayomi/models/changed.dart';
import 'package:mangayomi/modules/browse/extension/extension_package.dart';
import 'package:mangayomi/modules/browse/widgets/source_extension_icon.dart';
import 'package:mangayomi/modules/more/settings/sync/providers/sync_providers.dart';
import 'package:mangayomi/services/fetch_item_sources.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/services/uninstall_extension.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';
import 'package:mangayomi/utils/language.dart';

class ExtensionListTileWidget extends ConsumerStatefulWidget {
  final ExtensionCatalogEntry entry;
  const ExtensionListTileWidget({super.key, required this.entry});

  @override
  ConsumerState<ExtensionListTileWidget> createState() =>
      _ExtensionListTileWidgetState();
}

class _ExtensionListTileWidgetState
    extends ConsumerState<ExtensionListTileWidget> {
  bool _isLoading = false;
  late bool _updateAvailable;
  late bool _sourceNotEmpty;

  @override
  void initState() {
    super.initState();
    _updateState();
  }

  @override
  void didUpdateWidget(covariant ExtensionListTileWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateState();
  }

  void _updateState() {
    _updateAvailable = widget.entry.package.updateAvailable;
    _sourceNotEmpty = widget.entry.package.hasInstalledCode;
  }

  Future<void> _handleSourceFetch() async {
    setState(() => _isLoading = true);

    try {
      final provider = fetchItemSourcesListProvider(
        id: widget.entry.source.id,
        reFresh: true,
        itemType: widget.entry.source.itemType,
      );

      // A keep-alive family can otherwise return a completed prior attempt.
      // Invalidate it, then read it from this callback (`watch` belongs in
      // build methods and silently aborted installs in debug builds).
      ref.invalidate(provider);
      await ref.read(provider.future);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Failed to install ${widget.entry.name}: $error'),
          ),
        );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildTrailingButton(BuildContext context, String label) {
    final isInstall = label == context.l10n.install;
    final isUpdate = label == context.l10n.update;
    return _isLoading
        ? const SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2.0),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: _isLoading
                    ? null
                    : () {
                        if (!_updateAvailable && _sourceNotEmpty) {
                          context.push(
                            '/extension_detail',
                            extra: widget.entry.source,
                          );
                        } else {
                          _handleSourceFetch();
                        }
                      },
                child: Icon(
                  isInstall
                      ? Icons.download_outlined
                      : isUpdate
                      ? Icons.system_update_alt_outlined
                      : Icons.settings_outlined,
                  size: 24,
                ),
              ),
              if (_sourceNotEmpty)
                TextButton(
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (ctx) {
                        return AlertDialog(
                          title: Text(widget.entry.name),
                          content: Text(
                            ctx.l10n.uninstall_extension(widget.entry.name),
                          ),
                          actions: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton(
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                  },
                                  child: Text(ctx.l10n.cancel),
                                ),
                                const SizedBox(width: 15),
                                TextButton(
                                  onPressed: () {
                                    final result = uninstallExtension(
                                      widget.entry.source,
                                    );
                                    for (final sourceId
                                        in result.removedObsoleteSourceIds) {
                                      ref
                                          .read(
                                            synchingProvider(syncId: 1)
                                                .notifier,
                                          )
                                          .addChangedPart(
                                            ActionType.removeExtension,
                                            sourceId,
                                            "{}",
                                            false,
                                          );
                                    }

                                    Navigator.pop(ctx);
                                  },
                                  child: Text(ctx.l10n.ok),
                                ),
                              ],
                            ),
                          ],
                        );
                      },
                    );
                  },
                  child: Icon(Icons.delete_outline, size: 24),
                ),
            ],
          );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nLocalizations(context)!;
    final buttonLabel = !_sourceNotEmpty
        ? l10n.install
        : _updateAvailable
        ? l10n.update
        : l10n.settings;

    return ListTile(
      onTap: _isLoading
          ? null
          : () {
              if (_sourceNotEmpty) {
                context.push('/extension_detail', extra: widget.entry.source);
              } else {
                _handleSourceFetch();
              }
            },
      leading: Container(
        height: 37,
        width: 37,
        decoration: BoxDecoration(
          color: Theme.of(context).secondaryHeaderColor.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(5),
        ),
        child: SourceExtensionIcon(source: widget.entry.source, size: 37),
      ),
      title: Text(widget.entry.name),
      subtitle: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            completeLanguageName(widget.entry.lang.toLowerCase()),
            style: const TextStyle(fontWeight: FontWeight.w300, fontSize: 12),
          ),
          const SizedBox(width: 4),
          Text(
            widget.entry.source.version ?? '',
            style: const TextStyle(fontWeight: FontWeight.w300, fontSize: 12),
          ),
          if (widget.entry.package.isNsfw)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
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
          if (widget.entry.source.repo?.name != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                "- ${widget.entry.source.repo!.name!}",
                style: TextStyle(fontSize: 12),
              ),
            ),
          if (widget.entry.source.isObsolete ?? false)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                "OBSOLETE",
                style: TextStyle(
                  color: context.primaryColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
      trailing: _buildTrailingButton(context, buttonLabel),
    );
  }
}
