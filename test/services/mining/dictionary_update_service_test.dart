import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangayomi/services/hoshidicts/dictionary_storage.dart';
import 'package:mangayomi/services/mining/dictionary_update_service.dart';

void main() {
  group('hasNewerDictionaryRevision', () {
    test('compares numeric revisions component by component', () {
      expect(hasNewerDictionaryRevision('1.9', '1.10'), isTrue);
      expect(hasNewerDictionaryRevision('2.0', '1.99'), isFalse);
      expect(hasNewerDictionaryRevision('1.0', '1.0'), isFalse);
    });

    test('compares numeric revisions longer than an int', () {
      expect(
        hasNewerDictionaryRevision(
          '20240501123000000000',
          '20240601123000000000',
        ),
        isTrue,
      );
    });

    test('falls back to lexical comparison for named revisions', () {
      expect(hasNewerDictionaryRevision('2026-a', '2026-b'), isTrue);
      expect(hasNewerDictionaryRevision(null, '2'), isFalse);
    });
  });

  test('checks a compatible Yomitan remote update index', () async {
    final client = MockClient((request) async {
      expect(request.url, Uri.parse('https://example.test/index.json'));
      return http.Response(
        '{"revision":"1.10",'
        '"downloadUrl":"https://example.test/dictionary-1.10.zip"}',
        200,
      );
    });
    final service = DictionaryUpdateService(client: client);
    const dictionary = InstalledDictionary(
      name: 'Test',
      hasTerms: true,
      hasFrequencies: false,
      hasPitch: false,
      revision: '1.9',
      isUpdatable: true,
      indexUrl: 'https://example.test/index.json',
      downloadUrl: 'https://example.test/dictionary-1.9.zip',
    );

    final update = await service.check(dictionary);

    expect(update.hasUpdate, isTrue);
    expect(update.latestRevision, '1.10');
    expect(
      update.latestDownloadUrl,
      'https://example.test/dictionary-1.10.zip',
    );
  });
}
