import '../../ui/i18n.dart' show AppLang;

/// Every billing string in English and Somali (PLAN 2.4). Short lines only.
///
/// `tr('Plan & usage')` returns the Somali line when the app speaks Somali, else the English key itself.
/// Placeholders: `tr('Pay {usd}', {'usd': r'$2.00'})`. Arabic comes from Dev 3's language system: until it is wired in,
/// anything that is not Somali is English.
class BillingCopy {
  BillingCopy._();

  /// Tests only. null = follow the app's language setting.
  static bool? somaliOverride;

  /// Somali only when the app's own language is Somali (Settings > Language, or "Same as phone" on a Somali phone).
  /// The reply language is a separate setting and never changes these words.
  static bool get somali => somaliOverride ?? AppLang.I.code == 'so';

  static String tr(String en, [Map<String, String> args = const {}]) {
    var s = somali ? (so[en] ?? en) : en;
    args.forEach((k, v) => s = s.replaceAll('{$k}', v));
    return s;
  }

  /// English key -> Somali. Keys are the English lines exactly as the screens use them.
  static const so = <String, String>{
    // Plan & usage
    'Plan & usage': 'Qorshe & isticmaal',
    'Today left': 'Maanta haray',
    'Total left': 'Wadarta haray',
    'Resets at': 'Dib u bilaabanaya',
    'Plan': 'Qorshe',
    'Ends': 'Dhammaanaya',
    'Being confirmed': 'Waa la xaqiijinayaa',
    'Check now': 'Hubi hadda',
    'Get more': 'Iibso dheeraad',
    'Try again': 'Isku day mar kale',
    'Payment': 'Lacag bixin',
    "You'll finish paying on Sifalo's secure page.": 'Lacag bixinta waxaad ku dhammaystiraysaa bogga sugan ee Sifalo.',
    // plans
    'Free': 'Bilaash',
    'Weekly': 'Toddobaadle',
    'Monthly': 'Bille',
    'Monthly Plus': 'Bille Plus',
    'Pay as you go': 'Bixi inta aad rabto',
    'Packages': 'Xirmooyin',
    'Nothing here yet.': 'Weli waxba ma jiraan.',
    // amounts and time
    'About {n} replies': 'Qiyaastii {n} jawaab',
    'About {n} reply': 'Qiyaastii {n} jawaab',
    '{x} a day': '{x} maalintii',
    '{x} in total': '{x} wadar ahaan',
    '{n} day': '{n} maalin',
    '{n} days': '{n} maalmood',
    '{n} months': '{n} bilood',
    '{n} min': '{n} daqiiqo',
    '{n} h': '{n} saac',
    '{h} h {m} min': '{h} saac {m} daqiiqo',
    'Valid {x}': 'Muddo: {x}',
    'Pay {usd}': 'Bixi {usd}',
    'Done. {x} added.': 'Waa la dhammeeyay. {x} ayaa lagu daray.',
    'Done. Payment received.': 'Waa la dhammeeyay. Lacagta waa la helay.',
    'Done. {x} is ready.': 'Waa la dhammeeyay. {x} waa diyaar.',
    // pay
    'Pay': 'Bixi',
    'Pay with': 'Ku bixi',
    'Card': 'Kaar',
    'Use {x}': 'Isticmaal {x}',
    'Confirming…': 'Waa la xaqiijinayaa…',
    'Close': 'Xir',
    "You're offline. We'll check again when you're back.": 'Internet ma jiro. Waan hubin doonnaa markaad soo laabato.',
    'Starting your payment': 'Lacag bixinta waa la bilaabayaa',
    'Approve on your phone': 'Ku oggolow taleefankaaga',
    'We sent {amount} to {who}. Enter your PIN to pay.': 'Codsi {amount} ah ayaan u dirnay {who}. Geli PIN-kaaga si aad u bixiso.',
    'Still waiting for your approval…': 'Weli waxaan sugaynaa oggolaanshahaaga…',
    'No prompt? Check your number.': 'Fariin ma timid? Hubi lambarkaaga.',
    'Secure payment': 'Lacag bixin ammaan ah',
    'Confirming your payment': 'Lacagtaada waa la xaqiijinayaa',
    'Not confirmed yet': 'Weli lama xaqiijin',
    'You can leave this screen.': 'Shaashaddan waad ka bixi kartaa.',
    'Not enough money': 'Lacag kuma filna',
    'Payment timed out': 'Waqtigii wuu dhammaaday',
    "Payment didn't go through": 'Lacag bixintu ma dhicin',
    'No answer yet': 'Weli jawaab ma jirto',
    "You're offline": 'Internet ma jiro',
    "Couldn't start the payment": 'Lacag bixinta lama bilaabi karin',
    'Open the payment page again': 'Mar kale fur bogga lacag bixinta',
    'Choose another way to pay': 'Dooro hab kale oo lacag bixin',
    'wallet': 'boorsada',
    // limit sheet / notices
    'Ready. Try your message again.': 'Diyaar. Fariintaada mar kale dir.',
    'Still being confirmed.': 'Weli waa la xaqiijinayaa.',
    'Checking…': 'Waa la hubinayaa…',
    'Check my payment': 'Hubi lacagtayda',
    'OK': 'Hagaag',
    'Not now': 'Hadda maya',
    'Details': 'Faahfaahin',
    "You've used today's replies.": 'Jawaabaha maanta waad dhammaysay.',
    'Bots have used their share for today.': 'Bot-yadu qaybtoodii maanta way dhammaysteen.',
    "You've used all your replies.": 'Dhammaan jawaabahaagii waad isticmaashay.',
    'You need a plan for this.': 'Tan waxaad u baahan tahay qorshe.',
    'Telesia is busy. Try again soon.': 'Telesia waa mashquul. Dhawaan isku day.',
    "This reply couldn't be sent.": 'Jawaabtan lama dirin.',
    'Resets at midnight.': 'Saqda dhexe ayuu dib u bilaabanayaa.',
    'Resets at {t} (in {d}).': 'Dib u bilaabanaya {t} ({d} kadib).',
    // card page
    'Cancel payment?': 'Ma joojinaysaa lacag bixinta?',
    'Keep paying': 'Sii wad lacag bixinta',
    'Cancel payment': 'Jooji lacag bixinta',
    "If you already paid, it still counts. We'll check before you leave.":
        'Haddii aad bixisay, way xisaabsan tahay. Waan hubin doonnaa intaadan bixin.',
    "You're offline. Check your connection and try again.": 'Internet ma jiro. Hubi xiriirka oo mar kale isku day.',
    "We haven't received this payment yet. If you just paid, give it a minute.":
        'Lacagtan weli nama soo gaarin. Haddii aad hadda bixisay, sug daqiiqad.',
    "Couldn't load the payment page": 'Bogga lacag bixinta lama furi karin',
    'Check your connection, then try again. If you already paid, it still counts.':
        'Hubi xiriirka, kadibna isku day. Haddii aad bixisay, way xisaabsan tahay.',
    "I've paid, check now": 'Waan bixiyay, hubi hadda',
    'Checking your payment…': 'Lacagtaada waa la hubinayaa…',
    // payment outcomes (PayText)
    'Not enough money in your wallet. Nothing was taken.': 'Lacag kuguma filna boorsadaada. Waxba lagaama jarin.',
    'Payment declined or cancelled. Nothing was taken.': 'Lacag bixinta waa la diiday ama waa la joojiyay. Waxba lagaama jarin.',
    'Payment timed out. Nothing was taken.': 'Waqtigii wuu dhammaaday. Waxba lagaama jarin.',
    'This payment was refunded.': 'Lacagtan waa lagu celiyay.',
    "Payments are slow right now. If you approved, it's added in a few minutes.":
        'Lacag bixintu hadda way gaabinaysaa. Haddii aad oggolaatay, dhowr daqiiqo kadib ayaa lagu darayaa.',
    "Payments aren't available right now. Nothing was taken.": 'Lacag bixin hadda ma shaqaynayso. Waxba lagaama jarin.',
    "Couldn't start this payment. Nothing was taken.": 'Lacag bixintan lama bilaabi karin. Waxba lagaama jarin.',
    'Too many tries. Wait a minute.': 'Isku day badan. Sug daqiiqad.',
    'Tap Try again to start a new payment.': 'Taabo "Isku day mar kale" si aad u bilowdo lacag bixin cusub.',
    "We couldn't match this payment. If money was taken, contact support.":
        'Lacagtan lama waafajin karin dalabkaaga. Haddii lacag lagaa jaray, la xiriir taageerada.',
    "That number doesn't look right.": 'Lambarkaasi ma saxna.',
    'Choose EVC Plus, ZAAD, SAHAL, eDahab or Premier Wallet.': 'Dooro EVC Plus, ZAAD, SAHAL, eDahab ama Premier Wallet.',
    "That isn't available any more.": 'Taasi hadda lama heli karo.',
    'Please sign in again.': 'Fadlan mar kale gal.',
    "You're offline. Try again: you won't be charged twice.": 'Internet ma jiro. Isku day mar kale: laba jeer lagaa jari maayo.',
    'No answer in time. If you approved, it still counts.': 'Jawaab waqtigeeda kuma imaan. Haddii aad oggolaatay, way xisaabsan tahay.',
    'Payments are busy. Try again shortly.': 'Lacag bixintu waa mashquul. Dhawaan isku day.',
    "We couldn't find this payment.": 'Lacagtan lama helin.',
    'Starting your payment…': 'Lacag bixinta waa la bilaabayaa…',
    'Approve with your PIN on your phone.': 'Ku oggolow PIN-kaaga taleefanka.',
    'Finish on the secure page.': 'Ku dhammee bogga ammaanka ah.',
    'Confirming your payment…': 'Lacagtaada waa la xaqiijinayaa…',
    'Not heard back yet. If you approved, tap Check now.': 'Weli jawaab ma helin. Haddii aad oggolaatay, taabo Hubi hadda.',
    'Payment received.': 'Lacagta waa la helay.',
    "Payment didn't go through. Nothing was taken.": 'Lacag bixintu ma dhicin. Waxba lagaama jarin.',
    "You're offline. Try again when you're back.": 'Internet ma jiro. Isku day markaad soo laabato.',
    'Something went wrong. Nothing was charged.': 'Wax baa khaldamay. Waxba lagaama jarin.',
    // wallet number
    'Enter your wallet number.': 'Geli lambarka boorsadaada.',
    'Use digits only, like 61 234 5678.': 'Tirooyin kaliya, sida 61 234 5678.',
    'This number is too short.': 'Lambarkani waa gaaban yahay.',
    'This number is too long.': 'Lambarkani waa dheer yahay.',
    "This doesn't look like a Somali mobile number.": 'Kani uma eka lambar mobile Soomaaliyeed.',
    'This looks like a {x} number. Make sure it has {y}.': 'Kani wuxuu u eg yahay lambar {x}. Hubi inuu leeyahay {y}.',
    // activity
    'Paid': 'La bixiyay',
    'Payment being confirmed': 'Lacag la xaqiijinayo',
    'Payment not completed': 'Lacag aan dhammaystirmin',
    'Payment refunded': 'Lacag la celiyay',
    'Taken back': 'La celiyay',
    'Added': 'La daray',
    // account deletion (shown by the delete-account dialog)
    'You still have {x} you paid for. Deleting your account loses it.':
        'Weli waxaad haysataa {x} aad lacag ku bixisay. Haddii aad akoonka tirtirto, way lumaysaa.',
    'A payment is still being confirmed.': 'Lacag bixin weli waa la xaqiijinayaa.',
  };
}

/// Shorthand for [BillingCopy.tr].
String tr(String en, [Map<String, String> args = const {}]) => BillingCopy.tr(en, args);
