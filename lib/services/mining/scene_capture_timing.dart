class SceneTimingRange {
  const SceneTimingRange({required this.start, required this.end});

  final Duration start;
  final Duration end;

  Duration get duration => end - start;
}

class ParsedSubtitleTiming {
  const ParsedSubtitleTiming({
    required this.text,
    required this.start,
    required this.end,
  });

  final String text;
  final Duration start;
  final Duration end;
}

class SceneCaptureTiming {
  const SceneCaptureTiming({required this.scene, required this.audio});

  final SceneTimingRange scene;
  final SceneTimingRange audio;
}

SceneCaptureTiming resolveSubtitleSceneTiming({
  required String subtitleText,
  required Duration playbackPosition,
  required Duration mediaDuration,
  Duration? liveSubtitleStart,
  Duration? liveSubtitleEnd,
  Iterable<ParsedSubtitleTiming> parsedCues = const [],
  double subtitleSpeed = 1,
  Duration subtitleDelay = Duration.zero,
}) {
  final speed = subtitleSpeed.isFinite && subtitleSpeed > 0
      ? subtitleSpeed
      : 1.0;
  Duration? subtitleStart = liveSubtitleStart;
  Duration? subtitleEnd = liveSubtitleEnd;

  if (subtitleStart == null ||
      subtitleEnd == null ||
      subtitleEnd <= subtitleStart) {
    final subtitlePosition = _mediaToSubtitle(
      playbackPosition,
      speed: speed,
      delay: subtitleDelay,
    );
    ParsedSubtitleTiming? closest;
    var closestDistance = const Duration(days: 365);
    final normalizedText = _normalizeSubtitleText(subtitleText);
    for (final cue in parsedCues) {
      if (_normalizeSubtitleText(cue.text) != normalizedText) continue;
      final contains =
          subtitlePosition >= cue.start && subtitlePosition <= cue.end;
      final distance = contains
          ? Duration.zero
          : subtitlePosition < cue.start
          ? cue.start - subtitlePosition
          : subtitlePosition - cue.end;
      if (distance < closestDistance) {
        closest = cue;
        closestDistance = distance;
      }
    }
    if (closest != null) {
      subtitleStart = closest.start;
      subtitleEnd = closest.end;
    }
  }

  SceneTimingRange rawRange;
  if (subtitleStart != null &&
      subtitleEnd != null &&
      subtitleEnd > subtitleStart) {
    rawRange = SceneTimingRange(
      start: _subtitleToMedia(
        subtitleStart,
        speed: speed,
        delay: subtitleDelay,
      ),
      end: _subtitleToMedia(subtitleEnd, speed: speed, delay: subtitleDelay),
    );
  } else {
    rawRange = SceneTimingRange(
      start: playbackPosition - const Duration(milliseconds: 500),
      end: playbackPosition + const Duration(milliseconds: 500),
    );
  }

  final scene = _boundRange(
    rawRange,
    mediaDuration: mediaDuration,
    maximum: const Duration(seconds: 10),
  );
  final audio = _boundRange(
    SceneTimingRange(
      start: rawRange.start - const Duration(milliseconds: 250),
      end: rawRange.end + const Duration(milliseconds: 250),
    ),
    mediaDuration: mediaDuration,
    maximum: const Duration(seconds: 30),
  );
  return SceneCaptureTiming(scene: scene, audio: audio);
}

SceneCaptureTiming resolveOcrSceneTiming({
  required Duration playbackPosition,
  required Duration mediaDuration,
  Duration padding = const Duration(seconds: 3),
}) {
  final safePadding = padding.isNegative ? Duration.zero : padding;
  final range = _boundRange(
    SceneTimingRange(
      start: playbackPosition - safePadding,
      end: playbackPosition + safePadding,
    ),
    mediaDuration: mediaDuration,
    maximum: const Duration(seconds: 10),
  );
  return SceneCaptureTiming(scene: range, audio: range);
}

SceneTimingRange _boundRange(
  SceneTimingRange value, {
  required Duration mediaDuration,
  required Duration maximum,
}) {
  var start = value.start;
  var end = value.end;
  if (start.isNegative) start = Duration.zero;
  if (mediaDuration > Duration.zero && end > mediaDuration) {
    end = mediaDuration;
  }
  if (end <= start) end = start + const Duration(milliseconds: 250);
  if (end - start < const Duration(milliseconds: 250)) {
    end = start + const Duration(milliseconds: 250);
  }
  if (end - start > maximum) end = start + maximum;
  if (mediaDuration > Duration.zero && end > mediaDuration) {
    end = mediaDuration;
    start = end - const Duration(milliseconds: 250);
    if (start.isNegative) start = Duration.zero;
  }
  return SceneTimingRange(start: start, end: end);
}

Duration _subtitleToMedia(
  Duration value, {
  required double speed,
  required Duration delay,
}) {
  return Duration(microseconds: (value.inMicroseconds * speed).round()) + delay;
}

Duration _mediaToSubtitle(
  Duration value, {
  required double speed,
  required Duration delay,
}) {
  final adjusted = value - delay;
  if (adjusted.isNegative) return Duration.zero;
  return Duration(microseconds: (adjusted.inMicroseconds / speed).round());
}

String _normalizeSubtitleText(String value) =>
    value.replaceAll(RegExp(r'\s+'), ' ').trim();
