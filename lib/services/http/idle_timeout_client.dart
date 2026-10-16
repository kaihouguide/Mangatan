import 'dart:async';

import 'package:http/http.dart' as http;

/// Aborts a request once it has made no progress for [idleTimeout].
///
/// Sync transfers can be large EPUB or backup files on a slow connection, so a
/// fixed total timeout would fail a transfer that is still moving. Instead the
/// deadline restarts every time a request-body chunk is sent or a response
/// chunk arrives. A connection that stalls, whether while uploading, while the
/// server prepares its response, or mid-download, ends with a
/// [TimeoutException] instead of holding the sync lock forever.
class IdleTimeoutClient extends http.BaseClient {
  IdleTimeoutClient(
    this._inner, {
    this.idleTimeout = const Duration(minutes: 2),
  });

  final http.Client _inner;
  final Duration idleTimeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final abort = Completer<void>();
    var timedOut = false;
    Timer? timer;
    void stop() => timer?.cancel();
    void touch() {
      timer?.cancel();
      timer = Timer(idleTimeout, () {
        timedOut = true;
        if (!abort.isCompleted) abort.complete();
      });
    }

    // Keep a caller's own abort working through the copied request.
    if (request case http.Abortable(:final abortTrigger?)) {
      void abortCopy([Object? _]) {
        if (!abort.isCompleted) abort.complete();
      }

      abortTrigger.then(abortCopy, onError: abortCopy);
    }

    final copy =
        http.AbortableStreamedRequest(
            request.method,
            request.url,
            abortTrigger: abort.future,
          )
          ..headers.addAll(request.headers)
          ..contentLength = request.contentLength
          ..followRedirects = request.followRedirects
          ..maxRedirects = request.maxRedirects
          ..persistentConnection = request.persistentConnection;

    touch();
    request.finalize().listen(
      (chunk) {
        touch();
        copy.sink.add(chunk);
      },
      onError: copy.sink.addError,
      onDone: copy.sink.close,
      cancelOnError: true,
    );

    final http.StreamedResponse response;
    try {
      response = await _inner.send(copy);
    } catch (error) {
      stop();
      if (timedOut) throw _timeout(request);
      rethrow;
    }

    touch();
    final body = response.stream.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          touch();
          sink.add(chunk);
        },
        handleError: (error, stackTrace, sink) {
          stop();
          sink.addError(timedOut ? _timeout(request) : error, stackTrace);
        },
        handleDone: (sink) {
          stop();
          sink.close();
        },
      ),
    );
    return http.StreamedResponse(
      body,
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  TimeoutException _timeout(http.BaseRequest request) => TimeoutException(
    '${request.method} ${request.url.host} made no progress for '
    '${idleTimeout.inSeconds} seconds',
    idleTimeout,
  );

  @override
  void close() => _inner.close();
}
