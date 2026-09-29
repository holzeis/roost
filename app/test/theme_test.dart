import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:roost/theme/app_theme.dart';

/// The app background is defined twice: RoostColors.*Surface0 (Flutter) and
/// ios/Runner/Assets.xcassets/LaunchBackground.colorset (the native root
/// view, visible at the iOS keyboard bar's rounded corners — see
/// chat_screen.dart). This keeps the two from drifting apart.
Color _launchBackground({required bool dark}) {
  final json = jsonDecode(File('ios/Runner/Assets.xcassets/LaunchBackground.colorset/Contents.json').readAsStringSync())
      as Map<String, dynamic>;
  final entry = (json['colors'] as List).cast<Map<String, dynamic>>().firstWhere((c) => dark
      ? (c['appearances'] as List?)?.any((a) => a['value'] == 'dark') ?? false
      : c['appearances'] == null);
  final components = (entry['color'] as Map<String, dynamic>)['components'] as Map<String, dynamic>;
  int channel(String name) => int.parse((components[name] as String).substring(2), radix: 16);
  return Color.fromARGB(255, channel('red'), channel('green'), channel('blue'));
}

void main() {
  testWidgets('the app background is the WhatsApp-style white / dark slate', (tester) async {
    expect(AppTheme.light().scaffoldBackgroundColor, const Color(0xFFFFFFFF));
    expect(AppTheme.dark().scaffoldBackgroundColor, const Color(0xFF111B21));
  });

  test('the native iOS LaunchBackground matches the app background in both themes', () {
    expect(_launchBackground(dark: false), RoostColors.lightSurface0);
    expect(_launchBackground(dark: true), RoostColors.darkSurface0);
  });
}
