# The PlayStation — what every verb does there

A game built for the PlayStation too (`VBlank.game "NAME", consoles: %i[gba ps1]`, then
`vblank build`, which makes a program for each console, or `--console ps1` for the
PlayStation's alone) is the same game on another machine: a 320×240 screen (`screen_width`,
`screen_height`), pictures drawn by its graphics chip, colours of fifteen bits and lists of
256. The build makes a PS-X EXE, the file an emulator or a loader on a real console runs. Every
verb has one of two answers there, decided once in `Console::PS1Answers`:

- **works** — the same game, played the same way. The PlayStation lowering's run of
  `rake test:all` holds the program to the interpreter after every pass.
- **refused** — the build stops before anything is made, naming the hardware the PlayStation
  lacks and what to use instead.

This file is `Console::PS1Answers.reference` written out (`ruby tools/console_answers.rb`), and
a test fails when the two differ. The Advance's answers are in `.claude/dsl/game-boy-advance.md`.

- `screen` — works: `screen :bitmap` and `screen :tiled` work: the graphics chip draws both into video RAM. `tear_free: true` keeps two pictures, one drawn while the other shows. `screen :rotozoom` works too: the chip draws the turned background as a textured shape.
- `setting` — works: the same as on the Advance.
- `built_for_computer?` — works: false on a PlayStation.
- `screen_width` — works: 320 on a PlayStation.
- `screen_height` — works: 240 on a PlayStation.
- `border` — works: it does nothing on a PlayStation, which shows the game's screen whole.
- `wait_vblank` — works: in a game loop, the sprites and scroll of a pass show on the frame after the wait. If a game writes the wait in a scene or an `if`, they show a frame later than that.
- `halt` — works: the same as on the Advance.
- `debug_halt` — works: the game stops there, as `halt` does; the program is not cut short.
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
- `place` — works: a place is data in the program.
- `viewer` — works: a viewer is variables.
- `shading` — works: a shading is data in the program.
- `screen_spot` — works: the processor turns and projects the point, as the drawing of a place does.
- `draw_place` — works: the processor turns and projects every corner, and the graphics chip fills the faces.
- `clear_screen` — works: the same as on the Advance.
- `inside` — works: the same as on the Advance.
- `grid` — works: the same as on the Advance.
- `camera` — works: the same as on the Advance.
- `keep_showing` — works: the same as on the Advance.
- `fade` — works: `fade` and `tint` change the colours the console shows. How the graphics chip fades part of the screen (`inside:`, `outside:`, `under:`) is decided when that is made: until then the build refuses it and says so.
- `tint` — works: the same as on the Advance.
- `fade_in` — works: the same as on the Advance.
- `fade_out` — works: the same as on the Advance.
- `flash_screen` — works: the same as on the Advance.
- `fade_level` — works: the same as on the Advance.
- `shake_screen` — works: the same as on the Advance.
- `pixelate` — works: each block is the colour of one of its pixels, drawn by the graphics chip.
- `pixelate_in` — works: see `pixelate`.
- `pixelate_out` — works: see `pixelate`.
- `pixelate_size` — works: the same as on the Advance.
- `spotlight` — works: how the graphics chip darkens everything outside a circle is decided when the light is made: until then the build refuses a light and says so.
- `iris_in` — works: the iris is the game's light closing (see `spotlight`).
- `iris_out` — works: see `iris_in`.
- `iris_shut?` — works: see `iris_in`.
- `pulse` — works: the graphics chip draws the sprite bigger or smaller as a textured shape.
- `camera_follows` — works: the same as on the Advance.
- `image` — works: a picture is kept in video RAM, with a list of 16 or 256 colours.
- `color` — works: a colour has fifteen bits, as on the Advance.
- `rgb` — works: see `color`.
- `rgb8` — works: see `color`.
- `colors` — works: a list of colours holds 256 places on a PlayStation, the first see-through.
- `recolor` — works: the same as on the Advance.
- `color_walk` — works: the same as on the Advance.
- `colors_in_use` — works: the same as on the Advance.
- `mirror` — works: the same as on the Advance.
- `upside_down` — works: the same as on the Advance.
- `blit` — works: the same as on the Advance.
- `sprite` — works: a sprite is a picture the graphics chip draws each frame, any size up to 256 × 256. There is no limit of sprites on a row of the screen. A sprite that turns or resizes is drawn as a textured shape.
- `draw_in_order` — works: the same as on the Advance.
- `hide_sprites` — works: the same as on the Advance.
- `picture_groups` — works: the same as on the Advance.
- `pool` — works: the same as on the Advance.
- `box` — works: the same as on the Advance.
- `tiles` — works: the same as on the Advance.
- `background` — works: a background is a picture kept in video RAM, drawn by the graphics chip at its scroll. `show_only_inside` holds it to the chip's drawing area, and a background that turns or resizes is drawn as a textured shape.
- `status_bar` — works: the same as on the Advance.
- `canvas` — works: the same as on the Advance.
- `tile_pictures` — works: the same as on the Advance.
- `sprite_tiles` — works: the same as on the Advance.
- `layers` — works: the same as on the Advance.
- `layer` — works: see `layers`.
- `draw_text` — works: the same as on the Advance.
- `draw_number` — works: see `draw_text`.
- `font` — works: the same as on the Advance.
- `text_width` — works: the same as on the Advance.
- `text_height` — works: the same as on the Advance.
- `menu` — works: the same as on the Advance.
- `var` — works: a variable is the same 32-bit whole number as on the Advance.
- `save_var` — works: kept on the memory card in the first slot.
- `save_data` — works: kept on the memory card in the first slot.
- `part` — works: the same as on the Advance.
- `start_over` — works: the same as on the Advance.
- `clock` — **refused**: a PlayStation has no clock chip. Ask the player for the time on a screen of the game's own, if the game needs it.
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
- `func` — works: `fast:` means nothing on a PlayStation, which runs all of its code alike.
- `call` — works: the same as on the Advance.
- `scene` — works: see `func` for `fast:`.
- `case_var` — works: the same as on the Advance.
- `uses` — works: a pack's verbs are verbs of the game's own, and each one has its answer here.
- `dump_func` — **refused**: it lists the ARM a routine was made into, and a PlayStation has no ARM processor to list it for.
- `entry` — **refused**: `entry` is raw ARM for the Advance's processor, which a PlayStation does not have.
- `held` — works: a game names the pad's buttons by the shared names: `:a` is Cross, `:b` Circle, `:x` Triangle, `:y` Square, `:l` L1 and `:r` R1, with `:select`, `:start` and the D-pad. A PlayStation has two ports for pads. The build reads the first alone for now, so `player: 2` and `players:` more than 1 are not made yet.
- `pressed` — works: see `held`.
- `if_held` — works: see `held`.
- `if_pressed` — works: see `held`.
- `most_players` — works: the same as on the Advance.
- `drawing_for_local_player` — works: the player is always 1: a console is played by one person.
- `mark` — works: the same as on the Advance.
- `players_connected` — works: 1 while the build reads the first pad alone.
- `rumble` — works: nothing is felt. The build reads a digital pad, which has no motor, so the game plays the same without it.
- `seed` — works: the same as on the Advance.
- `randomize` — works: the same as on the Advance.
- `roll` — works: the same as on the Advance.
- `rand` — works: the same as on the Advance.
- `chance` — works: the same as on the Advance.
- `random_numbers` — works: the same as on the Advance.
- `enable_sound` — works: the same as on the Advance.
- `define_sound` — works: the sound chip plays a square as a short recording of one wave, on a voice of its own.
- `beep` — works: see `define_sound`.
- `noise` — works: the sound chip has a noise voice.
- `wave` — works: the waveform is played as a short recording of one wave.
- `stop_wave` — works: the same as on the Advance.
- `song` — works: the same as on the Advance.
- `play_song` — works: the same as on the Advance.
- `stop_music` — works: the same as on the Advance.
- `hold_music` — works: the same as on the Advance.
- `release_music` — works: the same as on the Advance.
- `music_volume` — works: the same as on the Advance.
- `fade_music_in` — works: the same as on the Advance.
- `fade_music_out` — works: the same as on the Advance.
- `songs` — works: the same as on the Advance.
- `sound_effects` — works: see `song`.
- `sample` — works: the sound chip plays recordings itself, 24 voices of them, each with its own loudness.
- `instrument` — works: see `sample`.

## Not made yet

An answer above is what the PlayStation does with a verb. The build for it is still growing,
and a game that reaches one of these steps is refused, naming the step, until it is made:

- the painted (bitmap) screen: `clear_screen`, `fill_rect`, `dma_fill_rect`, `draw_rect_at`, `draw_column_at`, `pixel`, `inside`, `blit`, `blit_pose`, `draw_text`, `draw_digit`, `save_region`, `restore_region`, `camera`
- fades, lights and screen effects: `fade`, `tint`, `pixelate`, `shade_outside`
- places drawn in 3D: `draw_place`, `fill_face`
- sprites and tiled backgrounds: `background`, `scroll_background`, `set_tile`, `show_map`, `present_objects`, `color_list_holds`, `background_colors`, `hide_sprites`, `place_bar`, `copy_tiles`, `box_background`, `copy_owed_tiles`, `load_sprite_tiles`, `affine_background`, `scroll_rows`, `see_through`, `show_held_tiles`, `show_picture_group`, `pixels_overlap`
- sound: `enable_sound`, `beep`, `noise`, `wave`, `stop_wave`, `play_song`, `stop_music`, `hold_music`, `play_from_list`, `play_sound_effect`, `play_sample`, `stop_sample`
- save memory: `save_init`, `save_store`, `save_write`, `save_erase`, `save_read`, `save_sum`
- numbers with a fraction: `mul_fix`, `div_fix`
