import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/modules/mining/widgets/hoshi_dictionary_popup.dart';

void main() {
  test('dictionary links open only web pages', () {
    expect(isExternalWebLink(Uri.parse('https://jisho.org/word/猫')), isTrue);
    expect(isExternalWebLink(Uri.parse('http://example.test/a')), isTrue);
    for (final link in [
      'file:///etc/hosts',
      'sms:+15550100?body=hi',
      'tel:+15550100',
      'intent://scan/#Intent;scheme=zxing;end',
      'someapp://open',
      'javascript:alert(1)',
      'https:///no-host',
    ]) {
      expect(isExternalWebLink(Uri.parse(link)), isFalse, reason: link);
    }
  });
}
