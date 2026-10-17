import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/utils/source_lookup.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';

Source? getSource(
  String lang,
  String name,
  int? sourceId, {
  bool installedOnly = false,
}) {
  try {
    var sourcesFilter = isar.sources.filter().idIsNotNull();
    if (installedOnly) {
      // isActive is the Browse language/source visibility filter. A hidden
      // source remains installed and must still serve existing library items.
      sourcesFilter = sourcesFilter.isAddedEqualTo(true);
    }
    final sourcesList = sourcesFilter.findAllSync();
    return findSourceFromList(
      sourcesList,
      lang: lang,
      name: name,
      sourceId: sourceId,
      installedOnly: installedOnly,
    );
  } catch (_) {
    return null;
  }
}
