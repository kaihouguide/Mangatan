import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/services/mining/proto_wire.dart';

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  test('reads strings, integers, floats and nested messages', () {
    final text = utf8.encode('字');
    final float = ByteData(4)..setFloat32(0, 0.5, Endian.little);
    final nested = [0x08, 0x2a]; // field 1, varint 42
    final message = ProtoWireMessage.decode(
      _bytes([
        0x0a, text.length, ...text, // field 1, string
        0x10, 0xac, 0x02, // field 2, varint 300
        0x1d, ...float.buffer.asUint8List(), // field 3, fixed32
        0x22, nested.length, ...nested, // field 4, message
        0x22, nested.length, ...nested, // field 4 repeated
        0x29, 0, 0, 0, 0, 0, 0, 0, 0, // field 5, unread fixed64
      ]),
    );

    expect(message.string(1), '字');
    expect(message.int32(2), 300);
    expect(message.float32(3), 0.5);
    expect(message.messages(4).map((m) => m.int32(1)), [42, 42]);
    expect(message.message(4)?.int32(1), 42);
  });

  test('a missing or mistyped field reads as empty', () {
    final message = ProtoWireMessage.decode(_bytes([0x08, 0x01]));

    expect(message.string(1), '');
    expect(message.float32(1), isNull);
    expect(message.int32(9), isNull);
    expect(message.message(1), isNull);
  });

  test('rejects truncated and malformed input', () {
    expect(
      () => ProtoWireMessage.decode(_bytes([0x08, 0x80])),
      throwsFormatException,
    );
    expect(
      () => ProtoWireMessage.decode(_bytes([0x0a, 0x05, 0x01])),
      throwsFormatException,
    );
    expect(
      () => ProtoWireMessage.decode(_bytes([0x00])),
      throwsFormatException,
    );
    expect(
      () => ProtoWireMessage.decode(_bytes([0x0b])), // wire type 3
      throwsFormatException,
    );
  });
}
