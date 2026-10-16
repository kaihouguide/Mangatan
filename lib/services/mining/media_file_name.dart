final _forbiddenFileNameCharacters = RegExp(r'[\\/:*?"<>|]');
final _forbiddenAnkiFileNameCharacters = RegExp(r'[\\/:*?"<>|\[\]]');
final _whitespaceRun = RegExp(r'\s+');

/// Replaces path-unsafe characters with `_` and collapses whitespace.
///
/// Set [forbidBrackets] for names Anki embeds in `[sound:...]` markers, where
/// a bracket would end the marker early.
String sanitizeMediaFileName(String value, {bool forbidBrackets = false}) =>
    value
        .replaceAll(
          forbidBrackets
              ? _forbiddenAnkiFileNameCharacters
              : _forbiddenFileNameCharacters,
          '_',
        )
        .replaceAll(_whitespaceRun, ' ')
        .trim();
