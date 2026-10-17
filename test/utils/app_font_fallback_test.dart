import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/utils/app_font_fallback.dart';

void main() {
  test('adds the bundled Japanese font to menu text styles', () {
    final theme = applyAppFontFallback(
      ThemeData(
        fontFamily: 'ABeeZee',
        textTheme: const TextTheme(
          labelLarge: TextStyle(fontFamily: 'ABeeZee'),
        ),
      ),
    );

    expect(
      theme.textTheme.labelLarge?.fontFamilyFallback,
      contains('MangatanCJK'),
    );
    expect(
      theme.primaryTextTheme.titleLarge?.fontFamilyFallback,
      contains('MangatanCJK'),
    );
  });
}
