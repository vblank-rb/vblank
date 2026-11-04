# The Super Nintendo — what every verb does there

A game built for the Super Nintendo too (`VBlank.game "NAME", consoles: %i[gba snes]`, then
`vblank build`, which makes a cartridge for each console, or `--console snes` for the Super
Nintendo's alone) is the same game on another machine: a 256×224 screen (`screen_width`,
`screen_height`), 128 sprites (34 pieces on a row of the screen), backgrounds of tiles, and
lists of sixteen colours. Every verb has one of two answers there, decided once in
`Console::SNESAnswers`:

- **works** — the same game, played the same way. The Super Nintendo lowering's run of
  `rake test:all` holds the cartridge to the interpreter after every pass.
- **refused** — the build stops before anything is made, naming the hardware the Super
  Nintendo lacks and what to use instead. Nothing is shown differently.

This file is `Console::SNESAnswers.reference` written out (`ruby tools/console_answers.rb`),
and a test fails when the two differ. The Advance's answers are in
`.claude/dsl/game-boy-advance.md`.

- `screen` — works: `screen :tiled` and `screen :bitmap` work. A Super Nintendo has no painted screen, so a painted (bitmap) screen is made of tiles internally. `tear_free: true` keeps one picture, because the picture is copied to the console whole before it shows. `screen :rotozoom` is refused: the build does not use the one layer a Super Nintendo can turn.
- `setting` — works: the same as on the Advance.
- `built_for_computer?` — works: false on a cartridge.
- `screen_width` — works: 256 on a Super Nintendo.
- `screen_height` — works: 224 on a Super Nintendo.
- `border` — works: it does nothing on a Super Nintendo, which shows the game's screen whole.
- `wait_vblank` — works: in a game loop, the sprites and scroll of a pass show on the frame after the wait. If a game writes the wait in a scene or an `if`, they show a frame later than that.
- `halt` — works: the same as on the Advance.
- `debug_halt` — works: the game stops there, as `halt` does; the cartridge is not cut short.
- `game_loop` — works: the same as on the Advance.
- `once_a_frame` — works: the same as on the Advance.
- `frames_since_power_on` — works: the same as on the Advance.
- `each_pass` — works: the same as on the Advance.
- `every` — works: the same as on the Advance.
- `after` — works: the same as on the Advance.
- `repeat` — works: the same as on the Advance.
- `timer` — works: a timer ticks by the frame, as the interpreter counts it.
- `pixel` — works: the same as on the Advance.
- `fill_rect` — works: the same as on the Advance.
- `dma_fill_rect` — works: the same as on the Advance.
- `draw_rect_at` — works: the same as on the Advance.
- `draw_column_at` — works: the same as on the Advance.
- `clear_screen` — works: the same as on the Advance.
- `inside` — works: the same as on the Advance.
- `grid` — works: the same as on the Advance.
- `camera` — works: a painted screen is the size of the screen, so moving the view over it shows black past the picture's edge. To move over a bigger world, use a tiled background and `scroll_to`.
- `keep_showing` — works: a painted screen is always shown whole, so a picture kept showing never tears.
- `fade` — works: `fade` to black is the display's own brightness, in sixteen levels, and costs no time. `tint`, and `fade` to white, change the colours the console shows, not the picture. `inside:`, `outside:` and `under:` are refused: the build cannot fade part of the screen on a Super Nintendo.
- `tint` — works: the same as on the Advance.
- `fade_in` — works: the same as on the Advance.
- `fade_out` — works: the same as on the Advance.
- `flash_screen` — works: the same as on the Advance.
- `fade_level` — works: the same as on the Advance.
- `shake_screen` — works: the same as on the Advance.
- `pixelate` — **refused**: a Super Nintendo's mosaic shows the backgrounds in blocks but not the sprites. Use `fade_out` and `fade_in` to go from one screen to the next.
- `pixelate_in` — **refused**: see `pixelate`.
- `pixelate_out` — **refused**: see `pixelate`.
- `pixelate_size` — works: the same as on the Advance.
- `spotlight` — **refused**: a light darkens everything outside a circle by degrees, and a Super Nintendo's colour maths only adds, subtracts or halves. Use `fade` to darken the whole screen.
- `iris_in` — **refused**: the iris is the game's light closing (see `spotlight`). Use `fade_out` and `fade_in`.
- `iris_out` — **refused**: see `iris_in`.
- `iris_shut?` — **refused**: see `iris_in`.
- `pulse` — **refused**: a Super Nintendo cannot resize a sprite. Draw the sprite's sizes as poses and `face` them in turn.
- `camera_follows` — works: the same as on the Advance.
- `image` — works: a sprite's picture holds fifteen colours and see-through, and a background's tiles sixteen colours, from lists of sixteen.
- `color` — works: the same as on the Advance.
- `rgb` — works: the same as on the Advance.
- `rgb8` — works: the same as on the Advance.
- `colors` — works: a list of colours holds sixteen places on a Super Nintendo, the first see-through on a sprite. The console holds eight lists for sprites and eight for backgrounds on each screen. If the sprites do not fit the 512 tiles of sprite memory with a copy of their pictures for each list they wear with `draw_with`, the build keeps one set of pictures for all those lists.
- `recolor` — works: a list told to hold other colours keeps a palette to itself, so a game can change eight lists of backgrounds on each screen and eight of sprites.
- `color_walk` — works: the same as on the Advance.
- `colors_in_use` — works: the same as on the Advance.
- `mirror` — works: the same as on the Advance.
- `upside_down` — works: the same as on the Advance.
- `blit` — works: the same as on the Advance.
- `sprite` — works: a sprite is made of the console's pieces, 128 pieces at once and 34 pieces of 8×8 on any one row of the screen. A square of 16×16 in a picture is one piece, so a screen of big sprites fits. A picture given with `pieces:` is those pieces, one each, 16×16 pieces too, wherever they sit. Past 128 pieces, a sprite is not drawn and no error shows as the game runs. The build warns when the sprites one screen declares pass 128, and when it gives up the squares of 16×16 to fit the tiles. It does not count pools or letters of text. `scale`, `face_angle` and `turn` are refused: a Super Nintendo cannot turn or resize a sprite. Draw the turns as poses. A sprite with `over_picture: true` on a painted screen is not made yet: the build refuses it and says so. That painted screen uses nearly all the video memory and all 256 colours, and the sprites need some of both.
- `draw_in_order` — works: the same as on the Advance.
- `hide_sprites` — works: on the next frame, no sprite shows. On the frame after, every sprite shows where it is.
- `picture_groups` — works: the same as on the Advance.
- `pool` — works: its sprites count towards the 128.
- `box` — works: the same as on the Advance.
- `tiles` — works: tiles of sixteen colours each.
- `background` — works: two backgrounds at a time, scrolled and changed as on the Advance. `above_row:` keeps a background to the rows above that row, and takes no processor time as the screen is drawn. A game with it cannot have a status bar yet. `show_only_inside` is refused: this build does not make it yet. `rotate` and `scale` are refused: the build does not use the one layer a Super Nintendo can turn. A background can be drawn from 16×16 tiles, which the console draws itself, as well as 8×8. A cell of its map is then one 16×16 tile. A `scroll_each_row` block runs for all 224 rows each pass, so a block that reads a table can take more than a frame. If a block only compares the row with numbers, as `row >= 68 ? a : b` does, it runs once for each band of rows, and the game keeps up. A scene can bend a background of its own. The rows go straight when that scene leaves. A block with no statement and no `?` takes none of the frame while that scene is away. Any other block runs as usual, because it can change a number. `held: true` changes nothing: a Super Nintendo writes its video memory only between frames, so the cells a pass changes with `set_tile` already show together.
- `status_bar` — works: the bar is one of the two backgrounds. `set_tile` with `now: true` is refused: a Super Nintendo writes its video memory only between frames, so a change shows on the frame after the pass.
- `canvas` — works: the same as on the Advance.
- `tile_pictures` — works: pictures of 8×8 or 16×16, each change one copy from the cartridge, however many cells show the tile. A group must fit one bank of the cartridge.
- `sprite_tiles` — works: a Super Nintendo can draw poses from tiles the game loads, but this build does not make it yet. A game with a pose drawn from sprite tiles is refused, and the build says so (see Not made yet).
- `layers` — works: a layer holds a background or sprites. A layer of backgrounds can be half see-through, over a background that covers the whole screen: `transparency:` from 50 to 56, or `shows: 50, shows_behind: 50`. It can also be added to what is behind it: `shows: 100, shows_behind: 100`, and there `shows_behind:` can be a number the game changes between 100 and 0, which turns the layer solid in one frame. A number between shows as 100. A Super Nintendo mixes one layer into another only by half or by adding, never by the Advance's sixteen steps, so other amounts are refused.
- `layer` — works: see `layers`.
- `draw_text` — works: painted on a painted screen; on a tiled one each letter is a sprite, so they count towards the 128, 34 pieces to a row.
- `draw_number` — works: see `draw_text`.
- `font` — works: the same as on the Advance.
- `text_width` — works: the same as on the Advance.
- `text_height` — works: the same as on the Advance.
- `menu` — works: see `draw_text` for what its rows are made of.
- `var` — works: a variable is the same 32-bit whole number as on the Advance.
- `save_var` — works: kept in 32K of battery-backed RAM on the cartridge. A cartridge with a Super FX chip cannot keep a save yet.
- `save_data` — works: kept in 32K of battery-backed RAM on the cartridge. A cartridge with a Super FX chip cannot keep a save yet.
- `part` — works: the same as on the Advance.
- `start_over` — works: the same as on the Advance.
- `clock` — **refused**: a Super Nintendo cartridge built here has no clock chip. Ask the player for the time on a screen of the game's own, if the game needs it.
- `saves_keep_everything` — works: the same as on the Advance.
- `set` — works: the same as on the Advance.
- `add` — works: the same as on the Advance.
- `add_var` — works: the same as on the Advance.
- `sub` — works: the same as on the Advance.
- `sub_var` — works: the same as on the Advance.
- `copy` — works: the same as on the Advance.
- `negate` — works: the same as on the Advance.
- `negate!` — works: the same as on the Advance.
- `flip` — works: the same as on the Advance.
- `flip!` — works: the same as on the Advance.
- `abs` — works: the same as on the Advance.
- `abs!` — works: the same as on the Advance.
- `negate_abs` — works: the same as on the Advance.
- `negate_abs!` — works: the same as on the Advance.
- `clamp` — works: the same as on the Advance.
- `clamp!` — works: the same as on the Advance.
- `approach` — works: the same as on the Advance.
- `approach!` — works: the same as on the Advance.
- `list` — works: the same as on the Advance.
- `if_eq` — works: the same as on the Advance.
- `if_ne` — works: the same as on the Advance.
- `if_gt` — works: the same as on the Advance.
- `if_lt` — works: the same as on the Advance.
- `if_ge` — works: the same as on the Advance.
- `if_le` — works: the same as on the Advance.
- `if_gte` — works: the same as on the Advance.
- `if_lte` — works: the same as on the Advance.
- `func` — works: `fast:` means nothing on a Super Nintendo, which runs all of its code alike. `on_chip: true` runs the routine on a Super FX cartridge's chip (sums, fractions, `if`, loops, tables, lists and a copy from a table into one, and calls of other `on_chip` routines; any other step is refused).
- `call` — works: the same as on the Advance.
- `scene` — works: see `func` for `fast:`.
- `case_var` — works: the same as on the Advance.
- `uses` — works: a pack's verbs are verbs of the game's own, and each one has its answer here.
- `dump_func` — **refused**: it lists the ARM a routine was made into, and a Super Nintendo has no ARM processor to list it for.
- `entry` — **refused**: `entry` is raw ARM for the Advance's processor, which a Super Nintendo does not have.
- `held` — works: the ten buttons the Advance has, and `:x` and `:y`: a Super Nintendo controller has twelve. `player: 2` reads the second controller, and `player: :any` reads either. `player: 3` or more is refused, and `players:` more than 2 is refused too: this build reads two controllers, and does not read a Multitap yet.
- `pressed` — works: see `held`.
- `if_held` — works: see `held`.
- `if_pressed` — works: see `held`.
- `players_connected` — works: a build for a computer answers it. The cartridge build does not make it yet: it refuses it and says so, because it cannot yet tell if the second controller is connected. A controller that is not connected holds no buttons, so a cartridge can wait for a button on it instead, like `pressed(:start, player: 2)`.
- `rumble` — works: nothing is felt. A Super Nintendo cartridge has no rumble motor, so the game plays the same without it.
- `seed` — works: the same as on the Advance.
- `randomize` — works: the same as on the Advance.
- `roll` — works: the same as on the Advance.
- `rand` — works: the same as on the Advance.
- `chance` — works: the same as on the Advance.
- `random_numbers` — works: the same as on the Advance.
- `enable_sound` — works: the same as on the Advance.
- `define_sound` — works: a Super Nintendo has no square voice: its sound chip plays recordings, so the square is played as a recording of one. The sound chip cannot make a note above 16000 Hz, so a higher note plays at 16000 Hz.
- `beep` — works: see `define_sound`.
- `noise` — works: a hiss is played on the sound chip's own noise. The sound chip has no metallic noise, so a metallic hit is played as a recording of one. The sound chip's noise is at most 32000 steps a second, so a :high hiss is lower than on the Game Boy Advance.
- `wave` — works: a Super Nintendo has no wave voice: its sound chip plays recordings, so it plays each waveform as a recording. A note above 4000 Hz plays at 4000 Hz.
- `stop_wave` — works: the same as on the Advance.
- `song` — works: see `define_sound` for the square and wave voices.
- `play_song` — works: the same as on the Advance.
- `stop_music` — works: the same as on the Advance.
- `hold_music` — works: the same as on the Advance.
- `release_music` — works: the same as on the Advance.
- `music_volume` — works: the same as on the Advance.
- `fade_music_in` — works: the same as on the Advance.
- `fade_music_out` — works: the same as on the Advance.
- `songs` — works: see `song`. A recorded note with `glides: true` carries on the note sounding at a new pitch: it fades as it was, and the voice is not struck again.
- `sound_effects` — works: see `song`.
- `sample` — works: each recording plays on a voice of the sound chip. The sound chip has eight voices. Four always play recordings, and each of the other four does when the game never uses it for a beep, a wave, noise or a song's own part. If every one of those plays a recording, the next recording is not heard. It still ends or loops as on the Advance.
- `instrument` — works: see `sample`.

## Not made yet

An answer above is what the Super Nintendo does with a verb. The build for it is still growing,
and a game that reaches one of these steps is refused, naming the step, until it is made:

- the picture: `show_picture_group`, `data_byte`
- sprite tiles the game loads: `load_sprite_tiles`
- telling which controllers are connected: `players_connected`
