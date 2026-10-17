import 'dart:ffi';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart' as app;
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/history.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/models/track.dart';
import 'package:mangayomi/modules/anime/providers/anime_player_controller_provider.dart';
import 'package:mangayomi/repositories/settings_repository.dart';

import '../../test_utils/isar_library.dart';

void main() {
  late Directory databaseDirectory;
  late Isar database;
  late ProviderContainer container;

  setUpAll(() async {
    await Isar.initializeIsarCore(
      libraries: {Abi.current(): await isarTestLibraryPath()},
    );
  });

  setUp(() async {
    databaseDirectory = await Directory.systemTemp.createTemp(
      'mangatan-anime-position-',
    );
    database = await Isar.open(
      [
        MangaSchema,
        ChapterSchema,
        HistorySchema,
        SettingsSchema,
        SourceSchema,
        TrackSchema,
      ],
      directory: databaseDirectory.path,
      name: 'anime_position_test',
    );
    app.isar = database;
    await database.writeTxn(() => database.settings.put(Settings()));
    container = ProviderContainer();
  });

  tearDown(() async {
    container.dispose();
    await database.close(deleteFromDisk: true);
    if (await databaseDirectory.exists()) {
      await databaseDirectory.delete(recursive: true);
    }
  });

  test('a queued sync write waits for an in-flight progress save', () async {
    final episode = Chapter(mangaId: 1, name: 'Episode 1', isRead: false);
    await database.writeTxn(() => database.chapters.put(episode));

    // Isar rejects a synchronous transaction while an async one is open. Both
    // writes go through the write queue, so the settings write waits.
    final progress = container
        .read(animeStreamControllerProvider(episode: episode).notifier)
        .setCurrentPosition(
          const Duration(seconds: 30),
          const Duration(minutes: 24),
          save: true,
        );
    final settings = settingsRepository.update((s) => s.cropBorders = true);
    await Future.wait([progress, settings]);

    expect((await database.chapters.get(episode.id!))?.lastPageRead, '30000');
    expect((await database.settings.get(227))?.cropBorders, isTrue);
  });

  test('saving anime progress persists its total duration for sync', () async {
    final episode = Chapter(mangaId: 1, name: 'Episode 1', isRead: false);
    await database.writeTxn(() => database.chapters.put(episode));

    await container
        .read(animeStreamControllerProvider(episode: episode).notifier)
        .setCurrentPosition(
          const Duration(seconds: 49),
          const Duration(minutes: 24),
          save: true,
        );

    final saved = await database.chapters.get(episode.id!);
    expect(saved?.lastPageRead, '49000');
    expect(saved?.duration, '1440000');
  });

  test(
    'completing playback marks the episode seen and updates history',
    () async {
      final manga = Manga(
        source: 'Source',
        author: '',
        artist: '',
        genre: const [],
        imageUrl: null,
        lang: 'en',
        link: '/anime',
        name: 'Anime',
        status: Status.ongoing,
        description: '',
        sourceId: 1,
      );
      await database.writeTxn(() => database.mangas.put(manga));
      final episode = Chapter(
        mangaId: manga.id,
        name: 'Episode 1',
        isRead: false,
      )..manga.value = manga;
      await database.writeTxn(() async {
        await database.chapters.put(episode);
        await episode.manga.save();
      });

      await container
          .read(animeStreamControllerProvider(episode: episode).notifier)
          .completeEpisode(const Duration(minutes: 24), elapsedSeconds: 42);

      final saved = await database.chapters.get(episode.id!);
      final history = await database.historys.where().findFirst();
      expect(saved?.isRead, isTrue);
      expect(saved?.lastPageRead, '1440000');
      expect(saved?.duration, '1440000');
      expect(history?.mangaId, manga.id);
      expect(history?.chapterId, episode.id);
      expect(history?.readingTimeSeconds, 42);
    },
  );
}
