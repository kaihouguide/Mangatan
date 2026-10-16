import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mangayomi/services/sync/chimahon_sync_codec.dart';
import 'package:mangayomi/services/sync/cross_device_sync_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mangayomi/services/sync/sync_bytes.dart';

const _recoveryDirectoryName = 'remote_recovery';
const _recoveryDigestDomain = 'mangatan.chimahon.remote-recovery.v2';

/// Opens the append-only recovery archive for one provider account.
///
/// The account scope can contain credentials or opaque provider identifiers,
/// so only its SHA-256 digest is ever used on disk.
Future<FileChimahonRemoteRecoveryStore> defaultChimahonRemoteRecoveryStore({
  required String scopeKey,
  Directory? applicationSupportDirectory,
}) async {
  if (scopeKey.trim().isEmpty) {
    throw ArgumentError.value(scopeKey, 'scopeKey', 'Must not be empty');
  }
  final support =
      applicationSupportDirectory ?? await getApplicationSupportDirectory();
  final scopeDigest = sha256.convert(utf8.encode(scopeKey)).toString();
  return FileChimahonRemoteRecoveryStore(
    Directory(
      p.join(
        support.path,
        'sync',
        'chimahon',
        scopeDigest,
        _recoveryDirectoryName,
      ),
    ),
  );
}

abstract interface class ChimahonRemoteRecoveryStore {
  /// Persists [snapshot] before the corresponding remote state is changed.
  ///
  /// Repeating identical content is idempotent, even when a provider assigns a
  /// new revision. Implementors must never replace an existing entry with
  /// different bytes.
  Future<ChimahonRemoteRecoveryRecord> preserve(RemoteSyncSnapshot snapshot);
}

class ChimahonRemoteRecoveryRecord {
  const ChimahonRemoteRecoveryRecord({
    required this.digest,
    required this.alreadyPresent,
  });

  /// A domain-separated digest of the exact recovery bytes.
  final String digest;
  final bool alreadyPresent;
}

enum ChimahonRemoteRecoveryFailure {
  incompleteSnapshot('incomplete_remote_snapshot'),
  invalidPayload('invalid_remote_payload'),
  existingEntryMismatch('existing_recovery_mismatch'),
  persistenceFailed('recovery_persistence_failed');

  const ChimahonRemoteRecoveryFailure(this.code);

  final String code;
}

/// Fixed-code error that cannot disclose a credential, account ID, Drive ID,
/// title, URL, or local path through a UI/log boundary.
class ChimahonRemoteRecoveryException implements Exception {
  const ChimahonRemoteRecoveryException(this.failure);

  final ChimahonRemoteRecoveryFailure failure;

  @override
  String toString() => 'Chimahon remote recovery failed (${failure.code}).';
}

/// Append-only local archive of exact, importable remote payload bytes.
class FileChimahonRemoteRecoveryStore implements ChimahonRemoteRecoveryStore {
  const FileChimahonRemoteRecoveryStore(
    this.directory, {
    this.codec = const ChimahonSyncCodec(),
  });

  final Directory directory;
  final ChimahonSyncCodec codec;

  @override
  Future<ChimahonRemoteRecoveryRecord> preserve(
    RemoteSyncSnapshot snapshot,
  ) async {
    if (!snapshot.isCompleteRecovery) {
      throw const ChimahonRemoteRecoveryException(
        ChimahonRemoteRecoveryFailure.incompleteSnapshot,
      );
    }

    final bytes = Uint8List.fromList(snapshot.bytes);
    try {
      // Both gzip protobuf and raw protobuf are accepted by Mangatan's
      // `.tachibk` importer. Decode before touching the archive so a corrupt
      // download can never be treated as recovery evidence.
      codec.decode(bytes);
    } on ChimahonSyncFormatException {
      throw const ChimahonRemoteRecoveryException(
        ChimahonRemoteRecoveryFailure.invalidPayload,
      );
    }

    final digest = _snapshotDigest(bytes);
    final target = File(p.join(directory.path, '$digest.tachibk'));
    RandomAccessFile? lock;
    try {
      await directory.create(recursive: true);
      lock = await File(p.join(directory.path, '.append.lock'))
          .open(mode: FileMode.append);
      await lock.lock(FileLock.blockingExclusive);

      if (await target.exists()) {
        final existing = await target.readAsBytes();
        if (!sameBytes(existing, bytes)) {
          throw const ChimahonRemoteRecoveryException(
            ChimahonRemoteRecoveryFailure.existingEntryMismatch,
          );
        }
        return ChimahonRemoteRecoveryRecord(
          digest: digest,
          alreadyPresent: true,
        );
      }

      final temporary = File(
        p.join(
          directory.path,
          '.tmp_${digest}_${pid}_${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      try {
        // Flush a uniquely named temporary file before publishing it. A crash
        // can therefore leave only an ignored temp, never an empty/truncated
        // digest entry that would permanently block later recovery attempts.
        await temporary.writeAsBytes(bytes, flush: true);
        if (await target.exists()) {
          final existing = await target.readAsBytes();
          if (!sameBytes(existing, bytes)) {
            throw const ChimahonRemoteRecoveryException(
              ChimahonRemoteRecoveryFailure.existingEntryMismatch,
            );
          }
          return ChimahonRemoteRecoveryRecord(
            digest: digest,
            alreadyPresent: true,
          );
        }
        // All cooperating writers hold the same account archive lock. The
        // target was checked again immediately before this atomic publish and
        // completed digest entries are never renamed, deleted, or rewritten.
        await temporary.rename(target.path);
        if (!sameBytes(await target.readAsBytes(), bytes)) {
          throw const ChimahonRemoteRecoveryException(
            ChimahonRemoteRecoveryFailure.persistenceFailed,
          );
        }
      } finally {
        // Clean only this call's unpublished temporary. Completed target files
        // are append-only and are never touched by failure cleanup.
        if (await temporary.exists()) {
          try {
            await temporary.delete();
          } catch (_) {}
        }
      }
      return ChimahonRemoteRecoveryRecord(
        digest: digest,
        alreadyPresent: false,
      );
    } on ChimahonRemoteRecoveryException {
      rethrow;
    } catch (_) {
      throw const ChimahonRemoteRecoveryException(
        ChimahonRemoteRecoveryFailure.persistenceFailed,
      );
    } finally {
      if (lock != null) {
        try {
          await lock.unlock();
        } catch (_) {}
        try {
          await lock.close();
        } catch (_) {}
      }
    }
  }

  String _snapshotDigest(Uint8List bytes) {
    final contentDigest = sha256.convert(bytes).toString();
    return sha256
        .convert(utf8.encode('$_recoveryDigestDomain\n$contentDigest'))
        .toString();
  }
}
