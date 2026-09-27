import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The cache manager every CachedNetworkImage/CachedNetworkImageProvider in
/// the app reads from, rather than each defaulting to the package's own
/// DefaultCacheManager() singleton directly. Overridden in tests with a
/// fake that implements BaseCacheManager directly (see test/fakes.dart's
/// FakeCacheManager) rather than the real CacheManager — the real class's
/// own internal StreamController/WebHelper machinery never reaches a state
/// WidgetTester.pumpAndSettle() considers settled, even with every one of
/// its dependencies faked out from underneath it.
final imageCacheManagerProvider = Provider<BaseCacheManager>((ref) => DefaultCacheManager());
