import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangayomi/eval/mihon/service.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/services/m_extension_server.dart';
import 'package:mangayomi/utils/log/logger.dart';

String resolveSourceUrl({required String baseUrl, required String url}) {
  final value = url.trim();
  if (value.isEmpty) return baseUrl;

  final parsed = Uri.tryParse(value);
  if (parsed?.hasScheme ?? false) return parsed.toString();

  final normalizedBase = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
  final base = Uri.tryParse(normalizedBase);
  return base?.resolve(value).toString() ?? '$normalizedBase$value';
}

Future<String> getMangaWebViewUrl(
  WidgetRef ref, {
  required Source source,
  required Manga manga,
}) async {
  final fallback = resolveSourceUrl(
    baseUrl: source.baseUrl ?? '',
    url: manga.link ?? '',
  );
  if (source.sourceCodeLanguage != SourceCodeLanguage.mihon) return fallback;

  return _withMihonService(
    ref,
    source,
    fallback: fallback,
    getUrl: (service) => service.getMangaWebViewUrl(manga),
  );
}

Future<String> getChapterWebViewUrl(
  WidgetRef ref, {
  required Source source,
  required Chapter chapter,
}) async {
  final fallback = resolveSourceUrl(
    baseUrl: source.baseUrl ?? '',
    url: chapter.url ?? '',
  );
  if (source.sourceCodeLanguage != SourceCodeLanguage.mihon) return fallback;

  return _withMihonService(
    ref,
    source,
    fallback: fallback,
    getUrl: (service) => service.getChapterWebViewUrl(chapter),
  );
}

Future<String> _withMihonService(
  WidgetRef ref,
  Source source, {
  required String fallback,
  required Future<String> Function(MihonExtensionService service) getUrl,
}) async {
  final server = MExtensionServerPlatform(ref);
  try {
    await server.startServer();
  } catch (error) {
    // The website URL needs no bridge. Opening or sharing it must still work;
    // bridge failures surface where the bridge itself is required.
    AppLogger.log(
      'Mihon bridge unavailable for a WebView URL: $error',
      logLevel: LogLevel.warning,
    );
    return fallback;
  }
  final service = MihonExtensionService(source, server.baseUrl);
  try {
    final url = (await getUrl(service)).trim();
    return url.isEmpty ? fallback : url;
  } catch (_) {
    // Older bridge JARs do not expose source-defined URLs. Keep their WebView
    // usable with standards-based resolution until the JAR is upgraded.
    return fallback;
  } finally {
    service.dispose();
  }
}
