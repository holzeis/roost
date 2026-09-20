import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:roost/features/chat/reaction_frequency.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('starts at the fixed defaults with no usage data', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final emojis = await container.read(quickReactionsProvider.future);
    expect(emojis, defaultQuickReactions);
  });

  test('a picked emoji outranks the defaults once used enough', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(quickReactionsProvider.future);
    final controller = container.read(quickReactionsProvider.notifier);

    // 🥳 isn't one of the fixed defaults; reacting with it enough times
    // should still land it in the ranked list, ahead of a never-used default.
    for (var i = 0; i < 5; i++) {
      await controller.recordUse('🥳');
    }

    final ranked = container.read(quickReactionsProvider).valueOrNull;
    expect(ranked, isNotNull);
    expect(ranked!.first, '🥳');
    expect(ranked.length, 6);
  });

  test('persists across a fresh container (survives an app relaunch)', () async {
    final first = ProviderContainer();
    await first.read(quickReactionsProvider.future);
    await first.read(quickReactionsProvider.notifier).recordUse('🥳');
    await first.read(quickReactionsProvider.notifier).recordUse('🥳');
    first.dispose();

    final second = ProviderContainer();
    addTearDown(second.dispose);
    final ranked = await second.read(quickReactionsProvider.future);

    expect(ranked.contains('🥳'), isTrue);
  });
}
