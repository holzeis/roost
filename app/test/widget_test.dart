import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:roost/main.dart';
import 'package:roost/router/app_router.dart';

void main() {
  // appRouter is a module-level singleton (as it must be in the real app),
  // so its location survives across tests unless reset here.
  setUp(() => appRouter.go('/'));

  testWidgets('Home screen lists rooms from the mockup data', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: RoostApp()));
    await tester.pumpAndSettle();

    expect(find.text('Roost'), findsOneWidget);
    expect(find.text('Family'), findsOneWidget);
    expect(find.text('Weekend trip'), findsOneWidget);
  });

  testWidgets('Tapping a room opens its chat screen', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: RoostApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    expect(find.text('Message'), findsOneWidget); // the composer's hint text
  });

  testWidgets('Profile screen exposes a theme picker with all three modes', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: RoostApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();
    expect(find.text('Profile'), findsWidgets);

    await tester.tap(find.text('Theme'));
    await tester.pumpAndSettle();

    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('System'), findsWidgets);
  });
}
