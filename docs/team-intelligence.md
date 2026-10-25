# Team intelligence (v1.13.95+162, owner 2026-10-24)

Owner's problems: the lead answers every time; `@silent` makes things worse; hardcoded automation; bots act like a
pipeline instead of people; team/bot chats lack the main chat's motion; long texts need an expandable container; status
rings too loud; no reply system; team heads should be one composite circle. Compared against Grok Bot's group chats:
docs.x.ai/grok-bot/chat-and-collaboration (read 2026-10-24), x.ai/news/designing-grok-bot, x.ai/changelog/bot.

## What Grok does (the bar)

- "Write normally to let the participating Bots decide who should respond." `@` one Bot when it owns the request;
  several mentions only when each is needed; `@everyone` sparingly.
- "Choose Reply on a Bot's message to direct your answer to that Bot"; an answer to a Bot's question goes back to it.
- A Bot "will always respond when directly addressed, but can also choose to respond in context" (tester report).
- Handoffs are visible, one owner per stage; "too many parallel handoffs create duplicate work and noisy updates".
- A new Bot waits for its first task. While a Bot works with nothing to report, the chat shows just its avatar.
- Reply quotes show the quoted text and jump to the replied message when clicked.

## Diagnosis (code read on main 33882a8)

| # | Symptom | Root cause |
|---|---|---|
| D1 | Lead answers every message | `TeamRun.send` sent every non-@ message to the lead's plan flow (`_propose`), and `Offices.ownerPost` added the lead whenever no member matched (`if (named.isEmpty) named.add(chiefId)`). |
| D2 | `@Nova` still woke the lead | Any `@word` counted as "a mention" in `TeamRun`, but routing in `ownerPost` matched only exact member names; an unmatched `@word` fell back to the lead. |
| D3 | `@silent` made it worse | The owner's `@silent` matched the "mention" regex, found no member, and woke the lead (the opposite of what was meant). For bots, every job ended with "end with @silent alone on the last line": a reply that answered the owner AND ended with the tag was dropped whole (kind `silent`); a tag mid-line leaked "@silent" into the chat; and the stop-code framing primed models to act like a pipeline. |
| D4 | Canned / automatic chatter | Timed team rounds (`fire` → `chief` job every `checkMinutes`, "add 1 to 5 tasks toward the goal"), a daily report on a timer, `supervise()` posting "@Nova checking in on …" and quiet-teammate notices, the lead's canned "Noted. I will pass that on to the team." on every message during a run, "Works on its own" mode, and a new bot greeting itself on first open (`hireBot` → first-meeting wake). |
| D5 | Pipeline feel | Routing was a rule table (mention → member, else lead plans); members had no way to read the room or stay quiet; reply jobs told the lead to "turn it into tasks and say who does what" for any message. |
| D6 | No motion in team chats | `_PostView` had no entrance; new posts popped in. Bot chats already use the main chat list (fade streaming from 161). |
| D7 | Long results | Team posts and member parts rendered full markdown inline; main chat folded only replies with 2+ headings (`longReplySplit`). |
| D8 | Loud rings | 2 px ring + 2 px gap on every head; member chips with icons; 30 px activity faces. |
| D9 | No replies | No reply model anywhere; chat messages sync as rows with fixed columns (a new column would need a server migration). |
| D10 | Team head | A team showed only its lead's face (or a letter). |

## What changed

- **Routing (`TeamRun.send`, `lib/services/team_run.dart`).** Addressed = `@mention`s (members only; `@team`/
  `@everyone`/`@all` = all), the author of the bot message you reply to, or a member name opening the message
  ("Nova, …"). Only they answer. Not addressed: one small model decision (`floorSystem`, "# Who speaks") with the
  roster, roles and the last 12 posts picks the member who should speak, `none`, or `team_task` (then the lead
  coordinates the visible plan → parts → combined answer flow). The lead answers only when addressed or coordinating a
  job; when addressed it decides itself whether the owner asked it to run the team. No rule tables; the prompt is
  instructions.
- **Silence (`lib/services/no_reply.dart`).** `[no reply]` (or nothing) is a normal outcome, said once in prompts that
  allow it (`NoReply.rule`). Lenient parsing: old tags still read as silence; a stray tag after real words is stripped
  and the words kept; replies to the owner and task results are always posted. The owner's `@silent` now means "post
  it, nobody answers". The main/bot chat never shows a bare silence marker.
- **No automation.** Team alarms only clear themselves (`arm`/`fire`); `supervise` is a no-op; "Works on its own" is
  gone (old teams read as "Only when I ask"); the lead-check / work-hours / daily-report rows are removed from team
  settings; queued timed rounds are dropped on load; no canned "Noted"; `hireBot` no longer makes a bot speak first.
  Kept (the owner asked for them explicitly): routines, follow-ups and a check-in interval the owner sets on a bot,
  "Ask the lead to check now", task hand-offs the lead makes inside a job.
- **People, not a pipeline.** `BotManner.colleague` adds "read the conversation before you speak…"; team prompt adds
  "speak when you are spoken to or have something the team needs; you can stay quiet". Reply jobs tell the bot the
  owner is talking to it and to answer in its own role; replies include what is being replied to.
- **Replies (`lib/widgets/chat/reply_quote.dart`).** Swipe toward the middle (mirrored in RTL) or hold → Reply. Quote
  above the composer (main, bot and team), quote inside the sent bubble, tap → `jumpToMessage` scrolls a lazy reversed
  list until the original is built, centres it and lets it glow. Main/bot chats: `ReplyCodec` puts
  `[Reply to <author> · #<id>]\n> <quote>` at the top of the message (no server change; the model reads it as context).
  Teams: `OfficePost.replyTo`; a reply to a bot's post routes to that bot.
- **Expandable long text (`lib/widgets/chat/long_text.dart`).** Over 1,100 characters or 16 lines: a faded 260 px
  preview with "Show more" (opens in place) and "Open" (the full reader). Main chat and bot chat replies (a reply that
  streamed in while you watched stays open), team posts, the lead's answer and each member's part.
- **Motion.** Team posts enter with the main chat's `Entrance` (bots) / `SendIn` (yours), only for posts that arrive
  while the chat is open; reduced motion = none. All timings from SubMotion.
- **Tiny status.** Ring stroke 1.25, gap 1.25 (was 2/2); idle ring at 45 % opacity. Member chips → a 30 px strip of
  18 px faces in their rings with the name. Activity rows: 18 px face in a working ring, caption text.
- **Composite team head (`lib/widgets/team_face.dart`).** One circle, exactly a bot head's size: 1 member = its face;
  2 overlapping; 3 in a triangle; 4+ = 2×2 (lead first); mirrored in RTL. Used in the rail, the workspace header, the
  empty-chat greeting and the drawer's team rows; the status ring goes around it as for a bot.

Tests: test/team_intelligence_test.dart (routing, silence, no chatter, replies, expandable text, team head sizes and
RTL, tiny rings), test/team_run_test.dart updated for the decision step.
