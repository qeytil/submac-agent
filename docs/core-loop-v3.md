# Core loop v3: an agent that is ready for anything

*2026-11-01. Owner: "our agent breaks if a user tries heavy tasks we did not train for, and if we train for tasks it
looks templated… we want the agent ready for anything." Research: what Claude Code, Codex, Cline, OpenHands and Manus
actually do (sources in the PR). Audit: the harness, traced end to end, file:line evidence.*

## The finding

The model was not the main problem. The harness kept deciding for it:

1. **Keywords picked the toolbox.** A short plain request with an uncommon verb ("reconcile my two statements",
   "benchmark three sorts") went to a light lane of ~18 tools with no write_file and no code_run. 6 of 10 novel heavy
   tasks landed there; 9 of 10 never saw the Python runner, while the prompt said "no python".
2. **Every plan was made at low effort**, on a pool of flash models.
3. **Every step after the third tool call said "Before your final reply… then reply:"**, and the user's request was
   re-sent as a fresh user message after every tool batch. Weak models answered early or started over, always in the
   same three-line shape. That is the templated feel.
4. **Working memory was thrown away**: 3 whole tool results, history folded to 300 words above 14k tokens.
5. **Progress meant files written.** A research or debugging run (all reads) was paused at step 50; polling a build
   six times was called a loop; only one read-only browser job per task.

## What v3 changes (this branch)

| | before | v3 |
|---|---|---|
| lanes | quick / light / full by regex | quick (whole-message small talk) / full |
| tools for real work | groups by keyword | browser + files + code always open; the rest one `more_tools` away, listed |
| effort | step 0 `low`, then the route default (`low`) | step 0 `high`, then `normal` = explicit `medium` (server) |
| per-step notes | final-answer shape after 3 calls; request re-sent each step | open checklist only; request recited every 8 steps, after a change or a compaction, as a reminder |
| prompt | "about 6 searches and 3 pages"; "no python" | depth follows the question; code_run for real programs; anti-early-stop rule; work like an engineer on unfamiliar tasks |
| memory | 3 whole results; 14k/5k history; 300-word summary | 10 whole results; 48k/16k; structured summary (task, state, files, what failed, next, promised) |
| progress | todo ticks or 2 writes | also 6 tool results never seen before; strikes forgiven on a write or a tick |
| loops | same call 6× whatever it returned | same call with the same result, or the same error |
| research browser jobs | 1 per task | 3 |
| read_file | 12k chars by char offset | also numbered lines by start_line/end_line |

## Next (not in this branch)

- **Server, needs a deploy:** pin one route per run (no mid-task model family swap), a stronger tier for tool steps,
  and a longer first-output limit for tool steps with big prompts. The effort change here also ships with `ai-chat`.
- An agent eval of 30–50 tasks it was never built for, run on every harness change (like browser_eval).
- A general `spawn_agent` (context isolation), a todo `in progress` state, and slimming the prompt's task recipes.
