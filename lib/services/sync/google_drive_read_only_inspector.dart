import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:mangayomi/services/http/idle_timeout_client.dart';
import 'package:mangayomi/services/sync/chimahon_backup_fingerprint.dart';
import 'package:mangayomi/services/sync/chimahon_sync_codec.dart';
import 'package:mangayomi/services/sync/cross_device_sync_storage.dart';
import 'package:mangayomi/services/sync/google_drive_sync_storage.dart';

/// GET-only diagnostic client for Chimahon's private Drive app-data space.
///
/// This deliberately does not implement [CrossDeviceSyncStorage] and exposes
/// no upload, rename, archive, or delete operation. Reports hash opaque account
/// and file identifiers, app-property values, and ETags so diagnostic output
/// can be shared without exposing credentials or stable Google identifiers.
class GoogleDriveReadOnlyInspector {
  GoogleDriveReadOnlyInspector({
    required this.accessToken,
    this.remoteFileName = GoogleDriveSyncStorage.chimahonRemoteFileName,
    http.Client? client,
  }) : _client = client ?? IdleTimeoutClient(http.Client()),
       _ownsClient = client == null;

  static const _apiHost = 'www.googleapis.com';

  final String accessToken;
  final String remoteFileName;
  final http.Client _client;
  final bool _ownsClient;

  Map<String, String> get _authorizationHeaders => {
    'Authorization': 'Bearer $accessToken',
    'Accept': 'application/json',
  };

  Future<GoogleDriveReadOnlyInspection> inspect({
    List<int>? referenceBytes,
  }) async {
    final accountPermissionId = await _currentUserPermissionId();
    final reference = referenceBytes == null
        ? null
        : ChimahonBackupFingerprint.fromBytes(referenceBytes);
    final remoteFiles = await _listRemoteFiles();
    final reports = <GoogleDriveReadOnlyFileInspection>[];
    for (final remoteFile in remoteFiles) {
      final metadataEtagSha256 = await _probeMetadataEtag(remoteFile);
      final legacyMetadata = await _probeLegacyMetadata(remoteFile);
      reports.add(
        await _downloadAndInspect(
          remoteFile,
          reference,
          metadataEtagSha256: metadataEtagSha256,
          legacyMetadata: legacyMetadata,
        ),
      );
    }
    final canonicalIndex = reports.indexWhere(
      (report) => report.fingerprint != null,
    );
    if (canonicalIndex >= 0) {
      reports[canonicalIndex] = reports[canonicalIndex].asCanonical();
    }
    return GoogleDriveReadOnlyInspection(
      accountPermissionIdSha256: _textSha256(accountPermissionId),
      remoteFileName: remoteFileName,
      reference: reference,
      files: List.unmodifiable(reports),
    );
  }

  Future<String> _currentUserPermissionId() async {
    final response = await _client.get(
      Uri.https(_apiHost, '/drive/v3/about', {'fields': 'user(permissionId)'}),
      headers: _authorizationHeaders,
    );
    _throwForResponse(response, 'identify the Google Drive account');
    final decoded = _decodeJsonObject(response.body);
    final user = decoded['user'];
    final permissionId = user is Map
        ? user['permissionId']?.toString().trim()
        : null;
    if (permissionId == null || permissionId.isEmpty) {
      throw const SyncStorageException(
        'Google Drive did not identify the signed-in account',
      );
    }
    return permissionId;
  }

  Future<List<_ReadOnlyDriveFile>> _listRemoteFiles() async {
    final escapedName = remoteFileName
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'");
    final filesById = <String, _ReadOnlyDriveFile>{};
    final seenPageTokens = <String>{};
    String? pageToken;
    do {
      final response = await _client.get(
        Uri.https(_apiHost, '/drive/v3/files', {
          'spaces': 'appDataFolder',
          'q': "name = '$escapedName' and trashed = false",
          'fields':
              'nextPageToken,files(id,name,mimeType,createdTime,modifiedTime,'
              'version,size,md5Checksum,appProperties)',
          'orderBy': 'modifiedTime desc',
          'pageSize': '1000',
          'pageToken': ?pageToken,
        }),
        headers: _authorizationHeaders,
      );
      _throwForResponse(response, 'list Google Drive sync data');
      final decoded = _decodeJsonObject(response.body);
      final values = decoded['files'];
      if (values is List) {
        for (final value in values.whereType<Map>()) {
          final file = _ReadOnlyDriveFile.fromJson(
            value.cast<String, dynamic>(),
          );
          if (file.id.isEmpty || file.name != remoteFileName) continue;
          final existing = filesById[file.id];
          if (existing != null && existing.revision != file.revision) {
            throw const SyncConflictException();
          }
          filesById[file.id] = file;
        }
      }
      final nextPageToken = decoded['nextPageToken']?.toString();
      if (nextPageToken == null || nextPageToken.isEmpty) break;
      if (!seenPageTokens.add(nextPageToken)) {
        throw const SyncStorageException(
          'Google Drive returned a repeated file-list page token',
        );
      }
      pageToken = nextPageToken;
    } while (true);
    final files = filesById.values.toList()
      ..sort(_ReadOnlyDriveFile.newestFirst);
    return files;
  }

  Future<String?> _probeMetadataEtag(_ReadOnlyDriveFile listedFile) async {
    final response = await _client.get(
      Uri.https(_apiHost, '/drive/v3/files/${listedFile.id}', {
        'fields': 'id,name,version',
      }),
      headers: _authorizationHeaders,
    );
    if (response.statusCode == 404) throw const SyncConflictException();
    _throwForResponse(response, 'inspect Google Drive sync metadata');

    final metadata = _decodeJsonObject(response.body);
    final returnedId = metadata['id']?.toString() ?? '';
    final returnedName = metadata['name']?.toString() ?? '';
    final returnedVersion = metadata['version']?.toString() ?? '';
    if (returnedId != listedFile.id ||
        returnedName != listedFile.name ||
        returnedVersion != listedFile.version) {
      throw const SyncConflictException();
    }
    return _nullableTextSha256(response.headers['etag']);
  }

  /// Drive v3 no longer exposes the file resource ETag in its JSON model.
  /// Drive v2 remains an officially published API and still exposes the same
  /// file's ETag and head revision ID. This GET-only probe establishes whether
  /// either value can provide a real conditional-write primitive; it does not
  /// use either value to mutate Drive.
  Future<_LegacyDriveMetadata> _probeLegacyMetadata(
    _ReadOnlyDriveFile listedFile,
  ) async {
    final response = await _client.get(
      Uri.https(_apiHost, '/drive/v2/files/${listedFile.id}', {
        'fields': 'id,title,version,etag,headRevisionId',
      }),
      headers: _authorizationHeaders,
    );
    if (response.statusCode == 404) throw const SyncConflictException();
    _throwForResponse(response, 'inspect Google Drive v2 sync metadata');

    final metadata = _decodeJsonObject(response.body);
    final returnedId = metadata['id']?.toString() ?? '';
    final returnedName = metadata['title']?.toString() ?? '';
    final returnedVersion = metadata['version']?.toString() ?? '';
    if (returnedId != listedFile.id ||
        returnedName != listedFile.name ||
        returnedVersion != listedFile.version) {
      throw const SyncConflictException();
    }
    final resourceEtag = _normalizedText(metadata['etag']?.toString());
    final headerEtag = _normalizedText(response.headers['etag']);
    return _LegacyDriveMetadata(
      resourceEtagSha256: resourceEtag == null
          ? null
          : _textSha256(resourceEtag),
      resourceEtagIsStrong: _isStrongEtag(resourceEtag),
      responseHeaderEtagSha256: headerEtag == null
          ? null
          : _textSha256(headerEtag),
      resourceAndHeaderEtagsMatch: resourceEtag == null || headerEtag == null
          ? null
          : resourceEtag == headerEtag,
      headRevisionIdSha256: _nullableTextSha256(
        metadata['headRevisionId']?.toString(),
      ),
    );
  }

  Future<GoogleDriveReadOnlyFileInspection> _downloadAndInspect(
    _ReadOnlyDriveFile file,
    ChimahonBackupFingerprint? reference, {
    required String? metadataEtagSha256,
    required _LegacyDriveMetadata legacyMetadata,
  }) async {
    final response = await _client.get(
      Uri.https(_apiHost, '/drive/v3/files/${file.id}', {'alt': 'media'}),
      headers: _authorizationHeaders,
    );
    if (response.statusCode == 404) throw const SyncConflictException();
    _throwForResponse(response, 'download Google Drive sync data');

    ChimahonBackupFingerprint? fingerprint;
    String? formatError;
    try {
      fingerprint = ChimahonBackupFingerprint.fromBytes(response.bodyBytes);
    } on ChimahonSyncFormatException {
      formatError = 'invalidChimahonPayload';
    }
    return GoogleDriveReadOnlyFileInspection(
      fileIdSha256: _textSha256(file.id),
      name: file.name,
      mimeType: file.mimeType,
      createdTime: file.createdTime,
      modifiedTime: file.modifiedTime,
      version: file.version,
      declaredSize: file.size,
      driveMd5Checksum: file.md5Checksum,
      appPropertyValueSha256: {
        for (final entry in file.appProperties.entries)
          entry.key: _textSha256(entry.value),
      },
      metadataEtagSha256: metadataEtagSha256,
      legacyMetadataEtagSha256: legacyMetadata.resourceEtagSha256,
      legacyMetadataEtagIsStrong: legacyMetadata.resourceEtagIsStrong,
      legacyMetadataHeaderEtagSha256: legacyMetadata.responseHeaderEtagSha256,
      legacyMetadataEtagsMatch: legacyMetadata.resourceAndHeaderEtagsMatch,
      legacyHeadRevisionIdSha256: legacyMetadata.headRevisionIdSha256,
      downloadEtagSha256: _nullableTextSha256(response.headers['etag']),
      declaredSizeMatchesDownload: file.size == null
          ? null
          : file.size == response.bodyBytes.length,
      driveMd5MatchesDownload: file.md5Checksum == null
          ? null
          : file.md5Checksum == md5.convert(response.bodyBytes).toString(),
      fingerprint: fingerprint,
      comparison: fingerprint == null || reference == null
          ? null
          : fingerprint.compareTo(reference),
      formatError: formatError,
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Map<String, dynamic> _decodeJsonObject(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // Keep response contents out of diagnostic errors.
    }
    throw const SyncStorageException(
      'Google Drive returned an invalid JSON response',
    );
  }

  void _throwForResponse(http.Response response, String operation) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw SyncStorageException(
      'Failed to $operation',
      statusCode: response.statusCode,
    );
  }

  String _textSha256(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  String? _nullableTextSha256(String? value) {
    final normalized = _normalizedText(value);
    return normalized == null || normalized.isEmpty
        ? null
        : _textSha256(normalized);
  }

  String? _normalizedText(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  bool? _isStrongEtag(String? value) {
    if (value == null) return null;
    if (value.length < 2 ||
        value.startsWith('W/') ||
        !value.startsWith('"') ||
        !value.endsWith('"')) {
      return false;
    }
    return !value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);
  }
}

class GoogleDriveReadOnlyInspection {
  const GoogleDriveReadOnlyInspection({
    required this.accountPermissionIdSha256,
    required this.remoteFileName,
    required this.reference,
    required this.files,
  });

  final String accountPermissionIdSha256;
  final String remoteFileName;
  final ChimahonBackupFingerprint? reference;
  final List<GoogleDriveReadOnlyFileInspection> files;

  Map<String, Object?> toSafeJson() => {
    'accountPermissionIdSha256': accountPermissionIdSha256,
    'remoteFileName': remoteFileName,
    'candidateCount': files.length,
    'validCandidateCount': files
        .where((file) => file.fingerprint != null)
        .length,
    'reference': reference?.toSafeJson(),
    'files': [for (final file in files) file.toSafeJson()],
  };
}

class GoogleDriveReadOnlyFileInspection {
  const GoogleDriveReadOnlyFileInspection({
    required this.fileIdSha256,
    required this.name,
    required this.mimeType,
    required this.createdTime,
    required this.modifiedTime,
    required this.version,
    required this.declaredSize,
    required this.driveMd5Checksum,
    required this.appPropertyValueSha256,
    required this.metadataEtagSha256,
    required this.legacyMetadataEtagSha256,
    required this.legacyMetadataEtagIsStrong,
    required this.legacyMetadataHeaderEtagSha256,
    required this.legacyMetadataEtagsMatch,
    required this.legacyHeadRevisionIdSha256,
    required this.downloadEtagSha256,
    required this.declaredSizeMatchesDownload,
    required this.driveMd5MatchesDownload,
    required this.fingerprint,
    required this.comparison,
    required this.formatError,
    this.wouldBeCanonical = false,
  });

  final String fileIdSha256;
  final String name;
  final String mimeType;
  final DateTime? createdTime;
  final DateTime? modifiedTime;
  final String version;
  final int? declaredSize;
  final String? driveMd5Checksum;
  final Map<String, String> appPropertyValueSha256;
  final String? metadataEtagSha256;
  final String? legacyMetadataEtagSha256;
  final bool? legacyMetadataEtagIsStrong;
  final String? legacyMetadataHeaderEtagSha256;
  final bool? legacyMetadataEtagsMatch;
  final String? legacyHeadRevisionIdSha256;
  final String? downloadEtagSha256;
  final bool? declaredSizeMatchesDownload;
  final bool? driveMd5MatchesDownload;
  final ChimahonBackupFingerprint? fingerprint;
  final ChimahonBackupComparison? comparison;
  final String? formatError;
  final bool wouldBeCanonical;

  GoogleDriveReadOnlyFileInspection asCanonical() =>
      GoogleDriveReadOnlyFileInspection(
        fileIdSha256: fileIdSha256,
        name: name,
        mimeType: mimeType,
        createdTime: createdTime,
        modifiedTime: modifiedTime,
        version: version,
        declaredSize: declaredSize,
        driveMd5Checksum: driveMd5Checksum,
        appPropertyValueSha256: appPropertyValueSha256,
        metadataEtagSha256: metadataEtagSha256,
        legacyMetadataEtagSha256: legacyMetadataEtagSha256,
        legacyMetadataEtagIsStrong: legacyMetadataEtagIsStrong,
        legacyMetadataHeaderEtagSha256: legacyMetadataHeaderEtagSha256,
        legacyMetadataEtagsMatch: legacyMetadataEtagsMatch,
        legacyHeadRevisionIdSha256: legacyHeadRevisionIdSha256,
        downloadEtagSha256: downloadEtagSha256,
        declaredSizeMatchesDownload: declaredSizeMatchesDownload,
        driveMd5MatchesDownload: driveMd5MatchesDownload,
        fingerprint: fingerprint,
        comparison: comparison,
        formatError: formatError,
        wouldBeCanonical: true,
      );

  Map<String, Object?> toSafeJson() => {
    'fileIdSha256': fileIdSha256,
    'name': name,
    'mimeType': mimeType,
    'createdTime': createdTime?.toUtc().toIso8601String(),
    'modifiedTime': modifiedTime?.toUtc().toIso8601String(),
    'version': version,
    'declaredSize': declaredSize,
    'driveMd5Checksum': driveMd5Checksum,
    'appPropertyValueSha256': appPropertyValueSha256,
    'metadataEtagSha256': metadataEtagSha256,
    'legacyMetadataEtagSha256': legacyMetadataEtagSha256,
    'legacyMetadataEtagIsStrong': legacyMetadataEtagIsStrong,
    'legacyMetadataHeaderEtagSha256': legacyMetadataHeaderEtagSha256,
    'legacyMetadataEtagsMatch': legacyMetadataEtagsMatch,
    'legacyHeadRevisionIdSha256': legacyHeadRevisionIdSha256,
    'downloadEtagSha256': downloadEtagSha256,
    'declaredSizeMatchesDownload': declaredSizeMatchesDownload,
    'driveMd5MatchesDownload': driveMd5MatchesDownload,
    'wouldBeCanonical': wouldBeCanonical,
    'fingerprint': fingerprint?.toSafeJson(),
    'referenceComparison': comparison?.toSafeJson(),
    'formatError': formatError,
  };
}

class _LegacyDriveMetadata {
  const _LegacyDriveMetadata({
    required this.resourceEtagSha256,
    required this.resourceEtagIsStrong,
    required this.responseHeaderEtagSha256,
    required this.resourceAndHeaderEtagsMatch,
    required this.headRevisionIdSha256,
  });

  final String? resourceEtagSha256;
  final bool? resourceEtagIsStrong;
  final String? responseHeaderEtagSha256;
  final bool? resourceAndHeaderEtagsMatch;
  final String? headRevisionIdSha256;
}

class _ReadOnlyDriveFile {
  const _ReadOnlyDriveFile({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.createdTime,
    required this.modifiedTime,
    required this.version,
    required this.size,
    required this.md5Checksum,
    required this.appProperties,
  });

  factory _ReadOnlyDriveFile.fromJson(Map<String, dynamic> json) {
    final rawProperties = json['appProperties'];
    return _ReadOnlyDriveFile(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      mimeType: json['mimeType']?.toString() ?? '',
      createdTime: DateTime.tryParse(json['createdTime']?.toString() ?? ''),
      modifiedTime: DateTime.tryParse(json['modifiedTime']?.toString() ?? ''),
      version: json['version']?.toString() ?? '',
      size: int.tryParse(json['size']?.toString() ?? ''),
      md5Checksum: json['md5Checksum']?.toString(),
      appProperties: rawProperties is Map
          ? {
              for (final entry in rawProperties.entries)
                entry.key.toString(): entry.value.toString(),
            }
          : const {},
    );
  }

  final String id;
  final String name;
  final String mimeType;
  final DateTime? createdTime;
  final DateTime? modifiedTime;
  final String version;
  final int? size;
  final String? md5Checksum;
  final Map<String, String> appProperties;

  String get revision => '$id:$version';

  static int newestFirst(_ReadOnlyDriveFile first, _ReadOnlyDriveFile second) {
    final modified =
        (second.modifiedTime ?? DateTime.fromMillisecondsSinceEpoch(0))
            .compareTo(
              first.modifiedTime ?? DateTime.fromMillisecondsSinceEpoch(0),
            );
    if (modified != 0) return modified;
    final version = (int.tryParse(second.version) ?? 0).compareTo(
      int.tryParse(first.version) ?? 0,
    );
    return version != 0 ? version : first.id.compareTo(second.id);
  }
}
