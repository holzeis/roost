import 'package:flutter/material.dart';

import 'call_controls.dart';

/// In-call screen for both 1:1 and group calls (FR4.1, FR4.2). The actual
/// LiveKit room connection (audio/video tracks, participant events) is not
/// wired up yet — this establishes the call UI and control surface described
/// in FR4.3/4.6/4.7 against mock participants; connecting it to
/// package:livekit_client and the server's POST /api/livekit/token endpoint
/// is the next milestone for this screen.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.roomId, this.isGroup = false});

  final String roomId;
  final bool isGroup;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  bool _micOn = true;
  bool _cameraOn = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CallColors.background,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: widget.isGroup ? _GroupParticipantGrid(cameraOn: _cameraOn) : const _SoloParticipant()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CallControlButton(
                    icon: _micOn ? Icons.mic_none : Icons.mic_off,
                    onPressed: () => setState(() => _micOn = !_micOn),
                  ),
                  const SizedBox(width: 10),
                  CallControlButton(
                    icon: _cameraOn ? Icons.videocam_outlined : Icons.videocam_off_outlined,
                    onPressed: () => setState(() => _cameraOn = !_cameraOn),
                  ),
                  const SizedBox(width: 10),
                  CallControlButton(icon: Icons.cameraswitch_outlined, onPressed: () {}),
                  const SizedBox(width: 10),
                  CallControlButton(
                    icon: Icons.call_end,
                    background: CallColors.danger,
                    iconColor: Colors.white,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SoloParticipant extends StatelessWidget {
  const _SoloParticipant();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        const SizedBox(height: 30),
        Container(
          width: 56,
          height: 56,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: CallColors.controlButton, shape: BoxShape.circle),
          child: const Icon(Icons.person_outline, color: CallColors.textSecondary, size: 24),
        ),
        const SizedBox(height: 10),
        const Text('Family call', style: TextStyle(color: CallColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w500)),
        const SizedBox(height: 3),
        const Text('02:14 · Mom, Sam', style: TextStyle(color: CallColors.textSecondary, fontSize: 11)),
      ],
    );
  }
}

class _GroupParticipantGrid extends StatelessWidget {
  const _GroupParticipantGrid({required this.cameraOn});

  final bool cameraOn;

  @override
  Widget build(BuildContext context) {
    const participants = ['Mom', 'Dad', 'Sam', 'You'];
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('Family call · 05:32', style: TextStyle(color: CallColors.textPrimary, fontSize: 12, fontWeight: FontWeight.w500)),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: GridView.count(
              crossAxisCount: 2,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              childAspectRatio: 1.1,
              children: [
                for (final name in participants) _ParticipantTile(name: name, isSelf: name == 'You', cameraOn: cameraOn),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({required this.name, required this.isSelf, required this.cameraOn});

  final String name;
  final bool isSelf;
  final bool cameraOn;

  @override
  Widget build(BuildContext context) {
    final showCamera = isSelf ? cameraOn : true;
    return Container(
      decoration: BoxDecoration(
        color: CallColors.tileBackground,
        borderRadius: BorderRadius.circular(8),
        border: isSelf ? Border.all(color: const Color(0xFF46463F)) : null,
      ),
      child: Stack(
        children: [
          Center(
            child: showCamera
                ? const Icon(Icons.videocam_outlined, color: Color(0xFF6B6B63), size: 20)
                : Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(color: CallColors.controlButton, shape: BoxShape.circle),
                    child: Text(name[0], style: const TextStyle(color: CallColors.textSecondary, fontSize: 12)),
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
