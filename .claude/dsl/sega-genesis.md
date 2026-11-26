# The Sega Genesis — what every verb does there

A game built for the Genesis too (`VBlank.game "NAME", consoles: %i[gba genesis]`, then
`vblank build`, which makes a cartridge for each console, or `--console genesis` for the
Genesis's alone) is the same game on another machine: a 320×224 screen (`screen_width`,
`screen_height`), 80 pieces of sprites up to 32×32 each (20 on a row of the screen), backgrounds of tiles, colours
of nine bits and four lists of sixteen. Every verb has one of two answers there, decided once
in `Console::GenesisAnswers`:

- **works** — the same game, played the same way. The Genesis lowering's run of
  `rake test:all` holds the cartridge to the interpreter after every pass.
- **refused** — the build stops before anything is made, naming the hardware the Genesis
  lacks and what to use instead. Nothing is shown differently.

This file is `Console::GenesisAnswers.reference` written out (`ruby tools/console_answers.rb`),
and a test fails when the two differ. The Advance's answers are in
`.claude/dsl/game-boy-advance.md`.

- `screen` — works: `screen :tiled` and `screen :bitmap` work. A Genesis has no painted screen, so a painted (bitmap) screen is made of tiles internally, which holds fifteen colours and black: a game that paints more is refused. `tear_free: true` keeps one picture, because the picture is copied to the console whole before it shows. A backdrop that follows a list of colours (`backdrop:` names a list) works: where the backdrop is a colour the list keeps in its own list of sixteen, the console shows it from there, and otherwise its colour is copied in with the list's. `screen :rotozoom` is refused: a Genesis cannot turn a background. `pixel_size: 2` is refused: a Genesis cannot show a pixel bigger. `shown_rows:` is refused: the build does not give up rows of the screen yet.
- `setting` — works: the same as on the Advance.
- `feature?` — works: the same as on the Advance.
- `built_for_computer?` — works: false on a cartridge.
- `built_for?` — works: true when asked about :genesis.
- `screen_width` — works: 320 on a Genesis.
- `screen_height` — works: 224 on a Genesis.
- `border` — works: it does nothing on a Genesis, which shows the game's screen whole.
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
- `draw_rect_at` — works: the same as on the Advance.
- `draw_column_at` — works: the same as on the Advance.
- `place` — works: a place is data in the cartridge. To draw it is refused: see `draw_place`.
- `viewer` — works: a viewer is variables. To draw a place from it is refused: see `draw_place`.
- `change_picture` — works: a slot is a number in a list. To draw the place is refused: see `draw_place`.
- `shading` — works: a shading is data in the cartridge. To draw a place with it is refused: see `draw_place`.
- `screen_spot` — works: the processor turns and projects the point.
- `draw_place` — **refused**: this build does not draw a place on a Genesis yet.
- `clear_screen` — works: the same as on the Advance.
- `inside` — works: the same as on the Advance.
- `grid` — works: the same as on the Advance.
- `camera` — works: a painted screen is the size of the screen, so moving the view over it shows the backdrop past the picture's edge. The view can move 192 pixels across and 32 down, either way. If a game moves it further, the game stops and says so. To move over a bigger world, use a tiled background and `scroll_to`. On a tiled screen the camera moves the backgrounds and the sprites together, with no such limit.
- `redraw_on_change` — works: a painted screen is copied to the console in the blank between frames, and only the squares that changed. A blank holds about a tenth of the screen, so a pass that changes all of it takes about eleven frames to show.
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
- `colors` — works: a list of colours holds sixteen places on a Genesis, the first see-through. The console holds four lists on each screen, for the sprites and the backgrounds together. A list that the game does not change takes one of the four, however many things draw with it: the sprites and a background told `draw_with` that list use the same one. If the pictures of all the scenes need more than four lists, each scene gets the lists that every scene does not use, and writes its own colours into them when it starts. A list that the game changes keeps the same one of the four in every scene that draws with it. If the scenes still need more, a scene that does not draw with that list uses its one for its own colours. If the scenes still need more, each picture declared with a list of 15 colours or fewer is drawn from one list that holds that list's colours in order, as a Genesis game's pieces each name a palette line. If a scene does not fit, the build stops and says what each kept list holds.
- `recolor` — works: a list told to hold other colours keeps one of the four lists to itself for the whole game, written over in the blank. In a game whose scenes need more than four lists, it keeps that one only in the scenes that draw with it (see `colors`). The sprites and the backgrounds drawn with it are drawn from that one list, however many sets it holds in turn. A background with tiles from other lists too draws only its tiles of that list from it, since each cell names its own list. A background that draws with several lists the game changes draws its tiles of each list from that list, so every list of a screen can change on one frame. If a background draws with more lists than the four, its short lists share one of the four. A list of three colours uses three of the fifteen places, so five such lists fit in one. A sprite's list does not share. A sprite whose pictures are drawn in the list's colours, and drawn with that list alone, keeps no list for its own colours. A sprite drawn with several lists (`draw_with [...], showing:`) takes one of the four for each list. If those lists do not fit, and the game does not change them, the build makes a copy of the sprite's pictures for each list instead. The copies use the video memory of more pictures, and they use one of the four together when all their colours fit in fifteen.
- `color_walk` — works: the same as on the Advance.
- `colors_in_use` — works: the same as on the Advance.
- `colors_name_of` — works: the same as on the Advance.
- `mirror` — works: the same as on the Advance.
- `upside_down` — works: the same as on the Advance.
- `blit` — works: the same as on the Advance.
- `sprite` — works: a sprite is made of the console's pieces. A piece is up to 32×32 pixels, so a picture of 32×32 or smaller is one piece, and the build covers a bigger picture with few pieces. A sprite whose poses are drawn from different lists of colors shows each pose in the colors of its own list, and it can follow those lists (`draw_with({ hero: :hero })`). It can also draw all those lists with one other list (`draw_with({ hero: :white, cape: :white })`). Each list that it follows uses one of the four palettes. Sprites that show the same poses use one table of them. The build draws a pose read from the frames of a data pack as the pieces of its frame. Each piece of the frame is one piece of the console. The video memory keeps each 8×8 square of picture one time. Every sprite and background that shows the square uses it, mirrored or upside down too. So a screen drawn from one slot of tiles uses each tile of the slot one time. If the pictures of a screen need more squares than the video memory holds, a sprite whose pose changes keeps room for one pose, as on the Advance. When the sprite changes pose, the console copies that pose in from the cartridge between two frames. Poses from the frames of a data pack work the same way. If the pictures do not fit even so, the build stops. It says how many squares they need and which pictures use the most. The Genesis shows 80 pieces at once, and 20 pieces and 320 pixels of sprites on any one row of the screen. A piece spends its whole width of those 320 pixels, its clear pixels and the pixels off the screen too. If there are more, some are not shown: past 20 pieces on a row, the pieces furthest back; past 320 pixels, the rest of the pieces furthest back; past 80 pieces, the pieces in front, on the whole screen. No error shows as the game runs. `scale`, `face_angle` and `turn` are refused: a Genesis cannot turn or resize a sprite. Draw the turns as poses. A sprite with `over_picture: true` shows over a painted screen, as on the Advance. The painted picture uses one of the four lists of colours and most of the video memory. So the sprites over it have three lists, and room for 350 different 8×8 squares of picture. If they need more, the build stops and says so.
- `draw_in_order` — works: the same as on the Advance.
- `hide_sprites` — works: on the next frame, no sprite shows. On the frame after, every sprite shows where it is.
- `picture_groups` — works: the same as on the Advance.
- `pool` — works: its sprites' pieces count towards the 80.
- `box` — works: the same as on the Advance.
- `tiles` — works: tiles of fifteen colours each and see-through, from one of the four lists.
- `background` — works: two backgrounds at a time, scrolled and changed as on the Advance. `above_row:` is refused: this build does not make it yet. `hide` and `show` are refused: this build does not make them yet. `show_only_inside` is refused: a Genesis cannot hide a background outside a box. Its window plane takes the place of one background in whole cells from an edge of the screen, and does not hide an ordinary background. A background is at most 64 tiles across and 64 down, as on the Advance. `rotate` and `scale` are refused: a Genesis cannot turn a background. A `scroll_each_row` block runs for all 224 rows each pass. A Genesis writes the tiles that `set_tile` changes between frames, 256 at most for one pass. If a pass changes more, each 256 are written while the pass runs, in the order the game changed them, and a frame can show part of the change. `held: true` changes nothing: up to 256 cells that a pass changes already show together. With `cells_in_front: true`, each cell that the map marks is in front of every sprite, as the console draws a cell with its priority bit set.
- `status_bar` — works: the bar is the window, a layer the console keeps beside its two backgrounds. `set_tile` with `now: true` is refused: a Genesis writes its video memory only between frames, so a change shows on the frame after the pass.
- `canvas` — works: the same as on the Advance.
- `tile_pictures` — works: the same as on the Advance.
- `sprite_tiles` — works: a Genesis can draw poses from tiles the game loads, but this build does not make it yet. A game with a pose drawn from sprite tiles is refused, and the build says so (see Not made yet).
- `layers` — works: a layer holds a background or sprites. A layer cannot be see-through: a Genesis cannot mix one layer into another, so `transparency:`, `shows:` and `shows_behind:` are refused.
- `layer` — works: see `layers`.
- `draw_text` — works: painted on a painted screen; on a tiled one each letter is a sprite, so they count towards the 80, 20 pieces to a row.
- `draw_number` — works: see `draw_text`.
- `font` — works: a font of the game's own pictures (`pictures:` or `strip:`) draws each character as its picture: a `blit` on a painted screen, a sprite on a tiled one.
- `text_width` — works: the same as on the Advance.
- `text_height` — works: the same as on the Advance.
- `menu` — works: see `draw_text` for what its rows are made of.
- `var` — works: a variable is the same 32-bit whole number as on the Advance.
- `save_var` — works: kept in battery-backed RAM on the cartridge.
- `save_data` — works: kept in battery-backed RAM on the cartridge.
- `part` — works: the same as on the Advance.
- `start_over` — works: the same as on the Advance.
- `clock` — **refused**: a Genesis cartridge has no clock chip. Ask the player for the time on a screen of the game's own, if the game needs it.
- `saves_keep_everything` — works: the same as on the Advance.
- `list` — works: the same as on the Advance.
- `func` — works: `fast:` means nothing on a Genesis, which runs all of its code alike.
- `call` — works: the same as on the Advance.
- `scene` — works: see `func` for `fast:`.
- `uses` — works: a pack's verbs are verbs of the game's own, and each one has its answer here.
- `data_pack` — works: the cartridge holds what each slot holds, as if the game had written it.
- `shell_screen` — works: the cartridge holds nothing of it. Only a build as a shell shows a first screen.
- `dump_func` — **refused**: it lists the ARM a routine was made into, and a Genesis has no ARM processor to list it for.
- `entry` — **refused**: `entry` is raw ARM for the Advance's processor, which a Genesis does not have.
- `held` — works: the buttons a Genesis pad has: `:a`, `:b`, `:c`, `:start` and the D-pad. A Genesis pad has no `:select`, `:l`, `:r`, `:x` or `:y`: use `:c` and `:start` for them. `player: 2` reads the second pad. `player: 3`, `player: 4` and `player: 5` read the pads in a Sega Team Player in the second port. `player: :any` reads all of them. The build refuses `player: 6` or more, and `players:` more than 5, because it reads five pads. If no Team Player is connected, players 3, 4 and 5 hold no buttons.
- `pressed` — works: see `held`.
- `pulled` — works: 0 or 100. Each button of a Genesis pad is on or off, so a button reads 100 while it is held and 0 when it is not. It has no `:l2` or `:r2`, and the build refuses them as `held` does.
- `max_players` — works: the same as on the Advance.
- `drawing_for_local_player` — works: the player is always 1: a cartridge is played by one person.
- `mark` — works: the mark is one more of the console's sprites, shown over the sprite it marks.
- `players_connected` — works: 1 at the start. A player is connected from the first frame that one of their buttons is down. Then the player stays connected. Players 3, 4 and 5 can connect only through a Sega Team Player in the second port. If no Team Player is connected, the count is 1 or 2.
- `rumble` — works: nothing is felt. A Genesis cartridge has no rumble motor, so the game plays the same without it.
- `computer_keys` — works: they are for the game built for a computer (the window, `vblank run`, the web page): the cartridge is built byte for byte as without it.
- `computer_gamepad` — works: they are for the game built for a computer (the window, `vblank run`, the web page): the cartridge is built byte for byte as without it.
- `seed` — works: the same as on the Advance.
- `randomize` — works: the same as on the Advance.
- `roll` — works: the same as on the Advance.
- `rand` — works: the same as on the Advance.
- `chance` — works: the same as on the Advance.
- `random_numbers` — works: the same as on the Advance.
- `enable_sound` — works: `main_volume:` is refused: the sound chips of a Sega Genesis have no main volume.
- `define_sound` — works: a Genesis plays a square on its PSG, which has three square voices. Each square is half up and half down, so `duty:` is not heard, and a PSG voice sounds from both speakers. A fade or a swell moves in the same time as on the Advance. The lowest square note is 109 Hz.
- `beep` — works: see `define_sound`.
- `noise` — works: a hiss is played on the PSG's noise voice, and `metallic:` is its rattle.
- `wave` — works: a Genesis has no wave voice: the first voice of its FM chip plays each waveform as a tone of its own, the first four harmonics of the waveform.
- `stop_wave` — works: the same as on the Advance.
- `song` — works: see `define_sound` for the square and wave voices. A wave part between the speakers (`pan -0.7`) plays from one speaker if that side is two or more times as loud as the other side. If not, it plays from both speakers. A part that plays a recording plays from the left speaker, the right speaker or both, the nearest to where `pan` puts it, by the same rule: the DAC plays through the FM chip's sixth voice, which has a switch for each speaker. For its loudness, see `sample`.
- `play_song` — works: the same as on the Advance.
- `stop_music` — works: the same as on the Advance.
- `hold_music` — works: the same as on the Advance.
- `release_music` — works: the same as on the Advance.
- `music_volume` — works: the same as on the Advance.
- `fade_music_in` — works: the same as on the Advance.
- `fade_music_out` — works: the same as on the Advance.
- `songs` — works: see `song`. A recorded note with `glides: true` carries on the note sounding at a new pitch, loudness and side: it goes on from where it has got to, and the voice is not struck again. It moves to the nearest speaker, as `song` says, and its new loudness is not heard, as no recording's is. A note on the noise voice can have its own `metallic:`, and a note on the wave voice can have its own `wave:`. The note sets them when it starts. If the game sets its music volume, such a note is refused: this build does not make it yet.
- `sound_effects` — works: see `song`.
- `sample` — works: a recording is played on the FM chip's sixth voice, which can play a recording of eight bits. The sound processor sounds about 13300 samples a second, and plays each recording at the rate it was recorded at. Only one recording plays at a time, and a recording cannot have a shape (`envelope:`). A recording plays at full loudness, whatever its volume: the DAC has no volume of its own. To play it more quietly, the sound processor must scale each sample, about 13300 times a second, through a table for each volume. This build does not do that yet. Its sample loop takes about 192 of the 269 cycles it has for each sample, and copies the recording ahead in the rest, so the look-up fits, and 16 tables take 4 KB of its 8 KB of memory. Until then, the music volume and a sound's volume are only in the sound log.
- `instrument` — works: see `sample`.

## Not made yet

An answer above is what the Genesis does with a verb. The build for it is still growing,
and a game that reaches one of these steps is refused, naming the step, until it is made:

- the status bar: `place_bar`
- sprite tiles the game loads: `load_sprite_tiles`
- layers see-through: `see_through`
- save memory: `save_erase`, `save_sum`, `save_load_list`, `save_store_list`

Parts of the picture are refused the same way, naming the part:

- a sprite's pose drawn from sprite tiles the game loads (`sprite_tiles`)
- a game with both a painted (bitmap) screen and a tiled one
- a background on a painted (bitmap) screen
- a sprite behind a background, or put in a layer behind one (`put_in_layer`)
- a scene's own background in a layer behind one every screen shows
- a `screen ... backdrop:` of a scene's own on a painted screen, or anywhere but in a scene's own lines
- background tiles that are not 8×8, or backgrounds of different sizes on one screen
- a map too big to hold
- more lists of colours than the console's four
- a sprite's picture painted from a list (`image ..., from: list`), and tiles of 16x16 painted from one
