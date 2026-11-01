# The Sega Genesis — what every verb does there

A game built for the Genesis too (`VBlank.game "NAME", consoles: %i[gba genesis]`, then
`vblank build`, which makes a cartridge for each console, or `--console genesis` for the
Genesis's alone) is the same game on another machine: a 320×224 screen (`screen_width`,
`screen_height`), 80 sprites (20 pieces on a row of the screen), backgrounds of tiles, colours
of nine bits and four lists of sixteen. Every verb has one of two answers there, decided once
in `Console::GenesisAnswers`:

- **works** — the same game, played the same way. The Genesis lowering's run of
  `rake test:all` holds the cartridge to the interpreter after every pass.
- **refused** — the build stops before anything is made, naming the hardware the Genesis
  lacks and what to use instead. Nothing is shown differently.

**Only the interpreter and the cartridge play a Genesis game.** The desktop, web and Ruby builds
(`--format`) are not asked to play one as a Genesis yet: they do not draw its backgrounds as the
console does, whose planes come round across a screen wider than they are, so a game for
`consoles: %i[gba genesis]` is built for those formats as the Advance.

This file is `Console::GenesisAnswers.reference` written out (`ruby tools/console_answers.rb`),
and a test fails when the two differ. The Advance's answers are in
`.claude/dsl/game-boy-advance.md`.

- `screen` — works: `screen :tiled` and `screen :bitmap` work. A Genesis has no painted screen, so a painted (bitmap) screen is made of tiles internally, which holds fifteen colours and black: a game that paints more is refused. `tear_free: true` keeps one picture, because the picture is copied to the console whole before it shows. `screen :rotozoom` is refused: a Genesis cannot turn a background.
- `setting` — works: the same as on the Advance.
- `screen_width` — works: 320 on a Genesis.
- `screen_height` — works: 224 on a Genesis.
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
- `fade` — works: `fade` and `tint` change the colours the console shows, not the picture: the colour memory is written again for each step, since a Genesis has no brightness control. `inside:`, `outside:` and `under:` are refused: the build cannot fade part of the screen on a Genesis.
- `tint` — works: the same as on the Advance.
- `fade_in` — works: the same as on the Advance.
- `fade_out` — works: the same as on the Advance.
- `flash_screen` — works: the same as on the Advance.
- `fade_level` — works: the same as on the Advance.
- `shake_screen` — works: the same as on the Advance.
- `pixelate` — **refused**: a Genesis cannot show the screen in blocks: it has no mosaic. Use `fade_out` and `fade_in` to go from one screen to the next.
- `pixelate_in` — **refused**: see `pixelate`.
- `pixelate_out` — **refused**: see `pixelate`.
- `pixelate_size` — works: the same as on the Advance.
- `spotlight` — **refused**: a light darkens everything outside a circle by degrees, and a Genesis cannot mix or darken part of the screen. Use `fade` to darken the whole screen.
- `iris_in` — **refused**: the iris is the game's light closing (see `spotlight`). Use `fade_out` and `fade_in`.
- `iris_out` — **refused**: see `iris_in`.
- `iris_shut?` — **refused**: see `iris_in`.
- `pulse` — **refused**: a Genesis cannot resize a sprite. Draw the sprite's sizes as poses and `face` them in turn.
- `camera_follows` — works: the same as on the Advance.
- `image` — works: a sprite's picture and a background's tile hold fifteen colours and see-through, from lists of sixteen. The four lists are shared by the sprites and the backgrounds.
- `color` — works: a colour has nine bits on a Genesis: three each of red, green and blue. A game names a colour in fifteen bits, and the Genesis shows the top three bits of each channel, as the interpreter does for the Genesis.
- `rgb` — works: see `color`.
- `rgb8` — works: see `color`.
- `colors` — works: a list of colours holds sixteen places on a Genesis, the first see-through. The console holds four lists, for the sprites and the backgrounds together.
- `recolor` — works: a list told to hold other colours keeps a palette to itself for the whole game, written over in the blank, so a game can change the four lists. So far only for a sprite drawn in the colours of the list it was drawn from (`draw_with` a list that holds the picture's own colours to begin with); any other `draw_with` is refused by name, and a background drawn with other colours is too.
- `color_walk` — works: the same as on the Advance.
- `colors_in_use` — works: the same as on the Advance.
- `mirror` — works: the same as on the Advance.
- `upside_down` — works: the same as on the Advance.
- `blit` — works: the same as on the Advance.
- `sprite` — works: a sprite is made of the console's pieces, 80 pieces at once and 20 pieces of 8×8 on any one row of the screen. Past 80 pieces, a sprite is not drawn and no error shows as the game runs. `scale`, `face_angle` and `turn` are refused: a Genesis cannot turn or resize a sprite. Draw the turns as poses.
- `draw_in_order` — works: the same as on the Advance.
- `hide_sprites` — works: on the next frame, no sprite shows. On the frame after, every sprite shows where it is.
- `picture_groups` — works: the same as on the Advance.
- `pool` — works: its sprites count towards the 80.
- `box` — works: the same as on the Advance.
- `tiles` — works: tiles of fifteen colours each and see-through, from one of the four lists.
- `background` — works: two backgrounds at a time, scrolled and changed as on the Advance. A background is at most 64 tiles across and 64 down, as on the Advance. `rotate` and `scale` are refused: a Genesis cannot turn a background. A `scroll_each_row` block runs for all 224 rows each pass.
- `status_bar` — works: the bar is the window, a layer the console keeps beside its two backgrounds. `set_tile` with `now: true` is refused: a Genesis writes its video memory only between frames, so a change shows on the frame after the pass.
- `canvas` — works: the same as on the Advance.
- `layers` — works: a layer holds a background or sprites. A layer cannot be see-through: a Genesis cannot mix one layer into another, so `transparency:`, `shows:` and `shows_behind:` are refused.
- `layer` — works: see `layers`.
- `draw_text` — works: painted on a painted screen; on a tiled one each letter is a sprite, so they count towards the 80, 20 pieces to a row.
- `draw_number` — works: see `draw_text`.
- `font` — works: the same as on the Advance.
- `text_width` — works: the same as on the Advance.
- `text_height` — works: the same as on the Advance.
- `menu` — works: see `draw_text` for what its rows are made of.
- `var` — works: a variable is the same 32-bit whole number as on the Advance.
- `save_var` — works: kept in battery-backed RAM on the cartridge.
- `save_data` — works: kept in battery-backed RAM on the cartridge.
- `clock` — **refused**: a Genesis cartridge has no clock chip. Ask the player for the time on a screen of the game's own, if the game needs it.
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
- `func` — works: `fast:` means nothing on a Genesis, which runs all of its code alike.
- `call` — works: the same as on the Advance.
- `scene` — works: see `func` for `fast:`.
- `case_var` — works: the same as on the Advance.
- `uses` — works: a pack's verbs are verbs of the game's own, and each one has its answer here.
- `dump_func` — **refused**: it lists the ARM a routine was made into, and a Genesis has no ARM processor to list it for.
- `entry` — **refused**: `entry` is raw ARM for the Advance's processor, which a Genesis does not have.
- `held` — works: the buttons a Genesis pad has: `:a`, `:b`, `:c`, `:start` and the D-pad. A Genesis pad has no `:select`, `:l`, `:r`, `:x` or `:y`: use `:c` and `:start` for them.
- `pressed` — works: see `held`.
- `if_held` — works: see `held`.
- `if_pressed` — works: see `held`.
- `rumble` — works: nothing is felt. A Genesis cartridge has no rumble motor, so the game plays the same without it.
- `seed` — works: the same as on the Advance.
- `randomize` — works: the same as on the Advance.
- `roll` — works: the same as on the Advance.
- `rand` — works: the same as on the Advance.
- `chance` — works: the same as on the Advance.
- `random_numbers` — works: the same as on the Advance.
- `enable_sound` — works: the same as on the Advance.
- `define_sound` — works: a Genesis plays a square on its PSG, which has three square voices.
- `beep` — works: see `define_sound`.
- `noise` — works: a hiss is played on the PSG's noise voice.
- `wave` — works: a Genesis has no wave voice: the six voices of its FM chip play each waveform as a tone of their own.
- `stop_wave` — works: the same as on the Advance.
- `song` — works: see `define_sound` for the square and wave voices.
- `play_song` — works: the same as on the Advance.
- `stop_music` — works: the same as on the Advance.
- `hold_music` — works: the same as on the Advance.
- `release_music` — works: the same as on the Advance.
- `music_volume` — works: the same as on the Advance.
- `fade_music_in` — works: the same as on the Advance.
- `fade_music_out` — works: the same as on the Advance.
- `songs` — works: see `song`.
- `sound_effects` — works: see `song`.
- `sample` — works: a recording is played on the FM chip's sixth voice, which can play a recording of eight bits. Only one recording plays at a time.
- `instrument` — works: see `sample`.

## Not made yet

An answer above is what the Genesis does with a verb. The build for it is still growing,
and a game that reaches one of these steps is refused, naming the step, until it is made:

- fades and tints: `fade`, `tint`
- the status bar: `place_bar`
- backgrounds bent row by row: `scroll_rows`
- tiles painted from a list: `copy_tiles`, `copy_owed_tiles`
- colours that change as the game runs: `background_colors`
- layers see-through: `see_through`
- the picture: `draw_column_at`, `show_picture_group`, `data_byte`
- save memory: `save_init`, `save_store`, `save_write`, `save_erase`, `save_read`, `save_sum`
- sound: `enable_sound`, `beep`, `noise`, `wave`, `stop_wave`, `play_song`, `stop_music`, `hold_music`, `play_from_list`, `play_sound_effect`, `play_sample`, `stop_sample`
