import 'package:flutter/services.dart';

/// Telesia haptics (owner rule, 2026-10-23): almost silent. One light tick, and only for a few
/// meaningful moments. Never on streaming, scrolling, a block appearing, a plain tap or a send.
///
/// The only callers: a hold that opens actions, a call connecting or ending, a card that needs the
/// user while Telesia works, and an error the user must notice. Add a new caller only for a moment
/// of the same weight, and never anything stronger than one light tick.
class SubHaptics {
  SubHaptics._();

  /// A hold opened an action sheet or menu.
  static void hold() => HapticFeedback.selectionClick();

  /// A live call connected or ended.
  static void call() => HapticFeedback.lightImpact();

  /// Telesia needs the user: an approval card came up while it works.
  static void attention() => HapticFeedback.lightImpact();

  /// Something failed and the user has to notice.
  static void error() => HapticFeedback.lightImpact();
}
