# Chat bug hunt 4: TEAMS (investigation only, do not merge)
Status: FINAL (2026-10-25 ~16:30 +0330). No merges, PRs or main pushes, and no changes to edge functions, `ai_settings` or real users.

## 0. Blocker: the emulator never ran
- Run **40193621738** (`chat-bughunt4-teams-emu.yml`, branch `chat-bughunt-4-teams`, head 0a04f40) failed in 0 s on attempt 1 and again on attempt 2 (re-run). No runner was assigned and no steps ran.
- The check-run annotation says: "The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the 'Billing & plans' section in your settings."
- This is GitHub billing for Submac-Org, and only the owner can clear it. Per the brief (no more than two loops on a blocker), I stopped.
- First dispatch attempt: `workflow_dispatch` returned 404, because GitHub only accepts dispatch for workflow files that exist on the default branch. The workflow now runs on push to this branch only.
- The harness is ready. Once billing is fixed, a push that touches the harness files starts it. Raise the allowance for the new `chatbugs4t-emu-*` uid while the APK builds (about 20 minutes).
- In place of the emulator run:
  - a small **live probe** of the team's two decision calls (floor = who speaks, and the plan), sent through production ai-chat v41 with the exact `floorSystem` text, as source `office`;
  - a **code reading** of every path on `chat-bughunt-3` (25f3d0e).

## 1. Results table
| # | Task | Outcome | Evidence |
|---|---|---|---|
| 1 | Create team (lead + 3) | Not run on device. Harness c0 creates Hodan (lead), Nova, Amina, Faisal. | — |
| 2 | 3-part job (laptops + table + email draft) | **Live floor:** `team_task:true` 2/2. **Live plan:** 3 parts (Nova, Amina, Faisal) and `questions:[]` 2/2, so the code starts at once with no go-ahead. That contradicts the intro "will suggest a plan and wait for your go-ahead" (CB-36). Full job not run. | teams_live/floor_results.json, plan_results.json |
| 3 | Second request while working | **Code:** while `busy`, the text goes to `_inbox` only, with no reply and no notice (CB-37). **Live floor** (team not busy): goes to Nova or Amina 2/2, so it would be answered. | team_run.dart send() busy branch |
| 4 | Owner Stop mid-job | **Code:** `busy()` is still `running` only, so reply jobs from `askBot` can't be stopped (CB-34). A part in flight posts "I could not finish my part this time." after stop (CB-19). **Live:** "stop" when not busy is routed by the floor, which picked Hodan 1/2, so a reply job starts instead of a stop. | team_run.dart l.107, _part/doPart |
| 5 | Step caps, report quality | **Code:** a member stops at 10 model calls (`memberSteps`). A halted run with no text becomes "I could not finish my part", and the research is lost (CB-65). Round 3 research took 18 steps, so a hit is likely. The lead's cap of parts+3 falls back to `_combine` (safe). Report quality: not measured. | core.dart l.603–606 |
| 6 | Team usage / Bot Activity | **Code + live numbers:** `_teamLlm` adds raw `r.tokens` to each bot's `tokensToday`. Probe raw total 8,943 vs about 3,005 server-weighted (3.0×). No team-level usage view exists. CB-20 still stands. | bots_controller.dart _teamLlm |
| 7 | Member error / tool failure | **Code:** a tool error is passed to the model as text. A failed model call → `onError` stop → generic "I could not finish my part" (English/Somali), with no retry and no reason. Not run. | team_run.dart _part |
| 8 | Delete team while running | **Code:** `Offices.remove()` never calls `TeamRun.stopWork`. Cores keep running and spending, and posts go to an orphan object that is never saved. `running` keeps the id until the end, and that office's pending approvals stay (CB-60). | offices.dart l.972 |
| 9 | Reopen app mid-job | **Code:** TeamRun has no `keepAlive` and no resume. A kill leaves "We are starting now. I will report back…" with no report and no notice (CB-62, CB-64). | team_run.dart |
| 10 | Somali / Arabic | **Live:** Somali → team_task 2/2. Arabic → team_task 1/2 (other try: plain reply by Amina). Arabic plan text is Arabic, but the app wraps it in English ("The plan:", "We are starting now…", "Nova, could you please take this part:") (CB-63). | floor/plan results; bot_manner.dart |
| 11 | Notifications | **Code:** TeamRun's plan, parts, answer and failure posts never notify. `_officeNotify` is only used for digests, credit pauses and `office_ask_owner` (CB-61). | team_run.dart, bots_controller.dart |

## 2. Bug verdicts
| Bug | Verdict |
|---|---|
| CB-19 member posts after Stop | **Confirmed (code), not on device.** The `_part` catch posts `partFailed` after `stopWork`. `doPart` posts without checking `_stopped`. |
| CB-20 bot usage counts raw tokens | **Confirmed (code + live numbers).** Bot Activity shows raw counts, about 3× the weighted charge on the probe. |
| CB-34 stop doesn't stop members / busy false | **Confirmed (code + live floor).** `busy()` is unchanged. A not-busy "stop" goes to the floor and may wake Hodan. |
| CB-36 plan promised | **Confirmed, changed form.** The floor now marks 3-part jobs as team tasks (4/4, so the round-2 single-reply case is not reproduced in English; Arabic 1/2 still single). But the plan starts at once (`questions:[]` 3/3), and the intro still promises a go-ahead wait. |
| CB-37 follow-up silently dropped | **Confirmed (code).** While busy it goes only to `_inbox`, with no reply and no notice. When not busy, the live floor answers it. |

New bugs (all **confirmed (code)**; none on device):
- **CB-60 (High)** Deleting a running team doesn't stop it. Work and spend continue into an orphan team. Fix: call `TeamRun.stopWork(o.id)`, then `Offices.expireFor` the team's approvals, in `remove()`.
- **CB-61 (Medium)** No notification when the team posts its plan, its answer or a failure while the owner is away.
- **CB-62 (Medium)** Team runs don't hold `keepAlive`, unlike `_officeRun`, so Android can stop a job in the background.
- **CB-63 (Medium)** Arabic teams get English fixed phrases (plan header, start line, hand-offs, stop and failure lines). Only Somali is detected.
- **CB-64 (Medium)** After a process kill, a started team job is lost with no message. The "I will report back" promise is broken.
- **CB-65 (Medium)** The member step cap (10) throws away the member's work: the halted run becomes "I could not finish my part", with no final summarise turn.
- CB-66 to CB-74: unused.

## 3. Tokens (`ai_usage`, uid 2ce2c1bc…, source office, gpt-oss:120b)
15 calls (12 floor + 3 plan): **6,920 prompt / 2,023 completion / 5,472 cached**. v41-weighted ≈ 1,448×0.3 + 5,472×0.1 + 2,023 ≈ **3,005**. This was charged to the free bucket; the 50M grant was untouched. The emulator run used 0.

## 4. Allowance change, and its revert
- Plans and allowance live in `billing.*`. `usage_gate` → `billing.position()` adds up the free bucket, `billing.subscriptions` and `billing.token_balances` (PAYG). `billing.is_unlimited()` reads the global `ai_settings.billing_unlimited`, so I did not use it.
- Change, per uid only: one `billing.token_balances` row each, 50,000,000 tokens, source 'admin', status active, expiring in 2 days, note 'chatbugs4t round-4 teams test allowance…':
  - dcaefb4a-5327-4b1c-aee1-b7e25f213d64 → 2ce2c1bc-80b3-4a4d-9663-12b5b53bd61e (chatbugs4t-a-1792931129)
  - 0aae6282-0ee7-4e93-9b45-9ad444918d80 → 6f541378-e877-460b-a2a0-aa33ab0eff16 (chatbugs4t-b-1792931129)
  - Afterwards `usage_gate` showed plan payg, today_left 50.2M.
- **Reverted:** both rows deleted (2). A check for any balance with a chatbugs4t note or uid returned 0.

## 5. Cleanup
- `delete from auth.users where email like 'chatbugs4t-%@example.com'` removed **2 rows** (the a and b accounts). Count afterwards: **0**.
- No `chatbugs4t-emu-*` account was ever created, because the job never started. chatbugs4b accounts were not touched (1 present).
- `ai_usage` rows were kept.

## 6. Files
- Clone: /workspace/work/chatbugs4t (branch chat-bughunt-4-teams).
- Harness: integration_test/chat_bughunt4_teams_test.dart. Capture script: tools/chatbug4t_capture.sh. Workflow: .github/workflows/chat-bughunt4-teams-emu.yml (push on this branch only, own concurrency group, job timeout 140 min, emulator step 110 min, drive 100 min, test 95 min, harness budget 80 min).
  - The harness turns "Let it take action" off and blocks app/phone/browser tools for members.
  - It auto-answers "Not now" to any waiting approval or on-screen sheet after 20 s.
  - It wraps `TeamRun.llm` and `runTool` to count calls per bot and to inject a tool failure.
  - Background test: HOME, then 60 s, then `am start`.
- Live probe: /workspace/work/chatbugs4/teams_live/ (floor.py, plan.py, floor_results.json, plan_results.json).
