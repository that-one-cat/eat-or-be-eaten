# data - data-driven content

Species, size bands, mutations, abilities, food and maps are data (JSON), not code. `scripts/sim/content_db.gd` (`ContentDB`) loads and validates everything here; adding a species, food type or mutation must not require touching sim logic (hard rule 8, keeps mods possible). `game/data/` beats any doc for a number.

**Schemas** (field meaning, bounds, defaults; no tuned numbers) live in `docs/data/`. **Numbers** live in the JSON files themselves; generated tables: `docs/generated/NUMBERS.md` (T0.7).

| Folder / file | What | Schema |
|---|---|---|
| `rules/core.json` | global rules: eat, bite, hunger, death, NPC, tiers, schools, presence, feedback (append keys, never reorder) | [docs/data/rules.md](../../docs/data/rules.md) |
| `size_bands/size_bands.json` | 4 size bands: length, XP thresholds, swim, bite power, camera | [docs/data/size_bands.md](../../docs/data/size_bands.md) |
| `species/<id>.json` | creature species: temperament, tier, length, HP, XP, behaviour, `inflate`, `boss` | [docs/data/species.md](../../docs/data/species.md) |
| `abilities/<id>.json` | boost, Bite-Dash, Sonar | [docs/data/abilities.md](../../docs/data/abilities.md) |
| `mutations/mutations.json` | mutation tree nodes and effect keys | [docs/data/mutations.md](../../docs/data/mutations.md) |
| `food/<id>.json` | eggs, snails, edible decor (food types) | [docs/data/food.md](../../docs/data/food.md) |
| `maps/<id>.json` | map: zones, seabed, obstacles, hiding volumes, spawners (+ packs), schools | [docs/data/maps.md](../../docs/data/maps.md) |
| `maps/<id>.json` `plankton`, `krill` | plankton density field, krill clouds | [docs/data/plankton-krill.md](../../docs/data/plankton-krill.md) |
| `maps/<id>_dressing.json`, `maps/<id>_proxies.json` (generated) | map dressing (presentation + bake input), baked collision proxies | [docs/data/dressing.md](../../docs/data/dressing.md) |
| `maps/<id>_food.json` (generated) | baked food sites | [docs/data/food.md](../../docs/data/food.md) |
| `controls/modes.json` | selectable control modes (T1.4): classic / smoothed / assisted presets (input smoothing, aim assist and lunge strengths) | [docs/data/controls.md](../../docs/data/controls.md) |
| `env/pieces.json` (generated) | environment piece index (bounds, flags) | [docs/data/env.md](../../docs/data/env.md) |

**Generated files** are written only by their tool (`tools/dressing/reef_layout.gd`, `bake_proxies.gd`, `bake_food.gd`); re-bake order and invariants: [docs/systems/dressing-collision.md](../../docs/systems/dressing-collision.md). Tests fail on stale bakes.

Old section names of this file, now in `docs/data/`: "S4 keys" -> `rules.md` (`npc_scale`, `tiers`, `schools`, `quality`), `species.md` (`schooling`, `xp_band_mult`), `maps.md` (`schools`, zones), `plankton-krill.md`; "Plankton patchiness", "Krill" -> `plankton-krill.md` (krill look and tuning notes -> `docs/systems/food-krill.md`); "S5 keys" -> `dressing.md`, `env.md`; "Rock collision keys" -> `maps.md` (`obb`), `dressing.md`; "S6 keys", "S7 keys" -> `mutations.md`, `abilities.md`, `species.md` (`boss`), `rules.md` (`spawn`); "F1 keys" -> `rules.md` (player bite feel); "Fish groups keys" -> `maps.md` (`spawners[].group`); "Food keys" -> `food.md`.

## God tools data (T1.1 keys / T1.2 places; keys are read by `scripts/ui/typed_words.gd`, places by `ContentDB._check_places` + `GodSimCommands`, not by the sim)

- `god/typed_words.json` (one file; `TypedWords.load_file()`; invalid records are skipped and reported as `<path>: words[i]...` errors, a missing file means no words and no keys; `core.json` is not involved):
  - `words`: `[{id, word, kind}]`. `id` snake_case, unique; `word` lowercase `a-z`, 3-16 letters, unique; `kind` `"dev"` (the dev tools, only reachable in debug / test builds, `GodBuild.allowed()`) or `"cheat"` (reserved for the player-facing cheat words of T7.2, stays in release). Shipped: `{id: god, word: eatgod, kind: dev}`. Typing the word while a run exists unlocks the session (in memory only); matching is by typed characters and by physical key letters, so a Russian layout works (`TypedWordMatcher`, 1.5 s of silence resets).
  - `menu_keys`, `console_keys`: `{physical: [key names], keycode: [key names], unicode: [integers]}`, every list optional. A key press matches when ANY list hits; echo, releases and ctrl / alt / meta combos never match, Shift is allowed. Key names are Godot key strings (`OS.find_keycode_from_string`: `F1`, `QuoteLeft`, `AsciiTilde`); `physical` is the layout-independent position, `keycode` the logical key, `unicode` the typed character. Shipped: `menu_keys.physical` F1, F4 and M (fallbacks: F1 is the brightness key on Mac laptops, F-keys need Fn on many Windows laptops; M works only after the `eatgod` unlock and never while a text field has focus); `console_keys` physical QuoteLeft, keycode QuoteLeft and AsciiTilde, unicode 96, 126, 1105, 1025 (the Russian layout types `yo` on that key).
- `god/tuning.json` (T1.3 tuning lab registry, `{"entries": [row]}`; loaded and validated by `TuningOverrides.create`, not by `ContentDB`): one row per slider, `{id, target (rules|band), path, label, group, min, max, step}` (+ optional `band`). A new tunable key is a new row, no code. Schema, presets (`user://tuning`, `reports/tuning`) and the `state_hash` rule: [docs/data/god-tuning.md](../../docs/data/god-tuning.md).
- `maps/<id>.json` `places` (optional array, God tools only; the sim ignores it): named teleport points `{id (unique snake_case), name (optional display text), pos: [x, y, z]}`, `pos` inside the map box (`|x|, |z| <= size_m / 2`, `-depth_m <= y <= 0`; validated by `ContentDB._check_places`). Pick free water 3-6 m off the pieces: `teleport` resolves the point through the sim collision anyway. reef.json: `spawn_0..2` (= `player_spawns`), `shallows`, `kelp`, `arches`, `cave`, `boat`, `cliff`, `abyss`, `boss` (the arena near the abyss; the console `boss tp` uses the live boss instead). `reef_layout.gd` does not rewrite it.
