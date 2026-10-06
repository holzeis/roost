import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/fakes.dart';

/// On iOS, chats sent to are donated to the share sheet natively with
/// their picture (ios/Runner/ShareSuggestionDonor.swift). Checks the app's
/// channel takes a donation with and without a picture. Run with:
///
///   flutter test integration_test/share_suggestions_test.dart -d <ios-device-id>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('roost/share_suggestions');

  testWidgets('donates a chat with its picture, and one without', (tester) async {
    final picture = await FakeCacheManager().getSingleFile('avatar');
    await channel.invokeMethod<void>(
        'donate', {'conversationIdentifier': 'room-1', 'name': 'Mom', 'imagePath': picture.path});
    await channel.invokeMethod<void>(
        'donate', {'conversationIdentifier': 'room-2', 'name': 'Family', 'imagePath': null});
  });
}
