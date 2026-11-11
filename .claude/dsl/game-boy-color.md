# The Game Boy Color — what every verb does there

A game built for the Color too (`VBlank.game "NAME", consoles: %i[gba gbc]`, then
`vblank build`, which makes both cartridges, or `--console gbc` for the Color's alone) is
the same game on a smaller machine: a 160×144 screen (`screen_width`, `screen_height`),
eight buttons, one background, forty sprites (ten on a row of the screen), and lists of
four colours. Every verb has one of two answers there, decided once in
`Console::ColorAnswers`:

- **works** — the same game, played the same way. The Game Boy Color lowering's run of
  `rake test:all` holds the cartridge to the interpreter on every frame.
- **refused** — the build stops before anything is made, naming the hardware the Color
  lacks and what to use instead. Nothing is shown differently: a game either plays the
  same on the Color or is refused there.

This file is `Console::ColorAnswers.reference` written out (`ruby tools/console_answers.rb`),
and a test fails when the two differ. The Advance's answers are in
`.claude/dsl/game-boy-advance.md`.

- `screen` — works: `screen :tiled` and `screen :bitmap` work. A painted (bitmap) screen is made of tiles internally. Each 8×8 square of the screen holds four colours. The screen holds eight sets of four colours. The build gives each square one set for each scene. If a game paints a colour at a place that it calculates as it runs, that colour can be in every square. If a scene does not clear the screen, its squares also keep the colours of the scene before it. The build refuses a game that can paint a fifth colour into a square, and names the square. It also refuses a game that needs more than eight sets, or whose colours cannot each keep one place in every set. `tear_free: true` keeps one picture, because a Game Boy Color always shows a painted picture whole. `backdrop:` works for the whole game. The Color keeps the backdrop as the first colour of each of its colour lists, so a scene that says a different backdrop is refused. A backdrop that follows a list of colours (`backdrop:` names a list) is not made yet: the build refuses it and says so. `screen :rotozoom` is refused: a Game Boy Color cannot turn or resize a background. `pixel_size: 2` is refused: a Game Boy Color cannot show a pixel bigger.
- `setting` — works: the same as on the Advance.
- `built_for_computer?` — works: false on a cartridge.
- `built_for?` — works: true when asked about :gbc.
- `screen_width` — works: 160 on a Game Boy Color.
- `screen_height` — works: 144 on a Game Boy Color.
- `border` — works: it does nothing on a Game Boy Color, which shows the game's screen whole. The same game built for the Advance with `variants: { gba: :color_screen }` shows the border round its screen.
- `wait_vblank` — works: in a game loop, the sprites and scroll of a pass show on the frame after the wait. If a game writes the wait in a scene or an `if`, they show a frame later than that.
- `halt` — works: the same as on the Advance.
- `debug_halt` — works: the game stops there, as `halt` does; the cartridge is not cut short.
- `game_loop` — works: the same as on the Advance.
- `once_a_frame` — works: the same as on the Advance.
- `frames_since_power_on` — works: the number includes the frames that the console uses to set up the game.
- `each_pass` — works: a step can start its own job again. A step that starts its own job through a routine it calls, or two jobs whose steps start each other, is refused for now: the Game Boy Color build cannot make a routine that calls itself yet.
- `every` — works: the same as on the Advance.
- `after` — works: the same as on the Advance.
- `repeat` — works: the same as on the Advance.
- `timer` — works: a timer ticks by the frame, as the interpreter counts it.
- `pixel` — works: the same as on the Advance.
- `fill_rect` — works: the same as on the Advance.
- `dma_fill_rect` — works: the same as on the Advance.
- `draw_rect_at` — works: the same as on the Advance.
- `draw_column_at` — works: the same as on the Advance.
- `place` — works: a place is data in the cartridge. To draw it is refused: see `draw_place`.
- `viewer` — works: a viewer is variables. To draw a place from it is refused: see `draw_place`.
- `change_picture` — works: a slot is a number in a list. To draw the place is refused: see `draw_place`.
- `shading` — works: a shading is data in the cartridge. To draw a place with it is refused: see `draw_place`.
- `screen_spot` — works: the processor turns and projects the point. With no multiply instruction, each spot takes many times longer than on a Game Boy Advance.
- `draw_place` — **refused**: a Game Boy Color has no multiply instruction, and a place takes many multiplies for each point it turns. This build does not draw a place on a Color. For a view of walls, use `draw_column_at`.
- `clear_screen` — works: the same as on the Advance.
- `inside` — works: the same as on the Advance.
- `grid` — works: the same as on the Advance.
- `camera` — works: a painted screen on a Game Boy Color is the size of the screen, so moving the view over it shows black past the picture's edge. To move over a bigger world, use a tiled background and `scroll_to`. On a tiled screen the camera moves the background and the sprites together.
- `keep_showing` — works: a painted screen on a Game Boy Color is always shown whole, so a picture kept showing never tears.
- `fade` — works: `fade` and `tint` change the colours the console shows, not the picture, as on the Advance. `under:` works where it falls between the background and the sprites; `inside:` and `outside:` are refused, since a Game Boy Color cannot fade part of the screen.
- `tint` — works: the same as on the Advance.
- `fade_in` — works: the same as on the Advance.
- `fade_out` — works: the same as on the Advance.
- `flash_screen` — works: the same as on the Advance.
- `fade_level` — works: the same as on the Advance.
- `shake_screen` — works: the same as on the Advance.
- `pixelate` — **refused**: a Game Boy Color cannot show the screen in blocks: it has no mosaic. Use `fade_out` and `fade_in` to go from one screen to the next.
- `pixelate_in` — **refused**: see `pixelate`.
- `pixelate_out` — **refused**: see `pixelate`.
- `pixelate_size` — works: the same as on the Advance.
- `spotlight` — **refused**: a light darkens everything outside a circle, which needs the Advance's blending. Use `fade` to darken the whole screen.
- `iris_in` — **refused**: the iris is the game's light closing, which a Game Boy Color cannot draw (see `spotlight`). Use `fade_out` and `fade_in`.
- `iris_out` — **refused**: see `iris_in`.
- `iris_shut?` — **refused**: see `iris_in`.
- `pulse` — **refused**: a Game Boy Color cannot resize a sprite. Draw the sprite's sizes as poses and `face` them in turn.
- `camera_follows` — works: the same as on the Advance.
- `image` — works: a sprite's picture holds three colours and see-through. A background tile that gives its pixels as places in a list of four colours, and has no see-through pixel, holds all four. Every tile from one list uses the same colours, so the screen holds eight such lists. Any other background tile holds three colours and the backdrop, which is black. The build refuses a picture with more, and names its colours.
- `color` — works: the same as on the Advance.
- `rgb` — works: the same as on the Advance.
- `rgb8` — works: the same as on the Advance.
- `colors` — works: a list of colours holds four places on a Game Boy Color, the first see-through on a sprite. The console holds eight lists for sprites. A game can use more: each list borrows one of the eight when a sprite that wears it is drawn. More than eight lists on the screen at once do not fit, and a sprite that finds no free list shows another list's colours. A profile of the game says how many times a sprite showed another list's colours.
- `recolor` — works: a background that draws with more than one list the game changes is not made yet: the build refuses it and says so.
- `color_walk` — works: the same as on the Advance.
- `colors_name_of` — works: the same as on the Advance.
- `colors_in_use` — works: a set can name eight lists or fewer, because the console holds eight lists for sprites. A set with more is refused, naming the set.
- `mirror` — works: the same as on the Advance.
- `upside_down` — works: the same as on the Advance.
- `blit` — works: on a painted screen, its colours count towards the four colours of each square that it covers.
- `sprite` — works: a sprite is made of the console's 8×8 pieces, forty at once and ten on any one row of the screen. A sprite whose poses are drawn from different lists of colors shows each pose in the colors of its own list. Such a sprite cannot follow those lists (`draw_with({ hero: :hero })`): this build does not make that yet, and refuses it. If the game says `sprite_piece_size: { gbc: [8, 16] }` where it is named, every piece is 8×16: two 8×8 squares one above the other are one of the forty, and a square with none under it is one too, with an empty lower half. `scale`, `face_angle` and `turn` are refused: a Game Boy Color cannot turn or resize a sprite. Draw the turns as poses. The console holds 256 tiles of sprite pictures at once. When a game needs more, the pictures that only one scene's sprites show come in as that scene takes over. The display is off while they come in, and the scene takes over on the same frame as when every picture fits. A scene that needs more than 256 tiles, with the pictures that every scene shows, is refused. A sprite with `over_picture: true` is shown over a painted screen, as on the Advance. The sprites are then copied to the console in each blank. So less of each blank is left to copy the painted screen's tiles.
- `draw_in_order` — works: the same as on the Advance.
- `hide_sprites` — works: on the next frame, no sprite shows. On the frame after, every sprite shows where it is.
- `picture_groups` — works: the Color copies a group's pictures into its sprite memory when the group comes up, as the Advance does. The Color holds 256 tiles of sprite pictures. A frame copies 32 tiles. If a group has more, the copy takes more frames, and no sprite shows until the copy ends.
- `pool` — works: its sprites count towards the forty.
- `box` — works: the same as on the Advance.
- `tiles` — works: tiles of four colours each.
- `background` — works: one background at a time, scrolled and changed as on the Advance, and bent row by row with `scroll_each_row`. `above_row:` is refused: this build does not make it yet. `show_only_inside` is refused: a Game Boy Color cannot hide its background outside a box. Its one window is a layer that covers the background from a corner to the bottom right of the screen. The console holds 32×32 cells of a map at once, so a bigger map is brought into view as the view moves. A second background showing at once is refused, and so are `rotate` and `scale`: a Game Boy Color cannot turn or resize a background. The console holds 512 different background tiles at once. When a game needs more, each scene's own tiles come in as the scene takes over, and each area's tiles of a background that walks between areas come in as a map of the area is shown. The display is off for that one frame. A scene or an area that needs more than 512 tiles is refused. The console holds eight lists of colours for backgrounds at once. When a game needs more, the lists of each scene and each area come in with its tiles. A fade or a tint that is on then changes them too. A scene or an area that needs more than eight lists, with the lists that every scene shares, is refused. A background that walks between areas can be told `draw_with` when the console holds the lists of every area at once. If the game uses more lists than the console holds at once, each area brings its own lists in. Then `draw_with` on a background that walks between areas is refused. `held: true` changes nothing: a Game Boy Color already keeps the cells a pass changes with `set_tile` and writes them in the gap between frames. A pass keeps 160 cells, and the gap has time for about 60 of them. The others show as the display allows on the next frame.
- `status_bar` — works: the bar is a layer of its own beside the one background, so a game with a bar still has its background. The bar's tiles and the background's tiles share the room for 512 tiles. A game with a bar cannot have a `screen :bitmap`, because the bar and a painted screen use the same memory. And a sprite cannot be behind a background in it: on a Game Boy Color, a sprite behind a background is behind the bar too.
- `canvas` — works: its colours are four, as a background's tiles' are.
- `tile_pictures` — works: its colours are four, and each picture of 8×8 goes through a list, so a change costs what `changed` costs.
- `sprite_tiles` — works: a set holds at most 128 tiles, of four colours with see-through. A load is copied from the cartridge in the blank after the pass. A pass can load 8 times, as on every build. If the game draws sprites in pieces of 8×16, each piece of a pose is an even tile of the set with the next tile under it.
- `layers` — works: a layer holds a background or sprites; a background in front of a sprite works. `transparency:` is refused: a Game Boy Color cannot show one layer through another.
- `layer` — works: see `layers`.
- `draw_text` — works: painted on a painted screen; on a tiled one each letter is a sprite, so they count towards the forty, ten to a row.
- `draw_number` — works: see `draw_text`.
- `font` — works: a font of the game's own pictures (`pictures:` or `strip:`) draws each character as its picture: a `blit` on a painted screen, a sprite on a tiled one. So on a tiled screen each picture holds 3 colours and see-through, as any sprite does.
- `text_width` — works: the same as on the Advance.
- `text_height` — works: the same as on the Advance.
- `menu` — works: see `draw_text` for what its rows are made of.
- `var` — works: a variable is the same 32-bit whole number as on the Advance. One that says `width: :byte` or `width: :half` is kept in that many bytes here, which makes reading, testing and writing it much quicker.
- `save_var` — works: kept in the cartridge's battery-backed memory.
- `save_data` — works: kept in the cartridge's battery-backed memory.
- `part` — works: the same as on the Advance.
- `start_over` — works: the same as on the Advance.
- `clock` — works: read from a clock chip in the cartridge, as Pokémon Gold, Silver and Crystal had. This chip counts days and keeps no date. So `clock.set?` is false and every reading is 0 until the game sets the clock with `clock.set_to`, from a screen of its own that asks the player. After that, the time moves on with the chip, and the save keeps it.
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
- `func` — works: `fast:` means nothing on a Game Boy Color, which runs all of its code alike.
- `call` — works: the same as on the Advance.
- `scene` — works: see `func` for `fast:`.
- `case_var` — works: the same as on the Advance.
- `uses` — works: a pack's verbs are verbs of the game's own, and each one has its answer here.
- `data_pack` — works: the cartridge holds what each slot holds, as if the game had written it.
- `shell_screen` — works: the cartridge holds nothing of it. Only a build as a shell shows a first screen.
- `dump_func` — works: it lists the SM83 code a routine was made into, with the game's variables and the runtime's routines by name.
- `entry` — **refused**: `entry` is raw ARM for the Advance's processor, which a Game Boy Color does not have.
- `held` — works: the eight buttons a Game Boy Color has. `:l` and `:r` are refused: it has no shoulder buttons. `:x` and `:y` are refused too: it has no X or Y button. `player: 2` or more is refused, and `players:` more than 1 is refused too: it has one controller. `player: :any` reads that one controller.
- `pressed` — works: see `held`.
- `most_players` — works: the same as on the Advance.
- `drawing_for_local_player` — works: the player is always 1: a cartridge is played by one person.
- `mark` — works: the mark is one more of the console's sprites, shown over the sprite it marks.
- `players_connected` — works: always 1: a Game Boy Color has one controller.
- `rumble` — works: the cartridge carries a rumble motor, and the motor runs on the frames the pattern says. A cartridge with a `clock` has no motor, so a game that uses both is refused.
- `seed` — works: the same as on the Advance.
- `randomize` — works: the same as on the Advance.
- `roll` — works: the same as on the Advance.
- `rand` — works: the same as on the Advance.
- `chance` — works: the same as on the Advance.
- `random_numbers` — works: the same as on the Advance.
- `enable_sound` — works: the same as on the Advance.
- `define_sound` — works: the same as on the Advance.
- `beep` — works: the same as on the Advance.
- `noise` — works: the same as on the Advance.
- `wave` — works: the same as on the Advance.
- `stop_wave` — works: the same as on the Advance.
- `song` — works: on the square, wave and noise voices. A part played on a recording (`voice ..., plays:`) is refused. A Game Boy Color plays one recording at a time, and the game's own recordings use it (see `sample`).
- `play_song` — works: the same as on the Advance.
- `stop_music` — works: the same as on the Advance.
- `hold_music` — works: the same as on the Advance.
- `release_music` — works: the same as on the Advance.
- `music_volume` — works: the same as on the Advance.
- `fade_music_in` — works: the same as on the Advance.
- `fade_music_out` — works: the same as on the Advance.
- `songs` — works: a recorded note with `glides: true` is refused: this build does not make it yet. For the rest of recordings, see `song`.
- `sound_effects` — works: see `song` for recordings. A game can have as many effects as the cartridge's banks hold. If the effects do not fit in the part of the cartridge always in view, the build keeps them in the banks.
- `sample` — works: it plays one recording at a time, on the wave voice. Each sample turns the voice full on or off, so the sound is rough, as a Color game's voice clips are. A play while a recording sounds is not heard. A recording can loop and play at another note (`pitch:`). The wave voice has no three quarters, so a recording at three quarters of its volume plays at full. A recording with a shape (`envelope:`) is refused. The wave voice is the recording's while it plays: a `wave` or `stop_wave` said then takes effect as the recording ends, a wave the game was sounding comes back then, and so does a wave note a song is holding. A sound effect's wave part is not heard while a recording plays, and its next note after the recording sounds.
- `instrument` — **refused**: an instrument plays a recording as a part of a song, and a Game Boy Color plays a song's parts on its square, wave and noise voices only (see `song`). Write the part for the square or wave voice.

## Not made yet

The build for the Color makes every kind of step that the answers above do not refuse. Some
uses of a step are not made yet, such as a background of tiles smaller than 8×8.
A game that reaches one is refused with words that name it.
