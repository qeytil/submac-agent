/// Design and output know-how for the agent and every bot (owner, 2026-10-24): "the agent just immediately sending
/// unfinished ugly broken websites ... DO NOT HARD CODE ANYTHING, GIVE THE USER FREEDOM TO CHOOSE WHAT THEY WANT, just
/// improve the knowledge of the agent".
///
/// So this file holds KNOWLEDGE and PROCESS only: how to read a brief, when to offer style directions, design
/// fundamentals, how to build complete files, how to check them, and how to shape and time replies. It never holds a
/// palette, a font, a layout or a template: the look always comes from the user's words and the brief. A test
/// (test/design_skills_test.dart) keeps hex colours, rgb() values and named font families out of these texts.
///
/// Built-in skills use the same shape as the shared library index (see [ApkBuild.skills]), so skill_search,
/// skill_use and the "Skills that may fit" hint find them, offline too. Pure Dart, unit tested.
class DesignSkills {
  DesignSkills._();

  static const webId = 'web-design';
  static const uiId = 'ui-design';
  static const reviewId = 'design-review';
  static const repliesId = 'rich-replies';
  static const timingId = 'reply-timing';
  static const docsId = 'documents-and-slides';
  static const chartsId = 'charts-and-data';

  static const ids = [webId, uiId, reviewId, repliesId, timingId, docsId, chartsId];

  // ---------------------------------------------------------------- what the user asked

  static final _siteWord = RegExp(
      r'\b(web ?sites?|web ?pages?|landing( page)?|home ?page|portfolio site|web ?app|html|css|one[- ]pager|microsite|'
      r'websaydh|website-?ka|bog(ga)? internet|boggii)\b',
      caseSensitive: false);
  static final _uiWord = RegExp(
      r'\b(ui|ux|user interface|app (screen|screens|design|layout)|(app|mobile|login|home|settings|onboarding|checkout|sign ?up) screens?|'
      r'screens? (for|of) [\w ]{0,24}\bapp|dashboard|mockup|mock-up|'
      r'wireframe|prototype|design system|component library|redesign|restyle|make it (look )?(nicer|better|modern|beautiful|clean))\b',
      caseSensitive: false);
  static final _makeWord = RegExp(
      r'\b(build|make|create|design|redesign|restyle|improve|fix|code|develop|set up|generate|samee|sameey|ii samee|dhis|naqshadee)\b',
      caseSensitive: false);

  /// The message asks to make or improve a website, page or web app.
  static bool wantsSite(String text) => text.trim().isNotEmpty && _siteWord.hasMatch(text) && _makeWord.hasMatch(text);

  /// The message asks to design or improve app screens or another interface (not a website).
  static bool wantsUi(String text) => text.trim().isNotEmpty && _uiWord.hasMatch(text) && _makeWord.hasMatch(text);

  /// A one-step hint for a design request ('' when the message is about something else).
  static String noteFor(String text) {
    final site = wantsSite(text), ui = wantsUi(text);
    if (!site && !ui) return '';
    final id = site ? webId : uiId;
    return '# Design request\n'
        'This request is about ${site ? 'a website or web page' : 'an interface (screens, dashboard, components)'}. Before you start, '
        'read skill_use $id and follow its process: understand the brief, offer style choices only when the user gave none, plan, '
        'build complete files, check them (skill $reviewId), and only then deliver. The user\'s own choices (style, colours, fonts, '
        'layout, sections, wording) are followed exactly. Never send a first draft as the finished result.';
  }

  /// Short lines for the main prompt: the rule, not the knowledge (the knowledge lives in the skills).
  static const promptRule = 'Design like a thoughtful senior designer, never from a template: the look comes from the brief and the '
      'user\'s own taste. Before building a website or UI read skill_use $webId (screens and apps: $uiId). If the user gave no style '
      'preference and the look matters, offer 2-3 distinct directions that fit their brief (ask_user, each a few words, plus "You '
      'choose"); when they chose anything (colours, fonts, layout, sections, tone), follow it exactly. Real content from what they told '
      'you; never invent their prices, contacts, reviews or team: ask, or leave a clearly marked spot. Self-contained files by default '
      '(no CDN scripts) so the preview and the free link always work; a web font or library only when they ask or the design truly needs '
      'it, with a fallback. Never deliver a first draft: build complete files, check them (code_check on the folder; SubMac also checks '
      'every page you wrote before your final reply), fix, then deliver with the ```file card.';

  /// The media line: graphics follow the brief too.
  static const mediaRule = 'a look that fits the brief and the user\'s taste (offer 2-3 directions when they gave none and it matters; '
      'follow their colours, fonts and style exactly when given), clear hierarchy and room to breathe';

  // ---------------------------------------------------------------- the built-in skills

  static Map<String, Object> _entry(String id, String name, String cat, String sub, String desc, List<String> tags) => {
        'id': id,
        'name': name,
        'cat': cat,
        'sub': sub,
        'desc': desc,
        'tags': tags,
        'powers': <String>[],
        'level': 'pro',
        'v': 1,
      };

  /// Library index lines (same shape as the shared library's index.json entries).
  static final skills = <Map<String, Object>>[
    _entry(webId, 'Design and build a finished website', 'developer', 'Web design',
        'Websites, landing pages, portfolios and web apps that look considered and work: brief, style choices, plan, design '
            'fundamentals, complete files, self-review and delivery. No templates: the look comes from the brief.',
        ['website', 'web site', 'web page', 'landing page', 'landing', 'portfolio', 'web app', 'html', 'css', 'web design',
          'site design', 'homepage', 'one pager', 'websaydh', 'bogga']),
    _entry(uiId, 'Design app screens and interfaces', 'developer', 'UI design',
        'App screens, dashboards, forms, components and design systems: hierarchy, layout, states, touch targets, accessibility, '
            'consistency. For HTML prototypes, Flutter or React code.',
        ['ui', 'ux', 'user interface', 'app design', 'app screen', 'dashboard', 'mockup', 'wireframe', 'prototype',
          'design system', 'components', 'redesign', 'restyle']),
    _entry(reviewId, 'Review a design before delivering it', 'developer', 'Design QA',
        'The check before anything visual is delivered: complete files, no broken links or pictures, phone width, contrast, '
            'real content, the user\'s choices honoured. Fix, then deliver.',
        ['design review', 'qa', 'check website', 'broken website', 'broken page', 'test website', 'responsive', 'accessibility',
          'contrast', 'review design']),
    _entry(repliesId, 'Clear, rich replies', 'productivity', 'Replies',
        'Choosing the right form for an answer: plain text, steps, a table, cards, a chart or diagram, a document, slides or a '
            'picture; and clean chat formatting.',
        ['format', 'formatting', 'table', 'cards', 'summary', 'report', 'compare', 'comparison', 'rich reply', 'layout answer']),
    _entry(timingId, 'Progress and final replies on long tasks', 'productivity', 'Replies',
        'When to send a progress line, when to stay quiet, and when the final reply is due: one final, only when the work is '
            'complete and checked.',
        ['progress', 'update', 'status', 'long task', 'final reply', 'timing']),
    _entry(docsId, 'Polished documents, sheets and slides', 'writing', 'Documents',
        'CVs, letters, reports, proposals, invoices, spreadsheets and slide decks that read well: structure, hierarchy, '
            'typography, tables, consistent styling, and checking the file before sending it.',
        ['document', 'pdf', 'docx', 'report', 'proposal', 'cv', 'resume', 'slides', 'presentation', 'deck', 'spreadsheet',
          'xlsx', 'invoice', 'letter']),
    _entry(chartsId, 'Charts and data that tell the truth', 'business', 'Data',
        'Picking the right chart for the question, honest axes and labels, few colours with meaning, and when a table or one '
            'number says it better.',
        ['chart', 'graph', 'diagram', 'data', 'visualisation', 'visualization', 'bar chart', 'line chart', 'pie', 'donut',
          'dashboard numbers', 'infographic']),
  ];

  /// The full instructions of a built-in design skill, or null when [id] is not one.
  static String? bodyOf(String id) => switch (id) {
        webId => _web,
        uiId => _ui,
        reviewId => _review,
        repliesId => _replies,
        timingId => _timing,
        docsId => _docs,
        chartsId => _charts,
        _ => null,
      };

  /// Every body, for tests.
  static Map<String, String> get bodies => {for (final id in ids) id: bodyOf(id)!};

  // ---------------------------------------------------------------- shared parts

  static const _freedom = '## The user decides the look\n'
      '- Whatever the user chose (colours, fonts, mood, layout, sections, wording, language, dark or light) is followed exactly, '
      'even where you would choose differently. If a choice would hurt them (unreadable text, a broken layout), say so in one line, '
      'suggest the smallest change, and still do it their way if they insist.\n'
      '- If they gave no preference and the look matters, offer 2-3 directions that are genuinely different and each fits their brief. '
      'Build each direction from their audience, field and goal, along a few axes: mood (calm, bold, playful, formal...), colour '
      'temperature and contrast, type character (classic, modern, technical, handwritten...), density (airy or compact) and shape '
      'language (soft, sharp, organic). Describe each in a few plain words, in one ask_user with the directions as options plus '
      '"You choose". Never offer the same three directions to everyone.\n'
      '- "You choose", "just do it" or a quick small job: pick the direction that best fits the brief and say in one line why. Do not ask.\n'
      '- Never ask about something they already said. Ask at most one round of questions (up to 3), only the ones that change the result.\n';

  static const _fundamentals = '## Design fundamentals (knowledge, not a style)\n'
      '- Hierarchy: one thing matters most on each screen. Make it obvious with size, weight, position and space before colour.\n'
      '- Type: a modular scale (each step a steady ratio larger), comfortable body size on phones (never smaller than 16px for body '
      'copy), line length of roughly 45-80 characters, line height around 1.4-1.7 for body and tighter for big headings. Two families '
      'at most; one is often enough. Fluid sizes with clamp() so headings scale from phone to desktop.\n'
      '- Space: one spacing scale used everywhere (a base unit and its multiples). Related things sit closer than unrelated ones. '
      'Generous space reads as calm and confident; cramped space reads as cheap.\n'
      '- Colour: a small set with clear roles (background, surface, text, muted text, one accent for action, states for success and '
      'error), defined once as CSS variables or theme tokens. Text contrast at least 4.5:1 (3:1 for large text and icons). Never '
      'carry meaning by colour alone.\n'
      '- Layout: mobile first. Design at about 360px wide, then let grid and flex layouts open up with a few breakpoints. No sideways '
      'scrolling, no fixed widths that overflow, images max-width: 100%. Touch targets at least about 44px.\n'
      '- Consistency: the same radius, shadow, border and spacing logic everywhere. Fewer, repeated decisions look designed.\n'
      '- Images: real or generated pictures that fit the brief, sized for the screen, with width and height (or aspect-ratio) set so '
      'the page does not jump, loading="lazy" below the fold, meaningful alt text, and a calm fallback (a colour or gradient) if one '
      'fails. Never a broken image, a hotlinked random photo, or a picture you have not checked exists.\n'
      '- Icons: one consistent set (inline SVG works offline). Never emoji as icons unless the user wants that style.\n'
      '- Motion: only to explain a change (hover, focus, open, appear). Short and soft, and respect prefers-reduced-motion.\n'
      '- Dark and light: if both are offered, design both deliberately (prefers-color-scheme), checking contrast in each.\n'
      '- States: hover, focus (always visible for keyboards), active, disabled, loading, empty and error states exist and look intended.\n';

  static const _content = '## Content\n'
      '- Words come from what the user told you, written for their audience, in their language. No lorem ipsum, no "Welcome to our '
      'website", no generic filler.\n'
      '- Never invent prices, phone numbers, addresses, reviews, team members, logos of clients or statistics. Ask for them, or '
      'leave a clearly marked spot (for example [Your phone number]) and list those spots in your final reply.\n'
      '- Every link goes somewhere real: a section on the page, another page you built, or an address the user gave. '
      'Buttons do something.\n';

  static const _build = '## Building complete files\n'
      '- A website or web app is files in sites/<short-name>/ (index.html, plus styles, scripts and pictures in the same folder), '
      'made with write_file. A small one-screen thing (a flyer, a menu) may be a ```page card, but only if it fits comfortably in one '
      'reply; anything longer is files.\n'
      '- Plan first (todo): the sections or screens in order, the design tokens (from the chosen direction), then one step per part.\n'
      '- Your replies have a length limit. Write each file in parts of about 150 lines: write_file the first part, append_file the '
      'rest, in order, until the file is whole. Never stop a file halfway, never leave "..." or "rest of the code here". Small fixes '
      'with edit_file, never a full rewrite.\n'
      '- Semantic HTML: header, nav, main, section, footer, h1-h3 in order, button for actions and a for links, label for every field, '
      'lang on <html>, a <title> and <meta name="viewport"> in <head>.\n'
      '- Self-contained by default: CSS and JavaScript in the folder (or inline), no CDN scripts, so the in-app preview and the free '
      'link work offline. Use a web font or library only when the user asks or the design truly needs it, always with a fallback.\n'
      '- Pictures: generate_image or code_media when a picture helps, saved into the site folder and referenced by that relative path. '
      'Keep the whole site under 5 MB (the publish limit).\n'
      '- When you change a page later, keep its <title> so Publish updates the same address.\n';

  static const _deliver = '## Delivering\n'
      '- Deliver only when the check passed (see $reviewId). While you work, short progress lines (say) at real milestones; never a '
      'final-looking "here is your site" before it is done.\n'
      '- The final reply: one line on what you made and the direction you took, two or three lines on what is in it, any marked '
      'spots they must fill, then the ```file card with the full path of index.html (the card has Open and Publish). End with one '
      'offer: a tweak they are likely to want (another direction, a section, publishing).\n'
      '- If something could not be fixed, say exactly what and why, in one line. Never call broken work finished.\n';

  // ---------------------------------------------------------------- bodies

  static const _web = '## When to use\nThe user wants a website, landing page, portfolio, web page or web app, or wants one improved.\n\n'
      '## Process\n'
      '1. Understand the brief: who it is for, what the visitor should do (call, buy, book, read, sign up), what content the user '
      'gave, and every instruction (name, colours, sections, language, what to avoid). Write that list down in your head and keep it.\n'
      '2. Ask only what truly changes the result and is not already said: usually the style direction (if none given) and real '
      'details only the user knows (contacts, prices). One ask_user, up to 3 questions, with likely answers to tap.\n'
      '3. Plan: the sections the visitor needs in a sensible order (not a stock list), the design tokens for the chosen direction, '
      'and the files. todo with every step.\n'
      '4. Build complete files, part by part (below).\n'
      '5. Check and fix (skill $reviewId). SubMac also checks every page you wrote before your final reply and sends back what fails.\n'
      '6. Deliver (below).\n\n'
      '$_freedom\n$_fundamentals\n$_content\n$_build\n$_deliver';

  static const _ui = '## When to use\nThe user wants app screens, a dashboard, a form, components or a design system designed or '
      'improved, as an HTML prototype or as real code (Flutter, React, another framework).\n\n'
      '## Process\n'
      '1. Understand the task each screen serves: who uses it, the one main action, what data it shows, and every instruction given.\n'
      '2. Follow what already exists: in an existing app, read its theme, tokens and a few screens first and design inside that '
      'system (same spacing, radius, type and colour roles). New look only when asked.\n'
      '3. If there is no system and no preference, offer 2-3 directions (below).\n'
      '4. Plan the screens and their states, then build them completely; run or render them where a tool allows (code_run, '
      'code_build test, the page preview) and fix what fails.\n'
      '5. Deliver with what changed, how it was checked, and the file or the screens.\n\n'
      '$_freedom\n$_fundamentals\n'
      '## Interface specifics\n'
      '- Navigation shows where you are and how to go back. The primary action is easy to reach with a thumb on phones.\n'
      '- Forms: one column, labels above fields, helpful errors next to the field, the right keyboard type, sensible defaults.\n'
      '- Lists and tables: align numbers right, keep labels short, make rows easy to scan, show an empty state that says what to do.\n'
      '- Dashboards: the few numbers that matter first, then trends, then detail. Label every number with its unit and period.\n'
      '- Text scales with the system font size; layouts survive long words and right-to-left languages.\n'
      '- In code, use the project\'s own tokens and components; never scatter one-off colours, sizes or durations.\n\n'
      '$_content\n$_deliver';

  static const _review = '## When to use\nBefore delivering anything visual: a website, page, screen, poster, document or slide.\n\n'
      '## The check\n'
      '1. Complete: every file ends properly (a page has its closing </body></html>, every tag and brace is closed, no file stops '
      'halfway). Run code_check on the folder (or file) and fix every problem it lists.\n'
      '2. Nothing broken: every local picture, style, script and page that is referenced exists in the folder; every in-page link '
      '(#section) has a matching id; no external picture you have not confirmed.\n'
      '3. Phone width: read the page as if 360px wide. No fixed widths wider than the screen, no text smaller than body size, no '
      'sideways scrolling, tap targets big enough, the main action visible early.\n'
      '4. Readable: text contrast against its background, headings that read as headings, comfortable line length.\n'
      '5. Real: no lorem ipsum, no invented facts, every marked spot listed for the user.\n'
      '6. Faithful: re-read the user\'s request and every choice they made (colours, fonts, sections, wording, language). Each one is in.\n'
      '7. Considered: hierarchy is clear, spacing is consistent, one accent for action, states (hover, focus, empty, error) exist.\n'
      '8. If a real look is possible (a screenshot of the page from a tool), use it and fix what looks wrong.\n\n'
      '## After the check\n'
      '- Fix what failed, then check again. Two rounds are usually enough; if something still fails, say exactly what in the final reply.\n'
      '- Say briefly how you checked it, with the real result, never "it should work".\n';

  static const _replies = '## When to use\nShaping any answer that is more than a sentence or two.\n\n'
      '## Pick the form that fits the content\n'
      '- A fact or a short answer: plain sentences, answer first.\n'
      '- How to do something: numbered steps, one action each.\n'
      '- Options to choose from: a short list with one pick and why; a ```table card when they differ on several points.\n'
      '- Numbers the user gave or a tool returned: a ```diagram card (bars to compare, line for change over time, donut only for '
      'parts of a whole with few parts, stats for a few headline numbers). See skill $chartsId.\n'
      '- A process, timeline, plan or hierarchy: a ```diagram card (steps, roadmap, tree, cycle).\n'
      '- A long answer, plan, itinerary or briefing: a ```summary card with a title and short sections.\n'
      '- Something they will keep, print, send or edit: a real file (make_document) with its ```file card. See skill $docsId.\n'
      '- Something visual they asked for: a picture (code_media for exact text and graphics, generate_image for photo-like scenes).\n'
      '- Words they will send as their own: a ```template card.\n'
      '- A choice they must make now: ```choices with 2-5 short answers.\n'
      '- Most replies need no card. Never two cards that say the same thing.\n\n'
      '## Clean formatting\n'
      '- Lead with the outcome. Short paragraphs (one to three sentences). Bold only the few words that matter.\n'
      '- Headings only for long answers. Bullets for parallel items, not for an argument.\n'
      '- Never a markdown table in chat (use the table card). Never raw JSON, paths or tool names in text.\n'
      '- Match the user\'s language and length. No filler, no recap of your steps, no emoji, one useful offer at the end at most.\n';

  static const _timing = '## When to use\nAny task that takes more than one step.\n\n'
      '## Rhythm\n'
      '- Start: one short line on what you are doing, then begin in the same reply.\n'
      '- During: a `say` line only at real news: a milestone done, something found, a problem, a change of plan, or after a long '
      'quiet stretch. Never a line per step, never the same line twice.\n'
      '- Questions: only when something only the user can decide blocks the work. Ask once, all together, and keep working on what '
      'does not depend on the answer.\n'
      '- Final: exactly one, when the work is complete and checked. Never a "done" message followed by another "done" message; never '
      'a final-looking reply before the files exist and passed their check.\n'
      '- If the task must pause (a limit, a blocker), say what is done, what is left, and the one thing that resumes it.\n'
      '- If the user writes while you work, answer that first in one line, then carry on.\n';

  static const _docs = '## When to use\nAny document, sheet or slide deck the user will keep, print, send or present.\n\n'
      '$_freedom\n'
      '## Structure first\n'
      '- Decide the reader and the one thing they must take away. Order the content so it arrives early.\n'
      '- Documents: a clear title, short sections with real headings, short paragraphs, lists for parallel items, tables for '
      'comparisons, page numbers on longer documents. A CV fits the field and region the user named.\n'
      '- Sheets: one table per sheet, a header row, units in headers, totals clearly marked, formulas rather than typed results.\n'
      '- Slides: one idea per slide, a headline that states the point, few words, one visual per slide, consistent placement.\n\n'
      '## Typography and styling\n'
      '- One or two type families, a clear size scale for title, headings and body, consistent spacing, aligned edges.\n'
      '- Colour used sparingly and with a role (headings or one accent), in the user\'s brand or chosen direction.\n'
      '- Real content only: never invent their details; mark spots to fill and list them.\n\n'
      '## Before sending\n'
      '- Read the file back (read_pdf or open it) and check: nothing cut off, every section there, the user\'s instructions met. '
      'Then the ```file card with one line on what it is.\n';

  static const _charts = '## When to use\nShowing numbers: a chart card, a dashboard, an infographic or a chart in a document.\n\n'
      '## Pick by the question\n'
      '- Compare amounts: bars (sorted unless the order means something).\n'
      '- Change over time: a line (or columns for a few periods).\n'
      '- Parts of a whole: a donut or stacked bar, only with a few parts that add up.\n'
      '- Relationship between two measures: scatter.\n'
      '- One or a few headline numbers: stats, with the change and the period.\n'
      '- Many exact values: a table, not a chart.\n\n'
      '## Honest and clear\n'
      '- Real numbers only, from the user or a tool. Never invent or round away what matters.\n'
      '- Bars start at zero. Label axes and units. Say the period and the source.\n'
      '- Few colours, each with a meaning; highlight the one thing that matters and keep the rest quiet.\n'
      '- A one-line takeaway above or below the chart says what it shows.\n';
}
