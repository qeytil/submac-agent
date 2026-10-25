# Grok UI reference (for the SubMac bots area)

Written 2026-10-23 for branch `feature/luxury-ui`. Purpose: borrow Grok's *structure and calm*, not its marks.
Nothing from Grok/xAI (logo, icons, wordmark, colours, fonts, images) is copied into SubMac. SubMac keeps its own
name, logo (the red dot / AgentMark), Paper and Ink palettes, Instrument Serif + Geist type.

## Sources (opened 2026-10-23)
- Fudge design capture of grok.com (tokens, layout, components): https://fudge.design/share/grok.com-design
- AI UX Playground, Grok composer teardown (updated 2026-06-13): https://aiuxplayground.com/teardowns/grok/composer
- Grok release notes (search excerpts): https://grok.com/release-notes/oct-03-2026 (Bots in the sidebar, sections), https://grok.com/release-notes/may-30-2026 (project side panel, compact cards), https://grok.com/changelog
- EONMSK, "Grok sidebar goes live for all users" (2025-06-24): https://www.eonmsk.com/2025/06/24/grok-sidebar-goes-live-for-all-users/
- Image search for app screenshots (sidebar, history, folders) — used for orientation only, nothing stored.

## What Grok does

### Overall character
- "A deliberately quiet AI interface: large fields of near-black or near-white space, one centered task, and carefully
  contained utility." Contrast comes from the surface mode (dark/light), not from colour. One warm accent (orange
  `#FF6B35`) used sparingly; text `#FCFCFC` on dark, supporting grey `#9E9E9E`.
- Hairline (1 px) outlines and surface contrast instead of shadows; radii 8/12/16/24 and full pills.
- Spacing clusters: 4-8 (icon to label), 12-16 (controls, card interiors), 24/32/36/48 (sections).
- Type is a plain sans: body 16/24-28, labels 14/21 weight 500-550, small 13-14, titles 20/28.

### Sidebar / drawer
- Top: a search field over the whole history.
- A short list of destinations (Chat, Tasks/Automations, Projects/Workspaces, History) — text-first rows, no cards.
- History grouped by time, pinnable rows, a row menu (rename, pin, move to project, delete) behind a long-press /
  overflow, never as visible buttons.
- **Bots section** (Oct 2026): "Your Bots appear in the sidebar's Bots section … organize the Bots sidebar into
  sections: create, rename, and reorder them, collapse each one separately." Each bot opens its own thread.
- Projects get a compact side panel with small rows and a smooth collapse animation.
- The sidebar can retract to an icon rail on web; on mobile it is a full-height drawer.
- Account / settings sit at the very bottom as one quiet row.

### Composer
- One rounded pill: `+` on the left (upload, recent, skills, connectors — a short four-row menu), the prompt, the
  model tier (Fast/Auto/Expert/Heavy) on the right, mic/voice icons on the far right.
- "No starter pills, no tool chips, no mode vocabulary on first load. You can just type."
- The right slot turns into a filled send arrow only once there is something to send.
- Attachments and armed skills appear as small chips *inside* the pill.

### Model picker
- Outcome labels (Fast, Expert, Heavy) with the version as quiet subtext; Auto explains that it chooses.

### Conversation
- Reading column, answer text without bubbles, a light action row and follow-ups kept visually subordinate.
- "Thinking" streams in a semi-collapsed box.

## What SubMac takes (and how it is SubMac, not Grok)
| Grok idea | SubMac version |
|---|---|
| Quiet drawer, search on top | `BotsDrawer`: search field, then sections, Paper/Ink surfaces, Geist rows, serif "SubMac" mark at the top. |
| Bots as a sidebar section, collapsible | Sections **Bots** (every bot profile with its presence dot), **Teams** (each team with "Led by <lead>", the Chief), each collapsible with a soft size animation. |
| Row menus behind long-press | Long-press a bot row: Message, Call, Profile. Long-press a team: Open, Tasks. |
| Account at the bottom | "New bot" + Settings row at the bottom. |
| Calm `+` composer, send appears only with text | The same Phase-1 composer in every bot chat. |
| Model tier on the bar | Not copied: SubMac has one model for every job (server picks), so no picker is shown. |
| Orange accent | SubMac's own brand red, used only for the activity dot and destructive actions. |
| Hairlines, no shadows | Already SubMac's rule (no dividers, spacing separates). |

## Not taken
- Grok's logo, black-hole mark, icon set, orange, promo/upgrade pills, Imagine/Private toggles, persona picker.

## Grok Bot roster, checked again 2026-10-23 (owner: "teams on, like Grok bot")
Sources: flaviocopes.com/grok-bot (desktop sidebar screenshot "Update old posts", Primary Bot dialog), Cursor forum (iOS sidebar
sections), docs.x.ai/grok-bot/bots. What the screenshots show:
- The sidebar is a **roster, not a history**: search on top, then plain grey section names with a quiet count
  ("Daily", "Every week", "Unassigned 2"), each foldable.
- Each row: avatar, **name** in bold, the time on the end ("8:20 AM", "Yesterday", "9/1"), and one muted line of the bot's
  last result. An unread dot sits on the end. No cards, no borders.
- The foot of the sidebar holds Marketplace and the account row. iOS: profile at top left, search and + at top right.
- One **Primary Bot** has a small badge and can be replaced ("Replace with different Bot"); it does everyday work and routes.
SubMac version: Bots screen = this roster. Sections Chief (SubMac's crown icon, `assets/icons/crown.svg`, "Change"),
Bots (working first, then latest activity) and Teams (lead's face, last post, "New"). Foot: New bot, Bot Store. Wide
screens keep the roster at 340 px with the bot or team beside it. Teams are on (`LaunchFlags.teams = true`).
