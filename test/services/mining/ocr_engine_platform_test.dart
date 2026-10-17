import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';
import 'package:mangayomi/services/sync/chimahon_mining_settings_adapter.dart';

void main() {
  test('Apple platforms expose Apple Vision but not ScreenAI', () {
    final engines = availableOcrEngines(platform: OcrHostPlatform.apple);

    expect(engines, contains(OcrEnginePreference.appleVision));
    expect(engines, isNot(contains(OcrEnginePreference.screenAi)));
  });

  test('Windows exposes ScreenAI but not Apple Vision', () {
    final engines = availableOcrEngines(platform: OcrHostPlatform.windows);

    expect(engines, contains(OcrEnginePreference.screenAi));
    expect(engines, isNot(contains(OcrEnginePreference.appleVision)));
  });

  test('other platforms expose neither platform-specific local engine', () {
    final engines = availableOcrEngines(platform: OcrHostPlatform.other);

    expect(engines, isNot(contains(OcrEnginePreference.appleVision)));
    expect(engines, isNot(contains(OcrEnginePreference.screenAi)));
  });

  test('stale platform-specific preferences normalize to Automatic', () {
    expect(
      normalizeOcrEngine(
        OcrEnginePreference.screenAi,
        platform: OcrHostPlatform.apple,
      ),
      OcrEnginePreference.automatic,
    );
    expect(
      normalizeOcrEngine(
        OcrEnginePreference.appleVision,
        platform: OcrHostPlatform.windows,
      ),
      OcrEnginePreference.automatic,
    );
  });

  test('portable local OCR maps to the platform-local implementation', () {
    expect(
      localOcrEngineForPlatform(OcrHostPlatform.apple),
      OcrEnginePreference.appleVision,
    );
    expect(
      localOcrEngineForPlatform(OcrHostPlatform.windows),
      OcrEnginePreference.screenAi,
    );
    expect(
      localOcrEngineForPlatform(OcrHostPlatform.other),
      OcrEnginePreference.automatic,
    );
  });

  test('Chimahon maps both local engines to its portable local value', () {
    expect(exportChimahonOcrEngine(OcrEnginePreference.appleVision), 'local');
    expect(exportChimahonOcrEngine(OcrEnginePreference.screenAi), 'local');
    expect(
      importChimahonOcrEngine('local', platform: OcrHostPlatform.apple),
      OcrEnginePreference.appleVision,
    );
    expect(
      importChimahonOcrEngine('local', platform: OcrHostPlatform.windows),
      OcrEnginePreference.screenAi,
    );
  });

  test('Chimahon 2.4 Paddle imports as the local on-device engine', () {
    expect(
      importChimahonOcrEngine('paddle', platform: OcrHostPlatform.apple),
      OcrEnginePreference.appleVision,
    );
    expect(
      importChimahonOcrEngine('paddle', platform: OcrHostPlatform.windows),
      OcrEnginePreference.screenAi,
    );
    expect(
      importChimahonOcrEngine('future-engine', platform: OcrHostPlatform.apple),
      isNull,
    );
  });
}
