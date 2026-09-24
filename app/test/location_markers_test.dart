import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:roost/features/location/location_markers.dart';

const _pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('renderAvatarMarkerPng', () {
    test('renders a valid PNG for an initial-letter marker when there is no photo', () async {
      final bytes = await renderAvatarMarkerPng(initial: 'M', color: Colors.teal);
      expect(bytes, isNotEmpty);
      expect(bytes.sublist(0, 8), _pngMagic);
    });

    test('renders a valid PNG when cropping an existing photo into a circle', () async {
      // A minimal 1x1 PNG, standing in for a downloaded profile photo.
      final onePixelPng = Uint8List.fromList(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='));

      final bytes =
          await renderAvatarMarkerPng(initial: 'M', color: Colors.teal, avatarBytes: onePixelPng);

      expect(bytes, isNotEmpty);
      expect(bytes.sublist(0, 8), _pngMagic);
    });
  });
}
