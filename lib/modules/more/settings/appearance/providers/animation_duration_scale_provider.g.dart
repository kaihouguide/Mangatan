// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'animation_duration_scale_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(AnimationDurationScale)
final animationDurationScaleProvider = AnimationDurationScaleProvider._();

final class AnimationDurationScaleProvider
    extends $NotifierProvider<AnimationDurationScale, double> {
  AnimationDurationScaleProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'animationDurationScaleProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$animationDurationScaleHash();

  @$internal
  @override
  AnimationDurationScale create() => AnimationDurationScale();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(double value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<double>(value),
    );
  }
}

String _$animationDurationScaleHash() =>
    r'07a6990893df150df9b580ce191f495ecabfee37';

abstract class _$AnimationDurationScale extends $Notifier<double> {
  double build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<double, double>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<double, double>,
              double,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}
