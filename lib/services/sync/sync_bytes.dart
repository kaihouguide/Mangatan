import 'package:protobuf/protobuf.dart';

/// Element-wise equality for byte buffers.
bool sameBytes(List<int> left, List<int> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

/// True when both messages serialize to the same bytes, including unknown
/// fields that a field-by-field comparison would miss.
bool sameMessageBytes(GeneratedMessage left, GeneratedMessage right) =>
    sameBytes(left.writeToBuffer(), right.writeToBuffer());
