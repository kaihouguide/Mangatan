import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/utils/url_protocol/protocol.dart';
import 'package:mangayomi/utils/url_protocol/windows_protocol.dart';

void main() {
  test('Windows protocol command quotes an executable path with spaces', () {
    final command = WindowsProtocolHandler.buildCommand(
      r'C:\Program Files\Mangatan\Mangatan.exe',
      const ['%s'],
    );

    expect(command, r'"C:\Program Files\Mangatan\Mangatan.exe" "%1"');
  });

  test('Windows command quoting handles flags and trailing backslashes', () {
    final command = WindowsProtocolHandler.buildCommand(
      r'C:\Program Files\Mangatan\Mangatan.exe',
      const ['--oauth-callback=%s', 'C:\\OAuth Data\\'],
    );

    expect(
      command,
      r'"C:\Program Files\Mangatan\Mangatan.exe" '
      r'"--oauth-callback=%1" "C:\OAuth Data\\"',
    );
  });

  test('Windows command quoting preserves Unicode paths', () {
    final command = WindowsProtocolHandler.buildCommand(
      r'C:\Users\ユーザー\読書アプリ\mangayomi.exe',
      const ['%s'],
    );

    expect(command, r'"C:\Users\ユーザー\読書アプリ\mangayomi.exe" "%1"');
  });

  test(
    'callback placeholder expansion does not mutate the executable path',
    () {
      final command = WindowsProtocolHandler.buildCommand(
        r'C:\Portable %s\mangayomi.exe',
        const ['%s'],
      );

      expect(command, r'"C:\Portable %s\mangayomi.exe" "%1"');
    },
  );

  test('recognizes only narrow legacy Mangatan protocol ownership', () {
    bool isOwned({
      String scheme = 'mangayomi',
      String? description = 'URL:Mangayomi',
      String? urlProtocol = '',
      String? command = r'"C:\Old Mangatan\mangayomi.exe" "%1"',
    }) => WindowsProtocolHandler.isLegacyMangatanRegistration(
      scheme: scheme,
      description: description,
      urlProtocol: urlProtocol,
      command: command,
    );

    expect(isOwned(), isTrue);
    expect(isOwned(command: r'C:\Old Mangatan\mangayomi.exe "%1"'), isTrue);
    expect(isOwned(scheme: 'app.chimahon.google.oauth'), isFalse);
    expect(isOwned(description: 'URL:Another app'), isFalse);
    expect(isOwned(urlProtocol: null), isFalse);
    expect(isOwned(urlProtocol: 'not-empty'), isFalse);
    expect(isOwned(command: r'"C:\Other\reader.exe" "%1"'), isFalse);
    expect(
      isOwned(command: r'cmd.exe /c "C:\Old\mangayomi.exe" "%1"'),
      isFalse,
    );
    expect(isOwned(command: r'"C:\Old\mangayomi.exe"'), isFalse);
  });

  test('reclaims only an explicitly owned abandoned temporary lease', () {
    bool isOwned(String? owner) =>
        WindowsProtocolHandler.isOwnedTemporaryRegistration(owner: owner);

    expect(isOwned('com.kodjodevf.mangayomi/temporary/v1'), isTrue);
    expect(isOwned('com.kodjodevf.mangayomi/persistent/v1'), isFalse);
    expect(isOwned('another.application/temporary/v1'), isFalse);
    expect(isOwned(null), isFalse);
  });

  test('Windows protocol schemes are normalized and validated', () {
    expect(
      WindowsProtocolHandler.normalizeScheme('App.Chimahon.Google.OAuth'),
      'app.chimahon.google.oauth',
    );
    for (final invalid in ['', '1oauth', 'oauth callback', r'oauth\command']) {
      expect(
        () => WindowsProtocolHandler.normalizeScheme(invalid),
        throwsArgumentError,
        reason: invalid,
      );
    }
  });

  test('Windows protocol command rejects an empty executable', () {
    expect(
      () => WindowsProtocolHandler.buildCommand('', const ['%s']),
      throwsArgumentError,
    );
  });

  test('protocol arguments must include the callback placeholder', () {
    final handler = _ProtocolHandlerForTest();

    expect(() => handler.getArguments(const []), throwsArgumentError);
    expect(
      () => handler.getArguments(const ['--oauth-callback']),
      throwsArgumentError,
    );
    expect(handler.getArguments(const ['--oauth-callback', '%s']), const [
      '--oauth-callback',
      '%s',
    ]);
  });
}

class _ProtocolHandlerForTest extends ProtocolHandler {
  @override
  void register(String scheme, {String? executable, List<String>? arguments}) {}

  @override
  void registerPersistent(
    String scheme, {
    String? executable,
    List<String>? arguments,
  }) {}

  @override
  void unregister(String scheme) {}
}
