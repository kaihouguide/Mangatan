import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:mangayomi/services/http/idle_timeout_client.dart';
import 'package:mangayomi/services/sync/google_drive_sync_storage.dart';

/// An explicitly invoked, destructive capability probe for Drive v2 ETags.
///
/// The probe never accepts a file ID or filename from its caller. It creates a
/// uniquely named file in `appDataFolder`, marks that file with a private Drive
/// property, and confines every write to the ID returned by that create call.
/// In particular, it never lists, reads, or writes Chimahon's canonical sync
/// filename.
///
/// This class is deliberately not wired into normal synchronization or app
/// startup. A caller must supply an already-authorized access token and invoke
/// [run] directly. Production synchronization relies only on Drive v2's
/// documented `File.etag`, so the probe gates only that validator. Response
/// header ETags are reported as observations but are never used for writes.
class GoogleDriveConditionalWriteProbe {
  GoogleDriveConditionalWriteProbe({
    required this.accessToken,
    http.Client? client,
  }) : _client = client ?? IdleTimeoutClient(http.Client()),
       _ownsClient = client == null {
    if (accessToken.trim().isEmpty) {
      throw ArgumentError.value(
        accessToken,
        'accessToken',
        'must not be empty',
      );
    }
  }

  static const probeFileNamePrefix =
      'Mangatan_google_drive_conditional_write_probe_';
  static const probeFileNameSuffix = '.tmp';
  static const ownershipPropertyKey = 'mangatanSyncCasProbe';
  static const _apiHost = 'www.googleapis.com';
  static const _metadataFields =
      'id,title,description,mimeType,etag,version,appDataContents,'
      'properties,labels';

  final String accessToken;
  final http.Client _client;
  final bool _ownsClient;
  final Random _random = Random.secure();
  bool _running = false;

  Map<String, String> get _authorizationHeaders => {
    'Authorization': 'Bearer $accessToken',
    'Accept': 'application/json',
  };

  /// Runs the probe against one newly created disposable file.
  ///
  /// The v2 resource-body ETag is mandatory because it is Drive v2's
  /// documented file validator. It is tested against both the metadata PATCH
  /// and multipart media-update endpoints. Response-header ETags are recorded
  /// for diagnostics only: a media response can describe a representation
  /// other than the Drive `File` resource and is not assumed interchangeable.
  Future<GoogleDriveConditionalWriteProbeResult> run() async {
    if (_running) {
      throw StateError(
        'A Google Drive conditional-write probe is already running',
      );
    }
    _running = true;

    final target = _newTarget();
    final availability =
        <
          GoogleDriveProbeValidatorSource,
          GoogleDriveProbeValidatorAvailability
        >{
          for (final source in GoogleDriveProbeValidatorSource.values)
            source: GoogleDriveProbeValidatorAvailability.notObserved,
        };
    final completedPairings = <GoogleDriveProbePairingResult>[];
    _ProbeFailure? failure;
    StackTrace? failureStackTrace;
    late GoogleDriveProbeCleanup cleanup;

    try {
      try {
        await _createProbeFile(target);
        final initial = await _readEvidence(target);
        for (final source in GoogleDriveProbeValidatorSource.values) {
          availability[source] = _availability(initial.validatorFor(source));
        }
        if (availability[GoogleDriveProbeValidatorSource.v2ResourceEtag] !=
            GoogleDriveProbeValidatorAvailability.strong) {
          throw const _ProbeFailure(
            'Drive v2 did not return a strong resource ETag for the disposable '
            'probe file',
          );
        }

        const productionSource = GoogleDriveProbeValidatorSource.v2ResourceEtag;
        for (final endpoint in GoogleDriveProbeWriteEndpoint.values) {
          completedPairings.add(
            await _probePairing(
              target,
              source: productionSource,
              endpoint: endpoint,
            ),
          );
        }
      } on _ProbeFailure catch (error, stackTrace) {
        failure = error;
        failureStackTrace = stackTrace;
      } catch (_, stackTrace) {
        failure = const _ProbeFailure(
          'The conditional-write probe encountered an unexpected transport or '
          'response failure',
        );
        failureStackTrace = stackTrace;
      }
    } finally {
      try {
        cleanup = await _cleanup(target);
      } finally {
        _running = false;
      }
    }

    if (failure != null) {
      final exception = GoogleDriveConditionalWriteProbeException(
        message: failure.message,
        statusCode: failure.statusCode,
        generatedFileName: target.name,
        validatorAvailability: Map.unmodifiable(availability),
        completedPairings: List.unmodifiable(completedPairings),
        cleanup: cleanup,
      );
      Error.throwWithStackTrace(exception, failureStackTrace!);
    }

    return GoogleDriveConditionalWriteProbeResult(
      generatedFileName: target.name,
      validatorAvailability: Map.unmodifiable(availability),
      pairings: List.unmodifiable(completedPairings),
      cleanup: cleanup,
    );
  }

  _ProbeTarget _newTarget() {
    final nameNonce = _randomHex(16);
    final marker = _randomHex(16);
    final name =
        '$probeFileNamePrefix'
        '${DateTime.now().toUtc().microsecondsSinceEpoch}_$nameNonce'
        '$probeFileNameSuffix';
    if (name == GoogleDriveSyncStorage.chimahonRemoteFileName ||
        !name.startsWith(probeFileNamePrefix)) {
      throw StateError('Failed to generate a safe Drive probe filename');
    }
    return _ProbeTarget(name: name, marker: marker);
  }

  String _randomHex(int byteCount) {
    final buffer = StringBuffer();
    for (var index = 0; index < byteCount; index++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  Future<void> _createProbeFile(_ProbeTarget target) async {
    final metadata = <String, Object>{
      'title': target.name,
      'description': _description(target, 'created'),
      'mimeType': 'application/octet-stream',
      'parents': [
        {'id': 'appDataFolder'},
      ],
      'properties': [
        {
          'key': ownershipPropertyKey,
          'value': target.marker,
          'visibility': 'PRIVATE',
        },
      ],
    };
    final request = _multipartRequest(
      method: 'POST',
      uri: Uri.https(_apiHost, '/upload/drive/v2/files', {
        'uploadType': 'multipart',
        'fields': _metadataFields,
      }),
      metadata: metadata,
      bytes: Uint8List.fromList(utf8.encode(_mediaSentinel(target, 'created'))),
      boundary: _boundary(target, 'create'),
    );
    final response = await _send(request);
    _requireSuccess(response, 'create the disposable Drive probe file');
    final decoded = _decodeJsonObject(response.body);
    final returnedId = _normalized(decoded['id']?.toString());
    if (returnedId == null || !_safeDriveFileId.hasMatch(returnedId)) {
      throw const _ProbeFailure(
        'Drive did not return a safe disposable probe file ID',
      );
    }
    target.id = returnedId;
    _requireOwnedMetadata(target, _V2FileMetadata.fromJson(decoded));
  }

  Future<GoogleDriveProbePairingResult> _probePairing(
    _ProbeTarget target, {
    required GoogleDriveProbeValidatorSource source,
    required GoogleDriveProbeWriteEndpoint endpoint,
  }) async {
    final before = await _readEvidence(target);
    final validator = before.validatorFor(source);
    if (!_isStrongEtag(validator)) {
      throw _ProbeFailure(
        'The ${source.name} validator disappeared or became weak during the '
        'probe',
      );
    }

    final pairingName = '${source.name}_${endpoint.name}';
    final matchingDescription = _description(target, 'matching_$pairingName');
    final staleDescription = _description(target, 'stale_$pairingName');
    final matchingMedia = Uint8List.fromList(
      utf8.encode(_mediaSentinel(target, 'matching_$pairingName')),
    );
    final staleMedia = Uint8List.fromList(
      utf8.encode(_mediaSentinel(target, 'stale_$pairingName')),
    );

    final matchingResponse =
        endpoint == GoogleDriveProbeWriteEndpoint.v2MetadataPatch
        ? await _metadataPatch(
            target,
            description: matchingDescription,
            validator: validator!,
          )
        : await _multipartMediaUpdate(
            target,
            description: matchingDescription,
            bytes: matchingMedia,
            validator: validator!,
            phase: 'matching_$pairingName',
          );
    if (matchingResponse.statusCode < 200 ||
        matchingResponse.statusCode >= 300) {
      throw _ProbeFailure(
        'Drive rejected a matching If-Match for ${source.name} and '
        '${endpoint.name}',
        statusCode: matchingResponse.statusCode,
      );
    }

    final staleResponse =
        endpoint == GoogleDriveProbeWriteEndpoint.v2MetadataPatch
        ? await _metadataPatch(
            target,
            description: staleDescription,
            validator: validator,
          )
        : await _multipartMediaUpdate(
            target,
            description: staleDescription,
            bytes: staleMedia,
            validator: validator,
            phase: 'stale_$pairingName',
          );
    if (staleResponse.statusCode != 412) {
      throw _ProbeFailure(
        'Drive did not return 412 for a stale If-Match using ${source.name} '
        'and ${endpoint.name}',
        statusCode: staleResponse.statusCode,
      );
    }

    final after = await _readEvidence(target);
    if (after.metadata.description != matchingDescription ||
        after.metadata.description == staleDescription) {
      throw _ProbeFailure(
        'Drive returned 412 but the stale metadata sentinel was applied for '
        '${source.name} and ${endpoint.name}',
      );
    }
    if (endpoint == GoogleDriveProbeWriteEndpoint.v2MultipartMediaUpdate &&
        (!_bytesEqual(after.mediaBytes, matchingMedia) ||
            _bytesEqual(after.mediaBytes, staleMedia))) {
      throw _ProbeFailure(
        'Drive returned 412 but the stale media sentinel was applied for '
        '${source.name} and ${endpoint.name}',
      );
    }

    return GoogleDriveProbePairingResult(
      validatorSource: source,
      endpoint: endpoint,
      matchingStatusCode: matchingResponse.statusCode,
      staleStatusCode: staleResponse.statusCode,
      sentinelVerified: true,
    );
  }

  Future<http.Response> _metadataPatch(
    _ProbeTarget target, {
    required String description,
    required String validator,
  }) async {
    final request =
        http.Request(
            'PATCH',
            Uri.https(_apiHost, '/drive/v2/files/${target.requireId}', {
              'fields': _metadataFields,
            }),
          )
          ..headers.addAll(_authorizationHeaders)
          ..headers['Content-Type'] = 'application/json; charset=UTF-8'
          ..headers['If-Match'] = validator
          ..body = jsonEncode({'description': description});
    return _send(request);
  }

  Future<http.Response> _multipartMediaUpdate(
    _ProbeTarget target, {
    required String description,
    required Uint8List bytes,
    required String validator,
    required String phase,
  }) {
    final request = _multipartRequest(
      // Drive v2 files.update requires PUT for its /upload URI. The PATCH
      // method is valid only on the metadata resource URI.
      method: 'PUT',
      uri: Uri.https(_apiHost, '/upload/drive/v2/files/${target.requireId}', {
        'uploadType': 'multipart',
        'fields': _metadataFields,
      }),
      metadata: {'description': description},
      bytes: bytes,
      boundary: _boundary(target, phase),
      validator: validator,
    );
    return _send(request);
  }

  http.Request _multipartRequest({
    required String method,
    required Uri uri,
    required Map<String, Object> metadata,
    required Uint8List bytes,
    required String boundary,
    String? validator,
  }) {
    final body = BytesBuilder(copy: false)
      ..add(
        utf8.encode(
          '--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '${jsonEncode(metadata)}\r\n'
          '--$boundary\r\n'
          'Content-Type: application/octet-stream\r\n\r\n',
        ),
      )
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--\r\n'));
    return http.Request(method, uri)
      ..headers.addAll(_authorizationHeaders)
      ..headers['Content-Type'] = 'multipart/related; boundary=$boundary'
      ..headers.addAll({'If-Match': ?validator})
      ..bodyBytes = body.takeBytes();
  }

  Future<_ProbeEvidence> _readEvidence(_ProbeTarget target) async {
    final metadataResponse = await _client.get(
      _metadataUri(target.requireId),
      headers: _authorizationHeaders,
    );
    _requireSuccess(metadataResponse, 'read disposable probe metadata');
    final metadata = _V2FileMetadata.fromJson(
      _decodeJsonObject(metadataResponse.body),
    );
    _requireOwnedMetadata(target, metadata);

    final mediaResponse = await _client.get(
      Uri.https(_apiHost, '/drive/v2/files/${target.requireId}', {
        'alt': 'media',
      }),
      headers: _authorizationHeaders,
    );
    _requireSuccess(mediaResponse, 'read disposable probe media');
    return _ProbeEvidence(
      metadata: metadata,
      metadataHeaderEtag: _normalized(metadataResponse.headers['etag']),
      mediaHeaderEtag: _normalized(mediaResponse.headers['etag']),
      mediaBytes: mediaResponse.bodyBytes,
    );
  }

  Future<GoogleDriveProbeCleanup> _cleanup(_ProbeTarget target) async {
    if (target.id == null) {
      return GoogleDriveProbeCleanup(
        disposition: GoogleDriveProbeCleanupDisposition.unknownCreationOutcome,
        reason: GoogleDriveProbeCleanupReason.noReturnedFileId,
        generatedFileName: target.name,
      );
    }

    try {
      final metadataResponse = await _client.get(
        _metadataUri(target.requireId),
        headers: _authorizationHeaders,
      );
      if (metadataResponse.statusCode == 404) {
        return GoogleDriveProbeCleanup(
          disposition: GoogleDriveProbeCleanupDisposition.alreadyAbsent,
          generatedFileName: target.name,
          fileIdSha256: _sha256(target.requireId),
        );
      }
      if (metadataResponse.statusCode < 200 ||
          metadataResponse.statusCode >= 300) {
        return _leftProbeFile(
          target,
          GoogleDriveProbeCleanupReason.metadataReadRejected,
        );
      }

      late final _V2FileMetadata metadata;
      try {
        metadata = _V2FileMetadata.fromJson(
          _decodeJsonObject(metadataResponse.body),
        );
        _requireOwnedMetadata(target, metadata);
      } on _ProbeFailure {
        return GoogleDriveProbeCleanup(
          disposition:
              GoogleDriveProbeCleanupDisposition.leftUnverifiedFileUntouched,
          reason: GoogleDriveProbeCleanupReason.ownershipGuardFailed,
          generatedFileName: target.name,
          fileIdSha256: _sha256(target.requireId),
        );
      }

      // Keep cleanup on the same documented File.etag contract as the probe.
      // Response headers are diagnostic observations, not write validators.
      final validator = metadata.resourceEtag;
      if (!_isStrongEtag(validator)) {
        return _leftProbeFile(
          target,
          GoogleDriveProbeCleanupReason.noStrongCleanupEtag,
        );
      }

      final deleteRequest =
          http.Request(
              'DELETE',
              Uri.https(_apiHost, '/drive/v2/files/${target.requireId}'),
            )
            ..headers.addAll(_authorizationHeaders)
            ..headers['If-Match'] = validator!;
      final deleteResponse = await _send(deleteRequest);
      if (deleteResponse.statusCode == 404) {
        return GoogleDriveProbeCleanup(
          disposition: GoogleDriveProbeCleanupDisposition.alreadyAbsent,
          generatedFileName: target.name,
          fileIdSha256: _sha256(target.requireId),
        );
      }
      if (deleteResponse.statusCode < 200 || deleteResponse.statusCode >= 300) {
        return _leftProbeFile(
          target,
          GoogleDriveProbeCleanupReason.deleteRejected,
        );
      }

      final confirmation = await _client.get(
        _metadataUri(target.requireId),
        headers: _authorizationHeaders,
      );
      if (confirmation.statusCode != 404) {
        return _leftProbeFile(
          target,
          GoogleDriveProbeCleanupReason.deleteNotConfirmed,
        );
      }
      return GoogleDriveProbeCleanup(
        disposition: GoogleDriveProbeCleanupDisposition.deleted,
        generatedFileName: target.name,
        fileIdSha256: _sha256(target.requireId),
      );
    } catch (_) {
      return _leftProbeFile(
        target,
        GoogleDriveProbeCleanupReason.cleanupRequestFailed,
      );
    }
  }

  GoogleDriveProbeCleanup _leftProbeFile(
    _ProbeTarget target,
    GoogleDriveProbeCleanupReason reason,
  ) => GoogleDriveProbeCleanup(
    disposition: GoogleDriveProbeCleanupDisposition.leftProbeNamedFile,
    reason: reason,
    generatedFileName: target.name,
    fileIdSha256: _sha256(target.requireId),
  );

  Uri _metadataUri(String id) =>
      Uri.https(_apiHost, '/drive/v2/files/$id', {'fields': _metadataFields});

  void _requireOwnedMetadata(_ProbeTarget target, _V2FileMetadata metadata) {
    if (target.id == null ||
        metadata.id != target.id ||
        metadata.title != target.name ||
        metadata.title == GoogleDriveSyncStorage.chimahonRemoteFileName ||
        !metadata.title.startsWith(probeFileNamePrefix) ||
        metadata.appDataContents != true ||
        metadata.trashed == true ||
        metadata.properties[ownershipPropertyKey] != target.marker) {
      throw const _ProbeFailure(
        'The disposable Drive file failed its ID, name, appData, or ownership '
        'marker guard',
      );
    }
  }

  Future<http.Response> _send(http.BaseRequest request) async =>
      http.Response.fromStream(await _client.send(request));

  void _requireSuccess(http.Response response, String operation) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw _ProbeFailure(
      'Failed to $operation',
      statusCode: response.statusCode,
    );
  }

  Map<String, dynamic> _decodeJsonObject(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // Do not include a Drive response body in a probe error.
    }
    throw const _ProbeFailure('Drive returned invalid probe metadata');
  }

  GoogleDriveProbeValidatorAvailability _availability(String? value) {
    if (value == null) return GoogleDriveProbeValidatorAvailability.absent;
    return _isStrongEtag(value)
        ? GoogleDriveProbeValidatorAvailability.strong
        : GoogleDriveProbeValidatorAvailability.weakOrInvalid;
  }

  bool _isStrongEtag(String? value) {
    if (value == null ||
        value.length < 2 ||
        value.startsWith('W/') ||
        !value.startsWith('"') ||
        !value.endsWith('"')) {
      return false;
    }
    final opaqueTag = value.substring(1, value.length - 1);
    return !opaqueTag.codeUnits.any(
      (unit) => unit == 0x22 || unit < 0x21 || (unit > 0x7e && unit < 0x80),
    );
  }

  bool _bytesEqual(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  String? _normalized(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  String _description(_ProbeTarget target, String phase) =>
      'Mangatan conditional-write probe ${target.marker}:$phase';

  String _mediaSentinel(_ProbeTarget target, String phase) =>
      'Mangatan conditional-write probe media ${target.marker}:$phase';

  String _boundary(_ProbeTarget target, String phase) =>
      'mangatan-drive-probe-${target.marker}-$phase';

  String _sha256(String value) => sha256.convert(utf8.encode(value)).toString();

  static final _safeDriveFileId = RegExp(r'^[A-Za-z0-9_-]+$');

  void close() {
    if (_ownsClient) _client.close();
  }
}

enum GoogleDriveProbeValidatorSource {
  v2ResourceEtag,
  v2MetadataResponseHeaderEtag,
  v2MediaResponseHeaderEtag,
}

enum GoogleDriveProbeValidatorAvailability {
  notObserved,
  absent,
  weakOrInvalid,
  strong,
}

enum GoogleDriveProbeWriteEndpoint { v2MetadataPatch, v2MultipartMediaUpdate }

class GoogleDriveProbePairingResult {
  const GoogleDriveProbePairingResult({
    required this.validatorSource,
    required this.endpoint,
    required this.matchingStatusCode,
    required this.staleStatusCode,
    required this.sentinelVerified,
  });

  final GoogleDriveProbeValidatorSource validatorSource;
  final GoogleDriveProbeWriteEndpoint endpoint;
  final int matchingStatusCode;
  final int staleStatusCode;
  final bool sentinelVerified;

  Map<String, Object> toSafeJson() => {
    'validatorSource': validatorSource.name,
    'endpoint': endpoint.name,
    'matchingStatusCode': matchingStatusCode,
    'staleStatusCode': staleStatusCode,
    'sentinelVerified': sentinelVerified,
  };
}

enum GoogleDriveProbeCleanupDisposition {
  deleted,
  alreadyAbsent,
  leftProbeNamedFile,
  leftUnverifiedFileUntouched,
  unknownCreationOutcome,
}

enum GoogleDriveProbeCleanupReason {
  noReturnedFileId,
  metadataReadRejected,
  ownershipGuardFailed,
  noStrongCleanupEtag,
  deleteRejected,
  deleteNotConfirmed,
  cleanupRequestFailed,
}

class GoogleDriveProbeCleanup {
  const GoogleDriveProbeCleanup({
    required this.disposition,
    required this.generatedFileName,
    this.reason,
    this.fileIdSha256,
  });

  final GoogleDriveProbeCleanupDisposition disposition;
  final GoogleDriveProbeCleanupReason? reason;
  final String generatedFileName;
  final String? fileIdSha256;

  bool get requiresManualCleanup =>
      disposition != GoogleDriveProbeCleanupDisposition.deleted &&
      disposition != GoogleDriveProbeCleanupDisposition.alreadyAbsent;

  Map<String, Object?> toSafeJson() => {
    'disposition': disposition.name,
    'reason': reason?.name,
    'generatedFileName': generatedFileName,
    'fileIdSha256': fileIdSha256,
    'requiresManualCleanup': requiresManualCleanup,
  };
}

class GoogleDriveConditionalWriteProbeResult {
  const GoogleDriveConditionalWriteProbeResult({
    required this.generatedFileName,
    required this.validatorAvailability,
    required this.pairings,
    required this.cleanup,
  });

  final String generatedFileName;
  final Map<
    GoogleDriveProbeValidatorSource,
    GoogleDriveProbeValidatorAvailability
  >
  validatorAvailability;
  final List<GoogleDriveProbePairingResult> pairings;
  final GoogleDriveProbeCleanup cleanup;

  bool pairingProven(
    GoogleDriveProbeValidatorSource source,
    GoogleDriveProbeWriteEndpoint endpoint,
  ) => pairings.any(
    (pairing) =>
        pairing.validatorSource == source &&
        pairing.endpoint == endpoint &&
        pairing.matchingStatusCode >= 200 &&
        pairing.matchingStatusCode < 300 &&
        pairing.staleStatusCode == 412 &&
        pairing.sentinelVerified,
  );

  Map<String, Object?> toSafeJson() => {
    'generatedFileName': generatedFileName,
    'validatorAvailability': {
      for (final entry in validatorAvailability.entries)
        entry.key.name: entry.value.name,
    },
    'pairings': [for (final pairing in pairings) pairing.toSafeJson()],
    'cleanup': cleanup.toSafeJson(),
  };
}

class GoogleDriveConditionalWriteProbeException implements Exception {
  const GoogleDriveConditionalWriteProbeException({
    required this.message,
    required this.statusCode,
    required this.generatedFileName,
    required this.validatorAvailability,
    required this.completedPairings,
    required this.cleanup,
  });

  final String message;
  final int? statusCode;
  final String generatedFileName;
  final Map<
    GoogleDriveProbeValidatorSource,
    GoogleDriveProbeValidatorAvailability
  >
  validatorAvailability;
  final List<GoogleDriveProbePairingResult> completedPairings;
  final GoogleDriveProbeCleanup cleanup;

  @override
  String toString() =>
      '$message${statusCode == null ? '' : ' (HTTP status $statusCode)'}; '
      'cleanup=${cleanup.disposition.name}; '
      'probeFile=$generatedFileName';
}

class _ProbeFailure implements Exception {
  const _ProbeFailure(this.message, {this.statusCode});

  final String message;
  final int? statusCode;
}

class _ProbeTarget {
  _ProbeTarget({required this.name, required this.marker});

  final String name;
  final String marker;
  String? id;

  String get requireId {
    final value = id;
    if (value == null || value.isEmpty) {
      throw const _ProbeFailure('The disposable Drive probe file has no ID');
    }
    return value;
  }
}

class _ProbeEvidence {
  const _ProbeEvidence({
    required this.metadata,
    required this.metadataHeaderEtag,
    required this.mediaHeaderEtag,
    required this.mediaBytes,
  });

  final _V2FileMetadata metadata;
  final String? metadataHeaderEtag;
  final String? mediaHeaderEtag;
  final Uint8List mediaBytes;

  String? validatorFor(GoogleDriveProbeValidatorSource source) =>
      switch (source) {
        GoogleDriveProbeValidatorSource.v2ResourceEtag => metadata.resourceEtag,
        GoogleDriveProbeValidatorSource.v2MetadataResponseHeaderEtag =>
          metadataHeaderEtag,
        GoogleDriveProbeValidatorSource.v2MediaResponseHeaderEtag =>
          mediaHeaderEtag,
      };
}

class _V2FileMetadata {
  const _V2FileMetadata({
    required this.id,
    required this.title,
    required this.description,
    required this.resourceEtag,
    required this.appDataContents,
    required this.trashed,
    required this.properties,
  });

  factory _V2FileMetadata.fromJson(Map<String, dynamic> json) {
    final rawProperties = json['properties'];
    final properties = <String, String>{};
    if (rawProperties is List) {
      for (final rawProperty in rawProperties.whereType<Map>()) {
        final key = rawProperty['key']?.toString();
        final value = rawProperty['value']?.toString();
        if (key != null && value != null) properties[key] = value;
      }
    }
    final labels = json['labels'];
    return _V2FileMetadata(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      resourceEtag: _normalizeStatic(json['etag']?.toString()),
      appDataContents: json['appDataContents'] as bool?,
      trashed: labels is Map ? labels['trashed'] as bool? : null,
      properties: Map.unmodifiable(properties),
    );
  }

  final String id;
  final String title;
  final String description;
  final String? resourceEtag;
  final bool? appDataContents;
  final bool? trashed;
  final Map<String, String> properties;

  static String? _normalizeStatic(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
