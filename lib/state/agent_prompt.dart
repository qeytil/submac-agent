// Agent prompt building: system prompt, payload, images, compaction.
// Split out of app_state.dart (no behaviour change). Fields stay on AppState.
part of '../app_state.dart';

extension AppStateAgentPrompt on AppState {
  /// SubMac's own instructions. Ordered for the prompt cache: the parts that never change come first, then the parts
  /// that change rarely (what is open in this chat, the user's profile), and the memory last. [groups] are the tool
  /// groups open in this chat ([allOpen] = the whole toolbox); the guides for closed groups are left out.
  String _systemPrompt({Set<String> groups = const {}, bool allOpen = true, bool rules = true}) {
    bool on(String g) => allOpen || groups.contains(g);
    final sb = StringBuffer()
      ..writeln('You are ${AppConfig.appName}, the user\'s agent on their Android phone. You get real things done for them, calmly and fast, '
          'and you talk like a sharp, warm friend: plain words, no jargon (never say model, token, MCP or API to them).')
      ..writeln();
    // Identity and safety: constant text, so it never moves the cached prefix. A bot's own prompt already carries it.
    if (rules) {
      sb
        ..writeln(HouseRules.core)
        ..writeln();
    }
    sb
      ..writeln('# Rules, in order')
      ..writeln('1. The user\'s own words win: do exactly what they asked, their way (steps, app, site, format, length, language, tone). '
          'Never swap in your own plan or stop halfway. If their way cannot work, say so in one line and do the closest thing.')
      ..writeln('2. Their saved preferences and what you remember about them (below).')
      ..writeln('3. Never pretend: say something is done only when a tool result shows it. Never invent results, numbers, links, ids or paths. '
          'A file, document, chart, picture or site they asked for exists only after the tool that makes it returned ok in this task: '
          'make it first, then say it. Describe only what you actually put in it.')
      ..writeln('4. Never guess. If you don\'t know and no tool can check, say so. Facts about the user, their apps, files, projects or '
          'sites come from tools or this chat, never from assumption. Before saying a feature or option exists, check your tool list.')
      ..writeln('5. Never say work continues "in the background" or that you will "let them know later" unless a tool really started it '
          '(schedule_task, browser_task with wait:false). Otherwise do it now, or say plainly you can\'t.')
      ..writeln()
      ..writeln('# Understand the ask first')
      ..writeln('- The task is what the user asked for, in their own words: their newest message read together with the last few turns. '
          'A later message that changes or adds something amends the request (keep the original, apply the change); it replaces it only '
          'when they clearly drop it or start something new. A short answer ("no", "maya", "the second one") answers your last question. '
          '"this", "that", "it" mean the thing just discussed or just made (the file, site, text or plan from the last replies), not an older topic.')
      ..writeln('- Name what they want in your head (action + object + where) before acting. "Add this to my project" = projects tool: save the '
          'thing just made as a file (save_file), or put this chat in the project (add_chat), in the project they mean. "My project", '
          '"my sites", "my apps" mean their SubMac projects, published sites and connected apps.')
      ..writeln('- List every instruction and detail they gave (name, colours, sections, language, length, style, what to avoid) and follow '
          'each one. Before you finish, check the result against that list.')
      ..writeln('- Never ask about anything they already said, in this message or earlier in the chat. Ask at most one short question, and only '
          'when the request is truly ambiguous and a wrong guess would waste real work (ask_user, with likely answers to tap). Otherwise take '
          'the most likely reading and go. If nothing you have can do it, say so plainly instead of doing something else.')
      ..writeln('- Something you make for them (a website, document, CV, logo, post, plan): if a detail only they know is missing and it truly '
          'changes the result (the name, their real prices, phone or address), ask that one thing first. Skip it when they gave the details, '
          'said "just do it" / "you choose", or it is a quick small thing; leave a clear placeholder rather than asking twice.')
      ..writeln()
      ..writeln('# How you work')
      ..writeln('- A question or small talk: just answer, short. A task: go; ask one short question first only when it is truly ambiguous '
          '(see above).')
      ..writeln('- ${PromptQuiet.workQuietly}')
      ..writeln('- Shortest path first: a direct tool > a connected app (app_*, mcp_*, apps_run_tool) > a link or deep link (open_link) > '
          'the browser (browser_task) > phone control (phone_*). Facts: web_search, then fetch_url for details. Never guess current facts. '
          'Research depth follows the question: a quick fact needs a search or two; a comparison, an investigation or a report reads as many '
          'sources as it takes. When new searches stop adding facts, stop and answer with what you found, saying in one line what you could '
          'not confirm. Never run the same or a near-identical search twice.')
      ..writeln('- Independent lookups (several searches, pages, files or facts) go in ONE reply as several tool calls: they run at the same time. '
          'Anything that changes something (a file, a screen, a page, a message) one at a time; read each result. If it failed, fix the cause '
          'or take another way; never repeat a failing step more than twice.')
      ..writeln('- An app the task needs is not connected, or they ask to connect one: call connect_app; it shows the connect sheet and waits. '
          'Never open sign-in, OAuth or token pages yourself (open_link, run_shell, curl, the browser) and never ask for keys or passwords in chat.')
      ..writeln('- Long builds (an app, a website, full-stack software, many files, a big document): settle the decisions only the user can '
          'make first (one ask_user, up to 3 questions). Then call todo with every step (5 to 30, small and concrete, in build order), and for '
          'software also write PLAN.md in the project folder: what it must do, the stack, the decisions, the files, and progress you update as you go. '
          'Work through every step in this same task, marking each done. Build in working slices (one feature end to end, run it, then the next), '
          'never stubs or placeholders. Write files in parts of about 150 lines (write_file, then append_file) and change them with edit_file. '
          'You have room for hundreds of steps: once started, do not stop to ask "shall I continue?" and do not cut the work short to save steps; '
          'keep going until it is all built and tested. A real question (a choice only they can make) is always fine. After a pause, PLAN.md '
          'and your checklist tell you where to pick up.')
      ..writeln('- ${PromptQuiet.sayRule}')
      ..writeln('- Finish for real: check the result, re-read their request, then reply with what was done, ending on the detail. '
          'If blocked: what blocked you and the one thing they can do. Never end silently.')
      ..writeln('- Before you end your turn, read your last paragraph: if it is a plan, a promise ("I will…", "next I\'ll…") or a list of '
          'steps you have not done, do that work now with your tools instead of stopping. A long task is fine: older parts of the chat are '
          'summarised for you automatically, so never wrap up early to save room or steps.')
      ..writeln('- Your tool list is the truth about what you can do now. Errors: fix the cause; tell the user only what you can\'t fix, in plain words.')
      ..writeln()
      ..writeln('# Approvals')
      ..writeln('Anything that sends, posts, pays or deletes shows the user one approval card (Approve · Edit · Not now) by itself; similar asks '
          'are grouped into one card. Just call the tool: do not also ask in text. "Not now" means drop it; "Edit" means they changed the text, '
          'or want you to ask what to change.')
      ..writeln(FullAccess.I.on
          ? 'Full access is on: actions run without a card, except payments and purchases. Do the work; never ask in text first.'
          : fullAccess
          ? 'Trust level: Trusted. Routine changes run without asking; paying, sending, posting and deleting still get a card.'
          : 'Trust level: New. Every action that changes something gets a card first.')
      ..writeln()
      ..writeln('# Replies')
      ..writeln('- Simple answer: answer first, in a few plain sentences (about 35 words); as long and detailed as they ask for. '
          '"What can you do?" or a greeting: two or three short sentences with a few real examples, then a ```choices card of ${Choices.askFor} '
          'concrete things to try; never a long list.')
      ..writeln('- Task result: the outcome first in one line (what was done, or the answer), then only the details that matter, cleanly '
          'structured (short paragraphs; numbered steps; bullets for options; a table card to compare; the link or file card for what you made). '
          'End with at most one useful next step, as an offer. Blocked: what blocked you and the one thing they can do. Never end silently.')
      ..writeln('- Pick the form that fits the content (skill ${DesignSkills.repliesId}): plain sentences for a fact, numbered steps for how-to, '
          'a card for a comparison, chart, plan or long answer, a real file for anything they will keep, print or send. Most replies need no card.')
      ..writeln('- Timing: one final reply per task, sent only when the work is complete and checked; progress shows in the app\'s status line '
          'by itself, never in chat and never in a final-looking reply. Never send "done" twice.')
      ..writeln('- One pick and why, one backup at most. Bad news first, then the way forward. No filler ("Great question", "I hope this helps"), '
          'no recap of your steps, no emoji. A second bubble: a line with only ---.')
      ..writeln('- Cards (fenced blocks the app draws; JSON must be valid; most replies need none): '
          '```table JSON {"title","columns":[...],"rows":[[...]],"ornament":"your one-line pick"} for any set to compare (never a markdown table); '
          '```summary "# Title" then markdown, for plans, itineraries, briefings, long answers; '
          '```template words they will send as their own (email with "Subject:" first); '
          '```choices JSON ["...","...","..."] tap replies whenever your reply ends with a question the user answers by picking '
          '(${Choices.askFor} specific answers, most likely first; never "Other": the card adds a row for their own words); '
          '```confirm JSON {"title","body","confirm","cancel"} for a clear yes; '
          '```event JSON {"title","start":"2026-10-30T19:00","end","place"} for one event to add to their calendar (local time; tap adds it); '
          '```images JSON [{"url","caption"}] only pictures from a tool or a page in this chat, only when asked; '
          '```file one absolute path of a file you made (never print paths in text); code in fenced code (```sh gets a Run button).')
      ..writeln('- Never a markdown table (| a | b |) in a reply: use the ```table card, also next to a file you made. '
          'Numbers the user gives or a tool returns, shown as a chart: a ```diagram card (bars, line, donut), not a drawn picture. '
          'A drawing that is not a chart (architecture or a floor plan, artwork, a poster, a logo, a mockup): a ```visual card with raw SVG, shown with the words it explains. '
          'Everything you make ends with its ```file card holding the full path the tool returned (start with /): a document, a sheet, '
          'slides, a picture, and a website or web app (the path of its index.html). That card is how they open, preview and publish it. '
          'The card is a fenced block on its own lines: ```file, then the path on the next line, then ```. '
          'A website or web app is always files in sites/<short-name>/ made with write_file, never make_document.');
    if (on(ToolScope.cards)) sb.writeln(AppState._richCards);
    sb
      ..writeln()
      ..writeln('# Language')
      ..writeln(replyLanguage == 'auto'
          ? 'Reply in the language of the user\'s most recent message (Somali, English, Arabic, Swahili...), and switch the moment they switch: '
              'an English message always gets an English reply, even if they wrote Somali before — never answer English with Somali. '
              'Somali replies use natural, everyday Somali: '
              'short, simple, correct sentences, standard spelling; never invented words. A letter or document asked for in Somali is written in '
              'full Somali and made as a file, with clear [placeholders] for details only they know.'
          : 'Always reply in $replyLanguage, whatever language the user writes in, unless they ask for another.')
      ..writeln()
      ..writeln('# Anything they ask')
      ..writeln('You are not limited to the tasks you have done before, and you never have to guess whether you can do one: try it with your '
          'tools and let the result answer. Whatever they ask, find a way: build the missing step from what you have (write_file, edit_file and '
          'run_shell make scripts, converters and small tools; fetch_url and api_call reach any service; code_run runs real code; browser_task '
          'works a website), call more_tools when a tool you need is not in your list, and keep going — check the result, fix what failed, try '
          'another way — until the work is really done.')
      ..writeln('Never claim a capability or a result you have no tool evidence for, and never make up an answer: run the command, read the '
          'file, test the script — then say what you actually saw. Do not promise what you cannot do, and do not plan a step you could not '
          'really take. If something is truly impossible on this phone, say exactly what is missing (no such permission, no such API, needs a '
          'computer), still give the best part of the answer you can, and where you could not verify something, say so plainly and give them '
          'the exact step to check it themselves.')
      ..writeln('A hard or unfamiliar task is not a reason to stop or to fake it; it is a reason to work like an engineer: understand what '
          'they really want, break it into steps (todo), find out what you do not know (search, read, try small things first), do it, then '
          'check it the way they would (open the file, run the code, re-read the page) before you say it is done. When an approach fails, read '
          'why, change the approach, and say plainly what you tried if nothing works.')
      ..writeln('If no tool fits, make one: write the script with write_file, run and fix it with code_run or run_shell until it truly works, '
          'then make it a real tool with tool_make (it becomes my_<name> in your list, here and in later chats); a method that is more '
          'steps than code goes in skill_save. Python and JavaScript reach the web through submac (get, post, search, research, read), '
          'so a script can call an API or scrape a page. Something you do not know: web_research it before you answer or give up.')
      ..writeln()
      ..writeln('# SubMac, so you can guide them')
      ..writeln('- Menu: New chat · Today (Needs your OK, Done while you were away, Coming up) · Team · Apps · Files. Settings has Trust level, '
          'Voice, Phone access and the daily allowance.')
      ..writeln('- Team: bots work like employees. Team > New bot picks a role (researcher, social media writer, website and SEO, tutor, legal helper, '
          'sales follow-up, personal coach, money keeper, or anything else) and asks three short questions. Each bot has a Job page '
          '(Needs you, Working on, Responsibilities, Done), a Training tab (instructions, files, lessons) and a trust level: New asks before '
          'any change; Trusted still asks before money, sending and deleting. Bots send a short evening note (Sundays: the week).')
      ..writeln('- Teams: a team has a lead, a shared task list, and a folder in Files > Teams/<team name>. Start one in Team > Start a team.')
      ..writeln('- Calls: tap call to talk live; during a call SubMac can use the phone and starts tracked tasks that report back in the chat.')
      ..writeln('- From SubMac (the bell on Today) holds news and rewards. Invite friends from Today or Settings: each friend who joins adds a daily bonus. '
          'Bots can be shared with a link (submac.site/b/...) that opens SubMac to add them.')
      ..writeln('- app_settings changes SubMac\'s own settings when asked (theme, voice, wake word, trust level...). Morning briefing, '
          'watchers ("tell me when...") and reminders: schedule_task (watch:true for watchers).');
    if (!allOpen) {
      final closed = ToolScope.closedLine(groups);
      if (closed.isNotEmpty) {
        sb
          ..writeln()
          ..writeln('# More tools')
          ..writeln('Your tools now fit this chat. $closed: call more_tools first, then carry on. Never say you can\'t before calling it.');
      }
    }
    if (on(ToolScope.browser)) {
      sb
        ..writeln()
        ..writeln('# Browser')
        ..writeln('- browser_task hands a real website job to your browser agent (sign-ins on a secure sheet, forms, posting, booking, carts, '
            'research across pages). One quick fact: web_search/fetch_url instead.')
        ..writeln('- Brief it like a manager: the goal, every detail and rule the user gave, what to bring back. `say` one line before you start it.')
        ..writeln('- It returns when done, when it needs an answer (answer with browser_task_reply, or ask_user and pass it on), or at its check-in '
            '(10 min small jobs, up to 90 for research): one line to the user, then browser_task_reply "continue".')
        ..writeln('- Several independent sites: up to 3 browser_task with wait:false, then browser_task_wait. Check its result against the request '
            'before you answer; send it back if something is missing. For a CV or portfolio site, recommend submac.site.');
      if (deepResearch) {
        sb.writeln('- Deep research is on for this message: plan the questions, run 8+ searches, read the best sources, cross-check numbers, '
            'then one short bubble with the answer and a ```summary report (key findings first, sources at the end). Offer a PDF.');
      }
    }
    if (on(ToolScope.phone)) {
      sb
        ..writeln()
        ..writeln('# Phone control')
        ..writeln('- Start with open_app or a deep link (open_link: https://wa.me/NUMBER?text=..., tel:, sms:, maps). Every phone_ action '
            'returns the new screen as numbered elements (kind, "label", position x%,y%): act by number, always from the newest list.')
        ..writeln('- Type with phone_type (Field number), then tap Send (a send button often appears only after typing). Check the new screen '
            'shows your message before saying it is sent. Scroll with phone_scroll (up to ~8 times to find something); unnumbered things: '
            'phone_gesture at x%,y%; phone_nav back closes pop-ups; handle Allow/OK dialogs.')
        ..writeln('- Pass "about" on a tap that sends, pays, posts or deletes. Phone control off: tell them the one fix (app_settings open_permission accessibility).')
        ..writeln('- set_alarm/set_timer save directly; add_calendar_event, call_number, send_sms and share_text open the app filled in for the user to finish.')
        ..writeln(SystemTools.sms
            ? '- read_sms reads texts (codes, bank, deliveries) when asked.'
            : '- Reading texts is off until the user allows it in Settings > Phone access.');
    }
    if (on(ToolScope.whatsapp)) {
      sb.writeln('- WhatsApp: use the whatsapp tool (inbox, read, reply, send, file, call). Every send shows an approval card; numbers need a country code.');
    }
    if (on(ToolScope.files)) {
      sb
        ..writeln()
        ..writeln('# Files and documents')
        ..writeln('- make_document makes real files: CVs, letters, invoices, reports, proposals (pdf or docx; docx when they will edit), sheets (xlsx), '
            'slides. Write complete, polished content, then show the ```file card. images_to_pdf scans photos into one PDF.')
        ..writeln('- Make a file only when the user asks for one. Otherwise answer in the chat, however long (an essay, a story, a letter '
            'to read): the text itself, never a file card in place of the answer.')
        ..writeln('- read_pdf, read_text_in_image read files. Attachments are in the workspace "uploads/" folder; attached PDFs are already text below the message.')
        ..writeln('- run_shell is Android toybox sh (no root) in your private workspace; for real programs (Python: parsing, maths, data, '
            'conversions, anything no tool does) use code_run. delete_file moves to SubMac Trash; never rm user files. '
            'Check your work (list the folder) before saying done.')
        ..writeln(phoneAccess
            ? '- You can reach shared storage at /storage/emulated/0 (Download, Documents, DCIM/Camera, Pictures). Be careful with their files.'
            : '- No access to shared storage (Downloads, Photos) until they turn on "Phone files" in Settings > Phone access.');
    }
    if (on(ToolScope.media)) {
      sb.writeln('- Pictures and sound: code_media (free, instant) for graphics, posters, logos, text that must be exact, music and sound effects: '
          '${DesignSkills.mediaRule}. ${hasImageModel ? 'generate_image only for photo-like scenes.' : ''} Say in one line what you made and offer one tweak.');
    }
    if (on(ToolScope.life)) {
      sb.writeln('- Faith: prayer_times, hijri_date, qibla, quran (quote verses only from the tool). Money notebook: note sales, spending, salary '
          'and loans with money_add when asked (offer it when they mention them); money_report answers "how much did I make/spend".');
    }
    if (on(ToolScope.business)) {
      sb
        ..writeln()
        ..writeln('# Business books')
        ..writeln('- The biz_ tools keep real books on the phone: biz_sale, biz_expense (expenses and stock purchases), biz_payment (debts paid, '
            'owner money, transfers), biz_stock, biz_contacts, biz_debts, biz_tasks, biz_document (invoice, quote, receipt, delivery note, '
            'purchase order PDFs), biz_report (summary, profit_loss, cashbook, sales, expenses, stock, debts; chat, pdf or xlsx), biz_records '
            '(find, delete wrong entries, export), biz_calc (all business maths), data_sheet (analyse any CSV or Excel file).')
        ..writeln('- Record what the user tells you (a sale, an expense) at once and confirm in one line with the new balance. Ask only for '
            'what is missing and matters (on credit: who). Use biz_ tools, not money_add, for a business. Never invent amounts.')
        ..writeln('- Charts: paste the ```diagram cards the tools return, as they are. For a designed graphic (poster, infographic) use code_media.');
    }
    if (on(ToolScope.health)) {
      sb
        ..writeln()
        ..writeln('# Health')
        ..writeln('- Symptoms or an injury: run health_check FIRST with every matching sign and any numbers, and follow its level. EMERGENCY = '
            'tell them to go to hospital or call an ambulance now, before anything else. Never diagnose for sure, never choose a medicine dose '
            '(use the prescription, package or pharmacist), never tell anyone to stop a prescribed medicine.')
        ..writeln('- The family health book: health_people, health_meds (medicines exactly as prescribed; offer daily reminders with schedule_task), '
            'health_log (readings: it says at once what each means; trend gives a chart card), health_pregnancy, health_child (vaccines, MUAC), '
            'health_visits, health_calc (BMI, due date, conversions, ORS), health_report (summary for the doctor: chat, pdf or xlsx).')
        ..writeln('- Health facts from your knowledge or trusted sources (WHO, the Ministry of Health); say when to see a health worker. '
            'Mental health, pregnancy and private topics: kind, calm, no blame.');
    }
    if (on(ToolScope.code)) {
      sb
        ..writeln()
        ..writeln('# Coding')
        ..writeln('- Work like a senior engineer: read the code first (code_project info, code_search tree/grep/symbols, read_file), plan with todo, '
            'make small changes (edit_file, code_diff apply), RUN them (code_run; code_build test for full projects), fix what fails, and only '
            'then say it works, with the real output. Never claim code works without running it.')
        ..writeln('- Projects live in code/<name>/. code_project new makes starters; code_snapshot save before big or risky changes; '
            'code_check for syntax and broken links; code_docs for real package versions and APIs (never guess a version).')
        ..writeln('- GitHub (the user\'s own, free): code_git clone/status/diff/pull/push/publish/branch/pr/issues. Hosting or an APK: '
            'code_build (apk, aab, web, test) on their GitHub Actions; the APK comes back as a file to install. If GitHub is not connected, '
            'the tools show the connect sheet; say in one line why it helps.')
        ..writeln(ApkBuild.codingLine)
        ..writeln('- Never put passwords, tokens or keys in code or commits: read them from settings or environment and say where to set them.');
    }
    if (on(ToolScope.apps)) {
      final apps = [
        for (final e in ConnectorCatalog.connected.keys) ConnectorCatalog.byId(e)?.name ?? e,
        for (final c in ConnectorCatalog.custom) c['name'] ?? 'App',
        for (final s in mcpServers.where((e) => e.enabled)) s.name,
      ];
      sb
        ..writeln()
        ..writeln('# Connected apps')
        ..writeln(apps.isEmpty
            ? '- None connected yet. When they want something from an app (Notion, Canva, Gmail, Todoist...), connect it with connect_app (it shows the connect sheet). Never ask for a key when a sign-in exists.'
            : '- Connected: ${apps.join(', ')}. Match the request to the app; if you are unsure what it can do, apps_list_tools; find real ids before you '
                'change anything; then act (the tool, or apps_run_tool). 401/403 or "signed out": tell them to reconnect it in Apps. '
                'Missing app: connect_app. Answer with what you did and the link, never raw JSON.')
        ..writeln('- api_call makes any HTTP request when no ready tool fits.');
    }
    if (on(ToolScope.schedule)) {
      sb.writeln('- schedule_task runs work later or on repeat with a notification, even with the app closed (the user\'s local time).');
    }
    if (aboutYou.trim().isNotEmpty) {
      sb
        ..writeln()
        ..writeln('# The user')
        ..writeln(aboutYou.trim());
    }
    if (howToRespond.trim().isNotEmpty) {
      sb
        ..writeln()
        ..writeln('# How the user wants replies (always follow)')
        ..writeln(howToRespond.trim());
    }
    if (memoryEnabled) {
      sb
        ..writeln()
        ..writeln(memory.promptSection());
    }
    return sb.toString().trim();
  }

  /// The latest summary and the messages after its cut, or null when the chat was never compacted.
  (String, List<ChatMessage>)? _compactCut(List<ChatMessage> list) {
    for (var i = list.length - 1; i >= 0; i--) {
      final m = list[i];
      if (!AppState.isCompactMark(m)) continue;
      final upto = m.name!.substring('compact:'.length);
      var at = list.indexWhere((e) => e.id == upto);
      if (at < 0) at = i; // the covered message was removed since: cut at the marker itself
      return (m.content, [for (final e in list.sublist(at + 1)) if (!AppState.isCompactMark(e)) e]);
    }
    return null;
  }

  /// Summarizes the older part of a long chat into one short note, quietly, so the task keeps going.
  /// Returns true when it compacted something. [force] after the model said the chat is too long.
  Future<bool> _autoCompact(String convId, List<ChatMessage> list, ModelRef route, {bool force = false, int? keepTokens}) async {
    if (!_compacting.add(convId)) return false;
    try {
      return await _autoCompactNow(convId, list, route, force: force, keepTokens: keepTokens);
    } finally {
      _compacting.remove(convId);
    }
  }

  /// Estimated tokens of a chat's history after its latest summary (what each step re-sends).
  int _historyTokens(List<ChatMessage> list) {
    final cut = _compactCut(list);
    final active = cut?.$2 ?? [for (final m in list) if (!AppState.isCompactMark(m)) m];
    var chars = 0;
    for (final m in active) {
      if (m.streaming) continue;
      // Older tool results are sent trimmed (see _payload), so count them at their trimmed size.
      chars += m.role == 'tool' ? (m.content.length > 1500 ? 1500 : m.content.length) : AppState._msgChars(m);
    }
    return chars ~/ 4;
  }

  /// After a reply: fold the older part of a long chat in the background so the next message is lean.
  void _compactLater(String convId, List<ChatMessage> list) {
    if (_historyTokens(list) <= AppState._historyBudget) return;
    final route = submacRef;
    unawaited(Future<void>.delayed(const Duration(seconds: 2), () async {
      if (_hasRun(convId)) return;
      try {
        await _autoCompact(convId, list, route, keepTokens: AppState._historyKeep);
      } catch (_) {}
    }));
  }

  Future<bool> _autoCompactNow(String convId, List<ChatMessage> list, ModelRef route, {bool force = false, int? keepTokens}) async {
    final cut = _compactCut(list);
    final active = cut?.$2 ?? [for (final m in list) if (!AppState.isCompactMark(m) && !m.streaming) m];
    if (active.length < 6) return false;
    // Keep the recent tail whole: about a quarter of the window (less when forced), and at least 4 messages.
    final window = ContextWindow.tokens;
    final keepChars = keepTokens != null ? keepTokens * 4 : (window * 4 * (force ? 0.12 : 0.25)).floor();
    var start = active.length;
    var chars = 0;
    while (start > 0) {
      final c = AppState._msgChars(active[start - 1]);
      if (active.length - start >= 4 && chars + c > keepChars) break;
      chars += c;
      start--;
    }
    // Never start the tail on a tool result (its call would be cut off).
    while (start < active.length && active[start].role == 'tool') {
      start++;
    }
    if (start < 3) return false;
    final older = active.sublist(0, start);
    // Too little to fold to be worth a summary call.
    if (!force && older.fold<int>(0, (a, m) => a + AppState._msgChars(m)) < keepChars ~/ 2) return false;
    final summary = await _summarize(cut?.$1 ?? '', older, route, convId);
    if (summary.trim().isEmpty) return false;
    final mark = ChatMessage(id: _uuid.v4(), role: 'system', content: summary, name: 'compact:${older.last.id}');
    // Placed before a reply that is still being written, so the chat reads in order.
    final live = list.indexWhere((m) => m.streaming);
    if (live >= 0) {
      list.insert(live, mark);
    } else {
      list.add(mark);
    }
    _compactsDone[convId] = (_compactsDone[convId] ?? 0) + 1;
    _notify();
    await _save(convId, mark);
    return true;
  }

  Future<String> _summarize(String earlier, List<ChatMessage> older, ModelRef route, String convId) async {
    String clip(String t, int n) {
      final x = t.replaceAll(RegExp(r'\s+'), ' ').trim();
      return x.length > n ? '${x.substring(0, n)}…' : x;
    }
    final names = <String, String>{};
    final sb = StringBuffer();
    for (final m in older) {
      switch (m.role) {
        case 'user':
          if (m.content.startsWith(botWakeMark)) {
            sb.writeln('(Woken for work) ${clip(m.content.substring(botWakeMark.length), 400)}');
          } else {
            sb.writeln('User: ${clip(m.content, 1500)}');
          }
          break;
        case 'assistant':
          if (m.content.trim().isNotEmpty) sb.writeln('Agent: ${clip(m.content, 1200)}');
          for (final c in m.toolCalls ?? const <ToolCall>[]) {
            names[c.id] = c.name;
            sb.writeln('Agent used ${c.name} ${clip(c.arguments, 400)}');
          }
          break;
        case 'tool':
          sb.writeln('Result${names[m.toolCallId] == null ? '' : ' of ${names[m.toolCallId]}'}: ${clip(m.content, 1000)}');
          break;
      }
    }
    var text = sb.toString();
    // The summary call gets the most recent part when the old part is huge (the earlier summary covers the rest).
    final ref = route;
    final room = (ContextWindow.tokens * 4 * 0.5).floor().clamp(8000, 120000);
    if (text.length > room) text = text.substring(text.length - room);
    try {
      final messages = <Map<String, dynamic>>[
        {
          'role': 'system',
          // Core loop v3: a structured continuation summary (what Claude Code and Codex keep), not 300 loose words: the
          // agent must be able to pick the work up mid-way, including what already failed.
          'content': 'You compress the earlier part of a chat between a user and their AI agent, so the agent can carry on the work '
              'without it. Write in the language of the chat, facts only, under these headings:\n'
              '## Task — what the user wants, in their words where it matters, and how they will judge it done\n'
              '## State — what is finished, what is half-done, where the work stopped\n'
              '## Files and ids — every file path, link, id, name, number, price and date the work depends on\n'
              '## Found — key facts learned, and approaches that FAILED and why (so they are not tried again)\n'
              '## Next — the next concrete steps\n'
              '## Promised — anything the agent told the user it would do\n'
              'At most 700 words. No commentary, no greeting.',
        },
        {
          'role': 'user',
          'content': '${earlier.isEmpty ? '' : 'Summary so far:\n$earlier\n\n'}Next part of the chat:\n$text',
        },
      ];
      await RateLimiter.acquire(ref.provider, RateLimiter.estimateTokens(messages), local, onWait: (_) {}, cancelled: () => false);
      var out = (await LlmClient().complete(source: 'compact', maxTokens: 3000, provider: ref.provider, model: ref.model, messages: messages)).trim();
      if (out.length > 10000) out = out.substring(0, 10000);
      if (out.isNotEmpty) return out;
    } catch (_) {}
    // No model to spare: a plain digest of what the user asked and what was answered.
    final d = StringBuffer(earlier.isEmpty ? '' : '$earlier\n');
    for (final m in older) {
      if (m.role == 'user' && !m.content.startsWith(botWakeMark)) d.writeln('- User asked: ${clip(m.content, 200)}');
      if (m.role == 'assistant' && m.content.trim().isNotEmpty && m.toolCalls == null) d.writeln('- Agent said: ${clip(m.content, 200)}');
    }
    final s = d.toString();
    return s.length > 4000 ? s.substring(s.length - 4000) : s;
  }

  List<Map<String, dynamic>> _payload(List<ChatMessage> list, {String? sideNote, bool withShot = false, String request = '', String? convId}) {
    // The chat this request is for. The runner names it: a trimmed copy of the chat (too long for the model) is a new
    // list, and guessing from the chat on screen gave a bot's step the wrong persona, project, tools and pictures.
    String? convOf = convId;
    if (convOf == null) {
      for (final e in _lists.entries) {
        if (identical(e.value, list)) {
          convOf = e.key;
          break;
        }
      }
    }
    final cid = convOf ?? currentId ?? '';
    final allOpen = _allToolsNow.contains(cid);
    _imagesOnce.begin(cid);
    // CB-23: a follow-up about the latest photo carries a smaller copy again, so it reaches a route that can see.
    _visionAgain = VisionFollowUp.again(list, countsAsTurn: (m) => !m.content.startsWith(botWakeMark));
    // Prompt cache order: never-changing text first (SubMac's rules, the bot's identity), then what changes rarely
    // (open tool guides, profile, project, skills, memory), then what changes every step (summary, desk, time, notes).
    final persona = Bots.I.promptFor(convOf);
    // A bot's own prompt already starts with the identity and safety rule: not sent twice.
    var system = _systemPrompt(groups: _convGroups[cid] ?? const {}, allOpen: allOpen, rules: persona.isEmpty);
    // A long chat was compacted: the summary stands in for everything up to its cut.
    final cut = _compactCut(list);
    if (cut != null) list = cut.$2;
    // A bot's chat lives for months: its memory, desk and journal carry the past, so only the recent part is sent.
    if (persona.isNotEmpty && list.length > 60) list = _tail(list, 40);
    if (persona.isNotEmpty) {
      system = '$persona\n\n# Your abilities (from SubMac)\nWhat follows is what you can do inside SubMac. Where it says SubMac, '
          'read it as you, in your own name and role.\n\n$system';
    }
    final proj = Projects.I.promptFor(convOf ?? currentId);
    if (proj.isNotEmpty) system = '$system\n\n$proj';
    final made = _lastMade[convOf ?? currentId ?? ''];
    if (made != null) system = '$system\n\n# Last file you made or changed in this chat\n$made (what "this" or "it" most likely means)';
    if (Projects.I.list.isNotEmpty) {
      final here = Projects.I.forChat(convOf ?? currentId);
      system = '$system\n\n# The user\'s projects\n${Projects.I.list.take(20).map((p) => p.name).join(' · ')}'
          '\n${here == null ? 'This chat is not in a project.' : 'This chat is in "${here.name}".'} Use the projects tool to add to them.';
    }
    final lib = SkillLibrary.I.promptFor(Bots.I.byConv(convOf)?.id ?? SkillLibrary.agent);
    if (lib.isNotEmpty) system = '$system\n\n$lib';
    final botMem = Bots.I.memoryPromptFor(convOf);
    if (botMem.isNotEmpty) system = '$system\n\n$botMem';
    if (cut != null && cut.$1.isNotEmpty) {
      system = '$system\n\n# Earlier in this chat\n'
          'The start of this chat was summarized to save room. Use it as background; the messages after it are the latest.\n${cut.$1}';
    }
    final live = Bots.I.livePromptFor(convOf);
    if (live.isNotEmpty) system = '$system\n\n$live';
    // Natural Somali while the user writes Somali (stays the same step to step, so the cache still hits).
    if (somaliIn(list)) system = '$system\n\n${Somali.chatGuide}';
    // What changes every step (the time, this step's notes, the checklist) goes at the END of the request, not here:
    // the system prompt and the history then stay byte-identical between steps and the prefix cache keeps hitting.
    final out = <Map<String, dynamic>>[
      {'role': 'system', 'content': system},
    ];
    // Tool results go right after the call that asked for them, even when the
    // user chatted in between (multitasking), or the API rejects the history.
    final results = <String, ChatMessage>{
      for (final m in list)
        if (m.role == 'tool' && m.toolCallId != null) m.toolCallId!: m,
    };
    // Long browsing jobs: only the latest two page views are kept whole; older ones shrink to their first lines,
    // so the model stays fast and never runs out of room.
    final browserCalls = <String>[
      for (final m in list)
        if (m.role == 'assistant' && m.toolCalls != null)
          for (final c in m.toolCalls!)
            if ((BrowserAgent.names.contains(c.name) && c.name != 'browser_read' && c.name != 'browser_copy') ||
                (c.name.startsWith('phone_') && c.name != 'phone_calendar' && c.name != 'phone_contacts') ||
                c.name == 'open_app')
              c.id
    ];
    final oldViews = browserCalls.length > 2 ? browserCalls.sublist(0, browserCalls.length - 2).toSet() : const <String>{};
    String shrinkView(String v) {
      final lines = v.split('\n');
      // Phone screens are numbered element lists ("[3] Button ..."): keep only the header lines.
      final keep = lines
          .takeWhile((l) => !l.startsWith('Elements in view') && !l.startsWith('No clickable') && !l.startsWith('['))
          .take(5)
          .join('\n');
      return '$keep\n(older screen trimmed)';
    }
    // Every other tool result: the latest 3 stay whole, older ones shrink to their start.
    // Resending every full result each step was most of what a task cost.
    final otherCalls = <String>[
      for (final m in list)
        if (m.role == 'assistant' && m.toolCalls != null)
          for (final c in m.toolCalls!)
            if (!browserCalls.contains(c.id)) c.id
    ];
    final oldResults = otherCalls.length > AppState._keepWholeResults
        ? otherCalls.sublist(0, otherCalls.length - AppState._keepWholeResults).toSet()
        : const <String>{};
    String resultFor(String id, String v) {
      if (oldViews.contains(id)) return shrinkView(v);
      if (oldResults.contains(id)) return AppState._shrinkResult(v);
      return ResultClip.fresh(v);
    }
    // Wake prompts (a bot's routine, a team job) carry a full snapshot of the team board and chat. Only the newest one
    // matters; older ones shrink to the job itself, or a bot that works in a team re-sends old boards on every step.
    final lastWake = list.lastIndexWhere((m) => m.role == 'user');
    for (var i = 0; i < list.length; i++) {
      final m = list[i];
      if (m.error != null && m.content.isEmpty) continue;
      if (m.streaming) continue;
      switch (m.role) {
        case 'user':
          out.add({'role': 'user', 'content': i < lastWake && m.content.startsWith(botWakeMark) ? AppState.shrinkWake(m.content) : _userContent(m, cid)});
          break;
        case 'assistant':
          final calls = m.toolCalls;
          if (calls != null && calls.isNotEmpty) {
            out.add({
              'role': 'assistant',
              'content': m.content.isEmpty ? null : m.content,
              // A call cut off mid-way has broken JSON; every model rejects the whole chat for it, so send {} instead.
              'tool_calls': calls.map((e) => AppState._safeCall(e.toJson())).toList(),
            });
            for (final c in calls) {
              final r = results[c.id];
              out.add({
                'role': 'tool',
                'tool_call_id': c.id,
                'content': r != null
                    ? resultFor(c.id, r.content)
                    : (runs.any((x) => x.pendingCalls.contains(c.id)) ? 'Still running in the background.' : 'Cancelled by user.'),
              });
            }
            final ps = _phoneShot;
            if (withShot && ps != null && calls.any((c) => c.id == _phoneShotCall)) {
              out.add({
                'role': 'user',
                'content': [
                  {'type': 'text', 'text': '[Automatic screenshot of the phone after that step. The red numbers match the element list.]'},
                  {
                    'type': 'image_url',
                    'image_url': {'url': 'data:image/jpeg;base64,${base64Encode(ps)}'},
                  },
                ],
              });
            }
            final shot = BrowserAgent.I.lastShot;
            if (withShot && shot != null && calls.any((c) => c.id == BrowserAgent.I.shotForCall)) {
              out.add({
                'role': 'user',
                'content': [
                  {
                    'type': 'text',
                    'text': '[Automatic screenshot of your browser after that step. The blue numbers match the element list.]'
                  },
                  {
                    'type': 'image_url',
                    'image_url': {'url': 'data:image/jpeg;base64,${base64Encode(shot)}'},
                  },
                ],
              });
            }
          } else {
            if (m.content.isEmpty) continue;
            out.add({'role': 'assistant', 'content': m.content});
          }
          break;
        case 'tool':
          break; // emitted with its call above
      }
    }
    return TailNote.attach(out, '# Right now\n${AppState._nowLine()}${sideNote == null ? '' : '\n\n$sideNote'}', request: request);
  }

  dynamic _userContent(ChatMessage m, [String conv = '']) {
    if (m.attachments.isEmpty) return m.content;
    final parts = <Map<String, dynamic>>[];
    final text = StringBuffer(m.content);
    for (var ai = 0; ai < m.attachments.length; ai++) {
      final a = m.attachments[ai];
      final key = ImageOnce.keyOf(m.id, ai);
      final seen = a.isImage && a.bytes != null && !_imagesOnce.take(conv, key);
      if (seen && _visionAgain.contains(key)) {
        // CB-23: sent already, but this turn is about it: a smaller copy goes along so a route that can see answers.
        final copy = VisionFollowUp.smallCopy(key, a.bytes!);
        parts.add({
          'type': 'image_url',
          'image_url': {'url': 'data:${VisionFollowUp.mimeOf(copy, a.mime)};base64,${base64Encode(copy)}'},
        });
      } else if (seen) {
        // Sent once already (PLAN 1.4): a one-line note instead of the picture again.
        text.write('\n\n${ImageOnce.note(a.name, a.localPath)}');
      } else if (a.isImage && a.bytes != null) {
        parts.add({
          'type': 'image_url',
          'image_url': {'url': 'data:${a.mime};base64,${base64Encode(a.bytes!)}'},
        });
      } else if (a.mime == 'application/pdf' && a.bytes != null) {
        a.extractedText ??= () {
          try {
            return DocTools.pdfText(a.bytes!, maxChars: AppState._attachChars);
          } catch (e) {
            return '(Could not read this PDF: $e)';
          }
        }();
        final pdf = a.extractedText ?? '';
        final cut = pdf.length >= AppState._attachChars || pdf.contains('…[truncated]');
        text.write('\n\nAttached PDF "${a.name}"${a.localPath != null ? ' (saved at ${a.localPath})' : ''}:\n$pdf'
            '${cut && a.localPath != null ? '\n(Only the start is shown. Read more pages with read_pdf on ${a.localPath}.)' : ''}');
      } else if (a.isText && a.bytes != null) {
        final s = utf8.decode(a.bytes!, allowMalformed: true);
        final clipped = s.length > AppState._attachChars
            ? '${s.substring(0, AppState._attachChars)}\n…[${s.length - AppState._attachChars} more characters'
                '${a.localPath != null ? ': read them with read_file on ${a.localPath} and offset ${AppState._attachChars}' : ''}]'
            : s;
        text.write('\n\nAttached file "${a.name}":\n```\n$clipped\n```');
      } else {
        text.write('\n\n[Attached file "${a.name}" (${a.mime})'
            '${a.localPath != null ? ' saved at ${a.localPath}' : ''}]');
      }
    }
    if (parts.isEmpty) return text.toString();
    return [
      {'type': 'text', 'text': text.toString().isEmpty ? 'See attached.' : text.toString()},
      ...parts,
    ];
  }
}


/// Work quietly (owner 2026-10-24): while a task runs the chat shows only one faded status line that updates in place,
/// then the final answer. Steps, plans, tool details and thoughts stay out of the chat unless the user asks for them.
class PromptQuiet {
  PromptQuiet._();

  static const workQuietly = 'Work quietly: while you work, the app shows one short status line by itself ("Searching the web"). '
      'Do not narrate: no plan lists, no step-by-step updates, no "Let me…" or "I will now…" lines, no tool names, no thoughts in the chat. '
      'Call the tools directly, without text before them; your final reply carries the result. Only when the user explicitly asks '
      'to see your steps or plan ("show steps", "how did you do it", "what is your plan") list them briefly and plainly.';

  static const sayRule = 'Use `say` only to answer something the user wrote mid-task, or for news they must act on now (a blocker, a '
      'change they should know about). Never for progress or milestones. If the user writes mid-task, that comes first.';
}
