import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/backup_format.dart';

void main() {
  final archive = Archive()
    ..addFile(ArchiveFile('content.backup.db', 0, const <int>[]));

  test('recognizes newly branded Mangatan backups', () {
    expect(
      checkBackupType('/tmp/mangatan_2026-07-10.backup', archive),
      BackupType.mangayomi,
    );
  });

  test('continues to recognize legacy backups', () {
    expect(
      checkBackupType('/tmp/mangayomi_2025-01-01.backup', archive),
      BackupType.mangayomi,
    );
  });
}
