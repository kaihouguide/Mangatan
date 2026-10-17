import 'dart:convert';

import 'package:mangayomi/services/sync/google_drive_refresh_token_store.dart';

class WebDavCredentials {
  const WebDavCredentials({required this.username, required this.password});

  factory WebDavCredentials.fromJson(Map<String, Object?> json) =>
      WebDavCredentials(
        username: json['username']?.toString() ?? '',
        password: json['password']?.toString() ?? '',
      );

  final String username;
  final String password;

  Map<String, Object?> toJson() => {'username': username, 'password': password};

  bool get isUsable => username.trim().isNotEmpty && password.isNotEmpty;
}

abstract interface class WebDavCredentialStore {
  Future<WebDavCredentials?> readCredentials();

  Future<void> writeCredentials(WebDavCredentials credentials);

  Future<void> clearCredentials();
}

class SecureWebDavCredentialStore implements WebDavCredentialStore {
  const SecureWebDavCredentialStore({
    this.backend = const FlutterSecureValueStoreBackend(),
    this.storageKey = defaultStorageKey,
  });

  static const defaultStorageKey = 'Mangatan WebDAV sync';

  final SecureValueStoreBackend backend;
  final String storageKey;

  @override
  Future<WebDavCredentials?> readCredentials() async {
    final raw = await backend.read(key: storageKey);
    if (raw == null || raw.trim().isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // Unreadable stored credentials mean signing in again, as for any
      // other unusable value.
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    final credentials = WebDavCredentials.fromJson(decoded);
    return credentials.isUsable ? credentials : null;
  }

  @override
  Future<void> writeCredentials(WebDavCredentials credentials) async {
    if (!credentials.isUsable) {
      throw ArgumentError.value(
        credentials.username,
        'credentials',
        'WebDAV username and password must not be blank',
      );
    }
    await backend.write(
      key: storageKey,
      value: jsonEncode(credentials.toJson()),
    );
  }

  @override
  Future<void> clearCredentials() => backend.delete(key: storageKey);
}
