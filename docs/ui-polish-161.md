# UI polish v1.13.94+161 (owner, 2026-10-24)

1. **One card per page build.** Root cause of the two previews: `PageBuildCard` flipped to "Page built / Open page"
   as soon as its first `write_file` returned (appends, fix rounds and the SiteGate check were still running), and the
   final reply's ```` ```file ```` card then drew a second, iframe `PageCard`. A rewrite in a fix round also made a second
   build card, and a reply held during the finish check carried its page card early. Now `PageBuildPlan`
   (lib/widgets/page_cards.dart) plans each turn: the first write of a page owns its card, later writes/appends feed it;
   the card is "done" only when the turn's task has finished; `hidePageCards` hides page previews while the task runs
   and drops the reply card of any page that has a build card. Done card: hold for Open page / Publish / Share.
2. **Soft top edge.** `ChatEdgeFade` (lib/widgets/chat/edge_fade.dart): one gradient `ShaderMask` over the list, clear
   under the status bar, full strength just below the floating controls. Main, bots and team chats.
3. **Bots workspace header.** `WorkspaceHeader` (bots_workspace.dart): frosted band (one blur) with the rail toggle, the
   active bot/team face in its status ring + name, Call and "+"; height = `chatTopInset`; swaps with one cross-fade.
4. **Hark-style long answers.** `longReplySplit` (chat_logic.dart): a long answer with 2+ headings renders as a short
   lead in the bubble plus a `SummaryCard` (serif title, faded preview, tap opens the reader). Headings get air above.
5. **Streaming fades in.** `revealTarget` lets out whole words in small batches (`revealEvery`); `FadeAppend`
   (lib/widgets/chat/fade_append.dart) lays the grown text over the old and fades only the new words in. Reduced motion:
   instant.
6. **Quiet agent.** Prompt: `PromptQuiet` (agent_prompt.dart) – no narration, plans or tool talk unless asked; `say` only
   for mid-task answers or blockers. UI: narration lines, the checklist and the step list under the status line are
   hidden unless the turn's user message asks (`asksForSteps`, e.g. "show steps"); a reply held during the finish check
   is hidden while the task runs. Approvals unchanged; team posts unchanged.
7. **Floating frosted composer.** `FloatingChatFrame` puts the footer over the chat and hands its measured height to the
   list (`ChatFooterInset`) so the newest message rests above it. "+", the field and the mic/send are separate
   `FrostedSurface`s (one blur each). Bottom edge fades like the top. Team composer field is frosted too.
8. **Rail.** Same sizes; rounded open-side corners + faint shadow (`railEdge`, mirrored in RTL); the small "+" under the
   heads became the Telesia mark ("Back to Telesia") that returns to the main chat. "New bot" and "Bot store" unchanged.

Tests: test/ui_polish_161_test.dart, test/bots_workspace_test.dart (header/rail/composer group), test/chat_feel_test.dart.
