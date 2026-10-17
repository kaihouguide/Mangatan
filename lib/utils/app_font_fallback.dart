import 'package:flutter/material.dart';

/// Common platform Japanese fonts, followed by a bundled offline CJK font.
///
/// This keeps translated menus readable when the selected Google font does not
/// contain Japanese glyphs. The bundled fallback also works while offline.
const appFontFamilyFallback = <String>[
  'Hiragino Sans',
  'Hiragino Kaku Gothic ProN',
  'Noto Sans CJK JP',
  'Noto Sans JP',
  'Yu Gothic UI',
  'Yu Gothic',
  'MangatanCJK',
  'sans-serif',
];

ThemeData applyAppFontFallback(ThemeData theme) {
  return theme.copyWith(
    textTheme: _applyTextThemeFallback(theme.textTheme),
    primaryTextTheme: _applyTextThemeFallback(theme.primaryTextTheme),
  );
}

TextTheme _applyTextThemeFallback(TextTheme theme) {
  TextStyle? withFallback(TextStyle? style) {
    if (style == null) return null;
    return style.copyWith(
      fontFamilyFallback: <String>{
        ...?style.fontFamilyFallback,
        ...appFontFamilyFallback,
      }.toList(),
    );
  }

  return theme.copyWith(
    displayLarge: withFallback(theme.displayLarge),
    displayMedium: withFallback(theme.displayMedium),
    displaySmall: withFallback(theme.displaySmall),
    headlineLarge: withFallback(theme.headlineLarge),
    headlineMedium: withFallback(theme.headlineMedium),
    headlineSmall: withFallback(theme.headlineSmall),
    titleLarge: withFallback(theme.titleLarge),
    titleMedium: withFallback(theme.titleMedium),
    titleSmall: withFallback(theme.titleSmall),
    bodyLarge: withFallback(theme.bodyLarge),
    bodyMedium: withFallback(theme.bodyMedium),
    bodySmall: withFallback(theme.bodySmall),
    labelLarge: withFallback(theme.labelLarge),
    labelMedium: withFallback(theme.labelMedium),
    labelSmall: withFallback(theme.labelSmall),
  );
}
