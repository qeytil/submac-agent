import 'package:agent/services/somali.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Somali is recognised, English is not', () {
    for (final s in [
      'Asc walaal iska warran',
      'Waxaan rabaa inaan website u sameeyo dukaankayga',
      'haa',
      'waa fiican, mahadsanid',
      'Sidee lacag loogu diraa EVC Plus?',
      'Ma ii samayn kartaa app yar oo ganacsi?',
      'berri saacadda 3-da ii xasuusi',
    ]) {
      expect(Somali.detect(s), isTrue, reason: s);
    }
    for (final s in [
      'I want to build a website for my shop with a cart page',
      'ok',
      'Can you check the weather in Nairobi tomorrow?',
      'ha ha nice',
      'see the book',
    ]) {
      expect(Somali.detect(s), isFalse, reason: s);
    }
  });

  test('the guides carry the rules that matter', () {
    expect(Somali.chatGuide, contains('Ma iman'));
    expect(Somali.chatGuide, contains('Wacalaykum salaam'));
    expect(Somali.chatGuide, contains('Isniin'));
    expect(Somali.voiceGuide, contains('Ma ku celin kartaa'));
    expect(Somali.transcribePrompt, contains('Somali'));
    // Small enough to send every step of a Somali chat.
    expect(Somali.chatGuide.length, lessThan(12500));
    expect(Somali.voiceGuide.length, lessThan(9500));
    expect(Somali.chatGuide, contains('Never ask a user\'s clan'));
  });

  test('live transcripts that Somali turned into Spanish, Hindi or a foreign script are caught', () {
    for (final s in [
      'Hola, que tal, quiero para mañana',
      'क्या हाल है भाई',
      'mera naam hai kya',
      'Sono qui, grazie molto',
      'nataka habari sana',
    ]) {
      expect(Somali.looksMisheard(s), isTrue, reason: s);
    }
    for (final s in [
      'Asc walaal iska warran',
      'Waxaan rabaa inaan lacag u diro hooyaday EVC Plus',
      'Can you call Cali tomorrow at three?',
      'ok',
      'Maxamed iyo Xasan ma yimaadeen?',
      '',
      'هل يمكنك',
    ]) {
      expect(Somali.looksMisheard(s), isFalse, reason: s);
    }
  });

  test('the live turn prompts steer to Somali spelling', () {
    expect(Somali.liveTurnPrompt, contains('not Spanish'));
    expect(Somali.liveTurnPrompt, contains('Muqdisho'));
    expect(Somali.liveTurnPromptAuto, contains('it is Somali'));
    expect(Somali.liveTurnPrompt.length, lessThan(2500));
  });
}
