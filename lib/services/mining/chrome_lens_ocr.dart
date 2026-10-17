import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;
import 'package:mangayomi/services/mining/ocr_image_tiling.dart';
import 'package:mangayomi/services/mining/ocr_models.dart';
import 'package:mangayomi/services/mining/proto_wire.dart';

class ChromeLensOcrResult {
  final int imageWidth;
  final int imageHeight;
  final List<OcrTextBlock> blocks;

  const ChromeLensOcrResult({
    required this.imageWidth,
    required this.imageHeight,
    required this.blocks,
  });
}

class ChromeLensOcrClient {
  static final Uri _endpoint = Uri.parse(
    'https://lensfrontend-pa.googleapis.com/v1/crupload',
  );
  static const _apiKey = 'AIzaSyDr2UxVnv_U85AbhhY8XSHSIavUW0DC-sY';
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Safari/537.36';
  static const _maxDimension = 1500;

  final http.Client _client;

  ChromeLensOcrClient({http.Client? client})
    : _client = client ?? http.Client();

  Future<ChromeLensOcrResult> recognize(
    Uint8List imageBytes, {
    String language = 'ja',
  }) async {
    final images = await _prepareImages(imageBytes);
    final blocks = <OcrTextBlock>[];
    for (final prepared in images) {
      final request = _buildRequest(prepared.image, language);
      final response = await _client
          .post(
            _endpoint,
            headers: const {
              'Content-Type': 'application/x-protobuf',
              'X-Goog-Api-Key': _apiKey,
              'User-Agent': _userAgent,
            },
            body: request,
          )
          .timeout(const Duration(seconds: 60));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'Google Lens OCR failed (${response.statusCode}): '
          '${utf8.decode(response.bodyBytes, allowMalformed: true)}',
        );
      }
      final result = decodeResponse(
        response.bodyBytes,
        imageWidth: prepared.image.originalWidth,
        imageHeight: prepared.image.originalHeight,
        language: language,
      );
      blocks.addAll(remapOcrBlocksFromTile(result.blocks, prepared.tile));
    }
    final first = images.first;
    return ChromeLensOcrResult(
      imageWidth: first.image.originalWidth,
      imageHeight: first.image.originalHeight,
      blocks: blocks,
    );
  }

  ChromeLensOcrResult decodeResponse(
    Uint8List bytes, {
    required int imageWidth,
    required int imageHeight,
    String language = 'ja',
  }) {
    final root = ProtoWireMessage.decode(bytes);
    final objects = root.message(2);
    final text = objects?.message(3);
    final layout = text?.message(1);
    final blocks = <OcrTextBlock>[];

    for (final paragraph in layout?.messages(1) ?? const <ProtoWireMessage>[]) {
      final lines = <String>[];
      final lineGeometries = <OcrLineGeometry>[];
      final lineRects = <_NormalizedRect>[];
      var verticalVotes = 0;

      for (final line in paragraph.messages(2)) {
        final words = line.messages(1).map((word) {
          final value = word.string(2);
          final separator = word.string(3);
          return '$value$separator';
        }).join();
        final normalizedText = _normalizeText(words, language);
        if (normalizedText.isEmpty) continue;
        final geometry = _readGeometry(line.message(2));
        if (geometry == null) continue;
        final rect = geometry.rect;
        lines.add(normalizedText);
        lineRects.add(rect);
        lineGeometries.add(
          OcrLineGeometry(
            xmin: rect.left,
            ymin: rect.top,
            xmax: rect.right,
            ymax: rect.bottom,
            rotation: geometry.rotation,
          ),
        );
        if (geometry.isVertical) verticalVotes++;
      }

      if (lines.isEmpty) continue;
      final paragraphGeometry = _readGeometry(paragraph.message(3));
      final rect = paragraphGeometry?.rect ?? _union(lineRects);
      if (rect == null || rect.width <= 0 || rect.height <= 0) continue;
      blocks.add(
        OcrTextBlock(
          xmin: rect.left,
          ymin: rect.top,
          xmax: rect.right,
          ymax: rect.bottom,
          lines: lines,
          vertical:
              paragraphGeometry?.isVertical == true ||
              verticalVotes > lines.length / 2,
          lineGeometries: lineGeometries,
          language: language,
        ),
      );
    }

    return ChromeLensOcrResult(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      blocks: blocks,
    );
  }

  void close() => _client.close();

  Future<List<_PreparedImageTile>> _prepareImages(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final originalWidth = frame.image.width;
    final originalHeight = frame.image.height;
    codec.dispose();
    final tiles = planVerticalOcrTiles(
      width: originalWidth,
      height: originalHeight,
    );

    final largest = math.max(originalWidth, originalHeight);
    if (tiles.length == 1 && largest <= _maxDimension) {
      final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      if (png == null) throw StateError('Could not encode image for OCR');
      return [
        _PreparedImageTile(
          image: _PreparedImage(
            bytes: png.buffer.asUint8List(),
            width: originalWidth,
            height: originalHeight,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
          ),
          tile: tiles.single,
        ),
      ];
    }

    final prepared = <_PreparedImageTile>[];
    try {
      for (final tile in tiles) {
        final scale = math.min(
          1.0,
          _maxDimension / math.max(originalWidth, tile.height),
        );
        final width = math.max(1, (originalWidth * scale).round());
        final height = math.max(1, (tile.height * scale).round());
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawImageRect(
          frame.image,
          ui.Rect.fromLTWH(
            0,
            tile.top.toDouble(),
            originalWidth.toDouble(),
            tile.height.toDouble(),
          ),
          ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          ui.Paint()..filterQuality = ui.FilterQuality.medium,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(width, height);
        picture.dispose();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (png == null) throw StateError('Could not encode OCR image tile');
        prepared.add(
          _PreparedImageTile(
            image: _PreparedImage(
              bytes: png.buffer.asUint8List(),
              width: width,
              height: height,
              originalWidth: originalWidth,
              originalHeight: originalHeight,
            ),
            tile: tile,
          ),
        );
      }
      return prepared;
    } finally {
      frame.image.dispose();
    }
  }

  Uint8List _buildRequest(_PreparedImage image, String language) {
    final random = math.Random.secure();
    final uuid =
        ((random.nextInt(0x7fffffff) << 32) | random.nextInt(0xffffffff)) &
        0x7fffffffffffffff;
    final writer = _ProtoWriter();
    writer.message(1, (objects) {
      objects.message(1, (context) {
        context.message(3, (requestId) {
          requestId.uint(1, uuid);
          requestId.uint(2, 1);
          requestId.uint(3, 1);
        });
        context.message(4, (client) {
          client.uint(1, 3);
          client.uint(2, 4);
          client.message(4, (locale) {
            locale.string(1, language);
            locale.string(2, 'US');
            locale.string(3, 'America/New_York');
          });
        });
      });
      objects.message(3, (data) {
        data.message(1, (payload) => payload.bytes(1, image.bytes));
        data.message(3, (metadata) {
          metadata.uint(1, image.width);
          metadata.uint(2, image.height);
        });
      });
    });
    return writer.takeBytes();
  }

  static String _normalizeText(String text, String language) {
    final trimmed = text.trim();
    if (language == 'ja' || language == 'zh') {
      return trimmed.replaceAll(RegExp(r'\s+'), '');
    }
    return trimmed.replaceAll(RegExp(r'\s+'), ' ');
  }

  static _LensGeometry? _readGeometry(ProtoWireMessage? geometry) {
    final box = geometry?.message(1);
    if (box == null) return null;
    final centerX = box.float32(1) ?? 0;
    final centerY = box.float32(2) ?? 0;
    final width = box.float32(3) ?? 0;
    final height = box.float32(4) ?? 0;
    final rotation = box.float32(5) ?? 0;
    if (width <= 0 || height <= 0) return null;
    final cos = math.cos(rotation).abs();
    final sin = math.sin(rotation).abs();
    final halfWidth = (width * cos + height * sin) / 2;
    final halfHeight = (width * sin + height * cos) / 2;
    final rect = _NormalizedRect(
      left: (centerX - halfWidth).clamp(0, 1).toDouble(),
      top: (centerY - halfHeight).clamp(0, 1).toDouble(),
      right: (centerX + halfWidth).clamp(0, 1).toDouble(),
      bottom: (centerY + halfHeight).clamp(0, 1).toDouble(),
    );
    final quarterTurn = (rotation.abs() - math.pi / 2).abs() < 0.5;
    return _LensGeometry(
      rect: rect,
      rotation: rotation,
      isVertical: quarterTurn || rect.height > rect.width * 1.25,
    );
  }

  static _NormalizedRect? _union(List<_NormalizedRect> rects) {
    if (rects.isEmpty) return null;
    return _NormalizedRect(
      left: rects.map((rect) => rect.left).reduce(math.min),
      top: rects.map((rect) => rect.top).reduce(math.min),
      right: rects.map((rect) => rect.right).reduce(math.max),
      bottom: rects.map((rect) => rect.bottom).reduce(math.max),
    );
  }
}

class _PreparedImage {
  final Uint8List bytes;
  final int width;
  final int height;
  final int originalWidth;
  final int originalHeight;

  const _PreparedImage({
    required this.bytes,
    required this.width,
    required this.height,
    required this.originalWidth,
    required this.originalHeight,
  });
}

class _PreparedImageTile {
  final _PreparedImage image;
  final OcrVerticalTile tile;

  const _PreparedImageTile({required this.image, required this.tile});
}

class _LensGeometry {
  final _NormalizedRect rect;
  final double rotation;
  final bool isVertical;

  const _LensGeometry({
    required this.rect,
    required this.rotation,
    required this.isVertical,
  });
}

class _NormalizedRect {
  final double left;
  final double top;
  final double right;
  final double bottom;

  const _NormalizedRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  double get width => right - left;
  double get height => bottom - top;
}

class _ProtoWriter {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  void uint(int field, int value) {
    _varint((field << 3) | 0);
    _varint(value);
  }

  void string(int field, String value) => bytes(field, utf8.encode(value));

  void bytes(int field, List<int> value) {
    _varint((field << 3) | 2);
    _varint(value.length);
    _bytes.add(value);
  }

  void message(int field, void Function(_ProtoWriter writer) build) {
    final nested = _ProtoWriter();
    build(nested);
    bytes(field, nested.takeBytes());
  }

  Uint8List takeBytes() => _bytes.takeBytes();

  void _varint(int value) {
    var remaining = value;
    while (remaining > 0x7f) {
      _bytes.addByte((remaining & 0x7f) | 0x80);
      remaining >>= 7;
    }
    _bytes.addByte(remaining);
  }
}
