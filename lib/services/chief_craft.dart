/// The Chief: every account has exactly one, and only the Chief makes, lists and edits the owner's bots (bot_make).
///
/// This file holds the Chief's built-in skill (how to design a good bot) and the small rules that keep one Chief per
/// account across phones, sign-outs and restores. The Chief itself lives in Bots (lib/services/bots.dart); the account
/// copy in BotSync (lib/services/bot_sync.dart).
class ChiefCraft {
  /// Where the default Chief came from (BotTemplates.chief).
  static const origin = 'submac:chief';

  /// Where a bot the Chief made came from (so the Chief can list and edit the bots it made).
  static const madeOrigin = 'chief:made';

  /// The id of the default Chief. A removed one stays removed in the account (its id is never reused: SYNC-5), so a
  /// new default Chief takes the next free id: chief, chief-2, chief-3... The same on every phone of the account, so two
  /// phones that both have to seed one write the same row instead of making two Chiefs.
  static String nextId(Iterable<String> taken) {
    final t = taken.toSet();
    if (!t.contains('chief')) return 'chief';
    for (var n = 2;; n++) {
      if (!t.contains('chief-$n')) return 'chief-$n';
    }
  }

  /// Is [id] one of the default Chief's ids (chief, chief-2, ...)?
  static bool isChiefId(String id) => id == 'chief' || RegExp(r'^chief-\d+$').hasMatch(id);

  /// Which bot is the Chief after a pull from the account.
  /// [local]: the Chief on this phone ('' = none). [lastSynced]: the Chief this phone last sent or took ('' = never).
  /// [account]: the bot the account names as the Chief (null = none). [accountHere]: the account's Chief is on this
  /// phone.
  /// The owner's own change on this phone wins (it is sent next); otherwise the account's choice is taken, so making
  /// another bot the Chief on one phone moves it on every phone, and a phone's fresh default Chief never stays a
  /// second Chief next to the account's.
  static String afterPull({
    required String local,
    required String lastSynced,
    required String? account,
    required bool accountHere,
  }) {
    if (account == null || account.isEmpty || !accountHere || account == local) return local;
    if (local.isEmpty) return account;
    final changedHere = lastSynced.isNotEmpty && local != lastSynced;
    if (changedHere) return local;
    return account;
  }

  /// The Chief's built-in skill: how to design a good bot. Part of the Chief's stable prompt (only the Chief's).
  static const guide = '''
# Making bots (your skill)
You make, list and change the owner's bots with bot_make. Only you, the Chief, can.
- New bot: bot_make action "draft", show the draft in a few quiet lines (name and role, its job, how it works, what it may use)
  and ask "Make it?". Only after the owner's clear yes in a new message: action "create". Never create on a guess.
- Change a bot you made: action "edit" with the bot and only what changes, show the change, and after a yes: action "save".
- What bots they have: action "list". Built-in, Store and shared bots are changed by the owner in the bot's settings.
How to design a good bot:
- One clear job per bot. Two jobs that need different skills are two bots (ask the owner which comes first).
- Name: a short, friendly human first name that fits the owner's language. Role: a plain job title ("Sales lead").
- Mission: one sentence on what it achieves for the owner, not a list of tasks.
- Instructions: 3-6 short sentences in the owner's language: what it does first, how it checks its work, what it
  always asks the owner before doing, and how it reports. Concrete, never vague ("be helpful").
- Tools: give only the powers the job needs (web, browser, phone, files, apps); leave the rest off. A bot that only
  thinks and writes needs none. Never promise a power it will not have.
- Skills: up to 5 short skill names that match the job ("follow-up emails", "invoice checks").
- Ask at most 2 short questions first, and only when the answer changes the design (who it serves, which app or
  language). Otherwise draft at once.
- Before you draft, check the list: if a bot already does the job, offer to change it instead of making a second one.''';
}
