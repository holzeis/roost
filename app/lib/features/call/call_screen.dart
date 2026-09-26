import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../data/api_config.dart';
import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import 'call_controls.dart';

/// In-call screen for both 1:1 and group calls (FR4.1, FR4.2), connected to
/// a real LiveKit room. Serves both the caller (who arrives here straight
/// from starting the call) and an accepting callee (who arrives here from
/// IncomingCallScreen) — either way, joining media is the same: mint a
/// token (POST /api/livekit/token, unchanged), connect, and publish
/// mic/camera per FR4.3's audio-only choice.
///
/// **Calls cannot be tested on the iOS Simulator — use a physical device.**
/// Starting one there kills the app with SIGABRT: WebRTC brings up Apple's
/// Voice-Processing I/O audio unit, `AURemoteIO::Initialize` times out on
/// its RPC to the audio daemon, and AudioToolbox calls `abort()`. That's
/// inside CoreAudio, well below anything catchable from Dart.
/// `LiveKitClient.initialize(bypassVoiceProcessing: true)` looks like the
/// fix and isn't — it was tried, forced on explicitly, and the abort is
/// unchanged, because the option doesn't reach WebRTC's audio device module
/// initialization. The Simulator also has no camera and shares the host's
/// single tailnet identity (so it can't be a second participant anyway),
/// which is why this isn't worth working around.
class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({
    super.key,
    required this.roomId,
    required this.messageId,
    this.isGroup = false,
    this.audioOnly = false,
    this.initialMessage,
  });

  final String roomId;
  final String messageId;
  final bool isGroup;
  final bool audioOnly;

  /// The call's own message, when the caller (or navigator) already has it
  /// in hand — the caller specifically has no other way to get it: they're
  /// deliberately excluded from the message.created WebSocket broadcast for
  /// their own call (see server/internal/api's handleStartCall/
  /// deliverToRoom), so messagesProvider's cache never contains it for them
  /// at all, unlike every other room member. Falls back to searching that
  /// cache when absent (e.g. a route pushed without this, or a future
  /// caller of this screen that doesn't have it handy).
  final ApiMessage? initialMessage;

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

/// Resolves the [ApiCall] a CallScreen instance should join: prefers
/// [initialMessage] (the caller's *only* source — see CallScreen's own doc
/// comment on why messagesProvider's cache never has it for them) and falls
/// back to finding [messageId] in [messages] otherwise. Pulled out as a
/// plain function so this lookup is unit-testable without a real LiveKit
/// connection.
ApiCall? resolveCallToJoin(String messageId, ApiMessage? initialMessage, List<ApiMessage> messages) {
  if (initialMessage?.call != null) return initialMessage!.call;
  final match = messages.where((m) => m.id == messageId);
  return match.isEmpty ? null : match.first.call;
}

class _CallScreenState extends ConsumerState<CallScreen> {
  final _room = lk.Room();
  lk.EventsListener<lk.RoomEvent>? _listener;
  String? _callId;
  Timer? _ringTimeout;
  lk.CameraPosition _cameraPosition = lk.CameraPosition.front;
  bool _micOn = true;
  late bool _cameraOn = !widget.audioOnly;
  bool _connecting = true;
  String? _error;
  String? _mediaWarning;
  bool _leaving = false;
  final _stopwatch = Stopwatch();

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    try {
      final messages = widget.initialMessage?.call != null
          ? const <ApiMessage>[]
          : await ref.read(messagesProvider(widget.roomId).future);
      final call = resolveCallToJoin(widget.messageId, widget.initialMessage, messages);
      if (call == null) throw StateError('call not found in room history');
      _callId = call.id;

      final api = ref.read(apiClientProvider);
      final token = await api.mintLiveKitToken(widget.roomId);

      _listener = _room.createListener()
        ..on<lk.ParticipantConnectedEvent>((_) {
          _ringTimeout?.cancel();
          if (mounted) setState(() {});
        })
        ..on<lk.ParticipantDisconnectedEvent>((_) {
          if (!mounted) return;
          setState(() {});
          // Nobody else is left in a call I'm still in — hang up too,
          // rather than sit alone in an empty room.
          if (_room.remoteParticipants.isEmpty) _hangUp();
        })
        ..on<lk.TrackSubscribedEvent>((_) => mounted ? setState(() {}) : null)
        ..on<lk.TrackUnsubscribedEvent>((_) => mounted ? setState(() {}) : null)
        ..on<lk.LocalTrackPublishedEvent>((_) => mounted ? setState(() {}) : null)
        // setCameraEnabled(false) mutes the track rather than unpublishing
        // it (the publication and track object both stick around, just
        // stopped) — so a disabled camera, ours or a remote participant's,
        // only shows up as one of these, never as the track disappearing.
        ..on<lk.TrackMutedEvent>((_) => mounted ? setState(() {}) : null)
        ..on<lk.TrackUnmutedEvent>((_) => mounted ? setState(() {}) : null);

      await _room.connect(livekitUrl, token);

      // Capturing local media can fail independently of the connection
      // itself — no camera at all (iOS Simulator), a denied permission, a
      // device already in use by another app. By this point we've already
      // joined the room, so failing the whole call over it would be wrong:
      // a participant who can't publish can still see and hear everyone
      // else. Each track is enabled separately so one failing doesn't take
      // the other down with it, and the UI just reflects what's off.
      final unavailable = <String>[];
      try {
        await _room.localParticipant?.setMicrophoneEnabled(true);
      } catch (_) {
        _micOn = false;
        unavailable.add('Microphone');
      }
      if (_cameraOn) {
        try {
          await _room.localParticipant?.setCameraEnabled(true);
        } catch (_) {
          _cameraOn = false;
          unavailable.add('Camera');
        }
      }
      if (unavailable.isNotEmpty) {
        _mediaWarning = '${unavailable.join(' and ')} unavailable';
      }
      _stopwatch.start();

      if (mounted) setState(() => _connecting = false);

      // FR3.4-style client-driven timeout, matching the location-sharing
      // pattern: if nobody else has joined within 45s, give up rather than
      // ring forever. Cancelled above the moment someone connects.
      _ringTimeout = Timer(const Duration(seconds: 45), () {
        if (_room.remoteParticipants.isEmpty) _hangUp();
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _hangUp() async {
    if (_leaving) return;
    _leaving = true;
    _ringTimeout?.cancel();
    final callId = _callId;
    if (callId != null) {
      try {
        await ref.read(apiClientProvider).leaveCall(callId);
      } catch (_) {
        // Best-effort — the call still gets disconnected locally either way.
      }
    }
    await _room.disconnect();
    if (mounted) Navigator.of(context).maybePop();
  }

  // Both toggles can throw for the same reasons the initial capture can
  // (no such device, permission denied) — turning one back on is a fresh
  // capture attempt, not just a mute flag, so it needs the same handling.
  Future<void> _toggleMic() async {
    final next = !_micOn;
    try {
      await _room.localParticipant?.setMicrophoneEnabled(next);
    } catch (_) {
      if (mounted) setState(() => _mediaWarning = 'Microphone unavailable');
      return;
    }
    if (mounted) setState(() => _micOn = next);
  }

  Future<void> _toggleCamera() async {
    final next = !_cameraOn;
    try {
      await _room.localParticipant?.setCameraEnabled(next);
    } catch (_) {
      if (mounted) setState(() => _mediaWarning = 'Camera unavailable');
      return;
    }
    if (mounted) setState(() => _cameraOn = next);
  }

  Future<void> _switchCamera() async {
    final pubs = _room.localParticipant?.videoTrackPublications ?? const [];
    final track = pubs.isEmpty ? null : pubs.first.track;
    if (track is! lk.LocalVideoTrack) return;
    _cameraPosition = _cameraPosition.switched();
    await track.setCameraPosition(_cameraPosition);
  }

  @override
  void dispose() {
    _ringTimeout?.cancel();
    _listener?.dispose();
    _room.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        backgroundColor: CallColors.background,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Could not join the call.\n$_error',
                  textAlign: TextAlign.center, style: const TextStyle(color: CallColors.textPrimary)),
              const SizedBox(height: 16),
              CallControlButton(
                icon: TablerIcons.phoneX,
                background: CallColors.danger,
                iconColor: Colors.white,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
      );
    }
    if (_connecting) {
      return const Scaffold(
        backgroundColor: CallColors.background,
        body: Center(child: CircularProgressIndicator(color: CallColors.textPrimary)),
      );
    }

    final remote = _room.remoteParticipants.values.toList();
    final usersById = ref.watch(usersByIdProvider).valueOrNull ?? const {};
    String nameFor(String identity) => usersById[identity]?.displayName ?? '?';

    return Scaffold(
      backgroundColor: CallColors.background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: remote.isEmpty
                  ? Text(
                      widget.isGroup ? 'Calling…' : 'Calling ${nameFor(_soleOtherIdentity() ?? '')}…',
                      style: const TextStyle(color: CallColors.textPrimary, fontSize: 12, fontWeight: FontWeight.w500),
                    )
                  : _CallDuration(stopwatch: _stopwatch),
            ),
            if (_mediaWarning != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _mediaWarning!,
                  style: const TextStyle(color: CallColors.danger, fontSize: 11),
                ),
              ),
            Expanded(
              child: remote.length <= 1 && !widget.isGroup
                  ? _SoloLayout(
                      room: _room,
                      remote: remote.isEmpty ? null : remote.first,
                      cameraOn: _cameraOn,
                      nameFor: nameFor,
                    )
                  : _GridLayout(room: _room, remote: remote, nameFor: nameFor),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CallControlButton(
                    icon: _micOn ? TablerIcons.microphone : TablerIcons.microphoneOff,
                    onPressed: _toggleMic,
                  ),
                  const SizedBox(width: 10),
                  CallControlButton(
                    icon: _cameraOn ? TablerIcons.video : TablerIcons.videoOff,
                    onPressed: _toggleCamera,
                  ),
                  const SizedBox(width: 10),
                  CallControlButton(icon: TablerIcons.cameraRotate, onPressed: _switchCamera),
                  const SizedBox(width: 10),
                  CallControlButton(
                    icon: TablerIcons.phoneX,
                    background: CallColors.danger,
                    iconColor: Colors.white,
                    onPressed: _hangUp,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// For a 1:1 call's "Calling…" label before the callee has connected —
  /// resolved from the room's members rather than LiveKit (nobody else has
  /// joined yet, so LiveKit has no remote participant to name).
  String? _soleOtherIdentity() {
    final meId = ref.read(meProvider).valueOrNull?.id;
    final room = ref.read(roomProvider(widget.roomId)).valueOrNull;
    if (room == null || meId == null) return null;
    final matches = room.members.where((id) => id != meId);
    return matches.isEmpty ? null : matches.first;
  }
}

/// Self-ticking MM:SS label — isolated here so only this small widget
/// rebuilds every second, not the whole call screen.
class _CallDuration extends StatefulWidget {
  const _CallDuration({required this.stopwatch});
  final Stopwatch stopwatch;

  @override
  State<_CallDuration> createState() => _CallDurationState();
}

class _CallDurationState extends State<_CallDuration> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.stopwatch.elapsed;
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return Text('$minutes:$seconds', style: const TextStyle(color: CallColors.textPrimary, fontSize: 12));
  }
}

class _SoloLayout extends StatelessWidget {
  const _SoloLayout({required this.room, required this.remote, required this.cameraOn, required this.nameFor});

  final lk.Room room;
  final lk.RemoteParticipant? remote;
  final bool cameraOn;
  final String Function(String) nameFor;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: remote == null
              ? const Center(child: Icon(TablerIcons.user, color: CallColors.textSecondary, size: 48))
              : _ParticipantTile(participant: remote!, name: nameFor(remote!.identity), fill: true),
        ),
        if (cameraOn)
          Positioned(
            right: 12,
            bottom: 12,
            width: 96,
            height: 130,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _ParticipantTile(participant: room.localParticipant, name: 'You', fill: true),
            ),
          ),
      ],
    );
  }
}

class _GridLayout extends StatelessWidget {
  const _GridLayout({required this.room, required this.remote, required this.nameFor});

  final lk.Room room;
  final List<lk.RemoteParticipant> remote;
  final String Function(String) nameFor;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      _ParticipantTile(participant: room.localParticipant, name: 'You'),
      for (final p in remote) _ParticipantTile(participant: p, name: nameFor(p.identity)),
    ];
    return Padding(
      padding: const EdgeInsets.all(12),
      child: GridView.count(
        crossAxisCount: 2,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        childAspectRatio: 1.1,
        children: tiles,
      ),
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({required this.participant, required this.name, this.fill = false});

  final lk.Participant? participant;
  final String name;
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final videoPubs = participant?.videoTrackPublications ?? const [];
    final videoTrack = videoPubs.isEmpty ? null : videoPubs.first.track;
    final subscribed = videoPubs.isEmpty ? false : videoPubs.first.subscribed;
    // A disabled camera mutes the publication rather than removing it (true
    // for both a remote participant and ourselves), so a still-present,
    // still-subscribed track can be showing nothing — checked here instead
    // of trusting track-existence alone.
    final muted = videoPubs.isEmpty ? false : videoPubs.first.muted;
    final showVideo = videoTrack != null && subscribed && !muted;

    return Container(
      decoration: BoxDecoration(
        color: CallColors.tileBackground,
        borderRadius: fill ? null : BorderRadius.circular(8),
      ),
      child: Stack(
        children: [
          if (showVideo)
            Positioned.fill(child: lk.VideoTrackRenderer(videoTrack as lk.VideoTrack))
          else
            Center(
              child: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: CallColors.controlButton, shape: BoxShape.circle),
                child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: const TextStyle(color: CallColors.textSecondary, fontSize: 16)),
              ),
            ),
          Positioned(
            left: 6,
            bottom: 5,
            child: Text(name, style: const TextStyle(color: CallColors.textPrimary, fontSize: 10)),
          ),
        ],
      ),
    );
  }
}
