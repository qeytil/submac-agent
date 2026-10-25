"""Skills adapted from open-source skill collections (MIT / Apache-2.0) for the SubMac skill library.

Each skill is rewritten for SubMac's tools and for everyday users (plain words, phone first), keeps a
credit line in its body, and carries `source`, `license` and `author` fields. The original licences
are listed in docs/third-party.md. Run `python3 build.py` to write `index_add.json` and `s/<id>.json`;
merge.py adds them to the live index (see README.md).
"""
import json
import os

SRC = {
    'superpowers': dict(author='Jesse Vincent (obra/superpowers)', license='MIT', url='https://github.com/obra/superpowers'),
    'anthropic': dict(author='Anthropic (anthropics/skills)', license='Apache-2.0', url='https://github.com/anthropics/skills'),
    'rezvani': dict(author='Alireza Rezvani (alirezarezvani/claude-skills)', license='MIT', url='https://github.com/alirezarezvani/claude-skills'),
}

S = []


def k(id, name, cat, sub, desc, tags, powers, src, path, body, level='basic'):
    s = SRC[src]
    credit = (f"\n---\nAdapted for SubMac from \"{path}\" by {s['author']}, {s['license']} licence, {s['url']}. "
              "Changed: rewritten for SubMac's tools and everyday users.")
    S.append(dict(id=id, name=name, cat=cat, sub=sub, desc=desc, tags=tags, powers=powers, level=level, v=1,
                  source=f"{s['url']}/tree/main/{path}", license=s['license'], author=s['author'],
                  body=body.strip() + '\n' + credit + '\n'))


# ---------------------------------------------------------------- obra/superpowers (MIT)

k('prd-brainstorm-to-plan', 'Turn a rough idea into a clear plan', 'productivity', 'Thinking',
  'Before building anything new (an app, a site, a business, an event, a talk), find out what the person really wants through a short, friendly conversation, then write a one-page plan they approve.',
  ['brainstorm', 'idea', 'plan', 'design', 'requirements', 'what should i build', 'project', 'new app', 'new business', 'fikrad', 'qorshe'], [],
  'superpowers', 'skills/brainstorming', """
## When to use
The user wants something new made and important details are missing: a website, an app, a shop, a party, a speech, a business.
If everything that matters is already in the request ("make the logo blue"), skip this and just do it.

## Steps
1. Open with one line: they can say "just start" any time and you will use sensible defaults. Then ask one open question about a real moment: "Tell me about the last time you wished this existed" or "Who will use it, and where?"
2. One question per message, one sentence, in their words (Somali, English or both). No lists of example answers unless they are stuck. When they say "you decide", propose something concrete.
3. Cover, as a conversation, not a form: what it is and what makes it special; why now and what success looks like; what it must not become; things they have seen and liked or hated; what already exists; details they care about; what they can spend (money, time) and what they already have (phone only, laptop, a domain, a logo).
4. Find out which choices they want to make and which they hand to you (platform, colours, tools). Say your choices plainly as yours.
5. When looking would help, offer it: their files, a site they like (fetch_url), or a quick web_search. They decide.
6. Think of several approaches privately, drop the weak ones, and show a comparison only if it helps them decide.
7. Write the plan in one page (or a make_document if they want a file): goal, who it is for, what is in and out, the main parts, the first version, open questions. Ask: "Shall I go ahead with this?"
8. Only after a yes, start building (use todo for long jobs).

## Quality bar
The plan uses their words, fits their budget, and contains no decision they never saw. Short messages, one question at a time.
""")

k('dev-implementation-plan', 'Write a step-by-step build plan', 'developer', 'Planning',
  'Turn an approved idea into a detailed build plan: small tasks in order, the exact files to touch, how to test each step, and what done looks like.',
  ['implementation plan', 'build plan', 'tasks', 'roadmap', 'spec', 'breakdown', 'milestones', 'coding plan'], ['files'],
  'superpowers', 'skills/writing-plans', """
## When to use
A design is agreed (see "Turn a rough idea into a clear plan") and the job takes more than a few steps: an app, a website, a bot, a script with several parts.

## Steps
1. Read what exists first (list_dir, read_file) so the plan builds on the current code and its style.
2. Write the plan to a file (write_file `plans/<name>.md`) with:
   - Goal in one sentence, and how we will know it works.
   - Each task small (2-10 minutes of work), in order, each with: files to create or change, what changes, the test that proves it, and the command to run the test.
   - Tests come before code in each task (see "Test first, then build").
   - Keep it simple: no extra features, no clever abstractions, nothing the user did not ask for.
3. Put the task list in todo, then work through it one task at a time. After each task: run its test, mark it done.
4. If reality differs from the plan (a file is not where expected, a library is missing), stop, update the plan, and say what changed in one line.
5. At the end, check every line of the goal against the result (see "Check the work before saying it is done").

## Quality bar
Someone with no context could follow the plan. Every task has a test. Nothing in the plan is vague ("improve", "handle errors") without saying exactly how.
""", level='advanced')

k('dev-systematic-debugging', 'Find the real cause of a bug', 'developer', 'Debugging',
  'Fix bugs, crashes, failing tests and broken builds by finding the root cause first: read the error, reproduce it, compare with what works, test one idea at a time.',
  ['bug', 'debug', 'error', 'crash', 'not working', 'broken', 'failing test', 'stack trace', 'fix', 'khalad'], ['files'],
  'superpowers', 'skills/systematic-debugging', """
## Rule
No fix before you know the cause. Guessing wastes time, even when you are in a hurry.

## Steps
1. Read the error fully: message, file, line, code. It often says exactly what is wrong.
2. Reproduce it: what exact steps make it happen, every time? If you cannot make it happen, gather more facts; do not guess.
3. What changed? Recent edits, new packages, settings, a different phone or browser.
4. When several parts are involved (app, server, database), check what goes in and out at each step (print or log once) to find the part where it breaks.
5. Compare with something similar that works, and list every difference, even small ones.
6. Form one clear idea: "I think X causes it because Y". Test it with the smallest possible change, one thing at a time.
7. Fix the cause, not the symptom. Add a test that failed before the fix and passes after.
8. If three fixes in a row fail, stop: the design may be wrong. Tell the user plainly and suggest the options.

## Warning signs
"Quick fix for now", "just try changing X", several changes at once, fixing without reproducing. Go back to step 1.

## Quality bar
You can explain the cause in one sentence, the fix touches only that cause, and the original problem is checked again after the fix.
""", level='advanced')

k('dev-test-first', 'Test first, then build', 'developer', 'Testing',
  'Build features and fix bugs test-first: write a small test that fails, write the least code to pass it, then tidy up. Keeps apps working as they grow.',
  ['tdd', 'test driven', 'unit test', 'tests', 'test first', 'regression', 'quality'], ['files'],
  'superpowers', 'skills/test-driven-development', """
## When to use
New features, bug fixes and changes to app or script code. Skip for throwaway experiments and pure design work (say so).

## The cycle
1. Red: write one small test for one behaviour, with a clear name ("rejects an empty phone number"). Run it and watch it fail for the right reason (the feature is missing, not a typo).
2. Green: write the simplest code that makes it pass. Nothing extra.
3. Run all tests: the new one passes and nothing else broke.
4. Tidy: clean names, remove repetition, keep tests green.
5. Next behaviour: back to Red.

## Rules
- Code written before its test: set it aside and redo it test-first; tests written after the fact only prove what the code does, not what it should do.
- A bug fix starts with a test that reproduces the bug.
- Test real behaviour; avoid mocks unless the real thing is slow or outside your control (network, payments).
- Run the tests yourself (run_shell) and read the output; never assume they pass.

## Quality bar
Every new function has a test that was seen failing first. All tests pass, the output is clean, and edge cases (empty, wrong input, errors) are covered.
""", level='advanced')

k('prd-check-before-done', 'Check the work before saying it is done', 'productivity', 'Quality',
  'Before telling the user something is finished, fixed, sent or working, prove it: run the check, read the result, and report what is true with the evidence.',
  ['verify', 'check', 'done', 'finished', 'quality', 'proof', 'double check', 'review my work', 'hubi'], [],
  'superpowers', 'skills/verification-before-completion', """
## Rule
No "done", "fixed" or "it works" without fresh proof from this step.

## Steps
1. Ask: what would prove this claim? (The test run for code, the opened file for a document, the live link for a website, the sent-message screen for a message, the totals for a budget.)
2. Do that check now, in full, not part of it.
3. Read the result: errors, numbers, what is missing.
4. If it does not confirm the claim, say what is actually true and what you will do next.
5. If it does, say so with the evidence: "All 34 tests pass", "The PDF opens with 3 pages and the totals match: $1,240", "The site is live at <link>".
6. For a request with several parts, re-read the user's message and tick each part off; report any part not done.

## Warning signs
"Should work", "probably", "looks right", celebrating before checking, trusting another step's report without looking.

## Quality bar
Every success claim in the final message has its proof next to it, and nothing the user asked for is silently missing.
""")

# ---------------------------------------------------------------- anthropics/skills (Apache-2.0)

k('cre-distinctive-design', 'Design a site or poster that stands out', 'creator', 'Design',
  'Give a website, landing page, app screen, flyer or poster a distinctive look that fits its subject (colours, type, layout, words), instead of a generic AI template.',
  ['design', 'website design', 'landing page', 'ui', 'look and feel', 'colors', 'typography', 'brand look', 'flyer', 'poster', 'naqshad'], ['files'],
  'anthropic', 'skills/frontend-design', """
## When to use
Building or restyling a website (sites), landing page, app screen, or a visual made with code_media.

## Steps
1. Ground it in the subject: what it is, who it is for, and its main job. If the brief does not say, propose one line and confirm. A tailoring shop in Hargeisa, a Quran school and a crypto dashboard should look nothing alike: take colours, textures and words from that world.
2. Make a short design plan first: 4-6 named colours with hex codes; one or two typefaces and their roles; the layout in a sentence (and a tiny text sketch); one principle that makes this design unique.
3. Check the plan against the usual AI defaults and change any you did not choose on purpose: cream background with a serif and a clay-orange accent; near-black with one neon accent; identical rounded cards with soft grey shadows and gradient washes; ALL-CAPS labels above every heading; "01 / 02 / 03" markers on content that is not a sequence; one italic word in the headline; arrows on every button.
4. Hero first: open with the most characteristic thing in the subject's world (a real product photo, a big clear promise, a live price, a map), not a stock "big number with a gradient".
5. Type carries the personality: a clear size scale, lines under 80 characters, generous line height for body text.
6. Spend boldness in one place; keep the rest calm. Motion only once (one entrance) or as a response to a tap.
7. Words: plain, specific, from the customer's side. Buttons say what happens ("Order on WhatsApp", not "Submit"). Real prices, real place names; never lorem ipsum.
8. Quality floor without announcing it: works on a small phone first, readable contrast, visible focus, respects reduced motion, loads fast on slow data.
9. Look at the result (preview) and remove one thing before you call it done.

## Quality bar
Someone could tell what the business is from the design alone, and nothing on the page looks like a default template.
""")

k('prd-design-themes', 'Pick a colour and font theme', 'productivity', 'Documents',
  'Give slides, documents, reports, menus and websites a consistent, professional look: choose one of 10 ready colour-and-font themes or create a custom one.',
  ['theme', 'colors', 'colours', 'palette', 'fonts', 'style', 'slides design', 'presentation design', 'brand colors', 'midab'], ['files'],
  'anthropic', 'skills/theme-factory', """
## When to use
The user wants a deck, document, menu, flyer or site to look polished, or asks for colours that go together.

## Steps
1. Suggest 2-3 themes from the list that fit the subject and audience, each in one line, and ask which one (or offer a custom theme).
2. Apply the chosen theme the same way everywhere: background, headings, accents, text, tables and charts. Keep text readable (dark on light or light on dark, never low contrast).
3. Custom theme: from the user's words or logo, make 4 colours (base, accent, light, dark) with hex codes and a font pair, give it a short name, show it, and apply after a yes.

## The 10 themes (colours: role, hex; fonts: headings / body)
1. Ocean Depths, calm and professional (finance, corporate): Deep Navy #1a2332 background, Teal #2d8b8b accent, Seafoam #a8dadc light accent, Cream #f1faee text. Sans bold / sans.
2. Sunset Boulevard, warm and energetic (creative pitches, events): Burnt Orange #e76f51, Coral #f4a261, Warm Sand #e9c46a, Deep Teal #264653 for text. Serif bold / sans.
3. Forest Canopy, natural (farming, environment, wellness): Forest Green #2d4a2b, Sage #7d8471, Olive #a4ac86, Ivory #faf9f6. Serif bold / sans.
4. Modern Minimalist, clean (tech, architecture, portfolios): Charcoal #36454f, Slate Gray #708090, Light Gray #d3d3d3, White #ffffff. Sans bold / sans.
5. Golden Hour, rich and welcoming (restaurants, hospitality): Mustard #f4a900, Terracotta #c1666b, Warm Beige #d4b896, Chocolate #4a403a. Sans bold / sans.
6. Arctic Frost, crisp (health, clinics, technology): Ice Blue #d4e4f7, Steel Blue #4a6fa5, Silver #c0c0c0, Crisp White #fafafa. Sans bold / sans.
7. Desert Rose, soft and elegant (fashion, beauty, weddings, boutiques): Dusty Rose #d4a5a5, Clay #b87d6d, Sand #e8d5c4, Deep Burgundy #5d2e46. Sans bold / sans.
8. Tech Innovation, bold (startups, apps, launches): Electric Blue #0066ff, Neon Cyan #00ffff, Dark Gray #1e1e1e, White #ffffff. Sans bold / sans.
9. Botanical Garden, fresh (food, markets, gardens): Fern Green #4a7c59, Marigold #f9a620, Terracotta #b7472a, Cream #f5f3ed. Serif bold / sans.
10. Midnight Galaxy, dramatic (entertainment, gaming, luxury): Deep Purple #2b1e3e, Cosmic Blue #4a4e8f, Lavender #a490c2, Silver #e6e6fa. Sans bold / sans.

## Quality bar
One theme used consistently from first page to last; contrast is easy to read on a phone in sunlight.
""")

k('biz-team-updates', 'Team updates, newsletters and FAQs', 'business', 'Team',
  'Write clear internal updates for a team or organisation: weekly Progress/Plans/Problems updates, staff newsletters, FAQ answers, incident notes and announcements.',
  ['team update', 'weekly update', 'status report', 'progress report', 'newsletter', 'staff', 'faq', 'announcement', 'incident report', '3p', 'warbixin'], [],
  'anthropic', 'skills/internal-comms', """
## Pick the format
1. Weekly 3P update (Progress, Plans, Problems), for managers and the team: confirm the team name and the dates. Gather facts from the user (or their connected email, calendar or notes when available). Format, strictly:
   [one fitting emoji] [Team name] ([dates])
   Progress: 1-3 sentences, what was finished: shipped, delivered, signed, numbers.
   Plans: 1-3 sentences, the top priorities for next week.
   Problems: 1-3 sentences, what is slowing the team (people, money, blockers).
   It should read in 30-60 seconds, with facts and numbers, no fluff.
2. Staff or company newsletter: short sections (announcements, wins, people, coming up), 1-2 sentences per bullet, written as "we", with links to the real documents. Organisation-wide news only; team detail belongs in 3P updates.
3. FAQ: the questions many people are asking, each as *Question* (one sentence) and *Answer* (1-2 sentences). Base answers on official information, say clearly when something is not confirmed, and flag questions that need a manager's answer.
4. Anything else (incident note, policy change, announcement): first ask the audience, the purpose and the tone; then lead with the most important point, use active voice, keep it short, and end with what people should do.

## Delivery
Plain text for WhatsApp, Telegram or email; make_document for a PDF or Word copy. Offer a weekly reminder (schedule_task) for recurring updates.

## Quality bar
Accurate, specific and short. Nothing invented; anything uncertain is marked.
""")

k('cre-poster-art-direction', 'Art-direct a poster or artwork', 'creator', 'Design',
  'Create an original poster, cover or piece of visual art by first naming a visual idea (a small design philosophy), then drawing it with care: mostly image, very little text.',
  ['poster', 'art', 'artwork', 'cover', 'visual', 'generative art', 'wall art', 'album cover', 'event poster', 'sawir'], ['files'],
  'anthropic', 'skills/canvas-design', """
## Steps
1. Read the brief for its subtle cues (subject, mood, where it will hang or be posted, the size). Ask only if the purpose is unclear.
2. Name a visual idea in 1-2 words ("Quiet Geometry", "Monsoon Signal") and describe it in a short paragraph: how it uses space and form, colour and material, scale and rhythm, composition, and what the eye sees first. Information lives in the design, not in paragraphs of text.
3. Draw it with code_media (or generate_image when a photo-like picture fits better): about 90% visual, 10% essential text (a title, a date, a place). Fonts clean and deliberate; text never cramped, cut off or overlapping.
4. Craft: it should look like an expert spent hours on it. Precise alignment, consistent spacing, a limited palette, every element placed on purpose. Never copy an existing artist's work or style closely.
5. Look at the result, refine once (spacing, contrast, balance), then deliver. Offer a version sized for a phone status, an Instagram post and A4 print if useful.

## Quality bar
Original, balanced, readable from a distance, and clearly about the user's subject.
""")

# ---------------------------------------------------------------- alirezarezvani/claude-skills (MIT)

k('wri-humanize-text', 'Make writing sound human', 'writing', 'Editing',
  'Rewrite stiff, robotic or AI-sounding text so it reads like a real person wrote it: cut filler words and hedging, vary the rhythm, add specifics and a real voice.',
  ['humanize', 'sounds like ai', 'robotic', 'natural', 'rewrite', 'tone', 'voice', 'make it human', 'less formal'], [],
  'rezvani', 'marketing-skill/skills/content-humanizer', """
## Steps
1. Ask (or infer) who will read it and the voice wanted: friendly shop owner, serious NGO, young creator. Use the user's own past writing as the voice guide when they share it.
2. Spot the tells:
   - Filler words: delve, landscape, crucial, vital, pivotal, leverage, furthermore, moreover, navigate (as a metaphor), robust, comprehensive, holistic, foster, facilitate, ensure.
   - Hedging chains: "It's important to note that", "It's worth mentioning", "In many cases", "Needless to say".
   - Dashes in every paragraph; every paragraph built the same way (topic, explanation, example, bridge).
   - Vague claims: "many companies", "studies show", "significantly improved", "a lot of".
   - Confident claims nobody can know; a conclusion that repeats the intro.
3. Rewrite: plain words ("use", not "leverage"); mix short and long sentences, with the odd fragment; replace vague with specific (numbers, names, places, real examples from the user); vary paragraph length; cut the summary ending and finish on something new or a clear next step.
4. Keep the meaning and every fact. Never invent statistics, quotes or experiences; ask the user for a real example instead.
5. Show the new version. If useful, list the 3-5 biggest changes in one line each.

## Quality bar
Read aloud, it sounds like one specific person talking. No filler words from the list remain unless they are truly the best word.
""")

k('mkt-cold-email', 'Cold emails that get replies', 'marketing', 'Sales',
  'Write short, personal first emails and follow-ups to people who do not know you yet (customers, partners, buyers, donors), written like a peer, not an advert.',
  ['cold email', 'outreach', 'prospecting', 'sales email', 'follow up', 'introduce my business', 'partnership email', 'b2b'], ['web'],
  'rezvani', 'marketing-skill/skills/cold-email', """
## Ask first
Who is sending (business, what it does, one proof: a client, a number), who receives it (role, company, why them), and the single ask (a 15-minute call, a reply, a sample).

## Write the first email
1. Subject: 2-5 plain words, like a colleague would write ("Question about your deliveries"). No hype, no ALL CAPS, no "Quick question!!".
2. First line about their world, not yours: something specific and true (a recent post, a new branch, a problem common in their trade). Check facts with web_search or fetch_url; never invent personalisation.
3. Connect it to a problem you solve, in one or two sentences, with one piece of proof.
4. One small ask, easy to say yes to.
5. Under 120 words, no attachments, no links except one if needed, a normal signature with a phone or WhatsApp number.

## Follow-ups
3-4 follow-ups over 2-3 weeks (e.g. day 3, 7, 14, 21), each adding something new (a short example, a useful tip, a different angle), never "just bumping this". The last one politely closes the loop.

## Avoid
Fake familiarity, long company histories, several asks, pressure tactics, buying lists, sending without the user's approval. Draft only; the user sends (or approves via the approval card).

## Quality bar
Reads like a busy peer wrote it in two minutes, specific to that one person, with one clear ask.
""")

k('biz-proposal-contract', 'Project proposals and simple service contracts', 'business', 'Sales',
  'Draft a clear project proposal, scope of work, freelance or service contract, retainer or NDA, with the clauses that prevent most disputes. Information, not legal advice.',
  ['proposal', 'contract', 'scope of work', 'sow', 'freelance contract', 'nda', 'retainer', 'agreement', 'quotation', 'heshiis'], ['documents'],
  'rezvani', 'business-growth/skills/contract-and-proposal-writer', """
## Ask first
Both parties (names, addresses, country), the work, deliverables, timeline, price and payment terms (deposit, milestones, mobile money or bank), and which country's law applies.

## Proposal (to win the work)
Short intro in the client's words, the problem, the proposed solution, deliverables, timeline with milestones, price table (calculate the totals), what is not included, why you (2-3 proofs), next step and validity date.

## Contract (to protect both sides)
Clauses to cover, in plain language:
1. Services and deliverables, with what is out of scope and how changes are priced.
2. Payment: amounts, deposit, due dates, late fees, currency.
3. Ownership: who owns the work and when (usually after full payment); the right to show it in a portfolio.
4. Confidentiality.
5. Revisions and acceptance: how many rounds, how long the client has to approve.
6. Warranty and limit of liability (often capped at the fees paid).
7. Termination: notice period and payment for work done.
8. Disputes: talk first, then mediation, then the named courts or arbitration.
9. Signatures and date.
For NDAs: what is confidential, exceptions, duration, return or deletion of information.

## Delivery
make_document as DOCX (easy to edit) or PDF. Mark it as a draft. Add one line that a local lawyer should check anything large or unusual; laws differ by country (Somalia, Kenya, the UK, the US, the EU each have their own rules).

## Quality bar
No blanks or placeholders left, numbers checked, plain words both sides understand.
""")

k('biz-tender-response', 'Answer a tender, RFP or RFQ', 'business', 'Sales',
  'Decide whether to bid and write a strong response to a tender, RFP, RFQ or NGO call: list every requirement, match proof to each one, plan the win themes, and check the format.',
  ['tender', 'rfp', 'rfq', 'rfi', 'bid', 'procurement', 'ngo tender', 'proposal request', 'eoi', 'expression of interest', 'qandaraas'], ['documents', 'web'],
  'rezvani', 'commercial/skills/rfp-responder', """
## Steps
1. Read the whole document (read_document or read_pdf). Pull out: deadline (with time zone), how and where to submit, page or format limits, required forms, eligibility (registration, tax certificate, experience years), and the scoring criteria.
2. List every requirement in a table and tag it MANDATORY (fail it and you are out), SCORED, or NICE TO HAVE.
3. For each requirement, mark your fit: STRONG, PARTIAL or GAP, with the proof you can show (past contracts, certificates, CVs, photos, references). Never claim what cannot be proved.
4. Bid or not: any MANDATORY gap, too little time, or a clear favourite already in place means no bid, a partner bid, or asking a clarification question before the deadline. Say the reason plainly.
5. Pick 3-5 win themes (e.g. local presence and fast delivery, lowest total cost, proven with the same donor) and repeat them across the answers.
6. Write each answer in the buyer's order and words: answer first, then proof. Price schedule checked with calculate. Include required forms, signed declarations and annexes.
7. Final check against the requirement table: every item answered, limits respected, files named as asked. Offer a reminder before the deadline (schedule_task).

## Quality bar
Nothing mandatory missing, every claim backed by proof, easy for an evaluator to score.
""", level='advanced')

k('stu-literature-review', 'Find and organise research papers', 'study', 'Research',
  'For a thesis, research paper or project: plan the search, find real academic papers through free open databases (OpenAlex, PubMed), spot the key ones, and make a reading guide.',
  ['literature review', 'research papers', 'academic papers', 'thesis', 'dissertation', 'sources', 'journal articles', 'pubmed', 'openalex', 'citations', 'cilmi baaris'], ['web', 'documents'],
  'rezvani', 'research/litreview/skills/litreview', """
## Ask first (one at a time)
1. The research question, as specific as possible (who, what, where, compared with what).
2. Recent work only, classic work, or both.
3. Depth: a quick scan (about 5 searches), a standard review (10) or a deep dive (20).

## Search (free, no sign-in, through fetch_url)
- OpenAlex: https://api.openalex.org/works?search=<words>&per-page=20 (add &filter=from_publication_date:2021-01-01 for recent, &filter=type:review for review articles). Read title (display_name), publication_year, cited_by_count, doi and authors.
- PubMed for health and medicine: https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term=<words>&retmode=json&retmax=20 then esummary.fcgi?db=pubmed&id=<ids>&retmode=json. Paper link: https://pubmed.ncbi.nlm.nih.gov/<id>/
Split the question into 3-5 sub-areas (PICO for health: population, intervention, comparison, outcome) and search each.

## Make sense of it
- Papers that show up in several searches are likely foundational; authors who keep appearing lead the field.
- Compare citations per year, not total citations (a 2023 paper with 150 citations beats a 2008 one with 150).

## Deliver (make_document, DOCX or PDF)
A short topic overview, a "start here" reading order (5-10 papers, each with why it matters), groups by sub-area, gaps in the research, and a reference list in the style the user needs (APA by default) with DOI links.

## Integrity
Only list papers you actually found, with working links. Never invent a paper, author, number or quote. Say when a search returned little.
""", level='advanced')

k('stu-deep-research', 'Deep research with checked sources', 'study', 'Research',
  'Investigate an important question or decision properly: search many sources, confirm each key claim with several independent sources, look for the opposite view, and write a clear, cited report.',
  ['deep research', 'research report', 'investigate', 'due diligence', 'fact check', 'compare options', 'market research', 'evidence', 'sources'], ['web', 'documents'],
  'rezvani', 'research/deep-research/skills/deep-research', """
## When to use
High-stakes questions where being wrong costs money, health or reputation: choosing a supplier, a school abroad, an investment, a big purchase, a policy. For quick facts, a single web_search is enough.

## Steps
1. Restate the question and what the decision is. Agree on scope and depth with the user in one message.
2. Plan 4-8 angles (official sources, news, expert analysis, user reviews and forums, data and statistics, critics). Put them in todo.
3. Search widely (web_search, fetch_url, wikipedia; browser_task for pages that need it). Save every source you use with its link and date to a notes file (write_file `research/<topic>.md`).
4. Triangulate: a key claim needs at least 3 independent sources (not copies of the same press release). Mark claims with one source as unconfirmed.
5. Argue against yourself: search for the strongest evidence that you are wrong and include it.
6. Write the report: the answer in 3 sentences first, then the findings with sources, the disagreements, what is unknown, and a recommendation with confidence (low, medium, high). Offer it as a PDF (make_document).

## Quality bar
Every important claim has a link, dates are given, the opposing view is fairly stated, and gaps are named rather than filled with guesses.
""", level='advanced')

k('ent-roast-my-idea', 'Pressure-test a business idea', 'entrepreneur', 'Validation',
  'Put a business or project idea in front of a five-voice panel (critic, champion, analyst, market investigator, customer), then give an honest verdict: go, reshape or kill, plus the cheapest test to run next.',
  ['roast my idea', 'validate idea', 'business idea', 'stress test', 'is this a good idea', 'feedback on idea', 'startup idea', 'second opinion', 'fikrad ganacsi'], ['web'],
  'rezvani', 'productivity/roast/skills/roast', """
## Step 1: frame the idea
Get in a few lines: the idea, who it is for and how it makes money (buyer and price), the user's edge (skills, audience, assets, location), and limits (budget, time, how soon money must come in).

## Step 2: the panel (write each voice separately, honestly)
1. The Critic: assume it fails. The fatal flaws, the fastest way it dies, the shakiest assumptions.
2. The Champion: the strongest case for it, the 10x version, opportunities the founder is missing.
3. The Analyst: no research, pure logic. Does the mechanism work, do incentives line up, does the maths work (use calculate)?
4. The Investigator: real evidence with web_search: competitors, prices they charge, signs of demand, local conditions.
5. The Customer: speak as the target buyer in first person. Would I pay? What is my real objection? What would I do instead?
Each gives a one-line stance, 3-5 sharp points, the one thing the user must hear, and a score from 1 to 10.

## Step 3: the verdict
Weigh demand (the Customer) and survival (the Critic) most, the Champion least. A customer who will not pay, or a fatal flaw, rules out GO. Then write:
THE VERDICT: GO / RESHAPE / KILL, confidence low, medium or high.
The call in one line; why, in 2-3 sentences that settle the panel's biggest disagreement; rough pricing and time to first income; and the cheapest test for the riskiest assumption (e.g. a WhatsApp status pre-order, 10 customer conversations, a one-page site with a price).

## Rules
Kind but honest; no false cheering. Real facts only, sources for market claims.
""")

if __name__ == '__main__':
    here = os.path.dirname(os.path.abspath(__file__))
    os.chdir(here)
    ids = [s['id'] for s in S]
    assert len(ids) == len(set(ids)), 'duplicate ids'
    with open('index_add.json', 'w') as f:
        json.dump([{x: v for x, v in s.items() if x not in ('body', 'source', 'author')} for s in S], f, ensure_ascii=False)
    os.makedirs('s', exist_ok=True)
    for s in S:
        d = dict(s)
        d['category'] = d.pop('cat')
        with open(f"s/{s['id']}.json", 'w') as f:
            json.dump(d, f, ensure_ascii=False)
    print(len(S))
