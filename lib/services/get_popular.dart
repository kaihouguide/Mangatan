import 'package:mangayomi/eval/model/m_pages.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/services/local_source_browser.dart';
import 'package:mangayomi/services/m_extension_server.dart';
import 'package:mangayomi/services/isolate_service.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'get_popular.g.dart';

@riverpod
Future<MPages?> getPopular(
  Ref ref, {
  required Source source,
  required int page,
}) async {
  if (source.name == "local" && source.lang == "") {
    return buildLocalSourcePage(
      await loadLocalSourceNames(isar, itemType: source.itemType),
      page: page,
    );
  }

  final proxyServer = await prepareMihonBridge(ref, source);
  return getIsolateService.get<MPages?>(
    page: page,
    source: source,
    serviceType: 'getPopular',
    proxyServer: proxyServer,
  );
}
