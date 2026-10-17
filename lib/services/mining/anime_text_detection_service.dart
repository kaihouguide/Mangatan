import 'dart:async';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter_litert/flutter_litert.dart';
import 'package:image/image.dart' as image_lib;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

enum AnimeTextModelStatus { missing, importing, ready, error }

/// Runs a LiteRT export of deepghs/AnimeText_yolo.
///
/// `tool/export_animetext_litert.py` creates the supported file from the
/// pinned nano checkpoint using the user's Hugging Face account access.
class AnimeTextDetectionService {
  AnimeTextDetectionService._();

  static final instance = AnimeTextDetectionService._();

  static const upstreamRevision = 'a180c191bfdb9f0e31b57e7de567e7b6bac50f84';
  static const upstreamModel = 'yolo12n_animetext';
  static const _filename = 'animetext_yolo12n.tflite';

  final status = ValueNotifier<AnimeTextModelStatus>(
    AnimeTextModelStatus.missing,
  );
  Interpreter? _interpreter;
  Future<void> _serialTail = Future<void>.value();

  Future<File> _modelFile() async {
    final support = await getApplicationSupportDirectory();
    return File(path.join(support.path, 'ocr_models', _filename));
  }

  Future<bool> isModelReady() async {
    final file = await _modelFile();
    if (status.value == AnimeTextModelStatus.ready && await file.exists()) {
      return true;
    }
    if (!await file.exists()) {
      status.value = AnimeTextModelStatus.missing;
      return false;
    }
    try {
      final valid = _hasSupportedShapes(file);
      status.value = valid
          ? AnimeTextModelStatus.ready
          : AnimeTextModelStatus.error;
      return valid;
    } catch (_) {
      status.value = AnimeTextModelStatus.error;
      return false;
    }
  }

  /// Opens [model] only to check its tensor shapes, always releasing the
  /// native interpreter even when reading them fails.
  static bool _hasSupportedShapes(File model) {
    final interpreter = Interpreter.fromFile(model);
    try {
      return animeTextModelShapesSupported(
        inputShape: interpreter.getInputTensor(0).shape,
        outputShape: interpreter.getOutputTensor(0).shape,
      );
    } finally {
      interpreter.close();
    }
  }

  Future<void> importModel(File source) async {
    status.value = AnimeTextModelStatus.importing;
    final target = await _modelFile();
    final partial = File('${target.path}.partial');
    try {
      await target.parent.create(recursive: true);
      if (await partial.exists()) await partial.delete();
      await source.openRead().pipe(partial.openWrite());
      final valid = _hasSupportedShapes(partial);
      if (!valid) {
        throw const FormatException(
          'This is not a supported AnimeText YOLO LiteRT export',
        );
      }
      _interpreter?.close();
      _interpreter = null;
      if (await target.exists()) await target.delete();
      await partial.rename(target.path);
      status.value = AnimeTextModelStatus.ready;
    } catch (_) {
      status.value = AnimeTextModelStatus.error;
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  Future<void> deleteModel() async {
    _interpreter?.close();
    _interpreter = null;
    final target = await _modelFile();
    if (await target.exists()) await target.delete();
    status.value = AnimeTextModelStatus.missing;
  }

  Future<List<Rect>> detect(Uint8List encodedImage) =>
      _serial(() => _detect(encodedImage));

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _serialTail = _serialTail.then((_) async {
      try {
        result.complete(await action());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  Future<List<Rect>> _detect(Uint8List encodedImage) async {
    final prepared = await compute(_prepareAnimeTextInput, encodedImage);
    final model = await _modelFile();
    if (!await model.exists()) {
      throw StateError('Import the AnimeText LiteRT model in OCR settings');
    }
    final interpreter = _interpreter ??= Interpreter.fromFile(model);
    interpreter.allocateTensors();
    final tensor = interpreter.getInputTensor(0);
    if (tensor.type != TensorType.float32) {
      throw StateError('AnimeText input must be float32');
    }
    final nchw = tensor.shape.length == 4 && tensor.shape[1] == 3;
    final input = nchw ? _nhwcToNchw(prepared.pixels) : prepared.pixels;
    tensor.data = input.buffer.asUint8List();
    interpreter.invoke();
    final outputTensor = interpreter.getOutputTensor(0);
    if (outputTensor.type != TensorType.float32) {
      throw StateError('AnimeText output must be float32');
    }
    final bytes = outputTensor.data;
    final output = Float32List.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes ~/ Float32List.bytesPerElement,
    );
    return parseAnimeTextOutput(
      output,
      outputShape: outputTensor.shape,
      sourceWidth: prepared.sourceWidth,
      sourceHeight: prepared.sourceHeight,
    );
  }
}

@visibleForTesting
bool animeTextModelShapesSupported({
  required List<int> inputShape,
  required List<int> outputShape,
}) {
  final inputOkay =
      inputShape.length == 4 &&
      inputShape.first == 1 &&
      (inputShape[1] == 3 || inputShape.last == 3);
  if (!inputOkay || outputShape.length != 3 || outputShape.first != 1) {
    return false;
  }
  return outputShape.contains(5) || outputShape.last == 6;
}

typedef _PreparedAnimeTextInput = ({
  Float32List pixels,
  int sourceWidth,
  int sourceHeight,
});

_PreparedAnimeTextInput _prepareAnimeTextInput(Uint8List encodedImage) {
  final source = image_lib.decodeImage(encodedImage);
  if (source == null) throw const FormatException('Unsupported page image');
  const size = 640;
  final scale = size / source.width < size / source.height
      ? size / source.width
      : size / source.height;
  final width = (source.width * scale).round();
  final height = (source.height * scale).round();
  final resized = image_lib.copyResize(
    source,
    width: width,
    height: height,
    interpolation: image_lib.Interpolation.linear,
  );
  final canvas = image_lib.Image(width: size, height: size);
  image_lib.fill(canvas, color: image_lib.ColorRgb8(114, 114, 114));
  image_lib.compositeImage(
    canvas,
    resized,
    dstX: (size - width) ~/ 2,
    dstY: (size - height) ~/ 2,
  );
  final pixels = Float32List(size * size * 3);
  var offset = 0;
  for (final pixel in canvas) {
    pixels[offset++] = pixel.r / 255;
    pixels[offset++] = pixel.g / 255;
    pixels[offset++] = pixel.b / 255;
  }
  return (
    pixels: pixels,
    sourceWidth: source.width,
    sourceHeight: source.height,
  );
}

Float32List _nhwcToNchw(Float32List source) {
  const area = 640 * 640;
  final result = Float32List(source.length);
  for (var pixel = 0; pixel < area; pixel++) {
    result[pixel] = source[pixel * 3];
    result[area + pixel] = source[pixel * 3 + 1];
    result[area * 2 + pixel] = source[pixel * 3 + 2];
  }
  return result;
}

@visibleForTesting
List<Rect> parseAnimeTextOutput(
  Float32List output, {
  required List<int> outputShape,
  required int sourceWidth,
  required int sourceHeight,
  double confidenceThreshold = .251,
  double iouThreshold = .35,
}) {
  if (sourceWidth <= 0 || sourceHeight <= 0 || outputShape.length != 3) {
    return const [];
  }
  final rows = <({double x, double y, double w, double h, double score})>[];
  if (outputShape[1] == 5) {
    final count = outputShape[2];
    if (output.length < count * 5) return const [];
    for (var i = 0; i < count; i++) {
      rows.add((
        x: output[i],
        y: output[count + i],
        w: output[count * 2 + i],
        h: output[count * 3 + i],
        score: output[count * 4 + i],
      ));
    }
  } else if (outputShape[2] == 5) {
    final count = outputShape[1];
    if (output.length < count * 5) return const [];
    for (var i = 0; i < count; i++) {
      final offset = i * 5;
      rows.add((
        x: output[offset],
        y: output[offset + 1],
        w: output[offset + 2],
        h: output[offset + 3],
        score: output[offset + 4],
      ));
    }
  } else if (outputShape[2] == 6) {
    final count = outputShape[1];
    if (output.length < count * 6) return const [];
    for (var i = 0; i < count; i++) {
      final offset = i * 6;
      final left = output[offset];
      final top = output[offset + 1];
      final right = output[offset + 2];
      final bottom = output[offset + 3];
      rows.add((
        x: (left + right) / 2,
        y: (top + bottom) / 2,
        w: right - left,
        h: bottom - top,
        score: output[offset + 4],
      ));
    }
  } else {
    return const [];
  }

  const size = 640.0;
  final scale = size / sourceWidth < size / sourceHeight
      ? size / sourceWidth
      : size / sourceHeight;
  final padX = (size - sourceWidth * scale) / 2;
  final padY = (size - sourceHeight * scale) / 2;
  final boxes = <({Rect rect, double score})>[];
  for (final row in rows) {
    if (!row.score.isFinite || row.score < confidenceThreshold) continue;
    final normalized =
        row.x.abs() <= 2 &&
        row.y.abs() <= 2 &&
        row.w.abs() <= 2 &&
        row.h.abs() <= 2;
    final factor = normalized ? size : 1.0;
    final left = (row.x - row.w / 2) * factor;
    final top = (row.y - row.h / 2) * factor;
    final right = (row.x + row.w / 2) * factor;
    final bottom = (row.y + row.h / 2) * factor;
    final rect = Rect.fromLTRB(
      ((left - padX) / scale / sourceWidth).clamp(0.0, 1.0).toDouble(),
      ((top - padY) / scale / sourceHeight).clamp(0.0, 1.0).toDouble(),
      ((right - padX) / scale / sourceWidth).clamp(0.0, 1.0).toDouble(),
      ((bottom - padY) / scale / sourceHeight).clamp(0.0, 1.0).toDouble(),
    );
    if (!rect.isEmpty && rect.width * rect.height >= .00002) {
      boxes.add((rect: rect, score: row.score));
    }
  }
  boxes.sort((a, b) => b.score.compareTo(a.score));
  final kept = <({Rect rect, double score})>[];
  for (final box in boxes) {
    if (kept.any((other) => _iou(box.rect, other.rect) > iouThreshold)) {
      continue;
    }
    kept.add(box);
  }
  final result = kept.map((item) => item.rect).toList();
  result.sort((a, b) {
    final row = a.top - b.top;
    if (row.abs() > .04) return row.sign.toInt();
    return a.left.compareTo(b.left);
  });
  return result;
}

double _iou(Rect a, Rect b) {
  final overlap = a.intersect(b);
  if (overlap.isEmpty) return 0;
  final intersection = overlap.width * overlap.height;
  return intersection /
      (a.width * a.height + b.width * b.height - intersection);
}
