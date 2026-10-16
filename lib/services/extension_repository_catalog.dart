import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

typedef ExtensionRepositoryLoader = Future<Uint8List> Function(Uri uri);

class ExtensionRepositoryCatalog {
  const ExtensionRepositoryCatalog({
    required this.indexUri,
    required this.entries,
    this.name,
    this.website,
    this.badgeLabel,
    this.signingKey,
  });

  final Uri indexUri;
  final List<Map<String, dynamic>> entries;
  final String? name;
  final String? website;
  final String? badgeLabel;
  final String? signingKey;
}

/// Loads legacy JSON repositories and Mihon's v2 JSON/protobuf repositories.
///
/// Modern repositories may advertise their v2 index through `repo.json`, and
/// may keep the extension list in a second document. Redirects are deliberately
/// bounded so a malformed repository cannot loop forever.
Future<ExtensionRepositoryCatalog> loadExtensionRepositoryCatalog(
  Uri initialUri,
  ExtensionRepositoryLoader load, {
  int maxHops = 4,
}) async {
  var uri = initialUri;
  _DecodedCatalog? store;

  for (var hop = 0; hop < maxHops; hop++) {
    final decoded = _decodeExtensionRepositoryCatalog(await load(uri), uri);
    if (decoded.redirectUri != null) {
      uri = uri.resolveUri(decoded.redirectUri!);
      continue;
    }
    if (decoded.extensionListUri != null) {
      store = decoded;
      uri = uri.resolveUri(decoded.extensionListUri!);
      final extensionList = _decodeExtensionRepositoryCatalog(
        await load(uri),
        uri,
        extensionListOnly: true,
      );
      return store.toPublic(indexUri: uri, entries: extensionList.entries);
    }
    return decoded.toPublic(indexUri: uri);
  }

  throw const FormatException(
    'Extension repository redirected too many times.',
  );
}

_DecodedCatalog _decodeExtensionRepositoryCatalog(
  List<int> responseBytes,
  Uri indexUri, {
  bool extensionListOnly = false,
}) {
  var bytes = Uint8List.fromList(responseBytes);
  if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
    bytes = Uint8List.fromList(gzip.decode(bytes));
  }
  if (bytes.isEmpty) {
    throw const FormatException('Extension repository is empty.');
  }

  final first = bytes.firstWhere(
    (byte) => byte != 0x09 && byte != 0x0a && byte != 0x0d && byte != 0x20,
    orElse: () => -1,
  );
  if (first == 0x5b) {
    final value = jsonDecode(utf8.decode(bytes));
    return _DecodedCatalog(entries: _jsonEntryList(value));
  }
  if (first == 0x7b) {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map) {
      throw const FormatException('Invalid extension repository object.');
    }
    final json = Map<String, dynamic>.from(value);
    final redirect = json['index_v2']?.toString().trim();
    if (redirect != null && redirect.isNotEmpty) {
      return _DecodedCatalog(
        entries: const [],
        redirectUri: Uri.parse(redirect),
        name: _nestedString(json, 'meta', 'name'),
        website: _nestedString(json, 'meta', 'website'),
      );
    }
    if (extensionListOnly || _looksLikeExtensionList(json)) {
      return _DecodedCatalog(entries: _modernJsonEntries(json, indexUri));
    }
    return _decodeModernJsonStore(json, indexUri);
  }

  final message = _ProtoReader(bytes);
  if (extensionListOnly) {
    return _DecodedCatalog(
      entries: _decodeProtoExtensionList(message, indexUri),
    );
  }
  return _decodeProtoStore(message, indexUri);
}

_DecodedCatalog _decodeModernJsonStore(
  Map<String, dynamic> json,
  Uri indexUri,
) {
  final extensionListUrl = json['extensionListUrl']?.toString().trim();
  final contact = json['contact'];
  return _DecodedCatalog(
    entries: _modernJsonEntries(json, indexUri),
    name: json['name']?.toString(),
    badgeLabel: json['badgeLabel']?.toString(),
    signingKey: json['signingKey']?.toString(),
    website: contact is Map ? contact['website']?.toString() : null,
    extensionListUri: extensionListUrl == null || extensionListUrl.isEmpty
        ? null
        : Uri.parse(extensionListUrl),
  );
}

bool _looksLikeExtensionList(Map<String, dynamic> json) =>
    json.containsKey('extensions') && !json.containsKey('extensionList');

List<Map<String, dynamic>> _modernJsonEntries(
  Map<String, dynamic> json,
  Uri indexUri,
) {
  final extensionList = json['extensionList'];
  final list = extensionList is Map
      ? extensionList['extensions']
      : json['extensions'];
  if (list == null) return const [];
  if (list is! List) {
    throw const FormatException('Invalid Mihon extension list.');
  }
  return list
      .whereType<Map>()
      .map(
        (entry) => _normalizeModernExtension(
          Map<String, dynamic>.from(entry),
          indexUri,
        ),
      )
      .toList();
}

Map<String, dynamic> _normalizeModernExtension(
  Map<String, dynamic> extension,
  Uri indexUri,
) {
  final resources = extension['resources'] is Map
      ? Map<String, dynamic>.from(extension['resources'] as Map)
      : const <String, dynamic>{};
  final rawSources = extension['sources'];
  final sources = (rawSources is List ? rawSources : const [])
      .whereType<Map>()
      // A source without an ID cannot be bound to a native Mihon source.
      .where((source) => source['id'] != null)
      .map(
        (source) => {
          'id': source['id'].toString(),
          'name': source['name']?.toString() ?? '',
          'lang': source['language']?.toString() ?? 'all',
          'baseUrl': source['homeUrl']?.toString() ?? '',
        },
      )
      .toList();
  return _legacyShapedEntry(
    indexUri: indexUri,
    name: extension['name']?.toString() ?? '',
    packageName: extension['packageName']?.toString() ?? '',
    versionCode: extension['versionCode'] ?? 0,
    versionName: extension['versionName']?.toString() ?? '',
    contentWarning: _contentWarningValue(extension['contentWarning']),
    apkUrl: resources['apkUrl']?.toString() ?? '',
    iconUrl: resources['iconUrl']?.toString() ?? '',
    sources: sources,
  );
}

int _contentWarningValue(Object? value) {
  if (value is num) return value.toInt();
  return switch (value?.toString().toUpperCase()) {
    'CONTENT_WARNING_SAFE' || 'SAFE' => 1,
    'CONTENT_WARNING_MIXED' || 'MIXED' => 2,
    'CONTENT_WARNING_NSFW' || 'NSFW' => 3,
    _ => 0,
  };
}

_DecodedCatalog _decodeProtoStore(_ProtoReader reader, Uri indexUri) {
  String? name;
  String? badgeLabel;
  String? signingKey;
  String? website;
  Uri? extensionListUri;
  var entries = <Map<String, dynamic>>[];

  while (!reader.isDone) {
    final field = reader.readField();
    switch (field.number) {
      case 1:
        name = reader.readString(field);
      case 2:
        badgeLabel = reader.readString(field);
      case 3:
        signingKey = reader.readString(field);
      case 4:
        final contact = reader.readMessage(field);
        while (!contact.isDone) {
          final contactField = contact.readField();
          if (contactField.number == 1) {
            website = contact.readString(contactField);
          } else {
            contact.skip(contactField);
          }
        }
      case 101:
        entries = _decodeProtoExtensionList(
          reader.readMessage(field),
          indexUri,
        );
      case 102:
        final value = reader.readString(field).trim();
        extensionListUri = value.isEmpty ? null : Uri.parse(value);
      default:
        reader.skip(field);
    }
  }

  return _DecodedCatalog(
    entries: entries,
    name: name,
    badgeLabel: badgeLabel,
    signingKey: signingKey,
    website: website,
    extensionListUri: extensionListUri,
  );
}

List<Map<String, dynamic>> _decodeProtoExtensionList(
  _ProtoReader reader,
  Uri indexUri,
) {
  final entries = <Map<String, dynamic>>[];
  while (!reader.isDone) {
    final field = reader.readField();
    if (field.number == 1) {
      entries.add(_decodeProtoExtension(reader.readMessage(field), indexUri));
    } else {
      reader.skip(field);
    }
  }
  return entries;
}

Map<String, dynamic> _decodeProtoExtension(_ProtoReader reader, Uri indexUri) {
  var name = '';
  var packageName = '';
  var apkUrl = '';
  var iconUrl = '';
  var versionCode = 0;
  var versionName = '';
  var contentWarning = 0;
  final sources = <Map<String, dynamic>>[];

  while (!reader.isDone) {
    final field = reader.readField();
    switch (field.number) {
      case 1:
        name = reader.readString(field);
      case 2:
        packageName = reader.readString(field);
      case 3:
        final resources = reader.readMessage(field);
        while (!resources.isDone) {
          final resourceField = resources.readField();
          if (resourceField.number == 1) {
            apkUrl = resources.readString(resourceField);
          } else if (resourceField.number == 2) {
            iconUrl = resources.readString(resourceField);
          } else {
            resources.skip(resourceField);
          }
        }
      case 5:
        versionCode = reader.readVarintField(field);
      case 6:
        versionName = reader.readString(field);
      case 7:
        contentWarning = reader.readVarintField(field);
      case 8:
        sources.add(_decodeProtoSource(reader.readMessage(field)));
      default:
        reader.skip(field);
    }
  }

  return _legacyShapedEntry(
    indexUri: indexUri,
    name: name,
    packageName: packageName,
    versionCode: versionCode,
    versionName: versionName,
    contentWarning: contentWarning,
    apkUrl: apkUrl,
    iconUrl: iconUrl,
    sources: sources,
  );
}

Map<String, dynamic> _decodeProtoSource(_ProtoReader reader) {
  var id = 0;
  var name = '';
  var language = 'all';
  var homeUrl = '';
  while (!reader.isDone) {
    final field = reader.readField();
    switch (field.number) {
      case 1:
        id = reader.readSignedInt64Field(field);
      case 2:
        name = reader.readString(field);
      case 3:
        language = reader.readString(field);
      case 4:
        homeUrl = reader.readString(field);
      default:
        reader.skip(field);
    }
  }
  return {
    'id': id.toString(),
    'name': name,
    'lang': language,
    'baseUrl': homeUrl,
  };
}

Map<String, dynamic> _legacyShapedEntry({
  required Uri indexUri,
  required String name,
  required String packageName,
  required Object versionCode,
  required String versionName,
  required int contentWarning,
  required String apkUrl,
  required String iconUrl,
  required List<Map<String, dynamic>> sources,
}) {
  final languages = sources.map((source) => source['lang']).toSet();
  return {
    'name': name,
    'pkg': packageName,
    'version': versionName,
    'code': versionCode,
    'lang': languages.length == 1 ? languages.first : 'all',
    'nsfw': contentWarning >= 2 ? 1 : 0,
    'sources': sources,
    'apk': apkUrl,
    '_apkUrl': indexUri.resolve(apkUrl).toString(),
    '_iconUrl': indexUri.resolve(iconUrl).toString(),
  };
}

List<Map<String, dynamic>> _jsonEntryList(Object? value) {
  if (value is! List) {
    throw const FormatException('Invalid legacy extension repository.');
  }
  return value.whereType<Map>().map(Map<String, dynamic>.from).toList();
}

String? _nestedString(Map<String, dynamic> json, String parent, String key) {
  final value = json[parent];
  return value is Map ? value[key]?.toString() : null;
}

class _DecodedCatalog {
  const _DecodedCatalog({
    required this.entries,
    this.name,
    this.website,
    this.badgeLabel,
    this.signingKey,
    this.redirectUri,
    this.extensionListUri,
  });

  final List<Map<String, dynamic>> entries;
  final String? name;
  final String? website;
  final String? badgeLabel;
  final String? signingKey;
  final Uri? redirectUri;
  final Uri? extensionListUri;

  ExtensionRepositoryCatalog toPublic({
    required Uri indexUri,
    List<Map<String, dynamic>>? entries,
  }) => ExtensionRepositoryCatalog(
    indexUri: indexUri,
    entries: entries ?? this.entries,
    name: name,
    website: website,
    badgeLabel: badgeLabel,
    signingKey: signingKey,
  );
}

class _ProtoField {
  const _ProtoField(this.number, this.wireType);

  final int number;
  final int wireType;
}

class _ProtoReader {
  _ProtoReader(List<int> bytes) : _bytes = Uint8List.fromList(bytes);

  final Uint8List _bytes;
  int _offset = 0;

  bool get isDone => _offset >= _bytes.length;

  _ProtoField readField() {
    final tag = _readVarint();
    if (tag == 0) throw const FormatException('Invalid protobuf field tag.');
    return _ProtoField(tag >> 3, tag & 7);
  }

  String readString(_ProtoField field) => utf8.decode(_readBytes(field));

  _ProtoReader readMessage(_ProtoField field) =>
      _ProtoReader(_readBytes(field));

  int readVarintField(_ProtoField field) {
    _expectWireType(field, 0);
    return _readVarint();
  }

  int readSignedInt64Field(_ProtoField field) {
    final value = readVarintField(field);
    return value >= (1 << 63) ? value - (1 << 64) : value;
  }

  Uint8List _readBytes(_ProtoField field) {
    _expectWireType(field, 2);
    final length = _readVarint();
    if (length < 0 || _offset + length > _bytes.length) {
      throw const FormatException('Truncated protobuf field.');
    }
    final value = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return value;
  }

  void skip(_ProtoField field) {
    switch (field.wireType) {
      case 0:
        _readVarint();
      case 1:
        _advance(8);
      case 2:
        _advance(_readVarint());
      case 5:
        _advance(4);
      default:
        throw FormatException(
          'Unsupported protobuf wire type ${field.wireType}.',
        );
    }
  }

  int _readVarint() {
    var value = 0;
    var shift = 0;
    while (_offset < _bytes.length && shift < 70) {
      final byte = _bytes[_offset++];
      value |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) return value;
      shift += 7;
    }
    throw const FormatException('Invalid protobuf varint.');
  }

  void _advance(int count) {
    if (count < 0 || _offset + count > _bytes.length) {
      throw const FormatException('Truncated protobuf field.');
    }
    _offset += count;
  }

  void _expectWireType(_ProtoField field, int expected) {
    if (field.wireType != expected) {
      throw FormatException(
        'Invalid wire type ${field.wireType} for field ${field.number}.',
      );
    }
  }
}
