import 'package:flutter/widgets.dart';

import 'motion.dart';
export 'motion.dart';

/// The one type scale.
///
/// Screens read from here instead of inventing a size. The steps are taken
/// from what the app already does well, then tightened: seven, not seventeen.
class AppText {
  const AppText._();

  /// Timestamps, counters, footnote marks.
  static const double caption = 11.5;

  /// Dense secondary text inside cards and rows.
  static const double micro = 12.5;

  /// Labels, section headers, quiet metadata.
  static const double meta = 13.5;

  /// The reading size for messages, rows and fields.
  static const double body = 15;

  /// Lead paragraph in cards and sheets.
  static const double lead = 16.5;

  /// Section and page titles in sans.
  static const double title = 20;

  /// Serif moments: the empty-state question, sheet titles.
  static const double display = 25;

  /// Serif moments: the largest statement on a screen.
  static const double displayLarge = 32;

  static const TextStyle captionStyle =
      TextStyle(fontSize: caption, height: 1.35, letterSpacing: 0.1);
  static const TextStyle microStyle = TextStyle(fontSize: micro, height: 1.4);
  static const TextStyle metaStyle = TextStyle(fontSize: meta, height: 1.45);
  static const TextStyle bodyStyle = TextStyle(fontSize: body, height: 1.5);
  static const TextStyle leadStyle = TextStyle(fontSize: lead, height: 1.45);
  static const TextStyle titleStyle =
      TextStyle(fontSize: title, height: 1.25, letterSpacing: -0.2);

  /// The one section-header style: sentence case, medium weight, muted colour
  /// applied by the caller. Never uppercase, never letter-spaced.
  static const TextStyle sectionStyle =
      TextStyle(fontSize: meta, height: 1.35, fontWeight: FontWeight.w600);
}

/// Separation rule (PLAN.md 3.1): no divider lines between rows or sections.
/// Group with spacing instead: [Space.x1] between rows in a group,
/// [Space.x6] between groups.

/// Corner radii: four sizes and a pill, nothing in between.
class Radii {
  const Radii._();

  /// Chips, tags, tiny controls.
  static const double sm = 8;

  /// Fields and buttons.
  static const double field = 12;

  /// Rows, cards, message bubbles.
  static const double row = 16;

  /// Sheets, dialogs, the composer.
  static const double sheet = 20;

  /// Fully round.
  static const double pill = 999;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius fieldAll = BorderRadius.all(Radius.circular(field));
  static const BorderRadius rowAll = BorderRadius.all(Radius.circular(row));
  static const BorderRadius sheetAll = BorderRadius.all(Radius.circular(sheet));
}

/// Spacing steps, 4 to 32.
class Space {
  const Space._();

  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 20;
  static const double x6 = 24;
  static const double x8 = 32;
}

/// Icon sizes, shared by brand glyphs and Material icons.
class IconSize {
  const IconSize._();

  static const double sm = 16;
  static const double md = 18;
  static const double lg = 20;
  static const double xl = 24;
}

/// Luxury chat rhythm (feature/luxury-ui): wide margins, generous air between turns,
/// and one set of motion timings so every entrance feels like the same hand.
class Lux {
  const Lux._();

  /// Side margin of the reading column.
  static const double gutter = 24;

  /// Space kept free on the far side of your own message.
  static const double promptInset = 56;

  /// Air between two turns.
  static const double turnGap = 36;

  /// Air between two blocks of one reply (a paragraph, a table, a file).
  static const double blockGap = 18;

  /// Reading size and leading of Telesia's prose.
  static const double read = 16.5;
  static const double readHeight = 1.62;

  /// Your own message, in the serif, when it is short enough to read as a line.
  static const double prompt = 21;
  static const int promptSerifMax = 220;

  /// The wordmark in the top bar.
  static const double wordmark = 24;

  /// The quiet label over a document, table or plan.
  static const double label = 12;

  /// The activity dot: 8 so the status text sits 12 inside the line (dot + [Space.x1]), the same
  /// inset the finished "Worked for ..." line takes, so the handover never shifts the words.
  static const double pulse = 8;

  /// Small round tap targets (icons in the bar and the composer).
  static const double tap = 40;

  /// The composer's corner.
  static const double composerRadius = 26;

  /// The Bots workspace rail (owner 2026-10-24): narrow, so the chat stays readable beside it.
  static const double railWidth = 84;

  /// A head in the rail.
  static const double railFace = 40;

  /// The bot's face in the greeting of its empty chat.
  static const double greetingFace = 64;
}

/// The chat's timings: all taken from Telesia's signature motion ([SubMotion] in ui/motion.dart).
class LuxMotion {
  const LuxMotion._();

  static const Duration quick = SubMotion.quick;
  static const Duration base = SubMotion.base;
  static const Duration enter = SubMotion.enter;

  /// Delay between blocks of one reply, and the most a block ever waits.
  static const Duration stagger = SubMotion.stagger;
  static const Duration maxStagger = SubMotion.maxStagger;

  /// How far a block rises as it fades in.
  static const double rise = SubMotion.rise;

  static const Curve ease = SubMotion.settle;
  static const Curve settle = SubMotion.settle;
}
