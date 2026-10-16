import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef ScreenAiDownloadProgress = void Function(int received, int total);

class ScreenAiComponentManager {
  static const version = '153.01';
  static const downloadSize = 75483214;
  static const archiveSha256 =
      '6e3f9bb7cf6c5e4e0160c07cc248377cf7fe84b32ff33cd7de48a1876914ad99';
  static const _instance = 'bj-bt89sXk4BYMB8wkg3fPf-hLMv8zzX3kihh2kUrZkC';
  static final downloadUri = Uri.parse(
    'https://chrome-infra-packages.appspot.com/dl/chromium/third_party/'
    'screen-ai/windows-amd64/+/$_instance',
  );

  static Future<Directory> _root() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'ocr_models', 'screen_ai'));
  }

  static Future<Directory> managedComponentDirectory() async {
    final root = await _root();
    return Directory(p.join(root.path, version, 'resources'));
  }

  static bool isValidComponentDirectory(Directory directory) {
    final library = File(p.join(directory.path, 'chrome_screen_ai.dll'));
    final fileList = File(p.join(directory.path, 'files_list_ocr.txt'));
    if (!library.existsSync() || !fileList.existsSync()) return false;
    try {
      final requiredFiles = fileList
          .readAsLinesSync()
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList(growable: false);
      return requiredFiles.isNotEmpty &&
          requiredFiles.every(
            (relative) =>
                p.isRelative(relative) &&
                !p.split(relative).contains('..') &&
                File(p.join(directory.path, relative)).existsSync(),
          );
    } on FileSystemException {
      return false;
    }
  }

  static Future<Directory?> installedComponentDirectory() async {
    final directory = await managedComponentDirectory();
    return isValidComponentDirectory(directory) ? directory : null;
  }

  static Future<Directory> install({
    ScreenAiDownloadProgress? onProgress,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'Managed ScreenAI is currently available on Windows',
      );
    }
    final existing = await installedComponentDirectory();
    if (existing != null) return existing;

    final root = await _root();
    await root.create(recursive: true);
    final archiveFile = File(p.join(root.path, '$version.download'));
    final staging = Directory(p.join(root.path, '$version.installing'));
    final target = Directory(p.join(root.path, version));
    if (await archiveFile.exists()) await archiveFile.delete();
    if (await staging.exists()) await staging.delete(recursive: true);

    try {
      await _download(archiveFile, onProgress: onProgress);
      final digest = await sha256.bind(archiveFile.openRead()).first;
      if (digest.toString() != archiveSha256) {
        throw const FormatException('ScreenAI download checksum did not match');
      }

      await staging.create(recursive: true);
      await Isolate.run(
        () => _extractScreenAiArchive(archiveFile.path, staging.path),
      );
      final stagedComponent = Directory(p.join(staging.path, 'resources'));
      if (!isValidComponentDirectory(stagedComponent)) {
        throw const FormatException(
          'ScreenAI package is missing OCR runtime files',
        );
      }
      await File(p.join(stagedComponent.path, 'mangatan_manifest.json'))
          .writeAsString(
            jsonEncode({
              'version': version,
              'instance': _instance,
              'sha256': archiveSha256,
            }),
            flush: true,
          );
      if (await target.exists()) await target.delete(recursive: true);
      await staging.rename(target.path);
      final installed = Directory(p.join(target.path, 'resources'));
      if (!isValidComponentDirectory(installed)) {
        throw const FileSystemException(
          'ScreenAI installation did not complete',
        );
      }
      return installed;
    } finally {
      if (await archiveFile.exists()) await archiveFile.delete();
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  static Future<void> remove() async {
    final root = await _root();
    if (await root.exists()) await root.delete(recursive: true);
  }

  static Future<void> _download(
    File destination, {
    ScreenAiDownloadProgress? onProgress,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.getUrl(downloadUri);
      request.headers.set(HttpHeaders.userAgentHeader, 'Mangatan/$version');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException(
          'ScreenAI download failed (${response.statusCode})',
          uri: downloadUri,
        );
      }
      final total = response.contentLength > 0
          ? response.contentLength
          : downloadSize;
      var received = 0;
      final sink = destination.openWrite();
      try {
        // connectionTimeout covers only the connect. A transfer that stalls
        // afterwards would otherwise hang the install indefinitely.
        await for (final chunk in response.timeout(
          const Duration(minutes: 1),
        )) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
      if (received == 0) {
        throw const HttpException('ScreenAI download was empty');
      }
    } finally {
      client.close(force: true);
    }
  }
}

Future<void> _extractScreenAiArchive(String source, String destination) async {
  final input = InputFileStream(source);
  try {
    final archive = ZipDecoder().decodeStream(input, verify: true);
    await extractArchiveToDisk(archive, destination);
  } finally {
    await input.close();
  }
}
