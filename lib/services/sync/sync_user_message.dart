import 'package:mangayomi/services/sync/chimahon_deferred_payload_store.dart';
import 'package:mangayomi/services/sync/chimahon_pre_upload_safety_gate.dart';
import 'package:mangayomi/services/sync/cross_device_sync_storage.dart';
import 'package:mangayomi/services/sync/google_drive_oauth.dart';
import 'package:mangayomi/services/sync/google_drive_refresh_token_store.dart';

enum SyncUserMessageContext {
  synchronization,
  signIn,
  googleDriveConnection,
  googleDriveDisconnection,
  webDavConnection,
  webDavDisconnection,
}

/// Maps sync failures to fixed user-facing text without rendering exceptions.
///
/// Exception strings can contain credentials, Drive identifiers, absolute
/// sidecar paths, or platform/plugin details. Keep every fallback constant and
/// branch only on typed errors or fixed error codes.
String safeSyncUserMessage(
  Object error, {
  SyncUserMessageContext context = SyncUserMessageContext.synchronization,
}) {
  if (context == SyncUserMessageContext.googleDriveDisconnection) {
    return 'Could not disconnect Google Drive. The saved connection was kept.';
  }
  if (context == SyncUserMessageContext.webDavDisconnection) {
    return 'Could not disconnect WebDAV. The saved connection was kept.';
  }
  if (error is GoogleDriveOAuthException) {
    return switch (error.code) {
      'invalid_grant' =>
        'Google Drive authorization expired. Reconnect Google Drive.',
      'callback_timeout' => 'Google Drive sign-in timed out. Try again.',
      'browser_launch_failed' =>
        'Could not open Google sign-in. Check your browser and try again.',
      'access_denied' => 'Google Drive sign-in was cancelled.',
      _ => 'Google Drive sign-in failed. Try again.',
    };
  }
  if (error is SyncCredentialAccessException) {
    return switch (error.reason) {
      SyncCredentialAccessFailureReason.denied => 'macOS Keychain access was denied. Restart Mangatan, retry, and approve the Keychain prompt.',
      SyncCredentialAccessFailureReason.locked => 'The system credential store is locked. Unlock it and try syncing again.',
      SyncCredentialAccessFailureReason.missing =>
        'Google Drive is not connected. Connect it again before syncing.',
      SyncCredentialAccessFailureReason.unavailable => 'The system credential store is unavailable. Try again after restarting Mangatan.',
    };
  }
  if (error is SyncLocalDataChangedException) {
    return 'Your library changed during sync, so nothing was overwritten. '
        'Sync again.';
  }
  if (error is SyncConflictException) {
    return 'Sync data changed on another device. Try syncing again.';
  }
  if (error is ChimahonPreUploadSafetyException) {
    return 'Sync was stopped by the Chimahon safety check.';
  }
  if (error is ChimahonDeferredPayloadCorruptionException ||
      error is ChimahonPendingManualRestoreIncompleteException) {
    return 'Chimahon restore data is incomplete. Restore the original backup '
        'again before syncing.';
  }
  if (error is ChimahonAuthoritativeDownloadIncompleteException) {
    return 'A previous Download-only restore did not finish. Retry Download '
        'only before uploading or running two-way sync.';
  }
  if (error is SyncStorageException) {
    return context == SyncUserMessageContext.googleDriveConnection
        ? 'Google Drive could not verify the sync data. No connection was saved.'
        : context == SyncUserMessageContext.webDavConnection
        ? 'WebDAV could not verify safe conditional sync. No connection was saved.'
        : 'The sync service is unavailable. Check the connection and try again.';
  }
  return switch (context) {
    SyncUserMessageContext.signIn =>
      'Sign-in failed. Check the server and credentials.',
    SyncUserMessageContext.googleDriveConnection =>
      'Google Drive connection failed. No connection was saved.',
    SyncUserMessageContext.googleDriveDisconnection =>
      'Could not disconnect Google Drive. The saved connection was kept.',
    SyncUserMessageContext.webDavConnection =>
      'WebDAV connection failed. No connection was saved.',
    SyncUserMessageContext.webDavDisconnection =>
      'Could not disconnect WebDAV. The saved connection was kept.',
    SyncUserMessageContext.synchronization => 'Sync failed safely. Try again.',
  };
}
