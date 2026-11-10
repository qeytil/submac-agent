# Skills adapted from open-source collections

`build.py` holds skills rewritten for Telesia from permissively licensed skill packs (obra/superpowers, MIT; anthropics/skills, only the folders that ship an Apache-2.0 LICENSE.txt; alirezarezvani/claude-skills, MIT). Every skill keeps a credit line in its body and `source`, `license`, `author` fields in its file; the index line carries `license`. Licences and versions are listed in `docs/third-party.md`.

1. `python3 build.py` writes `index_add.json` and `s/<id>.json`.
2. `python3 merge.py` downloads the live `skills/index.json`, adds or replaces these ids, bumps `v`, sets `count`, and writes `index.json`.
3. Upload `s/*.json` to `skills/s/` and `index.json` to `skills/index.json` in the public `skills` bucket (Supabase project moeemacbvsueekuvfjbo, storage API with the service key, `x-upsert: true`). The app picks the new index up within a day (or on pull to refresh).

Not imported on purpose: anthropics/skills document skills (docx, pdf, pptx, xlsx: source-available, not open source) and any folder without its own licence file (e.g. doc-coauthoring); skills that need a desktop toolchain (Playwright, Node bundlers); skills that duplicate the existing library.
