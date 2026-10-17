import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:mangayomi/services/http/idle_timeout_client.dart';
import 'package:mangayomi/services/sync/chimahon_sync_codec.dart';

class RemoteSyncSnapshot {
  const RemoteSyncSnapshot({
    required this.bytes,
    this.revision,
    this.isCompleteRecovery = false,
    this.uploadRetainsAllRemoteByteBlobs = false,
  });

  final Uint8List bytes;
  final String? revision;

  /// Whether [bytes] alone are a complete, exact recovery of the remote state
  /// represented by this snapshot.
  ///
  /// This deliberately defaults to false. A provider must opt in only when a
  /// single importable file can restore everything that an update may replace
  /// or archive. For example, a logical merge of duplicate cloud files is not
  /// an exact recovery of those files even when its decoded records are
  /// complete.
  final bool isCompleteRecovery;

  /// Whether an upload conditional on this snapshot retains every exact
  /// remote byte blob represented by it, including when the upload fails
  /// partway through.
  ///
  /// This deliberately defaults to false. A provider may opt in only when its
  /// snapshot-specific write path never overwrites or deletes any of the
  /// pre-existing blobs. Renaming those blobs is allowed. This proof lets a
  /// pre-upload safety gate proceed when duplicate remote files cannot be
  /// represented by one exact local recovery file.
  final bool uploadRetainsAllRemoteByteBlobs;
}

abstract interface class CrossDeviceSyncStorage {
  ChimahonSyncWireFormat get wireFormat;

  Future<RemoteSyncSnapshot?> download();

  Future<String?> upload(
    Uint8List bytes, {
    String? expectedRevision,
    bool expectedAbsent = false,
  });
}

abstract interface class ClosableSyncStorage {
  void close();
}

class SyncStorageException implements Exception {
  const SyncStorageException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() =>
      statusCode == null ? message : '$message (HTTP status $statusCode)';
}

/// Local data changed while a sync was in progress, so the sync stopped
/// before overwriting it. Retrying uses the newer local state.
class SyncLocalDataChangedException extends SyncStorageException {
  const SyncLocalDataChangedException(super.message);
}

class SyncConflictException extends SyncStorageException {
  const SyncConflictException()
    : super('The remote sync payload changed during synchronization');
}

/// Transport implementation for SyncYomi's `/api/sync/content` protocol.
/// Authentication details are supplied by a future settings/UI layer.
class SyncYomiStorage implements CrossDeviceSyncStorage, ClosableSyncStorage {
  SyncYomiStorage({
    required this.baseUrl,
    required this.apiToken,
    http.Client? client,
  }) : _client = client ?? IdleTimeoutClient(http.Client()),
       _ownsClient = client == null;

  final Uri baseUrl;
  final String apiToken;
  final http.Client _client;
  final bool _ownsClient;

  @override
  ChimahonSyncWireFormat get wireFormat => ChimahonSyncWireFormat.protobuf;

  Uri get _contentUri => baseUrl.resolve('/api/sync/content');

  Map<String, String> _headers({String? revision}) => {
    'X-API-Token': apiToken,
    if (revision != null && revision.isNotEmpty) 'If-Match': revision,
  };

  @override
  Future<RemoteSyncSnapshot?> download() async {
    final response = await _client.get(_contentUri, headers: _headers());
    if (response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SyncStorageException(
        'Failed to download SyncYomi data',
        statusCode: response.statusCode,
      );
    }
    return RemoteSyncSnapshot(
      bytes: response.bodyBytes,
      revision: _requireEtag(response, operation: 'download'),
      isCompleteRecovery: true,
    );
  }

  @override
  Future<String?> upload(
    Uint8List bytes, {
    String? expectedRevision,
    bool expectedAbsent = false,
  }) async {
    final response = await _client.put(
      _contentUri,
      headers: {
        ..._headers(revision: expectedRevision),
        if (expectedAbsent) 'If-None-Match': '*',
        'Content-Type': 'application/octet-stream',
      },
      body: bytes,
    );
    if (response.statusCode == 412) throw const SyncConflictException();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SyncStorageException(
        'Failed to upload SyncYomi data',
        statusCode: response.statusCode,
      );
    }
    return _requireEtag(response, operation: 'upload');
  }

  String _requireEtag(http.Response response, {required String operation}) {
    final etag = response.headers['etag']?.trim();
    if (etag == null || etag.isEmpty) {
      throw SyncStorageException(
        'SyncYomi did not provide an ETag after a successful $operation; '
        'refusing unsafe synchronization',
      );
    }
    return etag;
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}
