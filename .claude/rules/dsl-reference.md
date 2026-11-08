# DSL map — where each part of `VBlank.game` is told

A game is a `VBlank.game "NAME" do … end` block: **plain Ruby** (`.claude/dsl/plain-ruby.md`)
calling VBlank's verbs. This map names the page for each part. **Open the page before using,
changing or documenting a verb there**: its **On this page** list has a line per verb, and the
entries after it tell each in full, with its options, friendly errors, cost and worked example.
For an option or a handle's method, grep `.claude/dsl/`.

A drift test (`test/all/vblank/test_dsl_reference.rb`) fails if a verb is on no page's list, if a
verb on a list is not told on that page, or if a page is missing here. A new verb gets a line on
its page's list and its entry below it.

Coordinates are pixels from the top left of a 240×160 screen. Where a verb takes a number, a
number the game keeps works too.

**Mistakes that raise nothing** (each told on its page):

- A fraction divide that saturates, then has something added, wraps negative; floor the divisor (`d.clamp(NEAR, FAR)`). (variables)
- A `:byte`/`:half` slot keeps the low bits: 200 in a `:byte` reads -56. (lists)
- `pressed` inside `once_a_frame` fires once per caught-up frame; test presses in the loop. (control-flow)
- `pixelate_size == 16` and `iris_shut?` hold two frames running; keep a flag of your own. (drawing)
- A picture painted once on a tear-free screen flickers between pages (one page on the Color); use `keep_showing`. (drawing)

## The pages, under `.claude/dsl/`

**Writing a game**

- `plain-ruby.md` — game code: variables, tests, loops, what is refused, what builds and means something else.
- `variables.md` — numbers and fractions, arithmetic and bits, saves (`save_var`, `save_data`), `part` and `start_over`.
- `control-flow.md` — `game_loop`, `repeat`, `every`/`after`, `once_a_frame`, `each_pass`, timers.
- `scenes.md` — `func` and `call`, `scene`, game states.
- `input.md` — buttons, more players, matches, rumble.
- `randomness.md` — `rand`, `roll`, `chance`, seeds.
- `effects.md` — `uses`: verbs of the game's own.

**The screen**

- `screen.md` — `VBlank.game` options, `screen` kinds, `setting`, `built_for?`.
- `drawing.md` — painting, `inside`, `camera`, fades, tints, pixelation, lights, `keep_showing`.
- `sprites.md` — `image`, `sprite`, `blit`, colours and recolouring, sprite tiles.
- `backgrounds.md` — `tiles`, `canvas`, `background`, `status_bar`.
- `layers.md` — the stack, and the order sprites are drawn in.
- `places.md` — 3D: `place`, `viewer`, `draw_place`, shading.
- `collision.md` — `box`, `overlaps?`, `blocked_by`.
- `text.md` — `draw_text`, `draw_number`, `font`.
- `menus.md` — `menu`.

**The game's data**

- `lists.md`, `tables.md`, `pools.md` — a list the game changes, a table in the cartridge, many of one thing.
- `original.md` — `data_pack`: data read from the player's own copy of an original.
- `sound.md` — sounds, songs, samples, instruments.
- `clock.md` — the date and time.

**A finished game**

- `measuring.md` — `rom.profile`, films.
- `playthroughs.md` — playing with nobody at the controls: `playthrough`, `vblank run --script`, bots.

**Each console**: what every verb does there, and what it refuses.

- `game-boy-advance.md`, `game-boy-color.md`, `super-nintendo.md`, `sega-genesis.md`, `playstation.md`.
- `escape-hatch.md` — `entry`: raw ARM instructions.
