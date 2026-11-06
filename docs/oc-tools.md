# opencode tools fix (1.13.138+208, branch fix/oc-tools, 2026-11-06)

Owner bug report: (A) bots save "responsibility" notes without end, (B) opencode tool calls fail, (C) bots do not use
the owner's connected apps. Evidence: the synced chat of the News Reporter bot on 2026-11-05 ("Setup routine to send
me news every Hour in telegram"): 133 `bot_routine` calls, 51 removes, 25 routines left on its Job page for one ask.

## A. The save loop

Root cause:
- `bot_routine` could only make a routine at one time of day. "Every hour" had no way to be said (the hint pointed at
  `schedule_task`, which a bot never sees: it is not in its brief and sits behind find_tools), so the model made one
  daily routine per hour, 24 calls, each answered as a success, and nothing told it to stop.
- opencode runs tool calls side by side. `Bots.arm` walked `b.routines` while parallel adds changed it:
  "Concurrent modification during iteration" for two of them, so the model removed everything and started again,
  and again after the owner's next message.
- A call with a cron line and no `action` fell through to "list" ("No routines."), so the model tried other shapes.
- With Full access (autopilot) on, opencode's own repeat guard (`doom_loop` permission) was allowed automatically.

Fix:
- `bot_routine` takes `repeat` (hourly, every_3_hours), `every_hours` (2/4/6/8/12) and cron lines. Hourly and 3-hourly
  become ONE repeating scheduled task of the bot (Scheduler, the bot wakes for it); 2/4/6/8/12 hours make their
  routines in one call. A call with no action but a time/job/repeat is an add.
- Same job at the same time: "Already set" (nothing added). Same job at more than 4 times of day: refused with how
  to do it in one call.
- `SaveGuard` (lib/services/save_guard.dart): per chat or team key and per turn (10-min window as a backstop), the
  same save with the same arguments is answered with the first result and never run twice, and each kind of save
  has a cap (routines 6, memory 12, follow-ups 8, lessons 6, watches 6, desk tasks 25). Removes, lists and updates
  never count. A new turn resets the counts.
- `arm` walks a copy of the routine list.
- Autopilot never allows `doom_loop`.
- `bot_remember`: the same fact twice is one line; a line with a key or token is refused (the bot had saved the
  owner's Telegram bot token); `list: true` lists memory.
- The Job page and the bot's prompt show one job at many times as one line ("every hour"); deleting it removes all
  of its routines. Repeating scheduled tasks of the bot show under Responsibilities with a delete.
- Known issue fixed: a bot's `remember` / `forget` / `list_memories` act on the bot's own memory (bot_remember); the
  owner's memory tools are no longer in a bot's tool list (OcToolScope.ownerMemory / botMemory).

## B. opencode tool failures

Found in the 2026-11-02..06 tool rows:
- `run_tool` called with opencode's own tool names ("webfetch"): now answers "call webfetch directly".
- `bot_telegram` called with `message` instead of `text`: `message`, `body`, `content` are read too.
- `bot_routine` cron / missing action and the parallel-add crash (see A).
- Connected-app calls (`app_telegram`) all answered 404: the model sent `url` (ignored, so the request went to the
  bare base) or repeated the base's own path (`/bot<token>/sendMessage` doubled the token). `url`/`endpoint` are read
  as the path, the base's path is taken off when repeated, and an empty path is refused ("Nothing was sent").
- Routing with several turns at once: an MCP call with no matching event was refused after 1.5 s ("could not tell
  which chat"); it now waits up to 5 s while several turns run.
- Not changed (by design): a New-trust bot's bash in a run nobody watches is refused (BgRun.permission); the old
  "ripgrep execution failed" / "curl not found" rows are from before the static rg/curl (2026-11-03).

## C. Bots and the owner's connected apps

- The alarm gate opened when the bots and scheduled tasks had loaded, before the owner's connected apps and MCP
  servers were read, so a bot's run started by an alarm with SubMac closed found no apps. The gate now opens after
  them.
- `bot_telegram` only knew SubMac's own Telegram; the owner had connected their own Telegram bot in Apps, and the bot
  kept saying "not connected". It now sends through the connected Telegram bot (owner's chat = newest private chat
  from getUpdates, kept after the first send).
- A bot's opencode brief now lists the owner's connected apps it may use (cut by its powers and app scope) with how to
  call them, and says never to call one "not connected" before trying it.

## Not done here
- No server or edge-function change was needed.
- Existing duplicated routines are not rewritten automatically; they show as one line and one delete removes them.
- Device check: ask a bot "send me news every hour in Telegram" and check its Job page shows one "Every hour" line.
