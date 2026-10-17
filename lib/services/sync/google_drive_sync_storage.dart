import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/services/http/idle_timeout_client.dart';
import 'package:mangayomi/services/sync/chimahon_sync_codec.dart';
import 'package:mangayomi/services/sync/chimahon_sync_merger.dart';
import 'package:mangayomi/services/sync/cross_device_sync_storage.dart';
import 'package:mangayomi/services/sync/mangatan_epub_blob_storage.dart';
import 'package:mangayomi/services/sync/mangatan_epub_sync_manifest.dart';

/// Chimahon-compatible Google Drive transport.
///
/// The filename and `appDataFolder` space intentionally match Chimahon. File
/// discovery does not copy Chimahon's MIME filter because Chimahon writes
/// `application/octet-stream` while querying for `application/x-gzip`.
class GoogleDriveSyncStorage
    implements
        CrossDeviceSyncStorage,
        MangatanEpubBlobStorage,
        ClosableSyncStorage {
  GoogleDriveSyncStorage({
    required this.accessToken,
    required this.deviceId,
    this.remoteFileName = chimahonRemoteFileName,
    http.Client? client,
  }) : _client = client ?? IdleTimeoutClient(http.Client()),
       _ownsClient = client == null;

  static const chimahonRemoteFileName = 'Chimahon_sync.proto.gz';
  static const epubManifestRemoteFileName = mangatanEpubManifestFileName;
  static const _epubBlobNamePrefix = 'Mangatan_epub_blob_';
  static const _apiHost = 'www.googleapis.com';
  static const _v2MetadataFields =
      'id,title,mimeType,modifiedDate,version,etag,appDataContents,'
      'properties,labels(trashed)';

  final String accessToken;
  final String deviceId;
  final String remoteFileName;
  final http.Client _client;
  final bool _ownsClient;
  final Map<String, _DriveDownloadObservation> _downloadObservations = {};
  static const _codec = ChimahonSyncCodec();
  static const _merger = ChimahonSyncMerger();

  @override
  ChimahonSyncWireFormat get wireFormat => ChimahonSyncWireFormat.gzipProtobuf;

  @override
  Future<MangatanRemoteEpubManifest?> downloadEpubManifest() async {
    final candidates = await _listRemoteFilesByName(epubManifestRemoteFileName);
    if (candidates.isEmpty) return null;
    if (candidates.length > 1) {
      throw const SyncConflictException();
    }
    final candidate = candidates.single;
    final before = await _readV2Metadata(
      candidate,
      expectedName: epubManifestRemoteFileName,
    );
    final response = await _client.get(
      Uri.https(_apiHost, '/drive/v2/files/${candidate.id}', {'alt': 'media'}),
      headers: _authorizationHeaders,
    );
    if (_isConflictStatus(response.statusCode)) {
      throw const SyncConflictException();
    }
    _throwForResponse(response, 'download Mangatan EPUB manifest');
    final after = await _readV2Metadata(
      candidate,
      expectedName: epubManifestRemoteFileName,
    );
    if (before.etag != after.etag) throw const SyncConflictException();
    return MangatanRemoteEpubManifest(
      manifest: MangatanEpubManifest.decode(response.bodyBytes),
      revision: candidate.revision,
    );
  }

  @override
  Future<String?> uploadEpubManifest(
    MangatanEpubManifest manifest, {
    String? expectedRevision,
    bool expectedAbsent = false,
  }) async {
    final bytes = Uint8List.fromList(manifest.encode());
    final current = await _listRemoteFilesByName(epubManifestRemoteFileName);
    if (expectedAbsent) {
      if (expectedRevision != null || current.isNotEmpty) {
        throw const SyncConflictException();
      }
      return _uploadNamedMultipart(
        bytes,
        fileName: epubManifestRemoteFileName,
        mimeType: 'application/json',
      ).then((file) => file.revision);
    }
    if (expectedRevision == null || current.length != 1) {
      throw const SyncConflictException();
    }
    final target = current.single;
    if (target.revision != expectedRevision) {
      throw const SyncConflictException();
    }
    final metadata = await _readV2Metadata(
      target,
      expectedName: epubManifestRemoteFileName,
    );
    final updated = await _updateNamedMultipart(
      bytes,
      target: target,
      fileName: epubManifestRemoteFileName,
      mimeType: 'application/json',
      expectedEtag: _requireStrongQuotedEtag(metadata.etag, target.id),
    );
    return updated.revision;
  }

  @override
  Future<bool> hasEpubBlob(String sha256) async {
    final files = await _listRemoteFilesByName(_epubBlobName(sha256));
    return files.any((file) => file.name == _epubBlobName(sha256));
  }

  @override
  Future<void> uploadEpubBlob({
    required String sha256,
    required int sizeBytes,
    required Stream<List<int>> bytes,
  }) async {
    if (await hasEpubBlob(sha256)) return;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in bytes) {
      builder.add(chunk);
    }
    final payload = builder.takeBytes();
    if (payload.length != sizeBytes ||
        sha256 != crypto.sha256.convert(payload).toString()) {
      throw SyncStorageException(
        'Refusing to upload EPUB blob $sha256 because its content changed',
      );
    }
    await _uploadNamedMultipart(
      payload,
      fileName: _epubBlobName(sha256),
      mimeType: 'application/epub+zip',
      appProperties: {'kind': 'mangatan-epub-blob', 'sha256': sha256},
    );
  }

  @override
  Future<Uint8List> downloadEpubBlob(String sha256) async {
    final files = await _listRemoteFilesByName(_epubBlobName(sha256));
    if (files.length != 1) throw const SyncConflictException();
    final response = await _client.get(
      Uri.https(_apiHost, '/drive/v2/files/${files.single.id}', {
        'alt': 'media',
      }),
      headers: _authorizationHeaders,
    );
    if (_isConflictStatus(response.statusCode)) {
      throw const SyncConflictException();
    }
    _throwForResponse(response, 'download Mangatan EPUB blob');
    return Uint8List.fromList(response.bodyBytes);
  }

  String _epubBlobName(String sha256) => '$_epubBlobNamePrefix$sha256.epub';

  Map<String, String> get _authorizationHeaders => {
    'Authorization': 'Bearer $accessToken',
    'Accept': 'application/json',
  };

  /// Returns Drive's stable, opaque identifier for the signed-in account.
  ///
  /// Refresh tokens are credentials, not account identities, and Google may
  /// rotate them. Using `about.user.permissionId` keeps account-scoped merge
  /// baselines stable across rotation and reconnection without requesting a
  /// profile/email scope. The existing `drive.appdata` permission authorizes
  /// this read-only endpoint.
  Future<String> currentUserPermissionId() async {
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

  @override
  Future<RemoteSyncSnapshot?> download() async {
    final candidates = await _listRemoteFiles();
    if (candidates.isEmpty) return null;

    final downloaded = <_DownloadedDriveFile>[];
    BackupMihon? merged;
    _DownloadedDriveFile? canonical;
    Object? lastFormatError;
    var validCandidateCount = 0;
    Uint8List? soleValidRawBytes;
    // Stream oldest-to-newest so a large collection of legacy duplicates does
    // not keep every decoded protobuf in memory at once.
    for (final candidate in candidates.reversed) {
      final before = await _readV2Metadata(candidate);
      final response = await _client.get(
        Uri.https(_apiHost, '/drive/v2/files/${candidate.id}', {
          'alt': 'media',
        }),
        headers: _authorizationHeaders,
      );
      if (_isConflictStatus(response.statusCode)) {
        throw const SyncConflictException();
      }
      _throwForResponse(response, 'download Google Drive sync data');
      final after = await _readV2Metadata(candidate);
      if (before.etag != after.etag) {
        throw const SyncConflictException();
      }
      var isValid = false;
      try {
        final decoded = _codec.decode(response.bodyBytes);
        merged = merged == null
            ? decoded.backup.deepCopy()
            : _merger.merge(
                local: merged,
                remote: decoded.backup,
                remoteWinsRecordTies: true,
              );
        isValid = true;
        validCandidateCount++;
        soleValidRawBytes = Uint8List.fromList(response.bodyBytes);
      } on ChimahonSyncFormatException catch (error) {
        lastFormatError = error;
      }
      final downloadedCandidate = _DownloadedDriveFile(
        file: candidate,
        isValid: isValid,
        etag: after.etag,
      );
      downloaded.add(downloadedCandidate);
      if (isValid) canonical = downloadedCandidate;
    }

    if (merged == null || canonical == null) {
      throw SyncStorageException(
        'Google Drive contains $remoteFileName, but no valid Chimahon payload '
        'could be read${lastFormatError == null ? '' : ': $lastFormatError'}',
      );
    }

    final revision = _snapshotRevision(canonical.file, downloaded);
    _rememberObservation(
      _DriveDownloadObservation(
        revision: revision,
        canonical: canonical,
        candidates: List.unmodifiable(downloaded),
      ),
    );
    return RemoteSyncSnapshot(
      bytes: validCandidateCount == 1
          ? soleValidRawBytes!
          : _codec.encode(merged, format: ChimahonSyncWireFormat.gzipProtobuf),
      revision: revision,
      isCompleteRecovery: downloaded.length == 1 && validCandidateCount == 1,
      uploadRetainsAllRemoteByteBlobs: downloaded.length > 1,
    );
  }

  @override
  Future<String?> upload(
    Uint8List bytes, {
    String? expectedRevision,
    bool expectedAbsent = false,
  }) async {
    // Validate before making a remote change.
    _codec.decode(bytes);

    final currentFiles = await _listRemoteFiles();
    if (expectedAbsent &&
        (expectedRevision != null || currentFiles.isNotEmpty)) {
      throw const SyncConflictException();
    }

    if (expectedRevision == null) {
      if (currentFiles.isNotEmpty) {
        throw const SyncStorageException(
          'Google Drive sync data must be downloaded before it can be '
          'updated safely',
        );
      }
      return _create(bytes);
    }

    final observation = _downloadObservations[expectedRevision];
    if (observation == null) {
      throw const SyncStorageException(
        'Google Drive sync data must be downloaded again before it can be '
        'updated safely',
      );
    }
    if (!_sameDownloadedFileVersions(currentFiles, observation.candidates)) {
      throw const SyncConflictException();
    }

    // Check every precondition before making a remote change. This keeps a
    // missing ETag from causing a partially canonicalized remote state.
    for (final candidate in observation.candidates) {
      _requireStrongEtag(candidate);
    }

    if (observation.candidates.length > 1) {
      return _replaceDuplicatesWithoutOverwriting(
        bytes,
        expectedRevision: expectedRevision,
        observation: observation,
      );
    }

    final canonicalEtag = _requireStrongEtag(observation.canonical);
    final uploaded = await _update(
      bytes,
      target: observation.canonical.file,
      expectedEtag: canonicalEtag,
    );

    // Drive permits duplicate names, so there is no atomic create-or-update by
    // filename. Catch a writer that appeared during the update and let the sync
    // engine re-download and merge it on retry.
    final remaining = await _listRemoteFiles();
    if (remaining.length != 1 ||
        remaining.single.id != observation.canonical.file.id ||
        remaining.single.revision != uploaded.revision) {
      throw const SyncConflictException();
    }
    _downloadObservations.remove(expectedRevision);
    return uploaded.revision;
  }

  /// Replaces a duplicate exact-name set without overwriting any old bytes.
  ///
  /// The proposed payload is created as a new file first. Every observed old
  /// file is then conditionally renamed out of the exact-name set. A conflict
  /// at any point can leave extra exact-name or archived files, but every old
  /// byte blob remains recoverable and the next attempt will re-download all
  /// still-exact candidates before changing anything else.
  Future<String?> _replaceDuplicatesWithoutOverwriting(
    Uint8List bytes, {
    required String expectedRevision,
    required _DriveDownloadObservation observation,
  }) async {
    final uploaded = await _uploadMultipart(bytes);

    // Prove that no candidate changed or appeared between the preflight list
    // and creation. Do not archive anything if the exact-name set differs.
    final afterCreate = await _listRemoteFiles();
    if (!_sameDriveFileVersions(afterCreate, [
      ...observation.candidates.map((candidate) => candidate.file),
      uploaded,
    ])) {
      throw const SyncConflictException();
    }

    // Rename every old file, including the previous logical canonical. PATCH
    // changes metadata only, so neither successful nor partial cleanup
    // overwrites an old payload.
    for (final candidate in observation.candidates) {
      await _archive(candidate, expectedEtag: _requireStrongEtag(candidate));
    }

    final remaining = await _listRemoteFiles();
    if (remaining.length != 1 ||
        remaining.single.id != uploaded.id ||
        remaining.single.revision != uploaded.revision) {
      throw const SyncConflictException();
    }
    _downloadObservations.remove(expectedRevision);
    return uploaded.revision;
  }

  Future<String?> _create(Uint8List bytes) async {
    final uploaded = await _uploadMultipart(bytes);
    final matches = await _listRemoteFiles();
    if (matches.length != 1 ||
        matches.single.id != uploaded.id ||
        matches.single.revision != uploaded.revision) {
      throw const SyncConflictException();
    }
    return uploaded.revision;
  }

  Future<_DriveFile> _update(
    Uint8List bytes, {
    required _DriveFile target,
    required String expectedEtag,
  }) async {
    final metadata = <String, Object>{
      'title': remoteFileName,
      'mimeType': 'application/x-gzip',
      'properties': [
        {'key': 'deviceId', 'value': deviceId, 'visibility': 'PRIVATE'},
      ],
    };
    final response = await _sendMultipart(
      // Drive v2 exposes media updates through files.update. Its upload URI
      // requires PUT; files.patch is metadata-only and the analogous upload
      // path returns 404 on the live API.
      method: 'PUT',
      uri: Uri.https(_apiHost, '/upload/drive/v2/files/${target.id}', {
        'uploadType': 'multipart',
        'fields': _v2MetadataFields,
      }),
      metadata: metadata,
      bytes: bytes,
      expectedEtag: expectedEtag,
    );
    if (_isConflictStatus(response.statusCode)) {
      throw const SyncConflictException();
    }
    _throwForResponse(response, 'upload Google Drive sync data');
    return _validatedV2Mutation(
      response.body,
      expectedId: target.id,
      expectedPrivateDeviceId: deviceId,
    );
  }

  Future<_DriveFile> _updateNamedMultipart(
    Uint8List bytes, {
    required _DriveFile target,
    required String fileName,
    required String mimeType,
    required String expectedEtag,
  }) async {
    final response = await _sendMultipart(
      method: 'PUT',
      uri: Uri.https(_apiHost, '/upload/drive/v2/files/${target.id}', {
        'uploadType': 'multipart',
        'fields': _v2MetadataFields,
      }),
      metadata: {
        'title': fileName,
        'mimeType': mimeType,
        'properties': [
          {'key': 'deviceId', 'value': deviceId, 'visibility': 'PRIVATE'},
        ],
      },
      bytes: bytes,
      contentType: mimeType,
      expectedEtag: expectedEtag,
    );
    if (_isConflictStatus(response.statusCode)) {
      throw const SyncConflictException();
    }
    _throwForResponse(response, 'upload Mangatan EPUB manifest');
    return _validatedV2Mutation(
      response.body,
      expectedId: target.id,
      expectedTitle: fileName,
      expectedPrivateDeviceId: deviceId,
    );
  }

  Future<_DriveFile> _uploadMultipart(Uint8List bytes) async {
    final metadata = <String, Object>{
      'name': remoteFileName,
      'mimeType': 'application/x-gzip',
      'appProperties': {'deviceId': deviceId},
      'parents': ['appDataFolder'],
    };
    final response = await _sendMultipart(
      method: 'POST',
      uri: Uri.https(_apiHost, '/upload/drive/v3/files', {
        'uploadType': 'multipart',
        'fields': 'id,name,mimeType,modifiedTime,version,appProperties',
      }),
      metadata: metadata,
      bytes: bytes,
    );
    _throwForResponse(response, 'upload Google Drive sync data');
    final decoded = _decodeJsonObject(response.body);
    final uploaded = _DriveFile.fromJson(decoded);
    if (uploaded.id.isEmpty ||
        uploaded.name != remoteFileName ||
        uploaded.version.isEmpty) {
      throw const SyncStorageException(
        'Google Drive returned incomplete sync file metadata',
      );
    }
    return uploaded;
  }

  Future<_DriveFile> _uploadNamedMultipart(
    Uint8List bytes, {
    required String fileName,
    required String mimeType,
    Map<String, String> appProperties = const {},
  }) async {
    final response = await _sendMultipart(
      method: 'POST',
      uri: Uri.https(_apiHost, '/upload/drive/v3/files', {
        'uploadType': 'multipart',
        'fields': 'id,name,mimeType,modifiedTime,version,appProperties',
      }),
      metadata: {
        'name': fileName,
        'mimeType': mimeType,
        'appProperties': {'deviceId': deviceId, ...appProperties},
        'parents': ['appDataFolder'],
      },
      bytes: bytes,
      contentType: mimeType,
    );
    _throwForResponse(response, 'upload Mangatan EPUB data');
    final uploaded = _DriveFile.fromJson(_decodeJsonObject(response.body));
    if (uploaded.id.isEmpty || uploaded.name != fileName) {
      throw const SyncStorageException(
        'Google Drive returned incomplete EPUB sync metadata',
      );
    }
    return uploaded;
  }

  Future<http.Response> _sendMultipart({
    required String method,
    required Uri uri,
    required Map<String, Object> metadata,
    required Uint8List bytes,
    String contentType = 'application/x-gzip',
    String? expectedEtag,
  }) async {
    final boundary = 'mangatan-drive-${DateTime.now().microsecondsSinceEpoch}';
    final body = BytesBuilder(copy: false)
      ..add(
        utf8.encode(
          '--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '${jsonEncode(metadata)}\r\n'
          '--$boundary\r\n'
          'Content-Type: $contentType\r\n\r\n',
        ),
      )
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--\r\n'));
    final request = http.Request(method, uri)
      ..headers.addAll(_authorizationHeaders)
      ..headers['Content-Type'] = 'multipart/related; boundary=$boundary'
      ..bodyBytes = body.takeBytes();
    request.headers.addAll({'If-Match': ?expectedEtag});
    return http.Response.fromStream(await _client.send(request));
  }

  Future<void> _archive(
    _DownloadedDriveFile candidate, {
    required String expectedEtag,
  }) async {
    final reason = candidate.isValid ? 'duplicate' : 'corrupt';
    final archiveName = '$remoteFileName.mangatan-$reason-${candidate.file.id}';
    final response = await _client.patch(
      Uri.https(_apiHost, '/drive/v2/files/${candidate.file.id}', {
        'fields': _v2MetadataFields,
      }),
      headers: {
        ..._authorizationHeaders,
        'Content-Type': 'application/json; charset=UTF-8',
        'If-Match': expectedEtag,
      },
      body: jsonEncode({'title': archiveName}),
    );
    if (_isConflictStatus(response.statusCode)) {
      throw const SyncConflictException();
    }
    _throwForResponse(response, 'archive duplicate Google Drive sync data');
    final archived = _validatedV2Mutation(
      response.body,
      expectedId: candidate.file.id,
      expectedTitle: archiveName,
    );
    if (archived.id != candidate.file.id || archived.name != archiveName) {
      throw const SyncStorageException(
        'Google Drive did not confirm duplicate sync data was archived',
      );
    }
  }

  Future<_V2DriveFileMetadata> _readV2Metadata(
    _DriveFile expected, {
    String? expectedName,
  }) async {
    final response = await _client.get(
      Uri.https(_apiHost, '/drive/v2/files/${expected.id}', {
        'fields': _v2MetadataFields,
      }),
      headers: _authorizationHeaders,
    );
    if (_isConflictStatus(response.statusCode)) {
      throw const SyncConflictException();
    }
    _throwForResponse(response, 'read Google Drive sync metadata');
    final metadata = _V2DriveFileMetadata.fromJson(
      _decodeJsonObject(response.body),
    );
    if (metadata.id != expected.id ||
        metadata.title != (expectedName ?? expected.name) ||
        metadata.version != expected.version ||
        metadata.appDataContents != true ||
        metadata.trashed != false) {
      throw const SyncConflictException();
    }
    _requireStrongQuotedEtag(metadata.etag, expected.id);
    return metadata;
  }

  _DriveFile _validatedV2Mutation(
    String body, {
    required String expectedId,
    String? expectedTitle,
    String? expectedPrivateDeviceId,
  }) {
    final metadata = _V2DriveFileMetadata.fromJson(_decodeJsonObject(body));
    if (metadata.id != expectedId ||
        metadata.title != (expectedTitle ?? remoteFileName) ||
        metadata.version.isEmpty ||
        metadata.appDataContents != true ||
        metadata.trashed != false) {
      throw const SyncStorageException(
        'Google Drive returned incomplete sync file metadata',
      );
    }
    if (expectedPrivateDeviceId != null &&
        metadata.privateProperties['deviceId'] != expectedPrivateDeviceId) {
      throw const SyncStorageException(
        'Google Drive did not confirm the sync file device identity',
      );
    }
    _requireStrongQuotedEtag(metadata.etag, expectedId);
    return metadata.toDriveFile();
  }

  Future<List<_DriveFile>> _listRemoteFiles() =>
      _listRemoteFilesByName(remoteFileName);

  Future<List<_DriveFile>> _listRemoteFilesByName(String fileName) async {
    final escapedName = fileName
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'");
    final filesById = <String, _DriveFile>{};
    final seenPageTokens = <String>{};
    String? pageToken;
    do {
      final response = await _client.get(
        Uri.https(_apiHost, '/drive/v3/files', {
          'spaces': 'appDataFolder',
          'q': "name = '$escapedName' and trashed = false",
          'fields':
              'nextPageToken,files(id,name,mimeType,modifiedTime,version,'
              'appProperties)',
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
          final file = _DriveFile.fromJson(value.cast<String, dynamic>());
          if (file.id.isEmpty || file.name != fileName) continue;
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
    final files = filesById.values.toList();
    files.sort(_DriveFile.newestFirst);
    return files;
  }

  String _snapshotRevision(
    _DriveFile canonical,
    Iterable<_DownloadedDriveFile> candidates,
  ) {
    final revisions =
        candidates.map((candidate) => candidate.file.revision).toList()..sort();
    final digest = crypto.sha256.convert(utf8.encode(revisions.join('\n')));
    return '${canonical.revision}:$digest';
  }

  void _rememberObservation(_DriveDownloadObservation observation) {
    _downloadObservations[observation.revision] = observation;
    while (_downloadObservations.length > 8) {
      _downloadObservations.remove(_downloadObservations.keys.first);
    }
  }

  bool _sameDownloadedFileVersions(
    Iterable<_DriveFile> current,
    Iterable<_DownloadedDriveFile> observed,
  ) => _sameDriveFileVersions(
    current,
    observed.map((candidate) => candidate.file),
  );

  bool _sameDriveFileVersions(
    Iterable<_DriveFile> current,
    Iterable<_DriveFile> expected,
  ) {
    final currentRevisions = current.map((file) => file.revision).toList()
      ..sort();
    final expectedRevisions = expected.map((file) => file.revision).toList()
      ..sort();
    if (currentRevisions.length != expectedRevisions.length) return false;
    for (var index = 0; index < currentRevisions.length; index++) {
      if (currentRevisions[index] != expectedRevisions[index]) return false;
    }
    return true;
  }

  String _requireStrongEtag(_DownloadedDriveFile candidate) {
    return _requireStrongQuotedEtag(candidate.etag, candidate.file.id);
  }

  String _requireStrongQuotedEtag(String? value, String fileId) {
    final etag = value;
    final opaqueTag = etag != null && etag.length >= 2
        ? etag.substring(1, etag.length - 1)
        : null;
    if (etag == null ||
        etag.length < 2 ||
        etag.startsWith('W/') ||
        !etag.startsWith('"') ||
        !etag.endsWith('"') ||
        opaqueTag!.codeUnits.any(
          (unit) => unit == 0x22 || unit < 0x21 || (unit > 0x7e && unit < 0x80),
        )) {
      throw SyncStorageException(
        'Google Drive did not provide a strong ETag for $fileId; refusing an '
        'unsafe update',
      );
    }
    return etag;
  }

  bool _isConflictStatus(int statusCode) =>
      statusCode == 404 || statusCode == 409 || statusCode == 412;

  @override
  void close() {
    if (_ownsClient) _client.close();
  }

  Map<String, dynamic> _decodeJsonObject(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // Report a transport-level error without leaking response contents.
    }
    throw const SyncStorageException(
      'Google Drive returned an invalid JSON response',
    );
  }

  void _throwForResponse(http.Response response, String operation) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    var detail = '';
    try {
      final decoded = jsonDecode(response.body);
      final error = decoded is Map ? decoded['error'] : null;
      final message = error is Map ? error['message'] : null;
      if (message is String && message.isNotEmpty) detail = ': $message';
    } on FormatException {
      // The HTTP status remains enough to diagnose the request.
    }
    throw SyncStorageException(
      'Failed to $operation$detail',
      statusCode: response.statusCode,
    );
  }
}

class _DownloadedDriveFile {
  const _DownloadedDriveFile({
    required this.file,
    required this.isValid,
    required this.etag,
  });

  final _DriveFile file;
  final bool isValid;
  final String? etag;
}

class _DriveDownloadObservation {
  const _DriveDownloadObservation({
    required this.revision,
    required this.canonical,
    required this.candidates,
  });

  final String revision;
  final _DownloadedDriveFile canonical;
  final List<_DownloadedDriveFile> candidates;
}

class _DriveFile {
  const _DriveFile({
    required this.id,
    required this.name,
    required this.version,
    required this.modifiedTime,
  });

  factory _DriveFile.fromJson(Map<String, dynamic> json) => _DriveFile(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    version: json['version']?.toString() ?? '',
    modifiedTime: DateTime.tryParse(json['modifiedTime']?.toString() ?? ''),
  );

  final String id;
  final String name;
  final String version;
  final DateTime? modifiedTime;

  String get revision => '$id:$version';

  static int newestFirst(_DriveFile first, _DriveFile second) {
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

class _V2DriveFileMetadata {
  const _V2DriveFileMetadata({
    required this.id,
    required this.title,
    required this.version,
    required this.modifiedDate,
    required this.etag,
    required this.appDataContents,
    required this.trashed,
    required this.privateProperties,
  });

  factory _V2DriveFileMetadata.fromJson(Map<String, dynamic> json) {
    final labels = json['labels'];
    final appDataContents = json['appDataContents'];
    final trashed = labels is Map ? labels['trashed'] : null;
    return _V2DriveFileMetadata(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      version: json['version']?.toString() ?? '',
      modifiedDate: DateTime.tryParse(json['modifiedDate']?.toString() ?? ''),
      etag: _normalize(json['etag']?.toString()),
      appDataContents: appDataContents is bool ? appDataContents : null,
      trashed: trashed is bool ? trashed : null,
      privateProperties: Map.unmodifiable(
        _privateProperties(json['properties']),
      ),
    );
  }

  final String id;
  final String title;
  final String version;
  final DateTime? modifiedDate;
  final String? etag;
  final bool? appDataContents;
  final bool? trashed;
  final Map<String, String> privateProperties;

  _DriveFile toDriveFile() => _DriveFile(
    id: id,
    name: title,
    version: version,
    modifiedTime: modifiedDate,
  );

  static String? _normalize(String? value) {
    return value == null || value.isEmpty ? null : value;
  }

  static Map<String, String> _privateProperties(Object? raw) {
    final result = <String, String>{};
    if (raw is! List) return result;
    for (final property in raw.whereType<Map>()) {
      if (property['visibility']?.toString() != 'PRIVATE') continue;
      final key = _normalize(property['key']?.toString());
      final value = property['value']?.toString();
      if (key != null && value != null) result[key] = value;
    }
    return result;
  }
}
