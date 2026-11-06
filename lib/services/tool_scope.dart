import 'ai_models.dart';
import 'biz_tools.dart';
import 'code_tools.dart';
import 'health_tools.dart';
import 'browser_agent.dart';
import 'browser_jobs.dart';
import 'connector_tools.dart';
import 'doc_maker.dart';
import 'doc_tools.dart';
import 'life_tools.dart';
import 'somali_knowledge.dart';
import 'media_coder.dart';
import 'phone_tools.dart';
import 'setup_tools.dart';
import 'system_tools.dart';
import 'tools.dart';
import 'whatsapp.dart';

/// Sends only the tools a message needs (Plan 7, token burn). Every step used to carry the whole toolbox
/// (~8-10k tokens); now each chat gets the core tools plus the groups its messages point at, and `more_tools`
/// opens everything else in the next step. Groups only ever get added within a chat (sticky), so the request
/// prefix stays the same from turn to turn and the provider's prompt cache keeps working.
class ToolScope {
  static const browser = 'browser';
  static const phone = 'phone';
  static const files = 'files';
  static const apps = 'apps';
  static const schedule = 'schedule';
  static const media = 'media';
  static const life = 'life';
  static const whatsapp = 'whatsapp';
  static const business = 'business';
  static const health = 'health';
  static const code = 'code';

  /// Prompt-only group: the full card and diagram reference.
  static const cards = 'cards';

  /// Every gated group (cards is prompt-only).
  static const groups = [browser, phone, files, apps, schedule, media, life, whatsapp, business, health, code];

  /// The group a tool belongs to, or '' when it is always sent (search, memory, say, alarms, a bot's own tools...).
  /// Unknown names are always sent: only tools we know are gated.
  static String groupOf(String name) {
    if (SomaliKnowledge.names.contains(name)) return '';
    if (name == 'fetch_url' || name == 'set_alarm' || name == 'set_timer' || name == 'open_link') return '';
    if (name == WhatsAppTools.tool) return whatsapp;
    if (BrowserJobs.names.contains(name) || BrowserAgent.names.contains(name)) return browser;
    if (const {'schedule_task', 'list_scheduled', 'cancel_scheduled'}.contains(name)) return schedule;
    if (MediaCoder.names.contains(name) ||
        AiModels.names.contains(name) ||
        const {'generate_image', 'generate_video', 'make_image', 'make_video', 'media_generate'}.contains(name)) {
      return media;
    }
    if (LifeTools.names.contains(name)) return life;
    if (BizTools.names.contains(name)) return business;
    if (HealthTools.names.contains(name)) return health;
    if (CodeTools.names.contains(name)) return code;
    if (AgentTools.fileNames.contains(name) ||
        DocMaker.names.contains(name) ||
        DocTools.names.contains(name)) {
      return files;
    }
    if (name.startsWith('phone_') || SystemTools.names.contains(name) || PhoneTools.names.contains(name)) {
      return name == 'app_settings' ? '' : phone;
    }
    if (name == 'apps_list_tools' || name == 'apps_run_tool') return '';
    if (SetupTools.names.contains(name) ||
        ConnectorTools.names.contains(name) ||
        name == 'api_call' ||
        name.startsWith('email_') ||
        name.startsWith('mcp_') ||
        (name.startsWith('app_') && name != 'app_settings')) {
      return apps;
    }
    return '';
  }

  static final Map<String, RegExp> _hints = {
    browser: RegExp(
        r'\b(web ?site|site|online|sign ?in|sign ?up|log ?in|login|account|book|booking|reserve|apply|application|form|order|buy|purchase|shop|'
        r'cart|checkout|browse|browser|linkedin|facebook|instagram|twitter|tiktok|upwork|fiverr|indeed|amazon|ebay|alibaba|jumia|google|'
        r'flight|flights|hotel|ticket|tickets|job|jobs|post (it|this|on)|publish|research|deep research|compare|prices?|deal|deals|'
        r'iibso|dalbo|boos|raadi|raadso|bog|bogga|websaydh)\b|https?://|www\.|\.(com|org|net|so|io|site|co)\b',
        caseSensitive: false),
    phone: RegExp(
        r'\b(phone|screen|tap|swipe|scroll|open|app|apps|telegram|messenger|signal|sms|texts?|call|ring|dial|contacts?|calendar|'
        r'event|meeting|settings|wifi|wi-fi|bluetooth|notifications?|camera|gallery|install|uninstall|battery|volume|brightness|'
        r'instagram|tiktok|youtube|snapchat|facebook|imo|wac|fariin|taleefan|soo wac|dir|u dir)\b',
        caseSensitive: false),
    files: RegExp(
        r'\b(files?|folders?|pdf|docx?|documents?|cv|resume|résumé|invoice|receipt|letter|report|proposal|certificate|contract|'
        r'sheet|excel|xlsx|csv|spreadsheet|slides|presentation|ppt|scan|download|downloads|upload|storage|zip|rename|move|copy|delete|'
        r'web ?site|websites|landing( page)?|web ?app|html|css|javascript|typescript|python|flutter|react|game|software|program|programming|coding|codebase|develop|developer|build (me |an? )?(app|site|tool|game|bot)|'
        r'shell|command|script|code|budget|attendance|price list|menu|concept note|business plan|ocr|read (this|the) (photo|image|picture)|'
        r'warqad|warqadda|fayl|faylka|faylal|qor|ii qor|dukumenti|bog|bogga|xisaabi|sawir|sawirka)\b',
        caseSensitive: false),
    apps: RegExp(
        r'\b(e-?mails?|mail|inbox|gmail|outlook|notion|canva|airtable|todoist|slack|github|trello|asana|drive|google sheets|google docs|'
        r'zapier|pipedream|make\.com|api|webhook|endpoint|connect|connected|integration|my (tasks|notes|pages|boards|projects)|hubspot|'
        r'shopify|stripe|dropbox|jira|linear|figma|discord|spotify|calendly)\b',
        caseSensitive: false),
    schedule: RegExp(
        r'\b(remind|reminder|reminders|every|daily|weekly|monthly|each (day|morning|week|friday|monday)|schedule|scheduled|later|tomorrow|'
        r'tonight|morning|evening|at \d|in \d+ ?(min|mins|minutes|hours?|days?)|watch|tell me when|let me know when|notify|alert|'
        r'xasuusi|berri|subaxdii|habeenkii)\b',
        caseSensitive: false),
    media: RegExp(
        r'\b(draw|drawing|poster|logo|icon|image|images|picture|pictures|wallpaper|art|artwork|design|graphic|banner|flyer|sticker|'
        r'illustration|music|song|melody|beat|sound|ringtone|jingle|tune|video|animation|gif|sawir|naqshad|hees|muusig|'
        r'base ?url|api ?key|key_ref|provider|my model|this model|ai model|text to speech|tts|voice ?over|transcribe|transcription|embeddings?)\b',
        caseSensitive: false),
    life: RegExp(
        r'\b(pray|prayer|prayers|salah|salat|salaad|quran|qur.an|surah|surat|ayah|aayad|verse|qibla|qiblah|hijri|ramadan|eid|fajr|dhuhr|'
        r'asr|maghrib|isha|money|sold|sell|selling|bought|spent|spend|spending|expense|expenses|income|salary|profit|loss|debt|lend|lent|'
        r'loan|owe|owes|lacag|iibiyay|deyn|mushahar|faa.iido|xisaabi|xisaab)\b',
        caseSensitive: false),
    whatsapp: WhatsAppTools.hint,
    business: RegExp(
        r'\b(business|my shop|my store|dukaan|dukaanka|ganacsi|ganacsiga|invoices?|receipts?|quotation|sales|sold|selling|customers?|suppliers?|'
        r'stock|inventory|cashbook|cash book|ledger|bookkeeping|accounting|expenses?|purchases?|profit|margin|markup|break.?even|'
        r'debts?|owes? me|i owe|on credit|spreadsheet|excel|xlsx|csv|pivot|data analy[sz]is|analy[sz]e (this|the|my) (data|file|sheet|sales|numbers)|'
        r'iib|iibka|macmiil|deyn|kharash|faa.iido|khasaare|badeeco|rasiid|qaansheeg|xisaab)\b',
        caseSensitive: false),
    health: RegExp(
        r'\b(health|healthy|sick|ill|illness|pain|hurts?|fever|temperature|cough|cold|flu|diarrh(o)?ea|vomit(ing)?|rash|headache|doctor|clinic|hospital|'
        r'medicine|medicines|medication|pills?|tablets?|dose|blood pressure|bp|sugar|diabetes|diabetic|insulin|asthma|pregnan(t|cy)|baby|newborn|'
        r'vaccin(e|es|ation)|malaria|cholera|measles|tb|tuberculosis|malnutrition|muac|bmi|weight|period|menstrua\w*|mental|depress\w*|anxiety|'
        r'injury|injured|burn|bleeding|first aid|symptoms?|caafimaad|caafimaadka|xanuun|xanuunka|bukaan|buka|qandho|qufac|hargab|shuban|matag|'
        r'dhakhtar|dhakhtarka|isbitaal|cisbitaal|daawo|daawada|kiniin|dhiig ?kar|sonkor|macaan|uur|uurka|ilmo|dhallaan|tallaal|tallaalka|'
        r'duumo|daacuun|jadeeco|nafaqo|dhaawac|gubasho|dhiig|madax xanuun|calool xanuun|neef)\b',
        caseSensitive: false),
    code: RegExp(
        r'\b(code|coding|coder|programm(ing|er)|developer|debug|bugs?|exception|stack ?trace|traceback|compile|compiler|syntax|'
        r'python|javascript|typescript|nodejs|react|vue|flutter|dart|kotlin|java|swift|rust|golang|c\+\+|php|sqlite|sql|'
        r'apis?|endpoint|json|regex|algorithm|script|repo|repository|github|git|commit|pull request|branch|'
        r'apk|apks|aab|gradle|gradlew|android studio|github actions|build (the|my|an?) (app|apk)|deploy|unit tests?|refactor|npm|pip install|pub\.dev|backend|frontend|web ?app|source)\b',
        caseSensitive: false),
    cards: RegExp(
        r'\b(compare|comparison|table|chart|graph|plot|diagram|roadmap|timeline|itinerary|plan|steps|step by step|how to|explain|teach|'
        r'lesson|maths?|equation|function|curve|formula|qr|page|website|landing|menu|flyer|invoice|cart|options|vs|versus|show me|'
        r'visual|visuali[sz]e|stats|statistics|trend|budget|breakdown|summary|summari[sz]e|list of|ideas|xisaabi|bog)\b',
        caseSensitive: false),
  };

  /// The groups a message points at. [text] is the user's words (for a wake, only the job part).
  static Set<String> hinted(String text, {bool attachments = false, Iterable<String> appNames = const []}) {
    final out = <String>{};
    for (final e in _hints.entries) {
      if (e.value.hasMatch(text)) out.add(e.key);
    }
    if (attachments) out.add(files);
    final low = text.toLowerCase();
    for (final n in appNames) {
      final a = n.trim().toLowerCase();
      if (a.length >= 3 && low.contains(a)) {
        out.add(apps);
        break;
      }
    }
    // Messaging on WhatsApp is done through the phone too.
    if (out.contains(whatsapp)) out.add(phone);
    return out;
  }

  /// The tools for [groups] (order kept, so the prefix is stable). [all] = no scoping.
  static List<Map<String, dynamic>> filter(List<Map<String, dynamic>> tools, Set<String> groups, {bool all = false}) {
    if (all) return tools;
    return [
      for (final t in tools)
        if (_keep('${(t['function'] as Map?)?['name']}', groups)) t,
    ];
  }

  static bool _keep(String name, Set<String> groups) {
    final g = groupOf(name);
    return g.isEmpty || groups.contains(g);
  }

  /// Plain names of what is still behind more_tools, for the prompt.
  static String closedLine(Set<String> groups) {
    const words = {
      browser: 'the browser',
      phone: 'phone control, texts and calls',
      files: 'files and documents',
      apps: 'connected apps and email',
      schedule: 'scheduled tasks',
      media: 'pictures, music and video',
      life: 'prayer times, Quran and the money notebook',
      whatsapp: 'WhatsApp',
      business: 'the business books (sales, stock, invoices, reports, data sheets)',
      health: 'the family health book (danger-sign check, medicines, readings, pregnancy, vaccines, health summary)',
      code: 'the coding tools (run code, search, diff, git and GitHub, APK and web builds, API tester, package docs)',
    };
    final closed = [for (final g in ToolScope.groups) if (!groups.contains(g)) words[g]!];
    return closed.join(', ');
  }
}
