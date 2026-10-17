// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'immersion_stats_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Aggregates immersion statistics for one filter combination.
///
/// This is the Dart counterpart of Chimahon's `StatsScreenModel`. Manga rows
/// hold milliseconds and novel rows hold seconds, so every novel value is
/// converted at the point of use rather than at load time — matching Chimahon
/// and keeping the persisted schema byte-compatible.

@ProviderFor(immersionStats)
final immersionStatsProvider = ImmersionStatsFamily._();

/// Aggregates immersion statistics for one filter combination.
///
/// This is the Dart counterpart of Chimahon's `StatsScreenModel`. Manga rows
/// hold milliseconds and novel rows hold seconds, so every novel value is
/// converted at the point of use rather than at load time — matching Chimahon
/// and keeping the persisted schema byte-compatible.

final class ImmersionStatsProvider
    extends
        $FunctionalProvider<
          AsyncValue<ImmersionStatsOverview>,
          ImmersionStatsOverview,
          FutureOr<ImmersionStatsOverview>
        >
    with
        $FutureModifier<ImmersionStatsOverview>,
        $FutureProvider<ImmersionStatsOverview> {
  /// Aggregates immersion statistics for one filter combination.
  ///
  /// This is the Dart counterpart of Chimahon's `StatsScreenModel`. Manga rows
  /// hold milliseconds and novel rows hold seconds, so every novel value is
  /// converted at the point of use rather than at load time — matching Chimahon
  /// and keeping the persisted schema byte-compatible.
  ImmersionStatsProvider._({
    required ImmersionStatsFamily super.from,
    required ImmersionStatsQuery super.argument,
  }) : super(
         retry: null,
         name: r'immersionStatsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$immersionStatsHash();

  @override
  String toString() {
    return r'immersionStatsProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<ImmersionStatsOverview> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<ImmersionStatsOverview> create(Ref ref) {
    final argument = this.argument as ImmersionStatsQuery;
    return immersionStats(ref, query: argument);
  }

  @override
  bool operator ==(Object other) {
    return other is ImmersionStatsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$immersionStatsHash() => r'1dab33a8047bb4e128ac8943d68e9239646a9ddf';

/// Aggregates immersion statistics for one filter combination.
///
/// This is the Dart counterpart of Chimahon's `StatsScreenModel`. Manga rows
/// hold milliseconds and novel rows hold seconds, so every novel value is
/// converted at the point of use rather than at load time — matching Chimahon
/// and keeping the persisted schema byte-compatible.

final class ImmersionStatsFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<ImmersionStatsOverview>,
          ImmersionStatsQuery
        > {
  ImmersionStatsFamily._()
    : super(
        retry: null,
        name: r'immersionStatsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// Aggregates immersion statistics for one filter combination.
  ///
  /// This is the Dart counterpart of Chimahon's `StatsScreenModel`. Manga rows
  /// hold milliseconds and novel rows hold seconds, so every novel value is
  /// converted at the point of use rather than at load time — matching Chimahon
  /// and keeping the persisted schema byte-compatible.

  ImmersionStatsProvider call({required ImmersionStatsQuery query}) =>
      ImmersionStatsProvider._(argument: query, from: this);

  @override
  String toString() => r'immersionStatsProvider';
}

/// The per-title list backing the "In library" card drill-down.

@ProviderFor(immersionStatsTitles)
final immersionStatsTitlesProvider = ImmersionStatsTitlesFamily._();

/// The per-title list backing the "In library" card drill-down.

final class ImmersionStatsTitlesProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<ImmersionStatsTitle>>,
          List<ImmersionStatsTitle>,
          FutureOr<List<ImmersionStatsTitle>>
        >
    with
        $FutureModifier<List<ImmersionStatsTitle>>,
        $FutureProvider<List<ImmersionStatsTitle>> {
  /// The per-title list backing the "In library" card drill-down.
  ImmersionStatsTitlesProvider._({
    required ImmersionStatsTitlesFamily super.from,
    required ({
      ImmersionStatsQuery query,
      ImmersionStatsTitlesSort sort,
      String? search,
    })
    super.argument,
  }) : super(
         retry: null,
         name: r'immersionStatsTitlesProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$immersionStatsTitlesHash();

  @override
  String toString() {
    return r'immersionStatsTitlesProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $FutureProviderElement<List<ImmersionStatsTitle>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<ImmersionStatsTitle>> create(Ref ref) {
    final argument =
        this.argument
            as ({
              ImmersionStatsQuery query,
              ImmersionStatsTitlesSort sort,
              String? search,
            });
    return immersionStatsTitles(
      ref,
      query: argument.query,
      sort: argument.sort,
      search: argument.search,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ImmersionStatsTitlesProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$immersionStatsTitlesHash() =>
    r'5349d9f9f46697cf386e05a2cf3b78927e21c78f';

/// The per-title list backing the "In library" card drill-down.

final class ImmersionStatsTitlesFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<List<ImmersionStatsTitle>>,
          ({
            ImmersionStatsQuery query,
            ImmersionStatsTitlesSort sort,
            String? search,
          })
        > {
  ImmersionStatsTitlesFamily._()
    : super(
        retry: null,
        name: r'immersionStatsTitlesProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// The per-title list backing the "In library" card drill-down.

  ImmersionStatsTitlesProvider call({
    required ImmersionStatsQuery query,
    required ImmersionStatsTitlesSort sort,
    String? search,
  }) => ImmersionStatsTitlesProvider._(
    argument: (query: query, sort: sort, search: search),
    from: this,
  );

  @override
  String toString() => r'immersionStatsTitlesProvider';
}

/// Dictionary profiles available as a filter.

@ProviderFor(immersionStatsProfiles)
final immersionStatsProfilesProvider = ImmersionStatsProfilesProvider._();

/// Dictionary profiles available as a filter.

final class ImmersionStatsProfilesProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<DictionaryProfile>>,
          List<DictionaryProfile>,
          FutureOr<List<DictionaryProfile>>
        >
    with
        $FutureModifier<List<DictionaryProfile>>,
        $FutureProvider<List<DictionaryProfile>> {
  /// Dictionary profiles available as a filter.
  ImmersionStatsProfilesProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'immersionStatsProfilesProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$immersionStatsProfilesHash();

  @$internal
  @override
  $FutureProviderElement<List<DictionaryProfile>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<DictionaryProfile>> create(Ref ref) {
    return immersionStatsProfiles(ref);
  }
}

String _$immersionStatsProfilesHash() =>
    r'ea244dd8b8185e5cae12f3d73b9bac91e98f84be';
