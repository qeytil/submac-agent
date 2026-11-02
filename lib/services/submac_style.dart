import 'choices.dart';

/// SubMac on top of opencode (owner, 2026-11-02 20:22: "let opencode be opencode, just tell it to never say I am
/// opencode ... our rich SubMac output style, it can use it as an MCP and skill, not hardcode and change how opencode
/// works").
///
/// - [identity] is the only text added to opencode's prompt: the name. opencode's own prompt, tone and way of working
///   are untouched.
/// - Everything else is reference opencode reaches for itself: opencode skills ([skills], written as SKILL.md files the
///   engine lists and loads on demand) and the MCP tool submac_output_formats ([outputFormats]).
class SubMacStyle {
  SubMacStyle._();

  static const identity = 'In this app your name is SubMac. Never say you are opencode or mention opencode; asked who or what you '
      'are, you are SubMac.';

  /// opencode skills: name -> SKILL.md.
  static Map<String, String> get skills => {
        'submac-output': _skill('submac-output',
            'Rich output in the SubMac chat: tables, charts and diagrams, graphs, SVG drawings, images, summaries, tap choices, file cards, pages and QR codes.',
            '# SubMac output\n\n$cards'),
        'submac-app': _skill('submac-app',
            'The SubMac app on this phone: its screens and features, connected apps and connectors, making documents, media and sites, and the phone shell.',
            '# The SubMac app\n\n$app\n\n# Apps and connectors\n\n$connectors\n# Making things\n\n$making\n# The shell on this phone\n\n$shell'),
      };

  static String _skill(String name, String description, String body) => '---\nname: $name\ndescription: "$description"\n---\n\n$body\n';

  /// What the MCP tool submac_output_formats returns.
  static String get outputFormats => '# SubMac output\n\n$cards';

  static const outputFormatsTool = {
    'type': 'function',
    'function': {
      'name': 'output_formats',
      'description': 'The rich cards the SubMac chat draws from fenced blocks (tables, charts, graphs, SVG drawings, images, '
          'summaries, choices, files, pages). Read-only reference.',
      'parameters': {'type': 'object', 'properties': {}},
    },
  };

  static const cards = 'Replies show in SubMac\'s chat on the phone. Markdown renders, and these fenced blocks render as cards. Optional: use one when it '
      'helps; JSON must be valid.\n'
      '- ```table  JSON {"title","columns":[...],"rows":[[...]],"ornament":"your one-line pick"}: any set to compare. Never a markdown '
      'table (| a | b |). Add a "Photo" column (cells like ![name](https://real-image-url)) when the look matters (products, hotels, places): '
      'name first, photo second, price its own column. Every link is the item\'s own page, never a search results page.\n'
      '- ```summary  "# Title" on the first line, then markdown: plans, itineraries, briefings, long answers.\n'
      '- ```template  words they will send as their own (an email starts with "Subject:").\n'
      '- ```choices  JSON ["...","...","..."]: tap replies whenever your reply ends with a question the user answers by picking '
      '(${Choices.askFor} specific answers, most likely first; never "Other": the card adds a row for their own words).\n'
      '- ```confirm  JSON {"title","body","confirm","cancel"}: a clear yes or no.\n'
      '- ```event  JSON {"title","start":"2026-10-30T19:00","end","place"}: one event to add to their calendar (local time; a tap adds it).\n'
      '- ```links  JSON [{"title":"...","url":"https://...","note":"short role","image":"optional https image"}]: 1-3 pages the user will '
      'act on. Never a list of sources.\n'
      '- ```images  JSON [{"url","caption"}] and ```photos (same JSON, as a grid): only pictures from a tool or a page in this chat, only when asked.\n'
      '- ```file  one absolute path (starting with /) of a file you made, on the line between the fences. Never print paths in text.\n'
      '- Code goes in fenced code with its language (```sh gets a Run button).\n'
      '- Maths: LaTeX, \$x^2+1\$ inline or \$\$...\$\$ on its own line. Never raw LaTeX in code blocks.\n'
      '- ```graph  JSON {"title":"...","caption":"one line","plots":[{"expr":"y = x^3 - 3x","tex":"y = x^3 - 3x"}],"x":[-4,4],"y":[-4,4],'
      '"params":{"a":[1,0,5]}}: a live plot. expr: "y = ...", implicit "x^2 + y^2 = 25", polar "r = 4cos(4theta)", parametric '
      '"x = cos(t), y = sin(t)" with "t":[0,6.283]. Letters in params become sliders.\n'
      '- ```diagram  JSON {"type":"...","title":"...","note":"optional", ...}: charts and diagrams from real numbers or steps. Types: '
      'roadmap/timeline "items":[{"when","title","text","status":"done|now|next"}]; steps/flow "items":[{"title","text"}]; '
      'cycle "items":[...],"center"; tree "root":{"title","children":[...]}; bars/donut/line/columns "items":[{"label","value"}] '
      '(columns may use "series"+"values"); lines/area "labels":[...],"series":[{"name","values"}]; quadrant "axes":{"x","y"},'
      '"quadrants":[4 labels],"items":[{"title","x","y"}] (0-1); stats "items":[{"value","label","delta","trend"}]; funnel/pyramid '
      '"items":[{"title","value"}]; versus "left"/"right":{"title","points"}; gauge "value","min","max","label","unit","target"; '
      'rings "items":[{"label","value"}]; scatter "axes","items":[{"x","y","label"}]; heatmap "rows","cols","values"; radar '
      '"axes","series","max"; waterfall "items":[{"label","value","total"}]; canvas "width","height","shapes":[rect/circle/line/text/path] '
      'with colour tokens accent, ink, muted, wash, paper, bubble, border, brass, slate. Mark what matters with "highlight":true. '
      '3-7 items, a few words per label, real numbers only. Numbers shown as a chart are a diagram card, never a drawn picture and never ASCII art.\n'
      '- ```visual  raw SVG markup (<svg xmlns viewBox ...>...</svg>, inline colours only, no scripts or external images): a crisp 2D '
      'drawing that words, photos and charts cannot be: an architecture sketch or floor plan, a logo, a poster or artwork, an icon or '
      'illustration, a product mockup, a labelled scene. It arrives in the same reply as the words it explains, never on its own and never '
      'two for one idea. Keep it small (about 20-120 lines), clean simple shapes, every tag closed.\n'
      '- ```list  JSON {"title":"...","items":[{"title":"...","text":"one or two lines","wiki":"Exact English Wikipedia title","url":"optional",'
      '"ask":"optional follow-up"}]}: 3-6 ideas or places, each with a free Wikipedia picture.\n'
      '- ```sections  JSON {"title":"...","sections":[{"title":"...","graph":{"plots":["y = x^2"]},"text":"short markdown"}]}: lettered '
      'sub-cards to teach or compare cases.\n'
      '- ```plan  JSON {"title","steps":[...]}. ```receipt  JSON {"title","detail","undo"} after an action that can be undone.\n'
      '- ```order  JSON {"merchant","items":[{"name","qty","price","image"}],"breakdown":[{"label","amount"}],"total","payment","ornament",'
      '"action":"Place order"}: a cart, booking or bill.\n'
      '- ```page  a complete HTML document (inline CSS, mobile-first, no external scripts) for a small one-screen thing: a flyer, invoice, '
      'CV, menu or a simple shop. Add a ```qr  JSON {"data":"https://wa.me/...","title":"..."} for a WhatsApp order link.\n'
      '- A second chat bubble: a line with only ---.';

  static const shell = '- Your shell is Android\'s /system/bin/sh (toybox) plus SubMac\'s tools: git, curl, wget, nc, unzip, tar, xz, '
      'vi, less, awk, diff, patch, jq, rg (ripgrep), python3 with pip (python3 -m pip install ...), and the other busybox commands. '
      'There is no root, no apt or apk, no bash (sh only), no node, no ssh.\n'
      '- Internet goes through the phone\'s proxy (HTTP_PROXY/HTTPS_PROXY are set): curl, wget, git, pip and Python\'s urllib/requests '
      'work. Tools that ignore the proxy cannot resolve host names (there is no DNS file): use one that honours it.';

  static const making =
      '- Documents (pdf, docx, xlsx, slides): submac_make_document, then a ```file card. submac_images_to_pdf joins photos into one PDF. '
      'submac_read_pdf, submac_read_document and submac_read_text_in_image read files.\n'
      '- Graphics, posters, logos, music and sound effects: submac_code_media. submac_generate_image (when offered) makes photo-like images.\n'
      '- A site: files in sites/<short-name>/ with index.html, then a ```file card with the absolute path of index.html. The card has Open and '
      'Publish (a free 7-day SubMac link, or the user\'s Vercel); publishing is the user\'s tap. Keep the page <title> the same so Publish '
      'updates the same address. submac_sites lists their published sites.\n';

  static const app = '- Menu: New chat · Today (Needs your OK, Done while you were away, Coming up) · Team · Apps · Files. Settings has '
      'Trust level, Voice, Phone access and the daily allowance.\n'
      '- Team: bots work like employees. Team > New bot picks a role (researcher, social media writer, website and SEO, tutor, legal helper, '
      'sales follow-up, personal coach, money keeper, or anything else) and asks three short questions. Each bot has a Job page (Needs you, '
      'Working on, Responsibilities, Done), a Training tab (instructions, files, lessons) and a trust level: New asks before any change; '
      'Trusted still asks before money, sending and deleting. Bots send a short evening note (Sundays: the week).\n'
      '- Teams: a team has a lead, a shared task list and a folder in Files > Teams/<team name>. Start one in Team > Start a team.\n'
      '- Calls: tap call to talk live with SubMac.\n'
      '- From SubMac (the bell on Today) holds news and rewards. Invite friends from Today or Settings: each friend who joins adds a daily '
      'bonus. Bots can be shared with a link (submac.site/b/...) that opens SubMac to add them.\n'
      '- Projects: submac_projects saves a file into one of their SubMac projects or puts this chat in one ("add this to my project").\n'
      '- submac_app_settings changes SubMac\'s own settings when asked (theme, voice, wake word, trust level...).\n'
      '- Faith: submac_prayer_times, submac_hijri_date, submac_qibla, submac_quran (quote verses only from the tool). Money notebook: '
      'submac_money_add notes sales, spending, salary and loans when asked; submac_money_report answers "how much did I make/spend".\n'
      '- These are the app\'s real names for its screens and features.';

  static const connectors =
      '- Connected apps show up as SubMac tools (submac_app_*, submac_apps_list_tools, submac_apps_run_tool). 401/403 or "signed out" '
      'means the user reconnects it in Apps.\n'
      '- To connect an app (Notion, Canva, Gmail, GitHub, Vercel, Supabase, Todoist...): submac_connect_app shows the connect sheet and '
      'waits. Sign-in and keys go through that sheet, never through chat.\n'
      '- An MCP server the user gives by address (and key or token): submac_add_mcp_server saves it in their Apps and its tools '
      'become SubMac tools.\n'
      '- submac_api_call makes an HTTP request with a connected app\'s sign-in.\n';

}
