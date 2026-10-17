// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'file_scanner.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(LocalFoldersState)
final localFoldersStateProvider = LocalFoldersStateProvider._();

final class LocalFoldersStateProvider
    extends $NotifierProvider<LocalFoldersState, List<String>> {
  LocalFoldersStateProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'localFoldersStateProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$localFoldersStateHash();

  @$internal
  @override
  LocalFoldersState create() => LocalFoldersState();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(List<String> value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<List<String>>(value),
    );
  }
}

String _$localFoldersStateHash() => r'e3a995f05c3d074156046cd8218685df813d13e6';

abstract class _$LocalFoldersState extends $Notifier<List<String>> {
  List<String> build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<List<String>, List<String>>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<List<String>, List<String>>,
              List<String>,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}

/// Scans `Mangatan/local` folder (if exists) for Mangas/Animes and imports in library.
///
/// **Folder structure:**
/// ```
/// Mangatan/local/MangaName/CustomCover.jpg (optional)
/// Mangatan/local/MangaName/Chapter1/Page1.jpg
/// Mangatan/local/MangaName/Chapter2.cbz (or .cbr/.rar)
/// Mangatan/local/AnimeName/Episode1.mp4
/// Mangatan/local/NovelName/NovelName.epub
/// ```
/// **Supported filetypes:** (taken from lib/modules/library/providers/local_archive.dart, line 98)
/// ```
/// Videotypes:   mp4, mov, avi, flv, wmv, mpeg, mkv
/// Imagetypes:   jpg, jpeg, png, webp, avif
/// Archivetypes: cbz, zip, cbr, rar, cbt, tar
/// Other types: epub
/// ```

@ProviderFor(scanLocalLibrary)
final scanLocalLibraryProvider = ScanLocalLibraryProvider._();

/// Scans `Mangatan/local` folder (if exists) for Mangas/Animes and imports in library.
///
/// **Folder structure:**
/// ```
/// Mangatan/local/MangaName/CustomCover.jpg (optional)
/// Mangatan/local/MangaName/Chapter1/Page1.jpg
/// Mangatan/local/MangaName/Chapter2.cbz (or .cbr/.rar)
/// Mangatan/local/AnimeName/Episode1.mp4
/// Mangatan/local/NovelName/NovelName.epub
/// ```
/// **Supported filetypes:** (taken from lib/modules/library/providers/local_archive.dart, line 98)
/// ```
/// Videotypes:   mp4, mov, avi, flv, wmv, mpeg, mkv
/// Imagetypes:   jpg, jpeg, png, webp, avif
/// Archivetypes: cbz, zip, cbr, rar, cbt, tar
/// Other types: epub
/// ```

final class ScanLocalLibraryProvider
    extends $FunctionalProvider<AsyncValue<void>, void, FutureOr<void>>
    with $FutureModifier<void>, $FutureProvider<void> {
  /// Scans `Mangatan/local` folder (if exists) for Mangas/Animes and imports in library.
  ///
  /// **Folder structure:**
  /// ```
  /// Mangatan/local/MangaName/CustomCover.jpg (optional)
  /// Mangatan/local/MangaName/Chapter1/Page1.jpg
  /// Mangatan/local/MangaName/Chapter2.cbz (or .cbr/.rar)
  /// Mangatan/local/AnimeName/Episode1.mp4
  /// Mangatan/local/NovelName/NovelName.epub
  /// ```
  /// **Supported filetypes:** (taken from lib/modules/library/providers/local_archive.dart, line 98)
  /// ```
  /// Videotypes:   mp4, mov, avi, flv, wmv, mpeg, mkv
  /// Imagetypes:   jpg, jpeg, png, webp, avif
  /// Archivetypes: cbz, zip, cbr, rar, cbt, tar
  /// Other types: epub
  /// ```
  ScanLocalLibraryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'scanLocalLibraryProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$scanLocalLibraryHash();

  @$internal
  @override
  $FutureProviderElement<void> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<void> create(Ref ref) {
    return scanLocalLibrary(ref);
  }
}

String _$scanLocalLibraryHash() => r'7fdedaa37917728d9f3b9d8f15090c94bdb34238';
