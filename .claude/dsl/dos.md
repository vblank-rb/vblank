# DOS — what every verb does there

A game built for DOS too (`VBlank.game "NAME", consoles: %i[gba dos]`, then `vblank build`,
which makes a program for each console, or `--console dos` for DOS's alone) is the same game on
another machine: a 320×200 screen (`screen_width`, `screen_height`; `variants: { dos: :mode_x }`
is 320×240 and `variants: { dos: :vesa_640x480 }` is 640×480), pictures the processor draws,
colours of fifteen bits and lists of 256. A frame is one vertical retrace of the card: 70 a
second in mode 13h, 60 in the taller modes. The build makes an MZ EXE, the file DOS loads and
DOSBox runs. Every verb has one of two answers there, decided once in `Console::DOSAnswers`:

- **works** — the same game, played the same way. The DOS lowering's run of `rake test:all`
  holds the program to the interpreter after every pass.
- **refused** — the build stops before anything is made, naming the hardware a PC lacks and
  what to use instead.

This file is `Console::DOSAnswers.reference` written out (`ruby tools/console_answers.rb`), and
a test fails when the two differ. The Advance's answers are in `.claude/dsl/game-boy-advance.md`.

- `screen` — works: `screen :bitmap` and `screen :tiled` work: the processor draws both into a picture in memory that the VGA card shows. The game's screen is the card's whole picture, 320 × 200 in mode 13h (the variants :mode_x and :vesa_640x480 are 320 × 240 and 640 × 480), so a game laid out from `screen_width` and `screen_height` fills it. A painted picture has a colour of fifteen bits in each pixel, kept as one of 256 colours in the card's palette. `tear_free: true` changes nothing: every painted screen is drawn in memory and sent to the card between frames, so none tears, what a game paints once stays painted, and `late:` has nothing to decide. `screen :rotozoom` works too: the processor draws the turned background. `pixel_size: 2` is refused: the build does not show a painted screen bigger yet.
- `setting` — works: the same as on the Advance.
- `built_for_computer?` — works: false on DOS.
- `built_for?` — works: true when asked about :dos.
- `screen_width` — works: 320 on DOS, or what the variant says.
- `screen_height` — works: 200 on DOS, or what the variant says.
- `border` — works: it does nothing on DOS, which shows the game's screen whole.
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
- `dma_fill_rect` — works: the processor fills the rectangle: DOS has no DMA copy for the picture.
- `draw_rect_at` — works: the same as on the Advance.
- `draw_column_at` — works: the same as on the Advance.
- `place` — works: a place is data in the program.
- `viewer` — works: a viewer is variables.
- `change_picture` — works: every picture the place lists is in memory from the start, so a change copies nothing.
- `shading` — works: a shading is data in the program.
- `screen_spot` — works: the processor turns and projects the point, as the drawing of a place does.
- `draw_place` — works: the processor turns and projects every corner and fills each face itself, as the interpreter does, with the same rule for which pixels a face covers.
- `clear_screen` — works: the same as on the Advance.
- `inside` — works: the same as on the Advance.
- `grid` — works: the same as on the Advance.
- `camera` — works: the same as on the Advance.
- `keep_showing` — works: the same as on the Advance.
- `fade` — works: `fade` and `tint` change the palette the card shows, so the whole picture changes at once. A fade under a layer (`under:`) is refused: the card's 320 × 200 screen shows each pixel as one of 256 palette colours and cannot mix a faded colour with one that is not. How a fade of part of the screen (`inside:`, `outside:`) is made is decided when that is made: until then the build refuses it and says so.
- `tint` — works: see `fade`.
- `fade_in` — works: the same as on the Advance.
- `fade_out` — works: the same as on the Advance.
- `flash_screen` — works: the same as on the Advance.
- `fade_level` — works: the same as on the Advance.
- `shake_screen` — works: the same as on the Advance.
- `pixelate` — works: each block is the colour of one of its pixels, drawn by the processor.
- `pixelate_in` — works: see `pixelate`.
- `pixelate_out` — works: see `pixelate`.
- `pixelate_size` — works: the same as on the Advance.
- `spotlight` — works: how the processor darkens everything outside a circle is decided when the light is made: until then the build refuses a light and says so.
- `iris_in` — works: the iris is the game's light closing (see `spotlight`).
- `iris_out` — works: see `iris_in`.
- `iris_shut?` — works: see `iris_in`.
- `pulse` — works: the processor draws the sprite bigger or smaller.
- `camera_follows` — works: the same as on the Advance.
- `image` — works: a picture is kept in memory, a byte a pixel, each a number into the card's palette of 256 colours. Pictures share the palette where their colours fit. A game whose pictures need more colours than the palette holds is refused when it is built. A game whose pictures do not fit in the 640K of memory beside the program is refused when it is built.
- `color` — works: a colour has fifteen bits, as on the Advance. The card shows six bits of each channel, so every colour the game names is shown whole.
- `rgb` — works: see `color`.
- `rgb8` — works: see `color`.
- `colors` — works: a list of colours holds 256 places on DOS, which is the card's whole palette.
- `recolor` — works: the card has one palette for the whole screen, so each picture drawn with the list is kept once for each set of colours, and a sprite shows the set the list holds when it is next placed.
- `color_walk` — works: the same as on the Advance.
- `colors_in_use` — works: the same as on the Advance.
- `colors_name_of` — works: the same as on the Advance.
- `mirror` — works: the same as on the Advance.
- `upside_down` — works: the same as on the Advance.
- `blit` — works: the same as on the Advance.
- `sprite` — works: a sprite is a picture the processor draws each frame, any size up to 256 × 256, front-most last. The limit is time: the build counts 256 shown at once. A sprite that turns or resizes is drawn by the processor too.
- `draw_in_order` — works: the same as on the Advance.
- `hide_sprites` — works: the same as on the Advance.
- `picture_groups` — works: the same as on the Advance.
- `pool` — works: the same as on the Advance.
- `box` — works: the same as on the Advance.
- `tiles` — works: the same as on the Advance.
- `background` — works: a background is a picture kept in memory, drawn by the processor at its scroll. `show_only_inside` holds it to a rectangle, `above_row:` keeps it to the rows above a row, with `alone:` as on any console, and a background that turns or resizes is drawn by the processor too.
- `status_bar` — works: the bar is drawn by the processor from its top row down, over the backdrop, and the backgrounds are drawn only above it.
- `canvas` — works: the same as on the Advance.
- `tile_pictures` — works: the same as on the Advance.
- `sprite_tiles` — works: the same as on the Advance.
- `layers` — works: its 320 × 200 screen shows each pixel as one of 256 palette colours and mixes none, so `transparency:`, one layer seen through another, is refused. A layer's place in the stack works as on the Advance.
- `layer` — works: see `layers`.
- `draw_text` — works: the same as on the Advance.
- `draw_number` — works: see `draw_text`.
- `font` — works: a font of the game's own pictures (`pictures:` or `strip:`) draws each character as its picture: a `blit` on a painted screen, a sprite on a tiled one.
- `text_width` — works: the same as on the Advance.
- `text_height` — works: the same as on the Advance.
- `menu` — works: the same as on the Advance.
- `var` — works: a variable is the same 32-bit whole number as on the Advance.
- `save_var` — works: kept in a file beside the program.
- `save_data` — works: kept in a file beside the program.
- `part` — works: the same as on the Advance.
- `start_over` — works: the same as on the Advance.
- `clock` — works: the PC's clock chip keeps the date and the time.
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
- `func` — works: `fast:` means nothing on DOS, which runs all of its code alike.
- `call` — works: the same as on the Advance.
- `scene` — works: see `func` for `fast:`.
- `case_var` — works: the same as on the Advance.
- `uses` — works: a pack's verbs are verbs of the game's own, and each one has its answer here.
- `data_pack` — works: the program holds what each slot holds, as if the game had written it.
- `dump_func` — **refused**: it lists the ARM a routine was made into, and a PC has no ARM processor to list it for.
- `entry` — **refused**: `entry` is raw ARM for the Advance's processor, which a PC does not have.
- `held` — works: a game names the pad's buttons by the shared names: `:a` is Ctrl, `:b` Alt, `:l` Z, `:r` X, `:start` Enter, `:select` Right Shift, and the arrows are the D-pad. There is no `:x` or `:y`, and no joystick: the build reads the keyboard alone. `player: 2` is refused.
- `pressed` — works: see `held`.
- `most_players` — works: the same as on the Advance.
- `drawing_for_local_player` — works: the player is always 1: a console is played by one person.
- `mark` — works: the same as on the Advance.
- `players_connected` — works: 1.
- `rumble` — works: nothing is felt. A keyboard has no motor, so the game plays the same without it.
- `computer_keys` — works: they are for the game built for a computer (the window, `vblank run`, the web page): the cartridge is built byte for byte as without it.
- `computer_gamepad` — works: they are for the game built for a computer (the window, `vblank run`, the web page): the cartridge is built byte for byte as without it.
- `shell_screen` — works: the program holds nothing of it. Only a build as a shell shows a first screen.
- `seed` — works: the same as on the Advance.
- `randomize` — works: the same as on the Advance.
- `roll` — works: the same as on the Advance.
- `rand` — works: the same as on the Advance.
- `chance` — works: the same as on the Advance.
- `random_numbers` — works: the same as on the Advance.
- `enable_sound` — works: an AdLib card for music and effects, and a Sound Blaster for recordings.
- `define_sound` — works: a square is an FM voice of the AdLib's chip with a plain wave.
- `beep` — works: see `define_sound`.
- `noise` — works: the AdLib has no noise voice. The processor mixes a hiss into the recordings the Sound Blaster plays.
- `wave` — works: the waveform is played as a short recording of one wave on the Sound Blaster.
- `stop_wave` — works: the same as on the Advance.
- `song` — works: a song is played by the AdLib's nine FM voices.
- `play_song` — works: the same as on the Advance.
- `stop_music` — works: the same as on the Advance.
- `hold_music` — works: the same as on the Advance.
- `release_music` — works: the same as on the Advance.
- `music_volume` — works: the same as on the Advance.
- `fade_music_in` — works: the same as on the Advance.
- `fade_music_out` — works: the same as on the Advance.
- `songs` — works: the same as on the Advance.
- `sound_effects` — works: see `song`.
- `sample` — works: the processor mixes recordings, up to eight at a time, each with its own loudness, and the Sound Blaster plays the mix.
- `instrument` — works: see `sample`.

## Not made yet

An answer above is what DOS does with a verb. The build for it is still growing,
and a game that reaches one of these steps is refused, naming the step, until it is made.

- everything past numbers, the game loop and a painted screen of pixels, rectangles, pictures, text and numbers: the verbs `place`, `viewer`, `change_picture`, `shading`, `screen_spot`, `draw_place`, `grid`, `keep_showing`, `fade_in`, `fade_out`, `flash_screen`, `fade_level`, `pixelate_in`, `pixelate_out`, `pixelate_size`, `spotlight`, `iris_in`, `iris_out`, `iris_shut?`, `pulse`, `camera_follows`, `color_walk`, `colors_in_use`, `mirror`, `upside_down`, `draw_in_order`, `hide_sprites`, `picture_groups`, `box`, `canvas`, `tile_pictures`, `sprite_tiles`, `font`, `text_width`, `text_height`, `menu`, `part`, `start_over`, `saves_keep_everything`, `negate`, `negate!`, `flip`, `flip!`, `abs`, `abs!`, `negate_abs`, `negate_abs!`, `clamp`, `clamp!`, `approach`, `approach!`, `uses`, `data_pack`, `dump_func`, `entry`, `most_players`, `mark`, `rumble`, `random_numbers`, `enable_sound`, `define_sound`, `beep`, `noise`, `wave`, `stop_wave`, `song`, `play_song`, `stop_music`, `hold_music`, `release_music`, `music_volume`, `fade_music_in`, `fade_music_out`, `songs`, `sound_effects`, `sample`, `instrument`; the steps `beep`, `draw_place`, `enable_sound`, `fill_face`, `hide_sprites`, `hold_music`, `load_sprite_tiles`, `noise`, `play_from_list`, `play_sample`, `play_song`, `play_sound_effect`, `rumble`, `see_through`, `shade_outside`, `show_light_now`, `show_picture_group`, `stop_music`, `stop_sample`, `stop_wave`, `wave`
- the 640 × 480 screen (variants: { dos: :vesa_640x480 }): a game that uses one is refused.
- sprites put in order by a list: a game that uses one is refused.
- a screen of tiles with blocks or other colours; sprites painted from a list: a game that uses one is refused.
- a fade of part of the screen (`inside:`, `outside:`, `under:`): a game that uses one is refused.
