import 'dart:io';
import 'dart:typed_data';

import 'package:file/file.dart' as pkg_file;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'demo_backend.dart';

/// Serves the demo's images to every CachedNetworkImage in the app, in place
/// of the real cache manager (see imageCacheManagerProvider): URLs look like
/// `demo://media/<id>` (DemoApiClient.mediaUrl) and resolve to the bundled
/// asset or in-memory bytes [DemoBackend] holds, written once to a temp
/// file — no network involved.
class DemoCacheManager implements BaseCacheManager {
  DemoCacheManager(this._backend);

  final DemoBackend _backend;
  final Map<String, pkg_file.File> _files = {};
  Directory? _dir;

  static String? mediaIdFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'demo' || uri.host != 'media' || uri.pathSegments.isEmpty) return null;
    return uri.pathSegments.first;
  }

  Future<pkg_file.File> _resolve(String url) async {
    final mediaId = mediaIdFromUrl(url);
    if (mediaId == null) throw HttpExceptionWithStatus(404, 'not demo media: $url');
    final cached = _files[mediaId];
    if (cached != null) return cached;
    final Uint8List? bytes = await _backend.mediaBytes(mediaId);
    if (bytes == null) throw HttpExceptionWithStatus(404, 'demo media not found: $mediaId');
    final dir = _dir ??= await Directory.systemTemp.createTemp('roost-demo-media-');
    final file = const LocalFileSystem().file('${dir.path}/$mediaId');
    await file.writeAsBytes(bytes);
    return _files[mediaId] = file;
  }

  FileInfo _info(pkg_file.File file, String url) =>
      FileInfo(file, FileSource.Cache, DateTime.now().add(const Duration(days: 1)), url);

  @override
  Future<pkg_file.File> getSingleFile(String url, {String? key, Map<String, String>? headers}) => _resolve(url);

  @override
  @Deprecated('Prefer to use the new getFileStream method')
  Stream<FileInfo> getFile(String url, {String? key, Map<String, String>? headers}) =>
      getFileStream(url, key: key, headers: headers).where((r) => r is FileInfo).cast<FileInfo>();

  @override
  Stream<FileResponse> getFileStream(String url,
      {String? key, Map<String, String>? headers, bool withProgress = false}) async* {
    yield _info(await _resolve(url), url);
  }

  @override
  Future<FileInfo> downloadFile(String url, {String? key, Map<String, String>? authHeaders, bool force = false}) async =>
      _info(await _resolve(url), url);

  @override
  Future<FileInfo?> getFileFromCache(String key, {bool ignoreMemCache = false}) async {
    final file = _files[mediaIdFromUrl(key)];
    return file == null ? null : _info(file, key);
  }

  @override
  Future<FileInfo?> getFileFromMemory(String key) => getFileFromCache(key);

  @override
  Future<pkg_file.File> putFile(String url, Uint8List fileBytes,
          {String? key, String? eTag, Duration maxAge = const Duration(days: 30), String fileExtension = 'file'}) =>
      _resolve(url);

  @override
  Future<pkg_file.File> putFileStream(String url, Stream<List<int>> source,
          {String? key, String? eTag, Duration maxAge = const Duration(days: 30), String fileExtension = 'file'}) =>
      _resolve(url);

  @override
  Future<void> removeFile(String key) async {
    final file = _files.remove(mediaIdFromUrl(key));
    try {
      await file?.delete();
    } catch (_) {}
  }

  @override
  Future<void> emptyCache() async {
    for (final file in _files.values) {
      try {
        await file.delete();
      } catch (_) {}
    }
    _files.clear();
  }

  @override
  Future<void> dispose() => emptyCache();
}
