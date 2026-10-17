import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/eval/model/source_preference.dart';
import 'package:mangayomi/models/category.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/download.dart';
import 'package:mangayomi/models/history.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/models/sync_preference.dart';
import 'package:mangayomi/models/track.dart';
import 'package:mangayomi/models/update.dart';
import 'package:mangayomi/modules/more/data_and_storage/providers/proto/BackupMihon.pb.dart';
import 'package:mangayomi/services/mining/mining_preferences.dart';

/// Revision of every local collection that can change an authoritative
/// Download-only plan or one of its settings projections.
final class ChimahonLocalRevision {
  const ChimahonLocalRevision(this.value, {this.sections = const {}});

  final String value;

  /// One digest per local area (`manga`, `source`, `settings`, ...), so a
  /// failed comparison can say which areas changed without revealing data.
  final Map<String, String> sections;

  /// The areas whose contents differ from [other], sorted by name.
  List<String> changedSections(ChimahonLocalRevision other) {
    final names = {...sections.keys, ...other.sections.keys}.toList()..sort();
    return [
      for (final name in names)
        if (sections[name] != other.sections[name]) name,
    ];
  }

  static Future<ChimahonLocalRevision> capture(
    Isar database,
    BackupMihon projection,
  ) async {
    final miningSnapshot = MiningPreferences.writableSnapshot();
    final digestReceiver = _DigestReceiver();
    final digestSink = _SectionedDigestSink(
      sha256.startChunkedConversion(digestReceiver),
    );

    // Stream framed values into SHA-256. The previous implementation built a
    // second, base64-expanded copy of the projection and one very large JSON
    // string on every validation pass. Download-only deliberately captures
    // this revision three times, so avoiding those transient copies matters.
    _addValue(digestSink, 'projection', projection.writeToBuffer());
    // Isar's native exporter preserves stable primary-key order and includes
    // every persisted property. Hash inside its callback because the buffer is
    // owned by Isar and is released as soon as the callback returns.
    database.mangas.where().exportJsonRawSync(
      (bytes) => _addValue(digestSink, 'manga', bytes),
    );
    database.chapters.where().exportJsonRawSync(
      (bytes) => _addValue(digestSink, 'chapter', bytes),
    );
    database.categorys.where().exportJsonRawSync(
      (bytes) => _addValue(digestSink, 'category', bytes),
    );
    database.downloads.where().exportJsonRawSync(
      (bytes) => _addValue(digestSink, 'download', bytes),
    );
    database.historys.where().exportJsonRawSync(
      (bytes) => _addValue(digestSink, 'history', bytes),
    );
    database.updates.where().exportJsonRawSync(
      (bytes) => _addValue(digestSink, 'update', bytes),
    );
    database.tracks.where().exportJsonRawSync(
      (bytes) => _addValue(digestSink, 'track', bytes),
    );
    database.sources.where().exportJsonRawSync(
      (bytes) => _addValue(digestSink, 'source', bytes),
    );
    database.sourcePreferences.where().exportJsonRawSync(
      (bytes) => _addValue(digestSink, 'sourcePreference', bytes),
    );
    database.settings.where().exportJsonRawSync(
      (bytes) => _addValue(digestSink, 'settings', bytes),
    );
    database.syncPreferences.where().exportJsonRawSync(
      (bytes) => _addValue(digestSink, 'syncPreference', bytes),
    );
    _addValue(
      digestSink,
      'mining',
      _jsonEncoder.convert((await miningSnapshot).revisionEntries),
    );
    digestSink.close();
    return ChimahonLocalRevision(
      digestReceiver.value.toString(),
      sections: digestSink.sectionDigests(),
    );
  }

  static final _jsonEncoder = JsonUtf8Encoder();

  static void _addValue(
    _SectionedDigestSink digestSink,
    String name,
    List<int> value,
  ) {
    final nameBytes = utf8.encode(name);
    digestSink.overall
      ..add(_lengthBytes(nameBytes.length))
      ..add(nameBytes)
      ..add(_lengthBytes(value.length))
      ..add(value);
    digestSink.section(name).add(value);
  }

  static Uint8List _lengthBytes(int length) =>
      Uint8List(8)..buffer.asByteData().setUint64(0, length);
}

/// Feeds the overall revision digest and one digest per named section.
final class _SectionedDigestSink {
  _SectionedDigestSink(this.overall);

  final ByteConversionSink overall;
  final Map<String, (_DigestReceiver, ByteConversionSink)> _sections = {};

  ByteConversionSink section(String name) => _sections.putIfAbsent(name, () {
    final receiver = _DigestReceiver();
    return (receiver, sha256.startChunkedConversion(receiver));
  }).$2;

  void close() {
    overall.close();
    for (final (_, sink) in _sections.values) {
      sink.close();
    }
  }

  Map<String, String> sectionDigests() => {
    for (final MapEntry(:key, :value) in _sections.entries)
      key: value.$1.value.toString(),
  };
}

final class _DigestReceiver implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
