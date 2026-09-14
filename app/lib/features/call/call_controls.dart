import 'package:flutter/material.dart';

/// Shared visual language for in-call screens: the dark frame from the
/// mockups is intentionally independent of the app's light/dark theme
/// setting — video call UIs stay dark regardless, to avoid a bright flash
/// during a call and to keep camera previews readable.
class CallColors {
  CallColors._();
  static const background = Color(0xFF1C1C1A);
  static const tileBackground = Color(0xFF2C2C2A);
  static const controlButton = Color(0xFF3A3A37);
  static const textPrimary = Color(0xFFF5F5F0);
  static const textSecondary = Color(0xFFA3A39C);
  static const danger = Color(0xFFC14343);
  static const accept = Color(0xFF4A9463);
}

class CallControlButton extends StatelessWidget {
  const CallControlButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.background = CallColors.controlButton,
    this.size = 44,
    this.iconColor = CallColors.textPrimary,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final Color background;
  final double size;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: iconColor, size: size * 0.4),
        ),
      ),
    );
  }
}
