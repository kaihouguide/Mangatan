import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/services/sync/chimahon_deferred_payload_store.dart';
import 'package:mangayomi/services/sync/chimahon_pre_upload_safety_gate.dart';
import 'package:mangayomi/services/sync/cross_device_sync_storage.dart';
import 'package:mangayomi/services/sync/google_drive_oauth.dart';
import 'package:mangayomi/services/sync/google_drive_refresh_token_store.dart';
import 'package:mangayomi/services/sync/sync_user_message.dart';

void main() {
  const secret = 'refresh-token-secret';
  const privatePath = '/Users/private/sync/account.sidecar';

  test('generic messages never render exception text', () {
    final error = _SentinelError('$secret at $privatePath');

    for (final context in SyncUserMessageContext.values) {
      final message = safeSyncUserMessage(error, context: context);
      expect(message, isNot(contains(secret)));
      expect(message, isNot(contains(privatePath)));
      expect(message, isNot(contains('_SentinelError')));
    }
  });

  test('typed storage messages discard paths and provider details', () {
    final message = safeSyncUserMessage(
      const SyncStorageException('$secret at $privatePath'),
      context: SyncUserMessageContext.googleDriveConnection,
    );

    expect(
      message,
      'Google Drive could not verify the sync data. No connection was saved.',
    );
    expect(message, isNot(contains(secret)));
    expect(message, isNot(contains(privatePath)));
  });

  test('a local change during sync says so, not that the service is down', () {
    final message = safeSyncUserMessage(
      const SyncLocalDataChangedException('$secret at $privatePath'),
    );

    expect(
      message,
      'Your library changed during sync, so nothing was overwritten. '
      'Sync again.',
    );
    expect(message, isNot(contains(secret)));
    expect(message, isNot(contains(privatePath)));
  });

  test('OAuth mapping uses only its fixed code', () {
    final message = safeSyncUserMessage(
      const GoogleDriveOAuthException(
        '$secret at $privatePath',
        code: 'invalid_grant',
      ),
      context: SyncUserMessageContext.googleDriveConnection,
    );

    expect(
      message,
      'Google Drive authorization expired. Reconnect Google Drive.',
    );
    expect(message, isNot(contains(secret)));
    expect(message, isNot(contains(privatePath)));
  });

  test('safety-check messages do not trust an arbitrary code string', () {
    const error = ChimahonPreUploadSafetyException(
      code: '$secret at $privatePath',
    );

    final message = safeSyncUserMessage(error);

    expect(message, 'Sync was stopped by the Chimahon safety check.');
    expect(message, isNot(contains(secret)));
    expect(message, isNot(contains(privatePath)));
  });

  test('corrupt deferred restore message omits private paths', () {
    const error = ChimahonDeferredPayloadCorruptionException([
      '$secret at $privatePath',
    ]);

    final message = safeSyncUserMessage(error);

    expect(
      message,
      'Chimahon restore data is incomplete. Restore the original backup '
      'again before syncing.',
    );
    expect(message, isNot(contains(secret)));
    expect(message, isNot(contains(privatePath)));
  });

  test('incomplete pending restore message gives fixed recovery guidance', () {
    const error = ChimahonPendingManualRestoreIncompleteException(
      ChimahonPendingManualRestorePhase.preparing,
    );

    final message = safeSyncUserMessage(error);

    expect(
      message,
      'Chimahon restore data is incomplete. Restore the original backup '
      'again before syncing.',
    );
    expect(message, isNot(contains(secret)));
    expect(message, isNot(contains(privatePath)));
  });

  test('credential denial gives fixed Keychain recovery guidance', () {
    const error = SyncCredentialAccessException(
      SyncCredentialAccessFailureReason.denied,
    );

    final message = safeSyncUserMessage(error);

    expect(message, contains('approve the Keychain prompt'));
    expect(message, isNot(contains(secret)));
    expect(message, isNot(contains(privatePath)));
  });

  test('incomplete authoritative download instructs a safe retry', () {
    final message = safeSyncUserMessage(
      const ChimahonAuthoritativeDownloadIncompleteException(),
    );

    expect(message, contains('Retry Download only'));
    expect(message, isNot(contains(secret)));
    expect(message, isNot(contains(privatePath)));
  });
}

class _SentinelError implements Exception {
  const _SentinelError(this.value);

  final String value;

  @override
  String toString() => value;
}
