// What a tool does to the world, for resuming a run after the app was killed.
//
//  * read: only looks (search, read a file or page, see the screen). Safe to run again.
//  * idempotent: writes, but running it again gives the same state (write a file with the same content, make the same
//    document, open the same page). Safe to run again.
//  * sideEffect: changes something outside Telesia or can't be undone or repeated safely (send, post, pay, call, delete,
//    tap on a page, append). Never run again on resume: the model is told it may or may not have happened.
//
// A tool that is not listed is a side effect (the safe default).
enum ToolEffect { read, idempotent, sideEffect }

class ToolEffects {
  ToolEffects._();

  static const read = <String>{
    'web_search', 'get_weather', 'wikipedia', 'currency_convert', 'find_place', 'read_rss', 'youtube_transcript',
    'skill_search', 'skill_use', 'somali_knowledge', 'somali_knowledge_read', 'prayer_times', 'hijri_date', 'quran', 'qibla',
    'money_report', 'calculate', 'biz_report', 'biz_records', 'biz_calc', 'health_check', 'health_report', 'health_calc',
    'code_search', 'code_diff', 'code_docs', 'code_check', 'ai_providers', 'list_memories', 'browser_task_status',
    'browser_task_wait', 'list_scheduled', 'phone_screen', 'phone_wait', 'phone_calendar', 'phone_contacts', 'read_file',
    'list_dir', 'fetch_url', 'read_text_in_image', 'read_pdf', 'read_document', 'list_mcp', 'browser_read', 'browser_copy',
    'browser_find', 'browser_view', 'browser_tabs', 'browser_wait', 'knowledge_search', 'knowledge_read', 'docs_list',
    'docs_read', 'office_brief', 'apps_list_tools', 'more_tools', 'read_notifications',
  };

  static const idempotent = <String>{
    'todo', 'write_file', 'edit_file', 'make_document', 'images_to_pdf', 'code_build', 'code_snapshot', 'code_project',
    'generate_image', 'generate_video', 'generate_media', 'media_generate', 'code_media', 'ai_call', 'browser_open', 'browser_back',
    'browser_forward', 'browser_reload', 'browser_scroll', 'app_settings', 'data_sheet',
  };

  static ToolEffect of(String name) {
    if (read.contains(name)) return ToolEffect.read;
    if (idempotent.contains(name)) return ToolEffect.idempotent;
    return ToolEffect.sideEffect;
  }

  /// Safe to run again after the app was killed in the middle of it.
  static bool rerunnable(String name) => of(name) != ToolEffect.sideEffect;

  static String label(ToolEffect e) => switch (e) {
        ToolEffect.read => 'read',
        ToolEffect.idempotent => 'idempotent',
        ToolEffect.sideEffect => 'side_effect',
      };

  /// What the model reads for a side-effect call that was cut off by the app closing.
  static String interrupted(String name) =>
      'Interrupted: the app closed while $name was running, so it is unknown whether it happened. Check before retrying '
      '(look for the sent message, the saved item, the payment), and never repeat it blindly. If you cannot check, tell the user.';

  /// What the model reads for an approval that was still waiting when the app closed.
  static const approvalLost = 'Not done: the app closed while this was waiting for the user\'s approval, so nothing was done. '
      'If it is still needed, ask again.';

  /// What the model reads for a read-only or idempotent call that was cut off (it is not run again by the app).
  static String cutOffSafe(String name) =>
      'Cut off: the app closed while $name was running, so there is no result. It is safe to call it again if you still need it.';

  /// What the model reads for a call that never started before the app closed.
  static const notStarted = 'Not done: the app closed before this call started, so nothing happened. Call it again if it is still needed.';
}
