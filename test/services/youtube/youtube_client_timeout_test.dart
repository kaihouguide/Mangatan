import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mangayomi/services/youtube/youtube_service.dart';

class _HangingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

void main() {
  test('a stalled YouTube request times out instead of hanging', () async {
    final client = newYouTubeClient(
      inner: _HangingClient(),
      responseTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(client.close);

    await expectLater(
      client.videos.get('dQw4w9WgXcQ'),
      throwsA(isA<TimeoutException>()),
    );
  });
}
