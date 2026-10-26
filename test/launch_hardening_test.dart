// Launch hardening (feat/launch-hardening): unit tests for each fix. The scenario suite that drives whole tasks through
// the agent loop is test/launch_scenarios_test.dart. Findings and ranks: docs/launch-hardening.md.
//
// Run: flutter test test/launch_hardening_test.dart
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';

import 'package:agent/agent/core.dart';
import 'package:agent/models.dart';
import 'package:agent/services/agent_craft.dart';
import 'package:agent/services/agent_loop.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/services/reply_lang.dart';
import 'package:agent/services/reply_text.dart';
import 'package:agent/services/truth.dart';
import 'package:agent/widgets/math_text.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;

const _so = 'Fadlan ii sheeg sida loo sameeyo shaah fiican oo carruurta ay jeclaan karaan, waan ku mahadsanahay walaal.';
const _ar = 'من فضلك اشرح لي كيف أعد كوبًا جيدًا من الشاي بالحليب في البيت.';
const _en = 'Please tell me how to make a good cup of tea at home for my family.';

const _enReply = 'To make a good cup of tea, boil fresh water, warm the pot, add one spoon of tea for each cup and let it '
    'steep for three to five minutes. Then pour it through a strainer and add milk or sugar if you like. It is simple and '
    'it tastes much better than a tea bag.';
const _soReply = 'Si aad u samayso shaah fiican, biyo cusub karkari, ku dar caleen shaah iyo xoogaa sonkor ah, kadibna u daa '
    'shan daqiiqo. Ka dib caano ku dar haddii aad rabto. Waa fudud yahay, carruurtuna way jeclaan doonaan, walaal. Waxaan '
    'kuu soo jeedinayaa inaad hal mar isku daydo.';
const _arReply = 'لتحضير كوب جيد من الشاي، اغلِ ماءً عذبًا، ثم أضف ملعقة شاي لكل كوب واتركه ينقع من ثلاث إلى خمس دقائق، '
    'ثم صبّه وأضف الحليب أو السكر حسب رغبتك. الطريقة سهلة وطعمها أفضل بكثير من أكياس الشاي الجاهزة.';

void main() {
  // ================================================================== H-1 reply language
  group('H-1 ReplyLang: the reply follows the user\'s language', () {
    test('detects Somali, Arabic and English; too little text is unknown', () {
      expect(ReplyLang.detect(_so), 'so');
      expect(ReplyLang.detect(_ar), 'ar');
      expect(ReplyLang.detect(_en), 'en');
      expect(ReplyLang.detect('ok'), isNull);
      expect(ReplyLang.detect('2'), isNull);
      expect(ReplyLang.detect('ሰላም እንዴት ነህ'), 'am');
      // Persian / Urdu are not called Arabic (the generic "language of the latest message" line is used).
      expect(ReplyLang.detect('لطفا به من بگویید چگونه یک چای خوب درست کنم'), isNull);
      expect(ReplyLang.detect('براہ کرم مجھے بتائیں کہ اچھی چائے کیسے بنتی ہے'), isNull);
    });

    test('code, links and formulas do not decide the language', () {
      expect(ReplyLang.detect('اشرح هذا الكود من فضلك\n```python\nfor item in items:\n    print(item.name)\n```'), 'ar');
      expect(ReplyLang.detect('ما هذا الموقع؟ https://www.example.com/some/long/english/path/about/things'), 'ar');
    });

    test('a short answer ("haa", "ok") carries the language of the message before it', () {
      expect(ReplyLang.ofChat(['haa', _so]), 'so');
      expect(ReplyLang.ofChat(['ok', '2', _ar]), 'ar');
      expect(ReplyLang.ofChat(['ok']), isNull);
    });

    test('the anchor names the language, or falls back to "the language of the latest message"; a set language wins', () {
      expect(ReplyLang.anchor('so'), contains('is in Somali. Write your reply to them in Somali'));
      expect(ReplyLang.anchor('ar'), contains('in Arabic'));
      expect(ReplyLang.anchor(null), contains('language of the user\'s latest message'));
      expect(ReplyLang.anchor('so', setting: 'English'), contains('in English (their setting)'));
      for (final a in [ReplyLang.anchor('so'), ReplyLang.anchor(null)]) {
        expect(a, contains('even when tool results'));
        expect(a, contains('a translation'));
      }
    });

    test('mismatch: clear cases only', () {
      expect(ReplyLang.mismatch(_enReply, 'so'), isTrue, reason: 'Somali question, English answer');
      expect(ReplyLang.mismatch(_enReply, 'ar'), isTrue, reason: 'Arabic question, English answer');
      expect(ReplyLang.mismatch(_arReply, 'en'), isTrue, reason: 'English question, Arabic answer');
      expect(ReplyLang.mismatch(_soReply, 'en'), isTrue, reason: 'English question, Somali answer');
      expect(ReplyLang.mismatch(_soReply, 'so'), isFalse);
      expect(ReplyLang.mismatch(_arReply, 'ar'), isFalse);
      expect(ReplyLang.mismatch(_enReply, 'en'), isFalse);
      expect(ReplyLang.mismatch(_enReply, null), isFalse, reason: 'unknown user language: never sent back');
    });

    test('mismatch: short replies, brand names and code never trip it', () {
      expect(ReplyLang.mismatch('Done. iPhone 16 Pro Max, 256 GB.', 'ar'), isFalse);
      expect(ReplyLang.mismatch('هذا هو الكود:\n```python\n${'print("hello world from the example program")\n' * 20}```', 'ar'), isFalse);
      expect(ReplyLang.mismatch('OK', 'so'), isFalse);
    });

    test('mismatch: never when they asked for a translation or another language', () {
      expect(ReplyLang.mismatch(_enReply, 'so', userText: 'U turjun Ingiriisi: $_so'), isFalse);
      expect(ReplyLang.mismatch(_enReply, 'so', userText: 'Af Ingiriis igu qor warqad'), isFalse);
      expect(ReplyLang.mismatch(_enReply, 'ar', userText: 'ترجم هذا النص إلى الإنجليزية'), isFalse);
      expect(ReplyLang.mismatch(_arReply, 'en', userText: 'Write this in Arabic for my client'), isFalse);
      expect(ReplyLang.mismatch(_soReply, 'en', userText: 'translate to somali: good morning everyone'), isFalse);
    });

    test('the fix note asks for the same reply in the user\'s language, without tools', () {
      final n = ReplyLang.fixNote('so');
      expect(n, contains('fully in Somali'));
      expect(n, contains('Do not call tools'));
    });
  });

  // ================================================================== H-2 truth gate in Somali and Arabic
  group('H-2 Truth: done-claims in Somali and Arabic need a tool result', () {
    const none = <Evidence>[];
    test('Somali claims without proof are caught', () {
      expect(Truth.unproven('Fariinta waa la diray.', none), contains('a message was sent'));
      expect(Truth.unproven('Waan u diray Cali fariinta.', none), contains('a message was sent'));
      expect(Truth.unproven('Faylka waan kaydiyay.', none), contains('a file was saved'));
      expect(Truth.unproven('Ballanta waan kuu ballansaday.', none), contains('a booking was made'));
      expect(Truth.unproven('Lacagta waa la bixiyay.', none), contains('a payment went through'));
      expect(Truth.unproven('Xasuusiyaha waan kuu sameeyay.', none), contains('something was created'));
    });

    test('Arabic claims without proof are caught', () {
      expect(Truth.unproven('تم إرسال الرسالة إلى علي.', none), contains('a message was sent'));
      expect(Truth.unproven('لقد حجزت لك موعدًا غدًا.', none), contains('a booking was made'));
      expect(Truth.unproven('تم حذف الملف.', none), contains('something was deleted'));
      expect(Truth.unproven('تم الدفع بنجاح.', none), contains('a payment went through'));
    });

    test('negations and questions are not claims', () {
      expect(Truth.unproven('Fariinta weli lama dirin.', none), isNull);
      expect(Truth.unproven('Ma rabtaa inaan diro? Waan diray markii hore ma ahayn.', none), isNull);
      expect(Truth.unproven('لم يتم إرسال الرسالة بعد.', none), isNull);
      expect(Truth.unproven('تعذر إرسال الرسالة.', none), isNull);
    });

    test('a matching tool result proves it', () {
      const ev = [Evidence(tool: 'whatsapp_send', ok: true)];
      expect(Truth.unproven('Fariinta waa la diray.', ev), isNull);
      expect(Truth.unproven('تم إرسال الرسالة.', ev), isNull);
    });

    test('English claims behave as before', () {
      expect(Truth.unproven('I\'ve sent the message.', none), contains('a message was sent'));
      expect(Truth.unproven('I could not send the message.', none), isNull);
    });
  });

  // ================================================================== H-3 capability fallbacks
  group('H-3 unknown tools point at real ones; the prompt has a "cannot" playbook', () {
    test('near names: shared words and near spellings, best first, at most three', () {
      final known = {'web_search', 'fetch_url', 'email_draft', 'email_send', 'calculate', 'schedule_task', ToolNames.unknown};
      expect(ToolNames.near('browser.search', known), ['web_search']);
      expect(ToolNames.near('gmail.send_email', known).first, 'email_send');
      expect(ToolNames.near('calculte', known), ['calculate']);
      expect(ToolNames.near('set_reminder_task', known), contains('schedule_task'));
      expect(ToolNames.near('zzzz', known), isEmpty);
      expect(ToolNames.near('email', known).length, lessThanOrEqualTo(3));
      expect(ToolNames.near('unknown_tool', known), isNot(contains(ToolNames.unknown)));
    });

    test('resolve carries the near names to the stub, and the text tells the model what to do', () {
      final c = ToolNames.resolve(ToolCall(id: 'x', name: 'functions.search_web', arguments: '{}'), {'web_search', 'fetch_url'});
      expect(c.name, ToolNames.unknown);
      final a = jsonDecode(c.arguments) as Map<String, dynamic>;
      expect(a['tool'], 'search_web');
      expect(a['near'], ['web_search']);
      final t = ToolNames.unknownText(a['tool'], a['near']);
      expect(t, contains('Closest real tools: web_search'));
      expect(t, contains('closest real thing'));
      expect(ToolNames.unknownText('zzz'), 'Error: there is no tool named "zzz". Use one of the tools you were given.');
    });

    test('the craft block covers every kind of ask and the cannot-do playbook', () {
      for (final w in [
        AgentCraft.heading,
        'Knowledge and explanations',
        'Translation',
        'Code in the chat',
        'calculate',
        'When you cannot',
        'closest real thing',
        'schedule_task',
        'connect_app',
        'never invent sources',
        'no lecturing',
      ]) {
        expect(AgentCraft.block, contains(w));
      }
      expect(AgentCraft.block.length, lessThan(3000), reason: 'it rides on every request (cached), keep it lean');
      expect(AgentCraft.teamLine.length, lessThan(260));
    });
  });

  // ================================================================== H-4 localized stop reply
  group('H-4 the unknown-tool stop reply follows the user\'s language', () {
    test('Somali, Arabic, English', () {
      expect(ToolNames.stopReplyFor('so'), contains('SubMac'));
      expect(ReplyLang.detect(ToolNames.stopReplyFor('so')), 'so');
      expect(ReplyLang.detect(ToolNames.stopReplyFor('ar')), 'ar');
      expect(ToolNames.stopReplyFor(null), ToolNames.stopReply);
      expect(ToolNames.stopReplyFor('en'), ToolNames.stopReply);
      for (final l in ['so', 'ar', 'en']) {
        expect(ToolNames.stopReplyFor(l).length, lessThan(160));
      }
    });
  });

  // ================================================================== H-5 send-back ceiling
  group('H-5 a final reply is sent back at most maxSendBacks times', () {
    test('a gate that always objects cannot loop: the reply stands after the ceiling', () async {
      final h = _Hooks();
      var calls = 0;
      final core = AgentCore(
        hooks: h,
        tools: const [],
        transport: (t) async {
          calls++;
          return LlmResult('answer $calls', const [], 'stop');
        },
        gates: [(r) async => (note: 'again', hold: false)],
      );
      final res = await core.run().timeout(const Duration(seconds: 10));
      expect(res.end, RunEnd.done);
      expect(calls, FinishGateMiddleware.maxSendBacks + 1);
      expect(h.discarded, FinishGateMiddleware.maxSendBacks);
    });
  });

  // ================================================================== M-1 bubble direction
  group('M-1 code and links do not flip an Arabic reply to left-to-right', () {
    test('Arabic with a long code block stays right-to-left', () {
      final code = '```python\n${'def compute_total(items):\n    return sum(i.price for i in items)\n' * 10}```';
      expect(majorityDir('هذا هو الحل الكامل للمشكلة مع شرح قصير:\n$code'), TextDirection.rtl);
      expect(majorityDir('راجع الرابط https://www.example.com/a/very/long/english/path/that/has/many/letters/in/it'), TextDirection.rtl);
    });

    test('English with Arabic in code stays left-to-right; only code falls back to the code itself', () {
      expect(majorityDir('Here is the fix:\n```\nprint("مرحبا بالعالم من البرنامج")\n```'), TextDirection.ltr);
      expect(majorityDir('```\nمرحبا بالعالم\n```'), TextDirection.rtl);
      expect(majorityDir('Somali: Waan ku faraxsanahay inaan ku caawiyo'), TextDirection.ltr);
    });
  });

  // ================================================================== M-2 announcements in Somali and Arabic
  group('M-2 an announcement with nothing done is caught in Somali and Arabic', () {
    test('Somali', () {
      expect(Announce.only('Hadda waxaan raadinayaa macluumaadka.'), isTrue);
      expect(Announce.only('Waxaan kuu samayn doonaa warqadda.'), isTrue);
      expect(Announce.only('Aan eego.'), isTrue);
      expect(Announce.only('Waa kan jawaabta: shaahu waa caafimaad.'), isFalse);
    });

    test('Arabic', () {
      expect(Announce.only('سأبحث عن أفضل الأسعار الآن.'), isTrue);
      expect(Announce.only('دعني أتحقق من ذلك.'), isTrue);
      expect(Announce.only('جارٍ إنشاء الملف...'), isTrue);
      expect(Announce.only('هل تريد أن أبحث عن ذلك؟'), isFalse, reason: 'a question waits for the user');
      expect(Announce.only('السعر هو عشرة دولارات.'), isFalse);
    });

    test('English behaves as before', () {
      expect(Announce.only('Let me search for that.'), isTrue);
      expect(Announce.only('The price is ten dollars.'), isFalse);
    });
  });

  // ================================================================== M-3 attachments
  group('M-3 attached files say how to read them', () {
    test('Office documents point at read_document', () {
      final l = AgentCraft.attachLine('report.docx', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', '/w/uploads/report.docx');
      expect(l, contains('read_document'));
      expect(l, contains('/w/uploads/report.docx'));
      expect(l, contains('never guess'));
      expect(AgentCraft.attachLine('sales.xlsx', 'application/octet-stream', '/w/uploads/sales.xlsx'), contains('data_sheet'));
    });

    test('a file that never reached the workspace asks for it again', () {
      expect(AgentCraft.attachLine('a.docx', 'application/msword', null), contains('attach it again'));
    });

    test('audio and video: it cannot be heard or watched, so nothing is made up', () {
      expect(AgentCraft.attachLine('note.m4a', 'audio/mp4', '/w/uploads/note.m4a'), contains('cannot hear or watch'));
      expect(AgentCraft.attachLine('clip.mp4', 'video/mp4', '/w/uploads/clip.mp4'), contains('video'));
    });

    test('anything else: read it with a fitting tool, never guess', () {
      expect(AgentCraft.attachLine('x.bin', 'application/octet-stream', '/w/x.bin'), contains('never guess'));
    });
  });

  // ================================================================== M-4 math
  group('M-4 an unclosed display formula stays text', () {
    List<md.Node> parse(String s) =>
        md.Document(blockSyntaxes: [MathBlockSyntax()], inlineSyntaxes: [MathInlineSyntax()], encodeHtml: false).parse(s);
    bool hasBlock(List<md.Node> ns) => ns.any((n) => n is md.Element && (n.tag == 'mathblock' || hasBlock(n.children ?? const [])));

    test('closed formulas still render', () {
      expect(hasBlock(parse('Area:\n\n\$\$\nA = \\pi r^2\n\$\$\n\nDone.')), isTrue);
      expect(hasBlock(parse('\$\$E = mc^2\$\$')), isTrue);
      expect(hasBlock(parse('\\[\nx^2 + y^2 = z^2\n\\]')), isTrue);
    });

    test('an unclosed one does not swallow the rest of the reply', () {
      final ns = parse('Price list:\n\n\$\$\$ expensive\n\nSecond paragraph stays text.');
      expect(hasBlock(ns), isFalse);
      final text = ns.map((n) => n.textContent).join(' ');
      expect(text, contains('Second paragraph stays text.'));
    });
  });
}

class _Hooks extends CoreHooks {
  int discarded = 0;
  @override
  bool get cancelled => false;
  @override
  Future<Turn> buildTurn(int step, String? notes) async => Turn(step: step, payload: const [
        {'role': 'user', 'content': 'hi'}
      ]);
  @override
  Future<String> runTool(ToolCall call, Map<String, dynamic> args, {Object? approved}) async => 'ok';
  @override
  Future<void> discard(Reply r, {bool hold = false}) async => discarded++;
}
