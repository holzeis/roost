import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A cache key of our own, not DefaultCacheManager's 'libCachedImageData' —
/// this is a genuinely separate Config (see _cacheManager below), not that
/// singleton, so it needs its own cache directory/database name to avoid
/// colliding with it.
const _cacheKey = 'roostImageCache';

/// DefaultCacheManager()'s own Config — and so every other Flutter app that
/// just uses cached_network_image out of the box — defaults to CacheObjectProvider
/// on Android/iOS/macOS, which stores cache metadata in sqflite. Flutter_cache_manager's
/// own doc comment on Config.repo calls this "due to legacy"; every lookup and
/// write goes through a SQLite platform-channel round trip, which measurably
/// slowed down image loading here once more than a couple of images needed
/// their cache entry checked at once (e.g. opening a chat with several
/// photos, or several avatars rendering together) — exactly the "took quite
/// a while, even for the preview" regression this fixes. JsonCacheInfoRepository
/// is the same package's own alternative: cache metadata lives in a plain
/// Dart Map in memory (loaded from one JSON file at startup, written back
/// asynchronously), so a lookup after that initial load is a pure in-memory
/// operation with no platform channel involved at all.
final _cacheManager = CacheManager(Config(_cacheKey, repo: JsonCacheInfoRepository(databaseName: _cacheKey)));

/// The cache manager every CachedNetworkImage/CachedNetworkImageProvider in
/// the app reads from, rather than each defaulting to the package's own
/// DefaultCacheManager() singleton directly. Overridden in tests with a
/// fake that implements BaseCacheManager directly (see test/fakes.dart's
/// FakeCacheManager) rather than the real CacheManager — the real class's
/// own internal StreamController/WebHelper machinery never reaches a state
/// WidgetTester.pumpAndSettle() considers settled, even with every one of
/// its dependencies faked out from underneath it.
final imageCacheManagerProvider = Provider<BaseCacheManager>((ref) => _cacheManager);
