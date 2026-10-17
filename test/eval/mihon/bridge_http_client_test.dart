import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangayomi/eval/mihon/bridge_http_client.dart';

void main() {
  group('Mihon bridge HTTP client', () {
    test('normalizes APKBridge base URLs', () {
      expect(
        normalizeMihonBridgeBaseUrl('192.168.1.20'),
        'http://192.168.1.20:8080',
      );
      expect(
        normalizeMihonBridgeBaseUrl('http://192.168.1.20:3710/dalvik/'),
        'http://192.168.1.20:3710',
      );
      expect(
        mihonBridgeDalvikUri('http://192.168.1.20/').toString(),
        'http://192.168.1.20:8080/dalvik',
      );
      expect(
        mihonBridgeDalvikUri('https://bridge.example/base///').toString(),
        'https://bridge.example/dalvik',
      );
      expect(
        normalizeMihonBridgeBaseUrl('https://bridge.mangayomi.30062022.xyz/'),
        'https://bridge.mangayomi.30062022.xyz',
      );
      expect(
        mihonBridgeDalvikUri('https://bridge.mangayomi.30062022.xyz/')
            .toString(),
        'https://bridge.mangayomi.30062022.xyz/dalvik',
      );
      expect(
        () => mihonBridgeDalvikUri('ftp://192.168.1.20'),
        throwsFormatException,
      );
    });

    test('publishes extension toasts from any bridge response', () async {
      final toasts = <String>[];
      final subscription = mihonExtensionToasts.listen(toasts.add);
      addTearDown(subscription.cancel);
      String encode(Object value) =>
          base64.encode(utf8.encode(jsonEncode(value)));
      final responses = [
        http.Response(
          '[]',
          200,
          headers: {
            'x-mangatan-toasts': encode(['Login successful', 'ログイン成功']),
          },
        ),
        // Failures still deliver toasts, and bad headers are ignored.
        http.Response(
          '{"error":"Failed to login"}',
          500,
          headers: {
            'x-mangatan-toasts': encode(['Login failed']),
          },
        ),
        http.Response('[]', 200, headers: {'x-mangatan-toasts': '%%%'}),
      ];
      final client = MockClient((_) async => responses.removeAt(0));
      final uri = Uri.parse('http://127.0.0.1:3710/dalvik');

      await postMihonBridge(client, uri, body: {'method': 'a'});
      await expectLater(
        postMihonBridge(client, uri, body: {'method': 'b'}),
        throwsA(anything),
      );
      await postMihonBridge(client, uri, body: {'method': 'c'});
      await Future<void>.delayed(Duration.zero);

      expect(toasts, ['Login successful', 'ログイン成功', 'Login failed']);
    });

    test('recognizes only local bridge endpoints as loopback', () {
      expect(isLoopbackMihonBridge('http://127.0.0.1:3710'), isTrue);
      expect(isLoopbackMihonBridge('http://localhost:3710'), isTrue);
      expect(isLoopbackMihonBridge('http://[::1]:3710'), isTrue);
      expect(isLoopbackMihonBridge('http://192.168.1.20:3710'), isFalse);
    });

    test(
      'retries transient local transport failures with bounded delays',
      () async {
        var requests = 0;
        final delays = <Duration>[];
        final client = MockClient((request) async {
          requests++;
          if (requests <= mihonBridgeRetryDelays.length) {
            throw http.ClientException('connection refused', request.url);
          }
          return http.Response('ok', 200);
        });

        final response = await postMihonBridge(
          client,
          Uri.parse('http://127.0.0.1:3710/dalvik'),
          retryTransientFailures: true,
          delay: (duration) async => delays.add(duration),
        );

        expect(response.body, 'ok');
        expect(requests, mihonBridgeRetryDelays.length + 1);
        expect(delays, mihonBridgeRetryDelays);
      },
    );

    test('sends JSON headers and retries transient hosted gateways', () async {
      var requests = 0;
      final delays = <Duration>[];
      final client = MockClient((request) async {
        requests++;
        expect(request.headers['content-type'], contains('application/json'));
        expect(request.headers['accept'], 'application/json');
        if (requests < 3) {
          return http.Response(
            '<html>gateway unavailable</html>',
            requests == 1 ? 502 : 503,
            headers: const {'content-type': 'text/html'},
          );
        }
        return http.Response('ok', 200);
      });

      final response = await postMihonBridge(
        client,
        Uri.parse('https://bridge.example/dalvik'),
        body: '{}',
        delay: (duration) async => delays.add(duration),
      );

      expect(response.body, 'ok');
      expect(requests, 3);
      expect(delays, mihonBridgeGatewayRetryDelays);
    });

    test('does not retry a remote bridge or application error', () async {
      var remoteRequests = 0;
      final remoteClient = MockClient((request) async {
        remoteRequests++;
        throw http.ClientException('connection refused', request.url);
      });

      await expectLater(
        postMihonBridge(
          remoteClient,
          Uri.parse('http://192.168.1.20:3710/dalvik'),
        ),
        throwsA(isA<http.ClientException>()),
      );
      expect(remoteRequests, 1);

      var applicationRequests = 0;
      final applicationClient = MockClient((request) async {
        applicationRequests++;
        throw const FormatException('invalid response');
      });
      await expectLater(
        postMihonBridge(
          applicationClient,
          Uri.parse('http://127.0.0.1:3710/dalvik'),
          retryTransientFailures: true,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(applicationRequests, 1);
    });

    test('turns an HTML response into an actionable bridge error', () async {
      final client = MockClient(
        (request) async => http.Response(
          '<html>not APKBridge</html>',
          200,
          headers: const {'content-type': 'text/html'},
        ),
      );

      await expectLater(
        postMihonBridge(client, Uri.parse('http://192.168.1.20:8080/dalvik')),
        throwsA(
          isA<MihonBridgeResponseException>()
              .having(
                (error) => error.message,
                'message',
                contains('not APKBridge'),
              )
              .having(
                (error) => error.message,
                'message',
                contains('port 8080'),
              )
              .having(
                (error) => error.message,
                'message',
                contains('hosted HTTPS bridges'),
              ),
        ),
      );
    });

    test('explains a persistent hosted gateway failure', () async {
      final client = MockClient(
        (request) async => http.Response(
          '<html>bad gateway</html>',
          502,
          headers: const {'content-type': 'text/html'},
        ),
      );

      await expectLater(
        postMihonBridge(
          client,
          Uri.parse('https://bridge.example/dalvik'),
          gatewayRetryDelays: const [],
        ),
        throwsA(
          isA<MihonBridgeResponseException>()
              .having((error) => error.statusCode, 'status', 502)
              .having(
                (error) => error.message,
                'message',
                contains('URL is valid'),
              )
              .having(
                (error) => error.message,
                'message',
                contains('another hosted bridge'),
              ),
        ),
      );
    });

    test(
      'reuses the server-issued extension handle after the first APK upload',
      () async {
        const extensionId =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        final uri = Uri.parse('https://handle-cache.example/dalvik');
        final payloads = <Map<String, dynamic>>[];
        final client = MockClient((request) async {
          payloads.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
            '{}',
            200,
            headers: const {'x-mangatan-extension-id': extensionId},
          );
        });
        final body = {'method': 'getPopularAnime', 'data': 'base64-apk-data'};

        await postMihonBridge(client, uri, body: body);
        await postMihonBridge(client, uri, body: body);

        expect(payloads.first['data'], 'base64-apk-data');
        expect(payloads.first, isNot(contains('extensionId')));
        expect(payloads.last, isNot(contains('data')));
        expect(payloads.last['extensionId'], extensionId);
      },
    );

    test('resends the APK when a cached extension handle expired', () async {
      const firstId =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      const secondId =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      final uri = Uri.parse('https://stale-handle.example/dalvik');
      final payloads = <Map<String, dynamic>>[];
      final client = MockClient((request) async {
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        payloads.add(payload);
        if (payloads.length == 1) {
          return http.Response(
            '{}',
            200,
            headers: const {'x-mangatan-extension-id': firstId},
          );
        }
        if (payloads.length == 2) {
          return http.Response(
            '{"error":"extension expired","code":409}',
            409,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response(
          '{}',
          200,
          headers: const {'x-mangatan-extension-id': secondId},
        );
      });
      final body = {'method': 'getPopularAnime', 'data': 'another-apk'};

      await postMihonBridge(client, uri, body: body);
      await postMihonBridge(client, uri, body: body);

      expect(payloads, hasLength(3));
      expect(payloads[1]['extensionId'], firstId);
      expect(payloads[1], isNot(contains('data')));
      expect(payloads[2]['data'], 'another-apk');
      expect(payloads[2], isNot(contains('extensionId')));
    });

    test(
      'includes the bridge JSON error in rejected-request messages',
      () async {
        final client = MockClient(
          (request) async => http.Response(
            '{"error":"SAnime.background_url is missing","code":500}',
            500,
            headers: const {'content-type': 'application/json'},
          ),
        );

        await expectLater(
          postMihonBridge(client, Uri.parse('http://192.168.1.20:8080/dalvik')),
          throwsA(
            isA<MihonBridgeResponseException>().having(
              (error) => error.message,
              'message',
              contains('SAnime.background_url is missing'),
            ),
          ),
        );
      },
    );
  });
}
