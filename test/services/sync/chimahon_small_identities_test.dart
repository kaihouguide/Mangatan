import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupExtensionRepos.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupFeed.pb.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupSavedSearch.pb.dart';
import 'package:mangayomi/services/sync/chimahon_anime_repo_identity.dart';
import 'package:mangayomi/services/sync/chimahon_feed_identity.dart';

void main() {
  group('anime repository identity', () {
    test('a signing key wins over the URL so a moved repo matches', () {
      final old = BackupExtensionRepos(
        baseUrl: 'https://old.example/repo',
        signingKeyFingerprint: 'ABC',
      );
      final moved = BackupExtensionRepos(
        baseUrl: 'https://new.example/repo',
        signingKeyFingerprint: ' abc ',
      );
      expect(
        chimahonAnimeRepositoryIdentity(old),
        chimahonAnimeRepositoryIdentity(moved),
      );
    });

    test('without a key, URLs match ignoring case and trailing slashes', () {
      expect(
        chimahonAnimeRepositoryIdentity(
          BackupExtensionRepos(baseUrl: 'https://Repo.example/x//'),
        ),
        chimahonAnimeRepositoryIdentity(
          BackupExtensionRepos(baseUrl: 'https://repo.example/x'),
        ),
      );
    });
  });

  group('feed identity', () {
    test('an absent global flag means true, as in Chimahon', () {
      final absent = BackupFeed(source: Int64(1));
      final explicit = BackupFeed(source: Int64(1), global: true);
      expect(ChimahonFeedIdentity.semanticGlobal(absent), isTrue);
      expect(
        ChimahonFeedIdentity.key(absent),
        ChimahonFeedIdentity.key(explicit),
      );
      expect(
        ChimahonFeedIdentity.key(absent),
        isNot(
          ChimahonFeedIdentity.key(BackupFeed(source: Int64(1), global: false)),
        ),
      );
    });

    test('length framing keeps distinct saved searches apart', () {
      BackupFeed feed(String name) => BackupFeed(
        source: Int64(1),
        savedSearch: BackupSavedSearch(name: name),
      );
      expect(
        ChimahonFeedIdentity.key(feed('a')),
        isNot(ChimahonFeedIdentity.key(feed('b'))),
      );
    });
  });
}
