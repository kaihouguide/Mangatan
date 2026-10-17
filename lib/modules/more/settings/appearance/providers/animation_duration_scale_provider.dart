import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:mangayomi/repositories/settings_repository.dart';

part 'animation_duration_scale_provider.g.dart';

const defaultAnimationDurationScale = 1.0;
const minimumAnimationDurationScale = 0.0;
const maximumAnimationDurationScale = 1.1;

// Flutter's scheduler requires a positive time dilation. One thousandth makes
// finite UI animations finish before the next frame while keeping controllers
// in a valid completed state. Repeating motion is stopped by the app's
// reduced-motion UI branches.
const disabledAnimationTimeDilation = 0.001;

double normalizeAnimationDurationScale(double? value) {
  return (value ?? defaultAnimationDurationScale).clamp(
    minimumAnimationDurationScale,
    maximumAnimationDurationScale,
  );
}

double animationTimeDilation(double durationScale) {
  final normalized = normalizeAnimationDurationScale(durationScale);
  return normalized == minimumAnimationDurationScale
      ? disabledAnimationTimeDilation
      : normalized;
}

@riverpod
class AnimationDurationScale extends _$AnimationDurationScale {
  @override
  double build() {
    return normalizeAnimationDurationScale(
      isar.settings.getSync(227)!.animationDurationScale,
    );
  }

  void set(double value, {bool persist = false}) {
    state = normalizeAnimationDurationScale(value);
    if (!persist) return;

    settingsRepository.update((s) => s.animationDurationScale = state);
  }
}
