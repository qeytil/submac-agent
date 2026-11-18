import 'dart:ui' show Color;

import 'person.dart';

/// Colours for a digital person's status dot (the presence ring).
///
/// Kept next to [PresenceState] because the dot is a property of the person,
/// not of any one screen: the feed, the chat header and the profile sheet must
/// all show the same colour for the same state.
abstract final class PresenceStateColors {
  static const Color offline = Color(0xFF9C978E);
  static const Color online = Color(0xFF3F9A5B);
  static const Color thinking = Color(0xFF4A9BD9);
  static const Color working = Color(0xFF9B5DE5);
  static const Color accent = Color(0xFFF2C14E);

  static Color colorOf(PresenceState state) => switch (state) {
        PresenceState.offline => offline,
        PresenceState.online => online,
        PresenceState.thinking => thinking,
        PresenceState.working => working,
      };
}