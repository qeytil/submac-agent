/// Ready-made skills for everyday people. Picking one puts it in the composer as a chip;
/// the next message is answered with that skill's instructions.
class Skill {
  final String id;
  final String name;
  final String blurb;
  final String category;

  /// Instructions added for the message sent with this skill.
  final String instruction;

  /// What gets sent when the user taps send with only the chip.
  final String starter;

  /// prompt | scan | translate | meeting | research
  final String kind;
  final bool featured;
  const Skill(this.id, this.name, this.blurb, this.category, this.instruction,
      {this.starter = '', this.kind = 'prompt', this.featured = false});
}

class SkillsCatalog {
  SkillsCatalog._();

  static const categories = ['Featured', 'Documents', 'Writing', 'Faith', 'Money', 'Business', 'Study', 'Phone', 'Web'];

  static Skill? byId(String id) {
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }

  static List<Skill> inCategory(String c) =>
      c == 'Featured' ? all.where((s) => s.featured).toList() : all.where((s) => s.category == c).toList();

  /// The few shown as chips over the composer on an empty chat.
  static const quick = ['doc', 'scan', 'translate', 'prayer', 'meeting', 'research', 'money', 'whatsapp', 'shop', 'study'];

  static const all = <Skill>[
    // Documents
    Skill('doc', 'Document', 'CV, invoice, letter, receipt as a real file', 'Documents',
        'Make a real document file with make_document (PDF unless they ask for Word). Ask only for what is missing, in one short message, then make it. Clean, professional layout.',
        starter: 'Help me make a document.', featured: true),
    Skill('cv', 'CV / Resume', 'A clean one-page CV', 'Documents',
        'Make a professional one-page CV as a PDF (and Word if asked). Ask for name, contact, experience, education and skills in one message; write strong, honest bullet points.',
        starter: 'Make my CV.'),
    Skill('invoice', 'Invoice', 'Numbered, with totals and your logo name', 'Documents',
        'Make an invoice PDF: invoice number, date, seller and buyer, items with quantity and price, subtotal, discount, total, payment details. Ask only for missing details.',
        starter: 'Make an invoice.'),
    Skill('receipt', 'Receipt', 'For a sale or payment', 'Documents',
        'Make a simple receipt PDF with number, date, payer, items, total and "Paid". Ask only for missing details.',
        starter: 'Make a receipt.'),
    Skill('letter', 'Formal letter', 'Application, request, complaint', 'Documents',
        'Write a formal letter and make it a PDF. Ask who it is to and the purpose, then write it politely and clearly.',
        starter: 'Write a formal letter.'),
    Skill('slides', 'Slides', 'A short presentation', 'Documents',
        'Make a slide deck with make_document (slides). Ask the topic, audience and number of slides; keep each slide to a title and 3-5 short points.',
        starter: 'Make a presentation.'),
    Skill('sheet', 'Spreadsheet', 'A table you can open in Excel', 'Documents',
        'Make an Excel file with make_document (xlsx) with clear headers and totals where useful.',
        starter: 'Make a spreadsheet.'),
    Skill('scan', 'Scan to PDF', 'Photos of pages into one PDF', 'Documents', '', kind: 'scan', featured: true),
    Skill('certificate', 'Certificate', 'Award or completion certificate', 'Documents',
        'Make an elegant certificate PDF (landscape). Ask the name, what it is for, the date and who signs it.',
        starter: 'Make a certificate.'),

    // Writing
    Skill('whatsapp', 'WhatsApp message', 'Say it well, ready to send', 'Writing',
        'Write a WhatsApp message they can send as is, in a ```draft card. Ask who it is for and what they want to say if unclear. Warm, short, natural.',
        starter: 'Help me write a WhatsApp message.', featured: true),
    Skill('email', 'Email', 'Clear and polite', 'Writing',
        'Write an email in a ```draft card with a Subject line. Clear, polite, short.',
        starter: 'Help me write an email.'),
    Skill('post', 'Social post', 'Facebook, TikTok, Instagram', 'Writing',
        'Write a social media post with a strong first line and a few hashtags, in a ```draft card. Offer two versions when useful.',
        starter: 'Write a post for me.'),
    Skill('fix', 'Fix my writing', 'Grammar and tone, same meaning', 'Writing',
        'Correct grammar, spelling and tone while keeping the meaning and their voice. Show the fixed text in a ```draft card.',
        starter: 'Fix this text: '),
    Skill('summarize', 'Summarize', 'Long text or file, made short', 'Writing',
        'Summarize the text or file they give: the main point first, then key points. Short and plain.',
        starter: 'Summarize this: '),
    Skill('translate', 'Translate', 'Speak and hear it back', 'Writing', '', kind: 'translate', featured: true),
    Skill('translate_text', 'Translate text', 'Somali, English, Arabic and more', 'Writing',
        'Translate their text accurately and naturally. If the target language is unclear, ask once.',
        starter: 'Translate this: '),

    // Faith
    Skill('prayer', 'Prayer times', 'Today, with the Hijri date', 'Faith',
        'Use prayer_times and hijri_date. Ask the city if unknown. Show the five prayers clearly and the next one first.',
        starter: 'What are today\'s prayer times?', featured: true),
    Skill('quran', 'Quran', 'Arabic with Somali or English', 'Faith',
        'Use the quran tool to show the verse in Arabic with the translation in their reply language. Never invent verses.',
        starter: 'Show me a verse from the Quran.'),
    Skill('qibla', 'Qibla', 'The direction to pray', 'Faith',
        'Use the qibla tool for their location and explain the direction simply (degrees from north).',
        starter: 'Which way is the Qibla?'),

    // Money
    Skill('money', 'Money notebook', 'Sales, spending and debts', 'Money',
        'Use money_add and money_report. Show this month\'s money in and out, then help add today\'s entries.',
        starter: 'Open my money notebook.', featured: true),
    Skill('debts', 'Who owes me', 'Track debts and reminders', 'Money',
        'Use the money notebook to list debts (owed to them and by them) and offer friendly reminder messages.',
        starter: 'Who owes me money?'),
    Skill('budget', 'Monthly budget', 'Plan what to spend', 'Money',
        'Help plan a simple monthly budget from their income and costs; show it as a table and offer an Excel file.',
        starter: 'Help me plan my monthly budget.'),

    // Business
    Skill('shop', 'Shop page', 'With WhatsApp order buttons', 'Business',
        'Build a mobile shop page as a ```page card with products, prices and a WhatsApp order button per product, plus a ```qr card. Ask shop name, products, prices and WhatsApp number.',
        starter: 'Make a page for my shop.', featured: true),
    Skill('product', 'Product description', 'Words that sell', 'Business',
        'Write short, honest product descriptions that sell, with a headline and 3 benefits.',
        starter: 'Write a description for my product: '),
    Skill('plan', 'Business plan', 'A simple plan you can share', 'Business',
        'Write a simple business plan (idea, customers, costs, prices, first steps) and offer it as a PDF.',
        starter: 'Help me write a business plan.'),
    Skill('pricelist', 'Price list', 'Neat list for customers', 'Business',
        'Make a neat price list PDF. Ask for items and prices.',
        starter: 'Make a price list.'),

    // Study
    Skill('study', 'Study buddy', 'Learn step by step, then a quiz', 'Study',
        'Teach step by step at their level, with short examples, then quiz them one question at a time.',
        starter: 'Be my study buddy.', featured: true),
    Skill('homework', 'Homework help', 'Explain, don\'t just answer', 'Study',
        'Help with homework by explaining the steps clearly; give the final answer after the explanation.',
        starter: 'Help me with my homework: '),
    Skill('explain', 'Explain simply', 'Any topic in plain words', 'Study',
        'Explain the topic in plain words with one everyday example. Short.',
        starter: 'Explain simply: '),

    // Phone
    Skill('meeting', 'Record a meeting', 'Notes and who does what', 'Phone', '', kind: 'meeting', featured: true),
    Skill('missed', 'What did I miss?', 'Notifications, summed up', 'Phone',
        'Use read_notifications. Summarize what matters most first; group the rest.',
        starter: 'What did I miss?'),
    Skill('briefing', 'Morning briefing', 'Every day at your time', 'Phone',
        'Set up a daily scheduled task: weather, prayer times, top news and the day ahead. Ask city and time first.',
        starter: 'Set up a morning briefing.'),
    Skill('clean', 'Clean my phone', 'Big and duplicate files', 'Phone',
        'Find big and duplicate files in shared storage and list them; never delete without asking.',
        starter: 'Help me clean my phone.'),
    Skill('watch', 'Tell me when…', 'A price, a job, a reply', 'Phone',
        'Create a watcher with schedule_task (watch:true) that only notifies on change. Ask what to watch and how often.',
        starter: 'Tell me when '),

    // Web
    Skill('research', 'Deep research', 'Many sources, one clear report', 'Web', '', kind: 'research', featured: true),
    Skill('compare', 'Compare prices', 'Find the best deal online', 'Web',
        'Search several shops with the browser (use tabs), compare price, delivery and reviews in a table, and pick one.',
        starter: 'Compare prices for '),
    Skill('form', 'Fill a form online', 'Applications, sign-ups', 'Web',
        'Use the browser to fill the online form step by step. Ask for missing details; ask before submitting.',
        starter: 'Fill this form for me: '),
    Skill('news', 'News today', 'What matters, in short', 'Web',
        'Give today\'s top news (Somalia and the world unless they say otherwise) in short lines with sources in links.',
        starter: 'What is the news today?'),
  ];
}
