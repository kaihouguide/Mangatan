import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/services/mining/media_file_name.dart';

void main() {
  test('replaces path-unsafe characters and collapses whitespace', () {
    expect(sanitizeMediaFileName('  a/b:c*d  \n e?"<>|f  '), 'a_b_c_d e_____f');
  });

  test('keeps brackets unless the name goes inside an Anki marker', () {
    expect(sanitizeMediaFileName('[x]'), '[x]');
    expect(sanitizeMediaFileName('[x]', forbidBrackets: true), '_x_');
  });
}
