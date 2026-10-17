import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:mangayomi/modules/mining/widgets/dictionary_lookup_popup.dart';
import 'package:mangayomi/services/mining/dictionary_profile_resolver.dart';
import 'package:mangayomi/services/mining/generated_ocr.dart';
import 'package:mangayomi/services/mining/mining_models.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';
import 'package:mangayomi/services/mining/ocr_models.dart';
import 'package:mangayomi/services/mining/profile_ocr_language.dart';

class VideoOcrResult {
  const VideoOcrResult({
    required this.imageWidth,
    required this.imageHeight,
    required this.blocks,
  });

  final int imageWidth;
  final int imageHeight;
  final List<OcrTextBlock> blocks;
}

class VideoOcrFrame {
  const VideoOcrFrame({required this.bytes, required this.position});

  final Uint8List bytes;
  final Duration position;
}

typedef VideoOcrMiningContextBuilder = Future<MiningContext> Function(
  String text,
  Uint8List imageBytes,
  Duration? position,
);

Future<VideoOcrResult> recognizeVideoFrame(
  Uint8List bytes, {
  String? language,
}) async {
  final engine = await MiningPreferences.getOcrEngine();
  final effectiveLanguage =
      language ?? await MiningPreferences.getOcrLanguage();

  if (engine == OcrEnginePreference.mokuroOnly) {
    throw StateError(
      'Video OCR requires Apple Vision, ScreenAI, Hayai, or Google Lens',
    );
  }
  final result = await recognizeGeneratedOcr(
    bytes,
    engine: engine,
    language: effectiveLanguage,
  );
  return VideoOcrResult(
    imageWidth: result.imageWidth,
    imageHeight: result.imageHeight,
    blocks: result.blocks,
  );
}

class VideoOcrOverlay extends StatefulWidget {
  const VideoOcrOverlay({
    super.key,
    required this.imageBytes,
    required this.imagePosition,
    required this.fit,
    required this.miningContextBuilder,
    required this.onDismiss,
  });

  final Uint8List imageBytes;
  final Duration? imagePosition;
  final BoxFit fit;
  final VideoOcrMiningContextBuilder miningContextBuilder;
  final VoidCallback onDismiss;

  @override
  State<VideoOcrOverlay> createState() => _VideoOcrOverlayState();
}

class _VideoOcrOverlayState extends State<VideoOcrOverlay>
    with _VideoOcrLookup<VideoOcrOverlay> {
  VideoOcrResult? _result;
  Object? _error;
  MiningContext? _frameMiningContext;

  @override
  void initState() {
    super.initState();
    unawaited(DictionaryLookupPopup.prewarm(context));
    unawaited(_recognize());
  }

  Future<void> _recognize() async {
    try {
      final miningContext = await widget.miningContextBuilder(
        '',
        widget.imageBytes,
        widget.imagePosition,
      );
      final profile = await DictionaryProfileResolver.resolveMiningContext(
        miningContext,
      );
      final language = profileOcrLanguage(profile.languageCode);
      final result = await recognizeVideoFrame(
        widget.imageBytes,
        language: language,
      );
      if (!mounted) return;
      setState(() {
        _frameMiningContext = miningContext;
        _result = result;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    _popup?.dismiss();
    unawaited(_frameMiningContext?.sceneCapture?.dispose());
    super.dispose();
  }

  @override
  Future<MiningContext?> _miningContextFor(String sentence) async =>
      _frameMiningContext?.copyWith(sentence: sentence) ??
      await widget.miningContextBuilder(
        sentence,
        widget.imageBytes,
        widget.imagePosition,
      );

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Material(
        color: Colors.black,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final outputSize = Size(
              constraints.maxWidth,
              constraints.maxHeight,
            );
            final result = _result;
            final mapping = result == null
                ? null
                : _VideoFrameMapping.create(
                    imageSize: Size(
                      result.imageWidth.toDouble(),
                      result.imageHeight.toDouble(),
                    ),
                    outputSize: outputSize,
                    fit: widget.fit,
                  );
            final mappedBlocks = result == null || mapping == null
                ? const <_MappedVideoOcrBlock>[]
                : [
                        for (final block in result.blocks)
                          _MappedVideoOcrBlock(
                            block: block,
                            rect: mapping.mapBlock(block),
                          ),
                      ]
                      .where(
                        (item) => item.rect.overlaps(Offset.zero & outputSize),
                      )
                      .toList();

            return Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(widget.imageBytes, fit: widget.fit),
                for (final item in mappedBlocks)
                  Positioned.fromRect(
                    rect: item.rect,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 100),
                          decoration: BoxDecoration(
                            color: identical(_selection?.block, item.block)
                                ? Colors.amber.withValues(alpha: 0.28)
                                : Colors.transparent,
                            border: Border.all(
                              color: identical(_selection?.block, item.block)
                                  ? Colors.amber
                                  : Colors.lightBlueAccent.withValues(
                                      alpha: 0.7,
                                    ),
                              width: identical(_selection?.block, item.block)
                                  ? 2
                                  : 1,
                            ),
                          ),
                          child: VideoOcrText(
                            block: item.block,
                            selectionOffset:
                                identical(_selection?.block, item.block)
                                ? _selection?.offset
                                : null,
                            matchLength: _selection?.matchLength ?? 0,
                            onLookup: (offset, position) => _lookup(
                              context,
                              item.block,
                              item.rect,
                              position,
                              offset,
                            ),
                            selected: identical(_selection?.block, item.block),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (result == null && _error == null)
                  const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text(
                          'Finding text…',
                          style: TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                if (_error != null)
                  Center(
                    child: Card(
                      color: Colors.black87,
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          'Video OCR failed\n$_error',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                if (result != null && result.blocks.isEmpty)
                  const Center(
                    child: Text(
                      'No text found',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                SafeArea(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: IconButton.filledTonal(
                      tooltip: 'Close video OCR',
                      onPressed: widget.onDismiss,
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ),
                if (result != null && result.blocks.isNotEmpty)
                  const SafeArea(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.all(Radius.circular(18)),
                          ),
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            child: Text(
                              'Tap recognized text to look it up',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class LiveVideoOcrOverlay extends StatefulWidget {
  const LiveVideoOcrOverlay({
    super.key,
    required this.imageBytesLoader,
    required this.fit,
    required this.miningContextBuilder,
    required this.onDismiss,
  });

  final Future<VideoOcrFrame?> Function() imageBytesLoader;
  final BoxFit fit;
  final VideoOcrMiningContextBuilder miningContextBuilder;
  final VoidCallback onDismiss;

  @override
  State<LiveVideoOcrOverlay> createState() => _LiveVideoOcrOverlayState();
}

class _LiveVideoOcrOverlayState extends State<LiveVideoOcrOverlay>
    with _VideoOcrLookup<LiveVideoOcrOverlay> {
  static const _scanInterval = Duration(milliseconds: 2200);

  Timer? _timer;
  VideoOcrResult? _result;
  Object? _error;
  bool _scanning = false;
  String _lastSignature = '';
  VideoOcrFrame? _recognizedFrame;
  MiningContext? _recognizedMiningContext;

  @override
  void initState() {
    super.initState();
    unawaited(DictionaryLookupPopup.prewarm(context));
    unawaited(_scanFrame());
    _timer = Timer.periodic(_scanInterval, (_) => unawaited(_scanFrame()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _popup?.dismiss();
    unawaited(_recognizedMiningContext?.sceneCapture?.dispose());
    super.dispose();
  }

  Future<void> _scanFrame() async {
    if (_scanning) return;
    if (mounted) {
      setState(() => _scanning = true);
    } else {
      _scanning = true;
    }
    try {
      final frame = await widget.imageBytesLoader();
      if (frame == null || frame.bytes.isEmpty) return;
      final miningContext = await widget.miningContextBuilder(
        '',
        frame.bytes,
        frame.position,
      );
      final profile = await DictionaryProfileResolver.resolveMiningContext(
        miningContext,
      );
      final result = await recognizeVideoFrame(
        frame.bytes,
        language: profileOcrLanguage(profile.languageCode),
      );
      if (!mounted) return;
      final signature = result.blocks.map((block) => block.text).join('\n');
      if (signature == _lastSignature && _error == null) {
        final previous = _recognizedMiningContext;
        _recognizedFrame = frame;
        _recognizedMiningContext = miningContext;
        unawaited(previous?.sceneCapture?.dispose());
        return;
      }
      final previous = _recognizedMiningContext;
      setState(() {
        _lastSignature = signature;
        _result = result;
        _recognizedFrame = frame;
        _recognizedMiningContext = miningContext;
        _error = null;
        if (signature.isEmpty) {
          _popup?.dismiss();
          _selection = null;
        }
      });
      unawaited(previous?.sceneCapture?.dispose());
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) {
        setState(() => _scanning = false);
      } else {
        _scanning = false;
      }
    }
  }

  @override
  Future<MiningContext?> _miningContextFor(String sentence) async {
    final frame = _recognizedFrame;
    if (frame == null) return null;
    return _recognizedMiningContext?.copyWith(sentence: sentence) ??
        await widget.miningContextBuilder(
          sentence,
          frame.bytes,
          frame.position,
        );
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: false,
        child: Material(
          color: Colors.transparent,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final outputSize = Size(
                constraints.maxWidth,
                constraints.maxHeight,
              );
              final result = _result;
              final mapping = result == null
                  ? null
                  : _VideoFrameMapping.create(
                      imageSize: Size(
                        result.imageWidth.toDouble(),
                        result.imageHeight.toDouble(),
                      ),
                      outputSize: outputSize,
                      fit: widget.fit,
                    );
              final mappedBlocks = result == null || mapping == null
                  ? const <_MappedVideoOcrBlock>[]
                  : [
                          for (final block in result.blocks)
                            _MappedVideoOcrBlock(
                              block: block,
                              rect: mapping.mapBlock(block),
                            ),
                        ]
                        .where(
                          (item) =>
                              item.rect.overlaps(Offset.zero & outputSize),
                        )
                        .toList();

              return Stack(
                fit: StackFit.expand,
                children: [
                  for (final item in mappedBlocks)
                    Positioned.fromRect(
                      rect: item.rect,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 100),
                            decoration: BoxDecoration(
                              color: identical(_selection?.block, item.block)
                                  ? Colors.amber.withValues(alpha: 0.28)
                                  : Colors.lightBlueAccent.withValues(
                                      alpha: 0.08,
                                    ),
                              border: Border.all(
                                color: identical(_selection?.block, item.block)
                                    ? Colors.amber
                                    : Colors.lightBlueAccent.withValues(
                                        alpha: 0.75,
                                      ),
                                width: identical(_selection?.block, item.block)
                                    ? 2
                                    : 1,
                              ),
                            ),
                            child: VideoOcrText(
                              block: item.block,
                              selectionOffset:
                                  identical(_selection?.block, item.block)
                                  ? _selection?.offset
                                  : null,
                              matchLength: _selection?.matchLength ?? 0,
                              onLookup: (offset, position) => _lookup(
                                context,
                                item.block,
                                item.rect,
                                position,
                                offset,
                              ),
                              selected: identical(
                                _selection?.block,
                                item.block,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  SafeArea(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: DecoratedBox(
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.all(Radius.circular(18)),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_scanning)
                                  const SizedBox.square(
                                    dimension: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                else
                                  const Icon(
                                    Icons.visibility_rounded,
                                    size: 16,
                                    color: Colors.white,
                                  ),
                                const SizedBox(width: 8),
                                Text(
                                  _error == null
                                      ? 'Live OCR'
                                      : 'Live OCR paused: $_error',
                                  style: const TextStyle(color: Colors.white),
                                ),
                                const SizedBox(width: 8),
                                InkWell(
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: widget.onDismiss,
                                  child: const Padding(
                                    padding: EdgeInsets.all(2),
                                    child: Icon(
                                      Icons.close,
                                      size: 16,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The displayed text and lookup hit targets share the same paragraph layout.
/// The tap-to-look-up flow shared by the paused-frame and live OCR overlays.
mixin _VideoOcrLookup<T extends StatefulWidget> on State<T> {
  _VideoOcrSelection? _selection;
  DictionaryPopupHandle? _popup;

  /// Mining context for [sentence] in the recognized frame, or null when no
  /// frame has been recognized yet.
  Future<MiningContext?> _miningContextFor(String sentence);

  Future<void> _lookup(
    BuildContext context,
    OcrTextBlock block,
    Rect rect,
    Offset position,
    int textOffset,
  ) async {
    final renderBox = context.findRenderObject();
    final anchorOrigin = renderBox is RenderBox
        ? renderBox.localToGlobal(rect.topLeft)
        : rect.topLeft;
    final anchor = anchorOrigin & rect.size;
    final selection = _videoOcrSelectionAtOffset(block, textOffset);
    if (selection.text.isEmpty) return;
    _popup?.dismiss();
    setState(() => _selection = selection);
    final resolvedMiningContext = await _miningContextFor(block.sentence);
    if (resolvedMiningContext == null) return;
    if (!mounted || !context.mounted) {
      await resolvedMiningContext.sceneCapture?.dispose();
      return;
    }
    final miningContext = Future.value(resolvedMiningContext);
    final prefetch = DictionaryLookupPopup.prefetch(
      selection.text,
      miningContext: miningContext,
    );
    final handle = await DictionaryLookupPopup.show(
      context: context,
      anchor: anchor,
      text: selection.text,
      miningContext: miningContext,
      prefetch: prefetch,
      onMatchChanged: (count) {
        if (!mounted || count <= 0) return;
        setState(() {
          _selection = selection.copyWith(matchLength: count);
        });
      },
    );
    if (!mounted) {
      handle?.dismiss();
      return;
    }
    _popup = handle;
    if (handle == null) return;
    await handle.dismissed;
    if (mounted && identical(_popup, handle)) {
      setState(() {
        _popup = null;
        _selection = null;
      });
    }
  }
}

class VideoOcrText extends StatelessWidget {
  const VideoOcrText({
    super.key,
    required this.block,
    required this.selected,
    required this.onLookup,
    this.selectionOffset,
    this.matchLength = 0,
  });

  final OcrTextBlock block;
  final bool selected;
  final int? selectionOffset;
  final int matchLength;
  final void Function(int offset, Offset position) onLookup;

  @override
  Widget build(BuildContext context) {
    final lines = block.lines.where((line) => line.trim().isNotEmpty).toList();
    final text = lines.join('\n');
    if (text.isEmpty) return const SizedBox.shrink();
    // Inserted display line breaks are not part of the mining sentence.
    final sentenceOffsets = <int>[];
    var sentenceOffset = 0;
    for (var line = 0; line < lines.length; line++) {
      if (line > 0) sentenceOffsets.add(sentenceOffset);
      for (var i = 0; i < lines[line].length; i++) {
        sentenceOffsets.add(sentenceOffset++);
      }
    }
    sentenceOffsets.add(sentenceOffset);
    final paragraphKey = GlobalKey();
    final start = selectionOffset == null
        ? null
        : sentenceOffsets.lastIndexOf(
            selectionOffset!.clamp(0, sentenceOffset),
          );
    final end = start == null
        ? 0
        : sentenceOffsets.indexOf(
            (selectionOffset! + (matchLength > 0 ? matchLength : 1)).clamp(
              0,
              sentenceOffset,
            ),
          );
    return Center(
      child: Container(
        constraints: const BoxConstraints.expand(),
        padding: const EdgeInsets.all(2),
        child: FittedBox(
          fit: BoxFit.contain,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) {
              final paragraph = paragraphKey.currentContext?.findRenderObject();
              if (paragraph is! RenderParagraph) return;
              final offset = paragraph
                  .getPositionForOffset(
                    paragraph.globalToLocal(details.globalPosition),
                  )
                  .offset;
              onLookup(
                sentenceOffsets[offset.clamp(0, text.length - 1)],
                details.globalPosition,
              );
            },
            child: RichText(
              key: paragraphKey,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.center,
              text: TextSpan(
                style: TextStyle(
                  color: Colors.white.withValues(alpha: selected ? 0.75 : 0.10),
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  shadows: [
                    Shadow(
                      color: Colors.black.withValues(
                        alpha: selected ? 0.75 : 0.10,
                      ),
                      blurRadius: 2,
                    ),
                  ],
                ),
                children: [
                  if (start == null)
                    TextSpan(text: text)
                  else ...[
                    TextSpan(text: text.substring(0, start)),
                    TextSpan(text: text.substring(start, end)),
                    TextSpan(text: text.substring(end)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoFrameMapping {
  const _VideoFrameMapping({
    required this.imageSize,
    required this.source,
    required this.destination,
  });

  final Size imageSize;
  final Rect source;
  final Rect destination;

  factory _VideoFrameMapping.create({
    required Size imageSize,
    required Size outputSize,
    required BoxFit fit,
  }) {
    final fitted = applyBoxFit(fit, imageSize, outputSize);
    return _VideoFrameMapping(
      imageSize: imageSize,
      source: Alignment.center.inscribe(fitted.source, Offset.zero & imageSize),
      destination: Alignment.center.inscribe(
        fitted.destination,
        Offset.zero & outputSize,
      ),
    );
  }

  Rect mapBlock(OcrTextBlock block) {
    final left = block.xmin * imageSize.width;
    final top = block.ymin * imageSize.height;
    final right = block.xmax * imageSize.width;
    final bottom = block.ymax * imageSize.height;
    return Rect.fromLTRB(
      destination.left +
          (left - source.left) * destination.width / source.width,
      destination.top + (top - source.top) * destination.height / source.height,
      destination.left +
          (right - source.left) * destination.width / source.width,
      destination.top +
          (bottom - source.top) * destination.height / source.height,
    );
  }
}

class _MappedVideoOcrBlock {
  const _MappedVideoOcrBlock({required this.block, required this.rect});

  final OcrTextBlock block;
  final Rect rect;
}

class _VideoOcrSelection {
  const _VideoOcrSelection({
    required this.block,
    required this.text,
    required this.offset,
    this.matchLength = 0,
  });

  final OcrTextBlock block;
  final String text;
  final int offset;
  final int matchLength;

  _VideoOcrSelection copyWith({int? matchLength}) => _VideoOcrSelection(
    block: block,
    text: text,
    offset: offset,
    matchLength: matchLength ?? this.matchLength,
  );
}

_VideoOcrSelection _videoOcrSelectionAtOffset(
  OcrTextBlock block,
  int textOffset,
) {
  final text = block.sentence;
  if (text.isEmpty) {
    return _VideoOcrSelection(block: block, text: '', offset: 0);
  }
  var offset = textOffset.clamp(0, text.length - 1);
  while (offset < text.length && _isLookupBoundary(text[offset])) {
    offset++;
  }
  if (offset >= text.length) {
    return _VideoOcrSelection(block: block, text: '', offset: 0);
  }
  var start = offset;
  if (_isAsciiWord(text[start])) {
    while (start > 0 && _isAsciiWord(text[start - 1])) {
      start--;
    }
  }
  var end = start;
  while (end < text.length &&
      !_isLookupBoundary(text[end]) &&
      end - start < 80) {
    end++;
  }
  return _VideoOcrSelection(
    block: block,
    text: text.substring(start, end).trim(),
    offset: start,
  );
}

final _lookupBoundaryPattern = RegExp(
  r'[\u3000-\u303f\uff01-\uff65、。！？「」『』（）［］【】…‥・,.!?;:()\[\]{}]',
);
final _asciiWordPattern = RegExp(r'[A-Za-z0-9_\-]');

bool _isLookupBoundary(String character) =>
    character.trim().isEmpty || _lookupBoundaryPattern.hasMatch(character);

bool _isAsciiWord(String character) => _asciiWordPattern.hasMatch(character);
