# The Game Boy Advance — what every verb does there

A game built for the Advance (`VBlank.game "NAME", consoles: %i[gba]`, then
`vblank build`) has a 240×160 screen (`screen_width`, `screen_height`), ten buttons,
four backgrounds, 128 sprites and lists of sixteen colours. Every verb works there: the
verbs were written for the Advance first. The answers are decided in
`Console::AdvanceAnswers`, as every console's are, and the Game Boy Color's are in
`.claude/dsl/game-boy-color.md`.

This file is `Console::AdvanceAnswers.reference` written out (`ruby tools/console_answers.rb`),
and a test fails when the two differ.

- `built_for_computer?` — works: false on a cartridge.
- `screen_width` — works: 240 on a Game Boy Advance.
- `screen_height` — works: 160 on a Game Boy Advance.
- `sprite` — works: a sprite with `over_picture: true` on a painted screen is the console's own sprite. The painted picture uses half of the sprites' memory, so their pictures have 16K, not 32K.
- `background` — works: `above_row:` is refused: this build does not make it yet. `show_only_inside` uses the display's second window. One background at a time can be held to a box. A game that holds one cannot also have a light, a status bar, a fade held to part of the screen, or a fade under a layer, because these need the same windows.
- `status_bar` — works: the bar takes one of the four background layers. A game with a bar cannot also have a light, a fade held to part of the screen, or a fade under a layer, because these need the same part of the display.
- `uses` — works: a pack's verbs are verbs of the game's own, and each one has its answer here.
- `dump_func` — works: it lists the ARM a routine was made into.
- `entry` — works: raw ARM for the Advance's processor (`.claude/dsl/escape-hatch.md`).
- `held` — works: the ten buttons a Game Boy Advance has, the shoulder buttons `:l` and `:r` among them. `:x` and `:y` are refused: it has no X or Y button. `player: 2` is refused: it has one controller.
- `pressed` — works: see `held`.
- `if_held` — works: see `held`.
- `if_pressed` — works: see `held`.
- `rumble` — works: nothing is felt. A Game Boy Advance cartridge with a rumble motor is not made yet, so the game plays the same without it.
- `songs` — works: a recorded note with `glides: true` is refused: this build does not make it yet.

These work as their group files say:

`screen`, `setting`, `wait_vblank`, `halt`, `debug_halt`, `game_loop`, `once_a_frame`,
`frames_since_power_on`, `each_pass`, `every`, `after`, `repeat`, `timer`, `pixel`, `fill_rect`,
`dma_fill_rect`, `draw_rect_at`, `draw_column_at`, `clear_screen`, `inside`, `grid`, `camera`,
`keep_showing`, `fade`, `tint`, `fade_in`, `fade_out`, `flash_screen`, `fade_level`,
`shake_screen`, `pixelate`, `pixelate_in`, `pixelate_out`, `pixelate_size`, `spotlight`,
`iris_in`, `iris_out`, `iris_shut?`, `pulse`, `camera_follows`, `image`, `color`, `rgb`, `rgb8`,
`colors`, `recolor`, `colors_in_use`, `color_walk`, `mirror`, `upside_down`, `blit`,
`draw_in_order`, `hide_sprites`, `picture_groups`, `pool`, `box`, `tiles`, `canvas`,
`tile_pictures`, `sprite_tiles`, `layers`, `layer`, `draw_text`, `draw_number`, `font`,
`text_width`, `text_height`, `menu`, `var`, `save_var`, `save_data`, `clock`,
`saves_keep_everything`, `set`, `add`, `add_var`, `sub`, `sub_var`, `copy`, `negate`, `negate!`,
`flip`, `flip!`, `abs`, `abs!`, `negate_abs`, `negate_abs!`, `clamp`, `clamp!`, `approach`,
`approach!`, `list`, `if_eq`, `if_ne`, `if_gt`, `if_lt`, `if_ge`, `if_le`, `if_gte`, `if_lte`,
`func`, `call`, `scene`, `case_var`, `seed`, `randomize`, `roll`, `rand`, `chance`,
`random_numbers`, `enable_sound`, `define_sound`, `beep`, `noise`, `wave`, `stop_wave`, `song`,
`play_song`, `stop_music`, `hold_music`, `release_music`, `music_volume`, `fade_music_in`,
`fade_music_out`, `sound_effects`, `sample`, `instrument`.
