import 'dart:convert';
import 'dart:io';

import 'package:isar_community/isar.dart';
import 'package:mangayomi/eval/mihon/bridge_protocol.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/services/fetch_sources_list.dart';
import 'package:mangayomi/services/http/m_client.dart';
import 'package:mangayomi/services/m_extension_server.dart';
import 'package:mangayomi/utils/platform_utils.dart';
import 'package:mangayomi/repositories/db_write_queue.dart';

class MihonApkImportResult {
  const MihonApkImportResult({
    required this.extension,
    required this.itemType,
    required this.sourceCount,
  });

  final MihonExtensionDescriptor extension;
  final ItemType itemType;
  final int sourceCount;
}

class MihonApkImportPlan {
  const MihonApkImportPlan({
    required this.itemType,
    required this.sourceCodeUrl,
    required this.sources,
    required this.unavailableSourceIds,
  });

  final ItemType itemType;
  final String sourceCodeUrl;
  final List<Source> sources;
  final Set<int> unavailableSourceIds;
}

class MihonApkImportException implements Exception {
  const MihonApkImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

Future<MihonApkImportResult> importMihonExtensionApk(
  MExtensionServerPlatform server,
  String apkPath,
) async {
  if (!isDesktop) {
    throw const MihonApkImportException(
      'Local Mihon APK imports are supported on desktop only.',
    );
  }

  final file = File(apkPath);
  final apkBytes = await file.readAsBytes();
  if (apkBytes.length < 4 ||
      apkBytes[0] != 0x50 ||
      apkBytes[1] != 0x4b ||
      apkBytes[2] != 0x03 ||
      apkBytes[3] != 0x04) {
    throw const MihonApkImportException(
      'The selected file is not a valid APK archive.',
    );
  }

  final apkBase64 = base64.encode(apkBytes);
  final probe = Source()
    ..sourceCodeLanguage = SourceCodeLanguage.mihon
    ..sourceCode = apkBase64
    ..itemType = ItemType.manga;
  await server.startServer();
  if (!await server.check()) {
    throw const MihonBridgeUnavailableException();
  }
  final androidProxyServer = server.baseUrl;
  final client = MClient.init(reqcopyWith: {'useDartHttpClient': true});

  late final MihonExtensionDescriptor extension;
  try {
    extension = await fetchMihonExtensionDescriptor(
      client,
      probe,
      androidProxyServer,
    );
  } catch (error) {
    throw MihonApkImportException(
      'Could not inspect this APK. Make sure the configured extension-server '
      'supports local APK imports and that the file is a compatible Mihon or '
      'Aniyomi extension. ($error)',
    );
  }

  final existingSources = await isar.sources.where().findAll();
  final plan = planMihonApkImport(
    extension: extension,
    apkBase64: apkBase64,
    existingSources: existingSources,
  );
  await installMihonApkSources(
    sources: plan.sources,
    apkBase64: apkBase64,
    androidProxyServer: androidProxyServer,
    itemType: plan.itemType,
  );
  await _markUnavailablePackageSources(extension, plan, apkBase64);

  return MihonApkImportResult(
    extension: extension,
    itemType: plan.itemType,
    sourceCount: plan.sources.length,
  );
}

MihonApkImportPlan planMihonApkImport({
  required MihonExtensionDescriptor extension,
  required String apkBase64,
  required Iterable<Source> existingSources,
}) {
  final itemType = switch (extension.itemType) {
    MihonExtensionItemType.manga => ItemType.manga,
    MihonExtensionItemType.anime => ItemType.anime,
  };
  final sourceCodeUrl = Uri(
    scheme: 'mihon-apk',
    host: extension.packageName,
  ).toString();
  final existingByNativeId = <String, Source>{};
  final existingPackageSources = <Source>[];
  for (final source in existingSources) {
    final metadata = mihonSourceMetadata(source);
    if (metadata == null) continue;
    existingByNativeId[metadata.sourceId] = source;
    if (metadata.packageName == extension.packageName) {
      existingPackageSources.add(source);
    }
  }

  final version = extension.versionName.isEmpty
      ? '0.0.0'
      : extension.versionName;
  final sources = extension.sources
      .map((descriptor) {
        final existing = existingByNativeId[descriptor.id];
        final latestVersion = _latestKnownVersion(
          existing?.versionLast,
          version,
        );
        final wasUninstalledLocalSource =
            existing != null &&
            isLocallyImportedMihonExtension(existing) &&
            existing.isAdded != true;
        return Source()
          ..id = mihonLocalSourceId(descriptor.id)
          ..name = descriptor.name
          ..baseUrl = descriptor.baseUrl
          ..lang = descriptor.lang
          ..isActive = wasUninstalledLocalSource
              ? true
              : existing?.isActive ?? true
          ..isAdded = true
          ..isPinned = existing?.isPinned ?? false
          ..isNsfw = extension.isNsfw
          ..sourceCode = apkBase64
          ..sourceCodeUrl = sourceCodeUrl
          ..typeSource = ''
          ..iconUrl = existing?.iconUrl ?? ''
          ..isFullData = false
          ..hasCloudflare = false
          ..lastUsed = existing?.lastUsed ?? false
          ..dateFormat = ''
          ..dateFormatLocale = ''
          ..apiUrl = ''
          ..version = version
          ..versionLast = latestVersion
          ..itemType = itemType
          ..appMinVerReq = ''
          ..additionalParams = encodeMihonSourceMetadata(
            sourceId: descriptor.id,
            packageName: extension.packageName,
            extensionName: extension.name,
            packageLang: extension.lang,
          )
          ..isLocal = false
          ..isObsolete = false
          ..sourceCodeLanguage = SourceCodeLanguage.mihon
          ..notes = 'Imported from a local APK'
          ..repo = null;
      })
      .toList(growable: false);

  final importedNativeIds = extension.sources
      .map((source) => source.id)
      .toSet();
  final unavailableSourceIds = existingPackageSources
      .where((source) {
        final nativeId = mihonSourceMetadata(source)?.sourceId;
        return nativeId != null && !importedNativeIds.contains(nativeId);
      })
      .map((source) => source.id)
      .nonNulls
      .toSet();

  return MihonApkImportPlan(
    itemType: itemType,
    sourceCodeUrl: sourceCodeUrl,
    sources: sources,
    unavailableSourceIds: unavailableSourceIds,
  );
}

Future<void> _markUnavailablePackageSources(
  MihonExtensionDescriptor extension,
  MihonApkImportPlan plan,
  String apkBase64,
) async {
  if (plan.unavailableSourceIds.isEmpty) return;
  final sources = await isar.sources.getAll(
    plan.unavailableSourceIds.toList(growable: false),
  );
  final now = DateTime.now().millisecondsSinceEpoch;
  final version = extension.versionName.isEmpty
      ? '0.0.0'
      : extension.versionName;
  final updates = <Source>[];
  for (final source in sources.nonNulls) {
    final metadata = mihonSourceMetadata(source);
    if (metadata?.packageName != extension.packageName) continue;
    source
      ..isAdded = true
      ..isActive = false
      ..sourceCode = apkBase64
      ..sourceCodeUrl = plan.sourceCodeUrl
      ..version = version
      ..versionLast = _latestKnownVersion(source.versionLast, version)
      ..itemType = plan.itemType
      ..additionalParams = encodeMihonSourceMetadata(
        sourceId: metadata!.sourceId,
        packageName: extension.packageName,
        factoryAvailable: false,
        extensionName: extension.name,
        packageLang: extension.lang,
      )
      ..isObsolete = false
      ..repo = null
      ..updatedAt = now;
    updates.add(source);
  }
  if (updates.isEmpty) return;
  await dbWriteQueue.run(
    () => isar.writeTxn(() => isar.sources.putAll(updates)),
  );
}

String _latestKnownVersion(String? current, String imported) {
  if (current == null || current.isEmpty) return imported;
  return compareVersions(current, imported) >= 0 ? current : imported;
}
