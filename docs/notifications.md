# Notifications

Owner asks (2026-11-05), shipped in 1.13.128+198 (branch `feat/notifications`):

1. A notification shows a short summary of what the work produced, never "Running your scheduled task".
2. It says who it is from. A bot's notification carries the bot's name and face. Telesia's own (the agent) looks
   different, and each sender has its own Android channel.
3. Team notifications show the team's name with "<Bot>: message", one conversation per team, and an inline Reply
   that works with Telesia closed. Bot chats get the same Reply. A post marked "[needs you]" pops up.
4. A new light chime.
5. Teams, bots and Telesia's own scheduled tasks all run with the app closed.

## Who it is from

| Sender | Channel id (name in Settings) | Title | Look | Sound |
|---|---|---|---|---|
| Agent: Telesia's own chats and scheduled tasks | `telesia_agent_v2` ("Telesia") | `Telesia` | Telesia red accent (`#C2361B`), no large icon | chime |
| A bot, in its private chat | `telesia_bots_v2` ("Bots") | the bot's name | round face: its first letter on its avatar colour (`AvatarSpec`) | chime |
| A team chat | `telesia_teams_v2` ("Teams") | the team's name | MessagingStyle conversation, each line from a person with the bot's face | chime |
| A team post that needs the owner | `telesia_teams_needs_v2` ("Teams: needs you", high) | the team's name | same conversation | chime, pops up |
| Work running with Telesia closed | `telesia_work_v2` ("Background work", low) | `Nova · Hourly news` | ink, ongoing | silent |

These are unchanged: `telesia_quiet` (finished tasks, silent), `telesia_bot_calls` (ringing), `telesia_asks` (needs
your OK) and `telesia_wake` (wake word). A channel keeps the sound it was created with, so the chime needed new ids.
`Notifier.ensureChannels` deletes the old `telesia_tasks`, `telesia_tasks_v2` and `telesia_bot_msgs` channels.

The ids are named in Dart too, in `NotifChannels` (`lib/services/notif_text.dart`). Keep both in step.

## The words

`NotifText` (`lib/services/notif_text.dart`) writes the words. `lib/state/notifications.dart` routes each notification.

- **While it runs:** the foreground line, `NotifText.running(sender, task)`: `Nova · Hourly news`,
  `Telesia · Weather`, `Launch team · Nova: Write the brief`, `Nova · Your reply`. An alarm set before this version
  that has no label shows `Telesia · Getting ready` until Dart updates it.
- **When it ends:** a separate notification with `NotifText.summary(reply)`. It takes the first meaningful lines
  (at most 3 lines and 240 characters) and drops markdown, headings, bullets, code blocks, cards, links, URLs, bot
  tags (`@message`, `[no reply]`, `[needs you]`), greetings and "Here is…:" lines. A reply that is only a card uses
  the card's title. `NotifText.result` stays silent for `[no reply]`, for a watcher's `NO_CHANGE` and for an empty
  reply. A reply that has only code says `Done: <task>`.

## Where each notification comes from

| What | Code | Notification |
|---|---|---|
| A bot's routine or scheduled task (`@message`) | `_botOutcome` → `_notifyBot` | Bots |
| A bot's call that could not ring, a missed call, the evening report | `_botRing`, `_missedCall`, `_botReport` → `_notifyBot` | Bots |
| Telesia's own scheduled task ends | `_ocRunEnded` → `_notifyRunEnd` → `_notifyAgent` | Agent. This was lost when the old runner went (2026-11-02): no notification at all. |
| The answer to a Reply typed in a notification | `_ocRunEnded` (chat in `_notifReplyConvs`) | Bots for a bot's chat, Agent for Telesia's |
| A team member answers the owner, the lead's plan, the team's answer | `_officeRun` (reply jobs), `TeamRun._tell` → `Offices.notify` → `_officeNotify` | Teams |
| "[needs you]" posts, `office_ask_owner` | `Offices.post` / tool → `Offices.notifyNeeds` → `_officeNotify(needs: true)` | Teams: needs you |

Nothing is posted while the owner is looking at that chat or team. A bot's quiet hours hold for bots and teams.

A result the owner scheduled (a `message` routine or a scheduled task) is not counted against the bot's daily
message cap (`BgRun.outreach`). That cap is for messages the bot starts on its own. Before this change, an hourly
task stopped notifying after its third run.

## Reply from the notification (Telesia closed)

```
RemoteInput "reply_text" on the notification (payload office/<team> | conv/<chat> | botchat/<bot>)
  └─ AlarmReceiver.onReceive (reply_to)
       ├─ Notifier.replied: a team adds "You: …" to its conversation; a bot or Telesia shows "You: …" for 4 s
       ├─ TaskService.start("<name> · Your reply")      foreground + wake lock
       ├─ TelesiaApp.engine()                           headless engine (Bridge, AppUpdater, OcChannel)
       └─ Bridge.send("notifReply", {to, text})
Dart: onNotifReply → AlarmGate (waits until bots, teams and chats are loaded, at most 45 s) → _notificationReply
  ├─ NotifRoute.parse(to)
  ├─ team  → TeamRun.send(o, text): the owner's message in the team chat; whoever is addressed answers (office jobs)
  │           → each answer posts to the team's conversation notification (_officeRun)
  ├─ bot / Telesia chat → the owner's message is saved in the chat → _runAgent (a running task hears it at its next step)
  │           → at the end, its answer is posted as a notification (Bots or Agent)
  └─ unknown target → nothing starts, and the foreground service is released
```

Before this change, a reply that started a cold Telesia reached Dart before the bots and teams had loaded, and it was
dropped. It now waits behind the same `AlarmGate` as alarms.

## Working with the app closed: each path

Every path starts the headless engine through `TelesiaApp.engine()` under `TaskService` (foreground service and
partial wake lock), and waits on `AlarmGate`. The rules for unattended runs are in `bg_runs.dart`. The full flow is
in `docs/bots-background.md`.

| Path | Starts with | Unattended rules |
|---|---|---|
| A bot's routine, follow-up or check-in | alarm `bot|…` → `Bots.fire` → `_botWake` | `_botWakeConvs`: opencode asks and Telesia approvals are answered by `BgRun.permission`, or refused after `BgRun.approvalWait` with "Needs your OK" |
| A bot's scheduled task | alarm `s…` → `Scheduler.fire` → `_botWake` | same as above |
| Telesia's own scheduled task | alarm `s…` → `Scheduler.fire` → `startBackgroundTask(scheduled)` | `_scheduledConvs`. **New:** with no screen at all, a Telesia approval is refused at once and "Needs your OK" is posted. Before, it was refused silently. |
| Team work: a routine of the lead (`team_task`), queued jobs, retries | lead's wake / alarm `office|…|retry` → `_officePump` → `_officeRun` | **New:** `unattendedRun(teamKey)` is true while Telesia is off screen, so opencode asks follow `BgRun.permission` and approvals wait `approvalWait`. Before, an approval card nobody could see held the team for 3 hours. The retry alarm now carries the line `<Team> · Team work`. |
| Reply from a notification | `AlarmReceiver` `reply_to` | as above |
| After a restart | `BootReceiver` → `rearm` alarm | re-arms every alarm |

## The chime

`android_native/res/raw/telesia_chime.wav` comes from `tools/notif_chime.py`: 880 Hz, then 1320 Hz 0.11 s later,
with a 12 ms attack, an exponential decay and a light second harmonic. It lasts 0.52 s, peaks near -14 dBFS, and is
44.1 kHz, 16-bit mono (46 KB). `tools/patch_android.py` copies `android_native/res/**` into
`android/app/src/main/res`. The APK workflow now fails if `res/raw/telesia_chime.wav` is missing there, and
`res/raw/keep.xml` keeps the file through resource shrinking.

## Kotlin

- `Notifier.kt`: new channels (Agent, Bots, Teams, Teams: needs you, Background work) with the chime; old ids are
  deleted. New `from()` (agent or bot: title, summary, accent, face, Reply, `high`). New `team()` (MessagingStyle
  with `Person` on API 28+, the last 6 lines kept in the `telesia_team_notes` prefs, a group per team, Reply). New
  `face()` (a 128 px round bitmap with the initial). `replied()` now shows the owner's words. `bot()` goes through
  `from()`. `clearTasks()` also clears the team notifications and their history.
- `Bridge.kt`: `notifyFrom` and `notifyTeam`.
- `TaskService.kt`: the running line uses the Background work channel (silent, low, ongoing). The fallback is
  `Telesia · Getting ready`. A reply shows `<name> · Your reply` and passes its text and target to `replied()`.

Only platform `android.app.Notification` APIs are used (as before): no androidx. There is no kotlinc in the sandbox,
so the code was checked by reading. The APK build is the compile check.

## Device checks (after the next APK)

1. **Channels:** Settings > Apps > Telesia > Notifications lists Telesia, Bots, Teams, Teams: needs you, Background
   work, Finished tasks, Calls from bots, Needs your OK and Hello Telesia. The old "Tasks" and "Messages from bots"
   are gone.
2. **Chime:** send a bot a message, leave the chat, and wait for its reply. You should hear a soft, short two-note
   chime, not the old sound. Do the same for a Telesia scheduled task ("in 2 minutes, tell me the weather").
3. **Bot scheduled task, app closed:** set an hourly task on a bot, swipe Telesia away and turn the screen off.
   - While it works, a silent "Nova · <task>" line shows, with no sound and no pop-up.
   - When it ends, a separate "Nova" notification shows with the bot's round face (its initial on its colour) and
     1 to 3 plain lines of the result: no `**`, no code, no "Running…".
   - The fourth run of the day still notifies.
4. **Telesia's own scheduled task, app closed:** the notification is titled "Telesia", has a red accent and no face,
   and shows the result line. A watcher with nothing new posts nothing.
5. **Reply to a bot from the notification, app closed:** type "and tomorrow?". The notification shows
   "You: and tomorrow?" for a moment, then "Nova · Your reply" runs silently, then a new "Nova" notification brings
   the answer. The bot's chat has both messages when you open it.
6. **Team, app closed:** in a team chat, ask the lead something that takes a minute, then close Telesia. The answer
   arrives as "<Team name>" with "Nova: …". Reply "go ahead" from the notification: your line appears in the same
   conversation, and the team's answers follow in it. Several teams make separate notifications.
7. **[needs you]:** a teammate's "[needs you]" post pops up as a heads-up (Teams: needs you).
8. **Team approval, app closed:** a team member on "New" (Asks first) that needs a shell command gets a
   "Needs your OK" notification, and the team carries on within minutes. It does not wait for hours.
9. **Opening the app** clears the result and team notifications. The next team notification starts a fresh
   conversation.
10. `adb logcat | grep -i -E "telesia|flutter"` during a reply with the app closed shows no
    `MissingPluginException`.

## Tests

`test/notifications_test.dart` covers the summary text (markdown, cards, tags, greetings, length), the running line,
channels and titles, faces, reply routing (`NotifRoute`), `BgRun.outreach`, and the routing of bot results, Telesia
scheduled results, watcher silence, team posts and needs-you, replies from notifications for bot, Telesia and team
chats, an unknown reply target, and team unattended rules. The engine is mocked.
