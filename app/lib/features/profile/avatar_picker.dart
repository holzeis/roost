import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';

import '../../services/image_shrinker.dart';

/// Picks a photo from [source] and shrinks it for use as a profile or group
/// picture: it's only ever shown small, so 1024 px is plenty. Null when the
/// user backs out of the picker.
Future<ShrunkImage?> pickShrunkAvatar(WidgetRef ref, ImageSource source) async {
  final file = await ImagePicker().pickImage(source: source);
  if (file == null) return null;
  return ref.read(imageShrinkerProvider).shrink(
        await file.readAsBytes(),
        contentType: file.mimeType ?? lookupMimeType(file.path) ?? 'image/jpeg',
        filename: file.name,
        maxLongSide: 1024,
      );
}
