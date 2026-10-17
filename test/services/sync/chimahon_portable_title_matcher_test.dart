import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/services/sync/chimahon_portable_title_matcher.dart';
import 'package:mangayomi/services/sync/mihon_backup_source_resolver.dart';

const _source = ResolvedMihonBackupSource(
  nativeId: 1001,
  name: 'Source',
  language: 'en',
  localId: 7,
  installed: true,
);

Manga _manga(
  int id, {
  String link = '/title',
  String name = 'Title',
  String? author = 'Author',
  String? mihonSourceId = '1001',
  int? sourceId = 7,
  ItemType itemType = ItemType.manga,
  bool localArchive = false,
  bool overlay = false,
}) => Manga(
  id: id,
  source: 'Source',
  author: author,
  artist: null,
  genre: const [],
  imageUrl: null,
  lang: 'en',
  link: link,
  name: name,
  status: Status.ongoing,
  description: null,
  sourceId: sourceId,
  mihonSourceId: mihonSourceId,
  itemType: itemType,
  isLocalArchive: localArchive,
  hasLocalChapterOverlay: overlay,
);

Manga? _find(
  List<Manga> local, {
  String url = '/title',
  String title = 'Title',
  String? author = 'Author',
  bool fallback = false,
}) => const ChimahonPortableTitleMatcher().find(
  localMangas: local,
  itemType: ItemType.manga,
  source: _source,
  url: url,
  sourceTitle: title,
  author: author,
  allowSourceUrlFallback: fallback,
);

void main() {
  test('matches by source, url, title and author, ignoring case', () {
    final match = _manga(1);
    expect(_find([match], title: ' title ', author: 'AUTHOR'), same(match));
  });

  test('never matches another source, item type or a local archive', () {
    expect(_find([_manga(1, mihonSourceId: '999', sourceId: 8)]), isNull);
    expect(_find([_manga(2, itemType: ItemType.anime)]), isNull);
    expect(_find([_manga(3, localArchive: true)]), isNull);
  });

  test('a renamed title matches by url only when fallback is allowed', () {
    final renamed = _manga(1, name: 'Old name');
    expect(_find([renamed]), isNull);
    expect(_find([renamed], fallback: true), same(renamed));
  });

  test('url fallback refuses to guess between two candidates', () {
    final local = [_manga(1, name: 'A'), _manga(2, name: 'B')];
    expect(_find(local, fallback: true), isNull);
  });

  test('duplicates resolve to the one holding local chapter data', () {
    final plain = _manga(1);
    final withFiles = _manga(2, overlay: true);
    expect(_find([plain, withFiles]), same(withFiles));
  });

  test('duplicates that both hold local data stay ambiguous', () {
    expect(_find([_manga(1, overlay: true), _manga(2, overlay: true)]), isNull);
  });

  test('a pre-Mihon-identity row matches through the installed source', () {
    final legacy = _manga(1, mihonSourceId: null, sourceId: 7);
    expect(_find([legacy]), same(legacy));
  });

  test('without a url, title and author must match exactly per source', () {
    final match = _manga(1, link: '');
    expect(_find([match], url: ''), same(match));
    expect(_find([match], url: '', author: 'Someone else'), isNull);
  });

  test('identity keys differ when any identity field differs', () {
    const matcher = ChimahonPortableTitleMatcher();
    final key = matcher.identityKey(_manga(1));
    expect(matcher.identityKey(_manga(2)), key);
    expect(matcher.identityKey(_manga(3, link: '/other')), isNot(key));
    expect(matcher.identityKey(_manga(4, author: 'Other')), isNot(key));
    expect(matcher.identityKey(_manga(5, mihonSourceId: '2')), isNot(key));
  });
}
