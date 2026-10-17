import 'dart:convert';
import 'dart:typed_data';

/// A minimal protobuf wire-format reader for OCR responses that have no
/// generated message classes. Unknown fields are kept and simply never read.
class ProtoWireMessage {
  const ProtoWireMessage._(this._fields);

  final Map<int, List<_ProtoField>> _fields;

  /// Throws [FormatException] for a truncated or malformed message.
  factory ProtoWireMessage.decode(Uint8List bytes) {
    final fields = <int, List<_ProtoField>>{};
    final cursor = _ProtoCursor(bytes);
    while (!cursor.isDone) {
      final tag = cursor.varint();
      final field = tag >> 3;
      final wireType = tag & 7;
      if (field == 0) throw const FormatException('Invalid protobuf field');
      final value = switch (wireType) {
        0 => _ProtoField(wireType, cursor.varint()),
        1 => _ProtoField(wireType, cursor.read(8)),
        2 => _ProtoField(wireType, cursor.read(cursor.varint())),
        5 => _ProtoField(wireType, cursor.read(4)),
        _ => throw FormatException('Unsupported protobuf wire type $wireType'),
      };
      fields.putIfAbsent(field, () => []).add(value);
    }
    return ProtoWireMessage._(fields);
  }

  /// Every embedded message stored under [field], in wire order.
  Iterable<ProtoWireMessage> messages(int field) sync* {
    for (final value in _fields[field] ?? const <_ProtoField>[]) {
      if (value.wireType == 2 && value.value is Uint8List) {
        yield ProtoWireMessage.decode(value.value as Uint8List);
      }
    }
  }

  ProtoWireMessage? message(int field) => messages(field).firstOrNull;

  String string(int field) {
    final value = _fields[field]?.firstOrNull;
    if (value?.wireType != 2 || value?.value is! Uint8List) return '';
    return utf8.decode(value!.value as Uint8List, allowMalformed: true);
  }

  int? int32(int field) {
    final value = _fields[field]?.firstOrNull;
    if (value?.wireType != 0 || value?.value is! int) return null;
    return value!.value as int;
  }

  double? float32(int field) {
    final value = _fields[field]?.firstOrNull;
    if (value?.wireType != 5 || value?.value is! Uint8List) return null;
    final data = ByteData.sublistView(value!.value as Uint8List);
    return data.getFloat32(0, Endian.little).toDouble();
  }
}

class _ProtoField {
  const _ProtoField(this.wireType, this.value);

  final int wireType;
  final Object value;
}

class _ProtoCursor {
  _ProtoCursor(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  bool get isDone => offset >= bytes.length;

  int varint() {
    var result = 0;
    var shift = 0;
    while (offset < bytes.length && shift < 70) {
      final byte = bytes[offset++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
    }
    throw const FormatException('Truncated protobuf varint');
  }

  Uint8List read(int length) {
    if (length < 0 || offset + length > bytes.length) {
      throw const FormatException('Truncated protobuf field');
    }
    final value = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return value;
  }
}
