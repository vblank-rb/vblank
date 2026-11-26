# The Game Boy Advance — what every verb does there

A game built for the Advance (`VBlank.game "NAME", consoles: %i[gba]`, then
`vblank build`) has a 240×160 screen (`screen_width`, `screen_height`), ten buttons,
four backgrounds, 128 sprites and lists of sixteen colours. Every verb works there: the
verbs were written for the Advance first. The answers are decided in
`Console::AdvanceAnswers`, as every console's are, and the Game Boy Color's are in
`.claude/dsl/game-boy-color.md`.

This file is `Console::AdvanceAnswers.reference` written out (`ruby tools/console_answers.rb`),
and a test fails when the two differ.

- `screen` — works: `screen :bitmap, pixel_size: 2` shows each pixel of the game's 120×80 picture as a square of four. The console draws the painted screen through a background that can resize. It shows that background bigger, and the build copies nothing. `shown_rows:` is refused: a Game Boy Advance can write its painted screen at any time, so rows that do not show give it no more time. To give up rows on a Super Nintendo only, write `shown_rows:` when `built_for?(:snes)` is true.
- `built_for_computer?` — works: false on a cartridge.
- `built_for?` — works: true when asked about :gba.
- `screen_width` — works: 240 on a Game Boy Advance. 120 with `pixel_size: 2`. 160 on a game built with `variants: { gba: :color_screen }`, which is laid out for a Game Boy Color.
- `screen_height` — works: 160 on a Game Boy Advance. 80 with `pixel_size: 2`. 144 with `variants: { gba: :color_screen }`.
- `border` — works: with `variants: { gba: :color_screen }`, the build shows the game's 160×144 screen at its own size in the middle of the screen, and the border fills the 40 columns at each side and the 8 rows above and below. Without `border`, the build draws a border of its own. A fade or a tint does not change the border, and `hide_sprites` does not hide it. A status bar is in the game's screen. That build does not make a light, a fade held to a rectangle or under a layer, a background bent row by row or one that turns, `pixelate` or `read_scanline` yet, and refuses each. It gives the game 32 fewer sprites, which draw the border. Without the variant, `border` does nothing.
- `draw_place` — works: on `screen :bitmap, tear_free: true` only. The processor turns each point and fills each face a pixel at a time. Each `perspective:` setting is made.
- `shading` — works: the processor finds each lit pixel's colour in a table the build makes from the shading, one load a pixel. Each pixel is the colour the shading gives, exactly.
- `recolor` — works: a background that draws with more than one list the game changes has one group of 16 background colors for each of those lists. When a list changes, the build copies its colors into that group. A background that walks between areas is refused there: this build does not make it yet.
- `sprite` — works: a sprite with `over_picture: true` on a painted screen is the console's own sprite. The painted picture uses half of the sprites' memory, so their pictures have 16K, not 32K. A sprite whose poses are drawn from different lists of colors is refused: this build draws all the poses of one sprite from one list. Use one sprite for the poses of each list.
- `layers` — works: `subtract: true` is refused: an Advance's display can add a layer to what is behind it, and can make the whole picture darker or brighter. It cannot take what is behind a layer away from the layer. A see-through layer cannot hold a background and a sprite on one screen. The display mixes a see-through sprite with one thing behind it, not two. Over the layer's own background, the sprite cannot also show what is behind the layer. The build refuses such a layer.
- `layer` — works: see `layers`.
- `background` — works: `cells_in_front: true` is refused: an Advance keeps one priority for a whole background, and no priority for one cell. To put a whole background in front of the sprites, use `layers`. `above_row:` is refused: this build does not make it yet. `hide` and `show` switch the layer of the background off and on in the display settings. They use no window, so a game can hide a background and have a light. `show_only_inside` uses the display's second window. One background at a time can be held to a box. A game that holds one cannot also have a light, a status bar, a fade held to part of the screen, or a fade under a layer, because these need the same windows. With `held: true`, the cells a pass changes with `set_tile` wait in work memory and go into video memory together in the gap between frames, so they all show on the next frame. Up to 1024 changes wait. A pass that makes more writes the waiting ones at once.
- `status_bar` — works: the bar takes one of the four background layers. A game with a bar cannot also have a light, a fade held to part of the screen, or a fade under a layer, because these need the same part of the display.
- `font` — works: a font of the game's own pictures (`pictures:` or `strip:`) draws each character as its picture: a `blit` on a painted screen, a sprite on a tiled one.
- `uses` — works: a pack's verbs are verbs of the game's own, and each one has its answer here.
- `data_pack` — works: the cartridge holds what each slot holds, as if the game had written it.
- `shell_screen` — works: the cartridge holds nothing of it. Only a build as a shell shows a first screen.
- `dump_func` — works: it lists the ARM a routine was made into.
- `entry` — works: the game can write raw ARM instructions, the machine code of the Advance's processor.
- `held` — works: the ten buttons a Game Boy Advance has, the shoulder buttons `:l` and `:r` among them. `:x` and `:y` are refused: it has no X or Y button. `player: 2` or more is refused, and `players:` more than 1 is refused too: it has one controller. `player: :any` reads that one controller.
- `pressed` — works: see `held`.
- `pulled` — works: 0 or 100. Each button of a Game Boy Advance is on or off, so a button reads 100 while it is held and 0 when it is not. It has no `:l2` or `:r2`, and the build refuses them as `held` does.
- `drawing_for_local_player` — works: the player is always 1: a cartridge is played by one person.
- `mark` — works: the mark is one more of the console's sprites, shown over the sprite it marks.
- `players_connected` — works: always 1: a Game Boy Advance has one controller.
- `rumble` — works: the cartridge carries a rumble motor, and the motor runs on the frames the pattern says. The build marks the cartridge so the emulator it is checked in runs a motor. Other emulators run one only for the few real cartridges they know. A game can read the `clock` and rumble too: the clock and the motor share the cartridge's port.
- `computer_keys` — works: they are for the game built for a computer (the window, `vblank run`, the web page): the cartridge is built byte for byte as without it.
- `computer_gamepad` — works: they are for the game built for a computer (the window, `vblank run`, the web page): the cartridge is built byte for byte as without it.
- `enable_sound` — works: `main_volume:` sets the main volume of the sound chip to the nearest of its eight steps, from an eighth to all. At 0, the sound stays off. The square, wave and noise voices can also play at a half or a quarter of each step, so a quiet main volume is nearer. Recordings play at half or at all, whichever is nearer.
- `song` — works: a part can sit between the speakers. A square, wave or noise part between the speakers (`pan -0.7`) plays from one speaker if that side is two or more times as loud as the other side. If not, it plays from both speakers. A part that plays a recording plays from both speakers, wherever `pan` puts it: all recordings are mixed into one sound, and both speakers play it.
- `songs` — works: A recorded note with `glides: true` carries on the note sounding at a new pitch, loudness and side: it goes on from where it has got to, and the voice is not struck again. A note on the noise voice can have its own `metallic:`, and a note on the wave voice can have its own `wave:`. The note sets them when it starts.

These work as their group files say:

`setting`, `feature?`, `wait_vblank`, `halt`, `debug_halt`, `game_loop`, `once_a_frame`,
`frames_since_power_on`, `each_pass`, `every`, `after`, `repeat`, `timer`, `pixel`, `fill_rect`,
`draw_rect_at`, `draw_column_at`, `clear_screen`, `inside`, `grid`, `camera`,
`redraw_on_change`, `place`, `viewer`, `screen_spot`, `change_picture`, `fade`, `tint`,
`fade_in`, `fade_out`, `flash_screen`, `fade_level`, `shake_screen`, `pixelate`, `pixelate_in`,
`pixelate_out`, `pixelate_size`, `spotlight`, `iris_in`, `iris_out`, `iris_shut?`, `pulse`,
`camera_follows`, `image`, `color`, `rgb`, `rgb8`, `colors`, `colors_in_use`, `colors_name_of`,
`color_walk`, `mirror`, `upside_down`, `blit`, `draw_in_order`, `hide_sprites`,
`picture_groups`, `pool`, `box`, `tiles`, `canvas`, `tile_pictures`, `sprite_tiles`,
`draw_text`, `draw_number`, `text_width`, `text_height`, `menu`, `var`, `save_var`, `save_data`,
`clock`, `saves_keep_everything`, `part`, `start_over`, `list`, `func`, `call`, `scene`,
`max_players`, `seed`, `randomize`, `roll`, `rand`, `chance`, `random_numbers`, `define_sound`,
`beep`, `noise`, `wave`, `stop_wave`, `play_song`, `stop_music`, `hold_music`, `release_music`,
`music_volume`, `fade_music_in`, `fade_music_out`, `sound_effects`, `sample`, `instrument`.
