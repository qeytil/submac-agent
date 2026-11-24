/// Digital Human services — the living layer behind every bot.
///
/// A digital human is not a chat assistant that waits to be prompted. It is a
/// person who lives on the phone: aware of what matters, tired sometimes,
/// curious when idle, proactive when something needs doing, and never silent
/// unless it has nothing worth saying. This module holds the four subsystems
/// that make that true:
///
/// * [Heartbeat] — the pulse that says "I am still here".
/// * [SituationalAwareness] — what the world around us is doing right now.
/// * [LongTermMemory] — what we remember from before, and what we learned.
/// * [MoodEngine] — how we feel, which colours our words and our initiative.
///
/// See docs/digital-human.md for the full vision.

library;

export 'heartbeat.dart';
export 'awareness.dart';
export 'memory.dart';
export 'mood.dart';
