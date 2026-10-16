import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/services/mining/animated_avif_validator.dart';

void main() {
  // Fixtures are encoded with libaom-av1, which not every ffmpeg build has.
  // The app probes for it the same way before choosing animated AVIF.
  group('animated AVIF validator', skip: _libaomUnavailableReason(), () {
    late Directory temporaryDirectory;
    late Uint8List validAvif;

    setUpAll(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'mangatan-avif-validator-',
      );
      final source = File('${temporaryDirectory.path}/source.mkv');
      final output = File('${temporaryDirectory.path}/scene.avif');
      final sourceResult = await Process.run('ffmpeg', [
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=320x240:rate=8',
        '-t',
        '1',
        '-pix_fmt',
        'yuv420p',
        source.path,
      ]);
      if (sourceResult.exitCode != 0) {
        fail('Could not generate AVIF test input: ${sourceResult.stderr}');
      }
      final result = await Process.run('ffmpeg', [
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-i',
        source.path,
        '-t',
        '1',
        '-map',
        '0:0',
        '-an',
        '-sn',
        '-dn',
        '-vf',
        r'fps=8,scale=w=min(640\,iw):h=-2:force_original_aspect_ratio=decrease:force_divisible_by=2',
        '-frames:v',
        '80',
        '-pix_fmt',
        'yuv420p',
        '-c:v',
        'libaom-av1',
        '-crf',
        '35',
        '-cpu-used',
        '8',
        '-loop',
        '0',
        '-f',
        'avif',
        output.path,
      ]);
      if (result.exitCode != 0) {
        fail('Could not generate animated AVIF: ${result.stderr}');
      }
      validAvif = await output.readAsBytes();
    });

    tearDownAll(() async {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    test('validates a small FFmpeg-generated animated AVIF', () {
      final result = const AnimatedAvifValidator().validateBytes(validAvif);

      expect(result.width, 320);
      expect(result.height, 240);
      expect(result.frameCount, 8);
      expect(result.duration, const Duration(seconds: 1));
      expect(result.sampleBytes, greaterThan(0));
    });

    test('rejects missing animation brand', () {
      final bytes = Uint8List.fromList(validAvif);
      var index = _findAscii(bytes, 'avis');
      expect(index, greaterThanOrEqualTo(0));
      while (index >= 0) {
        bytes.setRange(index, index + 4, 'nope'.codeUnits);
        index = _findAscii(bytes, 'avis');
      }

      expect(
        () => const AnimatedAvifValidator().validateBytes(bytes),
        throwsA(isA<AnimatedAvifValidationException>()),
      );
    });

    test('rejects inconsistent timing and sample sizes', () {
      final timing = Uint8List.fromList(validAvif);
      final stts = _findAscii(timing, 'stts');
      expect(stts, greaterThanOrEqualTo(0));
      ByteData.sublistView(timing).setUint32(stts + 16, 0);
      expect(
        () => const AnimatedAvifValidator().validateBytes(timing),
        throwsA(isA<AnimatedAvifValidationException>()),
      );

      final sizes = Uint8List.fromList(validAvif);
      final stsz = _findAscii(sizes, 'stsz');
      expect(stsz, greaterThanOrEqualTo(0));
      ByteData.sublistView(sizes).setUint32(stsz + 8, animatedAvifMaxBytes + 1);
      expect(
        () => const AnimatedAvifValidator().validateBytes(sizes),
        throwsA(isA<AnimatedAvifValidationException>()),
      );
    });

    test('rejects dimensions and frame counts outside structural limits', () {
      final dimensions = Uint8List.fromList(validAvif);
      final tkhd = _findAscii(dimensions, 'tkhd');
      expect(tkhd, greaterThanOrEqualTo(4));
      final tkhdSize = ByteData.sublistView(dimensions).getUint32(tkhd - 4);
      ByteData.sublistView(dimensions)
          .setUint32(tkhd - 4 + tkhdSize - 8, 641 << 16);
      expect(
        () => const AnimatedAvifValidator().validateBytes(dimensions),
        throwsA(isA<AnimatedAvifValidationException>()),
      );

      final frames = Uint8List.fromList(validAvif);
      final stsz = _findAscii(frames, 'stsz');
      expect(stsz, greaterThanOrEqualTo(0));
      ByteData.sublistView(frames).setUint32(stsz + 12, 81);
      expect(
        () => const AnimatedAvifValidator().validateBytes(frames),
        throwsA(isA<AnimatedAvifValidationException>()),
      );
    });
  });
}

String? _libaomUnavailableReason() {
  try {
    final result = Process.runSync('ffmpeg', ['-hide_banner', '-encoders']);
    if ('${result.stdout}'.contains('libaom-av1')) return null;
    return 'ffmpeg has no libaom-av1 encoder';
  } on ProcessException {
    return 'ffmpeg is not installed';
  }
}

int _findAscii(Uint8List bytes, String value) {
  final pattern = value.codeUnits;
  for (var offset = 0; offset + pattern.length <= bytes.length; offset++) {
    var matches = true;
    for (var index = 0; index < pattern.length; index++) {
      if (bytes[offset + index] != pattern[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return offset;
  }
  return -1;
}
