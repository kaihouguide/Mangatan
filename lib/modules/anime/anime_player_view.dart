import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:bot_toast/bot_toast.dart';
import 'package:ffi/ffi.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_qjs/quickjs/ffi.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riv;
import 'package:go_router/go_router.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/eval/model/m_bridge.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/repositories/chapter_repository.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/custom_button.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/models/video.dart' as vid;
import 'package:mangayomi/modules/anime/providers/anime_player_controller_provider.dart';
import 'package:mangayomi/modules/anime/providers/auto_play_next_provider.dart';
import 'package:mangayomi/modules/anime/utils/audio_track_fallback.dart';
import 'package:mangayomi/modules/anime/utils/audio_track_label.dart';
import 'package:mangayomi/modules/anime/utils/playback_error_report.dart';
import 'package:mangayomi/modules/anime/utils/player_lifecycle.dart';
import 'package:mangayomi/modules/anime/utils/playback_media.dart';
import 'package:mangayomi/modules/anime/utils/subtitle_track_support.dart';
import 'package:mangayomi/modules/anime/utils/video_stream_preference.dart';
import 'package:mangayomi/modules/anime/utils/video_track_from_video.dart';
import 'package:mangayomi/modules/anime/widgets/aniskip_countdown_btn.dart';
import 'package:mangayomi/modules/anime/widgets/chimahon_primary_controls.dart';
import 'package:mangayomi/modules/anime/widgets/desktop.dart';
import 'package:mangayomi/modules/anime/widgets/jimaku_subtitle_dialog.dart';
import 'package:mangayomi/modules/library/providers/local_archive.dart';
import 'package:mangayomi/modules/manga/reader/widgets/btn_chapter_list_dialog.dart';
import 'package:mangayomi/modules/anime/widgets/mobile.dart';
import 'package:mangayomi/modules/anime/widgets/subtitle_view.dart';
import 'package:mangayomi/modules/anime/widgets/subtitle_setting_widget.dart';
import 'package:mangayomi/modules/anime/widgets/subtitle_cue_list.dart';
import 'package:mangayomi/modules/anime/widgets/video_ocr_overlay.dart';
import 'package:mangayomi/modules/mining/widgets/dictionary_lookup_popup.dart';
import 'package:mangayomi/modules/manga/reader/providers/push_router.dart';
import 'package:mangayomi/modules/more/settings/player/providers/player_audio_state_provider.dart';
import 'package:mangayomi/modules/more/settings/player/providers/player_decoder_state_provider.dart';
import 'package:mangayomi/modules/more/settings/player/providers/player_state_provider.dart';
import 'package:mangayomi/modules/widgets/custom_draggable_tabbar.dart';
import 'package:mangayomi/modules/widgets/desktop_back_navigation_handler.dart';
import 'package:mangayomi/modules/widgets/error_state.dart';
import 'package:mangayomi/modules/widgets/progress_center.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/providers/storage_provider.dart';
import 'package:mangayomi/services/aniskip.dart';
import 'package:mangayomi/services/fetch_subtitles.dart';
import 'package:mangayomi/services/mining/anime_sentence_audio_service.dart';
import 'package:mangayomi/services/get_video_list.dart';
import 'package:mangayomi/services/mining/jimaku_service.dart';
import 'package:mangayomi/services/mining/dictionary_profile_resolver.dart';
import 'package:mangayomi/services/mining/desktop_scene_capture.dart';
import 'package:mangayomi/services/mining/mining_models.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';
import 'package:mangayomi/services/mining/scene_capture_timing.dart';
import 'package:mangayomi/services/torrent_server.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';
import 'package:mangayomi/utils/chapter_recognition.dart';
import 'package:mangayomi/utils/language.dart';
import 'package:mangayomi/utils/log/logger.dart';
import 'package:mangayomi/utils/platform_utils.dart';
import 'package:mangayomi/utils/share.dart';
import 'package:mangayomi/utils/system_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:media_kit_video/media_kit_video_controls/src/controls/extensions/duration.dart';
import 'package:numberpicker/numberpicker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:window_manager/window_manager.dart' show windowManager;

import 'widgets/search_subtitles.dart';

import 'package:mangayomi/repositories/manga_repository.dart';

final Map<int, String> _sessionVideoStreamPreferences = {};

class AnimePlayerView extends riv.ConsumerStatefulWidget {
  final int episodeId;
  const AnimePlayerView({super.key, required this.episodeId});

  @override
  riv.ConsumerState<AnimePlayerView> createState() => _AnimePlayerViewState();
}

class _AnimePlayerViewState extends riv.ConsumerState<AnimePlayerView> {
  late final Chapter episode = chapterRepository.getById(widget.episodeId);
  List<String> _infoHashList = [];
  bool desktopFullScreenPlayer = false;
  bool _episodeReplacementInProgress = false;
  @override
  void dispose() {
    if (shouldExitDesktopFullscreenOnDispose(
      isDesktop: isDesktop,
      isFullscreen: desktopFullScreenPlayer,
      isEpisodeReplacement: _episodeReplacementInProgress,
    )) {
      unawaited(setFullScreen(value: false));
    }
    for (var infoHash in _infoHashList) {
      MTorrentServer().removeTorrent(infoHash);
    }
    restoreSystemUI();
    super.dispose();
  }

  Widget _buildLoading() {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text(''),
        leading: IconButton(
          color: Colors.white,
          autofocus: isTv,
          icon: const BackButtonIcon(),
          onPressed: () {
            restoreSystemUI();
            Navigator.pop(context);
          },
        ),
      ),
      body: const ProgressCenter(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final defaultSubtitleLang = ref.watch(defaultSubtitleLangStateProvider);
    final serversData = ref.watch(getVideoListProvider(episode: episode));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    return serversData.when(
      data: (data) {
        final (videos, isLocal, infoHashList, mpvDirectory) = data;
        _infoHashList = infoHashList;
        if (videos.isEmpty && !(episode.manga.value!.isLocalArchive ?? false)) {
          return Scaffold(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            appBar: AppBar(
              title: const Text(''),
              leading: BackButton(
                onPressed: () {
                  Navigator.pop(context);
                },
              ),
            ),
            body: const Center(child: Text("Video list is empty")),
          );
        }

        return AnimeStreamPage(
          defaultSubtitle: completeLanguageNameEnglish(
            defaultSubtitleLang.toLanguageTag(),
          ),
          episode: episode,
          videos: videos,
          isLocal: isLocal,
          isTorrent: infoHashList.isNotEmpty,
          desktopFullScreenPlayer: (value) {
            desktopFullScreenPlayer = value;
          },
          onEpisodeReplacement: () {
            _episodeReplacementInProgress = true;
          },
          mpvDirectory: mpvDirectory,
        );
      },
      error: (error, stackTrace) {
        if (serversData.isRefreshing || serversData.isReloading) {
          return _buildLoading();
        }
        return Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          appBar: AppBar(
            title: const Text(''),
            leading: IconButton(
              autofocus: isTv,
              icon: const BackButtonIcon(),
              onPressed: () {
                restoreSystemUI();
                Navigator.pop(context);
              },
            ),
          ),
          body: ErrorState(
            autofocusRetry: false,
            detail: error.toString(),
            onRetry: () =>
                ref.invalidate(getVideoListProvider(episode: episode)),
          ),
        );
      },
      loading: _buildLoading,
    );
  }
}

class AnimeStreamPage extends riv.ConsumerStatefulWidget {
  final List<vid.Video> videos;
  final Chapter episode;
  final String defaultSubtitle;
  final bool isLocal;
  final bool isTorrent;
  final Directory? mpvDirectory;
  final void Function(bool) desktopFullScreenPlayer;
  final VoidCallback onEpisodeReplacement;
  const AnimeStreamPage({
    super.key,
    required this.defaultSubtitle,
    required this.isLocal,
    required this.videos,
    required this.episode,
    required this.isTorrent,
    required this.desktopFullScreenPlayer,
    required this.onEpisodeReplacement,
    required this.mpvDirectory,
  });

  @override
  riv.ConsumerState<AnimeStreamPage> createState() => _AnimeStreamPageState();
}

enum _AniSkipPhase { none, opening, ending }

/// When the user first opens a video (on Desktop).
/// Only used for fullscreen/windowed behavior.
bool _firstTime = true;

class _AnimeStreamPageState extends riv.ConsumerState<AnimeStreamPage>
    with
        _AlwaysOnTopStateMixin,
        TickerProviderStateMixin,
        WidgetsBindingObserver {
  bool _routeExitInProgress = false;
  bool _videoTextureVisible = true;
  bool _resumePlaybackAfterWindowsSuspend = false;
  ({double width, double height})? _linuxVideoViewport;
  ({int width, int height})? _linuxVideoOutputSize;
  bool _linuxVideoResizeScheduled = false;
  late final GlobalKey<VideoState> _key = GlobalKey<VideoState>();
  late final useLibass = ref.read(useLibassStateProvider);
  late final useMpvConfig = ref.read(useMpvConfigStateProvider);
  late final useGpuNext = ref.read(useGpuNextStateProvider);
  late final debandingType = ref.read(debandingStateProvider);
  late final useYUV420P = ref.read(useYUV420PStateProvider);
  late final audioPreferredLang = ref.read(audioPreferredLangStateProvider);
  late final enableAudioPitchCorrection = ref.read(
    enableAudioPitchCorrectionStateProvider,
  );
  late final audioChannel = ref.read(audioChannelStateProvider);
  late final volumeBoostCap = ref.read(volumeBoostCapStateProvider);
  late final Player _player = Player(
    configuration: PlayerConfiguration(
      libass: useLibass,
      config: true,
      configDir: useMpvConfig ? widget.mpvDirectory?.path ?? "" : "",
      options: {
        if (debandingType == DebandingType.cpu) "vf": "gradfun=radius=12",
        if (debandingType == DebandingType.gpu) "deband": "yes",
        if (useYUV420P) "vf": "format=yuv420p",
        if (audioPreferredLang.isNotEmpty) "alang": audioPreferredLang,
        if (enableAudioPitchCorrection) "audio-pitch-correction": "yes",
        "volume-max": "${volumeBoostCap + 100}",
        if (audioChannel != AudioChannel.reverseStereo)
          "audio-channels": audioChannel.mpvName,
        if (audioChannel == AudioChannel.reverseStereo)
          "af": audioChannel.mpvName,
        "sub-visibility": "no",
      },
      observeProperties: {
        "user-data/aniyomi/show_text": generated.mpv_format.MPV_FORMAT_NODE,
        "user-data/aniyomi/toggle_ui": generated.mpv_format.MPV_FORMAT_NODE,
        "user-data/aniyomi/show_panel": generated.mpv_format.MPV_FORMAT_NODE,
        "user-data/aniyomi/software_keyboard":
            generated.mpv_format.MPV_FORMAT_NODE,
        "user-data/aniyomi/set_button_title":
            generated.mpv_format.MPV_FORMAT_NODE,
        "user-data/aniyomi/reset_button_title":
            generated.mpv_format.MPV_FORMAT_NODE,
        "user-data/aniyomi/toggle_button": generated.mpv_format.MPV_FORMAT_NODE,
        "user-data/aniyomi/switch_episode":
            generated.mpv_format.MPV_FORMAT_NODE,
        "user-data/aniyomi/pause": generated.mpv_format.MPV_FORMAT_NODE,
        "user-data/aniyomi/seek_by": generated.mpv_format.MPV_FORMAT_NODE,
        "user-data/aniyomi/seek_to": generated.mpv_format.MPV_FORMAT_NODE,
        "user-data/aniyomi/seek_by_with_text":
            generated.mpv_format.MPV_FORMAT_NODE,
        "user-data/aniyomi/seek_to_with_text":
            generated.mpv_format.MPV_FORMAT_NODE,
        "user-data/aniyomi/launch_int_picker":
            generated.mpv_format.MPV_FORMAT_NODE,
        "user-data/mangayomi/chapter_titles":
            generated.mpv_format.MPV_FORMAT_NODE,
        "user-data/mangayomi/current_chapter":
            generated.mpv_format.MPV_FORMAT_INT64,
        "user-data/mangayomi/selected_shader":
            generated.mpv_format.MPV_FORMAT_NODE,
      },
      eventHandler: _handleMpvEvents,
    ),
  );
  late final hwdecMode = ref.read(hwdecModeStateProvider());
  late final enableHardwareAccel = ref.read(enableHardwareAccelStateProvider);
  late final VideoController _controller;
  late final _streamController = ref.read(
    animeStreamControllerProvider(episode: widget.episode).notifier,
  );
  final Stopwatch _watchStopwatch = Stopwatch();
  late vid.Video _firstVid = preferredVideoStream(
    widget.videos,
    _sessionVideoStreamPreferences[widget.episode.manga.value?.id] ?? '',
  );
  late final ValueNotifier<VideoPrefs?> _video = ValueNotifier(
    VideoPrefs(
      videoTrack: videoTrackFromVideo(_firstVid),
      headers: _firstVid.headers,
    ),
  );
  final ValueNotifier<double> _playbackSpeed = ValueNotifier(1.0);
  final ValueNotifier<bool> _isDoubleSpeed = ValueNotifier(false);
  late final ValueNotifier<Duration> _currentPosition = ValueNotifier(
    _streamController.getCurrentPosition(),
  );
  final ValueNotifier<Duration?> _currentTotalDuration = ValueNotifier(null);
  final ValueNotifier<bool> _showFitLabel = ValueNotifier(false);
  final ValueNotifier<bool> _isCompleted = ValueNotifier(false);
  final ValueNotifier<Duration?> _tempPosition = ValueNotifier(null);
  final ValueNotifier<BoxFit> _fit = ValueNotifier(BoxFit.contain);
  final ValueNotifier<List<(String, int)>> _chapterMarks = ValueNotifier([]);
  final ValueNotifier<int?> _currentChapterMark = ValueNotifier(null);
  final ValueNotifier<String> _selectedShader = ValueNotifier("");
  final ValueNotifier<ActiveCustomButton?> _customButton = ValueNotifier(null);
  final ValueNotifier<List<CustomButton>?> _customButtons = ValueNotifier(null);
  Timer? _nativeSubtitlePaintTimer;
  late final ValueNotifier<_AniSkipPhase> _skipPhase = ValueNotifier(
    _AniSkipPhase.none,
  );
  Results? _openingResult;
  Results? _endingResult;
  bool _hasOpeningSkip = false;
  bool _hasEndingSkip = false;
  bool _initSubtitleAndAudio = true;
  bool _includeSubtitles = false;
  bool _bitmapSubtitleActive = false;
  bool _jimakuAutoLoadAttempted = false;
  bool _jimakuLoading = false;
  final List<SubtitleTrack> _jimakuSubtitleTracks = [];
  String? _activeJimakuSubtitlePath;
  bool _showSubtitleList = false;
  bool _videoOcrCapturing = false;
  bool _liveVideoOcrEnabled = false;
  Uint8List? _videoOcrBytes;
  Duration? _videoOcrPosition;
  final Set<int> _videoOcrGesturePointers = {};
  final Map<int, Offset> _videoOcrGestureStarts = {};
  DateTime? _videoOcrGestureStartedAt;
  bool _videoOcrGestureCandidate = false;
  List<AnimeSubtitleCue> _subtitleCues = const [];
  final Map<String, List<AnimeSubtitleCue>> _subtitleCuesByTitle = {};
  String _lastSubtitleHistoryText = '';
  int _nextSubtitleHistoryIndex = 0;
  int _subDelay = 0;
  final _subDelayController = TextEditingController(text: "0");
  double _subSpeed = 1;
  final _subSpeedController = TextEditingController(text: "1");
  int lastRpcTimestampUpdate = DateTime.now().millisecondsSinceEpoch;
  final AnkiExportJobController _sceneJobController = AnkiExportJobController();
  final Set<AnkiSceneCaptureHandle> _sceneCaptures = {};

  late final StreamSubscription<Duration> _currentPositionSub;
  late final StreamSubscription<List<String>> _subtitleTextSub;
  late final StreamSubscription<Track> _selectedTrackSub;
  late final StreamSubscription<String> _playerErrorSub;
  String? _lastPlayerError;
  DateTime? _lastPlayerErrorAt;
  final Set<String> _failedAudioTrackKeys = {};
  final Set<String> _failedAudioCodecs = {};
  String? _requestedAudioLanguage;
  bool _audioFallbackInProgress = false;
  bool _audioFallbackErrorQueued = false;

  late final StreamSubscription<Duration> _currentTotalDurationSub = _player
      .stream
      .duration
      .listen((duration) {
        _currentTotalDuration.value = duration;
        discordRpc?.updateChapterTimestamp(_currentPosition.value, duration);
      });

  bool get hasNextEpisode => _streamController.hasNextEpisode;

  late final StreamSubscription<bool> _completed = _player.stream.completed
      .listen(_handlePlaybackCompleted);

  Future<void> _handlePlaybackCompleted(bool completed) async {
    if (!completed || !mounted) return;

    _watchStopwatch.stop();
    final reportedDuration = _currentTotalDuration.value;
    final totalDuration =
        reportedDuration != null && reportedDuration > Duration.zero
        ? reportedDuration
        : _player.state.duration;
    try {
      await _streamController.completeEpisode(
        totalDuration,
        elapsedSeconds: _watchStopwatch.elapsed.inSeconds,
      );
    } catch (error) {
      // Failing to record history must not stop auto-play of the next episode.
      AppLogger.log(
        'Could not record the completed episode: $error',
        logLevel: LogLevel.warning,
      );
    }
    _watchStopwatch.reset();
    if (!mounted) return;

    final hasNext = hasNextEpisode;
    if (hasNext && ref.read(autoPlayNextEpisodeProvider)) {
      await pushToNewEpisode(context, _streamController.getNextEpisode());
      return;
    }

    // If the last episode of an Anime has ended, exit fullscreen mode.
    final isFullScreen = ref.read(fullscreenProvider);
    if (!hasNext && isDesktop && isFullScreen) {
      setFullScreen(value: false);
      ref.read(fullscreenProvider.notifier).state = false;
      widget.desktopFullScreenPlayer.call(false);
    }
  }

  Future<void> _handleMpvEvents(Pointer<generated.mpv_event> event) async {
    try {
      if (event.ref.event_id ==
          generated.mpv_event_id.MPV_EVENT_PROPERTY_CHANGE) {
        final prop = event.ref.data.cast<generated.mpv_event_property>();
        final propName = prop.ref.name.cast<Utf8>().toDartString();
        if (kDebugMode) {
          if (propName.startsWith("user-data/")) {
            print("DEBUG 00: $propName - ${prop.ref.format}");
          }
        }
        if (propName.startsWith("user-data/") &&
            prop.ref.format == generated.mpv_format.MPV_FORMAT_NODE) {
          final value = prop.ref.data.cast<generated.mpv_node>();
          _handleMpvNodeEvents(propName, value);
        } else if (propName.startsWith("user-data/") &&
            prop.ref.format == generated.mpv_format.MPV_FORMAT_INT64) {
          final value = prop.ref.data.cast<Int64>().value;
          _handleMpvNumberEvents(propName, value);
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint(e.toString());
      }
    }
  }

  String? _readMpvString(Pointer<generated.mpv_node> value) {
    if (value.ref.format != generated.mpv_format.MPV_FORMAT_STRING) return null;
    final text = value.ref.u.string.cast<Utf8>().toDartString();
    return text.isEmpty ? null : text;
  }

  Future<void> _seekTo(int absoluteSeconds) async {
    _tempPosition.value = Duration(seconds: absoluteSeconds);
    await _player.seek(Duration(seconds: absoluteSeconds));
    _tempPosition.value = null;
  }

  Future<void> _seekBy(int deltaSeconds) async {
    final pos = _currentPosition.value.inSeconds + deltaSeconds;
    await _seekTo(pos);
  }

  Future<void> _handleMpvNodeEvents(
    String propName,
    Pointer<generated.mpv_node> value,
  ) async {
    final nativePlayer = _player.platform as NativePlayer;
    switch (propName.substring(10)) {
      case "aniyomi/show_text":
        final text = _readMpvString(value);
        if (text == null) break;
        botToast(
          text,
          alignY: -0.99,
          second: 2,
          dismissDirections: const [
            DismissDirection.vertical,
            DismissDirection.horizontal,
          ],
          showIcon: false,
        );
        nativePlayer.setProperty("user-data/aniyomi/show_text", "");
        break;
      case "aniyomi/toggle_ui":
        final text = _readMpvString(value);
        if (text == null) break;
        switch (text) {
          // WIP
          case "show":
            break;
          case "hide":
            break;
          case "toggle":
            break;
        }
        nativePlayer.setProperty("user-data/aniyomi/toggle_ui", "");
        break;
      case "aniyomi/show_panel":
        final text = _readMpvString(value);
        if (text == null) break;
        switch (text) {
          // WIP
          case "subtitle_settings":
            break;
          case "subtitle_delay":
            break;
          case "audio_delay":
            break;
          case "video_filters":
            break;
        }
        nativePlayer.setProperty("user-data/aniyomi/show_panel", "");
        break;
      case "aniyomi/software_keyboard":
        final text = _readMpvString(value);
        if (text == null) break;
        switch (text) {
          // WIP
          case "show":
            break;
          case "hide":
            break;
          case "toggle":
            break;
        }
        nativePlayer.setProperty("user-data/aniyomi/software_keyboard", "");
        break;
      case "aniyomi/set_button_title":
        final text = _readMpvString(value);
        if (text == null) break;
        final temp = _customButton.value;
        if (temp == null) break;
        _customButton.value = temp..currentTitle = text;
        nativePlayer.setProperty("user-data/aniyomi/set_button_title", "");
        break;
      case "aniyomi/reset_button_title":
        final text = _readMpvString(value);
        if (text == null) break;
        final temp = _customButton.value;
        if (temp == null) break;
        _customButton.value = temp..currentTitle = temp.button.title ?? "";
        nativePlayer.setProperty("user-data/aniyomi/reset_button_title", "");
        break;
      case "aniyomi/toggle_button":
        final text = _readMpvString(value);
        if (text == null) break;
        final temp = _customButton.value;
        if (temp == null) break;
        switch (text) {
          case "show":
            _customButton.value = temp..visible = true;
            break;
          case "hide":
            _customButton.value = temp..visible = false;
            break;
          case "toggle":
            _customButton.value = temp..visible = !temp.visible;
            break;
        }
        nativePlayer.setProperty("user-data/aniyomi/toggle_button", "");
        break;
      case "aniyomi/switch_episode":
        final text = _readMpvString(value);
        if (text == null) break;
        switch (text) {
          case "n":
            pushToNewEpisode(context, _streamController.getNextEpisode());
            break;
          case "p":
            pushToNewEpisode(context, _streamController.getPrevEpisode());
            break;
        }
        nativePlayer.setProperty("user-data/aniyomi/switch_episode", "");
        break;
      case "aniyomi/pause":
        final text = _readMpvString(value);
        if (text == null) break;
        switch (text) {
          case "pause":
            await _player.pause();
            break;
          case "unpause":
            await _player.play();
            break;
          case "pauseunpause":
            await _player.playOrPause();
            break;
        }
        nativePlayer.setProperty("user-data/aniyomi/pause", "");
        break;
      case "aniyomi/seek_by":
        final text = _readMpvString(value);
        if (text == null) break;
        final data = int.parse(text.replaceAll("\"", ""));
        await _seekBy(data);
        nativePlayer.setProperty("user-data/aniyomi/seek_by", "");
        break;
      case "aniyomi/seek_to":
        final text = _readMpvString(value);
        if (text == null) break;
        final data = int.parse(text.replaceAll("\"", ""));
        await _seekTo(data);
        nativePlayer.setProperty("user-data/aniyomi/seek_to", "");
        break;
      case "aniyomi/seek_by_with_text":
        final text = _readMpvString(value);
        if (text == null) break;
        final data = text.split("|");
        await _seekBy(int.parse(data[0].replaceAll("\"", "")));
        (_player.platform as NativePlayer).command(["show-text", data[1]]);
        nativePlayer.setProperty("user-data/aniyomi/seek_by_with_text", "");
        break;
      case "aniyomi/seek_to_with_text":
        final text = _readMpvString(value);
        if (text == null) break;
        final data = text.split("|");
        await _seekTo(int.parse(data[0].replaceAll("\"", "")));
        (_player.platform as NativePlayer).command(["show-text", data[1]]);
        nativePlayer.setProperty("user-data/aniyomi/seek_to_with_text", "");
        break;
      case "aniyomi/launch_int_picker":
        final text = _readMpvString(value);
        if (text == null) break;
        final data = text.split("|");
        final start = int.parse(data[2]);
        final stop = int.parse(data[3]);
        final step = int.parse(data[4]);
        int currentValue = start;
        await showDialog(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: Text(data[0]),
              content: StatefulBuilder(
                builder: (context, setState) => SizedBox(
                  height: 200,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      NumberPicker(
                        value: currentValue,
                        minValue: start,
                        maxValue: stop,
                        step: step,
                        haptics: true,
                        textMapper: (numberText) =>
                            data[1].replaceAll("%d", numberText),
                        onChanged: (value) =>
                            setState(() => currentValue = value),
                      ),
                    ],
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
                        context.l10n.cancel,
                        style: TextStyle(color: context.primaryColor),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final namePtr = data[5].toNativeUtf8();
                        final valuePtr = calloc<Int64>(1)..value = currentValue;
                        nativePlayer.mpv.mpv_set_property(
                          nativePlayer.ctx,
                          namePtr.cast(),
                          generated.mpv_format.MPV_FORMAT_INT64,
                          valuePtr.cast(),
                        );
                        malloc.free(namePtr);
                        malloc.free(valuePtr);
                        Navigator.pop(context);
                      },
                      child: Text(
                        context.l10n.ok,
                        style: TextStyle(color: context.primaryColor),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
        nativePlayer.setProperty("user-data/aniyomi/launch_int_picker", "");
        break;
      case "mangayomi/chapter_titles":
        if (value.ref.format == generated.mpv_format.MPV_FORMAT_STRING) {
          final text = value.ref.u.string.cast<Utf8>().toDartString();
          final data = jsonDecode(text) as List<dynamic>;
          _chapterMarks.value = data
              .map(
                (e) => (
                  e["title"] as String,
                  e["timestamp"] is double
                      ? (e["timestamp"] as double).toInt() * 1000
                      : (e["timestamp"] as int) * 1000,
                ),
              )
              .toList();
        }
        break;
      case "mangayomi/selected_shader":
        final text = _readMpvString(value);
        _selectedShader.value = text ?? '';
        break;
    }
  }

  Future<void> _handleMpvNumberEvents(String propName, int value) async {
    switch (propName.substring(10)) {
      case "mangayomi/current_chapter":
        _currentChapterMark.value = max(value, 0);
        break;
    }
  }

  Future<void> _initCustomButton() async {
    if (!useMpvConfig) return;
    final customButtons = isar.customButtons
        .filter()
        .idIsNotNull()
        .sortByPos()
        .findAllSync();
    if (customButtons.isEmpty) return;
    final primaryButton =
        customButtons.firstWhereOrNull((e) => e.isFavourite ?? false) ??
        customButtons.first;
    final provider = StorageProvider();
    if (!(await provider.requestPermission())) {
      return;
    }
    if (!mounted) return;
    final dir = await provider.getMpvDirectory();
    if (!mounted || dir == null) return;
    String scriptsDir = path.join(dir.path, 'scripts');
    final mpvFile = File('$scriptsDir/init_custom_buttons.lua');
    final content = StringBuffer();
    content.writeln("""local lua_modules = mp.find_config_file('scripts')
if lua_modules then
  package.path = package.path .. ';' .. lua_modules .. '/?.lua;' .. lua_modules .. '/?/init.lua;' .. '\${scriptsDir()!!.filePath}' .. '/?.lua'
end
local aniyomi = require 'init_aniyomi_functions'""");
    for (final button in customButtons) {
      content.writeln(
        """
${button.getButtonStartup(primaryButton.id!).trim()}
function button${button.id}()
  ${button.getButtonPress(primaryButton.id!).trim()}
end
mp.register_script_message('call_button_${button.id}', button${button.id})
function button${button.id}long()
  ${button.getButtonLongPress(primaryButton.id!).trim()}
end
mp.register_script_message('call_button_${button.id}_long', button${button.id}long)""",
      );
    }
    await mpvFile.writeAsString(content.toString());
    if (!mounted) return;
    try {
      await (_player.platform as NativePlayer).command([
        "load-script",
        mpvFile.path,
      ]);
    } catch (error, stackTrace) {
      if (!mounted) return;
      _reportPlaybackError(error.toString(), stackTrace: stackTrace);
      return;
    }
    if (!mounted) return;
    _customButton.value = ActiveCustomButton(
      currentTitle: primaryButton.title!,
      visible: true,
      button: primaryButton,
      onPress: () => (_player.platform as NativePlayer).command([
        "script-message",
        "call_button_${primaryButton.id}",
      ]),
      onLongPress: () => (_player.platform as NativePlayer).command([
        "script-message",
        "call_button_${primaryButton.id}_long",
      ]),
    );
    _customButtons.value = customButtons;
  }

  Future<void> pushToNewEpisode(BuildContext context, Chapter episode) async {
    if (_routeExitInProgress) return;
    _routeExitInProgress = true;
    widget.desktopFullScreenPlayer.call(ref.read(fullscreenProvider));
    widget.onEpisodeReplacement();
    await _retireVideoTexture();
    if (context.mounted) {
      pushReplacementMangaReaderView(context: context, chapter: episode);
    }
  }

  Future<void> _retireVideoTexture() async {
    if (!_videoTextureVisible || !mounted) return;
    await retirePlaybackSurface(
      hideSurface: () {
        if (mounted) {
          setState(() => _videoTextureVisible = false);
        }
      },
      waitForFrame: () => WidgetsBinding.instance.endOfFrame,
    );
  }

  Future<void> _exitDesktopFullScreen() async {
    final isFullScreen = await setFullScreen(value: false);
    if (!mounted) return;
    ref.read(fullscreenProvider.notifier).state = isFullScreen;
    widget.desktopFullScreenPlayer.call(isFullScreen);
  }

  Future<void> _handleEscape() async {
    if (isDesktop && ref.read(fullscreenProvider)) {
      await _exitDesktopFullScreen();
      return;
    }
    await _goBackToDetail();
  }

  Future<void> _goBackToDetail() async {
    if (_routeExitInProgress) return;
    _routeExitInProgress = true;
    if (isDesktop && ref.read(fullscreenProvider)) {
      await _exitDesktopFullScreen();
    }
    restoreSystemUI();
    await _retireVideoTexture();
    if (!mounted) return;
    _firstTime = true;
    Navigator.pop(context);
  }

  void _unifiedPositionHandler(Duration position) {
    final currentSecs = position.inSeconds;
    _setCurrentAudSub(position, currentSecs);
    _setSkipPhase(currentSecs);
  }

  Future<void> _setSubtitleTrack(SubtitleTrack track) async {
    await _player.setSubtitleTrack(track);
    _activeJimakuSubtitlePath = _jimakuSubtitlePathFor(track);
    _activateSubtitleCuesForTrack(track);
    _syncNativeSubtitlePaintSoon();
  }

  String? _jimakuSubtitlePathFor(SubtitleTrack track) {
    for (final subtitle in _jimakuSubtitleTracks) {
      if (track.id == subtitle.id || track.title == subtitle.title) {
        return subtitle.id;
      }
    }
    return null;
  }

  void _activateSubtitleCuesForTrack(SubtitleTrack track) {
    List<AnimeSubtitleCue>? cues;
    for (final key in [track.title, track.language, track.id]) {
      if (key == null || key.trim().isEmpty) continue;
      cues ??= _subtitleCuesByTitle[key];
      cues ??= _subtitleCuesByTitle[path.basename(key)];
    }
    if (cues == null && track.uri) {
      final uri = Uri.tryParse(track.id);
      final filePath = uri?.scheme == 'file' ? uri!.toFilePath() : track.id;
      final file = File(filePath);
      if (file.existsSync()) {
        cues = parseAnimeSubtitleFile(file);
        _rememberSubtitleCues(track.title ?? path.basename(file.path), cues);
      }
    }
    if (!mounted) return;
    setState(() {
      _subtitleCues = cues ?? const [];
      _lastSubtitleHistoryText = '';
      _nextSubtitleHistoryIndex = _subtitleCues.length;
    });
  }

  void _rememberSubtitleCues(String title, List<AnimeSubtitleCue> cues) {
    if (title.trim().isEmpty || cues.isEmpty) return;
    _subtitleCuesByTitle[title] = cues;
    _subtitleCuesByTitle[path.basename(title)] = cues;
    _subtitleCuesByTitle['Jimaku $title'] = cues;
  }

  void _updateSubtitleHistory(List<String> lines) {
    if (_subtitleCues.isNotEmpty) return;
    final text = lines
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
    if (text.isEmpty) {
      _lastSubtitleHistoryText = '';
      return;
    }
    if (text == _lastSubtitleHistoryText) return;
    _lastSubtitleHistoryText = text;
    final cue = AnimeSubtitleCue(
      index: _nextSubtitleHistoryIndex++,
      text: text,
      start: _currentPosition.value,
      end: _currentPosition.value + const Duration(seconds: 5),
    );
    if (mounted) {
      setState(() {
        final updated = [..._subtitleCues, cue];
        _subtitleCues = updated.length > 500
            ? updated.sublist(updated.length - 500)
            : updated;
      });
    }
  }

  Future<void> _showVideoOcr() async {
    if (_videoOcrCapturing || _videoOcrBytes != null) return;
    setState(() {
      _videoOcrCapturing = true;
      _liveVideoOcrEnabled = false;
    });
    unawaited(MiningPreferences.setLiveVideoOcrEnabled(false));
    await _player.pause();
    try {
      final position = _currentPosition.value;
      final bitmapSubtitleActive = await _syncNativeSubtitlePaint();
      final bytes = await _player.screenshot(
        format: 'image/png',
        includeLibassSubtitles: _includeSubtitles || bitmapSubtitleActive,
      );
      if (!mounted) return;
      if (bytes == null || bytes.isEmpty) {
        botToast('Unable to capture the current video frame', second: 4);
        return;
      }
      setState(() {
        _videoOcrBytes = bytes;
        _videoOcrPosition = position;
      });
    } catch (error) {
      if (mounted) botToast('Video OCR capture failed: $error', second: 5);
    } finally {
      if (mounted) setState(() => _videoOcrCapturing = false);
    }
  }

  void _dismissVideoOcr() {
    DictionaryLookupPopup.dismissActive();
    final wasLiveOcrEnabled = _liveVideoOcrEnabled;
    setState(() {
      _videoOcrBytes = null;
      _videoOcrPosition = null;
      _liveVideoOcrEnabled = false;
    });
    if (wasLiveOcrEnabled) {
      unawaited(MiningPreferences.setLiveVideoOcrEnabled(false));
    }
  }

  Future<void> _handleVideoOcrShortcut() async {
    if (_videoOcrBytes != null) {
      _dismissVideoOcr();
      return;
    }
    await _showVideoOcr();
  }

  Future<void> _toggleLiveVideoOcr() async {
    final enabled = !_liveVideoOcrEnabled;
    DictionaryLookupPopup.dismissActive();
    setState(() {
      _liveVideoOcrEnabled = enabled;
      if (enabled) {
        _videoOcrBytes = null;
      }
    });
    await MiningPreferences.setLiveVideoOcrEnabled(enabled);
  }

  Future<VideoOcrFrame?> _captureLiveVideoOcrFrame() async {
    final position = _currentPosition.value;
    final bitmapSubtitleActive = await _syncNativeSubtitlePaint();
    final bytes = await _player.screenshot(
      format: 'image/png',
      includeLibassSubtitles: _includeSubtitles || bitmapSubtitleActive,
    );
    if (bytes == null || bytes.isEmpty) return null;
    return VideoOcrFrame(bytes: bytes, position: position);
  }

  void _syncNativeSubtitlePaintSoon() {
    unawaited(_syncNativeSubtitlePaint());
    _nativeSubtitlePaintTimer?.cancel();
    _nativeSubtitlePaintTimer = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(_syncNativeSubtitlePaint()),
    );
  }

  Future<bool> _syncNativeSubtitlePaint() async {
    try {
      final active = await updateNativeSubtitleVisibility(_player);
      _bitmapSubtitleActive = active;
      return active;
    } catch (_) {
      return _bitmapSubtitleActive;
    }
  }

  void _setCurrentAudSub(Duration position, int secs) {
    final totalSecs = _player.state.duration.inSeconds;
    _isCompleted.value = (totalSecs - secs) <= 10;
    _currentPosition.value = position;
    if (_initSubtitleAndAudio) {
      _initSubtitleAndAudio = false;
      unawaited(_initializeSubtitleAndAudio());
    }
  }

  Future<AudioTrack> _activeAudioTrack() async {
    final selectedAudio = _player.state.track.audio;
    if (selectedAudio.id != 'auto' && selectedAudio.id != 'no') {
      return selectedAudio;
    }

    final platform = _player.platform;
    if (platform is! NativePlayer) return selectedAudio;

    final aid = await _nativeAudioProperty(platform, 'aid');
    final explicitlySelected = _audioTrackForNativeId(aid);
    if (explicitlySelected != null) return explicitlySelected;

    final activeId = await _nativeAudioProperty(
      platform,
      'current-tracks/audio/id',
    );
    return _audioTrackForNativeId(activeId) ?? selectedAudio;
  }

  Future<bool> _shouldPreserveAudioSelection() async {
    final selectedAudio = _player.state.track.audio;
    if (selectedAudio.id != 'auto') return true;

    final platform = _player.platform;
    if (platform is! NativePlayer) return false;
    final aid = await _nativeAudioProperty(platform, 'aid');
    if (aid != null && aid != 'auto' && aid != '-1') return true;

    final preferredLanguage =
        _preferredAudioLanguage() ?? await _nativePreferredAudioLanguage();
    if (preferredLanguage == null) return false;

    final activeAudio = await _activeAudioTrack();
    return activeAudio.id != 'auto' &&
        activeAudio.id != 'no' &&
        audioTrackLanguagesMatch(activeAudio.language, preferredLanguage);
  }

  Future<String?> _nativeAudioProperty(
    NativePlayer platform,
    String property,
  ) async {
    try {
      final value = (await platform.getProperty(property)).trim();
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _nativePreferredAudioLanguage() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return null;

    final alang = await _nativeAudioProperty(platform, 'alang');
    for (final language in alang?.split(',') ?? const <String>[]) {
      final value = language.trim();
      if (value.isNotEmpty && value != 'auto') return value;
    }
    return null;
  }

  AudioTrack? _audioTrackForNativeId(String? id) {
    if (id == null || id == 'auto' || id == 'no' || id == '-1') return null;
    for (final track in _player.state.tracks.audio) {
      if (track.id == id) return track;
    }
    // Keep an unknown concrete native selection from being mistaken for auto
    // while the track list is still being populated.
    return AudioTrack(id, null, null);
  }

  bool _isVideoDecoderError(String? codec, AudioTrack activeAudio) {
    final normalized = codec?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) return false;
    if (activeAudio.codec?.trim().toLowerCase() == normalized) return false;

    final hasAudioCodec = _player.state.tracks.audio.any(
      (track) => track.codec?.trim().toLowerCase() == normalized,
    );
    final hasVideoCodec = _player.state.tracks.video.any(
      (track) => track.codec?.trim().toLowerCase() == normalized,
    );
    return hasVideoCodec && !hasAudioCodec;
  }

  Future<void> _initializeSubtitleAndAudio() async {
    final restoredJimaku = await _restoreJimakuSubtitles();
    if (!restoredJimaku && (_firstVid.subtitles?.isNotEmpty ?? false)) {
      try {
        final defaultTrack = _firstVid.subtitles!.firstWhere(
          (sub) => (sub.label ?? sub.language) == widget.defaultSubtitle,
          orElse: () => _firstVid.subtitles!.first,
        );
        final file = defaultTrack.file ?? "";
        final label = defaultTrack.label;
        final language = defaultTrack.language ?? label;
        final track = (file.startsWith("http") || file.startsWith("file"))
            ? SubtitleTrack.uri(file, title: label, language: language)
            : SubtitleTrack.data(file, title: label, language: language);
        await _setSubtitleTrack(track);
      } catch (_) {}
    }
    if (_firstVid.audios?.isNotEmpty ?? false) {
      try {
        final preferredLanguage =
            _preferredAudioLanguage() ?? await _nativePreferredAudioLanguage();
        if (!await _shouldPreserveAudioSelection()) {
          final at = _firstVid.audios!.firstWhere(
            (sourceTrack) => audioTrackLanguagesMatch(
              sourceTrack.language ?? sourceTrack.label,
              preferredLanguage,
            ),
            orElse: () => _firstVid.audios!.first,
          );
          await _setAudioTrack(
            AudioTrack.uri(
              at.file ?? "",
              title: at.label,
              language: at.language ?? at.label,
            ),
          );
        }
      } catch (_) {}
    }
    await _autoLoadJimakuSubtitle();
  }

  void _setSkipPhase(int secs) {
    _AniSkipPhase newPhase;
    if (_hasOpeningSkip &&
        secs >= _openingResult!.interval!.startTime!.ceil() &&
        secs < _openingResult!.interval!.endTime!.toInt()) {
      newPhase = _AniSkipPhase.opening;
    } else if (_hasEndingSkip &&
        secs >= _endingResult!.interval!.startTime!.ceil() &&
        secs < _endingResult!.interval!.endTime!.toInt()) {
      newPhase = _AniSkipPhase.ending;
    } else {
      newPhase = _AniSkipPhase.none;
    }
    if (_skipPhase.value != newPhase) _skipPhase.value = newPhase;
  }

  Future<MiningContext> _subtitleMiningContext(
    String subtitleText, {
    Uint8List? frozenImageBytes,
    Duration? frozenPosition,
    bool ocrTiming = false,
  }) async {
    final manga = widget.episode.manga.value;
    final source = manga?.sourceId == null
        ? null
        : isar.sources.getSync(manga!.sourceId!);
    final capturePosition = frozenPosition ?? _currentPosition.value;
    final imageBytes =
        frozenImageBytes ??
        await _player.screenshot(
          format: 'image/png',
          includeLibassSubtitles: _includeSubtitles,
        );
    final capture = imageBytes == null || imageBytes.isEmpty
        ? null
        : await _createSceneCapture(
            subtitleText: subtitleText,
            frozenImageBytes: imageBytes,
            frozenPosition: capturePosition,
            ocrTiming: ocrTiming,
          );
    final video = _video.value;
    final fallbackSource = video?.videoTrack?.id ?? _firstVid.url;
    final audioTiming = capture == null
        ? subtitleAudioTimingForCue(
            currentPosition: capturePosition,
            subtitleDelay: Duration(milliseconds: _subDelay),
          )
        : SubtitleAudioTiming(start: capture.audioStart, end: capture.audioEnd);
    final audioSource = capture?.playerSource ?? fallbackSource;
    final activeAudio = _player.state.track.audio;
    final selectedAudioSource = activeAudio.uri && activeAudio.id != 'no'
        ? activeAudio.id
        : audioSource;
    final headers = video?.headers == null
        ? const <String, String>{}
        : Map<String, String>.unmodifiable(video!.headers!);
    final position = capture?.position ?? capturePosition;
    return MiningContext(
      mediaType: MiningMediaType.anime,
      mangaId: manga?.id,
      sourceId: DictionaryProfileResolver.overrideIdForSource(source),
      sourceLanguage: DictionaryProfileResolver.sourceLanguageForSource(
        source,
        fallback: manga?.lang ?? '',
      ),
      sourceTitle: manga?.name ?? '',
      chapterTitle: widget.episode.name ?? '',
      sentence: subtitleText,
      position: position,
      sourceUri: Uri.tryParse(_firstVid.originalUrl),
      imageBytesLoader: imageBytes == null
          ? null
          : () async => Uint8List.fromList(imageBytes),
      sentenceAudioLoader: selectedAudioSource.trim().isEmpty
          ? null
          : (format) => AnimeSentenceAudioService().capture(
              source: selectedAudioSource,
              headers: headers,
              timing: audioTiming,
              format: format,
              sourceTitle: widget.episode.manga.value?.name ?? '',
              chapterTitle: widget.episode.name ?? '',
              audioStreamIndex:
                  capture != null && selectedAudioSource == capture.playerSource
                  ? capture.audioStreamIndex
                  : null,
            ),
      sceneCapture: capture,
    );
  }

  Future<AnkiSceneCaptureHandle> _createSceneCapture({
    required String subtitleText,
    required Uint8List frozenImageBytes,
    Duration? frozenPosition,
    required bool ocrTiming,
  }) async {
    final native = _player.platform;
    Future<String?> property(String name) async {
      if (native is! NativePlayer) return null;
      try {
        final value = await native.getProperty(name);
        return value.trim().isEmpty ? null : value.trim();
      } catch (_) {
        return null;
      }
    }

    final values = await Future.wait([
      property('path'),
      property('time-pos'),
      property('duration'),
      property('sub-start/full'),
      property('sub-end/full'),
      property('seekable'),
      property('current-tracks/video/ff-index'),
      property('current-tracks/audio/ff-index'),
    ]);
    final video = _video.value;
    final selectedSource = video?.videoTrack?.id ?? _firstVid.url;
    final liveSource = values[0];
    final source = liveSource ?? selectedSource.trim();
    final position =
        frozenPosition ??
        _durationFromSeconds(values[1]) ??
        _currentPosition.value;
    final duration =
        _durationFromSeconds(values[2]) ??
        _currentTotalDuration.value ??
        _player.state.duration;
    final timing = ocrTiming
        ? resolveOcrSceneTiming(
            playbackPosition: position,
            mediaDuration: duration,
          )
        : resolveSubtitleSceneTiming(
            subtitleText: subtitleText,
            playbackPosition: position,
            mediaDuration: duration,
            liveSubtitleStart: _durationFromSeconds(values[3]),
            liveSubtitleEnd: _durationFromSeconds(values[4]),
            parsedCues: [
              for (final cue in _subtitleCues)
                ParsedSubtitleTiming(
                  text: cue.text,
                  start: cue.start,
                  end: cue.end,
                ),
            ],
            subtitleSpeed: _subSpeed,
            subtitleDelay: Duration(milliseconds: _subDelay),
          );
    final videoIndex = int.tryParse(values[6] ?? '');
    final audioIndex = int.tryParse(values[7] ?? '');
    final selectedVideoId = _player.state.track.video.id;
    final selectedAudioId = _player.state.track.audio.id;
    final headers = Map<String, String>.unmodifiable(
      video?.headers ?? const {},
    );
    late final AnkiSceneCaptureHandle handle;
    handle = AnkiSceneCaptureHandle(
      fallbackScreenshot: frozenImageBytes,
      playerSource: source,
      position: position,
      duration: duration,
      sceneStart: timing.scene.start,
      sceneEnd: timing.scene.end,
      audioStart: timing.audio.start,
      audioEnd: timing.audio.end,
      subtitleDelay: Duration(milliseconds: _subDelay),
      subtitleSpeed: _subSpeed,
      videoStreamIndex: videoIndex,
      audioStreamIndex: audioIndex,
      headers: headers,
      seekable: _booleanProperty(values[5], fallback: widget.isLocal),
      jobController: _sceneJobController,
      validatePlayerState: () async =>
          mounted &&
          _player.state.track.video.id == selectedVideoId &&
          _player.state.track.audio.id == selectedAudioId,
      prepareAnimatedScreenshot: (session) => const DesktopSceneCaptureService()
          .prepare(capture: handle, session: session),
      disposeCapture: () async {
        _sceneCaptures.remove(handle);
      },
    );
    _sceneCaptures.add(handle);
    return handle;
  }

  Future<void> _autoLoadJimakuSubtitle() async {
    if (_jimakuAutoLoadAttempted || _jimakuLoading) return;
    _jimakuAutoLoadAttempted = true;
    if (!await MiningPreferences.getAutoJimakuEnabled()) return;
    final apiKey = await MiningPreferences.getJimakuApiKey();
    if (apiKey.trim().isEmpty) return;
    await _loadJimakuSubtitle(apiKey: apiKey, showFeedback: false);
  }

  Future<void> _showJimakuSubtitleDialog({required bool resumePlayback}) async {
    final mediaId = widget.episode.manga.value?.id;
    var apiKey = await MiningPreferences.getJimakuApiKey();
    final apiKeyController = isDesktop
        ? null
        : TextEditingController(text: apiKey);
    final titleController = TextEditingController(
      text: await MiningPreferences.getJimakuTitleOverride(mediaId),
    );
    var playbackRestored = false;

    Future<void> restorePlayback() async {
      if (playbackRestored) return;
      playbackRestored = true;
      if (resumePlayback && mounted) await _player.play();
    }

    try {
      if (!mounted) return;
      while (true) {
        if (!mounted) return;
        final action = await showDialog<JimakuSubtitleDialogAction>(
          context: context,
          builder: (dialogContext) => JimakuSubtitleDialog(
            apiKeyConfigured: apiKey.trim().isNotEmpty,
            apiKeyController: apiKeyController,
            titleController: titleController,
            titleHint: widget.episode.manga.value?.name ?? '',
            cancelLabel: dialogContext.l10n.cancel,
          ),
        );
        if (!mounted || action == null) return;

        if (action == JimakuSubtitleDialogAction.openSettings) {
          await context.push('/playerSubtitles');
          if (!mounted) return;
          apiKey = await MiningPreferences.getJimakuApiKey();
          if (!mounted || apiKey.trim().isEmpty) return;
          continue;
        }

        final searchApiKey = apiKeyController?.text ?? apiKey;
        if (apiKeyController != null) {
          await MiningPreferences.setJimakuApiKey(searchApiKey);
        }
        await MiningPreferences.setJimakuTitleOverride(
          mediaId,
          titleController.text,
        );
        await restorePlayback();
        await _loadJimakuSubtitle(
          apiKey: searchApiKey,
          titleOverride: titleController.text,
          showFeedback: true,
        );
        return;
      }
    } finally {
      await restorePlayback();
      apiKeyController?.dispose();
      titleController.dispose();
    }
  }

  Future<void> _loadJimakuSubtitle({
    required String apiKey,
    String titleOverride = '',
    required bool showFeedback,
  }) async {
    if (_jimakuLoading) return;
    _jimakuLoading = true;
    final service = JimakuSubtitleService();
    try {
      final guess = await _currentJimakuGuess(titleOverride);
      if (guess.title.trim().isEmpty) {
        if (showFeedback) botToast('Set a Jimaku title first', second: 3);
        return;
      }
      if (showFeedback) {
        botToast('Searching Jimaku: ${guess.displayName}');
      }
      final entries = await service.searchEntries(
        apiKey: apiKey,
        query: guess.title,
      );
      if (entries.isEmpty) {
        if (showFeedback) {
          botToast('No Jimaku entries found for "${guess.title}"', second: 4);
        }
        return;
      }
      final entry =
          selectBestJimakuEntry(entries, guess.title) ?? entries.first;
      final files = await service.matchingFiles(
        apiKey: apiKey,
        entry: entry,
        guess: guess,
      );
      if (files.isEmpty) {
        final episodeText = guess.episode == null
            ? ''
            : ' episode ${guess.episode}';
        if (showFeedback) {
          botToast(
            'No matching SRT Jimaku subtitles found for '
            '${entry.name}$episodeText',
            second: 4,
          );
        }
        return;
      }
      final outputDir = Directory(
        path.join((await getTemporaryDirectory()).path, 'jimaku_subtitles'),
      );
      final subtitleFiles = await service.downloadFiles(
        apiKey: apiKey,
        files: files,
        outputDirectory: outputDir,
      );
      _jimakuSubtitleTracks
        ..clear()
        ..addAll([
          for (var index = 0; index < subtitleFiles.length; index++)
            SubtitleTrack.uri(
              subtitleFiles[index].path,
              title: files[index].name,
              language: 'ja',
            ),
        ]);
      for (var index = 0; index < subtitleFiles.length; index++) {
        final subtitleFile = subtitleFiles[index];
        final file = files[index];
        final cues = parseAnimeSubtitleFile(subtitleFile);
        _rememberSubtitleCues(file.name, cues);
      }
      await _attachJimakuSubtitles(_jimakuSubtitleTracks.first.id);
      if (showFeedback) {
        botToast(
          subtitleFiles.length == 1
              ? 'Jimaku subtitle added'
              : 'Added ${subtitleFiles.length} Jimaku subtitles',
          second: 3,
        );
      }
    } catch (e) {
      if (showFeedback) botToast('Jimaku failed: $e', second: 5);
    } finally {
      service.close();
      _jimakuLoading = false;
    }
  }

  Future<JimakuMediaGuess> _currentJimakuGuess(String titleOverride) async {
    final overrideTitle = titleOverride.trim().isNotEmpty
        ? titleOverride.trim()
        : await MiningPreferences.getJimakuTitleOverride(
            widget.episode.manga.value?.id,
          );
    final animeTitle = widget.episode.manga.value?.name ?? '';
    final episode = ChapterRecognition().parseEpisodeNumber(
      animeTitle,
      widget.episode.name ?? '',
    );
    return buildChimahonJimakuGuess(
      overrideTitle: overrideTitle,
      animeTitle: animeTitle,
      mediaTitle: widget.episode.name ?? '',
      videoTitle: _firstVid.quality,
      videoUrl: _firstVid.originalUrl,
      episodeNumber: episode > 0 ? episode : null,
    );
  }

  Future<bool> _restoreJimakuSubtitles() async {
    final activePath = _activeJimakuSubtitlePath;
    if (activePath == null ||
        !_jimakuSubtitleTracks.any((track) => track.id == activePath)) {
      return false;
    }
    try {
      await _attachJimakuSubtitles(activePath);
      return true;
    } catch (error) {
      // The temporary subtitle files can be gone; fall back to the source's
      // own subtitles instead of failing the quality change.
      AppLogger.log(
        'Could not restore Jimaku subtitles: $error',
        logLevel: LogLevel.warning,
      );
      return false;
    }
  }

  Future<void> _attachJimakuSubtitles(String selectedPath) async {
    final selected = _jimakuSubtitleTracks.firstWhere(
      (track) => track.id == selectedPath,
    );
    final platform = _player.platform;
    if (platform is NativePlayer) {
      for (final subtitle in _jimakuSubtitleTracks) {
        if (subtitle == selected) continue;
        await platform.command([
          'sub-add',
          subtitle.id,
          'auto',
          subtitle.title ?? path.basename(subtitle.id),
          subtitle.language ?? 'ja',
        ]);
      }
    }
    await _setSubtitleTrack(selected);
  }

  void _updateRpcTimestamp() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (lastRpcTimestampUpdate + 5000 < now) {
      if (_currentTotalDuration.value != null) {
        discordRpc?.updateChapterTimestamp(
          _currentPosition.value,
          _currentTotalDuration.value!,
        );
      }
      lastRpcTimestampUpdate = now;
    }
  }

  void _onSubDelayChanged() {
    final nativePlayer = (_player.platform as NativePlayer);
    final delayMs = int.tryParse(_subDelayController.text);
    if (delayMs != null) {
      final namePtr = "sub-delay".toNativeUtf8();
      final valuePtr = calloc<Double>(1)..value = delayMs / 1000;
      nativePlayer.mpv.mpv_set_property(
        nativePlayer.ctx,
        namePtr.cast(),
        generated.mpv_format.MPV_FORMAT_DOUBLE,
        valuePtr.cast(),
      );
      malloc.free(namePtr);
      malloc.free(valuePtr);
      _subDelay = delayMs;
      unawaited(
        MiningPreferences.setSubtitleDelay(
          widget.episode.manga.value?.id,
          delayMs,
        ),
      );
    }
  }

  Future<void> _restoreEntrySubtitleDelay() async {
    final delay = await MiningPreferences.getSubtitleDelay(
      widget.episode.manga.value?.id,
    );
    if (!mounted) return;
    _subDelayController.value = TextEditingValue(text: '$delay');
  }

  Future<void> _restoreEntryVideoStreamPreference() async {
    final mediaId = widget.episode.manga.value?.id;
    final preference = mediaId == null
        ? ''
        : _sessionVideoStreamPreferences[mediaId] ??
              await MiningPreferences.getVideoStreamPreference(mediaId);
    if (!mounted || preference.isEmpty) return;
    final selected = preferredVideoStream(widget.videos, preference);
    _sessionVideoStreamPreferences[mediaId!] = preference;
    _firstVid = selected;
    _video.value = VideoPrefs(
      videoTrack: videoTrackFromVideo(selected),
      headers: selected.headers,
      isLocal: false,
    );
  }

  void _rememberVideoStreamPreference(String preference) {
    final mediaId = widget.episode.manga.value?.id;
    if (mediaId == null || preference.trim().isEmpty) return;
    _sessionVideoStreamPreferences[mediaId] = preference.trim();
    unawaited(MiningPreferences.setVideoStreamPreference(mediaId, preference));
  }

  Future<void> _snapSubtitleDelay({required bool next}) async {
    final platform = _player.platform;
    if (platform is NativePlayer) {
      try {
        await platform.command(['sub-step', next ? '1' : '-1']);
        final seconds = double.tryParse(
          await platform.getProperty('sub-delay'),
        );
        if (seconds != null) {
          _subDelayController.value = TextEditingValue(
            text: '${(seconds * 1000).round()}',
          );
          return;
        }
      } catch (_) {}
    }
    final delay = subtitleDelayForAdjacentCue(
      cues: _subtitleCues,
      playbackPosition: _currentPosition.value,
      currentDelayMs: _subDelay,
      next: next,
    );
    if (delay == null) return;
    _subDelayController.value = TextEditingValue(text: '$delay');
  }

  void _onSubSpeedChanged() {
    final nativePlayer = (_player.platform as NativePlayer);
    final speed = double.tryParse(_subSpeedController.text);
    if (speed != null) {
      final namePtr = "sub-speed".toNativeUtf8();
      final valuePtr = calloc<Double>(1)
        ..value = speed < 0.1
            ? 0.1
            : speed > 10
            ? 10
            : speed;
      nativePlayer.mpv.mpv_set_property(
        nativePlayer.ctx,
        namePtr.cast(),
        generated.mpv_format.MPV_FORMAT_DOUBLE,
        valuePtr.cast(),
      );
      malloc.free(namePtr);
      malloc.free(valuePtr);
      _subSpeed = speed;
    }
  }

  @override
  void initState() {
    super.initState();
    _watchStopwatch.start();
    _controller = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        hwdec: hwdecMode,
        enableHardwareAcceleration: shouldUseHardwareAcceleratedVideoOutput(
          userEnabled: enableHardwareAccel,
          isWindows: Platform.isWindows,
        ),
        vo: Platform.isAndroid
            ? useGpuNext
                  ? "gpu-next"
                  : "gpu"
            : "libmpv",
      ),
    );
    // If player is being launched the first time,
    // use global "Use Fullscreen" setting.
    // Else (if user already watches an episode and just changes it),
    // stay in the same mode, the user left it in.
    try {
      final defaultSkipIntroLength = ref.read(
        defaultSkipIntroLengthStateProvider,
      );
      (_player.platform as NativePlayer).setProperty(
        "user-data/current-anime/intro-length",
        "$defaultSkipIntroLength",
      );
    } catch (_) {}
    if (isDesktop) {
      if (_firstTime) {
        final globalFullscreen = ref.read(fullScreenPlayerStateProvider);
        // Delay fullscreen until after the first frame so the window is ready.
        // On Windows, calling setFullScreen before the widget tree is built
        // can silently fail, leaving the title bar visible.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          setFullScreen(value: globalFullscreen);
          ref.read(fullscreenProvider.notifier).state = globalFullscreen;
          widget.desktopFullScreenPlayer.call(globalFullscreen);
        });
        _firstTime = false;
      } else {
        // Episode replacement keeps the process-wide fullscreen provider and
        // native window mode. Mirror it into the new outer route so a later
        // disposal still knows the real window state.
        widget.desktopFullScreenPlayer.call(ref.read(fullscreenProvider));
      }
    }
    if (!isDesktop) {
      final forceLandscape = ref.read(forceLandscapePlayerStateProvider);
      // Playing the next episode pushes a fresh player, and the old one's
      // dispose() resets the orientation to portrait. A viewer still in
      // fullscreen (fullscreenProvider is global) must stay in landscape.
      if (forceLandscape || ref.read(fullscreenProvider)) {
        _setLandscapeMode(true);
      }
    }
    _currentPositionSub = _player.stream.position.listen(
      _unifiedPositionHandler,
    );
    _subtitleTextSub = _player.stream.subtitle.listen(_updateSubtitleHistory);
    _selectedTrackSub = _player.stream.track.listen((_) {
      _syncNativeSubtitlePaintSoon();
    });
    _playerErrorSub = _player.stream.error.listen(_reportPlaybackError);
    _completed;
    _currentTotalDurationSub;
    unawaited(_initializePlayback());
    unawaited(_initCustomButton());
    discordRpc?.showChapterDetails(ref, widget.episode);
    _currentPosition.addListener(_updateRpcTimestamp);
    _subDelayController.addListener(_onSubDelayChanged);
    _subSpeedController.addListener(_onSubSpeedChanged);
    unawaited(
      MiningPreferences.getLiveVideoOcrEnabled().then((enabled) {
        if (!mounted) return;
        setState(() => _liveVideoOcrEnabled = enabled);
      }),
    );
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _initializePlayback() async {
    try {
      await _loadAndroidFont();
      if (!mounted) return;
      await _restoreEntryVideoStreamPreference();
      if (!mounted) return;
      await _openMedia(_video.value!, _streamController.getCurrentPosition());
      if (!mounted) return;
      await _restoreEntrySubtitleDelay();
      if (!mounted) return;
      if (widget.isTorrent) {
        unawaited(
          Future.delayed(const Duration(seconds: 10)).then((_) async {
            if (mounted) {
              await _openMedia(
                _video.value!,
                _streamController.getCurrentPosition(),
              );
              if (!mounted) return;
              await _restoreEntrySubtitleDelay();
            }
          }),
        );
      }
      await _setPlaybackSpeed(ref.read(defaultPlayBackSpeedStateProvider));
      if (!mounted) return;
      if (ref.read(enableAniSkipStateProvider)) await _initAniSkip();
    } catch (error, stackTrace) {
      if (!mounted) return;
      _reportPlaybackError(error.toString(), stackTrace: stackTrace);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (Platform.isWindows) {
      if (shouldSuspendWindowsPlaybackSurface(state)) {
        _resumePlaybackAfterWindowsSuspend =
            _resumePlaybackAfterWindowsSuspend || _player.state.playing;
        _setWindowsVideoSurfaceVisible(false);
      } else if (shouldResumeWindowsPlaybackSurface(state)) {
        _setWindowsVideoSurfaceVisible(true);
        if (_resumePlaybackAfterWindowsSuspend) {
          _resumePlaybackAfterWindowsSuspend = false;
          unawaited(
            WidgetsBinding.instance.endOfFrame.then((_) {
              if (mounted && _videoTextureVisible) return _player.play();
            }),
          );
        }
      }
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _watchStopwatch.stop();
      _setCurrentPosition(true);
    } else if (state == AppLifecycleState.resumed) {
      _watchStopwatch.start();
    }
  }

  void _setWindowsVideoSurfaceVisible(bool visible) {
    if (!mounted || _routeExitInProgress || _videoTextureVisible == visible) {
      return;
    }
    setState(() => _videoTextureVisible = visible);
  }

  Future<void> _openMedia(VideoPrefs prefs, [Duration? position]) async {
    final start = position ?? _currentPosition.value;
    _resetAudioFallbackState(resetRequestedLanguage: true);
    try {
      await _player.open(
        playbackMedia(
          prefs.videoTrack!.id,
          isLocal: widget.isLocal,
          httpHeaders: prefs.headers,
          start: start,
        ),
      );
      _scheduleLinuxVideoOutputResize();
      if (start > Duration.zero) {
        // Media(start:) is unreliable for some sources. Seek again once the
        // stream reports a duration; a redundant seek is harmless.
        unawaited(
          _player.stream.duration
              .firstWhere((duration) => duration > Duration.zero)
              .timeout(const Duration(seconds: 8))
              .then((_) => mounted ? _player.seek(start) : null)
              .catchError((_) {}),
        );
      }
    } catch (error, stackTrace) {
      _reportPlaybackError(error.toString(), stackTrace: stackTrace);
    }
  }

  Future<void> _setAudioTrack(AudioTrack track) async {
    _resetAudioFallbackState();
    _requestedAudioLanguage = track.language ?? _preferredAudioLanguage();
    await _player.setAudioTrack(track);
  }

  String? _preferredAudioLanguage() {
    for (final language in audioPreferredLang.split(',')) {
      final value = language.trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  List<AudioTrack> _audioTracksForFallback() {
    final tracks = _player.state.tracks.audio.toList();
    for (final sourceTrack in _firstVid.audios ?? const <vid.Track>[]) {
      final file = sourceTrack.file;
      if (file == null || file.isEmpty) continue;
      tracks.add(
        AudioTrack.uri(
          file,
          title: sourceTrack.label,
          language: sourceTrack.language ?? sourceTrack.label,
        ),
      );
    }
    return tracks;
  }

  void _resetAudioFallbackState({bool resetRequestedLanguage = false}) {
    _failedAudioTrackKeys.clear();
    _failedAudioCodecs.clear();
    _audioFallbackErrorQueued = false;
    if (resetRequestedLanguage) _requestedAudioLanguage = null;
  }

  void _reportPlaybackError(String error, {StackTrace? stackTrace}) {
    final message = error.trim();
    if (message.isEmpty) return;

    if (isAudioDecoderInitializationError(message)) {
      if (_audioFallbackInProgress) {
        _audioFallbackErrorQueued = true;
        return;
      }
      unawaited(_recoverFromAudioDecoderError(message, stackTrace: stackTrace));
      return;
    }

    _surfacePlaybackError(message, stackTrace: stackTrace);
  }

  Future<void> _recoverFromAudioDecoderError(
    String message, {
    StackTrace? stackTrace,
  }) async {
    _audioFallbackInProgress = true;
    try {
      final failedTrack = await _activeAudioTrack();
      final failedCodec = audioDecoderCodecFromError(message);
      if (_isVideoDecoderError(failedCodec, failedTrack)) {
        _surfacePlaybackError(message, stackTrace: stackTrace);
        return;
      }

      _failedAudioTrackKeys.add(audioTrackFallbackKey(failedTrack));
      if (failedCodec != null) {
        _failedAudioCodecs.add(failedCodec.toLowerCase());
      }

      final requestedLanguage =
          failedTrack.language ??
          _requestedAudioLanguage ??
          _preferredAudioLanguage() ??
          await _nativePreferredAudioLanguage();
      final candidates = audioTrackFallbackCandidates(
        failedTrack: failedTrack,
        availableTracks: _audioTracksForFallback(),
        requestedLanguage: requestedLanguage,
        failedTrackKeys: _failedAudioTrackKeys,
        failedCodecs: _failedAudioCodecs,
      );
      final fallback = candidates.isEmpty ? null : candidates.first;

      if (fallback == null) {
        _surfacePlaybackError(message, stackTrace: stackTrace);
        return;
      }

      _requestedAudioLanguage = requestedLanguage;
      AppLogger.log(
        'Audio decoder failed for ${audioTrackLabel(failedTrack)}; '
        'trying ${audioTrackLabel(fallback)}.',
        logLevel: LogLevel.warning,
      );
      try {
        await _player.setAudioTrack(fallback);
      } catch (error, fallbackStackTrace) {
        _surfacePlaybackError(
          '$message\nAudio fallback failed: $error',
          stackTrace: fallbackStackTrace,
        );
      }
    } finally {
      _audioFallbackInProgress = false;
      if (_audioFallbackErrorQueued) {
        _audioFallbackErrorQueued = false;
        unawaited(
          _recoverFromAudioDecoderError(message, stackTrace: stackTrace),
        );
      }
    }
  }

  void _surfacePlaybackError(String message, {StackTrace? stackTrace}) {
    AppLogger.log(
      'Video playback error: $message'
      '${stackTrace == null ? '' : '\n$stackTrace'}',
      logLevel: LogLevel.error,
    );

    final now = DateTime.now();
    final shouldReport = shouldReportPlaybackError(
      message: message,
      lastMessage: _lastPlayerError,
      lastReportedAt: _lastPlayerErrorAt,
      now: now,
    );
    _lastPlayerError = message;
    _lastPlayerErrorAt = now;
    if (!mounted || !shouldReport) return;

    BotToast.showText(
      text: 'Playback error: ${formatPlaybackErrorToast(message)}',
      onlyOne: true,
      align: const Alignment(0, 0.90),
      duration: const Duration(seconds: 5),
    );
  }

  Future<void> _loadAndroidFont() async {
    if (Platform.isAndroid && useLibass) {
      try {
        final subDir = await getApplicationDocumentsDirectory();
        final fontPath = path.join(subDir.path, 'subfont.ttf');
        final data = await rootBundle.load('assets/fonts/subfont.ttf');
        final bytes = data.buffer.asInt8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        final fontFile = await File(fontPath).create(recursive: true);
        await fontFile.writeAsBytes(bytes);
        await (_player.platform as NativePlayer).setProperty(
          'sub-fonts-dir',
          subDir.path,
        );
        await (_player.platform as NativePlayer).setProperty(
          'sub-font',
          'Droid Sans Fallback',
        );
      } catch (_) {}
    }
  }

  Future<void> _initAniSkip() async {
    try {
      await _player.stream.buffer.first;
    } catch (_) {
      if (!mounted) return;
      rethrow;
    }
    if (!mounted) return;
    _streamController.getAniSkipResults((result) {
      final openingRes = result
          .where((element) => element.skipType == "op")
          .toList();
      _hasOpeningSkip = openingRes.isNotEmpty;
      if (_hasOpeningSkip) _openingResult = openingRes.first;
      final endingRes = result
          .where((element) => element.skipType == "ed")
          .toList();
      _hasEndingSkip = endingRes.isNotEmpty;
      if (_hasEndingSkip) _endingResult = endingRes.first;
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _watchStopwatch.stop();
    _currentPosition.removeListener(_updateRpcTimestamp);
    _subDelayController.removeListener(_onSubDelayChanged);
    _subSpeedController.removeListener(_onSubSpeedChanged);
    _nativeSubtitlePaintTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _setCurrentPosition(true, saveWatchTime: true);
    final playerCleanup = disposePlaybackSession(
      listenerCancellations: [
        _completed.cancel(),
        _currentPositionSub.cancel(),
        _subtitleTextSub.cancel(),
        _selectedTrackSub.cancel(),
        _playerErrorSub.cancel(),
        _currentTotalDurationSub.cancel(),
      ],
      // The Video widget is normally retired before route navigation. Keep a
      // final Windows-only grace period for non-navigation disposal paths so
      // Flutter's raster thread cannot race media_kit texture destruction.
      beforeDisposePlayer: Platform.isWindows
          ? () => Future<void>.delayed(const Duration(milliseconds: 250))
          : null,
      disposePlayer: _player.dispose,
    );
    unawaited(
      playerCleanup.catchError((Object error, StackTrace stackTrace) {
        AppLogger.log(
          'Failed to dispose video player: $error\n$stackTrace',
          logLevel: LogLevel.error,
        );
      }),
    );
    _currentPosition.dispose();
    _currentTotalDuration.dispose();
    _video.dispose();
    _playbackSpeed.dispose();
    _isDoubleSpeed.dispose();
    _showFitLabel.dispose();
    _isCompleted.dispose();
    _tempPosition.dispose();
    _fit.dispose();
    _skipPhase.dispose();
    _subDelayController.dispose();
    _subSpeedController.dispose();
    if (!isDesktop) _setLandscapeMode(false);
    discordRpc?.showIdleText();
    discordRpc?.showOriginalTimestamp();
    _streamController.keepAliveLink?.close();
    for (final capture in _sceneCaptures.toList(growable: false)) {
      unawaited(capture.dispose());
    }
    _sceneCaptures.clear();
    unawaited(_sceneJobController.dispose());
    super.dispose();
  }

  void _setCurrentPosition(bool save, {bool saveWatchTime = false}) {
    unawaited(
      _streamController.setCurrentPosition(
        _currentPosition.value,
        _currentTotalDuration.value,
        save: save,
      ),
    );
    unawaited(
      _streamController.setHistoryUpdate(
        elapsedSeconds: saveWatchTime ? _watchStopwatch.elapsed.inSeconds : 0,
      ),
    );
  }

  void _setLandscapeMode(bool state) {
    if (state) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  Widget textWidget(String text, bool selected) => Row(
    children: [
      Flexible(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: MediaQuery.of(context).padding.top,
          ),
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyLarge!.copyWith(
              fontSize: 16,
              fontStyle: selected ? FontStyle.italic : null,
              color: selected ? context.primaryColor : null,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    ],
  );

  Widget _videoQualityWidget(BuildContext context) {
    List<VideoPrefs> videoQuality = _player.state.tracks.video
        .where(
          (element) => element.w != null && element.h != null && widget.isLocal,
        )
        .toList()
        .map((e) => VideoPrefs(videoTrack: e, isLocal: true))
        .toList();

    if (widget.videos.isNotEmpty && !widget.isLocal) {
      for (var video in widget.videos) {
        videoQuality.add(
          VideoPrefs(
            videoTrack: videoTrackFromVideo(video),
            headers: video.headers,
            isLocal: false,
          ),
        );
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 12),
      child: Column(
        children: videoQuality.map((quality) {
          final selected =
              _video.value!.videoTrack!.title == quality.videoTrack!.title ||
              widget.isLocal;
          return GestureDetector(
            child: textWidget(
              widget.isLocal ? _firstVid.quality : quality.videoTrack!.title!,
              selected,
            ),
            onTap: () async {
              if (_video.value?.videoTrack?.id == quality.videoTrack?.id) {
                Navigator.pop(context);
                return;
              }
              _video.value = quality;
              final preference = quality.videoTrack?.title ?? '';
              _rememberVideoStreamPreference(preference);
              for (final video in widget.videos) {
                if (video.url == quality.videoTrack?.id) {
                  _firstVid = video;
                  break;
                }
              }
              await _player.stop();
              if (quality.isLocal && widget.isLocal) {
                await _player.setVideoTrack(quality.videoTrack!);
                _initSubtitleAndAudio = true;
              } else {
                _initSubtitleAndAudio = false;
                await _openMedia(quality);
                await _initializeSubtitleAndAudio();
              }
              if (!context.mounted) return;
              Navigator.pop(context);
            },
          );
        }).toList(),
      ),
    );
  }

  Future<void> _videoSettingDraggableMenu(
    BuildContext context, {
    int initialIndex = 0,
  }) async {
    final l10n = l10nLocalizations(context)!;
    bool hasSubtitleTrack = false;
    var openJimaku = false;
    final resumePlayback = _player.state.playing;
    await _player.pause();
    if (!context.mounted) return;
    await customDraggableTabBar(
      tabs: [
        Tab(text: l10n.video_quality),
        Tab(text: l10n.video_subtitle),
        Tab(text: l10n.video_audio),
      ],
      children: [
        _videoQualityWidget(context),
        _videoSubtitle(
          context,
          (value) => hasSubtitleTrack = value,
          onSearchJimaku: () => openJimaku = true,
        ),
        _videoAudios(context),
      ],
      context: context,
      vsync: this,
      fullWidth: true,
      initialIndex: initialIndex,
      moreWidget: IconButton(
        onPressed: () async {
          if (useLibass) {
            BotToast.showText(
              contentColor: Colors.white,
              textStyle: const TextStyle(color: Colors.black, fontSize: 20),
              onlyOne: true,
              align: const Alignment(0, 0.90),
              duration: const Duration(seconds: 2),
              text: context.l10n.libass_not_disable_message,
            );
          } else {
            await customDraggableTabBar(
              tabs: [
                Tab(text: l10n.font),
                Tab(text: l10n.color),
                const Tab(text: 'Filters'),
              ],
              children: [
                FontSettingWidget(hasSubtitleTrack: hasSubtitleTrack),
                ColorSettingWidget(hasSubtitleTrack: hasSubtitleTrack),
                const SubtitleFilterSettingWidget(),
              ],
              context: context,
              vsync: this,
              fullWidth: true,
            );
            if (context.mounted) {
              Navigator.pop(context);
            }
          }
        },
        icon: const Icon(Icons.settings_outlined),
      ),
    );
    if (!mounted) return;
    setState(() {});
    if (openJimaku) {
      await _showJimakuSubtitleDialog(resumePlayback: resumePlayback);
    } else if (resumePlayback) {
      await _player.play();
    }
  }

  Widget _videoSubtitle(
    BuildContext context,
    Function(bool) hasSubtitleTrack, {
    required VoidCallback onSearchJimaku,
  }) {
    List<VideoPrefs> videoSubtitle = _player.state.tracks.subtitle
        .toList()
        .map((e) => VideoPrefs(isLocal: true, subtitle: e))
        .toList();

    List<String> subs = [];
    if (widget.videos.isNotEmpty) {
      for (var video in widget.videos) {
        for (var sub in video.subtitles ?? []) {
          if (!subs.contains(sub.file)) {
            final file = sub.file!;
            final label = sub.label;
            final language = sub.language ?? label;
            videoSubtitle.add(
              VideoPrefs(
                isLocal: widget.isLocal,
                subtitle: (file.startsWith("http") || file.startsWith("file"))
                    ? SubtitleTrack.uri(file, title: label, language: language)
                    : SubtitleTrack.data(
                        file,
                        title: label,
                        language: language,
                      ),
              ),
            );
            subs.add(sub.file!);
          }
        }
      }
    }
    final subtitle = _player.state.track.subtitle;
    videoSubtitle = videoSubtitle
        .map((e) {
          VideoPrefs vid = e;
          vid.title =
              vid.subtitle?.title ??
              vid.subtitle?.language ??
              vid.subtitle?.channels ??
              "";
          return vid;
        })
        .toList()
        .where((element) => element.title!.isNotEmpty)
        .toList();
    videoSubtitle.sort((a, b) => a.title!.compareTo(b.title!));
    hasSubtitleTrack.call(videoSubtitle.isNotEmpty);
    videoSubtitle.insert(
      0,
      VideoPrefs(isLocal: false, subtitle: SubtitleTrack.no()),
    );
    List<VideoPrefs> videoSubtitleLast = [];
    for (var element in videoSubtitle) {
      final contains = videoSubtitleLast.any((sub) {
        return (sub.title ??
                sub.subtitle?.title ??
                sub.subtitle?.language ??
                sub.subtitle?.channels ??
                "None") ==
            (element.title ??
                element.subtitle?.title ??
                element.subtitle?.language ??
                element.subtitle?.channels ??
                "None");
      });
      if (!contains) {
        videoSubtitleLast.add(element);
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 12),
      child: Column(
        children: [
          Row(
            children: [
              Text(context.l10n.subtitle_delay_text),
              IconButton(
                onPressed: () {
                  _subDelay = 0;
                  _subDelayController.value = TextEditingValue(
                    text: "$_subDelay",
                  );
                  _subSpeed = 1;
                  _subSpeedController.value = TextEditingValue(
                    text: _subSpeed.toStringAsFixed(2),
                  );
                },
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              IconButton(
                tooltip: 'Snap delay to previous subtitle',
                onPressed:
                    _subtitleCues.isEmpty && _player.platform is! NativePlayer
                    ? null
                    : () => unawaited(_snapSubtitleDelay(next: false)),
                icon: const Icon(Icons.skip_previous_rounded),
              ),
              IconButton(
                onPressed: () {
                  _subDelay -= 50;
                  _subDelayController.value = TextEditingValue(
                    text: "$_subDelay",
                  );
                },
                icon: const Icon(Icons.remove_circle),
              ),
              Expanded(
                child: TextFormField(
                  controller: _subDelayController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    isDense: true,
                    label: Text(context.l10n.subtitle_delay),
                  ),
                ),
              ),
              IconButton(
                onPressed: () {
                  _subDelay += 50;
                  _subDelayController.value = TextEditingValue(
                    text: "$_subDelay",
                  );
                },
                icon: const Icon(Icons.add_circle),
              ),
              IconButton(
                tooltip: 'Snap delay to next subtitle',
                onPressed:
                    _subtitleCues.isEmpty && _player.platform is! NativePlayer
                    ? null
                    : () => unawaited(_snapSubtitleDelay(next: true)),
                icon: const Icon(Icons.skip_next_rounded),
              ),
            ],
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              IconButton(
                onPressed: () {
                  _subSpeed -= 0.01;
                  _subSpeedController.value = TextEditingValue(
                    text: _subSpeed.toStringAsFixed(2),
                  );
                },
                icon: const Icon(Icons.remove_circle),
              ),
              Expanded(
                child: TextFormField(
                  controller: _subSpeedController,
                  keyboardType: TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    isDense: true,
                    label: Text(context.l10n.subtitle_speed),
                  ),
                ),
              ),
              IconButton(
                onPressed: () {
                  _subSpeed += 0.01;
                  _subSpeedController.value = TextEditingValue(
                    text: _subSpeed.toStringAsFixed(2),
                  );
                },
                icon: const Icon(Icons.add_circle),
              ),
            ],
          ),
          const SizedBox(height: 30),
          ...videoSubtitleLast.toSet().toList().map((sub) {
            final title =
                sub.title ??
                sub.subtitle?.title ??
                sub.subtitle?.language ??
                sub.subtitle?.channels ??
                "None";

            final selected =
                (title ==
                    (subtitle.title ??
                        subtitle.language ??
                        subtitle.channels ??
                        "None")) ||
                (subtitle.id == "no" && title == "None");
            return GestureDetector(
              onTap: () {
                Navigator.pop(context);
                try {
                  unawaited(_setSubtitleTrack(sub.subtitle!));
                } catch (_) {}
              },
              child: textWidget(title, selected),
            );
          }),
          const SizedBox(height: 30),
          GestureDetector(
            onTap: () async {
              try {
                final path = (await FilePicker.pickFile())?.path;
                if (path != null && context.mounted) {
                  await _setSubtitleTrack(SubtitleTrack.uri(path));
                }
                if (!context.mounted) return;
                Navigator.pop(context);
              } catch (e) {
                botToast("Error: $e");
                Navigator.pop(context);
              }
            },
            child: textWidget(context.l10n.load_own_subtitles, false),
          ),
          const SizedBox(height: 30),
          GestureDetector(
            onTap: () async {
              try {
                final subtitle = await subtitlesSearchraggableMenu(
                  context,
                  chapter: widget.episode,
                  isLocal: widget.isLocal,
                ) as ImdbSubtitle?;
                if (subtitle != null && context.mounted) {
                  await _setSubtitleTrack(
                    SubtitleTrack.uri(
                      subtitle.url!,
                      title: subtitle.language,
                      language: subtitle.language,
                    ),
                  );
                }
                if (!context.mounted) return;
                Navigator.pop(context);
              } catch (_) {
                botToast("Error");
                Navigator.pop(context);
              }
            },
            child: textWidget(context.l10n.search_subtitles, false),
          ),
          const SizedBox(height: 30),
          GestureDetector(
            onTap: () {
              onSearchJimaku();
              Navigator.pop(context);
            },
            child: textWidget('Search Jimaku', false),
          ),
        ],
      ),
    );
  }

  Widget _videoAudios(BuildContext context) {
    List<VideoPrefs> videoAudio = _player.state.tracks.audio
        .toList()
        .map((e) => VideoPrefs(isLocal: true, audio: e))
        .toList();

    List<String> audios = [];
    if (widget.videos.isNotEmpty && !widget.isLocal) {
      for (var video in widget.videos) {
        for (var audio in video.audios ?? []) {
          if (!audios.contains(audio.file)) {
            videoAudio.add(
              VideoPrefs(
                isLocal: false,
                audio: AudioTrack.uri(
                  audio.file!,
                  title: audio.label,
                  language: audio.language ?? audio.label,
                ),
              ),
            );
            audios.add(audio.file!);
          }
        }
      }
    }
    final audio = _player.state.track.audio;
    videoAudio = videoAudio
        .map((e) {
          VideoPrefs vid = e;
          vid.title = audioTrackLabel(vid.audio);
          return vid;
        })
        .toList()
        .where((element) => element.title!.isNotEmpty)
        .toList();
    videoAudio.sort((a, b) => a.title!.compareTo(b.title!));
    videoAudio.insert(0, VideoPrefs(isLocal: false, audio: AudioTrack.no()));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 12),
      child: Column(
        children: videoAudio.toSet().toList().map((aud) {
          final title = aud.title ?? audioTrackLabel(aud.audio);
          final selected =
              (aud.audio == audio) || (audio.id == "no" && title == "None");
          return GestureDetector(
            onTap: () async {
              Navigator.pop(context);
              try {
                await _setAudioTrack(aud.audio!);
              } catch (_) {}
            },
            child: textWidget(title, selected),
          );
        }).toList(),
      ),
    );
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    await _player.setRate(speed);
    _playbackSpeed.value = speed;
  }

  Future<void> _changeFitLabel(WidgetRef ref) async {
    List<BoxFit> fitList = [
      BoxFit.contain,
      BoxFit.cover,
      BoxFit.fill,
      BoxFit.fitHeight,
      BoxFit.fitWidth,
      BoxFit.scaleDown,
      BoxFit.none,
    ];
    _showFitLabel.value = true;
    BoxFit? fit;
    if (fitList.indexOf(_fit.value) < fitList.length - 1) {
      fit = fitList[fitList.indexOf(_fit.value) + 1];
    } else {
      fit = fitList[0];
    }
    _fit.value = fit;
    _key.currentState?.update(fit: fit);
    BotToast.showText(
      onlyOne: true,
      align: const Alignment(0, 0.90),
      duration: const Duration(seconds: 1),
      text: fit.name.toUpperCase(),
    );
  }

  Widget _seekToWidget() {
    final defaultSkipIntroLength = ref.watch(
      defaultSkipIntroLengthStateProvider,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: SizedBox(
        height: 35,
        child: ValueListenableBuilder(
          valueListenable: _customButton,
          builder: (context, value, child) => (value?.visible ?? true)
              ? ElevatedButton(
                  onPressed:
                      value?.onPress ??
                      () async => await _seekBy(defaultSkipIntroLength),
                  onLongPress: value?.onLongPress,
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text(
                      value != null
                          ? value.currentTitle
                          : "+$defaultSkipIntroLength",
                      style: const TextStyle(fontWeight: FontWeight.w100),
                    ),
                  ),
                )
              : Container(),
        ),
      ),
    );
  }

  Widget _chapterMarkWidget() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 5),
      child: SizedBox(
        height: 35,
        child: ValueListenableBuilder(
          valueListenable: _currentChapterMark,
          builder: (context, value, child) => value != null
              ? PopupMenuButton<int>(
                  tooltip: '',
                  itemBuilder: (context) => _chapterMarks.value
                      .map(
                        (mark) => PopupMenuItem<int>(
                          value: mark.$2,
                          child: Text(
                            "${mark.$1} - ${Duration(milliseconds: mark.$2).label()}",
                          ),
                          onTap: () =>
                              _player.seek(Duration(milliseconds: mark.$2)),
                        ),
                      )
                      .toList(),
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text(
                      "${_chapterMarks.value[value].$1} - ${Duration(milliseconds: _chapterMarks.value[value].$2).label()}",
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                )
              : Container(),
        ),
      ),
    );
  }

  Widget _mobileBottomButtonBar(BuildContext context) {
    return _playerBottomButtonBar(context);
  }

  Widget _desktopBottomButtonBar(BuildContext context) {
    return _playerBottomButtonBar(context);
  }

  Widget _playerBottomButtonBar(BuildContext context) {
    final isFullScreen = ref.watch(fullscreenProvider);
    const speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 8, isDesktop ? 4 : 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  if (isDesktop)
                    CustomMaterialDesktopVolumeButton(controller: _controller),
                  ValueListenableBuilder<double>(
                    valueListenable: _playbackSpeed,
                    builder: (context, speed, _) => PopupMenuButton<double>(
                      tooltip: 'Playback speed',
                      onSelected: _setPlaybackSpeed,
                      itemBuilder: (context) => speeds
                          .map(
                            (value) => PopupMenuItem<double>(
                              value: value,
                              child: Text('${value}x'),
                            ),
                          )
                          .toList(),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Text(
                          '${speed}x',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                  _chapterMarkWidget(),
                ],
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_subtitleCues.isNotEmpty ||
                      _player.platform is NativePlayer) ...[
                    IconButton(
                      tooltip: 'Snap delay to previous subtitle',
                      icon: const Icon(Icons.skip_previous_rounded),
                      color: Colors.white,
                      onPressed: () =>
                          unawaited(_snapSubtitleDelay(next: false)),
                    ),
                    IconButton(
                      tooltip: 'Snap delay to next subtitle',
                      icon: const Icon(Icons.skip_next_rounded),
                      color: Colors.white,
                      onPressed: () =>
                          unawaited(_snapSubtitleDelay(next: true)),
                    ),
                  ],
                  _seekToWidget(),
                  if (isDesktop && useMpvConfig)
                    ..._buildMpvSettingsButton(context),
                  IconButton(
                    tooltip: 'Aspect ratio',
                    icon: const Icon(Icons.aspect_ratio_rounded),
                    color: Colors.white,
                    onPressed: () => _changeFitLabel(ref),
                  ),
                  if (isDesktop)
                    CustomMaterialDesktopFullscreenButton(
                      controller: _controller,
                      desktopFullScreenPlayer: widget.desktopFullScreenPlayer,
                    )
                  else
                    IconButton(
                      tooltip: isFullScreen ? 'Exit fullscreen' : 'Fullscreen',
                      icon: Icon(
                        isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      ),
                      color: Colors.white,
                      onPressed: () {
                        _setLandscapeMode(!isFullScreen);
                        ref.read(fullscreenProvider.notifier).state =
                            !isFullScreen;
                        widget.desktopFullScreenPlayer(!isFullScreen);
                      },
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildMpvSettingsButton(BuildContext context) {
    return [
      PopupMenuButton<String>(
        tooltip: 'Shaders',
        icon: const Icon(Icons.high_quality, color: Colors.white),
        itemBuilder: (context) =>
            [
                  ("Anime4K: Mode A (Fast)", "set_anime_a"),
                  ("Anime4K: Mode B (Fast)", "set_anime_b"),
                  ("Anime4K: Mode C (Fast)", "set_anime_c"),
                  ("Anime4K: Mode A+A (Fast)", "set_anime_aa"),
                  ("Anime4K: Mode B+B (Fast)", "set_anime_bb"),
                  ("Anime4K: Mode C+A (Fast)", "set_anime_ca"),
                  ("Anime4K: Mode A (HQ)", "set_anime_hq_a"),
                  ("Anime4K: Mode B (HQ)", "set_anime_hq_b"),
                  ("Anime4K: Mode C (HQ)", "set_anime_hq_c"),
                  ("Anime4K: Mode A+A (HQ)", "set_anime_hq_aa"),
                  ("Anime4K: Mode B+B (HQ)", "set_anime_hq_bb"),
                  ("Anime4K: Mode C+A (HQ)", "set_anime_hq_ca"),
                  ("AMD FSR", "set_fsr"),
                  ("Luma Upscaling", "set_luma"),
                  ("Qualcomm Snapdragon GSR", "set_snapdragon"),
                  ("NVIDIA Image Scaling", "set_nvidia"),
                  ("Clear GLSL shaders", "clear_anime"),
                ]
                .map(
                  (mode) => PopupMenuItem<String>(
                    value: mode.$1,
                    child: Text(
                      mode.$1,
                      style: TextStyle(
                        fontWeight: _selectedShader.value == mode.$1
                            ? FontWeight.w900
                            : FontWeight.normal,
                      ),
                    ),
                    onTap: () {
                      (_player.platform as NativePlayer).command([
                        "script-message",
                        mode.$2,
                      ]);
                    },
                  ),
                )
                .toList(),
      ),
      PopupMenuButton<String>(
        tooltip: 'Stats',
        icon: const Icon(Icons.memory, color: Colors.white),
        itemBuilder: (context) =>
            [
                  ("Stats Toggle", "stats/display-stats-toggle"),
                  ("Stats Page 1", "stats/display-page-1"),
                  ("Stats Page 2", "stats/display-page-2"),
                  ("Stats Page 3", "stats/display-page-3"),
                  ("Stats Page 4", "stats/display-page-4"),
                  ("Stats Page 5", "stats/display-page-5"),
                ]
                .map(
                  (mode) => PopupMenuItem<String>(
                    value: mode.$1,
                    child: Text(
                      mode.$1,
                      style: TextStyle(
                        fontWeight: _selectedShader.value == mode.$1
                            ? FontWeight.w900
                            : FontWeight.normal,
                      ),
                    ),
                    onTap: () {
                      (_player.platform as NativePlayer).command([
                        "script-binding",
                        mode.$2,
                      ]);
                    },
                  ),
                )
                .toList(),
      ),
      ValueListenableBuilder(
        valueListenable: _customButtons,
        builder: (context, value, child) => value != null
            ? PopupMenuButton<String>(
                tooltip: context.l10n.custom_buttons,
                icon: const Icon(Icons.terminal, color: Colors.white),
                itemBuilder: (context) => value
                    .map(
                      (btn) => PopupMenuItem<String>(
                        value: btn.title!,
                        child: Text(btn.title!),
                        onTap: () {
                          (_player.platform as NativePlayer).command([
                            "script-message",
                            "call_button_${btn.id}",
                          ]);
                        },
                      ),
                    )
                    .toList(),
              )
            : Container(),
      ),
    ];
  }

  Widget _topButtonBar(BuildContext context) {
    final fullScreen = ref.watch(fullscreenProvider);
    return Padding(
      padding: EdgeInsets.only(
        top: !isDesktop && !fullScreen ? MediaQuery.of(context).padding.top : 0,
      ),
      child: Row(
        children: [
          BackButton(color: Colors.white, onPressed: _goBackToDetail),
          Flexible(
            child: ListTile(
              dense: true,
              title: SizedBox(
                width: context.width(0.8),
                child: Text(
                  widget.episode.manga.value!.name!,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              subtitle: SizedBox(
                width: context.width(0.8),
                child: Text(
                  widget.episode.name!,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    fontStyle: FontStyle.italic,
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          Row(
            children: [
              if (_supportAlwaysOnTop())
                IconButton(
                  icon: Icon(
                    _alwaysOnTop ? Icons.push_pin : Icons.push_pin_outlined,
                    color: Colors.white,
                  ),
                  onPressed: () {
                    setState(() => _alwaysOnTop = !_alwaysOnTop);
                    windowManager.setAlwaysOnTop(_alwaysOnTop);
                  },
                ),
              IconButton(
                tooltip: 'Video OCR',
                icon: _videoOcrCapturing
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.document_scanner_rounded),
                color: Colors.white,
                onPressed: _videoOcrCapturing ? null : _showVideoOcr,
              ),
              IconButton(
                tooltip: _liveVideoOcrEnabled
                    ? 'Turn off live OCR'
                    : 'Turn on live OCR',
                icon: Icon(
                  _liveVideoOcrEnabled
                      ? Icons.visibility_rounded
                      : Icons.visibility_outlined,
                ),
                color: _liveVideoOcrEnabled
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white,
                onPressed: _videoOcrCapturing ? null : _toggleLiveVideoOcr,
              ),
              IconButton(
                tooltip: 'Subtitle list',
                icon: const Icon(Icons.format_list_bulleted_rounded),
                color: Colors.white,
                onPressed: () {
                  setState(() => _showSubtitleList = !_showSubtitleList);
                },
              ),
              IconButton(
                tooltip: context.l10n.video_subtitle,
                icon: const Icon(Icons.subtitles_rounded),
                color: Colors.white,
                onPressed: () =>
                    _videoSettingDraggableMenu(context, initialIndex: 1),
              ),
              IconButton(
                tooltip: context.l10n.video_audio,
                icon: const Icon(Icons.audiotrack_rounded),
                color: Colors.white,
                onPressed: () =>
                    _videoSettingDraggableMenu(context, initialIndex: 2),
              ),
              IconButton(
                tooltip: context.l10n.video_quality,
                icon: const Icon(Icons.high_quality_rounded),
                color: Colors.white,
                onPressed: () => _videoSettingDraggableMenu(context),
              ),
              btnToShowChapterListDialog(
                context,
                context.l10n.episodes,
                widget.episode,
                onChanged: (v) {
                  if (v) {
                    _player.play();
                  } else {
                    _player.pause();
                  }
                },
                iconColor: Colors.white,
              ),
              btnToShowShareScreenshot(
                widget.episode,
                onChanged: (v) {
                  if (v) {
                    _player.play();
                  } else {
                    _player.pause();
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  BoxFit? _lastFit;
  void _resize(BoxFit fit) async {
    if (fit == _lastFit) return;
    _lastFit = fit;
    // Wait for the widget tree to settle before updating fit
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) {
      _key.currentState?.update(
        fit: fit,
        width: context.width(1),
        height: context.height(1),
      );
    }
  }

  Widget _primaryButtonBar(BuildContext context) {
    return ChimahonPrimaryControls(
      controller: _controller,
      hasPrevious: _streamController.hasPreviousEpisode,
      hasNext: _streamController.hasNextEpisode,
      onPrevious: () =>
          pushToNewEpisode(context, _streamController.getPrevEpisode()),
      onNext: () =>
          pushToNewEpisode(context, _streamController.getNextEpisode()),
    );
  }

  Widget _videoPlayer(BuildContext context) {
    final fit = _fit.value;
    _resize(fit);
    final enableAniSkip = ref.read(enableAniSkipStateProvider);
    final enableAutoSkip = ref.read(enableAutoSkipStateProvider);
    final aniSkipTimeoutLength = ref.read(aniSkipTimeoutLengthStateProvider);
    final skipIntroLength = ref.read(defaultSkipIntroLengthStateProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        _linuxVideoViewport = (
          width: constraints.maxWidth,
          height: constraints.maxHeight,
        );
        _scheduleLinuxVideoOutputResize();
        return Listener(
          onPointerDown: _handleVideoOcrGestureDown,
          onPointerMove: _handleVideoOcrGestureMove,
          onPointerUp: _handleVideoOcrGestureUp,
          onPointerCancel: _handleVideoOcrGestureCancel,
          child: Stack(
            children: [
              if (_videoTextureVisible)
                Video(
                  subtitleViewConfiguration: SubtitleViewConfiguration(
                    visible: false,
                    style: subtileTextStyle(ref),
                  ),
                  fit: fit,
                  key: _key,
                  controls: (state) => isDesktop
                      ? DesktopControllerWidget(
                          videoController: _controller,
                          topButtonBarWidget: _topButtonBar(context),
                          primaryButtonBarWidget: _primaryButtonBar(context),
                          bottomButtonBarWidget: _desktopBottomButtonBar(
                            context,
                          ),
                          tempDuration: (value) {
                            _tempPosition.value = value;
                          },
                          doubleSpeed: (value) {
                            _isDoubleSpeed.value = value ?? false;
                          },
                          defaultSkipIntroLength: skipIntroLength,
                          desktopFullScreenPlayer:
                              widget.desktopFullScreenPlayer,
                          chapterMarks: _chapterMarks,
                          subtitleMiningContextBuilder: _subtitleMiningContext,
                          videoOcrActive: _videoOcrBytes != null,
                          onVideoOcrShortcut: _handleVideoOcrShortcut,
                        )
                      : MobileControllerWidget(
                          videoController: _controller,
                          topButtonBarWidget: _topButtonBar(context),
                          primaryButtonBarWidget: _primaryButtonBar(context),
                          bottomButtonBarWidget: _mobileBottomButtonBar(
                            context,
                          ),
                          doubleSpeed: (value) {
                            _isDoubleSpeed.value = value ?? false;
                          },
                          chapterMarks: _chapterMarks,
                          subtitleMiningContextBuilder: _subtitleMiningContext,
                        ),
                  controller: _controller,
                  width: context.width(1),
                  height: context.height(1),
                  resumeUponEnteringForegroundMode: true,
                )
              else
                const SizedBox.expand(),
              Stack(
                alignment: AlignmentDirectional.center,
                children: [
                  Positioned(
                    top: 30,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _isDoubleSpeed,
                      builder: (context, snapshot, _) {
                        return Text.rich(
                          textAlign: TextAlign.center,
                          TextSpan(
                            style: TextStyle(
                              background: Paint()
                                ..color = Theme.of(context)
                                    .scaffoldBackgroundColor
                                ..strokeWidth = 30.0
                                ..strokeJoin = StrokeJoin.round
                                ..style = PaintingStyle.stroke,
                            ),
                            children: snapshot
                                ? [
                                    TextSpan(
                                      text: " 2X ",
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    WidgetSpan(
                                      alignment: PlaceholderAlignment.middle,
                                      child: Icon(Icons.fast_forward),
                                    ),
                                  ]
                                : [],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
              if (enableAniSkip && (_hasOpeningSkip || _hasEndingSkip))
                Positioned(
                  right: 0,
                  bottom: 80,
                  child: ValueListenableBuilder<_AniSkipPhase>(
                    valueListenable: _skipPhase,
                    builder: (context, phase, _) {
                      if (phase == _AniSkipPhase.none) {
                        return const SizedBox.shrink();
                      }
                      final isOpening = phase == _AniSkipPhase.opening;
                      final result = isOpening
                          ? _openingResult!
                          : _endingResult!;
                      return AniSkipCountDownButton(
                        key: Key(isOpening ? 'skip_opening' : 'skip_ending'),
                        active: true,
                        autoSkip: enableAutoSkip,
                        timeoutLength: aniSkipTimeoutLength,
                        skipTypeText: isOpening
                            ? context.l10n.skip_opening
                            : context.l10n.skip_ending,
                        player: _player,
                        aniSkipResult: result,
                      );
                    },
                  ),
                ),
              if (_showSubtitleList)
                AnimeSubtitleListPanel(
                  cues: _subtitleCues,
                  position: _currentPosition,
                  subtitleDelayMs: _subDelay,
                  onSelect: (cue) {
                    unawaited(
                      _player.seek(
                        subtitleCuePlaybackTime(
                          cue,
                          subtitleDelayMs: _subDelay,
                        ),
                      ),
                    );
                  },
                  onDismiss: () => setState(() => _showSubtitleList = false),
                ),
              if (_videoOcrBytes case final imageBytes?)
                VideoOcrOverlay(
                  imageBytes: imageBytes,
                  imagePosition: _videoOcrPosition,
                  fit: fit,
                  miningContextBuilder: (text, bytes, position) =>
                      _subtitleMiningContext(
                        text,
                        frozenImageBytes: bytes,
                        frozenPosition: position,
                        ocrTiming: true,
                      ),
                  onDismiss: _dismissVideoOcr,
                ),
              if (_liveVideoOcrEnabled && _videoOcrBytes == null)
                LiveVideoOcrOverlay(
                  imageBytesLoader: _captureLiveVideoOcrFrame,
                  fit: fit,
                  miningContextBuilder: (text, bytes, position) =>
                      _subtitleMiningContext(
                        text,
                        frozenImageBytes: bytes,
                        frozenPosition: position,
                        ocrTiming: true,
                      ),
                  onDismiss: () {
                    DictionaryLookupPopup.dismissActive();
                    setState(() => _liveVideoOcrEnabled = false);
                    unawaited(MiningPreferences.setLiveVideoOcrEnabled(false));
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  void _scheduleLinuxVideoOutputResize() {
    if (!Platform.isLinux ||
        _linuxVideoResizeScheduled ||
        _linuxVideoViewport == null) {
      return;
    }
    _linuxVideoResizeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _linuxVideoResizeScheduled = false;
      if (!mounted) return;
      final viewport = _linuxVideoViewport;
      if (viewport == null) return;
      final outputSize = linuxVideoOutputSize(
        logicalWidth: viewport.width,
        logicalHeight: viewport.height,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      );
      if (outputSize == null || outputSize == _linuxVideoOutputSize) return;
      try {
        await _controller.setSize(
          width: outputSize.width,
          height: outputSize.height,
        );
        _linuxVideoOutputSize = outputSize;
      } catch (error, stackTrace) {
        AppLogger.log(
          'Failed to resize Linux video output: $error\n$stackTrace',
          logLevel: LogLevel.warning,
        );
      }
    });
  }

  void _handleVideoOcrGestureDown(PointerDownEvent event) {
    if (isDesktop) return;
    _videoOcrGesturePointers.add(event.pointer);
    _videoOcrGestureStarts[event.pointer] = event.position;
    if (_videoOcrGesturePointers.length == 2) {
      _videoOcrGestureStartedAt = DateTime.now();
      _videoOcrGestureCandidate = true;
    } else if (_videoOcrGesturePointers.length > 2) {
      _videoOcrGestureCandidate = false;
    }
  }

  void _handleVideoOcrGestureMove(PointerMoveEvent event) {
    if (!_videoOcrGestureCandidate) return;
    final start = _videoOcrGestureStarts[event.pointer];
    if (start != null && (event.position - start).distance > 24) {
      _videoOcrGestureCandidate = false;
    }
  }

  void _handleVideoOcrGestureUp(PointerUpEvent event) {
    final shouldToggle =
        _videoOcrGestureCandidate &&
        _videoOcrGesturePointers.length == 2 &&
        _videoOcrGestureStartedAt != null &&
        DateTime.now().difference(_videoOcrGestureStartedAt!) <=
            const Duration(milliseconds: 350);
    _videoOcrGesturePointers.remove(event.pointer);
    _videoOcrGestureStarts.remove(event.pointer);
    if (shouldToggle) {
      _videoOcrGestureCandidate = false;
      unawaited(_handleVideoOcrShortcut());
    }
    if (_videoOcrGesturePointers.isEmpty) {
      _videoOcrGestureCandidate = false;
      _videoOcrGestureStartedAt = null;
    }
  }

  void _handleVideoOcrGestureCancel(PointerCancelEvent event) {
    _videoOcrGesturePointers.remove(event.pointer);
    _videoOcrGestureStarts.remove(event.pointer);
    _videoOcrGestureCandidate = false;
    if (_videoOcrGesturePointers.isEmpty) {
      _videoOcrGestureStartedAt = null;
    }
  }

  Widget btnToShowShareScreenshot(
    Chapter episode, {
    void Function(bool)? onChanged,
  }) {
    return IconButton(
      onPressed: () async {
        onChanged?.call(false);
        Widget button(String label, IconData icon, Function() onPressed) =>
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(15),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    shadowColor: Colors.transparent,
                  ),
                  onPressed: onPressed,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(icon),
                      ),
                      Text(label),
                    ],
                  ),
                ),
              ),
            );
        final name =
            "${episode.manga.value!.name} ${episode.name} - ${_currentPosition.value.toString()}"
                .replaceAll(RegExp(r'[^a-zA-Z0-9 .()\-\s]'), '_');
        await showModalBottomSheet(
          context: context,
          constraints: BoxConstraints(maxWidth: context.width(1)),
          builder: (context) {
            return SuperListView(
              shrinkWrap: true,
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(20),
                      topRight: Radius.circular(20),
                    ),
                    color: context.themeData.scaffoldBackgroundColor,
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Container(
                          height: 7,
                          width: 35,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            color: context.secondaryColor.withValues(
                              alpha: 0.4,
                            ),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          button(
                            context.l10n.set_as_cover,
                            Icons.image_outlined,
                            () async {
                              final imageBytes = await _player.screenshot(
                                format: "image/png",
                                includeLibassSubtitles: _includeSubtitles,
                              );
                              if (context.mounted) {
                                final res = await showDialog(
                                  context: context,
                                  builder: (context) {
                                    return AlertDialog(
                                      content: Text(
                                        context.l10n.use_this_as_cover_art,
                                      ),
                                      actions: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.end,
                                          children: [
                                            TextButton(
                                              onPressed: () {
                                                Navigator.pop(context);
                                              },
                                              child: Text(context.l10n.cancel),
                                            ),
                                            const SizedBox(width: 15),
                                            TextButton(
                                              onPressed: () {
                                                final manga =
                                                    episode.manga.value!;
                                                mangaRepository.save(
                                                  manga
                                                    ..customCoverImage =
                                                        imageBytes
                                                            ?.getCoverImage,
                                                );
                                                if (context.mounted) {
                                                  Navigator.pop(context, "ok");
                                                }
                                              },
                                              child: Text(context.l10n.ok),
                                            ),
                                          ],
                                        ),
                                      ],
                                    );
                                  },
                                );
                                if (res != null &&
                                    res == "ok" &&
                                    context.mounted) {
                                  Navigator.pop(context);
                                  botToast(
                                    context.l10n.cover_updated,
                                    second: 3,
                                  );
                                }
                              }
                            },
                          ),
                          button(
                            context.l10n.share,
                            Icons.share_outlined,
                            () async {
                              final imageBytes = await _player.screenshot(
                                format: "image/png",
                                includeLibassSubtitles: _includeSubtitles,
                              );
                              if (context.mounted) {
                                final box =
                                    context.findRenderObject() as RenderBox?;
                                await shareOrCopy(
                                  ShareParams(
                                    files: [
                                      XFile.fromData(
                                        imageBytes!,
                                        name: name,
                                        mimeType: 'image/png',
                                      ),
                                    ],
                                    sharePositionOrigin:
                                        box!.localToGlobal(Offset.zero) &
                                        box.size,
                                  ),
                                  fallbackName: name,
                                );
                              }
                            },
                          ),
                          button(
                            context.l10n.save,
                            Icons.save_outlined,
                            () async {
                              final imageBytes = await _player.screenshot(
                                format: "image/png",
                                includeLibassSubtitles: _includeSubtitles,
                              );
                              final dir = await StorageProvider()
                                  .getGalleryDirectory();
                              final file = File(
                                path.join(dir!.path, "$name.png"),
                              );
                              file.writeAsBytesSync(imageBytes!);
                              if (context.mounted) {
                                botToast(context.l10n.picture_saved, second: 3);
                              }
                            },
                          ),
                        ],
                      ),
                      SwitchListTile(
                        onChanged: (value) {
                          setState(() {
                            _includeSubtitles = value;
                          });
                        },
                        title: Text(context.l10n.include_subtitles),
                        value: _includeSubtitles,
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
        onChanged?.call(true);
      },
      icon: Icon(Icons.adaptive.share, color: Colors.white),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = _videoPlayer(context);
    final shortcutBody = isDesktop ? body : _wrapWithPlayerShortcuts(body);
    return DesktopBackNavigationScope(
      onBack: _handleEscape,
      child: Scaffold(body: shortcutBody),
    );
  }

  /// Maps keyboard and TV-remote keys to player actions for non-desktop
  /// builds. Only dedicated media keys + the usual mpv-style keys are bound
  /// (no D-pad arrows beyond seek), so it stays additive and doesn't fight
  /// touch input. Reuses the existing player + episode-navigation methods.
  Widget _wrapWithPlayerShortcuts(Widget child) {
    void seekBy(int seconds) {
      _player.seek(_player.state.position + Duration(seconds: seconds));
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.space): () {
          _player.playOrPause();
        },
        const SingleActivator(LogicalKeyboardKey.mediaPlayPause): () {
          _player.playOrPause();
        },
        const SingleActivator(LogicalKeyboardKey.mediaPlay): () {
          _player.play();
        },
        const SingleActivator(LogicalKeyboardKey.mediaPause): () {
          _player.pause();
        },
        // Seek via J/L and the dedicated media keys only. Arrow keys are left
        // unbound so they keep driving d-pad focus traversal on Android TV
        // (and arrow-key focus movement with a keyboard) instead of seeking.
        const SingleActivator(LogicalKeyboardKey.keyJ): () => seekBy(-10),
        const SingleActivator(LogicalKeyboardKey.keyL): () => seekBy(10),
        const SingleActivator(LogicalKeyboardKey.mediaRewind): () =>
            seekBy(-10),
        const SingleActivator(LogicalKeyboardKey.mediaFastForward): () =>
            seekBy(10),
        const SingleActivator(LogicalKeyboardKey.mediaTrackNext): () {
          if (hasNextEpisode && mounted) {
            pushToNewEpisode(context, _streamController.getNextEpisode());
          }
        },
        const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): () {
          if (_streamController.hasPreviousEpisode && mounted) {
            pushToNewEpisode(context, _streamController.getPrevEpisode());
          }
        },
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}

Widget seekIndicatorTextWidget(Duration duration, Duration currentPosition) {
  final swipeDuration = duration.inSeconds;
  final value = currentPosition.inSeconds + swipeDuration;
  return Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Text(
        Duration(seconds: value).label(),
        style: const TextStyle(
          fontSize: 65.0,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
      Text(
        "[${swipeDuration > 0 ? "+${Duration(seconds: swipeDuration).label()}" : "-${Duration(seconds: swipeDuration).label()}"}]",
        style: const TextStyle(
          fontSize: 40.0,
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    ],
  );
}

Duration? _durationFromSeconds(String? value) {
  final seconds = double.tryParse(value ?? '');
  if (seconds == null || !seconds.isFinite || seconds < 0) return null;
  return Duration(
    microseconds: (seconds * Duration.microsecondsPerSecond).round(),
  );
}

bool _booleanProperty(String? value, {required bool fallback}) {
  return switch (value?.trim().toLowerCase()) {
    'yes' || 'true' || '1' => true,
    'no' || 'false' || '0' => false,
    _ => fallback,
  };
}

class VideoPrefs {
  String? title;
  VideoTrack? videoTrack;
  SubtitleTrack? subtitle;
  AudioTrack? audio;
  bool isLocal;
  final Map<String, String>? headers;
  VideoPrefs({
    this.videoTrack,
    this.isLocal = true,
    this.headers,
    this.subtitle,
    this.audio,
    this.title,
  });
}

mixin _AlwaysOnTopStateMixin<T extends StatefulWidget> on State<T> {
  // The original alwaysOnTop state.
  // This will be used to restore the original state when the widget disposed.
  bool? _savedAlwaysOnTop;

  bool _alwaysOnTop = false;

  @override
  void initState() {
    super.initState();
    _initAlwaysOnTop();
  }

  @override
  void dispose() {
    super.dispose();
    _disposeAlwaysOnTop();
  }

  Future<void> _initAlwaysOnTop() async {
    if (_supportAlwaysOnTop()) {
      _savedAlwaysOnTop = await windowManager.isAlwaysOnTop();
      if (mounted) {
        setState(() => _alwaysOnTop = _savedAlwaysOnTop!);
      }
    }
  }

  Future<void> _disposeAlwaysOnTop() async {
    if (_supportAlwaysOnTop()) {
      if (_savedAlwaysOnTop != null) {
        await windowManager.setAlwaysOnTop(_savedAlwaysOnTop!);
      }
    }
  }

  // Whether the platform support AlwaysOnTop feature.
  bool _supportAlwaysOnTop() => !kIsWeb && isDesktop;
}
