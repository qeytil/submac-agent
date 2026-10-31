# Agent flexibility: why the agent broke on new tasks, and the Claude Code fix

Owner request (2026-10-31): "the agent/bot can do only what we trained with, but struggles or breaks if
user asks different tasks that we didn't tested... our app should be Claude Code but in SubMac skin and
mobile." This document is the research and the fix.

## Second pass: what the open-source Codex CLI taught us (cloned openai/codex, codex-rs)

The first fix made the agent *willing* ("find a way"). The owner pushed back: willingness without honesty
breeds an agent that claims it can do what it cannot. Reading Codex's real system prompts
(`codex-rs/core/gpt_5_2_prompt.md`, `gpt-5.2-codex_prompt.md`) and tool registry shows how OpenAI squares
ambition with honesty — there is no "don't lie" lecture; there are four precise rules:

1. **Prove by trying, not by asserting.** "Do NOT guess or make up an answer... Autonomously resolve the
   query to the best of your ability, using the tools available to you." Capability is never claimed in
   the abstract — the agent runs the command and the tool result answers the "can you" question. (Codex's
   sandbox makes this cheap to do; SubMac's trust gates play the same role.)
2. **Never plan a step you cannot take.** "The content of your plan should not involve doing anything
   that you aren't capable of doing (i.e. don't try to test things that you can't test)." Overclaiming is
   blocked at the plan, before it becomes a broken promise.
3. **What you couldn't verify, hand over.** "If there's something that you couldn't do (even with
   approval)... include those instructions succinctly." An unverifiable claim is replaced by the exact
   step the user can run themselves.
4. **Persist through tool failures.** "Persevere even when function calls fail. Only terminate your turn
   when you are sure that the problem is solved."

Codex also settles the tool question: its whole registry is a handful of primitives (shell, apply_patch,
plan, view image, web) — and **Code Mode** lets the model call tools *as code*, composing them
programmatically. The lesson: the agent's toolset must be a floor to build on, never a ceiling. Any
capability it lacks should be *writable*.

## How Claude Code actually generalizes

Claude Code handles tasks nobody trained it for because of harness design, not model training:

1. **The loop is dumb on purpose.** One loop: call the model → run its tool calls → feed results back →
   repeat until it replies without tools. No task classifier, no workflow per use case. Complexity lives
   in tools, permissions, hooks and compaction — never in predicting what the user will ask.
2. **Broad primitives, not task tools.** Bash, Read, Write, Edit, Glob, Grep, WebFetch, sub-agents. The
   model *composes* a solution from general-purpose pieces. Any task that can be done on a computer has
   the parts it needs.
3. **Nothing is scoped away in advance.** Every tool is always visible; risky ones ask permission. The
   harness never decides "this message is not about X, so hide X's tools."
4. **Errors are fuel, not failure.** A failed tool returns its error text to the model, which fixes the
   inputs or tries another way. "Keep going until the task is fully done" is an instruction, enforced by
   the loop, not a hope.
5. **The prompt tells the model how to behave, not what shapes to emit.** Few output mandates; format
   rules never override solving the task.

## What SubMac did instead (the audit)

- **Regex lanes and hints decided everything before the model saw the message.** `QuickLane.laneFor`
  sent any message under 160 chars with no action keyword to the *light* lane (stripped prompt, ~17 core
  tools) — "can you fix my resume?" has no action word. The *quick* lane (no tools at all, "no lists, no
  headings") sat one short phrase away.
- **Tool groups opened only by keyword.** Eleven groups (browser, phone, files, apps...) open when a
  regex in `ToolScope._hints` matches. A novel task that missed every regex started with core tools only:
  no file tools, no browser — and recovered only if the model spontaneously called `more_tools`.
- **Narrow vertical tools with no composition floor.** biz_/health_/life_ silos are fine as shortcuts,
  but the general floor (files + web + shell + code) was itself gated behind keywords.

## The fix (implemented 2026-10-31)

1. **Questions and requests never take a small lane** (`lib/services/quick_lane.dart`). A new `_request`
   pattern — "?", can/could/how/what/please/help/need/want, Somali caawi/rabaa/ii sheeg... — sends these
   straight to the full lane. Greetings, thanks and "ok" still get the instant reply.
2. **A novel task gets a general workbench** (`lib/state/agent_stream.dart`, `_scopeFor`). When a message
   points at no tool group at all, the chat opens `browser` + `files` by default: web reading and file
   writing for anything new. Groups only ever grow, trust gates (money, sends, deletes) are untouched,
   and pure small talk still opens nothing.
3. **The prompt says what Codex says** (`lib/state/agent_prompt.dart`, "# Anything they ask"):
   - *Willingness*: build the missing step from write_file/edit_file/run_shell/fetch_url/api_call/
     code_run/browser_task, call more_tools when a tool is missing, keep going — check, fix, retry —
     until the work is really done.
   - *Honesty* (the Codex rules): never claim a capability or a result without tool evidence; never make
     up an answer — run, read, test, then say what you saw; never plan a step you could not take; if
     something is truly impossible, say exactly what is missing and give the best part of the answer;
     what you could not verify, say so plainly and hand the user the exact step to check.
   - *Tool creation*: if no tool fits, make one — write the script, run and fix it until it truly works,
     then save the proven method with `skill_save`.

## The agent can now forge its own tools (`skill_save`, implemented 2026-10-31)

SubMac already had every raw piece of runtime tool creation except the last wire: `write_file` writes
into a persistent workspace, `code_run path` executes a written script and files persist between steps,
`run_shell` reaches the same workspace. What it lacked was a registry — a way for a proven script to
*become* a tool. Now:

- **`skill_save(id, name, desc, body, tags)`** (`lib/services/skill_library.dart`) saves the method on
  the phone in the same folder and JSON format as downloaded library skills, marked `local`. It is
  instantly searchable, listed under "Your own skills", installable-free (already in the agent's
  installed list), readable with `skill_use`, and survives index refreshes and restarts. Library ids are
  protected (a local save can never shadow a library skill); local skills are never evicted by the
  60-skill cap; overwrites bump the version.
- **Every bot has it too** (added to the core power set in `lib/services/bot_powers.dart`), so a bot that
  learns a method teaches itself permanently — the closest thing to Claude Code's growing skills folder.
- The prompt convention ties the loop: build → test → save → reuse. This is Codex's Code Mode idea in
  SubMac's skin: the toolset is a floor, and the agent writes the missing tools onto it.

## What stays honest (the one gap)

- **The cloud computer.** SubMac's `run_shell` is Android toybox (no Python, no root), and heavy builds
  run through GitHub Actions. A task needing a real Linux box (long compiles, arbitrary packages) is the
  one capability Claude Code has that SubMac cannot give it on the phone — the owner already marked this
  as the allowed gap.
- The vertical tools (business books, health book, prayers) stay: they are SubMac's skin. Generalization
  comes from the floor under them, not from removing them.
