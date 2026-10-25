# Design and output skills (v1.13.89+156)

Owner request 2026-10-24: the agent sent "unfinished ugly broken websites". Improve its knowledge, never hard-code a look,
and let the user choose.

## What was wrong
- Finish check only ran for builds with 3+ todo steps or 3+ file writes, so a one- or two-file site went out unchecked.
- `code_check` existed but sat in the code tool group and was never required for pages; nothing checked a page before the final reply.
- Inline ```page cards were never validated, so a long page that hit the per-reply length cap could land half written.
- The prompt carried a fixed style (2-3 colours plus an accent, system font pairing, soft shadows, rounded corners, hero + CTA,
  "premium look") so every site looked alike and ignored the user's own taste.
- No design knowledge to read: no process (brief, choices, plan, build, check, deliver), no fundamentals.

## What changed
- `lib/services/design_skills.dart`: seven built-in skills in the library format (offline, found by skill_search and the
  "Skills that may fit" hint): web-design, ui-design, design-review, rich-replies, reply-timing, documents-and-slides,
  charts-and-data. Knowledge and process only; the user's choices win; 2-3 directions offered only when they gave none.
  `DesignSkills.noteFor` points website and UI requests at the right skill.
- `lib/services/site_check.dart`: static page check (complete file, closed tags/scripts/styles, missing local files incl.
  srcset and CSS url(), in-page links, title, viewport, lorem ipsum, "rest of code here" gaps, CSS braces, wide fixed widths;
  notes for user spots, alt text, external pictures, image sizes). `code_check` uses it for HTML and CSS too.
- Engine guard (`SiteGate`, agent_runner): any task that wrote a page, style or script gets its site checked before the
  final reply. Problems go back to the model (the draft is not shown) up to 2 rounds; then the final reply must say what still
  fails. A broken inline ```page card is sent back once.
- Prompt: fixed design rules replaced by `DesignSkills.promptRule` and `mediaRule`; reply form and timing lines added.
- Tests: test/design_skills_test.dart (skills listed and readable, no hex/rgb/font names in skill text, hint cases, page
  check cases, folder check on disk, gate decisions).

No server changes.
