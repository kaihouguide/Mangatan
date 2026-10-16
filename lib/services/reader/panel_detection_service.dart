import 'dart:io';
import 'dart:ui' show Rect;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_litert/flutter_litert.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as image_lib;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

enum PanelDetectionKind { panel, speechBubble }

class PanelDetection {
  const PanelDetection({
    required this.rect,
    required this.confidence,
    required this.kind,
  });

  final Rect rect;
  final double confidence;
  final PanelDetectionKind kind;
}

enum PanelModelStatus { missing, downloading, ready, error }

/// Downloads and runs the same manga panel/speech-bubble detector used by
/// Chimahon. The model is deliberately not bundled: panel navigation stays
/// opt-in and the normal application download remains small.
class PanelDetectionService {
  PanelDetectionService._();

  static final instance = PanelDetectionService._();

  static const modelRevision = '535bbe1fc1e922d2108f918cd1bce29ba3516196';
  static const modelSha256 =
      'b1a7d8d4492e04a777ae0d3efd9dc1fbd6e8f361971eadb813279ce3dfd1b464';
  static const modelUrl =
      'https://huggingface.co/leoxs22/manga-panel-detector-yolo26n/'
      'resolve/$modelRevision/manga_panel_detector_int8.tflite';
  static const _modelFilename = 'manga_panel_detector_int8.tflite';
  static const _inputSize = 640;

  final status = ValueNotifier<PanelModelStatus>(PanelModelStatus.missing);
  Interpreter? _interpreter;
  Future<File>? _download;

  Future<File> _modelFile() async {
    final support = await getApplicationSupportDirectory();
    return File(path.join(support.path, 'panel_detection', _modelFilename));
  }

  Future<bool> isModelReady() async {
    final file = await _modelFile();
    final valid = await _isValid(file);
    status.value = valid ? PanelModelStatus.ready : PanelModelStatus.missing;
    return valid;
  }

  Future<File> ensureModel() => _download ??= _ensureModel().whenComplete(() {
    _download = null;
  });

  Future<File> _ensureModel() async {
    final target = await _modelFile();
    if (await _isValid(target)) {
      status.value = PanelModelStatus.ready;
      return target;
    }
    status.value = PanelModelStatus.downloading;
    final partial = File('${target.path}.partial');
    try {
      await target.parent.create(recursive: true);
      if (await partial.exists()) await partial.delete();
      // ensureModel shares one in-flight download; a stalled connection
      // would otherwise keep every caller waiting forever.
      final response = await http
          .get(Uri.parse(modelUrl))
          .timeout(const Duration(minutes: 5));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Panel model download failed (${response.statusCode})',
          uri: Uri.parse(modelUrl),
        );
      }
      await partial.writeAsBytes(response.bodyBytes, flush: true);
      if (!await _isValid(partial)) {
        throw const FormatException('Panel model integrity check failed');
      }
      if (await target.exists()) await target.delete();
      await partial.rename(target.path);
      status.value = PanelModelStatus.ready;
      return target;
    } catch (_) {
      status.value = PanelModelStatus.error;
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  Future<void> deleteModel() async {
    _interpreter?.close();
    _interpreter = null;
    final file = await _modelFile();
    if (await file.exists()) await file.delete();
    status.value = PanelModelStatus.missing;
  }

  Future<bool> _isValid(File file) async {
    try {
      if (!await file.exists()) return false;
      final digest = await sha256.bind(file.openRead()).first;
      return digest.toString() == modelSha256;
    } on FileSystemException {
      // An unreadable model is unusable; report it as missing so the user
      // can download it again instead of seeing a settings page that never
      // finishes loading.
      return false;
    }
  }

  Future<List<PanelDetection>> detect(Uint8List encodedImage) async {
    final prepared = await compute(_preparePanelInput, encodedImage);
    final model = await ensureModel();
    final interpreter = _interpreter ??= Interpreter.fromFile(model);
    interpreter.allocateTensors();

    final input = prepared.pixels;
    final inputTensor = interpreter.getInputTensor(0);
    if (inputTensor.type == TensorType.float32) {
      inputTensor.data = input.buffer.asUint8List();
    } else if (inputTensor.type == TensorType.uint8) {
      final bytes = Uint8List(input.length);
      for (var i = 0; i < input.length; i++) {
        bytes[i] = (input[i] * 255).round().clamp(0, 255);
      }
      inputTensor.data = bytes;
    } else {
      throw StateError('Unsupported panel model input: ${inputTensor.type}');
    }
    interpreter.invoke();
    final outputTensor = interpreter.getOutputTensor(0);
    if (outputTensor.type != TensorType.float32) {
      throw StateError('Unsupported panel model output: ${outputTensor.type}');
    }
    final bytes = outputTensor.data;
    final output = Float32List.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes ~/ Float32List.bytesPerElement,
    );
    return parsePanelDetections(
      output,
      sourceWidth: prepared.sourceWidth,
      sourceHeight: prepared.sourceHeight,
    );
  }
}

typedef _PreparedPanelInput = ({
  Float32List pixels,
  int sourceWidth,
  int sourceHeight,
});

_PreparedPanelInput _preparePanelInput(Uint8List encodedImage) {
  final source = image_lib.decodeImage(encodedImage);
  if (source == null) throw const FormatException('Unsupported page image');
  const inputSize = PanelDetectionService._inputSize;
  final scale = inputSize / source.width > inputSize / source.height
      ? inputSize / source.height
      : inputSize / source.width;
  final width = (source.width * scale).round();
  final height = (source.height * scale).round();
  final resized = image_lib.copyResize(
    source,
    width: width,
    height: height,
    interpolation: image_lib.Interpolation.linear,
  );
  final canvas = image_lib.Image(width: inputSize, height: inputSize);
  image_lib.fill(canvas, color: image_lib.ColorRgb8(114, 114, 114));
  image_lib.compositeImage(
    canvas,
    resized,
    dstX: (inputSize - width) ~/ 2,
    dstY: (inputSize - height) ~/ 2,
  );
  final pixels = Float32List(inputSize * inputSize * 3);
  var offset = 0;
  for (final pixel in canvas) {
    pixels[offset++] = pixel.r / 255.0;
    pixels[offset++] = pixel.g / 255.0;
    pixels[offset++] = pixel.b / 255.0;
  }
  return (
    pixels: pixels,
    sourceWidth: source.width,
    sourceHeight: source.height,
  );
}

@visibleForTesting
List<PanelDetection> parsePanelDetections(
  Float32List output, {
  required int sourceWidth,
  required int sourceHeight,
}) {
  if (output.length % 6 != 0 || sourceWidth <= 0 || sourceHeight <= 0) {
    return const [];
  }
  final scale = 640 / sourceWidth > 640 / sourceHeight
      ? 640 / sourceHeight
      : 640 / sourceWidth;
  final padX = (640 - sourceWidth * scale) / 2;
  final padY = (640 - sourceHeight * scale) / 2;
  final candidates = <PanelDetection>[];
  for (var i = 0; i < output.length; i += 6) {
    final confidence = output[i + 4];
    final kind = output[i + 5].round() == 1
        ? PanelDetectionKind.speechBubble
        : PanelDetectionKind.panel;
    if (confidence < (kind == PanelDetectionKind.panel ? .25 : .4)) continue;
    final left = ((output[i] * 640 - padX) / scale / sourceWidth)
        .clamp(0.0, 1.0)
        .toDouble();
    final top = ((output[i + 1] * 640 - padY) / scale / sourceHeight)
        .clamp(0.0, 1.0)
        .toDouble();
    final right = ((output[i + 2] * 640 - padX) / scale / sourceWidth)
        .clamp(0.0, 1.0)
        .toDouble();
    final bottom = ((output[i + 3] * 640 - padY) / scale / sourceHeight)
        .clamp(0.0, 1.0)
        .toDouble();
    final rect = Rect.fromLTRB(left, top, right, bottom);
    if (rect.isEmpty ||
        (kind == PanelDetectionKind.panel && rect.width * rect.height < .02)) {
      continue;
    }
    candidates.add(
      PanelDetection(rect: rect, confidence: confidence, kind: kind),
    );
  }
  final filtered = _nonMaximumSuppression(candidates, .8);
  return orderPanelDetections(filtered);
}

List<PanelDetection> _nonMaximumSuppression(
  List<PanelDetection> detections,
  double threshold,
) {
  final sorted = [...detections]
    ..sort((a, b) => b.confidence.compareTo(a.confidence));
  final kept = <PanelDetection>[];
  for (final detection in sorted) {
    if (kept.any(
      (other) =>
          other.kind == detection.kind &&
          _intersectionOverUnion(other.rect, detection.rect) > threshold,
    )) {
      continue;
    }
    kept.add(detection);
  }
  return kept;
}

double _intersectionOverUnion(Rect a, Rect b) {
  final overlap = a.intersect(b);
  if (overlap.isEmpty) return 0;
  final intersection = overlap.width * overlap.height;
  return intersection /
      (a.width * a.height + b.width * b.height - intersection);
}

/// Produces a stable top-to-bottom reading order. Speech bubbles are used to
/// split very wide panels into focus regions, matching Chimahon's useful
/// full-width-panel behavior while keeping ordinary panels as the main stops.
@visibleForTesting
List<PanelDetection> orderPanelDetections(List<PanelDetection> detections) {
  final panels = detections
      .where((item) => item.kind == PanelDetectionKind.panel)
      .toList();
  final bubbles = detections
      .where((item) => item.kind == PanelDetectionKind.speechBubble)
      .toList();
  panels.sort((a, b) {
    final rowDelta = a.rect.top - b.rect.top;
    if (rowDelta.abs() > .08) return rowDelta.sign.toInt();
    return a.rect.left.compareTo(b.rect.left);
  });
  final result = <PanelDetection>[];
  for (final panel in panels) {
    final contained =
        bubbles.where((bubble) => panel.rect.overlaps(bubble.rect)).toList()
          ..sort((a, b) {
            final rowDelta = a.rect.center.dy - b.rect.center.dy;
            if (rowDelta.abs() > panel.rect.height * .08) {
              return rowDelta.sign.toInt();
            }
            return a.rect.left.compareTo(b.rect.left);
          });
    if (panel.rect.width >= .85 && contained.length > 1) {
      for (final bubble in contained) {
        final padded = bubble.rect.inflate(.05).intersect(panel.rect);
        result.add(
          PanelDetection(
            rect: Rect.fromCenter(
              center: padded.center,
              width: padded.width.clamp(.35, panel.rect.width),
              height: padded.height.clamp(.25, panel.rect.height),
            ).intersect(panel.rect),
            confidence: bubble.confidence,
            kind: PanelDetectionKind.panel,
          ),
        );
      }
    } else {
      result.add(panel);
    }
  }
  return result;
}
