// The live status line of a task (R2 item 1): what the agent is really doing right now.
//
// Every phase is set by an event of the run, never by a canned or rotating phrase: the request went out, reasoning or
// text arrived, the model chose a step, a tool started or returned, an approval or answer is awaited, a call failed and
// is retried (attempt N of M), the user pressed Stop. The only time-based change is the honest "still waiting" after a
// long silence in the same phase. The words are English keys translated with the app's i18n (tr): en, so, ar.
import '../ui/i18n.dart';

enum RunPhase {
  /// The run exists, the first request is not out yet (loading the tool list, opening the journal).
  starting,

  /// A model request is out; nothing has come back yet.
  waiting,

  /// The model streams its reasoning (no words of the reply yet).
  thinking,

  /// The reply's words are streaming.
  writing,

  /// The model is writing a tool call; the tool has not started.
  preparing,

  /// A tool is running.
  tool,

  /// An approval card is waiting for the user.
  approval,

  /// A failed call is about to be sent again.
  retrying,

  /// The app itself checks something (a page the task built, folding a long chat).
  checking,

  /// Stop was pressed; the call or tool in flight is being cut.
  stopping,

  /// The run failed for good (its error card follows).
  failed,
}

class RunStatus {
  RunStatus._();

  static const starting = 'Starting';
  static const sending = 'Sending your message';
  static const resuming = 'Resuming the task';
  static const waiting = 'Waiting for a response';
  static const waitingLong = 'Still waiting for a response';
  static const waitingSlow = 'The response is taking longer than usual';
  static const reading = 'Reading your new message';
  static const revising = 'Revising the reply';
  static const continuing = 'Continuing the reply';
  static const thinking = 'Thinking';
  static const thinkingLong = 'Still thinking';
  static const writing = 'Writing the reply';
  static const preparing = 'Preparing the next step';
  static const approval = 'Waiting for your approval';
  static const answer = 'Waiting for your answer';
  static const queued = 'Waiting to send ({n}s)';
  static const retryIn = 'Connection problem. Retrying in {n}s ({i} of {m})';
  static const reconnecting = 'Connection dropped. Retrying ({i} of {m})';
  static const compacting = 'Summarising earlier messages';
  static const checkingPage = 'Checking the page';
  static const stopping = 'Stopping';
  static const failed = 'Stopped with an error';
  static const more = '{n} more';

  /// Seconds in the same waiting/thinking phase before the line says so.
  static const longAfter = 8;
  static const slowAfter = 25;

  /// The words for a key and its holes, in the app language.
  static String text(String key, [Map<String, String> args = const {}]) => tr(key, args);

  /// The same in English (the model reads a running task's status in English).
  static String english(String key, [Map<String, String> args = const {}]) {
    var s = key;
    args.forEach((k, v) => s = s.replaceAll('{$k}', v));
    return s;
  }

  /// The key as shown after [waited] seconds in the same state: an honest note on a long silence, nothing else.
  static String shown(RunPhase phase, String key, int waited) {
    if (phase == RunPhase.waiting && key == waiting) {
      if (waited >= slowAfter) return waitingSlow;
      if (waited >= longAfter) return waitingLong;
    }
    if (phase == RunPhase.thinking && key == thinking && waited >= slowAfter) return thinkingLong;
    return key;
  }

  /// Every key the line can show by itself (the step labels of tools are listed in [toolKeys]).
  static const phaseKeys = [
    starting, sending, resuming, waiting, waitingLong, waitingSlow, reading, revising, continuing, thinking, thinkingLong, writing,
    preparing, approval, answer, queued, retryIn, reconnecting, compacting, checkingPage, stopping, failed, more,
  ];

  /// The step labels of Telesia's own tools and the parallel-read groups (AppStateAgentStream._toolStatus).
  static const toolKeys = [
    'Taking a note', 'Updating my desk', 'Planning ahead', 'Setting a watch', 'Calling you', 'Asking {name}',
    'Sharing to the Docs', 'Checking the Docs', 'Sending the email', 'Reading an email', 'Checking your email',
    'Calling {host}', 'Working in {app}', 'Making your spreadsheet', 'Making your slides', 'Writing your document',
    'Making your PDF', 'Checking prayer times', 'Checking the Hijri date', 'Opening the Quran', 'Finding the Qibla',
    'Writing it in your notebook', 'Checking your notebook', 'Checking your notifications', 'Running a command',
    'Reading a file', 'Writing a file', 'Editing a file', 'Looking through files', 'Reading a web page', 'Moving to Trash',
    'Creating an image', 'Making a video', 'Composing a sound', 'Animating', 'Drawing', 'Saving your provider',
    'Connecting {name}', 'Updating your projects', 'Taking your site offline', 'Checking your sites',
    'Waiting for you to connect {app}', 'Opening {name}', 'Looking at the screen', 'Tapping', 'Typing', 'Scrolling',
    'Using the phone', 'Adjusting your phone', 'Setting the alarm', 'Searching the web', 'Checking the weather',
    'Reading {n} pages', 'Searching the web ({n} searches)', 'Searching and reading {n} sources', 'Reading {n} files',
    'Checking {n} things at once', 'Updating the checklist',
  ];
}
