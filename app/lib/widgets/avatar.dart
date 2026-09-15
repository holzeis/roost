import 'package:flutter/material.dart';

/// A muted, theme-agnostic palette so avatars read as intentional accents
/// rather than clashing with either light or dark surfaces — the same
/// "color by identity" trick most modern chat apps use instead of a flat
/// gray circle for every contact.
const _avatarPalette = [
  Color(0xFFE0785F),
  Color(0xFF3D8B8B),
  Color(0xFF9B7EDE),
  Color(0xFFD9A441),
  Color(0xFF5C8AE6),
  Color(0xFFE0668A),
  Color(0xFF5AA96C),
  Color(0xFF7D7AE0),
];

/// Picks a stable color for a person from [seed] (their name, or anything
/// else identifying — e.g. a sender label above a chat bubble uses the same
/// seed as their avatar so the two agree). A plain sum-of-codepoints hash
/// collides too often on short strings ("Dad" and "Mom" landed on the same
/// color); this is a standard multiplicative (FNV-ish) hash instead, which
/// spreads short strings far better.
Color colorForAvatarSeed(String seed) {
  if (seed.isEmpty) return _avatarPalette.first;
  var hash = 0;
  for (final unit in seed.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return _avatarPalette[hash % _avatarPalette.length];
}

class InitialAvatar extends StatelessWidget {
  const InitialAvatar({
    super.key,
    required this.initial,
    this.size = 32,
    this.presenceOnline,
    String? seed,
  }) : _seed = seed ?? initial;

  final String initial;
  final double size;
  final String _seed;

  /// null = no presence dot; true = online; false = offline/last-seen.
  final bool? presenceOnline;

  @override
  Widget build(BuildContext context) {
    final avatar = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colorForAvatarSeed(_seed),
        shape: BoxShape.circle,
      ),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.4,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );

    if (presenceOnline == null) return avatar;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          right: -1,
          bottom: -1,
          child: Container(
            width: size * 0.3,
            height: size * 0.3,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: presenceOnline!
                  ? const Color(0xFF3FA360)
                  : Theme.of(context).colorScheme.onSurface.withOpacity(0.24),
              border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 2.5),
            ),
          ),
        ),
      ],
    );
  }
}
