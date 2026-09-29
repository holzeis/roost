import 'dart:io';

import 'package:video_player/video_player.dart';

/// A player for a media URL: streamed from the server normally, or read
/// straight from disk for a `file://` URL — which is how the in-app demo
/// (lib/demo/) serves videos recorded during the demo.
VideoPlayerController videoControllerForUrl(String url) {
  final uri = Uri.parse(url);
  return uri.scheme == 'file'
      ? VideoPlayerController.file(File(uri.toFilePath()))
      : VideoPlayerController.networkUrl(uri);
}
