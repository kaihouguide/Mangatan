import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:mangayomi/services/download_manager/jimaku_download.dart';
import 'package:mangayomi/services/mining/jimaku_service.dart';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:mangayomi/eval/lib.dart';
import 'package:mangayomi/eval/model/m_bridge.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/page.dart';
import 'package:mangayomi/repositories/download_repository.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/download.dart';
import 'package:mangayomi/models/video.dart';
import 'package:mangayomi/modules/anime/utils/video_stream_preference.dart';
import 'package:mangayomi/modules/manga/download/providers/convert_to_cbz.dart';
import 'package:mangayomi/modules/manga/download/providers/download_gate.dart';
import 'package:mangayomi/modules/manga/detail/providers/export_metadata.dart';
import 'package:mangayomi/modules/more/settings/browse/providers/browse_state_provider.dart';
import 'package:mangayomi/modules/more/settings/downloads/providers/downloads_state_provider.dart';
import 'package:mangayomi/modules/more/settings/general/providers/general_state_provider.dart';
import 'package:mangayomi/providers/storage_provider.dart';
import 'package:mangayomi/services/download_manager/download_queue_order.dart';
import 'package:mangayomi/services/download_manager/download_isolate_pool.dart';
import 'package:mangayomi/services/download_manager/m_downloader.dart';
import 'package:mangayomi/services/download_manager/downloaded_manga_artifact.dart';
import 'package:mangayomi/services/get_video_list.dart';
import 'package:mangayomi/services/get_chapter_pages.dart';
import 'package:mangayomi/services/http/m_client.dart';
import 'package:mangayomi/services/mining/mokuro_sidecar.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';
import 'package:mangayomi/services/download_manager/m3u8/m3u8_downloader.dart';
import 'package:mangayomi/services/download_manager/video_list_retry.dart';
import 'package:mangayomi/services/download_manager/m3u8/models/download.dart';
import 'package:mangayomi/utils/chapter_recognition.dart';
import 'package:mangayomi/utils/downloaded_page_file.dart';
import 'package:mangayomi/utils/extensions/string_extensions.dart';
import 'package:mangayomi/utils/headers.dart';
import 'package:mangayomi/utils/localized_message.dart';
import 'package:mangayomi/utils/reg_exp_matcher.dart';
import 'package:mangayomi/utils/utils.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/repositories/db_write_queue.dart';

export 'download_gate.dart' show isDownloadScheduled;

part 'download_provider.g.dart';

@riverpod
Future<void> addDownloadToQueue(Ref ref, {required Chapter chapter}) async {
  await downloadRepository.enqueue(chapter);
}

@riverpod
Future<void> downloadChapter(
  Ref ref, {
  required Chapter chapter,
  bool? useWifi,
  VoidCallback? callback,
}) async {
  if (!scheduleDownload(chapter.id!)) return;
  final keepAlive = ref.keepAlive();

  // Show the chapter as queued straight away, before it waits for a slot, so
  // the download icon reacts to the tap immediately even while it sits in the
  // gate behind other downloads.

  // Every download path funnels through here, so acquiring the shared gate is
  // what makes the concurrency limit, per-source serialization (#645) and the
  // start delay/jitter (#621) apply no matter how the download was started.
  final sourceKey = chapterSourceKey(chapter);
  var acquired = false;
  try {
    final maxConcurrent = ref.read(allowConcurrentDownloadsStateProvider)
        ? ref.read(concurrentDownloadsStateProvider)
        : 1;
    final delaySeconds = ref.read(downloadDelaySecondsStateProvider);
    await downloadRepository.enqueue(chapter);
    if (downloadRepository.getById(chapter.id!)?.isDownload == true) return;
    await DownloadGate.instance.acquire(
      id: chapter.id!,
      sourceKey: sourceKey,
      maxConcurrent: maxConcurrent,
      delaySeconds: delaySeconds,
    );
    acquired = true;
    // Cancelled while it waited for a slot in the gate? Its record was deleted,
    // so don't resurrect it.
    if (isDownloadCancelled(chapter)) {
      keepAlive.close();
      return;
    }
    bool onlyOnWifi = useWifi ?? ref.read(onlyOnWifiStateProvider);
    final connectivity = await Connectivity().checkConnectivity();
    final isOnWifi =
        connectivity.contains(ConnectivityResult.wifi) ||
        connectivity.contains(ConnectivityResult.ethernet);
    if (onlyOnWifi && !isOnWifi) {
      botToast(localizedMessage((l10n) => l10n.downloads_are_limited_to_wifi));
      return;
    }
    final http = MClient.init(
      reqcopyWith: {'useDartHttpClient': true, 'followRedirects': false},
    );

    List<PageUrl> pageUrls = [];
    PageUrl? novelPage;
    List<PageUrl> pages = [];
    final StorageProvider storageProvider = StorageProvider();
    await storageProvider.requestPermission();
    final manga = chapter.manga.value!;
    final itemType = manga.itemType;
    final mangaMainDirectory = (await storageProvider.getMangaMainDirectory(
      chapter,
    ))!;
    await storageProvider.createDirectorySafely(mangaMainDirectory.path);
    final metadataHeaders = (manga.isLocalArchive ?? false)
        ? null
        : ref.read(
            headersProvider(
              source: manga.source!,
              lang: manga.lang!,
              sourceId: manga.sourceId,
            ),
          );
    await exportMangaMetadata(
      manga: manga,
      directory: mangaMainDirectory,
      headers: metadataHeaders,
      onlyIfMissing: true,
    );
    List<Track>? subtitles;
    bool isOk = false;
    // Reason the download couldn't be prepared, if any — used to fail loudly
    // instead of hanging in the wait-loop below.
    String? startFailure;
    final chapterName = downloadedMangaChapterBaseName(chapter);
    final saveAsCbz = ref.read(saveAsCBZArchiveStateProvider);
    final chapterDirectory = (await storageProvider.getMangaChapterDirectory(
      chapter,
      mangaMainDirectory: mangaMainDirectory,
    ))!;
    await storageProvider.createDirectorySafely(chapterDirectory.path);
    Map<String, String> videoHeader = {};
    Map<String, String> htmlHeader = {
      "Priority": "u=0, i",
      "User-Agent": ref.read(userAgentStateProvider),
    };
    bool hasM3U8File = false;
    List<Video> m3u8Videos = [];

    Future<void> processConvert() async {
      if (!saveAsCbz) return;
      try {
        final pageFiles = await chapterDirectory
            .list()
            .where(
              (entity) =>
                  entity is File && entity.path.toLowerCase().endsWith('.jpg'),
            )
            .map((entity) => entity.path)
            .toList();

        // Extract chapter number from name (e.g., "Chapter 5" → "5")
        final chapterNumber = ChapterRecognition().resolveChapterNumber(
          chapter.manga.value!.name!,
          chapter.name!,
          sourceChapterNumber: chapter.chapterNumber,
        );

        final comicInfo = ComicInfoData(
          title: chapter.name,
          series: manga.name,
          number: chapterNumber.toString(),
          writer: manga.author,
          penciller: manga.artist,
          summary: manga.description,
          genre: manga.genre?.join(', '),
          translator: chapter.scanlator,
          publishingStatusStr: manga.status.name,
        );

        await ref.read(
          convertToCBZProvider(
            chapterDirectory.path,
            mangaMainDirectory.path,
            chapterName,
            pageFiles,
            comicInfo: comicInfo,
          ).future,
        );
      } catch (error) {
        botToast("Failed to create CBZ: $error");
      }
    }

    Future<void> persistMokuroSidecar() async {
      final source = getSource(manga.lang!, manga.source!, manga.sourceId);
      final sourceName = source?.name ?? manga.source ?? '';
      final artifact = saveAsCbz
          ? downloadedMangaChapterCbz(mangaMainDirectory, chapter)
          : chapterDirectory;
      if (!await artifact.exists()) return;

      final store = MokuroSidecarStore();
      try {
        await store.ensureDownloaded(
          sourceName: sourceName,
          chapterUrl: chapter.url ?? '',
          artifact: artifact,
        );
      } finally {
        store.close();
      }
    }

    int lastPersistedPercent = -1;
    var lastPersistTime = DateTime.fromMillisecondsSinceEpoch(0);
    Future<void> setProgress(DownloadProgress progress) async {
      final percent = progress.completed == 0 || progress.total == 0
          ? 0
          : (progress.completed / progress.total * 100).toInt();
      // Progress events arrive per network chunk (hundreds per video);
      // persisting each one floods the UI isolate with sync transactions.
      // Only write when the visible percentage changes (rate-limited) or on
      // completion.
      final now = DateTime.now();
      if (!progress.isCompleted &&
          (percent == lastPersistedPercent ||
              now.difference(lastPersistTime).inMilliseconds < 500)) {
        return;
      }
      lastPersistedPercent = percent;
      lastPersistTime = now;
      if (progress.total == 0) return;
      // Queued so progress never opens a synchronous transaction while another
      // queued write is open. The record is read inside the transaction:
      // cancellation deletes it, and a late progress callback must not
      // recreate it and make a cancelled item reappear.
      unawaited(
        dbWriteQueue.run(
          () => isar.writeTxnSync(() {
            final download = isar.downloads.getSync(chapter.id!);
            if (download == null) return;
            isar.downloads.putSync(
              download
                ..succeeded = percent
                ..total = 100
                ..failed = 0
                ..isDownload = progress.isCompleted,
            );
          }),
        ),
      );
    }

    Future<void> exportCoverFromDownloadedPages() async {
      if (itemType != ItemType.manga) return;
      if (findMangaCoverFile(mangaMainDirectory) != null) return;
      if (!await chapterDirectory.exists()) return;
      final imageFiles =
          await chapterDirectory
                .list()
                .where(
                  (entity) =>
                      entity is File && isRecognizedImageFile(entity.path),
                )
                .cast<File>()
                .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      if (imageFiles.isEmpty) return;
      await exportMangaCoverFromFile(
        directory: mangaMainDirectory,
        imageFile: imageFiles.first,
        onlyIfMissing: true,
      );
    }

    Future<void> deleteEmptyAnimeEpisodeDirectory() async {
      if (itemType != ItemType.anime) return;
      if (!await chapterDirectory.exists()) return;
      if (await chapterDirectory.list().isEmpty) {
        await chapterDirectory.delete();
      }
    }

    Future<void> finalizeDownload() async {
      if (isDownloadCancelled(chapter)) return;
      if (itemType == ItemType.anime) {
        await validateDownloadedVideoFile(
          File(p.join(mangaMainDirectory.path, "$chapterName.mp4")),
        );
      }
      if (itemType == ItemType.manga) {
        // The cover must be read from the page folder before CBZ conversion
        // replaces it.
        try {
          await exportCoverFromDownloadedPages();
        } catch (_) {
          // A missing local cover must not fail a completed download.
        }
        await processConvert();
        await persistMokuroSidecar();
      }
      if (itemType == ItemType.anime &&
          await MiningPreferences.getAutoJimakuEnabled()) {
        final service = JimakuSubtitleService();
        try {
          final episode = ChapterRecognition().parseEpisodeNumber(
            manga.name ?? '',
            chapter.name ?? '',
          );
          await downloadJimakuSidecars(
            service: service,
            apiKey: await MiningPreferences.getJimakuApiKey(),
            guess: buildChimahonJimakuGuess(
              overrideTitle: await MiningPreferences.getJimakuTitleOverride(
                manga.id,
              ),
              animeTitle: manga.name ?? '',
              mediaTitle: chapter.name ?? '',
              episodeNumber: episode > 0 ? episode : null,
            ),
            chapterDirectory: chapterDirectory.path,
          ).timeout(const Duration(seconds: 60));
        } catch (error) {
          botToast(
            'Video saved, but Jimaku subtitles could not be downloaded: $error',
          );
        } finally {
          service.close();
        }
      }
      await setProgress(DownloadProgress(1, 1, itemType, isCompleted: true));
      try {
        await deleteEmptyAnimeEpisodeDirectory();
      } catch (_) {
        // Leaving an empty folder behind is harmless.
      }
    }

    await setProgress(DownloadProgress(0, 0, itemType));
    if (itemType == ItemType.manga) {
      ref
          .read(getChapterPagesProvider(chapter: chapter).future)
          .then((value) {
            if (value.pageUrls.isNotEmpty) {
              pageUrls = value.pageUrls;
              isOk = true;
            } else {
              startFailure = "No pages returned by the source";
            }
          })
          .catchError((Object e) {
            startFailure = "Failed to load chapter pages: $e";
          });
    } else if (itemType == ItemType.anime) {
      try {
        final videoListProvider = getVideoListProvider(episode: chapter);
        final value = await resolveVideoListWithRetry(
          resolve: () => ref.read(videoListProvider.future),
          beforeRetry: () => ref.invalidate(videoListProvider),
        );
        final m3u8Urls = value.$1
            .where(
              (element) =>
                  _isM3u8Url(element.url) || _isM3u8Url(element.originalUrl),
            )
            .toList();
        final videosUrls = value.$1
            .where(
              (element) =>
                  // Jellyfin and some bridge proxies use extensionless
                  // stream endpoints, so the URL scheme is the reliable
                  // direct-download signal here.
                  _isHttpUrl(element.url) || m3u8Urls.contains(element),
            )
            .toList();
        if (videosUrls.isNotEmpty) {
          // Select across formats in source order, just like playback. A direct
          // link must not override the user's preferred HLS server (or vice versa).
          final selected = preferredVideoStream(
            videosUrls,
            await MiningPreferences.getVideoStreamPreference(manga.id),
          );
          hasM3U8File = m3u8Urls.contains(selected);
          if (hasM3U8File) {
            // Match the player's saved stream preference, then try the
            // remaining source URLs if that stream has expired.
            m3u8Videos = [
              selected,
              ...m3u8Urls.where((video) => video.url != selected.url),
            ];
            subtitles = selected.subtitles;
          } else {
            pageUrls = [PageUrl(selected.url)];
            subtitles = selected.subtitles;
            videoHeader.addAll(selected.headers ?? {});
          }
          isOk = true;
        } else {
          // Got a video list but nothing exposed a playable HTTP URL.
          startFailure = value.$1.isEmpty
              ? "No videos returned by the source"
              : "No downloadable URL among ${value.$1.length} video(s) "
                    "(none exposed an HTTP video or playlist URL)";
        }
      } catch (e) {
        startFailure = "Failed to load the video list: $e";
      }
    } else if (itemType == ItemType.novel && chapter.url != null) {
      final manga = chapter.manga.value!;
      final source = getSource(
        manga.lang!,
        manga.source!,
        manga.sourceId,
        installedOnly: true,
      )!;
      final chapterUrl = "${source.baseUrl}${chapter.url!.getUrlWithoutDomain}";
      final cookie = MClient.getCookiesPref(chapterUrl);
      final headers = htmlHeader;
      if (cookie.isNotEmpty) {
        final userAgent = ref.read(userAgentStateProvider);
        headers.addAll(cookie);
        headers[HttpHeaders.userAgentHeader] = userAgent;
      }
      final res = await http.get(Uri.parse(chapterUrl), headers: headers);
      if (res.headers.containsKey("Location")) {
        novelPage = PageUrl(res.headers["Location"]!);
      } else {
        novelPage = PageUrl(chapterUrl);
      }
      isOk = true;
    }

    // Wait for the source to resolve pages/video — but never forever. Bail on
    // a recorded failure or after a timeout so a bad/unmatched URL surfaces an
    // error instead of a silent, endless stall.
    final startDeadline = DateTime.now().add(const Duration(seconds: 45));
    await Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (isOk == true || startFailure != null) {
        return false;
      }
      if (DateTime.now().isAfter(startDeadline)) {
        startFailure = "Timed out preparing the download";
        return false;
      }
      return true;
    });

    if (!isOk) {
      botToast(startFailure ?? "Couldn't start the download");
      await markDownloadFailed(chapter);
      if (callback != null) callback();
      keepAlive.close();
      return;
    }

    // Cancelled during the (up to 45s) prep wait? Bail before writing files.
    if (isDownloadCancelled(chapter)) {
      keepAlive.close();
      return;
    }

    // HLS publishes a .ts file only after its transfer and decryption finish.
    // Keep those completed segments on retry; incomplete writes use .part.
    // Each stream URL has its own cache directory, so variants stay separate.

    if (pageUrls.isNotEmpty) {
      // A stalled or failed attempt can leave a partial single-file download
      // (anime .mp4, novel .html) on disk. The existence check below would then
      // treat it as already downloaded and mark it complete — a truncated but
      // "finished" file. If this chapter's download record is not actually
      // complete, delete any such leftover first so it re-downloads fresh.
      final downloadRecord = downloadRepository.getById(chapter.id!);
      if (!(downloadRecord?.isDownload ?? false)) {
        for (final leftover in [
          File(p.join(mangaMainDirectory.path, "$chapterName.mp4")),
          File(p.join(mangaMainDirectory.path, "$chapterName.html")),
        ]) {
          if (leftover.existsSync()) {
            try {
              leftover.deleteSync();
            } catch (_) {}
          }
        }
      }
      bool cbzFileExist =
          await downloadedMangaChapterCbz(
            mangaMainDirectory,
            chapter,
          ).exists() &&
          saveAsCbz;
      final animeFile = File(
        p.join(mangaMainDirectory.path, "$chapterName.mp4"),
      );
      bool mp4FileExist = await animeFile.exists();
      if (mp4FileExist && itemType == ItemType.anime) {
        try {
          await validateDownloadedVideoFile(animeFile);
        } catch (_) {
          await animeFile.delete();
          mp4FileExist = false;
        }
      }
      bool htmlFileExist = await File(
        p.join(mangaMainDirectory.path, "$chapterName.html"),
      ).exists();
      if (!cbzFileExist && itemType == ItemType.manga ||
          !mp4FileExist && itemType == ItemType.anime ||
          !htmlFileExist && itemType == ItemType.novel) {
        final mainDirectory = (await storageProvider.getDirectory())!;
        await storageProvider.createDirectorySafely(mainDirectory.path);
        for (var index = 0; index < pageUrls.length; index++) {
          if (Platform.isAndroid) {
            if (!(await File(p.join(mainDirectory.path, ".nomedia"))
                .exists())) {
              await File(p.join(mainDirectory.path, ".nomedia")).create();
            }
          }
          final page = pageUrls[index];
          final cookie = MClient.getCookiesPref(page.url);
          final headers = itemType == ItemType.manga
              ? ref.read(
                  headersProvider(
                    source: manga.source!,
                    lang: manga.lang!,
                    sourceId: manga.sourceId,
                  ),
                )
              : itemType == ItemType.anime
              ? videoHeader
              : htmlHeader;
          if (cookie.isNotEmpty) {
            final userAgent = ref.read(userAgentStateProvider);
            headers.addAll(cookie);
            headers[HttpHeaders.userAgentHeader] = userAgent;
          }
          Map<String, String> pageHeaders = headers;
          pageHeaders.addAll(page.headers ?? {});

          if (itemType == ItemType.manga) {
            final existing = findDownloadedPageFile(chapterDirectory, index);
            if (existing == null) {
              pages.add(
                PageUrl(
                  page.url.trim(),
                  headers: pageHeaders,
                  // No extension - the real one is only knowable once the
                  // response arrives (see download_isolate_pool.dart), which
                  // appends whatever detectImageExtension() finds. Every
                  // later lookup goes through findDownloadedPageFile, not
                  // this literal path.
                  fileName: p.join(chapterDirectory.path, padIndex(index)),
                ),
              );
            }
          } else if (itemType == ItemType.anime) {
            final file = File(
              p.join(mangaMainDirectory.path, "$chapterName.mp4"),
            );
            if (!file.existsSync()) {
              pages.add(
                PageUrl(
                  page.url.trim(),
                  headers: pageHeaders,
                  fileName: p.join(mangaMainDirectory.path, "$chapterName.mp4"),
                ),
              );
            }
          }
        }
      }

      if (pages.isEmpty && pageUrls.isNotEmpty) {
        await finalizeDownload();
      } else {
        await MDownloader(
          chapter: chapter,
          pageUrls: pages,
          subtitles: subtitles,
          subDownloadDir: chapterDirectory.path,
        ).download((progress) {
          if (!progress.isCompleted) setProgress(progress);
        });
        await finalizeDownload();
      }
    } else if (itemType == ItemType.novel) {
      final file = File(p.join(chapterDirectory.path, "$chapterName.html"));
      if (!file.existsSync() && novelPage != null) {
        final source = getSource(
          manga.lang!,
          manga.source!,
          manga.sourceId,
          installedOnly: true,
        )!;
        p.join(chapterDirectory.path, "$chapterName.html");
        final html = await withExtensionService(
          source,
          ref.read(androidProxyServerStateProvider),
          (service) =>
              service.getHtmlContent(chapter.manga.value!.name!, chapter.url!),
        );
        if (html.isNotEmpty) {
          await file.writeAsString(html);
          await setProgress(
            DownloadProgress(1, 1, itemType, isCompleted: true),
          );
        }
      } else {
        await setProgress(DownloadProgress(1, 1, itemType, isCompleted: true));
      }
    } else if (hasM3U8File) {
      Object? lastError;
      StackTrace? lastStackTrace;
      for (var index = 0; index < m3u8Videos.length; index++) {
        final video = m3u8Videos[index];
        try {
          await M3u8Downloader(
            m3u8Url: video.url,
            downloadDir: chapterDirectory.path,
            headers: video.headers ?? {},
            subtitles: video.subtitles,
            fileName: p.join(mangaMainDirectory.path, "$chapterName.mp4"),
            chapter: chapter,
          ).download((progress) {
            if (!progress.isCompleted) setProgress(progress);
          });
          lastError = null;
          break;
        } catch (error, stackTrace) {
          if (isDownloadCancelled(chapter)) rethrow;
          lastError = error;
          lastStackTrace = stackTrace;
          if (index + 1 < m3u8Videos.length) {
            await _clearM3u8FallbackArtifacts(
              chapterDirectory: chapterDirectory,
              outputFile: File(
                p.join(mangaMainDirectory.path, "$chapterName.mp4"),
              ),
            );
          }
        }
      }
      if (lastError != null) {
        Error.throwWithStackTrace(lastError, lastStackTrace!);
      }
      // An offline episode must never retain an ephemeral bridge URL from an
      // earlier attempt; only the verified local artifact is durable.
      await finalizeDownload();
    }
    if (callback != null) {
      callback();
    }
    keepAlive.close();
  } catch (e) {
    // Surface the failure instead of swallowing it — a silent catch here is
    // exactly how "downloads just don't start" stays invisible.
    if (!isDownloadCancelled(chapter)) botToast("Download failed: $e");
    await markDownloadFailed(chapter);
    if (callback != null) callback();
    keepAlive.close();
  } finally {
    if (acquired) DownloadGate.instance.release(sourceKey);
    unscheduleDownload(chapter.id);
    keepAlive.close();
  }
}

bool _isHttpUrl(String value) {
  final scheme = Uri.tryParse(value.trim())?.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https';
}

bool _isM3u8Url(String value) {
  final trimmed = value.trim().toLowerCase();
  final path = Uri.tryParse(trimmed)?.path.toLowerCase() ?? trimmed;
  return path.endsWith('.m3u8') ||
      path.endsWith('.m3u') ||
      path.endsWith('/m3u8') ||
      path.endsWith('/m3u') ||
      trimmed.contains('.m3u8?') ||
      trimmed.contains('.m3u?');
}

Future<void> _clearM3u8FallbackArtifacts({
  required Directory chapterDirectory,
  required File outputFile,
}) async {
  final tempDirectory = Directory(p.join(chapterDirectory.path, 'temp'));
  if (await tempDirectory.exists()) {
    await tempDirectory.delete(recursive: true);
  }
  if (await outputFile.exists()) {
    await outputFile.delete();
  }
}

@riverpod
Future<void> processDownloads(Ref ref, {bool? useWifi}) async {
  final keepAlive = ref.keepAlive();
  try {
    // Fire in the user's manual queue order (#514) so the initial slots go to
    // the highest-priority chapters; the gate then keeps honoring live reorders
    // as later slots free.
    final ongoingDownloads = DownloadQueueOrder.sorted(
      await downloadRepository.getPendingStarted(),
    );
    if (!ref.mounted) return;
    // Kick off every pending download. The shared _DownloadGate enforces the
    // concurrency limit, per-source serialization (#645), the start delay
    // (#621) and the manual order (#514), so they can all be fired at once and
    // will queue themselves instead of being paced here (which used to block on
    // the main isolate).
    for (final downloadItem in ongoingDownloads) {
      if (!downloadItem.chapter.isLoaded) {
        try {
          downloadItem.chapter.loadSync();
        } catch (_) {}
      }
      final chapter = downloadItem.chapter.value;
      if (chapter == null) continue;
      if (isDownloadScheduled(chapter.id)) continue;
      final provider = downloadChapterProvider(
        chapter: chapter,
        useWifi: useWifi,
      );
      ref.invalidate(provider);
      ref.read(provider);
    }
  } catch (error) {
    botToast('Could not start download queue: $error');
  } finally {
    keepAlive.close();
  }
}
