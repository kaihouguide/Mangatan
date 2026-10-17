import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const mihonBridgeRetryDelays = [
  Duration(milliseconds: 250),
  Duration(milliseconds: 750),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 8),
];

const mihonBridgeGatewayRetryDelays = [
  Duration(milliseconds: 500),
  Duration(milliseconds: 1500),
];

bool isLoopbackMihonBridge(String baseUrl) {
  final host = Uri.tryParse(normalizeMihonBridgeBaseUrl(baseUrl))?.host;
  return host == InternetAddress.loopbackIPv4.address ||
      host == InternetAddress.loopbackIPv6.address ||
      host == 'localhost';
}

String normalizeMihonBridgeBaseUrl(String value) {
  var address = value.trim();
  if (address.isEmpty) {
    throw const FormatException('Enter the address shown in APKBridge.');
  }
  if (!address.contains('://')) {
    address = 'http://$address';
  }

  final uri = Uri.tryParse(address);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    throw FormatException('Invalid APKBridge address: $value');
  }

  final usesApkBridgeDefaultPort = _isDirectMihonBridgeHost(uri.host);
  final port = uri.hasPort
      ? uri.port
      : usesApkBridgeDefaultPort
      ? 8080
      : null;

  return Uri(scheme: uri.scheme, host: uri.host, port: port).toString();
}

Uri mihonBridgeDalvikUri(String baseUrl) {
  final baseUri = Uri.parse(normalizeMihonBridgeBaseUrl(baseUrl));
  return baseUri.replace(path: '/dalvik');
}

Future<http.Response> postMihonBridge(
  http.Client client,
  Uri uri, {
  Object? body,
  Map<String, String>? headers,
  bool retryTransientFailures = false,
  List<Duration> retryDelays = mihonBridgeRetryDelays,
  List<Duration> gatewayRetryDelays = mihonBridgeGatewayRetryDelays,
  Future<void> Function(Duration) delay = Future<void>.delayed,
}) async {
  var transportRetries = 0;
  var gatewayRetries = 0;
  final preparedBody = _PreparedBridgeBody.from(uri, body);
  while (true) {
    try {
      final response = await client.post(
        uri,
        body: preparedBody.body,
        headers: _bridgeRequestHeaders(headers),
      );
      _publishExtensionToasts(response);
      _validateMihonBridgeResponse(response, uri);
      preparedBody.rememberExtensionId(response);
      return response;
    } catch (error) {
      if (error is MihonBridgeResponseException &&
          error.statusCode == 409 &&
          preparedBody.retryWithApk()) {
        continue;
      }

      Duration? retryDelay;
      if (retryTransientFailures &&
          isTransientBridgeTransportError(error) &&
          transportRetries < retryDelays.length) {
        retryDelay = retryDelays[transportRetries++];
      } else if (isTransientMihonBridgeGatewayError(error) &&
          gatewayRetries < gatewayRetryDelays.length) {
        retryDelay = gatewayRetryDelays[gatewayRetries++];
      } else {
        rethrow;
      }
      await delay(retryDelay);
    }
  }
}

const _extensionIdHeader = 'x-mangatan-extension-id';
const _extensionToastsHeader = 'x-mangatan-toasts';
final _extensionToasts = StreamController<String>.broadcast();

/// Toasts extensions showed on the bridge, such as "Login successful".
///
/// Extensions often report a result only this way, sometimes from background
/// work that finishes after the request that started it. The bridge attaches
/// queued toasts to its next response as a base64 JSON list.
Stream<String> get mihonExtensionToasts => _extensionToasts.stream;

void _publishExtensionToasts(http.Response response) {
  final encoded = response.headers[_extensionToastsHeader];
  if (encoded == null || encoded.isEmpty) return;
  try {
    final toasts = jsonDecode(utf8.decode(base64.decode(encoded)));
    if (toasts is! List) return;
    for (final toast in toasts.whereType<String>()) {
      if (toast.trim().isNotEmpty) _extensionToasts.add(toast);
    }
  } on FormatException {
    // A malformed header only loses the toasts, never the response.
  }
}

const _maximumRememberedExtensions = 128;
final _extensionIds = <String, String>{};

class _PreparedBridgeBody {
  _PreparedBridgeBody({
    required this.body,
    this.fullBody,
    this.cacheKey,
    this.usingExtensionId = false,
  });

  factory _PreparedBridgeBody.from(Uri uri, Object? originalBody) {
    final payload = _jsonObject(originalBody);
    if (payload == null) {
      return _PreparedBridgeBody(body: originalBody);
    }

    final fullBody = originalBody is String
        ? originalBody
        : jsonEncode(payload);
    final apkData = payload['data'];
    if (apkData is! String || apkData.isEmpty) {
      return _PreparedBridgeBody(body: fullBody);
    }

    final cacheKey = _extensionCacheKey(uri, apkData);
    final extensionId = _extensionIds[cacheKey];
    if (extensionId == null) {
      return _PreparedBridgeBody(
        body: fullBody,
        fullBody: fullBody,
        cacheKey: cacheKey,
      );
    }

    payload
      ..remove('data')
      ..['extensionId'] = extensionId;
    return _PreparedBridgeBody(
      body: jsonEncode(payload),
      fullBody: fullBody,
      cacheKey: cacheKey,
      usingExtensionId: true,
    );
  }

  Object? body;
  final Object? fullBody;
  final String? cacheKey;
  bool usingExtensionId;

  void rememberExtensionId(http.Response response) {
    final key = cacheKey;
    final extensionId = response.headers[_extensionIdHeader]?.trim();
    if (key == null ||
        extensionId == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(extensionId)) {
      return;
    }
    _extensionIds.remove(key);
    _extensionIds[key] = extensionId;
    while (_extensionIds.length > _maximumRememberedExtensions) {
      _extensionIds.remove(_extensionIds.keys.first);
    }
  }

  bool retryWithApk() {
    if (!usingExtensionId || fullBody == null || cacheKey == null) {
      return false;
    }
    _extensionIds.remove(cacheKey);
    body = fullBody;
    usingExtensionId = false;
    return true;
  }
}

Map<String, dynamic>? _jsonObject(Object? body) {
  if (body is Map) {
    return body.map((key, value) => MapEntry(key.toString(), value));
  }
  if (body is! String) return null;
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
  } on FormatException {
    return null;
  }
  return null;
}

String _extensionCacheKey(Uri uri, String apkData) {
  final prefixLength = apkData.length < 32 ? apkData.length : 32;
  final suffixStart = apkData.length < 32 ? 0 : apkData.length - 32;
  return '$uri|${apkData.length}|${apkData.hashCode}|'
      '${apkData.substring(0, prefixLength)}|${apkData.substring(suffixStart)}';
}

bool isTransientBridgeTransportError(Object error) {
  return error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException;
}

bool isTransientMihonBridgeGatewayError(Object error) {
  return error is MihonBridgeResponseException &&
      const {502, 503, 504}.contains(error.statusCode);
}

void _validateMihonBridgeResponse(http.Response response, Uri uri) {
  final contentType = response.headers['content-type']?.toLowerCase() ?? '';
  final bodyStart = response.body.trimLeft().toLowerCase();
  final returnedHtml =
      contentType.contains('text/html') ||
      bodyStart.startsWith('<html') ||
      bodyStart.startsWith('<!doctype html');

  if (const {502, 503, 504}.contains(response.statusCode)) {
    final hosted = !_isDirectMihonBridgeHost(uri.host);
    throw MihonBridgeResponseException(
      hosted
          ? 'The hosted APKBridge gateway is unavailable (HTTP '
                '${response.statusCode} at $uri). The URL is valid, but its '
                'backend could not run the extension. Try again later, choose '
                'another hosted bridge, or use APKBridge on an Android device.'
          : 'APKBridge is temporarily unavailable (HTTP '
                '${response.statusCode} at $uri). Check the Android device and '
                'try again.',
      statusCode: response.statusCode,
    );
  }

  if (returnedHtml) {
    final reason = response.statusCode >= 500
        ? 'APKBridge failed while running the Mihon extension'
        : 'the configured server is not APKBridge';
    throw MihonBridgeResponseException(
      '$reason (HTTP ${response.statusCode} at $uri). Use the complete bridge '
      'URL. Direct Android-device addresses normally use port 8080, for '
      'example http://192.168.1.20:8080; hosted HTTPS bridges normally do not '
      'need an explicit port.',
      statusCode: response.statusCode,
    );
  }

  if (response.statusCode < 200 || response.statusCode >= 300) {
    final serverError = _bridgeServerError(response.body);
    throw MihonBridgeResponseException(
      'APKBridge rejected the extension request (HTTP '
      '${response.statusCode} at $uri).${serverError == null ? ' Check the '
                'APKBridge log and update both APKBridge and the Mihon extension.' : ' $serverError'}',
      statusCode: response.statusCode,
    );
  }
}

String? _bridgeServerError(String responseBody) {
  try {
    final decoded = jsonDecode(responseBody);
    if (decoded is! Map || decoded['error'] is! String) return null;
    final normalized = (decoded['error'] as String)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.isEmpty) return null;
    return normalized.length <= 300
        ? normalized
        : '${normalized.substring(0, 297)}...';
  } on FormatException {
    return null;
  }
}

bool _isDirectMihonBridgeHost(String host) {
  return host == 'localhost' ||
      host.endsWith('.local') ||
      host.endsWith('.lan') ||
      !host.contains('.') ||
      InternetAddress.tryParse(host) != null;
}

Map<String, String> _bridgeRequestHeaders(Map<String, String>? headers) {
  final result = <String, String>{...?headers};
  final normalizedNames = result.keys.map((key) => key.toLowerCase()).toSet();
  if (!normalizedNames.contains('content-type')) {
    result['content-type'] = 'application/json; charset=utf-8';
  }
  if (!normalizedNames.contains('accept')) {
    result['accept'] = 'application/json';
  }
  return result;
}

class MihonBridgeResponseException implements Exception {
  const MihonBridgeResponseException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
