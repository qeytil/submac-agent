# Bots working with Telesia closed

Owner bug (2026-11-05): a bot asked to "use your research tools and send me local and international news every
hour in Telegram" did nothing until the app was opened. The notification said a scheduled task was running, but
the work only started once Telesia was on screen. Fixed in 1.13.125+195 (branch `fix/bots-background`).

## Root causes

1. **opencode had no channel without the screen.** The `telesia/native` handlers that start and query the engine
   (`ocStart`, `ocToken`, `ocStop`, `ocStatus`) were registered only in `MainActivity.configureFlutterEngine`
   (MainActivity.kt:130 before the fix). An alarm starts the engine headless through `TelesiaApp.engine()`
   (TelesiaApp.kt:27), which attached only `Bridge` and `AppUpdater`. With Telesia closed (a cold process), the first
   `OpenCodeEngine.ensure()` → `_start()` call `invokeMethod('ocStop')` (lib/services/opencode.dart:113) threw
   `MissingPluginException`, so the bot's turn failed before it started. Once the screen opened, the handler existed
   and the next run worked: hence "only when I open the app".
2. **No wake lock.** `TaskService` was a foreground service only. That keeps the process, not the CPU: with the
   screen off (Doze) the run stalled until something woke the phone.
3. **Alarm before start-up finished.** Android delivers the queued `alarm` event as soon as Dart says `ready`
   (`SystemBridge.init()`, lib/state/system_phone.dart, before the fix line 155). `Scheduler` and `Bots` were loaded
   *after* that, so `Scheduler.fire()` found no task (uid not loaded yet), dropped it and turned the service off.
4. **Waiting on cards nobody can see.** opencode asks before `bash`; in a bot's chat that became an in-app card
   with no timeout. Telesia's own approvals for a bot waited up to 3 hours behind a notification.
5. **Held wakes only ran from the home screen.** A wake that came before the account was restored was held and
   replayed only by `onSignedIn()`, which runs from `HomeScreen`'s first frame (never, headless).
6. **Boot re-arm could freeze.** `BootReceiver` started the engine directly; the receiver's process is frozen
   seconds after it returns (and Android 15 forbids a dataSync service from a boot broadcast), so the alarms were
   sometimes never set again after a restart.

## The flow now

```
AlarmManager.setExactAndAllowWhileIdle (USE_EXACT_ALARM)            Alarms.set(id, at, label)
  └─ AlarmReceiver.onReceive (exact alarm: allowed to start a foreground service)
       ├─ TaskService.start(label)  → foreground (dataSync) + PARTIAL_WAKE_LOCK (30 min, renewed on every update)
       ├─ TelesiaApp.engine()        → headless FlutterEngine, main() runs; Bridge + AppUpdater + OcChannel attached
       └─ Bridge.send("alarm", id)  → queued until Dart says ready
Dart main() → AppState.initLocal() → _initSystem()
  ├─ SystemBridge.init() → "ready" → onAlarm(id) → AlarmGate (waits for start-up, max 45 s)
  ├─ headless? (no lifecycle state, not foreground) → appVisible = false
  ├─ Scheduler.init(uid) + Bots.init() (re-arms every alarm) + Offices + TelegramBridge.init (awaited)
  ├─ held wakes run, then retried after 15 s / 45 s / 2 min (BgRun.heldRetries)
  └─ AlarmGate.open() → _onAlarm(id)
        ├─ 'bot|<bot>|<routine|followup|hb|rep>' → Bots.fire → _botWake
        ├─ 's…' scheduled task → Scheduler.fire (arms the next run first) → runTask → bot task: _botWake
        └─ 'rearm' (after a restart) → alarms are already set → keepAlive(false)
_botWake
  ├─ ready? budget (bot's own daily budget, bots' share) → else hold / note / skip
  ├─ keepAlive(true, "<Bot name> · <task title>")       (BgRun.line)
  └─ startBackgroundTask → _runAgent (opencode)
        ├─ OpenCodeEngine.ensure() → telesia/native → OcChannel (works with no Activity) → OpenCode.kt + LocalProxy
        ├─ lane: bots' share (telesia-bg), OcBgGuard stops it when the share or the bot's budget runs out
        ├─ tools: opencode's own (webfetch allowed), Telesia MCP (web_search, bot_*, bot_telegram, …)
        ├─ permission asks: unattended → BgRun.permission (Full access or "On its own" bot: once; else reject +
        │   one "Needs your OK" notification). Questions are skipped.
        ├─ Telesia approvals: unattended → notification, wait BgRun.approvalWait (3 min), then refuse + "Needs your OK"
        └─ end → _ocRunEnded → _botOutcome: result saved in the bot's chat; @message → notification; keepAlive(false)
```

`bot_telegram` (new bot tool): sends the text (and files) to the owner's own paired Telegram chat through the
Telegram bridge. It reaches only the owner, so it needs no approval and no power can switch it off. When Telegram
is not connected or not paired, the tool says so and the bot tells the owner where to connect it.

Cadence: hourly / every 3 hours / daily tasks are `Scheduler` tasks (`schedule_task`), time-of-day routines are
bot routines. Every fire arms the next one before the run starts; a restart re-arms through the `rearm` alarm.

## Kotlin changed

- `OcChannel.kt` (new): the four opencode calls, app context only; attached to every engine `TelesiaApp` makes.
- `MainActivity.kt`: forwards `ocStart|ocToken|ocStop|ocStatus` to `OcChannel` (was inline).
- `TelesiaApp.kt`: `OcChannel.attach(...)` on engine creation.
- `TaskService.kt`: wake lock; a second start while running only updates the line; alarm `label` extra.
- `Bridge.kt`: `scheduleAlarm` passes `label`.
- `BootReceiver.kt`: sets a `rearm` exact alarm 5 s out (also when only scheduled tasks exist) instead of starting
  the engine from the receiver.

No kotlinc in the sandbox: the Kotlin was checked by reading only. The APK build is the compile check.

## Device checks (after the next APK)

1. Make a bot, ask it: "send me local and international news every hour in Telegram" (Telegram paired). Swipe
   Telesia away from recents, turn the screen off.
2. At the hour: notification "<Bot name> · Send me local and international news…" appears, a Telegram message
   arrives within a few minutes, the notification goes away, the bot's chat has the run.
3. Doze: `adb shell dumpsys deviceidle force-idle`, then `adb shell cmd alarm` / wait for the alarm (or set the
   task "in 2 minutes"). The run must still finish with the screen off.
4. Restart the phone, do not open Telesia: within ~10 s a short "Getting your bots ready" notification, then the
   next hour still fires (`adb shell dumpsys alarm | grep com.telesia.app` lists the alarms).
5. A "New" (Asks first) bot whose task needs a shell command: the run ends and a "Needs your OK: Run this command?"
   notification appears; nothing hangs, no stuck "running" notification.
6. Battery: Settings > Apps > Telesia > Battery "Unrestricted" helps on Xiaomi/Samsung/Huawei, whose own killers
   ignore exact alarms for "restricted" apps.
7. `adb logcat | grep -i -E "telesia|opencode|flutter"` during a run: no `MissingPluginException`.

## Tests

`test/bots_unattended_test.dart`: AlarmGate order and timeout; BgRun rules (unattended, line, permission);
OpenCodeAsks unattended (refused at once and told, allowed at once, question skipped, watched chat still asks);
an alarm before start-up runs after it, unattended, with the "<Bot> · <task>" line (mock engine); a held wake runs
on a retry without the home screen; an unattended approval stops after `approvalWait` and notifies; a scheduled task
fired before the Scheduler loaded runs once it has and the next hour is armed with its label; `bot_telegram`.
