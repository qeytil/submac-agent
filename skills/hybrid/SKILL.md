---
name: hybrid
description: Make an animated video where the characters are drawn in 2D and the world is a real 3D scene (a "2D-in-3D" or 2.5D look, like Paper Mario, Octopath Traveller or Don't Starve). Use whenever someone asks for "2D characters in a 3D world", a "2.5D animation", a drawn character moving through a modelled place, or to redo or extend one of these videos. Before building, asks for the story (who, where, what happens), the length, and whether to plan together first (with a design sheet of the characters); defaults are 30 seconds and straight to work. Delivered as one self-contained HTML file that plays with sound plus an MP4 rendered from the same code. Always use this skill instead of building 2D-in-3D animations ad hoc, because it holds the intake questions, the hand-drawn character rig, the 3D world kit, the compositing and lighting rules, the parallel MP4 renderer, and the review checks.
---

# Hybrid — 2D characters in a 3D world

Makes an animated video whose characters are hand-drawn in 2D and whose sets are real 3D geometry, lit and moved by a real three.js camera, as one self-contained HTML file that plays in a browser with sound, plus an MP4 rendered frame by frame from the same code.

Everything lives in this skill folder. `scripts/new_hybrid.sh` starts a project from `template/`, a working 10-second example in the default Storybook-ink look (a drawn kid walking through a modelled meadow). Below, `SK` is this skill folder and `P` is the video's project folder.

## 1. Ask before building

Never invent the story. Check the request for:

- **Story**: who it is about, where it happens, and what happens from start to end. A subject is required; if it is missing or vague, ask before writing any code.
- **Length**: how long the video should be.
- **Plan together or just get to work**: plan the video together first, or go straight to making it?

Ask only for what wasn't given, in one short message, and say the default for the rest: 30 seconds for length, and getting straight to work if there's no choice. Don't fill gaps in the story yourself and don't add requirements nobody asked for.

**Fixed defaults (don't ask):** 16:9 at 1920x1080, 24 fps, music and sound effects on.

**Storyboard before a long film.** For anything over about 60 seconds, write the beat list and the shot list first and show them before rendering, because a long render is expensive to redo.

## 2. Plan the video

- Write a short beat list: one line per beat, with rough times.
- Write a shot list: one line per shot with rough times, the framing (wide, medium, close), the camera move, and what the shot shows. Vary the framing and keep the camera roughly at character eye level so the drawn characters sit naturally in the 3D space.
- Decide the emotional turn: what the character wants or feels at the start and how it has changed by the end.

**If planning together was chosen**, get sign-off before building the scenes:

1. Post the beat list and the shot list.
2. Start the project (section 3), build just the main characters and any key props, and render a design sheet with `node render.mjs --design` (front, three-quarter and side of each item). The design sheet draws the 2D characters on a plain card, so proportions and palette can be checked before they are placed in a set.
3. Send the sheet and the lists together and wait for an answer. Change what's asked for and send a new sheet until it's approved. Only then build the shots.

**If getting straight to work was chosen** (or nothing was chosen), post the beat list for reference and keep building without waiting.

## 3. Start the project

- `P` is the folder the request names. Otherwise use a new subfolder named `<slug>-hybrid/` in the current working folder.
- Run `bash "$SK/scripts/new_hybrid.sh" "$P"`. It copies the template, installs the rendering library and esbuild, reuses an installed Playwright (installs one only if none works), and makes sure Python has numpy and scipy (in `~/.cache/hybrid-skill/venv` if the system Python lacks them). If it reports node or ffmpeg missing, pass on the `brew install` line it prints.
- Layout: `src/beats.json` (title, length, cue times), `src/story.js` (sets, characters, shots), `src/kit.js` (the 3D world kit; extend it, don't fork it), `src/kit2d.js` (the 2D character rig and the billboard compositor; extend it the same way), `src/assets/title.woff2` (title font, OFL), `audio/audio.py` + `audio/audiolib.py` (sound), `build.mjs`, `render.mjs`, and `build/` for outputs. Replace the example entirely.

## 4. Build

Read [references/technique.md](references/technique.md) before writing scene code. In short:

1. **Beats.** Write `src/beats.json`: `title`, `duration`, `fps`, and named `cues` for every moment that needs a sound or a cut. Picture and sound both read these times, so change timing here only.
2. **Sets (3D).** Build each location once as a `THREE.Scene` with the world kit: ground, sky gradient, a warm sun with shadows, and props (trees, rocks, buildings). Keep the palette tight; the 3D world is the quieter half.
3. **Characters (2D).** Make each character a factory in `src/kit2d.js`: a pose function of `t` (joints → tapered limbs, hair/cloth from strands) drawn to an offscreen canvas, uploaded each frame as a `CanvasTexture` on a camera-facing plane. Give each one a soft ground-shadow blob and a cel shadow that follows the scene's light direction, so it sits in the world.
4. **Animate on global time `t`** so things stay put across cuts. Nothing may depend on the previous frame, a clock or `Math.random`. Use `keys`, `seg`, `ease`, `onPath` and the pose functions.
5. **Shots.** List shots in order with `set`, `dur`, a `cam(local, p)` function and an optional `in` transition. Durations must add up to `duration`. Every shot names its set; several shots can share one set.
6. **Depth.** Let 3D props stand in front of and behind the drawn character so the plane reads as part of the place: put the character on a billboard with depth testing on, and place near props (a fence post, a rock) closer to the camera.
7. **Quick checks:** `node build.mjs`, then `node render.mjs --stills 1,4.5,9` (one time per shot). Look at `build/stills/sheet.jpg` and fix problems before the full render.

## 5. Sound

Edit `audio/audio.py`: music that suits the mood and sound effects on the cues from `beats.json`. `audiolib.py` has instruments, effects and ambience beds; add new sounds there when needed. Run `./py audio/audio.py build/audio.wav`. Add a voiceover only if one is asked for.

## 6. Render, preview and review

1. `node build.mjs` writes `build/<slug>.html` with the rendering library, font and sound inside.
2. **Preview as you go (important).** The request expects to see progress during the build. After each shot is drafted, render its key frames with `node render.mjs --stills <times>` and send `build/stills/sheet.jpg` in the chat with one line naming the shot. Fix what's wrong in that shot before starting the next. Never go silent through a long build.
3. `node render.mjs` renders with parallel headless Chromium workers, adds the sound at -16 LUFS, and writes `build/<slug>.mp4` plus `build/review/contact-*.jpg` (one tile per second). Use `--scale 0.5` for a fast draft, `--scale 2` for 4K, `--from`/`--to` for a section.
4. Review every contact sheet against the checklist in [references/technique.md](references/technique.md). Fix, rebuild and re-render until it passes.

## 7. Deliver

- Deliver the HTML (click or space to play with sound, arrow keys to step) and the MP4 from `P/build/`, with the length and one line on any choice that wasn't specified.
- When changes are asked for, move the previous cut to `P/v1/` (then `v2/`, ...) before re-rendering.
- Add new review lessons from feedback to the bottom of [references/technique.md](references/technique.md).
