# DSL verb reference — the flat `VBlank.build` API

The verbs a `VBlank.game "NAME" do … end` block calls (mixed into `Builder` from
`lib/vblank/builder/*.rb`). **This file is the index**: a line per verb, enough to find it.
Each verb's options, friendly errors, cost and worked example are in the group file its section
names, under `.claude/dsl/`. **Read that file before using, changing or documenting a verb**, and
grep `.claude/dsl/` for an option or handle method not named here.

A drift test (`test/all/vblank/test_dsl_reference.rb`) fails if a builder verb is missing from
this index or from its section's group file. A new verb gets a few words here and its whole
story in the group file.

Coordinates are pixels from the top left of a 240×160 screen. A `:symbol` names a variable, an
Integer is a literal, a `Value` (from `var`) is an expression. Handles (`Value`, `List`,
`Sprite`, `Condition`…) are `VBlank::DSL::*` in `lib/vblank/dsl/`.

**Mistakes that raise nothing** (each in full in its group file):

- A fraction divide that saturates, then has something added, wraps negative; floor the divisor (`d.clamp(NEAR, FAR)`). (variables)
- A `:byte`/`:half` slot keeps the low bits: 200 in a `:byte` reads -56. (lists)
- `pressed` inside `once_a_frame` fires once per caught-up frame; test presses in the loop. (control-flow)
- `pixelate_size == 16` and `iris_shut?` hold two frames running; keep a flag of your own. (drawing)
- A picture painted once on a tear-free screen flickers between pages (one page on the Color); use `keep_showing`. (drawing)

## Build / screen — `.claude/dsl/screen.md`

- `VBlank.game "NAME", consoles: %i[gba]` — the game and the consoles it is for (`%i[gba gbc]` for the Color too); `vblank build` makes a cartridge for each. `stack_room:`; `sprite_piece_size: { gbc: [8, 16] }` (taller sprite pieces); `menu: false` (no menu in a computer's window); `players: 4` (input).
- `screen :bitmap` / `:tiled` / `:rotozoom` (`tear_free:`, `colors:`, `late:`, `pace:`, `backdrop:`) — the display, per scene; `:bitmap` by default. `backdrop: :list` (`backdrop_place:`) — a backdrop that fades with a list.
- `screen_width` / `screen_height` — the screen's size, to lay a game out from.
- `border` — round a Color game on the Advance (`:color_screen`).
- `setting :floors, 60` — a value handed to one build (`settings:`, `--set`).
- `built_for_computer?` — true in a computer's build, false in a cartridge's.
- `wait_vblank`, `halt`, `debug_halt` (cut a ROM to bisect).

## Drawing — `.claude/dsl/drawing.md`

- `pixel`, `fill_rect` / `dma_fill_rect` (fixed place, even width), `draw_rect_at` (run-time, any width), `clear_screen`.
- `draw_column_at :pic, slice:, x:, top:, height:` — a picture column stretched to a run-time height.
- `inside x, y, w, h do … end` — clip to a rectangle. `camera x, y`; `camera_follows hero, across: world` (tiled).
- `fade :black, 50`, `tint :red, 30`; over time `fade_out` / `fade_in` / `flash_screen`; `fade_level` → 0..100.
- `pixelate 8`; over time `pixelate_out` / `pixelate_in`; `pixelate_size`.
- `spotlight at:, radius:, dark:` → a light (tiled, one per game); `iris_out` / `iris_in` / `iris_shut?`.
- `pulse sprite, to: 1.3`; `shake_screen intensity:, frames:`.
- `keep_showing :name do … end` — paint only on a change, right on a two-page screen.
- `grid :name, cols:, rows:, cell:, over:` → `Grid`.

## Images & sprites — `.claude/dsl/sprites.md`

- `image :name, "#" => :red do … end` — ASCII art, `data:`, `from: "file.png"`, or `from: list` painted at run time.
- `sprite :name, at: [x, y]` → `Sprite` (software on bitmap, hardware on tiled): moving, facing, frames, hitbox, turning. `over_picture: true` on bitmap: the console's own, in front of all the picture.
- `blit :name, x, y` — a picture at a run-time place, clipped.
- `mirror(:pic)` / `upside_down(:pic)` — turned.
- `colors :hurt, [...]` + `draw_with`; `recolor :slot, :goblin` at run time; `colors_in_use` (a hint).
- `color_walk :city, from: :black` → the lists of a console game's fade, for `draw_with` or `recolor` with `showing:`.
- `picture_groups :rooms, {…}` + `show` — sprite pictures by room, so only the rooms up take sprite memory.
- `sprite_tiles :ball, count: 32, colors:` → `SpriteTileSet`; `image :spin0, tiles_from: :ball, pieces: [[dx, dy, tile], …]` — poses from one tile set; `set.copy_from :pic, at:, count:, to:` loads tiles.
- `hide_sprites` — no sprite on the next frame drawn (tiled screens).
- `rgb r, g, b` (0–31), `rgb8` (0–255), `color value` — a 15-bit colour.

## Tiled backgrounds — `.claude/dsl/backgrounds.md`

- `tiles :name, "#" => :brick, solid: ["#"]` — a tileset; `from:` a sheet, or a list painted at run time.
- `canvas :board, width:, height:, colors:` — a picture drawn into with words.
- `tile_pictures :water, colors:, tiles: { deep: %i[a b c] }` → `TilePictureGroup`: tiles taking turns through pictures in the cartridge; `group[:deep]` in a tileset, `group.show n`.
- `background :name, tiles:, map:` → `Background`: set a tile, switch maps, recolour, scroll, bend rows, turn; four per screen; `above_row:` (rows above one), `held:` (cells as one).
- `bg.show_only_inside x, y, w, h` / `bg.show_everywhere` — a background drawn only inside a box the game moves and sizes.
- `status_bar :name, tiles:, map:, top:` → `StatusBar`: fixed from a row down, over a scrolling field; `move_to`, `top`, `set_tile`.

## Layers — `.claude/dsl/layers.md`

- `layers :sky, :world, :ui` — the stack, back to front (`[:a, :b]` inside it: two layers sharing one level); `layer :name do … end` puts what it declares at that depth.
- `hero.put_in_layer`, `guards.put_in_layer` (a pool); `draw_in_order hero, guards` — sprites re-ordered each frame, lower on screen in front; `take_turns: true` (or `:last`) — the named order and its reverse, a frame each.

## Places — `.claude/dsl/places.md`

- `place :cube do … end`, `viewer :eye, at:`, `draw_place :cube, seen_by:`, `screen_spot` — 3D faces, lit by `shading :dim, colors:, levels:`.

## Collision — `.claude/dsl/collision.md`

- `box x, y, w, h`; `off_screen?` and edge tests; `a.overlaps?(b)` (per pixel unless `hitbox:`); `blocked_by(background)`.

## Text & numbers — `.claude/dsl/text.md`

- `draw_text "HI", x, y, color`, `draw_number :var, x, y, color, digits:`; `:left`/`:center`/`:right` for a column.
- `text_width`, `text_height`; `font :name do glyph … end`. On `screen :tiled` text is sprite glyphs.

## Variables & math — `.claude/dsl/variables.md`

- `hp = 10` — a game variable, if game code changes it. `var :name, init` → `Value` (`width: :byte` or `:half` to keep it narrow); `var :mode, :title` holds a name, and `call mode` runs it.
- `save_var :name, default`; `save_data :file do keep … end` → save records; `saves_keep_everything except:`.
- `part :play` (from here on, or a block) + `start_over :play` — a new game: that part's variables, lists and pools back as declared, on one pass; a scene's name works too.
- `x = 5`, `x += 1`, `x -= 1`, `flags |= 4`, `x = y` — change a variable.
- `negate!`/`flip!`, `abs!`, `negate_abs!`, `clamp!`, `approach!` — words of their own that change a variable.
- Without `!` nothing changes: on a Value (`abs`, `clamp`, `approach`, `flip`, `negate_abs`) a new number; flat (`set`, `add`, `sub`, `add_var`, `sub_var`, `copy`, `negate`) a friendly error.
- On a Value: `+ - * / %`, comparisons → `Condition`, `&&`/`||`, `if`/`else`, bits; a Float makes a fraction. `estimate:` only warns.

## Control flow — `.claude/dsl/control-flow.md`

- `if`, `unless`, `while`, `until`, `&&`, `||`, `!`, ternary — normal Ruby; a test the game makes becomes game code. `return`, `break`, `next` under one are refused.
- `game_loop do … end` — once a frame. `repeat(n) { |i| … }`; `every(n)`, `after(n)`; `once_a_frame`.
- `each_pass(:name) { |job| … }` → `PassJob`; `timer :name, per_second:` → `Timer`.
- `frames_since_power_on` → a `Value`, real frames shown since power-on, setting up included.
- Low-level `if_eq` `if_ne` `if_gt` `if_lt` `if_ge` `if_le` (`if_gte`, `if_lte`).

## The date and time — `.claude/dsl/clock.md`

- `clock` → `Clock` (`hour` … `weekday`); ask `present?` and `set?` first; `set_to(year:, month:, day:, hour:, minute:)` sets it.

## Scenes & funcs — `.claude/dsl/scenes.md`

- `func(:name) { … }` + `call :name` (or `call [:a, :b], number: n`); `on_chip: true` runs it on a Super FX cartridge's chip; `dump_func :name` disassembles one.
- `scene(:name) { … }` + `case_var(:state) do when_val 0, :title end` — game states; a scene owns what it draws. `measure_holding: %i[up b]` (or a tape): what the measured build presses in it.

## Input — `.claude/dsl/input.md`

- `held(:left)`, `pressed(:start)` (`:any`); low-level `if_held`, `if_pressed`. Buttons `a b select start right left up down r l`, and `x y` on the Super Nintendo.
- `held(:left, player: 3)` (1 to 16, or `:any`); `players: 1..4` on `VBlank.game`; `most_players`; `drawing_for_local_player { |me| … }` → draw for this player alone, `mark over: hero, with: :arrow` there; `players_connected` → how many now. `vblank run --host` / `--join`: a match.
- `rumble frames: 12, pattern: "##..##.."` — shake a cartridge with a motor (the Color's).

## Menus — `.claude/dsl/menus.md`

- `menu :name, at: [x, y] do |m| m.item("NEW GAME") { … } end` → `Menu`.

## Lists — `.claude/dsl/lists.md`

- `list :name, capacity: N` → `List`, an array the game changes (`holds:`, `width:`, `full_of:`).

## Tables — `.claude/dsl/tables.md`

- `table :name, array` → `Table`, read-only ROM data read by a run-time index.

## Pools — `.claude/dsl/pools.md`

- `pool :name, field: default, capacity: N` → `Pool`, many of one thing (`spawn`, `each`, `remove`, `pool.func`).

## Randomness — `.claude/dsl/randomness.md`

- `seed n`, `randomize`, `roll :var, 1..6`, `rand(1..6)`, `chance(25)`, `random_numbers`.

## Sound & music — `.claude/dsl/sound.md`

- `enable_sound`; `define_sound :name, …` + `beep :name`; `noise`, `wave` / `stop_wave`.
- `song(:name) { … }` + `play_song`, `stop_music`; `hold_music` / `release_music`; `music_volume`, `fade_music_out` / `fade_music_in`.
- `sample :name, from: "clip.wav"` → `Sample`, recorded sound, mixed.
- `songs :music, [score, …]`, `sound_effects :sfx, {…}` — music and effects as `Audio::Score` data.
- `instrument :piano, from:, note:` → `Instrument`.

## Measuring a finished game — `.claude/dsl/measuring.md`

- `rom.profile` / `vblank profile game.rb` — where the frames went; `tape:, frames: 9..12` reads each (not GBA); `rom.sprite_memory`.
- `Diagnostics::Film.make "door.mp4", sides:, parts:, keys:` — an MP4 of 1 or 2 cartridges; `FilmTasks`: rake film.

## Playing a finished game with nobody at the controls — `.claude/dsl/playthroughs.md`

- `VBlank.playthrough "name" do … end` — scripted presses on a cartridge; `vblank compare`.
- `vblank run game.rb --script s.rb` / `--tape t.tape` — the one command that plays a game: a person without either, nobody with one; as Ruby unless `--on js|native|logic|interpreter`. No cartridge: `--write-mgba-script`, `--write-bk2` reach a console.
- `VBlank.bot` + `vblank bot FILE` — a script plays in a match.

## The Game Boy Advance — `.claude/dsl/game-boy-advance.md`

- `consoles: %i[gba]` — what every verb does on the Advance.

## The Game Boy Color — `.claude/dsl/game-boy-color.md`

- `consoles: %i[gba gbc]`, `vblank build --console gbc` — the game on a Color too; what every verb does there.

## The Super Nintendo — `.claude/dsl/super-nintendo.md`

- `consoles: %i[gba snes]`, `vblank build --console snes` — the game on a Super Nintendo too; what every verb does there.

## The Sega Genesis — `.claude/dsl/sega-genesis.md`

- `consoles: %i[gba genesis]`, `vblank build --console genesis` — the game on a Sega Genesis too; what every verb does there.

## Effects a game writes — `.claude/dsl/effects.md`

- `uses MyPack` — a module of the game's own verbs.

## Escape hatch — `.claude/dsl/escape-hatch.md`

- `entry do … end` — raw ARM instructions.
