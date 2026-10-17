import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:mangayomi/services/mining/mining_models.dart';

class AnkiConnectException implements Exception {
  final String message;
  const AnkiConnectException(this.message);

  @override
  String toString() => message;
}

class AnkiDuplicateException extends AnkiConnectException {
  AnkiDuplicateException(String expression, [String? detail])
    : super(
        detail == null || detail.isEmpty
            ? 'A card for "$expression" already exists.'
            : detail,
      );
}

class AnkiCanAddResult {
  const AnkiCanAddResult({required this.canAdd, this.error});

  final bool canAdd;
  final String? error;

  bool get isDuplicate =>
      !canAdd && (error?.toLowerCase().contains('duplicate') ?? false);
}

class AnkiConnectService {
  final Uri endpoint;
  final http.Client? _injectedClient;

  AnkiConnectService({Uri? endpoint, http.Client? client})
    : endpoint = endpoint ?? Uri.parse('http://127.0.0.1:8765'),
      _injectedClient = client;

  Future<dynamic> invoke(
    String action, {
    Map<String, dynamic> params = const {},
  }) async {
    // AnkiConnect closes idle HTTP/1.1 sockets without advertising it. Dart's
    // pooled client can then reuse that stale socket and fail on the next
    // request with Windows error 10053. Use a one-shot connection by default.
    final client = _injectedClient ?? http.Client();
    late final http.Response response;
    try {
      response = await client
          .post(
            endpoint,
            headers: const {
              'content-type': 'application/json',
              'connection': 'close',
            },
            body: jsonEncode({
              'action': action,
              'version': 6,
              'params': params,
            }),
          )
          .timeout(const Duration(seconds: 15));
    } catch (error) {
      throw AnkiConnectException(
        'Could not reach AnkiConnect at $endpoint. Make sure Anki is open and the AnkiConnect add-on is installed. ($error)',
      );
    } finally {
      if (_injectedClient == null) client.close();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AnkiConnectException(
        'AnkiConnect HTTP ${response.statusCode}: ${response.body}',
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      decoded = null;
    }
    // Another program can hold AnkiConnect's port. Report that like any other
    // connection problem instead of surfacing a raw decoding error.
    if (decoded is! Map) {
      throw AnkiConnectException(
        'The service at $endpoint did not answer like AnkiConnect.',
      );
    }
    final error = decoded['error'];
    if (error != null) {
      throw AnkiConnectException(error.toString());
    }
    return decoded['result'];
  }

  static List<Object?> _list(Object? result, String action) {
    if (result is List) return result;
    throw AnkiConnectException('AnkiConnect returned no list for $action.');
  }

  Future<int> version() async {
    final result = await invoke('version');
    return result is int ? result : int.tryParse(result.toString()) ?? 0;
  }

  Future<List<String>> deckNames() async {
    final result = await invoke('deckNames');
    return _list(result, 'deckNames').map((item) => item.toString()).toList();
  }

  Future<List<String>> modelNames() async {
    final result = await invoke('modelNames');
    return _list(result, 'modelNames').map((item) => item.toString()).toList();
  }

  Future<List<String>> modelFieldNames(String modelName) async {
    if (modelName.trim().isEmpty) return const [];
    final result = await invoke(
      'modelFieldNames',
      params: {'modelName': modelName},
    );
    return _list(
      result,
      'modelFieldNames',
    ).map((item) => item.toString()).toList();
  }

  Future<List<int>> findNotes(String query) async {
    final result = await invoke('findNotes', params: {'query': query});
    return _list(result, 'findNotes').whereType<int>().toList();
  }

  Future<List<int>> findDuplicateNoteIds({
    required String deckName,
    required String modelName,
    required String expression,
    String duplicateScope = 'deck',
    List<String> duplicateDeckNames = const [],
  }) async {
    final fields = await modelFieldNames(modelName);
    if (fields.isEmpty || expression.trim().isEmpty) return const [];
    final escapedDeck = _escapeSearch(deckName);
    final rootDeck = _escapeSearch(deckName.split('::').first);
    final escapedExpression = _escapeSearch(expression);
    final selectedDecks = _effectiveDuplicateDecks(
      deckName,
      duplicateDeckNames,
    );
    final scope = switch (duplicateScope) {
      'collection' => '',
      'deckroot' => '"deck:$rootDeck" ',
      'decks' when selectedDecks.isNotEmpty =>
        '(${selectedDecks.map((deck) => '"deck:${_escapeSearch(deck)}"').join(' or ')}) ',
      _ => '"deck:$escapedDeck" ',
    };
    return findNotes(
      '$scope"${fields.first.toLowerCase()}:$escapedExpression"',
    );
  }

  Future<List<int>> browseNotes(List<int> noteIds) async {
    if (noteIds.isEmpty) return const [];
    final result = await invoke(
      'guiBrowse',
      params: {'query': 'nid:${noteIds.join(',')}'},
    );
    return _list(result, 'guiBrowse').whereType<int>().toList();
  }

  /// Uploads media by embedding the raw bytes as base64 `data`.
  ///
  /// Regression guard for issue #42 ("Screenshot | Anki image export
  /// Failure"): never switch this to AnkiConnect's `url`/`path` fetch modes.
  /// When Suwayomi/OCR is self-hosted behind a Cloudflare Zero Trust (or any
  /// authenticated) custom domain, a non-host device cannot make the
  /// AnkiConnect server fetch the image itself — the server hits the auth wall
  /// and Anki reports "Failure to load image". Embedding `data` keeps the image
  /// inside the request so export works regardless of where the server runs.
  Future<String?> storeMediaFile({
    required String filename,
    required Uint8List data,
  }) async {
    final result = await invoke(
      'storeMediaFile',
      params: {'filename': filename, 'data': base64Encode(data)},
    );
    return result?.toString();
  }

  Future<String?> storeMediaSource({
    required String filename,
    required AnkiMediaSource source,
  }) {
    return source.readBytes().then(
      (data) => storeMediaFile(filename: filename, data: data),
    );
  }

  Future<int> addNote(
    AnkiCardDraft draft, {
    bool allowDuplicate = false,
    String duplicateScope = 'deck',
    bool checkAllModels = false,
  }) async {
    final result = await invoke(
      'addNote',
      params: {
        'note': {
          'deckName': draft.deckName,
          'modelName': draft.modelName,
          'fields': draft.fields,
          'tags': draft.tags,
          'options': _duplicateOptions(
            deckName: draft.deckName,
            allowDuplicate: allowDuplicate,
            duplicateScope: duplicateScope,
            checkAllModels: checkAllModels,
          ),
        },
      },
    );
    if (result is! int) {
      throw const AnkiConnectException('AnkiConnect did not return a note id.');
    }
    return result;
  }

  Future<void> sync() async {
    await invoke('sync');
  }

  Future<List<int>> findDuplicateExpressions({
    required String deckName,
    required String expression,
  }) {
    final escapedDeck = deckName.replaceAll('"', r'\"');
    final escapedExpression = expression.replaceAll('"', r'\"');
    return findNotes('deck:"$escapedDeck" "$escapedExpression"');
  }

  /// Uses Anki's own duplicate validator, matching Hoshi Reader and Yomitan.
  /// This is more accurate than a text search because Anki evaluates the
  /// actual model's first field and configured duplicate scope.
  Future<AnkiCanAddResult> canAddDraft(
    AnkiCardDraft draft, {
    String duplicateScope = 'deck',
    List<String> duplicateDeckNames = const [],
    bool checkAllModels = false,
  }) async {
    final normalized = await _normalizeFieldsForModel(draft);
    return _canAddNormalizedDraftForScope(
      normalized,
      duplicateScope: duplicateScope,
      duplicateDeckNames: duplicateDeckNames,
      checkAllModels: checkAllModels,
    );
  }

  Future<AnkiCanAddResult> checkDuplicateExpression({
    required String deckName,
    required String modelName,
    required String expression,
    String duplicateScope = 'deck',
    List<String> duplicateDeckNames = const [],
    bool checkAllModels = false,
  }) async {
    final fields = await modelFieldNames(modelName);
    if (fields.isEmpty) return const AnkiCanAddResult(canAdd: true);
    return _canAddNormalizedDraftForScope(
      AnkiCardDraft(
        deckName: deckName,
        modelName: modelName,
        expression: expression,
        fields: {
          for (final field in fields)
            field: field == fields.first ? expression : '',
        },
      ),
      duplicateScope: duplicateScope,
      duplicateDeckNames: duplicateDeckNames,
      checkAllModels: checkAllModels,
    );
  }

  Future<int> exportDraft(
    AnkiCardDraft draft, {
    bool duplicateCheck = true,
    bool allowDuplicate = false,
    String duplicateScope = 'deck',
    List<String> duplicateDeckNames = const [],
    bool checkAllModels = false,
    bool syncOnCreate = false,
  }) async {
    final normalized = await _normalizeFieldsForModel(draft);
    if (duplicateCheck) {
      final status = await _canAddNormalizedDraftForScope(
        normalized,
        duplicateScope: duplicateScope,
        duplicateDeckNames: duplicateDeckNames,
        checkAllModels: checkAllModels,
      );
      _handleCanAddResult(
        status,
        expression: normalized.expression,
        allowDuplicate: allowDuplicate,
      );
    }
    for (final media in normalized.mediaFiles) {
      await storeMediaSource(filename: media.filename, source: media.source);
    }
    if (normalized.screenshotFileName case final filename?) {
      var source = normalized.screenshotSource;
      final screenshotBytes = normalized.screenshotBytes;
      if (source == null && screenshotBytes != null) {
        source = AnkiMediaSource.bytes(screenshotBytes);
      }
      if (source != null) {
        await storeMediaSource(filename: filename, source: source);
      }
    }
    final noteId = await addNote(
      normalized,
      allowDuplicate: allowDuplicate || !duplicateCheck,
      duplicateScope: duplicateScope,
      checkAllModels: checkAllModels,
    );
    if (syncOnCreate) await sync();
    return noteId;
  }

  Future<AnkiExportResult> exportPending(
    PendingAnkiCard pending, {
    bool duplicateCheck = true,
    bool allowDuplicate = false,
    String duplicateScope = 'deck',
    List<String> duplicateDeckNames = const [],
    bool checkAllModels = false,
    bool syncOnCreate = false,
  }) async {
    final placeholder = await _normalizeFieldsForModel(
      pending.placeholderDraft,
    );
    if (duplicateCheck) {
      final status = await _canAddNormalizedDraftForScope(
        placeholder,
        duplicateScope: duplicateScope,
        duplicateDeckNames: duplicateDeckNames,
        checkAllModels: checkAllModels,
      );
      _handleCanAddResult(
        status,
        expression: placeholder.expression,
        allowDuplicate: allowDuplicate,
      );
    }

    AnkiExportJobSession? session;
    PreparedAnkiCard? prepared;
    final warnings = <String>[];
    try {
      session = pending.jobController?.beginPreparing();
      prepared = await pending.prepare(session);
      session?.throwIfCancelled();
      var normalized = await _normalizeFieldsForModel(prepared.draft);
      session?.throwIfCancelled();
      session?.beginCommitting();

      final screenshot = prepared.screenshot;
      if (screenshot != null) {
        var storedFilename = screenshot.filename;
        try {
          await storeMediaSource(
            filename: screenshot.filename,
            source: screenshot.source,
          );
        } catch (_) {
          if (screenshot.animated) {
            try {
              await storeMediaSource(
                filename: screenshot.fallbackFilename,
                source: screenshot.fallbackSource,
              );
              storedFilename = screenshot.fallbackFilename;
              warnings.add(
                'Animated scene storage failed; the frozen still was used.',
              );
            } catch (_) {
              storedFilename = '';
              warnings.add(
                'Screenshot storage failed; the note was added without an image.',
              );
            }
          } else {
            storedFilename = '';
            warnings.add(
              'Screenshot storage failed; the note was added without an image.',
            );
          }
          normalized = _replaceScreenshotReference(
            normalized,
            from: screenshot.filename,
            to: storedFilename,
          );
        }
      }

      // The screenshot is committed first so animation/storage failures can
      // still degrade to the frozen frame before any note mutation.
      for (final media in normalized.mediaFiles) {
        await storeMediaSource(filename: media.filename, source: media.source);
      }
      final noteId = await addNote(
        normalized,
        allowDuplicate: allowDuplicate || !duplicateCheck,
        duplicateScope: duplicateScope,
        checkAllModels: checkAllModels,
      );
      if (syncOnCreate) {
        // The note exists now. Failing the export over a sync error, such as
        // not being logged in to AnkiWeb, would invite a duplicate on retry.
        try {
          await sync();
        } on AnkiConnectException catch (error) {
          warnings.add('Added, but syncing to AnkiWeb failed: $error');
        }
      }
      warnings
        ..insertAll(0, prepared.warnings)
        ..removeWhere((warning) => warning.trim().isEmpty);
      return AnkiExportResult(noteId: noteId, warnings: warnings);
    } finally {
      await prepared?.dispose();
      session?.finish();
    }
  }

  static AnkiCardDraft _replaceScreenshotReference(
    AnkiCardDraft draft, {
    required String from,
    required String to,
  }) {
    final expected = '<img src="$from">';
    final replacement = to.isEmpty ? '' : '<img src="$to">';
    return AnkiCardDraft(
      deckName: draft.deckName,
      modelName: draft.modelName,
      expression: draft.expression,
      fields: draft.fields.map(
        (field, value) =>
            MapEntry(field, value.replaceAll(expected, replacement)),
      ),
      tags: draft.tags,
      screenshotFileName: to.isEmpty ? null : to,
      screenshotBytes: draft.screenshotBytes,
      screenshotSource: draft.screenshotSource,
      mediaFiles: draft.mediaFiles,
    );
  }

  static void _handleCanAddResult(
    AnkiCanAddResult status, {
    required String expression,
    required bool allowDuplicate,
  }) {
    if (status.canAdd) return;
    if (status.isDuplicate) {
      if (!allowDuplicate) {
        throw AnkiDuplicateException(expression, status.error);
      }
      return;
    }
    final detail = status.error?.trim();
    throw AnkiConnectException(
      detail == null || detail.isEmpty
          ? 'Anki rejected the note during validation.'
          : detail,
    );
  }

  Future<AnkiCanAddResult> _canAddNormalizedDraftForScope(
    AnkiCardDraft draft, {
    required String duplicateScope,
    required List<String> duplicateDeckNames,
    required bool checkAllModels,
  }) {
    if (duplicateScope == 'decks') {
      return _canAddNormalizedDraftAcrossDecks(
        draft,
        duplicateDeckNames: duplicateDeckNames,
        checkAllModels: checkAllModels,
      );
    }
    return _canAddNormalizedDraft(
      draft,
      duplicateScope: duplicateScope,
      checkAllModels: checkAllModels,
    );
  }

  Future<AnkiCanAddResult> _canAddNormalizedDraftAcrossDecks(
    AnkiCardDraft draft, {
    required List<String> duplicateDeckNames,
    required bool checkAllModels,
  }) async {
    final decks = _effectiveDuplicateDecks(draft.deckName, duplicateDeckNames);
    final result = await invoke(
      'canAddNotesWithErrorDetail',
      params: {
        'notes': [
          for (final deck in decks)
            {
              'deckName': deck,
              'modelName': draft.modelName,
              'fields': draft.fields,
              'tags': draft.tags,
              'options': _duplicateOptions(
                deckName: deck,
                allowDuplicate: false,
                duplicateScope: 'deck',
                checkAllModels: checkAllModels,
              ),
            },
        ],
      },
    );
    if (result is! List || result.length != decks.length) {
      throw const AnkiConnectException(
        'AnkiConnect returned an invalid multi-deck duplicate response.',
      );
    }
    for (final indexed in result.indexed) {
      final entry = indexed.$2;
      if (entry is! Map) {
        throw const AnkiConnectException(
          'AnkiConnect returned an invalid multi-deck duplicate response.',
        );
      }
      if (entry['canAdd'] != true) {
        final detail = entry['error']?.toString();
        return AnkiCanAddResult(
          canAdd: false,
          error: detail == null || detail.isEmpty
              ? 'Duplicate found in ${decks[indexed.$1]}'
              : '${decks[indexed.$1]}: $detail',
        );
      }
    }
    return const AnkiCanAddResult(canAdd: true);
  }

  Future<AnkiCanAddResult> _canAddNormalizedDraft(
    AnkiCardDraft draft, {
    required String duplicateScope,
    required bool checkAllModels,
  }) async {
    final result = await invoke(
      'canAddNotesWithErrorDetail',
      params: {
        'notes': [
          {
            'deckName': draft.deckName,
            'modelName': draft.modelName,
            'fields': draft.fields,
            'tags': draft.tags,
            'options': _duplicateOptions(
              deckName: draft.deckName,
              allowDuplicate: false,
              duplicateScope: duplicateScope,
              checkAllModels: checkAllModels,
            ),
          },
        ],
      },
    );
    if (result is! List || result.isEmpty || result.first is! Map) {
      throw const AnkiConnectException(
        'AnkiConnect returned an invalid duplicate-check response.',
      );
    }
    final first = result.first as Map;
    return AnkiCanAddResult(
      canAdd: first['canAdd'] == true,
      error: first['error']?.toString(),
    );
  }

  static Map<String, dynamic> _duplicateOptions({
    required String deckName,
    required bool allowDuplicate,
    required String duplicateScope,
    required bool checkAllModels,
  }) {
    final normalizedScope = switch (duplicateScope) {
      'collection' => 'collection',
      'deckroot' => 'deckroot',
      _ => 'deck',
    };
    final options = <String, dynamic>{
      'allowDuplicate': allowDuplicate,
      'duplicateScope': normalizedScope == 'collection' ? 'collection' : 'deck',
    };
    if (normalizedScope != 'collection' || checkAllModels) {
      options['duplicateScopeOptions'] = <String, dynamic>{
        if (normalizedScope != 'collection')
          'deckName': normalizedScope == 'deckroot'
              ? deckName.split('::').first
              : deckName,
        if (normalizedScope != 'collection')
          'checkChildren': normalizedScope == 'deckroot',
        'checkAllModels': checkAllModels,
      };
    }
    return options;
  }

  static List<String> _effectiveDuplicateDecks(
    String destinationDeck,
    List<String> selectedDecks,
  ) {
    final decks = <String>[];
    for (final deck in [destinationDeck, ...selectedDecks]) {
      final normalized = deck.trim();
      if (normalized.isNotEmpty && !decks.contains(normalized)) {
        decks.add(normalized);
      }
    }
    return decks;
  }

  static String _escapeSearch(String value) => value.replaceAll('"', '');

  Future<AnkiCardDraft> _normalizeFieldsForModel(AnkiCardDraft draft) async {
    final modelFields = await modelFieldNames(draft.modelName);
    if (modelFields.isEmpty) return draft;
    return AnkiCardDraft(
      deckName: draft.deckName,
      modelName: draft.modelName,
      expression: draft.expression,
      fields: {
        for (final field in modelFields) field: draft.fields[field] ?? '',
      },
      tags: draft.tags,
      screenshotFileName: draft.screenshotFileName,
      screenshotBytes: draft.screenshotBytes,
      screenshotSource: draft.screenshotSource,
      mediaFiles: draft.mediaFiles,
    );
  }
}
