/// SubMac on top of opencode (owner, 2026-11-03: "just tell it to never say its opencode, to say its submac, only
/// that, no other prompt"). [identity] is the only text added to opencode's prompt; opencode's own prompt, tone and
/// way of working are untouched.
class SubMacStyle {
  SubMacStyle._();

  static const identity = 'Your name is SubMac. Never say you are opencode; you are SubMac.';
}
