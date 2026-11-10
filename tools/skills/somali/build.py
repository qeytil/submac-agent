import json
S=[]
def k(id,name,cat,sub,desc,tags,powers,body,level='basic'):
    S.append(dict(id=id,name=name,cat=cat,sub=sub,desc=desc,tags=tags,powers=powers,level=level,v=1,body=body.strip()+"\n"))
SAFE_INFO="Information only: say so once, briefly, and point to the right office or person for anything binding."

k('so-somali-writing','Write natural Somali','somalia','Language',
 'Reply and write in clear, natural Somali (and understand Somali typed in Latin letters, mixed with English, or with Maay words).',
 ['somali','af soomaali','maay','language','translate','turjun','qoraal'],[],
"""## When to use
The user writes in Somali, asks for Somali text (post, letter, message, explanation) or a translation to or from Somali.

## How
1. Answer in the user's language. If they mix Somali and English, reply in Somali and keep technical words they used in English.
2. Use standard Somali spelling: double vowels (aa, ee, ii, oo, uu), x for the Arabic ḥ, c for ʿayn, kh, dh, sh. Keep it short and plain; avoid literal word-for-word English.
3. Understand Maay and regional words; reply in standard Somali unless the user writes fully in Maay.
4. Tone: respectful and warm. Formal letters open with "Mudane/Marwo ..." and close with "Mahadsanid"; Islamic greetings are fine when the user uses them.
5. Numbers, dates and money: write amounts as digits with the currency ($, Shilin). Use the Gregorian date, adding the Hijri date only for religious events.
6. Translation: keep the meaning and the tone, not the word order. For legal, medical or official text, add one line that a person should check the final copy.

## Quality bar
A Somali reader would think a fluent person wrote it: natural word order, correct spelling, no awkward calques.
""")

k('so-mobile-money-book','Mobile money bookkeeping','somalia','Business',
 'Keep a simple money book of EVC Plus, Zaad, e-Dahab, Sahal and cash: sales, expenses, debts, and daily or monthly totals.',
 ['evc','evc plus','zaad','edahab','e-dahab','sahal','mobile money','lacag','bookkeeping','xisaab','sales','dayn','debt','expenses'],['money'],
"""## When to use
A shop owner, trader or family wants to track money in and out, often from mobile money SMS messages.

## Steps
1. Ask once what to track (shop sales, household, one business) and the main currency (USD is common; Somali shillings for small amounts).
2. Record each entry with money_add: type (in, out, owed_to_me, i_owe), amount, what for, who, and the wallet (EVC Plus, Zaad, e-Dahab, Sahal, bank or cash) in the note.
3. When the user pastes or photographs payment SMS messages, read the amount, sender or receiver, and date from each one (read_text_in_image for photos). Confirm the list in one line, then add the entries.
4. For totals, use money_report: today, this week or this month; money in versus out; profit; who owes what. Show the three numbers that matter first.
5. Debts (dayn): list who owes, how much and since when. Offer a polite reminder message in Somali that the user can send themselves.
6. Monthly: offer a one-page summary (make_document) with totals by category and wallet.

## Quality bar
Every number traces back to an entry, totals add up, and nothing is invented. Ask when an SMS is unclear.

## Safety
Never ask for a PIN or wallet password. Never send money or messages on your own.
""")

k('so-shop-sales-debts','Shop daily sales and debts','somalia','Business',
 'Run a small shop day to day: daily sales, stock to reorder, customers who buy on credit, and end-of-day totals.',
 ['shop','dukaan','tukaan','sales','iib','stock','alaab','credit','dayn','customers','macmiil'],['money','files'],
"""## When to use
A shopkeeper wants help with the day: what sold, what to reorder, who owes.

## Steps
1. Keep the stock list in a file (write_file `shop/stock.csv`: item, unit price, quantity, reorder level). Ask for the first list, or read it from a photo.
2. Sales: add each sale or the day's total with money_add (type in). Reduce stock with edit_file when the user says what sold.
3. Credit customers: money_add type owed_to_me with the customer's name. At day end, list open debts, oldest first.
4. End of day ("xisaabta maanta"): money in, money out, profit estimate, the top 3 items sold, items below reorder level.
5. Reorder list: group items by supplier with quantities. Offer a Somali message for the supplier.
6. Offer a daily reminder at closing time with schedule_task, if they want it.

## Quality bar
Short, clear numbers in Somali or English, as the user prefers. Nothing invented. Ask when a quantity is missing.
""")

k('so-invoice-receipt','Invoices and receipts','somalia','Business',
 'Make clean invoices, receipts and quotations in Somali and/or English as PDF, with mobile money payment details.',
 ['invoice','receipt','rasiid','quotation','qiimeyn','bill','pdf','biil'],['documents'],
"""## Ask first
Business name and phone, the customer's name, items (name, quantity, price), currency, and whether to show mobile money numbers for payment (EVC Plus, Zaad, e-Dahab, Sahal; a merchant number if they have one).

## Steps
1. Number the invoices in order (keep the last number in memory with remember, e.g. INV-0012).
2. Build it with make_document as a PDF: logo or name at the top, date, invoice number, customer, an item table, subtotal, discount, total, payment details, and a thank-you line ("Mahadsanid ganacsigaaga").
3. Bilingual by default when customers include non-Somali speakers: Somali first, English under it.
4. Receipts: the same layout marked "Rasiid / Receipt" and "PAID", with the payment method and the transaction reference if the user gives one.
5. Quotations: add a validity date (e.g. 7 days).

## Quality bar
Totals double-checked with calculate, with no empty fields and no placeholders left.
""")

k('so-sell-on-social','Sell on Facebook, TikTok and WhatsApp','somalia','Marketing',
 'Write product posts, captions, price lists and replies that sell, in Somali and English, for local Facebook, TikTok and WhatsApp buyers.',
 ['facebook','tiktok','whatsapp','instagram','post','caption','marketing','iibi','xayeysiis','ads','status'],['web'],
"""## Steps
1. Ask what they sell, the price, the area (city or neighbourhood), and how buyers order (WhatsApp number, shop location, delivery).
2. Write 3 short options: a hook line, the benefit, the price, and how to order. Use Somali first; add English for diaspora or mixed audiences. Add a few local hashtags (city name, product).
3. TikTok or Reels: a 15-30 second script (hook in the first 2 seconds, show the product, price, call to action) plus an on-screen text line.
4. WhatsApp status and catalog: one line per product with the price, plus a short welcome reply and an FAQ (delivery, payment by mobile money, returns).
5. Offers: Eid, Ramadan, back-to-school and wedding season promos fit local buying peaks.
6. Never post for them unless they ask. Posting goes through the approval card.

## Quality bar
Short, honest and specific (real price, real place). No fake reviews, no false claims.
""")

k('so-import-costing','Import cost and pricing','somalia','Business',
 'Work out the real landed cost of goods from Dubai, China, Turkey or Kenya (price, freight, duties, fees) and a selling price with margin.',
 ['import','dubai','china','turkey','freight','shipping','customs','canshuur','landed cost','margin','faa\'iido','wholesale'],['web'],
"""## Steps
1. Collect: item cost and quantity, the supplier's currency, shipping method (sea container, air cargo, road), the port or airport (Mogadishu, Berbera, Bosaso, Kismayo), and their usual clearing agent cost if known.
2. Convert currencies with currency_convert (today's rate) and say the rate used.
3. Landed cost = goods + freight + insurance + customs duty + port and clearing fees + local transport, then divided by units. Duty rates differ by region and item: ask the user's agent or check official sources with web_search, and mark any estimate clearly as an estimate.
4. Selling price: show 2-3 margin options (e.g. 15%, 25%, 35%) and the break-even price.
5. Compare with local market prices if the user gives them.
6. Put the result in a small table. Offer to save it as a file for the next order.

## Quality bar
Each line of cost shown; estimates labelled; math checked with calculate.
""")

k('so-business-plan-simple','Simple business plan and loan pitch','somalia','Business',
 'Turn an idea into a one-to-five page plan for a microfinance, Islamic finance (murabaha, mudaraba) or investor application.',
 ['business plan','qorshe ganacsi','loan','deyn','microfinance','murabaha','mudaraba','investor','startup','grant'],['documents','web'],
"""## Steps
1. Ask a few short questions: what they sell, to whom, where, startup costs, expected monthly sales and costs, what they already have, and how much they need.
2. Write the plan: summary, the problem and the offer, customers and market (local facts, no invented statistics), competition, operations, the team, the money (startup cost table, 12-month simple projection, break-even), risks and how they are handled, and the ask.
3. Islamic finance: describe the deal in the right terms (murabaha cost-plus purchase, mudaraba profit share, ijara lease). Keep interest wording out of it.
4. Grants and NGO programmes: match the language to the call (youth, women, agriculture) and keep within the word limits.
5. Deliver with make_document (PDF or DOCX) in Somali or English, as the funder needs.

## Quality bar
Numbers add up and are clearly assumptions; plain words; no made-up market data. Use web_search for real figures and cite where they came from.
""")

k('so-family-budget-remit','Family budget and remittances','somalia','Money',
 'Plan a household budget, track family support sent or received, and compare remittance options and fees.',
 ['budget','miisaaniyad','remittance','xawaalad','hawala','dahabshiil','amal','taaj','family','qoys','send money'],['money','web'],
"""## Steps
1. Budget: list monthly income (salary, business, money received from abroad) and fixed costs (rent, school fees, food, water, electricity, phone or internet). Use money_add for real entries.
2. Suggest a simple split: essentials, savings or emergencies, family support, zakat or sadaqah. Keep it realistic for their income.
3. Remittances (xawaalad): for a given amount and corridor, compare fees and exchange rates of the services they use. Check current fees with web_search or the provider's site, and say when a figure is not confirmed.
4. Diaspora senders: a monthly plan for who gets what, with a reminder (schedule_task) on the sending day.
5. Monthly check: money_report, then 3 plain findings ("food went up 20%").

## Safety
Never ask for account PINs. Never move money. Treat other family members' details privately.
""")

k('so-hagbad-savings','Hagbad savings group tracker','somalia','Money',
 'Run a hagbad (ayuuto) rotating savings group: members, contribution, payout order, who paid, and reminders.',
 ['hagbad','ayuuto','savings group','keyd','rotating savings','members','contribution'],['files'],
"""## Steps
1. Set up: group name, members, contribution amount, how often (weekly or monthly), start date, and payout order (agreed or by draw).
2. Keep a table file (write_file `hagbad/<group>.csv`: round, date, receiver, then each member paid or not).
3. Each round: mark payments as the user reports them, show who is still missing, and the receiver of this round.
4. Reminders: offer a schedule_task before each due date, and a polite Somali message the organiser can send to the group.
5. Draw: if the group wants a random order, make it with a clear method and save it.
6. End: a summary showing everyone paid and received equally.

## Quality bar
Fair and transparent: totals per member always equal across the cycle.
""")

k('so-form4-exam-tutor','Form 4 and national exam tutor','somalia','Education',
 'Help secondary students prepare for national Form 4 exams: subject revision, practice questions, past-paper style drills, explained in Somali or English.',
 ['form 4','imtixaan','exam','shahaado','secondary','dugsi sare','math','xisaab','physics','chemistry','biology','revision'],['web'],
"""## Steps
1. Ask the subject, the exam date, which curriculum or region exam they sit, and the language of the exam (Somali, English or Arabic).
2. Make a short study plan to the exam date (topics per day, revision days, rest). Offer reminders with schedule_task.
3. Teach one topic at a time: a simple explanation in the student's language, one worked example, then 3-5 practice questions from easy to hard.
4. Mark their answers: what was right, the exact mistake, and the correct method. Never just give answers to homework they must submit; guide them to solve it.
5. Math and science: show every step; check with calculate. Use local examples (shillings, camels, market prices) to make ideas concrete.
6. Before the exam: a mixed mock test with a time limit, then a score and the topics to fix.

## Quality bar
Correct content, patient tone, short steps. Say when a topic is outside the syllabus or you're not sure.
""")

k('so-homework-from-photo','Explain homework from a photo','somalia','Education',
 'Read a photo of a page, worksheet or textbook and explain it step by step in Somali or English, for students or parents helping kids.',
 ['homework','layli','photo','sawir','worksheet','textbook','buug','explain','parents','waalid'],['vision'],
"""## Steps
1. Read the page (read_text_in_image, or look at the image directly). If parts are unreadable, ask for a clearer photo of just that part.
2. Ask who it is for: the student, or a parent who wants to help their child.
3. Explain the idea first in simple words, then solve one question together step by step. Let the student try the rest, then check their work.
4. For parents: a short guide in Somali on how to explain it at home, with an everyday example.
5. Languages: translate English or Arabic textbook terms into Somali with the original word kept in brackets.

## Quality bar
The student understands the method, not just the answer.
""")

k('so-english-coach','English coach for Somali speakers','somalia','Education',
 'Practical English for Somali speakers: everyday speaking, work and NGO English, IELTS and Duolingo English Test practice, with explanations in Somali.',
 ['english','ingiriis','ielts','duolingo','toefl','speaking','grammar','vocabulary','interview english'],[],
"""## Steps
1. Find their level and goal with 3 quick questions (or a 5-question mini test): daily life, a job, university, a visa or an exam.
2. Each session: 5 useful phrases for their goal, one grammar point explained in Somali with examples, then a short practice dialogue they answer.
3. Correct gently: show their sentence, the correct one, and why, in one line each. Watch for common Somali-speaker slips (articles a/the, p and b sounds, word order, verb tenses).
4. IELTS or DET: timed practice tasks (writing task 2 essay, speaking part 2 cue card), scored roughly against the public band descriptors, with 3 fixes.
5. Offer a daily 10-minute practice with schedule_task.

## Quality bar
Encouraging, practical, and short sessions. Real progress over long theory.
""")

k('so-scholarship-apply','Scholarships for Somali students','somalia','Education',
 'Find scholarships open to Somali students, check eligibility and deadlines, and write strong motivation letters and applications.',
 ['scholarship','deeq waxbarasho','university','jaamacad','masters','bachelor','motivation letter','turkey','study abroad'],['web','documents'],
"""## Steps
1. Ask: level (bachelor, master, PhD, short course), field, grades, English or other language test, budget, and preferred countries or online study.
2. Search current calls with web_search and fetch_url on official pages only (government scholarship portals, universities, recognised foundations). Check that Somali citizens are eligible and the deadline has not passed.
3. Give a short table: name, country, level, what it covers, deadline, official link. Never list an opportunity you could not verify on its official page.
4. Write the motivation letter or personal statement from the student's real story: background, goals, why this field, and how it helps Somalia. No clichés, within the word limit.
5. A checklist of documents (transcripts, passport, recommendation letters, language certificate) and reminders before each deadline with schedule_task.

## Safety
Warn about scams: real scholarships never ask for an application fee through a personal mobile money number.
""")

k('so-teacher-kit','Teacher lesson kit','somalia','Education',
 'Lesson plans, worksheets, quizzes, marking schemes and report comments for teachers in Somali schools, in Somali, English or Arabic.',
 ['teacher','macallin','lesson plan','casharka','quiz','worksheet','marking','school','dugsi'],['documents'],
"""## Steps
1. Ask the subject, the class or grade, the topic, the lesson length and the language of instruction.
2. Lesson plan: objectives, a warm-up, explanation with local examples, an activity (pairs or groups, low-resource: no projector needed), a check for understanding, and homework.
3. Worksheets and quizzes: mixed questions (multiple choice, short answer, one problem), plus an answer key and marking scheme.
4. Big classes: tips for 60+ students (group roles, quick checks).
5. Report comments: short, kind, specific comments per student from the marks the teacher gives.
6. Deliver as a printable PDF or DOCX with make_document.

## Quality bar
Accurate content, age-right language, printable on one or two pages.
""")

k('so-jobs-cv-ngo','Jobs, CV and interviews','somalia','Jobs',
 'Find jobs in Somalia and remotely, write a CV and cover letter for NGO, UN, telecom, bank and government roles, and practise interviews.',
 ['job','shaqo','cv','resume','cover letter','ngo','un','interview','wareysi','vacancy','somalijobs','reliefweb'],['web','documents'],
"""## Steps
1. Ask what role and city (or remote), their experience, education and languages.
2. Find openings with web_search on job boards used in Somalia and international NGO and UN sites. Show the title, organisation, location, deadline and link. Only list jobs you could open.
3. CV: a clean two-page layout (make_document) with a profile, experience with results, education, skills, languages (Somali, English, Arabic), and referees available on request. Match keywords from the job ad.
4. Cover letter: specific to the role, one page, with 3 achievements that fit the ad.
5. Interview practice: 8 likely questions (including competency questions in STAR format), then feedback on their answers.
6. Deadline reminders with schedule_task.

## Safety
Warn about job scams that ask for fees or personal documents up front.
""")

k('so-freelance-start','Start freelancing online','somalia','Jobs',
 'Get started on Upwork, Fiverr and remote work from Somalia: pick a service, build a profile, write proposals, price work and receive payment.',
 ['freelance','upwork','fiverr','remote work','online work','shaqo online','proposal','portfolio','payoneer'],['web'],
"""## Steps
1. Find their best sellable skill (writing, translation Somali-English, design, video editing, data entry, coding, virtual assistance).
2. Profile: title, overview (client benefit first), 3 portfolio samples (offer to help make them), and a fair starting price.
3. Proposals: short, specific to the job post, with a question back to the client. Make 2 templates they adapt.
4. Payments: explain options that work for their country, checked with web_search on the platform's own help pages, since availability changes. Never guess.
5. A daily routine: how many proposals to send, and how to follow up.

## Safety
Never accept work that asks for payment first, off-platform payments from strangers, or account renting.
""")

k('so-gov-papers','Government papers guide','somalia','Civic',
 'Step-by-step guidance for common papers: national ID, passport, birth certificate, business licence, driving licence, with what to bring and where.',
 ['passport','baasaboor','national id','aqoonsi','nira','birth certificate','shahaado dhalasho','business licence','ruqsad','driving licence'],['web'],
"""## Steps
1. Ask which paper, for whom, and which region or city, since steps differ between federal member states and Somaliland.
2. Find the current steps, fees and documents on the official site of the authority with web_search and fetch_url. Prefer official pages and say when information could not be confirmed there.
3. Give a short checklist: documents to bring, fee (if confirmed), where to go, opening days, and how long it usually takes.
4. Online applications: guide them through the official portal. Use browser_task only if they ask, and never enter details they did not give.
5. Offer a reminder for appointments or pick-up dates.

## Safety
""" + SAFE_INFO + """ Warn against middlemen asking for extra fees.
""")

k('so-simple-agreements','Simple written agreements','somalia','Civic',
 'Draft simple, clear agreements in Somali and English for everyday deals: room rental, sale of goods or a vehicle, loans between people, partnerships, with witnesses.',
 ['agreement','heshiis','contract','rental','kiro','sale','iib','loan','amaah','partnership','shuraako','witness','markhaati'],['documents'],
"""## When to use
Everyday deals between people who want them in writing. Large property, land, company or court matters belong with a lawyer or notary: say so and offer a summary they can take to one.

## Steps
1. Ask: who the parties are (names, phone, ID number if they want), what is agreed, amount and payment schedule (mobile money or cash), dates, what happens if someone doesn't pay or wants to end it, and witnesses.
2. Write plain clauses in Somali first, then English if needed. Number each clause. Use clear dates and amounts written in digits and words.
3. Loans: the amount, repayment dates and no interest wording unless the user asks; many users prefer Islamic-compliant terms.
4. Add signature lines for both parties and two witnesses, plus a date and place.
5. Deliver as PDF or DOCX with make_document.

## Safety
""" + SAFE_INFO + """
""")

k('so-faraid-calculator','Islamic inheritance (faraid) calculator','somalia','Faith',
 'Work out the fixed Islamic inheritance shares (faraid) for a family case, show the math, and explain it in Somali.',
 ['faraid','dhaxal','inheritance','mirath','shares','will','dardaaran','islamic'],[],
"""## Steps
1. Ask carefully who survived the deceased: spouse(s), sons, daughters, father, mother, grandparents, brothers and sisters (full, paternal or maternal). Ask about debts, funeral costs and any will (wasiyya, max one third, not to heirs).
2. Order: pay funeral costs and debts, then a valid wasiyya, then divide the rest.
3. Apply the Quranic fixed shares (e.g. wife 1/8 with children, 1/4 without; husband 1/4 with children, 1/2 without; mother 1/6 with children; sons and daughters as residuaries with a 2:1 ratio). Handle exclusion (hajb), aul (shares exceed the whole) and radd (shares fall short) correctly.
4. Show a table: heir, share fraction, percentage, and amount for the estate value given. Check that it sums to 100% with calculate.
5. Explain each share in simple Somali.

## Safety
End with one line: confirm with a trusted scholar or the court before dividing property, especially with complex or disputed cases.
""", level='advanced')

k('so-seasons-farming','Weather, seasons and farming','somalia','Farming',
 'Rain and drought outlook for the Gu and Deyr seasons, planting and water advice, and daily weather for farmers and herders.',
 ['weather','cimilo','rain','roob','gu','deyr','jilaal','hagaa','drought','abaar','farming','beer','planting','herders','flood','fatahaad'],['web'],
"""## Steps
1. Ask the location (town or district) and what they do: crops (which), livestock, or both.
2. Today and this week: get_weather for the place. Rainfall amount, heat, wind, in plain words.
3. Season outlook: look for the latest official seasonal and drought or flood updates for Somalia with web_search (national and UN early-warning bulletins). Summarise in 3 lines with the source name and date.
4. Advice that fits the outlook: planting time, water harvesting and storage, moving herds, selling animals before prices drop in drought, flood precautions near rivers (Shabelle, Juba).
5. Offer a weekly weather summary with schedule_task.

## Quality bar
Say where each outlook came from and when it was issued. Never invent a forecast.
""")

k('so-livestock-basics','Livestock care basics','somalia','Farming',
 'Everyday care for camels, goats, sheep and cattle: feeding, water, common problems, when to call a vet, and market timing.',
 ['livestock','xoolo','camel','geel','goat','ari','sheep','cattle','lo\'','vet','dhakhtar xoolaad','market','suuq'],['web'],
"""## Steps
1. Ask the animal, herd size, location and the issue (feeding, sickness signs, breeding, selling).
2. Care basics: water and feed in dry seasons, shade, clean pens, vaccination timing (as advised by local vets or the livestock ministry), and separating sick animals.
3. Sickness: list the warning signs and say plainly when to get a vet now (not eating, high fever signs, bleeding, many animals sick at once, sudden deaths). Do not give drug doses; the vet decides.
4. Market timing: export seasons (e.g. before Hajj and Eid al-Adha) and drought sell-off risks. Check current prices with web_search if the user wants them.
5. Records: offer a simple herd file (births, sales, vaccinations).

## Safety
No medicine doses. Suspected outbreaks should be reported to local animal-health officers.
""")

k('so-first-aid-home','First aid and home care','somalia','Health',
 'Basic first aid and safe home care: ORS for diarrhea, fever, burns, cuts, heat, with clear danger signs that need a clinic now.',
 ['first aid','gargaar degdeg','ors','diarrhea','shuban','fever','qandho','burn','gubasho','cut','dhaawac','heat','cholera','daacuun'],[],
"""## When to use
Everyday first aid questions. Diagnosis, treatment plans and medicines are for health workers: point to a clinic or a Telesia health bot if the user has one.

## Steps
1. First, danger signs: if any apply, say "go to a clinic or hospital now" first, in one line. These include trouble breathing, unconscious or fitting, heavy bleeding, severe dehydration (no urine, very sleepy, sunken eyes), a baby under 2 months with fever, chest pain, or a poisoning.
2. Diarrhea: ORS (sachet in clean water as the packet says; home mix of 1 litre of clean water, 6 level teaspoons of sugar and half a teaspoon of salt only if no sachet), keep feeding and breastfeeding, zinc for children as a health worker advises, and safe water (boil or treat).
3. Fever: fluids, light clothes, a cool cloth; see a health worker if it lasts more than 2 days, or sooner in malaria areas.
4. Burns: cool running water for 20 minutes, no butter or toothpaste, cover loosely.
5. Cuts: press to stop bleeding, clean with clean water, cover.
6. Answer in the user's language, simple steps, short lines.

## Safety
No medicine doses beyond what a packet label says. Never replace a health worker.
""")

k('so-local-business-site','Website for a local business','somalia','Building',
 'Build and publish a simple, fast website for a Somali shop, school, clinic, restaurant or service, with WhatsApp ordering and mobile money details.',
 ['website','bogga','web','shop site','school site','restaurant','publish','whatsapp button','landing page'],['files','sites'],
"""## Steps
1. Ask: business name, what they offer, city and area, phone and WhatsApp, opening hours, mobile money numbers for payment if they want them shown, languages (Somali and/or English), and photos or a logo if they have them.
2. Plan with todo: home, products or services with prices, about, contact (map link, WhatsApp button "Nala soo xiriir WhatsApp"), and an FAQ.
3. Build as files in `sites/<name>/` (write_file, then append_file and edit_file). Mobile-first, light pages that load fast on slow connections, compress images, readable Somali text.
4. Preview, then publish when they say so (free link or their own host).
5. After publishing, offer social posts to share the link.

## Quality bar
Looks professional on a cheap phone, every link and button works, and the contact details are correct.
""")

k('so-whatsapp-business','WhatsApp Business setup','somalia','Business',
 'Set up and run WhatsApp Business: profile, catalog, quick replies, greeting and away messages, labels for orders, all in Somali.',
 ['whatsapp business','whatsapp','catalog','quick replies','greeting','orders','dalab','macaamiil'],['phone'],
"""## Steps
1. Profile: business name, category, short description in Somali, address, hours, and a website link if any.
2. Greeting message (Somali and English), away message with hours, and 5 quick replies: prices, location, delivery, payment by mobile money, and order received.
3. Catalog: one line per product with price and a short description. Offer to write them all from a price list or photos.
4. Labels: New order, Paid, Delivered, Owes money.
5. If they want, guide them on their phone step by step, or use phone control only with their permission.
6. Never message customers unless the user asks. Sending goes through the approval card.
""")

k('so-news-digest','Somali news digest and rumor check','somalia','Daily life',
 'A short daily news summary in Somali from reliable sources, and fact-checks of viral messages and rumors.',
 ['news','war','wararka','digest','rumor','been abuur','fact check','fake news'],['web'],
"""## Steps
1. Ask the topics (national, local city, business, sport, world) and the preferred length.
2. Gather from established news outlets with web_search, read_rss and fetch_url. Prefer 2+ sources for any big claim.
3. Write 5-8 short items in Somali: what happened, where, when (with the date), and the source name.
4. Rumor check: for a forwarded message, search for the claim, then say clearly whether it is confirmed, false or unconfirmed, and why. Note any warning signs: no source, urgency, money requests.
5. Offer a daily digest with schedule_task at their chosen time.

## Quality bar
Neutral, dated and sourced. No invented details. Sensitive security news is stated carefully.
""")

k('so-events-wedding','Weddings, aqiiqa and family events','somalia','Daily life',
 'Plan a Somali wedding, aqiiqa, graduation or family gathering: budget, guest list, venue, food, schedule and invitations.',
 ['wedding','aroos','meher','aqiiqa','graduation','event','munaasabad','guests','marti','budget','invitation','casuumad'],['money','files'],
"""## Steps
1. Ask the event, date, city, rough guest count and budget.
2. Budget table: venue or hall, food (e.g. hilib, bariis), drinks, decoration, clothes (dirac, garbasaar), henna, music or nashiid, photos, transport, and the gifts customary in their family. Track spending with money_add.
3. Guest list file with RSVP status, and an invitation text in Somali (plus English for diaspora), for WhatsApp or print.
4. Timeline: a checklist from 8 weeks to the day, with reminders via schedule_task.
5. On the day: a simple schedule with who is responsible for what.

## Quality bar
Respect family and religious customs. Real numbers from the user, no invented vendor prices.
""")

k('so-diaspora-helper','Diaspora and travel helper','somalia','Daily life',
 'Help Somalis travelling home or abroad: visa and document checklists, flights, what to bring, sending goods, and staying in touch with family.',
 ['travel','safar','visa','fiiso','diaspora','qurbajoog','flights','duulimaad','airport','hajj','umrah','cumra'],['web'],
"""## Steps
1. Ask the trip: from where to where, dates, passport nationality, and purpose (family visit, study, work, Hajj or Umrah).
2. Visa and entry rules: check the official embassy or government page with web_search and fetch_url. List the documents and fees, and say when something could not be confirmed.
3. Flights: compare main routes (often via Nairobi, Addis Ababa, Istanbul or Dubai), with times and rough prices, using search or browser_task if the user asks to book.
4. Packing and money: what to bring, currency and mobile money on arrival, SIM options.
5. Hajj or Umrah: a preparation checklist and a schedule, with prayer_times and qibla tools on the trip.
""")

with open('index_add.json','w') as f: json.dump([{x:v for x,v in s.items() if x!='body'} for s in S],f,ensure_ascii=False)
import os; os.makedirs('s',exist_ok=True)
for s in S:
    d=dict(s); d['category']=d.pop('cat')
    json.dump(d,open(f's/{s["id"]}.json','w'),ensure_ascii=False)
print(len(S))
