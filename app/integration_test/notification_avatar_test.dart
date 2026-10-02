import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:roost/services/message_notifications.dart';

/// A message notification shows the sender's profile picture, fetched from
/// the chat server by the id the push carries — here against a real HTTP
/// server on the device, the way the background isolate fetches it. Run
/// with:
///
///   flutter test integration_test/notification_avatar_test.dart -d <device-id>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const avatarId = '0b7d3c1e-5f2a-4c4e-9d1b-2a3f4e5d6c7b';
  late HttpServer server;
  late String baseUrl;
  final requested = <String>[];

  setUp(() async {
    requested.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://${server.address.host}:${server.port}';
    server.listen((request) {
      requested.add(request.uri.toString());
      if (request.uri.path == '/api/media/$avatarId') {
        request.response.add([0x89, 0x50, 0x4e, 0x47]);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      request.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  testWidgets('fetches the sender\'s picture as the small preview', (tester) async {
    expect(await fetchSenderAvatar(avatarId, baseUrl: baseUrl), [0x89, 0x50, 0x4e, 0x47]);
    expect(requested, ['/api/media/$avatarId?variant=preview']);
  });

  testWidgets('shows the notification without a picture the server doesn\'t have', (tester) async {
    expect(await fetchSenderAvatar('ffffffff-5f2a-4c4e-9d1b-2a3f4e5d6c7b', baseUrl: baseUrl), isNull);
  });

  testWidgets('gives up on an unreachable server', (tester) async {
    await server.close(force: true);
    expect(await fetchSenderAvatar(avatarId, baseUrl: baseUrl), isNull);
  });
}
