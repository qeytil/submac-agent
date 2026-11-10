# The per-person runtime (owner 2026-11-08)

The owner's ask: every digital person should run on its **own runtime**, so many of them never conflict — their own
engine, brain, memory, sandbox — and a team should feel like a **WhatsApp group** where each member is a person.

This is the architecture, and it is honest about the one thing a phone cannot duplicate: its physical hardware.

## 1. One engine, one instance per person

An "engine" is **code**. You do not copy the code per person; you give each person its **own instance** of it. That is
already how bots run:

- `BotAgents.forBot(b)` keeps one stable `BotAgentConfig` per person (its limits, its notes folder).
- Every turn builds its own `BotAgentEngine` with that person's config — no shared loop, no shared session.
- `RuntimeHost.of(botId)` (new) keeps one `BotRuntime` per person for the life of the app: its phase (idle / thinking /
  working / waiting / off), its last and next wake, its in-flight count, its queued wake.

So "each bot creates duplicates of the engine" is already true in the only sense that matters: **separate state, separate
loop, separate schedule** — one codebase, many independent instances.

## 2. What is already per-person

| Piece | Where | State |
|---|---|---|
| Engine instance + limits | `bot_agent/` | per turn, per person |
| Brain / model | `BotModelRoute.of(b)` | the person's own BYOK key, else Telesia's lane |
| Memory | `b.memory`, `b.journal`, `b.knowledge` | its own |
| Sandbox | `Bots.botFolder(b)` | its own notes/files folder |
| Conversation | `b.convId` | its own chat |
| Allowance | the person's profile | its own |
| Rhythm | `RuntimeHost.jitter(b.id, window)` (new) | its own offset in the wake window |
| Presence | `RuntimeHost.of(b.id).phase` (new) | its own live state |

## 3. What cannot be duplicated (the honest part)

A phone has **one microphone, one speaker, one WebView, one battery, one network**. These are physical, and pretending
otherwise would ship noise:

- **Voice:** only **one live call** can hold the microphone at a time. The right build is one call at a time, plus a
  **group call** = **one** Live session with **many personas** (the model decides who speaks; each has its own voice).
  That is what a real group call is, and it is one runtime with many participants — not N runtimes.
- **Browser:** browser-using people share the one WebView, so they queue on it. This is a device resource, not a design
  flaw.
- **Model calls:** a **governor** (planned) caps total in-flight calls, so 50 people never stampede the network or the
  battery. Independence means *never blocked by each other*, not *all at once*.

## 4. Why not a Dart isolate per person

The cost of a turn is the **model's network round-trip**, not CPU. An isolate per person would add memory and complexity,
would **not** make a turn faster, and the plugins/browser/audio would not move with it. Isolation here is **logical**
(its own state, schedule, queue, identity), which is what removes the conflicts — and it costs almost nothing.

## 5. What ships now

- **`BotRuntime` + `RuntimeHost`** — one runtime per person.
- **Heartbeat jitter** — a stable per-person offset inside its wake window, so a crowd never wakes in the same minute
  (the old "thundering herd").
- **A free check-in gate** — a person with no open desk work, no promised follow-up and no live mission costs **zero**
  model calls at its heartbeat (`Bots.checkInEmpty`). Only when there is something does it ask the fast yes/no question.
- **A live "Thinking" phase** — the person shows it is thinking while it prepares, before its run turns it "Working".
- **Presence in its own voice** — a bot's chat says "Nova is thinking", "Nova is reading a file", "Nova is reconnecting";
  a desk item left for the owner reads **"Waiting for you"**.
- **The event inbox** (`BotInbox`, one per person, in `BotRuntime.inbox`) — real events about the world wait in that
  person's own queue: **deduped**, **bounded**, and a burst becomes **one wake with one digest** (12 s quiet moment) instead
  of one turn per event. Today the phone-notification watches feed it (`Bots.notificationEvent` → `Bots.onEvent` →
  `AppState.pushBotEvent`); an event that finds the person busy waits only **2 minutes**, not the 15 of a routine.
  Email, a price or a page changing is the same call, so a new source needs no new plumbing.

## 6. Next

1. **The governor** — a cap on total in-flight calls, so many people work at once without stampeding.
2. **More event sources** — email and calendar through the connectors, and a page/price watcher, all pushing into the
   same per-person inbox.
3. **Voice** — one call at a time done well, then the **group call** (one session, many voices).

## 7. Teams are groups

A team is a **group chat**, and each member is a person with its own runtime, avatar and voice:

- One group thread; every member reads it and speaks as itself (already: `team:<team>:<bot>` sessions, team live lines).
- You **@name** a member; it answers. Members talk to each other in the group.
- The **lead coordinates** (assigns, combines) — it is a coordinator, not a separate engine.
- A **group call** = one voice session with the members as participants.

Nothing about a person changes between its 1:1 chat and its group: same runtime, same brain, same memory.
