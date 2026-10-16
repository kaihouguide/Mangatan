import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:mangayomi/services/http/idle_timeout_client.dart';
import 'package:mangayomi/services/sync/chimahon_sync_codec.dart';
import 'package:mangayomi/services/sync/cross_device_sync_storage.dart';
import 'package:mangayomi/services/sync/mangatan_epub_blob_storage.dart';
import 'package:mangayomi/services/sync/mangatan_epub_sync_manifest.dart';
import 'package:mangayomi/services/sync/webdav_credential_store.dart';

class WebDavSyncStorage
    implements
        CrossDeviceSyncStorage,
        MangatanEpubBlobStorage,
        ClosableSyncStorage {
  WebDavSyncStorage({
    required Uri collectionUrl,
    required this.credentials,
    http.Client? client,
  }) : collectionUrl = _asCollectionUrl(collectionUrl),
       _client = client ?? IdleTimeoutClient(http.Client()),
       _ownsClient = client == null;

  static const chimahonRemoteFileName = 'Chimahon_sync.proto.gz';
  static const _manifestFileName = mangatanEpubManifestFileName;
  static const _blobCollection = 'mangatan-epub-blobs';
  static const _codec = ChimahonSyncCodec();

  final Uri collectionUrl;
  final WebDavCredentials credentials;
  final http.Client _client;
  final bool _ownsClient;

  @override
  ChimahonSyncWireFormat get wireFormat => ChimahonSyncWireFormat.gzipProtobuf;

  Future<void> testConnection() async {
    await _ensureCollections();
    final probeName =
        '.mangatan-webdav-probe-${DateTime.now().microsecondsSinceEpoch}-'
        '${Random.secure().nextInt(1 << 32)}';
    final probe = _child(probeName);
    final created = await _put(
      probe,
      Uint8List.fromList(utf8.encode('probe')),
      ifNoneMatch: '*',
      operation: 'create WebDAV conditional-write probe',
    );
    try {
      final etag = _requireEtag(created, operation: 'create probe');
      await _put(
        probe,
        Uint8List.fromList(utf8.encode('probe-updated')),
        ifMatch: etag,
        operation: 'update WebDAV conditional-write probe',
      );
    } finally {
      await _deleteBestEffort(probe);
    }
  }

  @override
  Future<RemoteSyncSnapshot?> download() async {
    final response = await _request('GET', _child(chimahonRemoteFileName));
    if (response.statusCode == 404) return null;
    _throwForResponse(response, 'download WebDAV Chimahon sync data');
    final etag = _requireEtag(response, operation: 'download sync data');
    return RemoteSyncSnapshot(
      bytes: response.bodyBytes,
      revision: etag,
      isCompleteRecovery: true,
    );
  }

  @override
  Future<String?> upload(
    Uint8List bytes, {
    String? expectedRevision,
    bool expectedAbsent = false,
  }) async {
    _codec.decode(bytes);
    await _ensureCollections();
    final response = await _put(
      _child(chimahonRemoteFileName),
      bytes,
      ifMatch: expectedRevision,
      ifNoneMatch: expectedAbsent ? '*' : null,
      operation: 'upload WebDAV Chimahon sync data',
    );
    return _requireEtag(response, operation: 'upload sync data');
  }

  @override
  Future<MangatanRemoteEpubManifest?> downloadEpubManifest() async {
    final response = await _request('GET', _child(_manifestFileName));
    if (response.statusCode == 404) return null;
    _throwForResponse(response, 'download WebDAV EPUB manifest');
    final etag = _requireEtag(response, operation: 'download EPUB manifest');
    return MangatanRemoteEpubManifest(
      manifest: MangatanEpubManifest.decode(response.bodyBytes),
      revision: etag,
    );
  }

  @override
  Future<String?> uploadEpubManifest(
    MangatanEpubManifest manifest, {
    String? expectedRevision,
    bool expectedAbsent = false,
  }) async {
    await _ensureCollections();
    final response = await _put(
      _child(_manifestFileName),
      Uint8List.fromList(manifest.encode()),
      contentType: 'application/json',
      ifMatch: expectedRevision,
      ifNoneMatch: expectedAbsent ? '*' : null,
      operation: 'upload WebDAV EPUB manifest',
    );
    return _requireEtag(response, operation: 'upload EPUB manifest');
  }

  @override
  Future<bool> hasEpubBlob(String sha256) async {
    final response = await _request('HEAD', _blobUri(sha256));
    if (response.statusCode == 404) return false;
    _throwForResponse(response, 'check WebDAV EPUB blob');
    _requireEtag(response, operation: 'check EPUB blob');
    return true;
  }

  @override
  Future<void> uploadEpubBlob({
    required String sha256,
    required int sizeBytes,
    required Stream<List<int>> bytes,
  }) async {
    if (await hasEpubBlob(sha256)) return;
    await _ensureCollections();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in bytes) {
      builder.add(chunk);
    }
    final payload = builder.takeBytes();
    if (payload.length != sizeBytes ||
        crypto.sha256.convert(payload).toString() != sha256) {
      throw SyncStorageException(
        'Refusing to upload WebDAV EPUB blob $sha256 because its content changed',
      );
    }
    await _put(
      _blobUri(sha256),
      payload,
      contentType: 'application/epub+zip',
      ifNoneMatch: '*',
      operation: 'upload WebDAV EPUB blob',
    );
  }

  @override
  Future<Uint8List> downloadEpubBlob(String sha256) async {
    final response = await _request('GET', _blobUri(sha256));
    if (response.statusCode == 404) {
      throw SyncStorageException('WebDAV EPUB blob $sha256 was not found');
    }
    _throwForResponse(response, 'download WebDAV EPUB blob');
    return Uint8List.fromList(response.bodyBytes);
  }

  Future<void> _ensureCollections() async {
    await _mkcol(collectionUrl);
    await _mkcol(_child(_blobCollection, collection: true));
  }

  Future<void> _mkcol(Uri uri) async {
    final response = await _request('MKCOL', uri);
    if (response.statusCode == 201 || response.statusCode == 405) return;
    if (response.statusCode == 301 ||
        response.statusCode == 302 ||
        response.statusCode == 307 ||
        response.statusCode == 308) {
      return;
    }
    _throwForResponse(response, 'create WebDAV collection');
  }

  Future<http.Response> _put(
    Uri uri,
    List<int> bytes, {
    String contentType = 'application/octet-stream',
    String? ifMatch,
    String? ifNoneMatch,
    required String operation,
  }) async {
    if (ifMatch == null && ifNoneMatch == null) {
      throw SyncStorageException(
        'Refusing blind WebDAV upload without an ETag precondition',
      );
    }
    final response = await _request(
      'PUT',
      uri,
      body: bytes,
      headers: {
        'Content-Type': contentType,
        'If-Match': ?ifMatch,
        'If-None-Match': ?ifNoneMatch,
      },
    );
    if (response.statusCode == 412 || response.statusCode == 409) {
      throw const SyncConflictException();
    }
    _throwForResponse(response, operation);
    _requireEtag(response, operation: operation);
    return response;
  }

  Future<http.Response> _request(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
    int redirectsRemaining = 5,
  }) async {
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll({
        'Authorization':
            'Basic ${base64Encode(utf8.encode('${credentials.username}:${credentials.password}'))}',
        'Accept': '*/*',
        ...headers,
      });
    if (body != null) request.bodyBytes = body;
    final response = await http.Response.fromStream(await _client.send(request));
    if (!_isRedirect(response.statusCode) || redirectsRemaining <= 0) {
      return response;
    }
    final location = response.headers['location'];
    if (location == null || location.isEmpty) return response;
    final target = uri.resolve(location);
    // Every request carries Basic credentials. Following a redirect to
    // another origin (or from https down to http) would hand them to that
    // server, so only same-origin redirects are followed.
    if (target.scheme != uri.scheme ||
        target.host.toLowerCase() != uri.host.toLowerCase() ||
        target.port != uri.port) {
      return response;
    }
    return _request(
      method,
      target,
      headers: headers,
      body: body,
      redirectsRemaining: redirectsRemaining - 1,
    );
  }

  bool _isRedirect(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 307 ||
      statusCode == 308;

  String _requireEtag(http.Response response, {required String operation}) {
    final etag = response.headers['etag']?.trim();
    if (etag == null ||
        etag.isEmpty ||
        etag.startsWith('W/') ||
        !etag.startsWith('"') ||
        !etag.endsWith('"')) {
      throw SyncStorageException(
        'WebDAV server did not provide a strong ETag after $operation; '
        'refusing unsafe synchronization',
        statusCode: response.statusCode,
      );
    }
    return etag;
  }

  void _throwForResponse(http.Response response, String operation) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    final message = response.reasonPhrase?.trim();
    throw SyncStorageException(
      'Failed to $operation${message == null || message.isEmpty ? '' : ': $message'}',
      statusCode: response.statusCode,
    );
  }

  Future<void> _deleteBestEffort(Uri uri) async {
    try {
      await _request('DELETE', uri);
    } catch (_) {}
  }

  Uri _child(String name, {bool collection = false}) {
    final encoded = Uri.encodeComponent(name);
    return collectionUrl.resolve(collection ? '$encoded/' : encoded);
  }

  Uri _blobUri(String sha256) =>
      _child(_blobCollection, collection: true).resolve('$sha256.epub');

  static Uri _asCollectionUrl(Uri uri) {
    final text = uri.toString();
    return text.endsWith('/') ? uri : Uri.parse('$text/');
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}
