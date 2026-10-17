// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'local_archive.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(importArchivesFromFile)
final importArchivesFromFileProvider = ImportArchivesFromFileFamily._();

final class ImportArchivesFromFileProvider
    extends $FunctionalProvider<AsyncValue<dynamic>, dynamic, FutureOr<dynamic>>
    with $FutureModifier<dynamic>, $FutureProvider<dynamic> {
  ImportArchivesFromFileProvider._({
    required ImportArchivesFromFileFamily super.from,
    required (Manga?, {ItemType itemType, bool init, bool splitChapters})
    super.argument,
  }) : super(
         retry: null,
         name: r'importArchivesFromFileProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$importArchivesFromFileHash();

  @override
  String toString() {
    return r'importArchivesFromFileProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $FutureProviderElement<dynamic> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<dynamic> create(Ref ref) {
    final argument =
        this.argument
            as (Manga?, {ItemType itemType, bool init, bool splitChapters});
    return importArchivesFromFile(
      ref,
      argument.$1,
      itemType: argument.itemType,
      init: argument.init,
      splitChapters: argument.splitChapters,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ImportArchivesFromFileProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$importArchivesFromFileHash() =>
    r'7fa565e0f20aebf29a7950709230d419ec203c61';

final class ImportArchivesFromFileFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<dynamic>,
          (Manga?, {ItemType itemType, bool init, bool splitChapters})
        > {
  ImportArchivesFromFileFamily._()
    : super(
        retry: null,
        name: r'importArchivesFromFileProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ImportArchivesFromFileProvider call(
    Manga? mManga, {
    required ItemType itemType,
    required bool init,
    bool splitChapters = false,
  }) => ImportArchivesFromFileProvider._(
    argument: (
      mManga,
      itemType: itemType,
      init: init,
      splitChapters: splitChapters,
    ),
    from: this,
  );

  @override
  String toString() => r'importArchivesFromFileProvider';
}

/// Imports paths supplied by a non-picker source, such as desktop drag-and-drop.

@ProviderFor(importArchivesFromPaths)
final importArchivesFromPathsProvider = ImportArchivesFromPathsFamily._();

/// Imports paths supplied by a non-picker source, such as desktop drag-and-drop.

final class ImportArchivesFromPathsProvider
    extends $FunctionalProvider<AsyncValue<void>, void, FutureOr<void>>
    with $FutureModifier<void>, $FutureProvider<void> {
  /// Imports paths supplied by a non-picker source, such as desktop drag-and-drop.
  ImportArchivesFromPathsProvider._({
    required ImportArchivesFromPathsFamily super.from,
    required (
      Manga?, {
      List<String> filePaths,
      ItemType itemType,
      bool init,
      bool splitChapters,
    })
    super.argument,
  }) : super(
         retry: null,
         name: r'importArchivesFromPathsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$importArchivesFromPathsHash();

  @override
  String toString() {
    return r'importArchivesFromPathsProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $FutureProviderElement<void> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<void> create(Ref ref) {
    final argument =
        this.argument
            as (
              Manga?, {
              List<String> filePaths,
              ItemType itemType,
              bool init,
              bool splitChapters,
            });
    return importArchivesFromPaths(
      ref,
      argument.$1,
      filePaths: argument.filePaths,
      itemType: argument.itemType,
      init: argument.init,
      splitChapters: argument.splitChapters,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ImportArchivesFromPathsProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$importArchivesFromPathsHash() =>
    r'ab6183a1611de1c0e6d68662b49381a349f8609f';

/// Imports paths supplied by a non-picker source, such as desktop drag-and-drop.

final class ImportArchivesFromPathsFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<void>,
          (
            Manga?, {
            List<String> filePaths,
            ItemType itemType,
            bool init,
            bool splitChapters,
          })
        > {
  ImportArchivesFromPathsFamily._()
    : super(
        retry: null,
        name: r'importArchivesFromPathsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// Imports paths supplied by a non-picker source, such as desktop drag-and-drop.

  ImportArchivesFromPathsProvider call(
    Manga? mManga, {
    required List<String> filePaths,
    required ItemType itemType,
    required bool init,
    bool splitChapters = false,
  }) => ImportArchivesFromPathsProvider._(
    argument: (
      mManga,
      filePaths: filePaths,
      itemType: itemType,
      init: init,
      splitChapters: splitChapters,
    ),
    from: this,
  );

  @override
  String toString() => r'importArchivesFromPathsProvider';
}
