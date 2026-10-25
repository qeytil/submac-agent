# How Grok's bots work with people (research, 2026-10-24)

Why: the owner asked (2026-10-24) to make SubMac's bots and teams "professional like Grok bot", then to "focus on grok first"
and follow Grok's real behaviour. This note is what we found and what SubMac now does because of it.

## Sources (read 2026-10-24)

- xAI, *Introducing Grok Bot* (Aug 11, 2026): https://x.ai/news/introducing-grok-bot
- xAI, *Designing Grok Bot for a world of persistent agents* (Sep 3, 2026): https://x.ai/news/designing-grok-bot
- Grok Bot docs, *Create and manage Bots*: https://docs.x.ai/grok-bot/bots
- Grok Bot docs, *Get started*: https://docs.x.ai/grok-bot/get-started
- Grok Bot docs, *Message and collaborate* (group chats, handoffs, stop): https://docs.x.ai/grok-bot/chat-and-collaboration
- Grok Bot docs, *Approvals, security, and privacy*: https://docs.x.ai/grok-bot/approvals-security-and-privacy
- Grok Bot docs, *FAQ*: https://docs.x.ai/grok-bot/faq
- Grok Bot changelog (first-bot setup, Primary Bot proactivity): https://x.ai/changelog/bot
- xAI API docs, *Multi Agent* (grok-4.20 leader + sub-agents): https://docs.x.ai/developers/model-capabilities/text/multi-agent
- Screens kept in the workspace: Grok Bot "Create your first Bot" and "Introducing Primary Bot".

## One bot

- **A Bot is a teammate, not a chat.** The sidebar is a roster of Bots (name, avatar, title), not a history of chats. You
  come back to the same Bot tomorrow; it remembers.
- **Creating one is light.** New chat → *Create new Bot* gives a Bot called "New Bot"; the create screen is one calm column:
  a big face, a row of colours, a row of shapes, a Name field and one *Get started* button, with *Suggestions* (ready
  roles such as "Night Shift", "Inbox Triage") under it. Name, title, description and picture are edited later from the
  Bot's details. Setup is a message, not a workflow builder: "give the Bot its job, sources and approval boundaries in
  the first message".
- **It acts when you give it work.** "Message it like a teammate and hand off the work"; Bots "finish jobs end to end, and
  only come back when something needs your approval". There is no ask-every-step mode; the docs warn there is no dry
  run.
- **Opening and proactivity.** A new Bot waits for its first task. The Primary Bot (marked with a star) "will spot work it
  can take off your plate and offer to handle it": it offers, it does not start. Suggestions are shown as choices.
- **Approvals.** Consequential actions (send, publish, delete, purchase, change production) stop for an approval card in
  the chat with **Allow once**, **Always allow** (saves a rule) and **Deny**. *Auto-review* rules: *Ask first* always
  stops; *Allow automatically* lets matching actions run. Passwords, codes and payments are a hand-over to the person.
- **Tone and form.** Answers are short, specific and often structured (cards and inline widgets instead of long prose).
  Status is shown by the avatar's motion and a short step list, not by spinners or dots.

## Teams (group chats and multi-agent)

- **Group chats** hold two to six Bots plus you. "Write normally to let the participating Bots decide who should
  respond", or @mention one. Bots "pass work, assign ownership, and only pull you in for judgment calls". Handoffs are
  visible in the conversation; one owner per stage.
- **A coordinator.** People make a "Chief of Staff" Bot that coordinates specialists so "you're not the middleman".
- **Steering.** A new message redirects work in progress; "Stop now" ends it immediately (finished actions are not
  undone).
- **Multi-agent answers (grok-4.20).** A leader agent splits the task, sub-agents work in parallel, the leader resolves
  conflicts and presents one final answer; the app shows live progress notes per agent.

## What SubMac does now (and why)

| Area | SubMac now | Grok basis |
|---|---|---|
| New bot | One page on the sky: face with colour and shape rows, then Name, Role, What it does, Instructions on one surface, *Can use* switches, one ink pill button; role *Suggestions* fill the form. | Create screen, Suggestions, "give it its job and boundaries" |
| First message | The bot greets in a line, says what it can take on and suggests one or two first tasks as tap replies. That turn has no tools (engine guard, `BotAsk`). | New Bot waits for a task; Primary Bot offers |
| Greetings, small talk | No tools; a short reply with suggestions. | Same as above |
| A real request | Runs end to end without check-ins; comes back only for a judgment call or an approval. | "Finish jobs end to end" |
| Teams | The lead posts who does what and the team starts at once; it waits only when it must ask the owner something. Members report in the chat; the lead gives one combined answer; "stop" stops. | Group chats pull you in "only for judgment calls"; leader synthesises |
| Approvals | Settings > Advanced > **Full access** (off by default): on = no approval cards, except payments and purchases. Off = small changes in SubMac's own space no longer ask. Every card has **Allow always (Full access)** (never on a payment). | Allow once / Always allow / Ask first rules |
| Look | Approval cards, profile tabs, team screens, call screen and chat cards on the shared sky surface: no borders, no dots, pills for actions. | Calm, minimal UI; avatar carries status |

Owner's earlier rules (bots never act; teams wait for Go) were dropped on the owner's instruction of 2026-10-24 10:15
+0330 ("ignore my rules … focus on grok first"). Where Grok has no equivalent (Somali/Arabic, phone tools) SubMac keeps its
own behaviour.
