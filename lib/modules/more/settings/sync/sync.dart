import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangayomi/eval/model/m_bridge.dart';
import 'package:mangayomi/modules/more/settings/sync/providers/sync_connection_status_provider.dart';
import 'package:mangayomi/modules/more/settings/sync/providers/sync_progress_provider.dart';
import 'package:mangayomi/modules/more/settings/sync/providers/sync_providers.dart';
import 'package:mangayomi/modules/more/settings/sync/widgets/auto_sync_frequency_option.dart';
import 'package:mangayomi/utils/date.dart';
import 'package:mangayomi/models/sync_preference.dart';
import 'package:mangayomi/modules/more/settings/sync/widgets/sync_listile.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/services/sync_server.dart';
import 'package:mangayomi/services/sync/google_drive_oauth.dart';
import 'package:mangayomi/services/sync/chimahon_media_sync_selection.dart';
import 'package:mangayomi/services/sync/chimahon_restore_sync_coordinator.dart';
import 'package:mangayomi/services/sync/chimahon_sync_codec.dart';
import 'package:mangayomi/services/sync/google_drive_platform_support.dart';
import 'package:mangayomi/services/sync/google_drive_refresh_token_store.dart';
import 'package:mangayomi/services/sync/google_drive_sync_storage.dart';
import 'package:mangayomi/services/sync/sync_user_message.dart';
import 'package:mangayomi/services/sync/webdav_credential_store.dart';
import 'package:mangayomi/services/sync/webdav_sync_storage.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';
import 'package:mangayomi/utils/log/logger.dart';
import 'package:mangayomi/utils/platform_utils.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mangayomi/repositories/sync_preference_repository.dart';

final _googleDriveConnectionSingleFlight = GoogleDriveConnectionSingleFlight();

/// Deduplicates process-local Connect clicks while preserving synchronous
/// setup before the operation's first asynchronous gap.
@visibleForTesting
class GoogleDriveConnectionSingleFlight {
  Future<void>? _active;

  Future<void> run(Future<void> Function() operation) {
    final active = _active;
    if (active != null) return active;

    final started = Future<void>.sync(operation);
    late final Future<void> tracked;
    tracked = started.whenComplete(() {
      if (identical(_active, tracked)) _active = null;
    });
    _active = tracked;
    return tracked;
  }
}

class SyncScreen extends ConsumerWidget {
  static const serverUrl = "https://github.com/Schnitzel5/mangayomi-server";

  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = l10nLocalizations(context)!;
    final autoSyncOptions = {
      l10n.sync_auto_off: 0,
      l10n.sync_auto_5_minutes: 300,
      l10n.sync_auto_10_minutes: 600,
      l10n.sync_auto_30_minutes: 1800,
      l10n.sync_auto_1_hour: 3600,
      l10n.sync_auto_3_hours: 10800,
      l10n.sync_auto_6_hours: 21600,
      l10n.sync_auto_12_hours: 43200,
    };
    final googleDriveSupported =
        supportsGoogleDriveChimahonSyncOnCurrentPlatform;
    return Scaffold(
      appBar: AppBar(title: Text(l10nLocalizations(context)!.syncing)),
      body: SingleChildScrollView(
        child: StreamBuilder(
          stream: syncPreferenceRepository.watchAllWithSyncId(),
          builder: (context, snapshot) {
            SyncPreference syncPreference = snapshot.data?.isNotEmpty ?? false
                ? snapshot.data?.first ?? SyncPreference()
                : SyncPreference();
            final isChimahon = syncPreference.syncMode == SyncMode.chimahon;
            final isGoogleDrive =
                isChimahon &&
                syncPreference.chimahonSyncProvider ==
                    ChimahonSyncProvider.googleDrive;
            final isWebDav =
                isChimahon &&
                syncPreference.chimahonSyncProvider ==
                    ChimahonSyncProvider.webDav;
            final bool isLogged = isGoogleDrive
                ? syncPreference.googleDriveConnected
                : isWebDav
                ? syncPreference.googleDriveConnected &&
                      (syncPreference.server?.isNotEmpty ?? false)
                : isChimahon
                ? (syncPreference.syncYomiApiToken?.isNotEmpty ?? false) &&
                      (syncPreference.syncYomiServer?.isNotEmpty ?? false)
                : syncPreference.authToken?.isNotEmpty ?? false;
            final connectionStatus = isChimahon || !isLogged
                ? null
                : ref.watch(syncConnectionStateProvider(syncId: 1));
            final progress = ref.watch(syncProgressProvider(syncId: 1));
            final canSync =
                syncPreference.syncOn && isLogged && !progress.active;
            return Column(
              children: [
                SwitchListTile(
                  value: syncPreference.syncOn,
                  title: Text(context.l10n.sync_on),
                  onChanged: (value) {
                    ref
                        .read(synchingProvider(syncId: 1).notifier)
                        .setSyncOn(value);
                    if (!value) {
                      ref
                          .read(synchingProvider(syncId: 1).notifier)
                          .setAutoSyncFrequency(0);
                    }
                  },
                ),
                ListTile(
                  title: const Text('Sync mode'),
                  subtitle: Text(
                    isChimahon
                        ? syncPreference.chimahonSyncProvider ==
                                  ChimahonSyncProvider.googleDrive
                              ? 'Chimahon compatible · Google Drive'
                              : syncPreference.chimahonSyncProvider ==
                                    ChimahonSyncProvider.webDav
                              ? 'Chimahon compatible · WebDAV'
                              : 'Chimahon compatible · SyncYomi'
                        : 'Mangayomi native',
                    style: TextStyle(
                      fontSize: 11,
                      color: context.secondaryColor,
                    ),
                  ),
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Sync mode'),
                        content: RadioGroup(
                          groupValue: syncPreference.syncMode,
                          onChanged: (value) {
                            if (value == null) return;
                            ref
                                .read(synchingProvider(syncId: 1).notifier)
                                .setSyncMode(value);
                            Navigator.pop(context);
                          },
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              RadioListTile(
                                value: SyncMode.native,
                                title: Text('Mangayomi native'),
                                subtitle: Text(
                                  'Uses the existing Mangayomi sync server.',
                                ),
                              ),
                              RadioListTile(
                                value: SyncMode.chimahon,
                                title: Text('Chimahon / SyncYomi compatible'),
                                subtitle: Text(
                                  'Uses Chimahon-compatible protobuf sync data.',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
                if (isChimahon)
                  ListTile(
                    title: const Text('Chimahon sync service'),
                    subtitle: Text(
                      isGoogleDrive
                          ? 'Google Drive'
                          : isWebDav
                          ? 'WebDAV'
                          : 'SyncYomi',
                      style: TextStyle(
                        fontSize: 11,
                        color: context.secondaryColor,
                      ),
                    ),
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Chimahon sync service'),
                          content: RadioGroup(
                            groupValue: syncPreference.chimahonSyncProvider,
                            onChanged: (value) {
                              if (value == null) return;
                              ref
                                  .read(synchingProvider(syncId: 1).notifier)
                                  .setChimahonSyncProvider(value);
                              Navigator.pop(context);
                            },
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                RadioListTile(
                                  value: ChimahonSyncProvider.googleDrive,
                                  enabled: googleDriveSupported,
                                  title: Text('Google Drive'),
                                  subtitle: Text(
                                    googleDriveSupported
                                        ? 'Uses Chimahon’s hidden Drive app-data file.'
                                        : 'Available on macOS, Windows, and Linux.',
                                  ),
                                ),
                                const RadioListTile(
                                  value: ChimahonSyncProvider.syncYomi,
                                  title: Text('SyncYomi'),
                                  subtitle: Text(
                                    'Uses a SyncYomi server and API token.',
                                  ),
                                ),
                                RadioListTile(
                                  value: ChimahonSyncProvider.webDav,
                                  enabled: googleDriveSupported,
                                  title: const Text('WebDAV'),
                                  subtitle: Text(
                                    googleDriveSupported
                                        ? 'Uses a desktop WebDAV folder with strong ETags.'
                                        : 'Available on macOS, Windows, and Linux.',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                if (isChimahon) ...[
                  const ListTile(
                    title: Text('Media to sync'),
                    subtitle: Text(
                      'Controls what this device contributes; existing cloud '
                      'items stay.',
                    ),
                  ),
                  SwitchListTile(
                    key: const ValueKey('chimahon-sync-manga'),
                    dense: true,
                    value: syncPreference.chimahonSyncManga,
                    title: const Text('Manga'),
                    onChanged: ref
                        .read(synchingProvider(syncId: 1).notifier)
                        .setChimahonSyncManga,
                  ),
                  SwitchListTile(
                    key: const ValueKey('chimahon-sync-anime'),
                    dense: true,
                    value: syncPreference.chimahonSyncAnime,
                    title: const Text('Anime'),
                    onChanged: ref
                        .read(synchingProvider(syncId: 1).notifier)
                        .setChimahonSyncAnime,
                  ),
                  SwitchListTile(
                    key: const ValueKey('chimahon-sync-novels'),
                    dense: true,
                    value: syncPreference.chimahonSyncNovels,
                    title: const Text('Novels'),
                    onChanged: ref
                        .read(synchingProvider(syncId: 1).notifier)
                        .setChimahonSyncNovels,
                  ),
                  if (isGoogleDrive || isWebDav)
                    ListTile(
                      leading: const Icon(Icons.menu_book_outlined),
                      title: const Text('EPUB file transfer'),
                      subtitle: const Text(
                        'Mangatan uploads EPUB blobs to a separate provider '
                        'manifest. Missing cloud novels retry from the normal '
                        'sync buttons; Chimahon clients ignore these files.',
                      ),
                      trailing: const Icon(Icons.refresh_outlined),
                      onTap: !canSync
                          ? null
                          : () => ref
                                .read(syncServerProvider(syncId: 1).notifier)
                                .startSync(l10n, false),
                    ),
                ],
                ListTile(
                  enabled: syncPreference.syncOn,
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (context) {
                        return AlertDialog(
                          title: Text(l10n.sync_auto),
                          content: SizedBox(
                            width: context.width(0.8),
                            child: RadioGroup(
                              groupValue: syncPreference.autoSyncFrequency,
                              onChanged: (value) {
                                ref
                                    .read(synchingProvider(syncId: 1).notifier)
                                    .setAutoSyncFrequency(
                                      autoSyncFrequencyFromRadioValue(value),
                                    );
                                Navigator.pop(context);
                              },
                              child: SuperListView.builder(
                                shrinkWrap: true,
                                itemCount: autoSyncOptions.length,
                                itemBuilder: (context, index) {
                                  final optionName = autoSyncOptions.keys
                                      .elementAt(index);
                                  final optionValue = autoSyncOptions.values
                                      .elementAt(index);
                                  return AutoSyncFrequencyOption(
                                    value: optionValue,
                                    title: optionName,
                                  );
                                },
                              ),
                            ),
                          ),
                          actions: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton(
                                  onPressed: () async {
                                    Navigator.pop(context);
                                  },
                                  child: Text(
                                    l10n.cancel,
                                    style: TextStyle(
                                      color: context.primaryColor,
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
                  title: Text(l10n.sync_auto),
                  subtitle: Text(
                    autoSyncOptions.entries
                        .where(
                          (o) => o.value == syncPreference.autoSyncFrequency,
                        )
                        .first
                        .key,
                    style: TextStyle(
                      fontSize: 11,
                      color: context.secondaryColor,
                    ),
                  ),
                ),
                ListTile(
                  title: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber_outlined,
                          color: context.secondaryColor,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            l10n.sync_auto_warning,
                            softWrap: true,
                            style: TextStyle(
                              fontSize: 11,
                              color: context.secondaryColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (!isChimahon)
                  Padding(
                    padding: const EdgeInsets.only(
                      left: 15,
                      right: 15,
                      bottom: 10,
                      top: 10,
                    ),
                    child: Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            if (!await launchUrl(
                              Uri.parse(serverUrl),
                              mode: LaunchMode.externalApplication,
                            )) {
                              AppLogger.log(
                                'Could not launch $serverUrl',
                                logLevel: LogLevel.error,
                              );
                              botToast(l10n.could_not_launch_url(serverUrl));
                            }
                          },
                          label: Text(l10n.get_sync_server),
                          icon: const Icon(Icons.download_outlined),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(
                    left: 15,
                    right: 15,
                    bottom: 10,
                    top: 5,
                  ),
                  child: Row(
                    children: [
                      Text(
                        l10n.services,
                        style: TextStyle(
                          fontSize: 13,
                          color: context.primaryColor,
                        ),
                      ),
                    ],
                  ),
                ),
                SyncListile(
                  enabled:
                      syncPreference.syncOn &&
                      ((!isGoogleDrive && !isWebDav) || googleDriveSupported),
                  onTap: () async {
                    if (isGoogleDrive) {
                      await _connectGoogleDrive(context);
                    } else if (isChimahon) {
                      _showChimahonLoginDialog(context, ref, syncPreference);
                    } else {
                      _showNativeLoginDialog(context, ref, syncPreference);
                    }
                  },
                  id: 1,
                  preference: syncPreference,
                  text: isChimahon
                      ? isGoogleDrive
                            ? 'Google Drive (Chimahon)'
                            : isWebDav
                            ? 'WebDAV'
                            : 'SyncYomi'
                      : null,
                  loggedIn: isLogged,
                  icon: isGoogleDrive
                      ? Icons.cloud_outlined
                      : isWebDav
                      ? Icons.folder_shared_outlined
                      : Icons.dns_outlined,
                  onLogout: isGoogleDrive
                      ? () => _disconnectGoogleDrive(context)
                      : isWebDav
                      ? () => _disconnectWebDav(context, ref)
                      : isChimahon
                      ? () => ref
                            .read(synchingProvider(syncId: 1).notifier)
                            .disconnectSyncYomi()
                      : null,
                ),
                if (connectionStatus != null)
                  _connectionStatusTile(context, ref, connectionStatus),
                ListTile(
                  title: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          color: context.secondaryColor,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            l10n.syncing_subtitle,
                            softWrap: true,
                            style: TextStyle(
                              fontSize: 11,
                              color: context.secondaryColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (syncPreference.lastSync != null)
                  ListTile(
                    leading: Icon(
                      Icons.history_toggle_off,
                      color: context.secondaryColor,
                    ),
                    title: Text(
                      "${l10n.last_sync} ${dateFormat(syncPreference.lastSync!.toString(), ref: ref, context: context)} ${dateFormatHour(syncPreference.lastSync!.toString(), context)}",
                      style: TextStyle(
                        fontSize: 11,
                        color: context.secondaryColor,
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 20,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Column(
                      children: [
                        IconButton(
                          onPressed: !canSync
                              ? null
                              : () {
                                  ref
                                      .read(
                                        syncServerProvider(syncId: 1).notifier,
                                      )
                                      .startSync(l10n, false);
                                },
                          icon: Icon(
                            Icons.sync,
                            color: !canSync
                                ? context.secondaryColor
                                : context.primaryColor,
                          ),
                        ),
                        Text(l10n.sync_button_sync),
                      ],
                    ),

                    Column(
                      children: [
                        IconButton(
                          onPressed: !canSync
                              ? null
                              : () => _showConfirmDialog(context, ref, true),
                          icon: Icon(
                            Icons.file_upload_outlined,
                            color: !canSync
                                ? context.secondaryColor
                                : context.primaryColor,
                          ),
                        ),
                        Text(l10n.sync_button_upload),
                      ],
                    ),

                    Column(
                      children: [
                        IconButton(
                          onPressed: !canSync
                              ? null
                              : isChimahon
                              ? () => _startDownloadWithPreview(context, ref)
                              : () => _showConfirmDialog(context, ref, false),
                          icon: Icon(
                            Icons.file_download_outlined,
                            color: !canSync
                                ? context.secondaryColor
                                : context.primaryColor,
                          ),
                        ),
                        Text(l10n.sync_button_download),
                      ],
                    ),
                  ],
                ),
                if (progress.active)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 8,
                    ),
                    child: Column(
                      children: [
                        LinearProgressIndicator(value: progress.fraction),
                        const SizedBox(height: 6),
                        Text(
                          progress.fraction != null
                              ? l10n.sync_progress_percent(
                                  (progress.fraction! * 100).round(),
                                )
                              : l10n.sync_progress_indeterminate,
                          style: TextStyle(
                            fontSize: 11,
                            color: context.secondaryColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 20),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _connectionStatusTile(
    BuildContext context,
    WidgetRef ref,
    SyncConnectionStatus status,
  ) {
    final l10n = l10nLocalizations(context)!;
    final (icon, color, label) = switch (status) {
      SyncConnectionStatus.notConfigured => (
        Icons.link_off,
        context.secondaryColor,
        l10n.sync_status_not_configured,
      ),
      SyncConnectionStatus.checking => (
        Icons.sync,
        context.secondaryColor,
        l10n.sync_status_checking,
      ),
      SyncConnectionStatus.connected => (
        Icons.check_circle,
        Colors.green,
        l10n.sync_status_connected,
      ),
      SyncConnectionStatus.unauthorized => (
        Icons.error_outline,
        Colors.red,
        l10n.sync_status_unauthorized,
      ),
      SyncConnectionStatus.unreachable => (
        Icons.error_outline,
        Colors.red,
        l10n.sync_status_unreachable,
      ),
    };
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color, size: 20),
      title: Text(label, style: TextStyle(fontSize: 13, color: color)),
      trailing: IconButton(
        icon: const Icon(Icons.refresh, size: 20),
        onPressed: () {
          ref.read(syncConnectionStateProvider(syncId: 1).notifier).recheck();
        },
      ),
    );
  }

  Future<void> _showConfirmDialog(
    BuildContext context,
    WidgetRef ref,
    bool isUpload,
  ) async {
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          content: Text(
            isUpload
                ? context.l10n.sync_button_upload_info
                : context.l10n.sync_button_download_info,
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          actions: [
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(context.l10n.cancel),
                ),
                const SizedBox(width: 15),
                ElevatedButton(
                  onPressed: () {
                    ref
                        .read(syncServerProvider(syncId: 1).notifier)
                        .startSync(
                          context.l10n,
                          false,
                          upload: isUpload,
                          download: !isUpload,
                        );
                    Navigator.pop(context);
                  },
                  child: Text(context.l10n.dialog_confirm),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<void> _startDownloadWithPreview(
    BuildContext context,
    WidgetRef ref,
  ) async {
    await ref
        .read(syncServerProvider(syncId: 1).notifier)
        .startSync(
          context.l10n,
          false,
          download: true,
          confirmChimahonDownload: (plan) async {
            if (!context.mounted) return false;
            return await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    content: Text(
                      plan.confirmationSummary,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: Text(dialogContext.l10n.cancel),
                      ),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(dialogContext, true),
                        child: Text(dialogContext.l10n.dialog_confirm),
                      ),
                    ],
                  ),
                ) ??
                false;
          },
        );
  }

  // Only a server address is asked for here - there's no username/password
  // field. Logging in opens the system browser to that server's own login
  // page (OAuth/PKCE against the server's /api/oauth/authorize), so this
  // dialog never sees or handles a credential itself.
  void _showNativeLoginDialog(
    BuildContext context,
    WidgetRef ref,
    SyncPreference syncPreference,
  ) {
    final serverController = TextEditingController(text: syncPreference.server);
    String server = syncPreference.server ?? "";
    String errorMessage = "";
    bool isLoading = false;
    final l10n = l10nLocalizations(context)!;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Text(
              l10n.login_into("SyncServer"),
              style: const TextStyle(fontSize: 30),
            ),
            content: SingleChildScrollView(
              child: SizedBox(
                width: MediaQuery.of(context).size.width,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: TextFormField(
                        controller: serverController,
                        autofocus: !isTv,
                        onChanged: (value) => setState(() {
                          server = value;
                        }),
                        decoration: InputDecoration(
                          hintText: l10n.sync_server,
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
                    ),
                    const SizedBox(height: 10),
                    Text(
                      errorMessage,
                      style: const TextStyle(color: Colors.red),
                    ),
                    const SizedBox(height: 20),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: SizedBox(
                        width: context.width(1),
                        height: 50,
                        child: ElevatedButton.icon(
                          onPressed: isLoading || server.trim().isEmpty
                              ? null
                              : () async {
                                  setState(() {
                                    isLoading = true;
                                    errorMessage = "";
                                  });
                                  final res = await ref
                                      .read(
                                        syncServerProvider(syncId: 1).notifier,
                                      )
                                      .login(l10n, server);
                                  if (!res.$1) {
                                    setState(() {
                                      isLoading = false;
                                      errorMessage = res.$2;
                                    });
                                  } else {
                                    if (context.mounted) {
                                      Navigator.pop(context);
                                    }
                                  }
                                },
                          icon: isLoading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.open_in_browser),
                          label: Text(l10n.sync_login_browser),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _showChimahonLoginDialog(
    BuildContext context,
    WidgetRef ref,
    SyncPreference syncPreference,
  ) {
    final isWebDav =
        syncPreference.chimahonSyncProvider == ChimahonSyncProvider.webDav;
    final serverController = TextEditingController(
      text: isWebDav ? syncPreference.server : syncPreference.syncYomiServer,
    );
    final emailController = TextEditingController();
    final passwordController = TextEditingController();
    String server = serverController.text;
    String email = emailController.text;
    String password = "";
    String errorMessage = "";
    bool isLoading = false;
    bool obscureText = true;
    final l10n = l10nLocalizations(context)!;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Text(
              isWebDav ? 'Connect WebDAV' : 'Connect SyncYomi',
              style: const TextStyle(fontSize: 30),
            ),
            content: SizedBox(
              height: isWebDav ? 400 : 300,
              width: MediaQuery.of(context).size.width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: TextFormField(
                      controller: serverController,
                      autofocus: true,
                      onChanged: (value) => setState(() {
                        server = value;
                      }),
                      decoration: InputDecoration(
                        hintText: isWebDav
                            ? 'WebDAV collection URL'
                            : l10n.sync_server,
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
                  ),
                  if (isWebDav) ...[
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: TextFormField(
                        controller: emailController,
                        autofocus: true,
                        onChanged: (value) => setState(() {
                          email = value;
                        }),
                        decoration: InputDecoration(
                          hintText: 'WebDAV username',
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
                    ),
                  ],
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: TextFormField(
                      controller: passwordController,
                      obscureText: isWebDav && obscureText,
                      onChanged: (value) => setState(() {
                        password = value;
                      }),
                      decoration: InputDecoration(
                        hintText: isWebDav
                            ? 'WebDAV password or app token'
                            : 'SyncYomi API token',
                        suffixIcon: !isWebDav
                            ? null
                            : IconButton(
                                onPressed: () => setState(() {
                                  obscureText = !obscureText;
                                }),
                                icon: Icon(
                                  obscureText
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                ),
                              ),
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
                  ),
                  const SizedBox(height: 10),
                  Text(errorMessage, style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 30),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: SizedBox(
                      width: context.width(1),
                      height: 50,
                      child: ElevatedButton(
                        onPressed: isLoading
                            ? null
                            : () async {
                                setState(() {
                                  isLoading = true;
                                });
                                final res = isWebDav
                                    ? await _saveWebDavCredentials(
                                        ref,
                                        server,
                                        email,
                                        password,
                                      )
                                    : _saveSyncYomiCredentials(
                                        ref,
                                        server,
                                        password,
                                      );
                                // The dialog can be dismissed while the
                                // connection test is still running.
                                if (!context.mounted) return;
                                if (!res.$1) {
                                  setState(() {
                                    isLoading = false;
                                    errorMessage = res.$2;
                                  });
                                } else {
                                  Navigator.pop(context);
                                }
                              },
                        child: isLoading
                            ? const CircularProgressIndicator()
                            : Text(l10n.login),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  (bool, String) _saveSyncYomiCredentials(
    WidgetRef ref,
    String server,
    String token,
  ) {
    if (server.trim().isEmpty || token.trim().isEmpty) {
      return (false, 'SyncYomi server and API token required');
    }
    ref
        .read(synchingProvider(syncId: 1).notifier)
        .saveSyncYomiCredentials(server: server.trim(), apiToken: token.trim());
    botToast('SyncYomi token saved');
    return (true, '');
  }

  Future<(bool, String)> _saveWebDavCredentials(
    WidgetRef ref,
    String server,
    String username,
    String password,
  ) async {
    final normalizedServer = server.trim();
    final credentials = WebDavCredentials(
      username: username.trim(),
      password: password,
    );
    if (normalizedServer.isEmpty || !credentials.isUsable) {
      return (false, 'WebDAV URL, username, and password required');
    }
    try {
      final storage = WebDavSyncStorage(
        collectionUrl: Uri.parse(normalizedServer),
        credentials: credentials,
      );
      try {
        await storage.testConnection();
      } finally {
        storage.close();
      }
      await const SecureWebDavCredentialStore().writeCredentials(credentials);
      ref
          .read(synchingProvider(syncId: 1).notifier)
          .saveWebDavConnection(server: normalizedServer);
      botToast('WebDAV connected');
      return (true, '');
    } catch (error) {
      return (
        false,
        safeSyncUserMessage(
          error,
          context: SyncUserMessageContext.webDavConnection,
        ),
      );
    }
  }

  Future<void> _connectGoogleDrive(BuildContext context) async {
    if (!supportsGoogleDriveChimahonSyncOnCurrentPlatform) {
      botToast('Google Drive sync is available on macOS, Windows, and Linux.');
      return;
    }
    final container = ProviderScope.containerOf(context, listen: false);
    await _googleDriveConnectionSingleFlight.run(() {
      // Pause synchronously before waiting on the shared coordinator. This
      // closes the window where a timer can begin while an existing sync is
      // finishing, without stacking pause tokens for duplicate Connect clicks.
      final pauseToken = container
          .read(synchingProvider(syncId: 1).notifier)
          .pauseAutoSyncForExternalOperation();
      final connectionIntent = container
          .read(synchingProvider(syncId: 1).notifier)
          .captureGoogleDriveConnectionIntent();
      var connectionSaved = false;
      return ChimahonRestoreSyncCoordinator.shared
          .duringSync(() async {
            botToast('Opening Google Drive sign-in…');
            final oauth = GoogleDriveOAuthClient();
            try {
              final tokens = await oauth.signIn();
              final deviceId = container
                  .read(synchingProvider(syncId: 1).notifier)
                  .ensureChimahonDeviceId();
              final storage = GoogleDriveSyncStorage(
                accessToken: tokens.accessToken,
                deviceId: deviceId,
              );
              try {
                // Verify the stable Drive account identity used to isolate
                // local merge baselines before persisting the credential.
                final permissionId = await storage.currentUserPermissionId();
                final activeMediaSelectionScopeToken =
                    chimahonMediaSelectionScopeToken(
                      'google-drive|${oauth.config.clientId}|$permissionId',
                    );
                final remote = await storage.download();
                final currentPreference = container.read(
                  synchingProvider(syncId: 1),
                );
                final currentSelectionState =
                    ChimahonMediaSyncSelectionState.fromPreference(
                      currentPreference,
                    );
                final remotePreferences = remote == null
                    ? null
                    : const ChimahonSyncCodec()
                          .decode(remote.bytes)
                          .backup
                          .backupPreferences;
                final bootstrappedSelection =
                    chimahonMediaSelectionBootstrapForScope(
                      current: currentSelectionState,
                      activeScopeToken: activeMediaSelectionScopeToken,
                      remotePreferences: remotePreferences,
                    );
                const tokenStore = SecureGoogleDriveRefreshTokenStore();
                await persistGoogleDriveConnectionWithTokenRollback(
                  tokenStore: tokenStore,
                  newRefreshToken: tokens.refreshToken,
                  persistConnection: () => container
                      .read(synchingProvider(syncId: 1).notifier)
                      .persistGoogleDriveConnectionIfIntentCurrent(
                        intent: connectionIntent,
                        mediaSelection: bootstrappedSelection,
                        mediaSelectionInitialized: false,
                        mediaSelectionUserSelected: false,
                        mediaSelectionScopeToken:
                            activeMediaSelectionScopeToken,
                        expectedMediaSelectionState: currentSelectionState,
                      ),
                  markDisconnected: () => container
                      .read(synchingProvider(syncId: 1).notifier)
                      .setGoogleDriveConnected(false),
                );
                connectionSaved = true;
                if (context.mounted) {
                  final connectionMessage = remote == null
                      ? 'Google Drive connected; no Chimahon sync file found'
                      : 'Google Drive connected; Chimahon sync data found';
                  botToast(
                    '$connectionMessage'
                    '${pauseToken.changedSchedule ? '; automatic sync was turned off for the first review' : ''}',
                    second: 5,
                  );
                }
              } catch (error) {
                if (context.mounted) {
                  botToast(
                    safeSyncUserMessage(
                      error,
                      context: SyncUserMessageContext.googleDriveConnection,
                    ),
                    second: 8,
                  );
                }
              } finally {
                storage.close();
              }
            } catch (error) {
              if (context.mounted) {
                botToast(
                  safeSyncUserMessage(
                    error,
                    context: SyncUserMessageContext.googleDriveConnection,
                  ),
                  second: 8,
                );
              }
            } finally {
              oauth.close();
            }
          })
          .whenComplete(() {
            if (!connectionSaved) {
              container
                  .read(synchingProvider(syncId: 1).notifier)
                  .restoreAutoSyncAfterFailedExternalOperation(pauseToken);
            }
          });
    });
  }

  Future<void> _disconnectGoogleDrive(BuildContext context) async {
    final container = ProviderScope.containerOf(context, listen: false);
    // Record the user's disconnect intent before waiting behind an OAuth flow.
    container
        .read(synchingProvider(syncId: 1).notifier)
        .invalidateGoogleDriveConnectionIntent();
    final failureMessage = await ChimahonRestoreSyncCoordinator.shared
        .duringSync(
          () => disconnectGoogleDriveCredentialSafely(
            tokenStore: const SecureGoogleDriveRefreshTokenStore(),
            markDisconnected: () => container
                .read(synchingProvider(syncId: 1).notifier)
                .setGoogleDriveConnected(false),
          ),
        );
    if (failureMessage != null && context.mounted) {
      botToast(failureMessage, second: 8);
    }
  }

  Future<void> _disconnectWebDav(BuildContext context, WidgetRef ref) async {
    try {
      await const SecureWebDavCredentialStore().clearCredentials();
      ref.read(synchingProvider(syncId: 1).notifier).disconnectWebDav();
      botToast('WebDAV disconnected');
    } catch (error) {
      if (context.mounted) {
        botToast(
          safeSyncUserMessage(
            error,
            context: SyncUserMessageContext.webDavDisconnection,
          ),
          second: 8,
        );
      }
    }
  }
}

/// Clears the secure credential before changing the visible connection state.
/// Returns fixed user-facing text on failure and never renders the exception.
@visibleForTesting
Future<String?> disconnectGoogleDriveCredentialSafely({
  required GoogleDriveRefreshTokenStore tokenStore,
  required void Function() markDisconnected,
}) async {
  try {
    await tokenStore.clearRefreshToken();
    markDisconnected();
    return null;
  } catch (error) {
    return safeSyncUserMessage(
      error,
      context: SyncUserMessageContext.googleDriveDisconnection,
    );
  }
}

/// Persists a new Drive credential and compensates if the local connection
/// row cannot be committed. A known previous credential is restored; without
/// one, the new token is removed and the UI is marked disconnected.
@visibleForTesting
Future<void> persistGoogleDriveConnectionWithTokenRollback({
  required GoogleDriveRefreshTokenStore tokenStore,
  required String newRefreshToken,
  required void Function() persistConnection,
  required void Function() markDisconnected,
}) async {
  String? previousRefreshToken;
  var previousTokenKnown = false;
  try {
    previousRefreshToken = await tokenStore.readRefreshToken();
    previousTokenKnown = true;
  } catch (_) {
    // An unreadable prior token cannot safely be restored.
  }

  await tokenStore.writeRefreshToken(newRefreshToken);
  try {
    persistConnection();
  } catch (error, stackTrace) {
    var priorRestored = false;
    if (previousTokenKnown && previousRefreshToken != null) {
      try {
        await tokenStore.writeRefreshToken(previousRefreshToken);
        priorRestored = true;
      } catch (_) {
        // Fall through to revoking the new credential below.
      }
    }
    if (!priorRestored) {
      try {
        await tokenStore.clearRefreshToken();
      } catch (_) {
        // Preserve the original database failure for the caller.
      }
      try {
        markDisconnected();
      } catch (_) {
        // Preserve the original database failure for the caller.
      }
    }
    Error.throwWithStackTrace(error, stackTrace);
  }
}
