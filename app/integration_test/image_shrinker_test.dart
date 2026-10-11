import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:roost/services/image_shrinker.dart';

/// Photos are shrunk with the platform's own codecs before upload; only a
/// real device or simulator has those. Run with:
///
///   flutter test integration_test/image_shrinker_test.dart -d <device-id>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// A [width]x[height] PNG of a gradient with fine noise, like a photo.
  Future<Uint8List> photo(int width, int height) async {
    final pixels = Uint8List(width * height * 4);
    var seed = 1;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        final noise = seed % 24;
        final o = (y * width + x) * 4;
        pixels[o] = (x * 255 ~/ width + noise) % 256;
        pixels[o + 1] = (y * 255 ~/ height + noise) % 256;
        pixels[o + 2] = (128 + noise * 3) % 256;
        pixels[o + 3] = 255;
      }
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    final descriptor = ui.ImageDescriptor.raw(buffer,
        width: width, height: height, pixelFormat: ui.PixelFormat.rgba8888);
    final frame = await (await descriptor.instantiateCodec()).getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    return png!.buffer.asUint8List();
  }

  /// [png] as a camera saves it: a full-size, maximum-quality JPEG.
  Future<Uint8List> cameraJpeg(Uint8List png) =>
      FlutterImageCompress.compressWithList(png, minWidth: 100000, minHeight: 100000, quality: 100);

  Future<(int, int)> sizeOf(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    return (descriptor.width, descriptor.height);
  }

  testWidgets('a camera-sized photo comes out at most 2048px, as a JPEG', (tester) async {
    for (final (w, h) in [(4032, 3024), (3024, 4032)]) {
      final original = await cameraJpeg(await photo(w, h));
      expect(await sizeOf(original), (w, h));
      final out = await const ImageShrinker().shrink(original, contentType: 'image/jpeg', filename: 'IMG.JPG');

      expect(out.contentType, 'image/jpeg');
      expect(out.filename, 'IMG.jpg');
      expect(await sizeOf(out.bytes), w > h ? (2048, 1536) : (1536, 2048));
      expect(out.bytes.length, lessThan(original.length / 3),
          reason: '${original.length} bytes shrunk to ${out.bytes.length}');
    }
  });

  testWidgets('a small photo is sent as it is', (tester) async {
    final original = await photo(800, 600);
    final out = await const ImageShrinker().shrink(original, contentType: 'image/png', filename: 'small.png');
    expect(out.bytes, same(original));
  });
}
