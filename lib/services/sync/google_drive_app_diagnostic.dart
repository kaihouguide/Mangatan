import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mangayomi/services/http/idle_timeout_client.dart';
import 'package:mangayomi/services/sync/chimahon_sync_codec.dart';
import 'package:mangayomi/services/sync/google_drive_chimahon_preview_runner.dart';
import 'package:mangayomi/services/sync/google_drive_conditional_write_probe.dart';
import 'package:mangayomi/services/sync/google_drive_oauth.dart';
import 'package:mangayomi/services/sync/google_drive_read_only_inspector.dart';
import 'package:mangayomi/services/sync/google_drive_refresh_token_store.dart';

typedef GoogleDriveDiagnosticTokenRefresher =
    Future<String> Function(String refreshToken);
typedef GoogleDriveDiagnosticInspector =
    Future<Map<String, Object?>> Function(String accessToken);
typedef GoogleDriveDiagnosticConditionalWriteProbe =
    Future<Map<String, Object?>> Function(String accessToken);
typedef GoogleDriveDiagnosticSyncPreview =
    Future<Map<String, Object?>> Function(Uint8List referenceBackupBytes);

/// Runs a Drive diagnostic from inside Mangatan's process.
///
/// The process therefore accesses its own platform credential store;
/// command-line tools never receive either OAuth token. Inspection maps come
/// exclusively from [GoogleDriveReadOnlyInspection.toSafeJson], while probe
/// maps come exclusively from [GoogleDriveConditionalWriteProbeResult.toSafeJson].
class GoogleDriveAppDiagnosticRunner {
  GoogleDriveAppDiagnosticRunner({
    this.tokenStore = const SecureGoogleDriveRefreshTokenStore(),
    GoogleDriveDiagnosticTokenRefresher? refreshAccessToken,
    GoogleDriveDiagnosticInspector? inspectAccessToken,
    GoogleDriveDiagnosticConditionalWriteProbe? probeAccessToken,
  }) : _refreshAccessToken =
           refreshAccessToken ?? _refreshAccessTokenWithGoogle,
       _inspectAccessToken = inspectAccessToken ?? _inspectWithGoogleDrive,
       _probeAccessToken =
           probeAccessToken ?? _probeConditionalWritesWithGoogleDrive;

  final GoogleDriveRefreshTokenStore tokenStore;
  final GoogleDriveDiagnosticTokenRefresher _refreshAccessToken;
  final GoogleDriveDiagnosticInspector _inspectAccessToken;
  final GoogleDriveDiagnosticConditionalWriteProbe _probeAccessToken;

  Future<Map<String, Object?>> inspect() async {
    final accessToken = await _readAndRefreshAccessToken();
    return _inspectAccessToken(accessToken);
  }

  Future<Map<String, Object?>> conditionalWriteProbe() async {
    final accessToken = await _readAndRefreshAccessToken();
    return _probeAccessToken(accessToken);
  }

  Future<String> _readAndRefreshAccessToken() async {
    final refreshToken = await tokenStore.readRefreshToken();
    if (refreshToken == null) {
      throw const GoogleDriveAppDiagnosticException('notConnected');
    }
    return _refreshAccessToken(refreshToken);
  }

  static Future<String> _refreshAccessTokenWithGoogle(
    String refreshToken,
  ) async {
    final oauth = GoogleDriveOAuthClient();
    try {
      return (await oauth.refresh(refreshToken)).accessToken;
    } finally {
      oauth.close();
    }
  }

  static Future<Map<String, Object?>> _inspectWithGoogleDrive(
    String accessToken,
  ) async {
    final inspector = GoogleDriveReadOnlyInspector(accessToken: accessToken);
    try {
      return (await inspector.inspect()).toSafeJson();
    } finally {
      inspector.close();
    }
  }

  static Future<Map<String, Object?>> _probeConditionalWritesWithGoogleDrive(
    String accessToken,
  ) async {
    final probe = GoogleDriveConditionalWriteProbe(accessToken: accessToken);
    try {
      return (await probe.run()).toSafeJson();
    } finally {
      probe.close();
    }
  }
}

class GoogleDriveAppDiagnosticException implements Exception {
  const GoogleDriveAppDiagnosticException(this.code);

  final String code;
}

enum GoogleDriveAppDiagnosticOperation {
  inspect(
    wireName: 'inspect',
    deepLinkHost: 'chimahon-drive-diagnostic',
    callbackPathPrefix: 'chimahon-drive-diagnostic',
  ),
  conditionalWriteProbe(
    wireName: 'conditional-write-probe',
    deepLinkHost: 'chimahon-drive-conditional-write-probe',
    callbackPathPrefix: 'chimahon-drive-conditional-write-probe',
    requiresDisposableWriteOptIn: true,
  ),
  syncPreview(
    wireName: 'sync-preview',
    deepLinkHost: 'chimahon-drive-sync-preview',
    callbackPathPrefix: 'chimahon-drive-sync-preview',
    requiresReferenceTransport: true,
  );

  const GoogleDriveAppDiagnosticOperation({
    required this.wireName,
    required this.deepLinkHost,
    required this.callbackPathPrefix,
    this.requiresDisposableWriteOptIn = false,
    this.requiresReferenceTransport = false,
  });

  final String wireName;
  final String deepLinkHost;
  final String callbackPathPrefix;
  final bool requiresDisposableWriteOptIn;
  final bool requiresReferenceTransport;
}

class GoogleDriveAppDiagnosticRequest {
  const GoogleDriveAppDiagnosticRequest({
    required this.operation,
    required this.callback,
  });

  final GoogleDriveAppDiagnosticOperation operation;
  final Uri callback;
}

/// Debug-only, one-shot bridge between a local diagnostic CLI and Mangatan.
///
/// A caller first binds a random loopback port, then opens an operation-specific
/// `mangayomi` link containing that callback. Only literal IPv4 loopback
/// callbacks with a 256-bit nonce path are accepted. The conditional-write
/// operation additionally requires a distinct host and explicit opt-in query
/// value. Responses are redacted and redirects are disabled.
class GoogleDriveDebugDiagnosticHandler {
  GoogleDriveDebugDiagnosticHandler({
    GoogleDriveAppDiagnosticRunner? runner,
    this.syncPreview,
    http.Client? client,
    this.enabled = kDebugMode,
    this.referenceTransferTimeout = const Duration(seconds: 30),
    this.callbackTransferTimeout = const Duration(seconds: 10),
  }) : _runner = runner ?? GoogleDriveAppDiagnosticRunner(),
       _client = client ?? IdleTimeoutClient(http.Client()),
       _ownsClient = client == null,
       assert(referenceTransferTimeout > Duration.zero),
       assert(callbackTransferTimeout > Duration.zero);

  static const deepLinkHost = 'chimahon-drive-diagnostic';
  static const callbackPathPrefix = 'chimahon-drive-diagnostic';
  static const disposableWriteOptInParameter = 'allow-disposable-drive-writes';
  static const disposableWriteOptInValue = 'true';
  static const referenceTransportParameter = 'reference-transport';
  static const referenceTransportValue = 'loopback';
  static const referencePathSegment = 'reference';
  static const responseSchemaVersion = 1;
  static final _noncePattern = RegExp(r'^[0-9a-f]{64}$');

  final GoogleDriveAppDiagnosticRunner _runner;
  final GoogleDriveDiagnosticSyncPreview? syncPreview;
  final http.Client _client;
  final bool _ownsClient;
  final bool enabled;
  final Duration referenceTransferTimeout;
  final Duration callbackTransferTimeout;
  bool _inProgress = false;

  /// Returns whether [uri] was a valid diagnostic request handled here.
  Future<bool> handle(Uri uri) async {
    if (!enabled) return false;
    final request = validatedRequest(uri);
    if (request == null) return false;

    if (_inProgress) {
      await _postResult(
        request.callback,
        _errorResult(request.operation, 'busy'),
      );
      return true;
    }

    _inProgress = true;
    try {
      Map<String, Object?> payload;
      try {
        payload = {
          'schemaVersion': responseSchemaVersion,
          'operation': request.operation.wireName,
          'ok': true,
          _resultField(request.operation): await _run(request),
        };
      } on GoogleDriveAppDiagnosticException catch (error) {
        payload = _errorResult(request.operation, error.code);
      } on GoogleDriveConditionalWriteProbeException catch (error) {
        payload =
            request.operation ==
                GoogleDriveAppDiagnosticOperation.conditionalWriteProbe
            ? _probeFailureResult(error)
            : _errorResult(
                request.operation,
                _unexpectedFailureCode(request.operation),
              );
      } on GoogleDriveChimahonPreviewException catch (error) {
        payload = _errorResult(request.operation, error.code);
      } catch (_) {
        // Never echo an exception from credential or network code to the
        // callback. Even an unexpectedly secret-bearing error stays private.
        payload = _errorResult(
          request.operation,
          _unexpectedFailureCode(request.operation),
        );
      }
      await _postResult(request.callback, payload);
    } finally {
      _inProgress = false;
    }
    return true;
  }

  @visibleForTesting
  static GoogleDriveAppDiagnosticRequest? validatedRequest(Uri uri) {
    GoogleDriveAppDiagnosticOperation? operation;
    for (final candidate in GoogleDriveAppDiagnosticOperation.values) {
      if (uri.host.toLowerCase() == candidate.deepLinkHost) {
        operation = candidate;
        break;
      }
    }
    if (operation == null) return null;
    final expectedParameterCount =
        1 +
        (operation.requiresDisposableWriteOptIn ? 1 : 0) +
        (operation.requiresReferenceTransport ? 1 : 0);
    if (uri.scheme.toLowerCase() != 'mangayomi' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.path.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.queryParametersAll.length != expectedParameterCount) {
      return null;
    }
    if (operation.requiresDisposableWriteOptIn) {
      final optInValues = uri.queryParametersAll[disposableWriteOptInParameter];
      if (optInValues == null ||
          optInValues.length != 1 ||
          optInValues.single != disposableWriteOptInValue) {
        return null;
      }
    }
    if (operation.requiresReferenceTransport) {
      final transportValues =
          uri.queryParametersAll[referenceTransportParameter];
      if (transportValues == null ||
          transportValues.length != 1 ||
          transportValues.single != referenceTransportValue) {
        return null;
      }
    }
    final callbackValues = uri.queryParametersAll['callback'];
    if (callbackValues == null || callbackValues.length != 1) return null;
    final callback = Uri.tryParse(callbackValues.single);
    if (callback == null ||
        callback.scheme != 'http' ||
        !callback.hasAuthority ||
        callback.host != '127.0.0.1' ||
        callback.userInfo.isNotEmpty ||
        !callback.hasPort ||
        callback.port < 1024 ||
        callback.port > 65535 ||
        callback.query.isNotEmpty ||
        callback.fragment.isNotEmpty ||
        callback.pathSegments.length != 2 ||
        callback.pathSegments.first != operation.callbackPathPrefix ||
        !_noncePattern.hasMatch(callback.pathSegments.last)) {
      return null;
    }
    return GoogleDriveAppDiagnosticRequest(
      operation: operation,
      callback: callback,
    );
  }

  @visibleForTesting
  static Uri? validatedCallback(Uri uri) => validatedRequest(uri)?.callback;

  Future<Map<String, Object?>> _run(GoogleDriveAppDiagnosticRequest request) =>
      switch (request.operation) {
        GoogleDriveAppDiagnosticOperation.inspect => _runner.inspect(),
        GoogleDriveAppDiagnosticOperation.conditionalWriteProbe =>
          _runner.conditionalWriteProbe(),
        GoogleDriveAppDiagnosticOperation.syncPreview => _runSyncPreview(
          request.callback,
        ),
      };

  Future<Map<String, Object?>> _runSyncPreview(Uri callback) async {
    final preview = syncPreview;
    if (preview == null) {
      throw const GoogleDriveAppDiagnosticException('previewUnavailable');
    }
    return preview(await _fetchReferenceBackup(callback));
  }

  Future<Uint8List> _fetchReferenceBackup(Uri callback) async {
    final referenceUri = callback.replace(
      pathSegments: [...callback.pathSegments, referencePathSegment],
    );
    final deadline = _AbortableRequestDeadline(referenceTransferTimeout);
    final request =
        http.AbortableRequest(
            'GET',
            referenceUri,
            abortTrigger: deadline.abortTrigger,
          )
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers['Accept'] = 'application/octet-stream';
    try {
      final response = await deadline.wait(_client.send(request));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _cancelResponseStream(response.stream);
        throw const GoogleDriveAppDiagnosticException(
          'referenceTransferFailed',
        );
      }
      final declaredLength = response.contentLength;
      if (declaredLength != null &&
          declaredLength > ChimahonSyncCodec.defaultSizeLimit) {
        _cancelResponseStream(response.stream);
        throw const GoogleDriveAppDiagnosticException('referenceTooLarge');
      }
      final bytes = BytesBuilder(copy: false);
      await _consumeResponseStream(
        response.stream,
        deadline: deadline,
        onData: (chunk) {
          if (bytes.length + chunk.length >
              ChimahonSyncCodec.defaultSizeLimit) {
            throw const GoogleDriveAppDiagnosticException('referenceTooLarge');
          }
          bytes.add(chunk);
        },
      );
      if (bytes.isEmpty) {
        throw const GoogleDriveAppDiagnosticException('invalidReferenceBackup');
      }
      return bytes.takeBytes();
    } on GoogleDriveAppDiagnosticException {
      rethrow;
    } catch (_) {
      throw const GoogleDriveAppDiagnosticException('referenceTransferFailed');
    } finally {
      deadline.close();
    }
  }

  String _resultField(GoogleDriveAppDiagnosticOperation operation) =>
      switch (operation) {
        GoogleDriveAppDiagnosticOperation.inspect => 'report',
        GoogleDriveAppDiagnosticOperation.conditionalWriteProbe => 'probe',
        GoogleDriveAppDiagnosticOperation.syncPreview => 'preview',
      };

  String _unexpectedFailureCode(GoogleDriveAppDiagnosticOperation operation) =>
      switch (operation) {
        GoogleDriveAppDiagnosticOperation.inspect => 'inspectionFailed',
        GoogleDriveAppDiagnosticOperation.conditionalWriteProbe =>
          'conditionalWriteProbeFailed',
        GoogleDriveAppDiagnosticOperation.syncPreview => 'previewFailed',
      };

  Map<String, Object?> _errorResult(
    GoogleDriveAppDiagnosticOperation operation,
    String code,
  ) => {
    'schemaVersion': responseSchemaVersion,
    'operation': operation.wireName,
    'ok': false,
    'errorCode': code,
  };

  Map<String, Object?> _probeFailureResult(
    GoogleDriveConditionalWriteProbeException error,
  ) => {
    'schemaVersion': responseSchemaVersion,
    'operation':
        GoogleDriveAppDiagnosticOperation.conditionalWriteProbe.wireName,
    'ok': false,
    'errorCode': 'conditionalWriteProbeRejected',
    'probeFailure': {
      'statusCode': error.statusCode,
      'generatedFileName': error.generatedFileName,
      'validatorAvailability': {
        for (final entry in error.validatorAvailability.entries)
          entry.key.name: entry.value.name,
      },
      'completedPairings': [
        for (final pairing in error.completedPairings) pairing.toSafeJson(),
      ],
      'cleanup': error.cleanup.toSafeJson(),
    },
  };

  Future<void> _postResult(Uri callback, Map<String, Object?> payload) async {
    final deadline = _AbortableRequestDeadline(callbackTransferTimeout);
    try {
      final request =
          http.AbortableRequest(
              'POST',
              callback,
              abortTrigger: deadline.abortTrigger,
            )
            ..followRedirects = false
            ..maxRedirects = 0
            ..headers['Content-Type'] = 'application/json; charset=utf-8'
            ..body = jsonEncode(payload);
      final response = await deadline.wait(_client.send(request));
      await _consumeResponseStream(response.stream, deadline: deadline);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('Google Drive diagnostic callback was not accepted.');
      }
    } catch (_) {
      // The callback is a convenience channel. Keep failures fixed-text so
      // credential-bearing exception strings never reach logs.
      debugPrint('Google Drive diagnostic callback could not be delivered.');
    } finally {
      deadline.close();
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

/// One total deadline spanning request headers and the complete response body.
/// Completing [abortTrigger] lets `IOClient` close its socket immediately; the
/// explicit stream cancellation in [_consumeResponseStream] also protects
/// clients which do not implement abortable requests (notably test clients).
class _AbortableRequestDeadline {
  _AbortableRequestDeadline(Duration timeout) {
    _timer = Timer(timeout, _expire);
  }

  final Completer<void> _abort = Completer<void>();
  final Completer<void> _expired = Completer<void>();
  late final Timer _timer;

  Future<void> get abortTrigger => _abort.future;

  Future<T> wait<T>(Future<T> operation) => Future.any([
    operation,
    _expired.future.then<T>(
      (_) => throw TimeoutException('Local diagnostic transfer timed out.'),
    ),
  ]);

  void _expire() {
    if (!_abort.isCompleted) _abort.complete();
    if (!_expired.isCompleted) _expired.complete();
  }

  void close() => _timer.cancel();
}

Future<void> _consumeResponseStream(
  Stream<List<int>> stream, {
  required _AbortableRequestDeadline deadline,
  void Function(List<int> chunk)? onData,
}) async {
  final completed = Completer<void>();
  late final StreamSubscription<List<int>> subscription;
  subscription = stream.listen(
    (chunk) {
      if (completed.isCompleted) return;
      try {
        onData?.call(chunk);
      } catch (error, stackTrace) {
        completed.completeError(error, stackTrace);
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!completed.isCompleted) completed.completeError(error, stackTrace);
    },
    onDone: () {
      if (!completed.isCompleted) completed.complete();
    },
    cancelOnError: true,
  );
  try {
    await deadline.wait(completed.future);
  } finally {
    _cancelSubscription(subscription);
  }
}

void _cancelResponseStream(Stream<List<int>> stream) {
  final subscription = stream.listen(null);
  _cancelSubscription(subscription);
}

void _cancelSubscription(StreamSubscription<List<int>> subscription) {
  // Cancellation is initiated synchronously. Do not await a peer-controlled
  // `onCancel` future: doing so would let that peer defeat the total deadline.
  unawaited(subscription.cancel().catchError((_) {}));
}
