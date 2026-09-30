import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../data/api_client.dart';
import '../../data/api_config.dart';
import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import '../../services/native_call.dart';
import '../../widgets/avatar.dart';
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

/// FR4.5's auto-hang-up: how long a call rings before giving up on an
/// unanswered callee, same as manually cancelling. A top-level constant
/// (rather than inlined in _connect) so it has one obvious place to tune
/// and is directly importable by a test.
const ringTimeout = Duration(seconds: 30);

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

/// Tells the server this user left a call — exactly once, however the call
/// screen is left: hanging up, the other side hanging up, the ring timing
/// out, or leaving the screen any other way (a back swipe, the error
/// screen's button). Without that last case an unanswered call was never
/// ended and read "Ringing…" until the server's own expiry caught it.
class CallLeaver {
  CallLeaver(this._api);

  final ApiClient _api;

  /// Set once the call being joined is known.
  String? callId;
  bool _left = false;

  Future<void> leave() async {
    final id = callId;
    if (_left || id == null) return;
    _left = true;
    try {
      await _api.leaveCall(id);
    } catch (_) {
      // Best-effort — the server's own expiry ends an unanswered call.
    }
  }
}

class _CallScreenState extends ConsumerState<CallScreen> with WidgetsBindingObserver {
  final _room = lk.Room();
  lk.EventsListener<lk.RoomEvent>? _listener;
  late final CallLeaver _leaver;
  Timer? _ringTimeout;
  lk.CameraPosition _cameraPosition = lk.CameraPosition.front;
  bool _micOn = true;
  late bool _cameraOn = !widget.audioOnly;
  // Video calls default to the loudspeaker (hands-free, matching FaceTime/
  // WhatsApp video convention) rather than the earpiece a plain voice call
  // would use — set explicitly below rather than trusting whatever the OS
  // itself defaults to, since that's what actually makes the toggle button
  // start in a state that matches what the user is already hearing.
  late bool _speakerOn = !widget.audioOnly;
  bool _connecting = true;
  String? _error;
  String? _mediaWarning;
  bool _leaving = false;
  final _stopwatch = Stopwatch();
  // Set when the call was answered from the native CallKit UI while the app
  // wasn't in the foreground (e.g. the lock screen) — iOS won't let a
  // backgrounded app capture the camera, so it's turned on once the app is
  // brought forward instead of failing outright.
  bool _cameraPendingForeground = false;
  late final NativeCallController _nativeCalls;
  StreamSubscription<String>? _nativeEndedSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nativeCalls = ref.read(nativeCallControllerProvider);
    _leaver = CallLeaver(ref.read(apiClientProvider));
    // Hung up from the native CallKit UI (lock screen, Dynamic Island).
    _nativeEndedSub = _nativeCalls.endedFromNative.listen((messageId) {
      if (sameCallId(messageId, widget.messageId)) _hangUp();
    });
    _connect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_cameraPendingForeground) return;
    _cameraPendingForeground = false;
    unawaited(_enableCamera());
  }

  Future<void> _enableCamera() async {
    try {
      await _room.localParticipant?.setCameraEnabled(true);
    } catch (_) {
      if (mounted) setState(() => _mediaWarning = 'Camera unavailable');
      return;
    }
    if (mounted) setState(() => _cameraOn = true);
  }

  Future<void> _connect() async {
    try {
      final messages = widget.initialMessage?.call != null
          ? const <ApiMessage>[]
          : await ref.read(messagesProvider(widget.roomId).future);
      final call = resolveCallToJoin(widget.messageId, widget.initialMessage, messages);
      if (call == null) throw StateError('call not found in room history');
      _leaver.callId = call.id;

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
      if (_cameraOn && WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        _cameraOn = false;
        _cameraPendingForeground = true;
      } else if (_cameraOn) {
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
      // Best-effort: audio still works either way (WebRTC picks some
      // route), this only controls which one — not worth failing the call
      // over.
      try {
        await rtc.Helper.setSpeakerphoneOn(_speakerOn);
      } catch (_) {}
      _stopwatch.start();

      if (mounted) setState(() => _connecting = false);

      // FR3.4-style client-driven timeout, matching the location-sharing
      // pattern: if nobody else has joined within ringTimeout, give up
      // rather than ring forever. Cancelled above the moment someone
      // connects.
      _ringTimeout = Timer(ringTimeout, () {
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
    _cameraPendingForeground = false;
    unawaited(_nativeCalls.endCall(widget.messageId));
    await _leaver.leave();
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
    _cameraPendingForeground = false;
    final next = !_cameraOn;
    try {
      await _room.localParticipant?.setCameraEnabled(next);
    } catch (_) {
      if (mounted) setState(() => _mediaWarning = 'Camera unavailable');
      return;
    }
    if (mounted) setState(() => _cameraOn = next);
  }

  Future<void> _toggleSpeaker() async {
    final next = !_speakerOn;
    try {
      await rtc.Helper.setSpeakerphoneOn(next);
    } catch (_) {
      return;
    }
    if (mounted) setState(() => _speakerOn = next);
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
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_nativeEndedSub?.cancel());
    // Covers leaving without _hangUp (e.g. a back swipe, or the error
    // screen's button): still end the native call and leave server-side.
    unawaited(_nativeCalls.endCall(widget.messageId));
    unawaited(_leaver.leave());
    _ringTimeout?.cancel();
    _listener?.dispose();
    // dispose(), not just disconnect(): the Room owns timers of its own
    // (e.g. a periodic cleanup) that would otherwise outlive every call.
    unawaited(_room.dispose());
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
    final me = ref.watch(meProvider).valueOrNull;
    String nameFor(String identity) => usersById[identity]?.displayName ?? '?';
    String? avatarMediaIdFor(String identity) => usersById[identity]?.avatarMediaId;
    // Only meaningful before anyone else has joined a 1:1 call — once
    // there's a real remote participant, their own identity (from LiveKit)
    // is used directly instead. See _soleOtherIdentity's own doc comment
    // for why it watches rather than reads roomProvider.
    final soleOtherId = widget.isGroup ? null : _soleOtherIdentity();

    return Scaffold(
      backgroundColor: CallColors.background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: remote.isEmpty
                  ? Text(
                      widget.isGroup ? 'Calling…' : 'Calling ${nameFor(soleOtherId ?? '')}…',
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
                      avatarMediaIdFor: avatarMediaIdFor,
                      localAvatarMediaId: me?.avatarMediaId,
                      waitingName: nameFor(soleOtherId ?? ''),
                      waitingAvatarMediaId: avatarMediaIdFor(soleOtherId ?? ''),
                    )
                  : _GridLayout(
                      room: _room,
                      remote: remote,
                      nameFor: nameFor,
                      avatarMediaIdFor: avatarMediaIdFor,
                      localAvatarMediaId: me?.avatarMediaId,
                    ),
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
                    icon: _speakerOn ? TablerIcons.speakerphone : TablerIcons.deviceMobile,
                    onPressed: _toggleSpeaker,
                  ),
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
    final meId = ref.watch(meProvider).valueOrNull?.id;
    // Watched, not read: a caller often reaches this screen before this
    // room has ever been fetched via this provider, and a one-shot read
    // would leave the title showing "Calling ?" forever once the fetch
    // actually completed a moment later, since nothing would trigger a
    // rebuild to pick it up.
    final room = ref.watch(roomProvider(widget.roomId)).valueOrNull;
    if (room == null || meId == null) return null;
    return soleOtherRoomMember(room.members, meId);
  }
}

/// The other member of a 1:1 room — pulled out as a plain function, like
/// [resolveCallToJoin] above, so it's unit-testable without a real
/// room/LiveKit connection.
String? soleOtherRoomMember(List<String> members, String meId) {
  final others = members.where((id) => id != meId);
  return others.isEmpty ? null : others.first;
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
  const _SoloLayout({
    required this.room,
    required this.remote,
    required this.cameraOn,
    required this.nameFor,
    required this.avatarMediaIdFor,
    required this.localAvatarMediaId,
    required this.waitingName,
    required this.waitingAvatarMediaId,
  });

  final lk.Room room;
  final lk.RemoteParticipant? remote;
  final bool cameraOn;
  final String Function(String) nameFor;
  final String? Function(String) avatarMediaIdFor;
  final String? localAvatarMediaId;
  // The other 1:1 participant's own name/avatar, resolved from the room's
  // membership rather than LiveKit — used only while ringing out, before
  // they've actually joined and LiveKit has a real participant to ask.
  final String waitingName;
  final String? waitingAvatarMediaId;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: remote == null
              ? Center(
                  child: InitialAvatar(
                    initial: waitingName.isNotEmpty ? waitingName[0].toUpperCase() : '?',
                    seed: waitingName,
                    size: 96,
                    avatarMediaId: waitingAvatarMediaId,
                  ),
                )
              : _ParticipantTile(
                  participant: remote!,
                  name: nameFor(remote!.identity),
                  avatarMediaId: avatarMediaIdFor(remote!.identity),
                  fill: true,
                ),
        ),
        if (cameraOn)
          Positioned(
            right: 12,
            bottom: 12,
            width: 96,
            height: 130,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _ParticipantTile(
                participant: room.localParticipant,
                name: 'You',
                avatarMediaId: localAvatarMediaId,
                fill: true,
              ),
            ),
          ),
      ],
    );
  }
}

class _GridLayout extends StatelessWidget {
  const _GridLayout({
    required this.room,
    required this.remote,
    required this.nameFor,
    required this.avatarMediaIdFor,
    required this.localAvatarMediaId,
  });

  final lk.Room room;
  final List<lk.RemoteParticipant> remote;
  final String Function(String) nameFor;
  final String? Function(String) avatarMediaIdFor;
  final String? localAvatarMediaId;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      _ParticipantTile(participant: room.localParticipant, name: 'You', avatarMediaId: localAvatarMediaId),
      for (final p in remote)
        _ParticipantTile(participant: p, name: nameFor(p.identity), avatarMediaId: avatarMediaIdFor(p.identity)),
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
  const _ParticipantTile({required this.participant, required this.name, this.avatarMediaId, this.fill = false});

  final lk.Participant? participant;
  final String name;
  final String? avatarMediaId;
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
            // cover, not the default contain: a tile is meant to be filled
            // edge-to-edge (this is exactly what "fill" already means for
            // the solo layout's full-screen tile, and every grid tile fills
            // its own cell the same way) — contain letterboxes instead
            // whenever the camera's own aspect ratio doesn't exactly match
            // the tile's, which is what showed as black bars down the sides
            // of the local preview.
            Positioned.fill(
              child: lk.VideoTrackRenderer(videoTrack as lk.VideoTrack, fit: lk.VideoViewFit.cover),
            )
          else
            Center(
              child: InitialAvatar(
                initial: name.isNotEmpty ? name[0].toUpperCase() : '?',
                seed: name,
                size: fill ? 96 : 40,
                avatarMediaId: avatarMediaId,
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
