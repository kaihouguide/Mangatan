import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:mangayomi/modules/manga/reader/u_chap_data_preload.dart';
import 'package:mangayomi/src/rust/api/image.dart';
import 'package:mangayomi/src/rust/frb_generated.dart';
import 'package:mangayomi/utils/extensions/others.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
part 'crop_borders_provider.g.dart';

@Riverpod(keepAlive: false)
Future<Uint8List?> cropBorders(
  Ref ref, {
  required UChapDataPreload data,
  required bool cropBorder,
}) async {
  Uint8List? imageBytes;

  if (cropBorder) {
    imageBytes = await data.getImageBytes;

    if (imageBytes == null) {
      return null;
    }

    return imgCropIsolate.process(imageBytes);
  }
  return null;
}

/// Crops reader pages on one long-lived Rust worker isolate.
///
/// The reader preloads several pages at once, so the worker is started once
/// and shared. If it fails to start or dies, every waiting crop resolves to
/// null (the page shows uncropped) and the next request starts a new worker.
class ImageCropIsolate {
  ImageCropIsolate({this.entryPoint = _rustIsolateEntryPoint});

  /// The worker's entry point; tests replace it to avoid the Rust library.
  @visibleForTesting
  final void Function(SendPort mainSendPort) entryPoint;
  final Set<Completer<Uint8List?>> _pending = {};
  Future<SendPort?>? _worker;
  Isolate? _isolate;
  ReceivePort? _receivePort;
  ReceivePort? _exitPort;

  Future<void> start() => _workerPort();

  Future<SendPort?> _workerPort() => _worker ??= _spawn();

  Future<SendPort?> _spawn() async {
    final receivePort = ReceivePort();
    final exitPort = ReceivePort();
    final ready = Completer<SendPort?>();
    _receivePort = receivePort;
    _exitPort = exitPort;
    receivePort.listen((message) {
      if (message is SendPort && !ready.isCompleted) ready.complete(message);
    });
    // Uncaught errors are fatal to the worker, so its exit covers a failed
    // RustLib.init as well as a crash mid-request.
    exitPort.listen((_) {
      if (!ready.isCompleted) ready.complete(null);
      _reset();
    });
    try {
      _isolate = await Isolate.spawn(
        entryPoint,
        receivePort.sendPort,
        onExit: exitPort.sendPort,
      );
    } catch (error) {
      if (kDebugMode) print('Image crop isolate failed to start: $error');
      _reset();
      return null;
    }
    return ready.future;
  }

  static Future<void> _rustIsolateEntryPoint(SendPort mainSendPort) async {
    await RustLib.init();

    final receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);
    receivePort.listen((message) async {
      if (message is Map<String, dynamic>) {
        final responsePort = message['responsePort'] as SendPort;
        try {
          final imageBytes = message['imageBytes'] as Uint8List;
          final croppedImage = processCropImage(image: imageBytes);
          responsePort.send({'success': true, 'data': croppedImage});
        } catch (e) {
          responsePort.send({'success': false, 'error': e.toString()});
        }
      } else if (message == 'dispose') {
        RustLib.dispose();
        receivePort.close();
      }
    });
  }

  Future<Uint8List?> process(Uint8List imageBytes) async {
    final worker = await _workerPort();
    if (worker == null) {
      if (kDebugMode) print('Image crop isolate is not running');
      return null;
    }

    final responsePort = ReceivePort();
    final completer = Completer<Uint8List?>();
    _pending.add(completer);
    responsePort.listen((response) {
      if (completer.isCompleted) return;
      if (response is Map && response['success'] == true) {
        completer.complete(response['data'] as Uint8List?);
      } else {
        if (kDebugMode) {
          print(
            'Image cropping failed: ${response is Map ? response['error'] : response}',
          );
        }
        completer.complete(null);
      }
    });
    worker.send({
      'imageBytes': imageBytes,
      'responsePort': responsePort.sendPort,
    });
    try {
      return await completer.future;
    } finally {
      _pending.remove(completer);
      responsePort.close();
    }
  }

  Future<void> stop() async {
    final worker = _worker;
    if (worker == null) return;
    (await worker)?.send('dispose');
    _reset();
  }

  /// Tears the worker down and resolves every waiting crop to null.
  void _reset() {
    _isolate?.kill(priority: Isolate.immediate);
    _receivePort?.close();
    _exitPort?.close();
    _isolate = null;
    _receivePort = null;
    _exitPort = null;
    _worker = null;
    for (final completer in _pending.toList()) {
      if (!completer.isCompleted) completer.complete(null);
    }
  }
}

final imgCropIsolate = ImageCropIsolate();
