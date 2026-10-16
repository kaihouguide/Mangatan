import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mangayomi/services/http/idle_timeout_client.dart';

void main() {
  late HttpServer server;
  late Uri baseUri;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUri = Uri.parse('http://127.0.0.1:${server.port}');
  });

  tearDown(() => server.close(force: true));

  test('times out a server that never responds', () async {
    server.listen((_) {});
    final client = IdleTimeoutClient(
      http.Client(),
      idleTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(client.close);

    await expectLater(
      client.get(baseUri.resolve('/stalled')),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('times out a response body that stops arriving', () async {
    final raw = await _rawServer((socket) async {
      socket.add('HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n'.codeUnits);
      socket.add(List.filled(10, 1));
      await socket.flush();
    });
    final client = IdleTimeoutClient(
      http.Client(),
      idleTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(client.close);

    await expectLater(client.get(raw), throwsA(isA<TimeoutException>()));
  });

  test('lets a slow transfer finish while it keeps making progress', () async {
    // dart:io's HttpServer buffers small chunks until the response closes,
    // so a raw socket is used to space the bytes out for real.
    final raw = await _rawServer((socket) async {
      socket.add('HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\n'.codeUnits);
      await socket.flush();
      for (var chunk = 0; chunk < 6; chunk++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        socket.add([chunk]);
        await socket.flush();
      }
      await socket.close();
    });
    final client = IdleTimeoutClient(
      http.Client(),
      idleTimeout: const Duration(milliseconds: 300),
    );
    addTearDown(client.close);

    final response = await client.get(raw);
    expect(response.statusCode, 200);
    expect(response.bodyBytes, [0, 1, 2, 3, 4, 5]);
  });

  test('forwards the request body and headers', () async {
    server.listen((request) async {
      final body = await request.fold<List<int>>(
        [],
        (bytes, chunk) => bytes..addAll(chunk),
      );
      request.response
        ..headers.set('x-echo', request.headers.value('x-test') ?? '')
        ..add(body);
      await request.response.close();
    });
    final client = IdleTimeoutClient(http.Client());
    addTearDown(client.close);

    final response = await client.put(
      baseUri.resolve('/echo'),
      headers: {'x-test': 'value'},
      body: 'payload',
    );
    expect(response.body, 'payload');
    expect(response.headers['x-echo'], 'value');
  });
}

/// Serves each connection with [respond] after reading its request head.
Future<Uri> _rawServer(Future<void> Function(Socket socket) respond) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  final sockets = <Socket>[];
  addTearDown(() {
    for (final socket in sockets) {
      socket.destroy();
    }
  });
  server.listen((socket) {
    sockets.add(socket);
    var responded = false;
    socket.listen((_) {
      if (responded) return;
      responded = true;
      unawaited(respond(socket));
    }, onError: (_) {});
  });
  return Uri.parse('http://127.0.0.1:${server.port}/');
}
