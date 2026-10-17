import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupManga.pb.dart';
import 'package:mangayomi/services/sync/sync_bytes.dart';

void main() {
  test('compares byte buffers element by element', () {
    expect(sameBytes([1, 2, 3], [1, 2, 3]), isTrue);
    expect(sameBytes([1, 2, 3], [1, 2, 4]), isFalse);
    expect(sameBytes([1, 2], [1, 2, 3]), isFalse);
    expect(sameBytes(const [], const []), isTrue);
  });

  test('message comparison sees fields a == check is not asked about', () {
    final left = BackupManga(title: 'A', url: '/a');
    final same = BackupManga(title: 'A', url: '/a');
    final different = BackupManga(title: 'A', url: '/b');

    expect(sameMessageBytes(left, same), isTrue);
    expect(sameMessageBytes(left, different), isFalse);
  });

  test('message comparison includes unknown fields', () {
    final plain = BackupManga(title: 'A');
    // Field 9999 is unknown to this schema but must survive a round trip, so
    // two messages differing only there are not the same payload.
    final withUnknown = BackupManga.fromBuffer([
      ...plain.writeToBuffer(),
      0xf8, 0xb8, 0x04, 0x01, // field 9999, varint 1
    ]);

    expect(withUnknown.unknownFields.isEmpty, isFalse);
    expect(sameMessageBytes(plain, withUnknown), isFalse);
  });
}
