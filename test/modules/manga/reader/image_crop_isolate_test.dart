import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/modules/manga/reader/providers/crop_borders_provider.dart';

const _timeout = Duration(seconds: 10);

void _failingWorker(SendPort mainSendPort) {
  throw StateError('Rust library unavailable');
}

/// Echoes each image reversed, standing in for the Rust crop.
void _echoWorker(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((message) {
    if (message is! Map) return;
    final bytes = message['imageBytes'] as Uint8List;
    (message['responsePort'] as SendPort).send({
      'success': true,
      'data': Uint8List.fromList(bytes.reversed.toList()),
    });
  });
}

/// Dies on the first request without answering it.
void _dyingWorker(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((message) {
    if (message is Map) Isolate.exit();
  });
}

void main() {
  test('a worker that cannot start yields null instead of hanging', () async {
    final cropper = ImageCropIsolate(entryPoint: _failingWorker);

    expect(
      await cropper.process(Uint8List.fromList([1])).timeout(_timeout),
      isNull,
    );
    // A later page retries rather than staying stuck on the dead start.
    expect(
      await cropper.process(Uint8List.fromList([2])).timeout(_timeout),
      isNull,
    );
  });

  test('concurrent pages share one worker and get their own result', () async {
    final cropper = ImageCropIsolate(entryPoint: _echoWorker);

    final results = await Future.wait([
      cropper.process(Uint8List.fromList([1, 2])),
      cropper.process(Uint8List.fromList([3, 4])),
      cropper.process(Uint8List.fromList([5, 6])),
    ]).timeout(_timeout);

    expect(results, [
      [2, 1],
      [4, 3],
      [6, 5],
    ]);
    await cropper.stop();
  });

  test('a worker dying mid-request releases the waiting page', () async {
    final cropper = ImageCropIsolate(entryPoint: _dyingWorker);

    expect(
      await cropper.process(Uint8List.fromList([1])).timeout(_timeout),
      isNull,
    );
  });
}
