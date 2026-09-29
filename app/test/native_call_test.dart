import 'package:flutter/material.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import 'package:roost/data/api_models.dart';
import 'package:roost/data/ws_client.dart';
import 'package:roost/features/call/call_controls.dart';
import 'package:roost/features/call/incoming_call_screen.dart';
import 'package:roost/providers/chat_providers.dart';
import 'package:roost/services/native_call.dart';

import 'fakes.dart';

/// Stands in for CallKit: tracks which native calls are showing and which
/// ones the app ended.
class FakeNativeCallKit implements NativeCallKit {
  final List<CallKitParams> active = [];
  final List<String> ended = [];

  @override
  Future<List<CallKitParams>> activeCalls() async => List.of(active);

  @override
  Future<void> endCall(String id) async {
    ended.add(id);
    active.removeWhere((c) => sameCallId(c.id, id));
  }
}

class _EndedCallApiClient extends FakeApiClient {
  _EndedCallApiClient(super.ws);

  @override
  Future<void> acceptCall(String callId) async {
    callActions.add(('accept', callId));
    throw Exception('this call has already ended');
  }
}

const _extra = {'roomId': 'room-1', 'messageId': 'msg-1', 'callId': 'call-1', 'callerId': 'them'};

CallKitParams _nativeCall({String id = 'msg-1', bool isAccepted = false, Map<String, dynamic> extra = _extra}) =>
    CallKitParams(id: id, isAccepted: isAccepted, extra: extra);

void main() {
  group('IncomingCallScreen', incomingCallScreenTests);

  group('NativeCallInfo.fromExtra', () {
    test('reads roomId/messageId/callId', () {
      final info = NativeCallInfo.fromExtra(_extra)!;
      expect(info.roomId, 'room-1');
      expect(info.messageId, 'msg-1');
      expect(info.callId, 'call-1');
    });

    test('returns null when extra is null', () {
      expect(NativeCallInfo.fromExtra(null), isNull);
    });

    test('returns null when any id is missing or empty', () {
      for (final key in ['roomId', 'messageId', 'callId']) {
        expect(NativeCallInfo.fromExtra({..._extra}..remove(key)), isNull, reason: 'missing $key');
        expect(NativeCallInfo.fromExtra({..._extra, key: ''}), isNull, reason: 'empty $key');
      }
    });
  });

  group('callRoute', () {
    test('goes straight to CallScreen, not IncomingCallScreen', () {
      expect(callRoute('room-1', 'msg-1', isGroup: false), '/call/room-1?messageId=msg-1&group=false');
      expect(callRoute('room-1', 'msg-1', isGroup: true), '/call/room-1?messageId=msg-1&group=true');
    });
  });

  group('sameCallId', () {
    test('ignores case, since CallKit may uppercase UUIDs', () {
      expect(sameCallId('abc-def', 'ABC-DEF'), isTrue);
      expect(sameCallId('abc', 'abd'), isFalse);
    });
  });

  group('finishedCallMessageId', () {
    Map<String, dynamic> payload(String status) => {
          'id': 'msg-1',
          'call': {'id': 'call-1', 'status': status}
        };

    test('reports a call message that left ringing', () {
      for (final status in ['completed', 'missed', 'declined']) {
        expect(finishedCallMessageId(WsEvent('message.updated', payload(status))), 'msg-1');
      }
    });

    test('ignores a still-ringing call, non-call updates, and other event types', () {
      expect(finishedCallMessageId(WsEvent('message.updated', payload('ringing'))), isNull);
      expect(finishedCallMessageId(const WsEvent('message.updated', {'id': 'msg-2', 'body': 'hi'})), isNull);
      expect(finishedCallMessageId(WsEvent('message.created', payload('missed'))), isNull);
      expect(finishedCallMessageId(null), isNull);
    });
  });

  group('NativeCallController', () {
    late FakeApiClient api;
    late FakeNativeCallKit callKit;
    late List<String> routes;
    late ProviderContainer container;
    late NativeCallController controller;

    void setUpWith(FakeApiClient client) {
      api = client;
      api.rooms = [
        ApiRoom(id: 'room-1', isGroup: false, createdBy: 'them', createdAt: DateTime.now()),
        ApiRoom(id: 'room-g', isGroup: true, createdBy: 'them', createdAt: DateTime.now()),
      ];
      callKit = FakeNativeCallKit();
      routes = [];
      container = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(api),
        wsClientProvider.overrideWithValue(api.ws),
        nativeCallKitProvider.overrideWithValue(callKit),
        callNavigatorProvider.overrideWithValue(routes.add),
      ]);
      addTearDown(container.dispose);
      controller = container.read(nativeCallControllerProvider);
    }

    setUp(() => setUpWith(FakeApiClient(FakeWsClient())));

    test('a native accept joins the call and opens CallScreen directly', () async {
      callKit.active.add(_nativeCall(isAccepted: true));

      await controller.handleEvent(CallEventActionCallAccept(_nativeCall(isAccepted: true)));

      expect(api.callActions, [('accept', 'call-1')]);
      expect(routes, ['/call/room-1?messageId=msg-1&group=false']);
      expect(callKit.ended, isEmpty, reason: 'the native call stays up for the call itself');
    });

    test('a native accept of a group call opens the group layout', () async {
      const extra = {'roomId': 'room-g', 'messageId': 'msg-g', 'callId': 'call-g'};

      await controller.handleEvent(CallEventActionCallAccept(_nativeCall(id: 'msg-g', extra: extra)));

      expect(routes, ['/call/room-g?messageId=msg-g&group=true']);
    });

    test('a native accept also clears the same call shown as incoming in-app', () async {
      container.read(incomingCallProvider);
      api.ws.emit(WsEvent('message.created', {
        'id': 'msg-1',
        'roomId': 'room-1',
        'senderId': 'them',
        'kind': 'call',
        'createdAt': DateTime.now().toIso8601String(),
        'call': {'id': 'call-1', 'status': 'ringing', 'startedAt': DateTime.now().toIso8601String()},
      }));
      await Future<void>.delayed(Duration.zero);
      expect(container.read(incomingCallProvider), isNotNull);

      await controller.handleEvent(CallEventActionCallAccept(_nativeCall(isAccepted: true)));

      expect(container.read(incomingCallProvider), isNull);
    });

    test('a native accept of a call that already ended drops the native call instead of navigating', () async {
      setUpWith(_EndedCallApiClient(FakeWsClient()));
      callKit.active.add(_nativeCall(isAccepted: true));

      await controller.handleEvent(CallEventActionCallAccept(_nativeCall(isAccepted: true)));

      expect(routes, isEmpty);
      expect(callKit.ended, ['msg-1']);
    });

    test('an accept seen both live and on resume joins only once', () async {
      callKit.active.add(_nativeCall(isAccepted: true));

      await controller.handleEvent(CallEventActionCallAccept(_nativeCall(isAccepted: true)));
      await controller.resumeAcceptedCalls();

      expect(api.callActions, [('accept', 'call-1')]);
      expect(routes, hasLength(1));
    });

    test('resumeAcceptedCalls joins a call accepted before Dart was listening, and ignores a ringing one', () async {
      const ringingExtra = {'roomId': 'room-1', 'messageId': 'msg-2', 'callId': 'call-2'};
      callKit.active
        ..add(_nativeCall(isAccepted: true))
        ..add(_nativeCall(id: 'msg-2', extra: ringingExtra));

      await controller.resumeAcceptedCalls();

      expect(api.callActions, [('accept', 'call-1')]);
      expect(routes, ['/call/room-1?messageId=msg-1&group=false']);
    });

    test('a native decline declines the call server-side', () async {
      await controller.handleEvent(CallEventActionCallDecline(_nativeCall()));

      expect(api.callActions, [('decline', 'call-1')]);
    });

    test('ending a ringing native call ourselves is not treated as the user declining', () async {
      callKit.active.add(_nativeCall());

      await controller.endCall('msg-1');
      // CallKit reports our own end of an unanswered call as a decline.
      await controller.handleEvent(CallEventActionCallDecline(_nativeCall()));

      expect(callKit.ended, ['msg-1']);
      expect(api.callActions, isEmpty);
    });

    test('a user-initiated native end is reported on endedFromNative', () async {
      final ended = <String>[];
      controller.endedFromNative.listen(ended.add);

      await controller.handleEvent(CallEventActionCallEnded(_nativeCall(isAccepted: true)));
      await Future<void>.delayed(Duration.zero);

      expect(ended, ['msg-1']);
    });

    test('our own endCall is not reported on endedFromNative', () async {
      final ended = <String>[];
      controller.endedFromNative.listen(ended.add);
      callKit.active.add(_nativeCall(isAccepted: true));

      await controller.endCall('msg-1');
      await controller.handleEvent(CallEventActionCallEnded(_nativeCall(isAccepted: true)));
      await Future<void>.delayed(Duration.zero);

      expect(ended, isEmpty);
    });

    test('endCall is a no-op when no native call matches', () async {
      callKit.active.add(_nativeCall(id: 'msg-other'));

      await controller.endCall('msg-1');

      expect(callKit.ended, isEmpty);
    });

    test('endCall matches the native call id case-insensitively', () async {
      callKit.active.add(_nativeCall(id: 'ABC-DEF'));

      await controller.endCall('abc-def');

      expect(callKit.ended, ['abc-def']);
    });

    test('the call finishing server-side ends its native call', () async {
      callKit.active.add(_nativeCall());

      api.ws.emit(const WsEvent('message.updated', {
        'id': 'msg-1',
        'call': {'id': 'call-1', 'status': 'missed'},
      }));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(callKit.ended, ['msg-1']);
    });

    test('a still-ringing update leaves the native call alone', () async {
      callKit.active.add(_nativeCall());

      api.ws.emit(const WsEvent('message.updated', {
        'id': 'msg-1',
        'call': {'id': 'call-1', 'status': 'ringing'},
      }));
      await Future<void>.delayed(Duration.zero);

      expect(callKit.ended, isEmpty);
    });
  });
}

/// In-app answering/declining must stop the native CallKit ring too — the
/// other half of the linkage NativeCallController covers above.
void incomingCallScreenTests() {
  testWidgets('declining in-app declines the call and ends its native ring', (tester) async {
    final api = FakeApiClient(FakeWsClient())
      ..rooms = [ApiRoom(id: 'room-1', isGroup: false, createdBy: 'them', createdAt: DateTime.now())]
      ..messagesByRoom['room-1'] = [
        ApiMessage(
          id: 'msg-1',
          roomId: 'room-1',
          senderId: 'them',
          kind: 'call',
          createdAt: DateTime.now(),
          call: ApiCall(id: 'call-1', status: 'ringing', startedAt: DateTime.now()),
        ),
      ];
    final callKit = FakeNativeCallKit()..active.add(_nativeCall());

    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        wsClientProvider.overrideWithValue(api.ws),
        nativeCallKitProvider.overrideWithValue(callKit),
      ],
      child: const MaterialApp(home: IncomingCallScreen(roomId: 'room-1', messageId: 'msg-1')),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithIcon(CallControlButton, TablerIcons.phoneX));
    await tester.pumpAndSettle();

    expect(api.callActions, [('decline', 'call-1')]);
    expect(callKit.ended, ['msg-1']);
  });
}
