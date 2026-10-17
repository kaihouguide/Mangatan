import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:mangayomi/services/http/idle_timeout_client.dart';
import 'package:mangayomi/utils/url_protocol/api.dart';
import 'package:url_launcher/url_launcher.dart';

/// OAuth identity used by Chimahon v2.2.0 for its private Drive app-data
/// space. The values can be replaced at build time if the Chimahon project
/// owner provides a platform-appropriate client in the same Google project.
class ChimahonGoogleOAuthConfig {
  const ChimahonGoogleOAuthConfig({
    required this.clientId,
    required this.redirectUri,
  });

  static const current = ChimahonGoogleOAuthConfig(
    clientId: String.fromEnvironment(
      'CHIMAHON_GOOGLE_CLIENT_ID',
      defaultValue:
          '207565405172-osbisi7elvjcg00ive35ml2q4cqandbb.apps.googleusercontent.com',
    ),
    redirectUri: String.fromEnvironment(
      'CHIMAHON_GOOGLE_REDIRECT_URI',
      defaultValue: 'app.chimahon.google.oauth:/oauth2redirect',
    ),
  );

  static const authorizationEndpoint =
      'https://accounts.google.com/o/oauth2/auth';
  static const tokenEndpoint = 'https://oauth2.googleapis.com/token';
  static const driveFileScope = 'https://www.googleapis.com/auth/drive.file';
  static const driveAppDataScope =
      'https://www.googleapis.com/auth/drive.appdata';

  final String clientId;
  final String redirectUri;

  Uri get parsedRedirectUri => Uri.parse(redirectUri);

  String get callbackUrlScheme {
    final redirect = parsedRedirectUri;
    if (redirect.scheme == 'http' || redirect.scheme == 'https') {
      return redirect.hasPort
          ? '${redirect.scheme}://${redirect.host}:${redirect.port}'
          : '${redirect.scheme}://${redirect.host}';
    }
    return redirect.scheme;
  }
}

class GoogleDriveOAuthTokens {
  const GoogleDriveOAuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.grantedScopes,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final Set<String> grantedScopes;
}

class GoogleDriveOAuthException implements Exception {
  const GoogleDriveOAuthException(this.message, {this.code});

  final String message;
  final String? code;

  bool get requiresReauthentication => code == 'invalid_grant';

  @override
  String toString() => message;
}

typedef GoogleOAuthBrowser =
    Future<String> Function(Uri authorizationUri, String callbackUrlScheme);

typedef GoogleOAuthProtocolRegistrar = void Function(String scheme);
typedef GoogleOAuthProtocolUnregistrar = void Function(String scheme);
typedef GoogleOAuthLinkStream = Stream<Uri> Function();
typedef GoogleOAuthExternalLauncher = Future<bool> Function(Uri uri);

/// Collects a custom-protocol OAuth callback on desktop platforms.
///
/// The app-links listener is installed before the authorization page is opened,
/// so even an immediate redirect cannot be missed. OAuth state validation stays
/// in [GoogleDriveOAuthClient], after this class has filtered unrelated links.
class DesktopGoogleOAuthBrowser {
  DesktopGoogleOAuthBrowser({
    required this.expectedRedirectUri,
    GoogleOAuthProtocolRegistrar? registerProtocol,
    GoogleOAuthProtocolUnregistrar? unregisterProtocol,
    GoogleOAuthLinkStream? linkStream,
    GoogleOAuthExternalLauncher? launchExternal,
    this.callbackTimeout = const Duration(minutes: 10),
  }) : _registerProtocol = registerProtocol ?? registerProtocolHandler,
       _unregisterProtocol = unregisterProtocol ?? unregisterProtocolHandler,
       _linkStream = linkStream ?? (() => AppLinks().uriLinkStream),
       _launchExternal = launchExternal ?? _launchInExternalBrowser;

  final Uri expectedRedirectUri;
  final Duration callbackTimeout;
  final GoogleOAuthProtocolRegistrar _registerProtocol;
  final GoogleOAuthProtocolUnregistrar _unregisterProtocol;
  final GoogleOAuthLinkStream _linkStream;
  final GoogleOAuthExternalLauncher _launchExternal;

  Future<String> authenticate(Uri authorizationUri) async {
    final callback = Completer<Uri>();
    final expectedState = authorizationUri.queryParameters['state'];
    var protocolRegistered = false;
    final subscription = _linkStream().listen(
      (uri) {
        final stateMatches =
            expectedState == null ||
            uri.queryParameters['state'] == expectedState;
        if (!callback.isCompleted &&
            stateMatches &&
            _matchesExpectedRedirect(uri)) {
          callback.complete(uri);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!callback.isCompleted) {
          callback.completeError(error, stackTrace);
        }
      },
    );

    try {
      _registerProtocol(expectedRedirectUri.scheme);
      protocolRegistered = true;
      if (!await _launchExternal(authorizationUri)) {
        throw const GoogleDriveOAuthException(
          'Could not open the Google sign-in page',
          code: 'browser_launch_failed',
        );
      }

      try {
        return (await callback.future.timeout(callbackTimeout)).toString();
      } on TimeoutException {
        throw const GoogleDriveOAuthException(
          'Google sign-in timed out before the app received its callback',
          code: 'callback_timeout',
        );
      }
    } finally {
      try {
        await subscription.cancel();
      } finally {
        if (protocolRegistered) {
          try {
            _unregisterProtocol(expectedRedirectUri.scheme);
          } catch (_) {
            // Platform registrations carry Mangatan's narrow ownership marker,
            // so a later attempt can safely reclaim or reuse them. Cleanup
            // must not discard an authorization callback (or mask the original
            // browser failure) merely because the OS could not release the
            // per-user registration at this moment.
          }
        }
      }
    }
  }

  bool _matchesExpectedRedirect(Uri uri) =>
      _matchesRedirectAddress(uri, expectedRedirectUri);

  static Future<bool> _launchInExternalBrowser(Uri uri) {
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

/// Browser-based OAuth for Chimahon's Google Drive app-data identity.
///
/// Chimahon's published Android client only permits its custom redirect URI.
/// macOS captures it with ASWebAuthenticationSession. Windows and Linux share
/// the registered-protocol and app-links callback flow above; only their
/// per-user protocol registration adapters differ.
class GoogleDriveOAuthClient {
  GoogleDriveOAuthClient({
    this.config = ChimahonGoogleOAuthConfig.current,
    http.Client? client,
    GoogleOAuthBrowser? browser,
    DateTime Function()? clock,
  }) : _client = client ?? IdleTimeoutClient(http.Client()),
       _ownsClient = client == null,
       _browser = browser ?? _defaultBrowser(config),
       _clock = clock ?? DateTime.now;

  final ChimahonGoogleOAuthConfig config;
  final http.Client _client;
  final bool _ownsClient;
  final GoogleOAuthBrowser _browser;
  final DateTime Function() _clock;

  Future<GoogleDriveOAuthTokens> signIn() async {
    final state = _randomUrlSafeValue();
    final verifier = _randomUrlSafeValue(byteCount: 48);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final authorizationUri =
        Uri.parse(ChimahonGoogleOAuthConfig.authorizationEndpoint).replace(
          queryParameters: {
            'client_id': config.clientId,
            'redirect_uri': config.redirectUri,
            'response_type': 'code',
            'scope': [
              ChimahonGoogleOAuthConfig.driveFileScope,
              ChimahonGoogleOAuthConfig.driveAppDataScope,
            ].join(' '),
            'access_type': 'offline',
            'prompt': 'consent',
            'state': state,
            'code_challenge': challenge,
            'code_challenge_method': 'S256',
          },
        );

    final callback = _parseBrowserCallback(
      await _browser(authorizationUri, config.callbackUrlScheme),
    );
    if (!_matchesConfiguredRedirect(callback)) {
      throw const GoogleDriveOAuthException(
        'Google sign-in returned to an unexpected callback address',
        code: 'invalid_callback',
      );
    }
    if (callback.queryParameters['state'] != state) {
      throw const GoogleDriveOAuthException(
        'Google sign-in returned an invalid state value',
        code: 'invalid_state',
      );
    }
    final error = callback.queryParameters['error'];
    if (error != null) {
      throw GoogleDriveOAuthException(
        callback.queryParameters['error_description'] ?? error,
        code: error,
      );
    }
    final code = callback.queryParameters['code'];
    if (code == null || code.isEmpty) {
      throw const GoogleDriveOAuthException(
        'Google sign-in did not return an authorization code',
      );
    }

    return _requestTokens({
      'client_id': config.clientId,
      'code': code,
      'code_verifier': verifier,
      'grant_type': 'authorization_code',
      'redirect_uri': config.redirectUri,
    }, requireAppDataScope: true);
  }

  Future<GoogleDriveOAuthTokens> refresh(String refreshToken) {
    if (refreshToken.trim().isEmpty) {
      throw const GoogleDriveOAuthException('Google Drive is not connected');
    }
    return _requestTokens(
      {
        'client_id': config.clientId,
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      },
      fallbackRefreshToken: refreshToken,
      requireAppDataScope: true,
    );
  }

  Future<GoogleDriveOAuthTokens> _requestTokens(
    Map<String, String> body, {
    String? fallbackRefreshToken,
    bool requireAppDataScope = false,
  }) async {
    final response = await _client.post(
      Uri.parse(ChimahonGoogleOAuthConfig.tokenEndpoint),
      headers: const {'Accept': 'application/json'},
      body: body,
    );
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      // The status-specific error below is more useful than a JSON exception.
    }
    final values = decoded is Map<String, dynamic>
        ? decoded
        : const <String, dynamic>{};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final description = values['error_description'] ?? values['error'];
      throw GoogleDriveOAuthException(
        description is String && description.isNotEmpty
            ? description
            : 'Google token request failed (HTTP ${response.statusCode})',
        code: values['error']?.toString(),
      );
    }

    final accessToken = values['access_token'];
    final refreshToken = values['refresh_token'] ?? fallbackRefreshToken;
    if (accessToken is! String || accessToken.isEmpty) {
      throw const GoogleDriveOAuthException(
        'Google token response did not include an access token',
      );
    }
    if (refreshToken is! String || refreshToken.isEmpty) {
      throw const GoogleDriveOAuthException(
        'Google did not return a refresh token; disconnect and try again',
      );
    }
    final expiresIn = switch (values['expires_in']) {
      int value => value,
      String value => int.tryParse(value) ?? 3600,
      _ => 3600,
    };
    final returnedScope = values['scope'];
    final grantedScopes = returnedScope is String
        ? returnedScope
              .split(RegExp(r'\s+'))
              .where((scope) => scope.isNotEmpty)
              .toSet()
        // OAuth permits omitting `scope` when it is identical to the request.
        // A partial grant must include it, and the read-only Drive probe made
        // before token persistence is the final permission check.
        : requireAppDataScope
        ? {
            ChimahonGoogleOAuthConfig.driveFileScope,
            ChimahonGoogleOAuthConfig.driveAppDataScope,
          }
        : <String>{};
    if (requireAppDataScope &&
        !grantedScopes.contains(ChimahonGoogleOAuthConfig.driveAppDataScope)) {
      throw const GoogleDriveOAuthException(
        'Google Drive app-data permission was not granted',
        code: 'insufficient_scope',
      );
    }
    return GoogleDriveOAuthTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: _clock().add(Duration(seconds: expiresIn)),
      grantedScopes: grantedScopes,
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  bool _matchesConfiguredRedirect(Uri callback) {
    return _matchesRedirectAddress(callback, config.parsedRedirectUri);
  }

  Uri _parseBrowserCallback(String value) {
    final callback = Uri.parse(value);
    final expected = config.parsedRedirectUri;
    if (callback.hasScheme ||
        (expected.scheme != 'http' && expected.scheme != 'https')) {
      return callback;
    }

    // The desktop loopback implementation reports HttpRequest.requestedUri,
    // which is a path/query reference rather than an absolute URL. Resolve it
    // against the configured redirect before applying the same exact redirect
    // and OAuth-state checks used for custom-protocol callbacks.
    return expected.resolveUri(callback);
  }

  static GoogleOAuthBrowser _defaultBrowser(ChimahonGoogleOAuthConfig config) {
    return (authorizationUri, callbackUrlScheme) {
      final redirect = config.parsedRedirectUri;
      if ((Platform.isWindows || Platform.isLinux) &&
          redirect.scheme != 'http' &&
          redirect.scheme != 'https') {
        return DesktopGoogleOAuthBrowser(
          expectedRedirectUri: redirect,
        ).authenticate(authorizationUri);
      }
      return _authenticateInBrowser(authorizationUri, callbackUrlScheme);
    };
  }

  static Future<String> _authenticateInBrowser(
    Uri authorizationUri,
    String callbackUrlScheme,
  ) {
    return FlutterWebAuth2.authenticate(
      url: authorizationUri.toString(),
      callbackUrlScheme: callbackUrlScheme,
    );
  }

  String _randomUrlSafeValue({int byteCount = 32}) {
    final random = Random.secure();
    final bytes = List<int>.generate(byteCount, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

bool _matchesRedirectAddress(Uri callback, Uri expected) {
  return callback.scheme.toLowerCase() == expected.scheme.toLowerCase() &&
      callback.hasAuthority == expected.hasAuthority &&
      callback.userInfo == expected.userInfo &&
      callback.host.toLowerCase() == expected.host.toLowerCase() &&
      callback.hasPort == expected.hasPort &&
      (!expected.hasPort || callback.port == expected.port) &&
      callback.path == expected.path;
}
