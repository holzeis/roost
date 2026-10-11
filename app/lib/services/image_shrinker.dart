import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// An image ready to upload.
typedef ShrunkImage = ({Uint8List bytes, String contentType, String filename});

/// Shrinks photos before they're uploaded: a phone's camera produces 4–8 MB
/// at 12 MP or more, far more than a chat needs and slow to send over the
/// tailnet. The long side is capped at [ImageShrinker.maxLongSide] pixels
/// (sharp full screen on any phone) and re-encoded as JPEG, typically a few
/// hundred KB. Uses the platform's own image codecs (flutter_image_compress),
/// which also read HEIC and apply the photo's EXIF rotation.
class ImageShrinker {
  const ImageShrinker();

  static const maxLongSide = 2048;
  static const quality = 85;

  /// A photo that's already this small, at most [maxLongSide] and in a format
  /// every viewer reads, is sent as it is.
  static const keepAsIsBelowBytes = 1024 * 1024;

  /// [bytes] ready to upload: shrunk when it's a large photo, otherwise
  /// unchanged — also whenever shrinking fails, which never stops a send.
  /// GIFs stay as they are (shrinking would drop their animation).
  Future<ShrunkImage> shrink(
    Uint8List bytes, {
    required String contentType,
    required String filename,
    int maxLongSide = maxLongSide,
  }) async {
    final original = (bytes: bytes, contentType: contentType, filename: filename);
    if (!contentType.startsWith('image/') || contentType == 'image/gif') return original;

    final size = await _dimensions(bytes);
    final plainFormat = contentType == 'image/jpeg' || contentType == 'image/png';
    if (size != null &&
        size.longSide <= maxLongSide &&
        plainFormat &&
        bytes.length <= keepAsIsBelowBytes) {
      return original;
    }
    try {
      final shrunk = await FlutterImageCompress.compressWithList(
        bytes,
        // The plugin scales the short side down to this (never up), so this
        // caps the long side at maxLongSide. Without the dimensions, assume
        // a phone photo's 4:3.
        minWidth: shortSideFor(size, maxLongSide),
        minHeight: shortSideFor(size, maxLongSide),
        quality: quality,
        format: CompressFormat.jpeg,
      );
      if (shrunk.isEmpty) return original;
      return (bytes: shrunk, contentType: 'image/jpeg', filename: jpegName(filename));
    } catch (_) {
      return original;
    }
  }

  /// The short side to scale an image of [size] to so its long side ends up
  /// at [maxLongSide] (orientation doesn't matter: both bounds get this
  /// value). Never more than [maxLongSide] itself, e.g. for a square photo.
  static int shortSideFor(({int width, int height})? size, int maxLongSide) {
    if (size == null || size.width <= 0 || size.height <= 0) return (maxLongSide * 3 / 4).round();
    final short = size.width < size.height ? size.width : size.height;
    return (maxLongSide * short / size.longSide).round().clamp(1, maxLongSide);
  }

  /// [filename] with a .jpg extension, as the shrunk image is a JPEG.
  static String jpegName(String filename) {
    final dot = filename.lastIndexOf('.');
    return '${dot > 0 ? filename.substring(0, dot) : filename}.jpg';
  }

  /// The encoded image's pixel size, read from its header without decoding
  /// it; null if Flutter can't read the format.
  static Future<({int width, int height})?> _dimensions(Uint8List bytes) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = (width: descriptor.width, height: descriptor.height);
      descriptor.dispose();
      buffer.dispose();
      return size;
    } catch (_) {
      return null;
    }
  }
}

extension on ({int width, int height}) {
  int get longSide => width > height ? width : height;
}

final imageShrinkerProvider = Provider<ImageShrinker>((ref) => const ImageShrinker());
