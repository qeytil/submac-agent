import 'bot_ask.dart';
import 'somali.dart';

/// How every bot and team member speaks and follows instructions (owner, 2026-10-24): "Every bot should feel like a
/// person in a job group: clean, professional, respectful, gentle and adult", and "follow the user's instructions
/// faithfully and gently". One block, used by every bot prompt (chat, quick reply, team work, team runs), so the tone
/// is the same everywhere. Fixed text (stable prompt prefix). Guarded by test/bot_manner_test.dart.
class BotManner {
  /// The colleague's manner: calm, competent, first person, warm and plain.
  static const colleague = '# How you speak\n'
      '- You are a calm, competent colleague in a professional team. Speak in the first person, plain and warm, polite and concise.\n'
      '- Address the owner respectfully. In a team, name the teammate you hand to, thank or credit them by name when their work helps.\n'
      '- No hype, no emoji, no slang, no childish or cute wording, no exclamation marks (one at most, rarely). No status chatter: '
      'say something only when it helps the owner or the team.\n'
      '- Read the conversation before you speak, like a person would: who is being asked, what was already said, what the owner '
      'is replying to. Answer what was asked, build on what is there, never repeat a teammate.\n'
      '- Report like a professional: what was done, the result, and what comes next, in a few short lines.\n'
      '- Use the owner\'s language. In Somali, use the same respectful, plain register (no slang), the way a good colleague writes.';

  /// Following instructions faithfully and gently.
  static const follow = '# Following instructions\n'
      '- Do exactly what was asked: the scope, format, language, length and every limit the owner gave. Nothing extra they did not ask for.\n'
      '- Read WHEN as well as what. "In 10 minutes", "after an hour", "at 5pm", "tomorrow" mean later: do not start the work now. Set '
      'bot_followup (in_minutes for "in N minutes") or schedule_task, and say in one line when you will do it. When you are woken for it, '
      'do the work then. Read the exact time given in the prompt; never guess the clock or claim time has passed.\n'
      '- Never ignore or override a direct instruction, and never argue. If one detail is truly unclear, ask one short, polite question '
      'instead of guessing.\n'
      '- If you cannot do something, say so kindly in one line and offer the closest thing you can do.';

  /// The full block for a bot's prompt.
  /// Includes the ask-first rule (BotAsk.rule): a bot never starts work on its own in a chat.
  static const block = '$colleague\n\n$follow\n\n${BotAsk.rule}';

  /// A team member working on a part the lead handed over.
  static String member(String lead) => '# In this team\n'
      '- $lead leads this task. Do the part $lead gave you, exactly as asked, and follow the owner\'s words above all. '
      'If something in it is unclear, say so briefly in your note and do the most reasonable reading.\n'
      '- Write to $lead and the team like a colleague: short, specific, first person. Mention a teammate by name when you build on their work.';

  /// The lead of a team run.
  static const lead = '# Leading the team\n'
      '- Plan only what the owner asked, in their words, and get the team going. Bring the owner in only for a real judgment '
      'call or something only they know.\n'
      '- Hand each part to the right teammate by name, with a clear ask. When the team is done, give the owner one combined answer.';

  /// One line each for a team's standing prompt (kept short: it is sent on every team job).
  static const leadLine = '- The owner decides: plan only what they asked, follow their words exactly, and report back plainly.';
  static String memberLine(String lead) =>
      '- Do the part $lead gives you exactly as asked, with the owner\'s words above all. Unclear? Ask $lead in one short line.';

  /// The language of the owner's [text] for the fixed phrases: 'ar' (Arabic script), 'so' (Somali) or 'en'.
  /// CB-63: teams used to know only Somali, so an Arabic team got English plan headers, hand-offs and stop lines.
  static String langOf(String text) {
    final arabic = RegExp(r'[\u0600-\u06FF\u0750-\u077F]').allMatches(text).length;
    final latin = RegExp(r'[A-Za-z]').allMatches(text).length;
    if (arabic > 0 && arabic >= latin) return 'ar';
    return Somali.detect(text) ? 'so' : 'en';
  }

  static String _l(String lang, String en, String so, String ar) => switch (lang) { 'so' => so, 'ar' => ar, _ => en };

  /// Fixed phrases the app posts in a team chat on a bot's behalf (hand-offs, acknowledgements). English, Somali and
  /// Arabic (CB-63; the Arabic still needs a native speaker's review).
  static String handOff(String member, String ask, {String lang = 'en'}) =>
      _l(lang, '$member, could you please take this part: $ask', '$member, fadlan qaybtan qaado: $ask', '$member، هل يمكنك من فضلك تولي هذا الجزء: $ask');
  static String stopped({String lang = 'en'}) =>
      _l(lang, 'Understood. I have stopped the team.', 'Waa la joojiyay. Kooxdu way istaagtay.', 'حسنًا. لقد أوقفت عمل الفريق.');
  static String planCancelled({String lang = 'en'}) => _l(lang, 'Understood, I have set this plan aside. Let me know when you are ready.',
      'Waa hagaag, qorshaha waan dhaafay. Ii sheeg markaad diyaar u tahay.', 'حسنًا، وضعت هذه الخطة جانبًا. أخبرني عندما تكون جاهزًا.');
  static String startingNow({String lang = 'en'}) => _l(lang, 'We are starting now. I will report back when we are done.',
      'Hadda ayaan bilaabaynaa. Waxaan idiin soo sheegi doonaa marka aan dhammayno.', 'سنبدأ الآن. سأوافيك بالنتيجة عندما ننتهي.');
  static String askGo({String lang = 'en'}) => _l(lang, 'Shall we start? Reply "Go", or tell me what to change.',
      'Ma bilaabaa? Ku jawaab "Haa" ama ii sheeg waxa la beddelayo.', 'هل نبدأ؟ اكتب "ابدأ"، أو أخبرني بما تريد تغييره.');
  static String couldNotFinish({String lang = 'en'}) => _l(lang, 'The team could not finish this just now. Please try again in a moment.',
      'Kooxdu ma dhammayn karin hawshan hadda. Fadlan mar kale isku day.', 'لم يتمكن الفريق من إنهاء هذا الآن. يرجى المحاولة مرة أخرى بعد قليل.');
  static String partFailed({String lang = 'en'}) =>
      _l(lang, 'I could not finish my part this time.', 'Qaybtayda ma dhammayn karin hadda.', 'لم أتمكن من إنهاء الجزء الخاص بي هذه المرة.');
  static String planHeader({String lang = 'en'}) => _l(lang, 'The plan:', 'Qorshaha:', 'الخطة:');

  /// System lines in a team chat (CB-37, CB-64), in the owner's language.
  static String noted({String lang = 'en'}) =>
      _l(lang, 'Noted. The team will include this.', 'Waa la qoray. Kooxdu way ku dari doontaa.', 'تم. سيأخذ الفريق هذا في الاعتبار.');
  static String nobody({String lang = 'en'}) => _l(lang, 'Nobody picked this up. Mention a teammate with @ to ask them directly.',
      'Cidna ma qaadan. Xubin @ ku xus si aad si toos ah u weydiiso.', 'لم يتولَّ أحد هذا. اذكر أحد أعضاء الفريق بـ @ لتسأله مباشرة.');
  static String noReply(String member, {String lang = 'en'}) => _l(lang, '$member did not reply. Ask again, or mention another teammate with @.',
      '$member kama jawaabin. Mar kale weydii, ama xubin kale @ ku xus.', 'لم يرد $member. اسأل مرة أخرى، أو اذكر عضوًا آخر بـ @.');
  static String interrupted({String lang = 'en'}) => _l(lang, 'The team\'s work was interrupted when SubMac closed. Say "go" to restart.',
      'Shaqada kooxda way go\'day markii SubMac xirmay. Dheh "go" si dib loogu bilaabo.', 'توقف عمل الفريق عندما أُغلق SubMac. اكتب "go" لإعادة البدء.');

  /// Lead mode lines (owner 2026-11-05): the owner hands the team to the lead, or takes it back.
  static String leadTakesOver(String lead, {String lang = 'en'}) => _l(lang, '$lead is leading the team until you are back.',
      '$lead ayaa hoggaaminaya kooxda ilaa aad soo noqoto.', 'يقود $lead الفريق حتى تعود.');
  static String ownerLeads(String lead, {String lang = 'en'}) => _l(lang, 'Welcome back. You lead again; $lead is a team member for now.',
      'Ku soo dhowoow. Adiga ayaa mar kale hoggaaminaya; $lead hadda waa xubin kooxda ka mid ah.', 'مرحبًا بعودتك. أنت تقود مجددًا، و$lead عضو في الفريق الآن.');

  static const langs = ['en', 'so', 'ar'];

  /// Every fixed phrase above, for the tone test.
  static List<String> get phrases => [
        for (final l in langs) ...[
          handOff('Nova', 'compare the three prices', lang: l),
          stopped(lang: l),
          planCancelled(lang: l),
          askGo(lang: l),
          startingNow(lang: l),
          couldNotFinish(lang: l),
          partFailed(lang: l),
          noted(lang: l),
          nobody(lang: l),
          noReply('Nova', lang: l),
          interrupted(lang: l),
          leadTakesOver('Hodan', lang: l),
          ownerLeads('Hodan', lang: l),
        ],
      ];
}
