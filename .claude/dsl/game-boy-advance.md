# The Game Boy Advance — what every verb does there

A game built for the Advance (`VBlank.game "NAME", consoles: %i[gba]`, then
`vblank build`) has a 240×160 screen (`screen_width`, `screen_height`), ten buttons,
four backgrounds, 128 sprites and lists of sixteen colours. Every verb works there: the
verbs were written for the Advance first. The answers are decided in
`Console::AdvanceAnswers`, as every console's are, and the Game Boy Color's are in
`.claude/dsl/game-boy-color.md`.

This file is `Console::AdvanceAnswers.reference` written out (`ruby tools/console_answers.rb`),
and a test fails when the two differ.

- `screen` — works: `screen :bitmap, pixel_size: 2` shows each pixel of the game's 120×80 picture as a square of four. The console draws the painted screen through a background that can resize. It shows that background bigger, and the build copies nothing.
- `built_for_computer?` — works: false on a cartridge.
- `built_for?` — works: true when asked about :gba.
- `screen_width` — works: 240 on a Game Boy Advance. 120 with `pixel_size: 2`. 160 on a game built with `variants: { gba: :color_screen }`, which is laid out for a Game Boy Color.
- `screen_height` — works: 160 on a Game Boy Advance. 80 with `pixel_size: 2`. 144 with `variants: { gba: :color_screen }`.
- `border` — works: with `variants: { gba: :color_screen }`, the build shows the game's 160×144 screen at its own size in the middle of the screen, and the border fills the 40 columns at each side and the 8 rows above and below. Without `border`, the build draws a border of its own. A fade or a tint does not change the border. That build does not make a status bar, a light, a fade held to a rectangle or under a layer, a background bent row by row or one that turns, `pixelate`, `hide_sprites` or `read_scanline` yet, and refuses each. It gives the game 32 fewer sprites, which draw the border. Without the variant, `border` does nothing.
- `draw_place` — works: on `screen :bitmap, tear_free: true` only. The processor turns each point and fills each face a pixel at a time. Each `perspective:` setting is made.
- `shading` — works: the processor finds each lit pixel's colour in a table the build makes from the shading, one load a pixel. Each pixel is the colour the shading gives, exactly.
- `sprite` — works: a sprite with `over_picture: true` on a painted screen is the console's own sprite. The painted picture uses half of the sprites' memory, so their pictures have 16K, not 32K.
- `background` — works: `above_row:` is refused: this build does not make it yet. `show_only_inside` uses the display's second window. One background at a time can be held to a box. A game that holds one cannot also have a light, a status bar, a fade held to part of the screen, or a fade under a layer, because these need the same windows. With `held: true`, the cells a pass changes with `set_tile` wait in work memory and go into video memory together in the gap between frames, so they all show on the next frame. Up to 1024 changes wait. A pass that makes more writes the waiting ones at once.
- `status_bar` — works: the bar takes one of the four background layers. A game with a bar cannot also have a light, a fade held to part of the screen, or a fade under a layer, because these need the same part of the display.
- `font` — works: a font of the game's own pictures (`pictures:` or `strip:`) draws each character as its picture: a `blit` on a painted screen, a sprite on a tiled one.
- `uses` — works: a pack's verbs are verbs of the game's own, and each one has its answer here.
- `data_pack` — works: the cartridge holds what each slot holds, as if the game had written it.
- `dump_func` — works: it lists the ARM a routine was made into.
- `entry` — works: raw ARM for the Advance's processor (`.claude/dsl/escape-hatch.md`).
- `held` — works: the ten buttons a Game Boy Advance has, the shoulder buttons `:l` and `:r` among them. `:x` and `:y` are refused: it has no X or Y button. `player: 2` or more is refused, and `players:` more than 1 is refused too: it has one controller. `player: :any` reads that one controller.
- `pressed` — works: see `held`.
- `drawing_for_local_player` — works: the player is always 1: a cartridge is played by one person.
- `mark` — works: the mark is one more of the console's sprites, shown over the sprite it marks.
- `players_connected` — works: always 1: a Game Boy Advance has one controller.
- `rumble` — works: nothing is felt. A Game Boy Advance cartridge with a rumble motor is not made yet, so the game plays the same without it.
- `songs` — works: a recorded note with `glides: true` is refused: this build does not make it yet.

These work as their group files say:

`setting`, `wait_vblank`, `halt`, `debug_halt`, `game_loop`, `once_a_frame`,
`frames_since_power_on`, `each_pass`, `every`, `after`, `repeat`, `timer`, `pixel`, `fill_rect`,
`dma_fill_rect`, `draw_rect_at`, `draw_column_at`, `clear_screen`, `inside`, `grid`, `camera`,
`keep_showing`, `place`, `viewer`, `screen_spot`, `change_picture`, `fade`, `tint`, `fade_in`,
`fade_out`, `flash_screen`, `fade_level`, `shake_screen`, `pixelate`, `pixelate_in`,
`pixelate_out`, `pixelate_size`, `spotlight`, `iris_in`, `iris_out`, `iris_shut?`, `pulse`,
`camera_follows`, `image`, `color`, `rgb`, `rgb8`, `colors`, `recolor`, `colors_in_use`,
`color_walk`, `mirror`, `upside_down`, `blit`, `draw_in_order`, `hide_sprites`,
`picture_groups`, `pool`, `box`, `tiles`, `canvas`, `tile_pictures`, `sprite_tiles`, `layers`,
`layer`, `draw_text`, `draw_number`, `text_width`, `text_height`, `menu`, `var`, `save_var`,
`save_data`, `clock`, `saves_keep_everything`, `part`, `start_over`, `set`, `add`, `add_var`,
`sub`, `sub_var`, `copy`, `negate`, `negate!`, `flip`, `flip!`, `abs`, `abs!`, `negate_abs`,
`negate_abs!`, `clamp`, `clamp!`, `approach`, `approach!`, `list`, `func`, `call`, `scene`,
`case_var`, `most_players`, `seed`, `randomize`, `roll`, `rand`, `chance`, `random_numbers`,
`enable_sound`, `define_sound`, `beep`, `noise`, `wave`, `stop_wave`, `song`, `play_song`,
`stop_music`, `hold_music`, `release_music`, `music_volume`, `fade_music_in`, `fade_music_out`,
`sound_effects`, `sample`, `instrument`.
