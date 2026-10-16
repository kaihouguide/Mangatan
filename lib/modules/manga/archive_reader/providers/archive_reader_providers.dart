import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:mangayomi/modules/manga/archive_reader/models/models.dart';
import 'package:mangayomi/services/epub_manga.dart';
import 'package:mangayomi/src/rust/api/epub.dart';
import 'package:mangayomi/src/rust/api/rar.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:path/path.dart' as p;
part 'archive_reader_providers.g.dart';

// Constants for supported file types
const List<String> _kImageExtensions = [
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.avif',
  '.heic',
  '.heif',
  '.jxl',
];
const List<String> _kArchiveExtensions = [
  '.cbz',
  '.zip',
  '.cbr',
  '.rar',
  '.cbt',
  '.tar',
];

@riverpod
Future<List<(String, LocalExtensionType, Uint8List, String)>>
getArchivesDataFromDirectory(Ref ref, String path) async {
  return _extractArchiveMetadataFromDirectory(path);
}

@riverpod
Future<List<LocalArchive>> getArchiveDataFromDirectory(
  Ref ref,
  String path,
) async {
  return _extractArchivesFromDirectory(path);
}

@riverpod
Future<(String, LocalExtensionType, Uint8List, String)> getArchivesDataFromFile(
  Ref ref,
  String path,
) async {
  if (_isEpubFile(path)) {
    final archive = await _extractEpubArchive(path);
    return (archive.name!, LocalExtensionType.epub, archive.coverImage!, path);
  }
  if (_isRarFile(path)) return _extractArchiveMetadata(path);
  return compute(_extractArchiveMetadata, path);
}

@riverpod
Future<LocalArchive> getArchiveDataFromFile(Ref ref, String path) {
  if (_isEpubFile(path)) return _extractEpubArchive(path);
  if (_isRarFile(path)) return _extractArchive(path);
  return compute(_extractArchive, path);
}

Future<LocalArchive> _extractEpubArchive(String path) async {
  final book = await parseEpubFromPath(epubPath: path, fullData: true);
  final pages = epubMangaPageImages(book);
  if (pages.isEmpty) {
    throw Exception(
      'No image pages were found in the EPUB spine. Import it as a novel instead.',
    );
  }
  final title = book.name.trim().isEmpty
      ? p.basenameWithoutExtension(path)
      : book.name.trim();
  return LocalArchive()
    ..path = path
    ..extensionType = LocalExtensionType.epub
    ..name = title
    ..images = pages
    ..coverImage = book.cover ?? pages.first.image;
}

/// Extract full archive data from all archives in a directory (recursive)
Future<List<LocalArchive>> _extractArchivesFromDirectory(
  String directoryPath,
) async {
  final archives = <LocalArchive>[];

  try {
    final paths = await compute(_findArchivePaths, directoryPath);
    for (final path in paths) {
      try {
        final archive = _isRarFile(path)
            ? await _extractArchive(path)
            : await compute(_extractArchive, path);
        archives.add(archive);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Error extracting archive at $path: $e');
        }
      }
    }
  } catch (e) {
    if (kDebugMode) {
      debugPrint('Error scanning directory $directoryPath: $e');
    }
  }

  return archives;
}

/// Extract only metadata (cover) from all archives in a directory (recursive)
Future<List<(String, LocalExtensionType, Uint8List, String)>>
_extractArchiveMetadataFromDirectory(String directoryPath) async {
  final metadata = <(String, LocalExtensionType, Uint8List, String)>[];

  try {
    final paths = await compute(_findArchivePaths, directoryPath);
    for (final path in paths) {
      try {
        final data = _isRarFile(path)
            ? await _extractArchiveMetadata(path)
            : await compute(_extractArchiveMetadata, path);
        metadata.add(data);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Error extracting metadata at $path: $e');
        }
      }
    }
  } catch (e) {
    if (kDebugMode) {
      debugPrint('Error scanning directory $directoryPath: $e');
    }
  }

  return metadata;
}

/// Recursively finds archive files. This runs in a worker isolate so large
/// local libraries do not block the UI while they are scanned.
List<String> _findArchivePaths(String directoryPath) {
  final paths = <String>[];
  final dir = Directory(directoryPath);
  if (!dir.existsSync()) return paths;

  _scanDirectoryRecursive(dir, paths);
  return paths;
}

void _scanDirectoryRecursive(Directory dir, List<String> paths) {
  try {
    final entities = dir.listSync();

    for (final entity in entities) {
      if (entity is Directory) {
        _scanDirectoryRecursive(entity, paths);
      } else if (entity is File && _isArchiveFile(entity.path)) {
        paths.add(entity.path);
      }
    }
  } catch (e) {
    if (kDebugMode) {
      debugPrint('Error scanning directory ${dir.path}: $e');
    }
  }
}

/// Check if a file is an image based on extension
@visibleForTesting
bool isArchiveReaderImagePath(String path) {
  final extension = p.extension(path).toLowerCase();
  return _kImageExtensions.contains(extension);
}

/// Compares archive paths in the order a person expects numbered pages to
/// appear. This keeps unpadded names such as `2.webp` before `10.webp`.
@visibleForTesting
int compareArchiveReaderPaths(String left, String right) {
  final leftLower = left.toLowerCase();
  final rightLower = right.toLowerCase();
  var leftIndex = 0;
  var rightIndex = 0;

  while (leftIndex < leftLower.length && rightIndex < rightLower.length) {
    final leftIsDigit = _isAsciiDigit(leftLower.codeUnitAt(leftIndex));
    final rightIsDigit = _isAsciiDigit(rightLower.codeUnitAt(rightIndex));

    if (leftIsDigit && rightIsDigit) {
      final leftEnd = _digitRunEnd(leftLower, leftIndex);
      final rightEnd = _digitRunEnd(rightLower, rightIndex);
      final leftSignificant = _firstSignificantDigit(
        leftLower,
        leftIndex,
        leftEnd,
      );
      final rightSignificant = _firstSignificantDigit(
        rightLower,
        rightIndex,
        rightEnd,
      );
      final leftLength = leftEnd - leftSignificant;
      final rightLength = rightEnd - rightSignificant;

      if (leftLength != rightLength) return leftLength.compareTo(rightLength);

      final numberComparison = leftLower
          .substring(leftSignificant, leftEnd)
          .compareTo(rightLower.substring(rightSignificant, rightEnd));
      if (numberComparison != 0) return numberComparison;

      final runLengthComparison = (leftEnd - leftIndex).compareTo(
        rightEnd - rightIndex,
      );
      if (runLengthComparison != 0) return runLengthComparison;

      leftIndex = leftEnd;
      rightIndex = rightEnd;
      continue;
    }

    final characterComparison = leftLower
        .codeUnitAt(leftIndex)
        .compareTo(rightLower.codeUnitAt(rightIndex));
    if (characterComparison != 0) return characterComparison;
    leftIndex++;
    rightIndex++;
  }

  final lengthComparison = leftLower.length.compareTo(rightLower.length);
  if (lengthComparison != 0) return lengthComparison;
  return left.compareTo(right);
}

bool _isAsciiDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

int _digitRunEnd(String value, int start) {
  var end = start;
  while (end < value.length && _isAsciiDigit(value.codeUnitAt(end))) {
    end++;
  }
  return end;
}

int _firstSignificantDigit(String value, int start, int end) {
  var index = start;
  while (index < end - 1 && value.codeUnitAt(index) == 0x30) {
    index++;
  }
  return index;
}

/// Check if a file is a supported archive based on extension
bool _isArchiveFile(String path) {
  final extension = p.extension(path).toLowerCase();
  return _kArchiveExtensions.any((ext) => extension.endsWith(ext));
}

bool _isEpubFile(String path) => p.extension(path).toLowerCase() == '.epub';

bool _isRarFile(String path) {
  final extension = p.extension(path).toLowerCase();
  return extension == '.cbr' || extension == '.rar';
}

/// Extract full archive with all images
Future<LocalArchive> _extractArchive(String path) async {
  try {
    // Handle directory of images
    if (Directory(path).existsSync()) {
      return await _extractFromImageFolder(path);
    }

    // Handle archive file
    return await _extractFromArchiveFile(path);
  } catch (e) {
    if (kDebugMode) {
      debugPrint('Error extracting archive from $path: $e');
    }
    rethrow;
  }
}

/// Extract images from a folder
///
/// Unlike the archive-file case, these pages already exist as standalone
/// files on disk - there's no need to read every one of them into memory
/// just to hand the bytes back to a caller who's only going to write them
/// back out to a temp file to get a path again. Only the first file (the
/// cover) is actually read; every other [LocalImage] carries its real [path]
/// instead of [image], and callers read the file directly when they need it.
Future<LocalArchive> _extractFromImageFolder(String path) async {
  final dir = Directory(path);
  final imageFiles =
      await dir
            .list()
            .where(
              (entity) =>
                  entity is File && isArchiveReaderImagePath(entity.path),
            )
            .cast<File>()
            .toList()
        ..sort((a, b) => compareArchiveReaderPaths(a.path, b.path));

  if (imageFiles.isEmpty) {
    throw Exception('No images found in folder: $path');
  }

  final images = imageFiles.map((file) {
    return LocalImage()
      ..path = file.path
      ..name = p.basename(file.path);
  }).toList();

  return LocalArchive()
    ..path = path
    ..extensionType = LocalExtensionType.folder
    ..name = p.basename(path)
    ..images = images
    ..coverImage = imageFiles.first.readAsBytesSync();
}

/// Extract images from an archive file
Future<LocalArchive> _extractFromArchiveFile(String path) async {
  final extensionType = _getArchiveType(path);
  if (_isRarArchiveType(extensionType)) {
    return _extractFromRarArchiveFile(path, extensionType);
  }
  final localArchive = LocalArchive()
    ..path = path
    ..extensionType = extensionType
    ..name = p.basenameWithoutExtension(path)
    ..images = [];

  InputFileStream? inputStream;

  try {
    inputStream = InputFileStream(path);
    final archive = _decodeArchive(inputStream, extensionType);

    final imageFiles =
        archive.files
            .where(
              (file) =>
                  file.isFile &&
                  isArchiveReaderImagePath(file.name) &&
                  !file.name.startsWith('.'),
            )
            .toList()
          ..sort((a, b) => compareArchiveReaderPaths(a.name, b.name));

    if (imageFiles.isEmpty) {
      throw Exception('No images found in archive: $path');
    }

    // Extract images
    for (final file in imageFiles) {
      final filename = file.name;
      final data = file.content;

      if (filename.toLowerCase().contains('cover')) {
        localArchive.coverImage = data;
      }

      localArchive.images!.add(
        LocalImage()
          ..image = data
          ..name = p.basename(filename),
      );
    }

    // Set cover image if not explicitly found
    localArchive.coverImage ??= localArchive.images!.first.image;

    return localArchive;
  } finally {
    inputStream?.close();
  }
}

Future<LocalArchive> _extractFromRarArchiveFile(
  String path,
  LocalExtensionType extensionType,
) async {
  final entries = await _rarImageEntries(path);
  final extracted =
      await extractRarEntries(
          archivePath: path,
          entryNames: entries.map((entry) => entry.name).toList(),
        )
        ..sort((a, b) => compareArchiveReaderPaths(a.name, b.name));
  final images = extracted
      .map(
        (entry) => LocalImage()
          ..image = entry.content
          ..name = p.basename(entry.name),
      )
      .toList();

  final cover = extracted
      .where((entry) => entry.name.toLowerCase().contains('cover'))
      .firstOrNull;
  return LocalArchive()
    ..path = path
    ..extensionType = extensionType
    ..name = p.basenameWithoutExtension(path)
    ..images = images
    ..coverImage = cover?.content ?? images.first.image;
}

/// Extract only metadata (name, type, cover) from archive
Future<(String, LocalExtensionType, Uint8List, String)> _extractArchiveMetadata(
  String path,
) async {
  try {
    // Handle directory of images
    if (await Directory(path).exists()) {
      return await _extractMetadataFromImageFolder(path);
    }

    // Handle archive file
    return await _extractMetadataFromArchiveFile(path);
  } catch (e) {
    if (kDebugMode) {
      debugPrint('Error extracting metadata from $path: $e');
    }
    rethrow;
  }
}

/// Extract metadata from image folder
Future<(String, LocalExtensionType, Uint8List, String)>
_extractMetadataFromImageFolder(String path) async {
  final dir = Directory(path);
  final images =
      await dir
            .list()
            .where(
              (entity) =>
                  entity is File && isArchiveReaderImagePath(entity.path),
            )
            .cast<File>()
            .toList()
        ..sort((a, b) => compareArchiveReaderPaths(a.path, b.path));

  if (images.isEmpty) {
    throw Exception('No images found in folder: $path');
  }

  final cover = images.first.readAsBytesSync();
  return (p.basename(path), LocalExtensionType.folder, cover, path);
}

/// Extract metadata from archive file
Future<(String, LocalExtensionType, Uint8List, String)>
_extractMetadataFromArchiveFile(String path) async {
  final extensionType = _getArchiveType(path);
  final name = p.basenameWithoutExtension(path);
  if (_isRarArchiveType(extensionType)) {
    final imageEntries = await _rarImageEntries(path);
    final coverEntry = imageEntries.firstWhere(
      (entry) => entry.name.toLowerCase().contains('cover'),
      orElse: () => imageEntries.first,
    );
    final coverImage = (await extractRarEntries(
      archivePath: path,
      entryNames: [coverEntry.name],
    )).first.content;
    return (name, extensionType, coverImage, path);
  }

  InputFileStream? inputStream;

  try {
    inputStream = InputFileStream(path);
    final archive = _decodeArchive(inputStream, extensionType);

    // Look for cover image first
    final coverFile = archive.files.firstWhere(
      (file) =>
          file.isFile &&
          isArchiveReaderImagePath(file.name) &&
          file.name.toLowerCase().contains('cover') &&
          !file.name.startsWith('.'),
      orElse: () {
        // If no cover, get first image alphabetically
        final imageFiles =
            archive.files
                .where(
                  (file) =>
                      file.isFile &&
                      isArchiveReaderImagePath(file.name) &&
                      !file.name.startsWith('.'),
                )
                .toList()
              ..sort((a, b) => compareArchiveReaderPaths(a.name, b.name));

        if (imageFiles.isEmpty) {
          throw Exception('No images found in archive: $path');
        }

        return imageFiles.first;
      },
    );

    final coverImage = coverFile.content;
    return (name, extensionType, coverImage, path);
  } finally {
    inputStream?.close();
  }
}

Future<List<RarEntry>> _rarImageEntries(String path) async {
  final imageEntries =
      (await listRarEntries(archivePath: path))
          .where(
            (entry) =>
                entry.isFile &&
                isArchiveReaderImagePath(entry.name) &&
                !entry.name.startsWith('.'),
          )
          .toList()
        ..sort((a, b) => compareArchiveReaderPaths(a.name, b.name));
  if (imageEntries.isEmpty) {
    throw Exception('No images found in archive: $path');
  }
  return imageEntries;
}

bool _isRarArchiveType(LocalExtensionType type) =>
    type == LocalExtensionType.cbr || type == LocalExtensionType.rar;

/// Decode archive based on type
Archive _decodeArchive(InputFileStream stream, LocalExtensionType type) {
  switch (type) {
    case LocalExtensionType.cbt:
    case LocalExtensionType.tar:
      return TarDecoder().decodeStream(stream);
    case LocalExtensionType.zip:
    case LocalExtensionType.cbz:
    case LocalExtensionType.epub:
    case LocalExtensionType.folder:
      return ZipDecoder().decodeStream(stream);
    case LocalExtensionType.cbr:
    case LocalExtensionType.rar:
      throw ArgumentError.value(type, 'type', 'RAR uses the native decoder');
  }
}

/// Get archive type from file extension
LocalExtensionType _getArchiveType(String path) {
  final extension = p.extension(path).toLowerCase().replaceFirst('.', '');
  return setTypeExtension(extension);
}

String getTypeExtension(LocalExtensionType type) {
  return type.name;
}

LocalExtensionType setTypeExtension(String extension) {
  return switch (extension.toLowerCase()) {
    'cbt' => LocalExtensionType.cbt,
    'zip' => LocalExtensionType.zip,
    'cbr' => LocalExtensionType.cbr,
    'rar' => LocalExtensionType.rar,
    'tar' => LocalExtensionType.tar,
    'cbz' => LocalExtensionType.cbz,
    'epub' => LocalExtensionType.epub,
    _ => LocalExtensionType.cbz,
  };
}
