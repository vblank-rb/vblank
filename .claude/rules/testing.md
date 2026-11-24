---
paths:
  - "test/**/*.rb"
---

# Testing rules — `test/`

The rules every test here follows. What to assert at which altitude, and the cross-backend rule,
are in `.claude/CLAUDE.md`. The APIs and the long stories are in `.claude/testing/`; read the one
you need before writing a test that uses it:

| file | what it holds |
|---|---|
| `interpreter.md` | the reference interpreter: reading pixels, variables, lists, pools, sprites; input; late passes; the step budget |
| `emulator.md` | the emulator's reader: pixels, whole-screen questions, sprites, palettes, sound, stepping, counting passes |
| `differential.md` | interpreter against console: every pixel (`assert_backends_agree`), every byte of mixed sound |
| `lowerings.md` | the native, JavaScript and Game Boy Color runs: what `game_player` is there, what it compares, saves, examples, `test/console/gba/`, the library's test kit |
| `native-sound.md` | the game as C's speaker against the cartridge's, and the frame-apart trap |
| `desktop.md` | the desktop window: keys, Retina, the save file, frame pacing, the editor's C checker |
| `runs.md` | rake commands, which run a change needs, the machine-wide lock, worktrees, the native run's processes |
| `costs.md` | asserting what something costs: bytes emitted, or the profiler's idle share and fps |

## Skills here

Which skill fits is "Skills" in `.claude/rules/shared/all-projects.md`. Here `tdd`'s red test goes at
the altitude `.claude/CLAUDE.md` sets and in the folder the table below says; `code-review` is due for
a change to shared code or a lowering's logic; `writing-for-agents` when editing these notes.

The order around them: red test, fix, the touched test files, `rake test:golden`, `rake emitted:check`
if a cartridge's contents changed, commit, review, its fixes folded into the commit.

## Where a test file goes: the folder says which runs play it

`rake test:all` plays the suite once per run, and each run's player is `game_player`: the
interpreter on the gba run; on every other run that run's own build of the game (as C,
JavaScript, Ruby, a Color or Super Nintendo cartridge), checked against the interpreter on every
frame or pass. The folder a test file sits in is all that says which runs load it
(`test/support/suites.rb` is the table; a test fails if a file sits anywhere else):

| folder | what goes there | runs that load it |
|---|---|---|
| `test/all/` | what a game does, asked only through `game_player` | every run |
| `test/console/<console>/` | what only that console's hardware can do (two backgrounds, part-screen fades on the Advance) | every run that plays games as that console |
| `test/lowering/<lowering>/` | that lowering's own output: the ARM, the C, the cartridge built, read in the emulator, measured | that lowering's run |
| `test/interpreter/` | what only the interpreter answers: `frames_each_pass`, a power cut after N steps | the run whose player is the interpreter |

**A new test goes in `test/all/`.** If it fails on a run whose console cannot do what it asks,
write it again for each run that can, in that console's or lowering's folder, and keep the game
it plays once, in a module both include (or duplicate it where it cannot be shared cleanly).
Don't bend a test to make it play everywhere; move it. `rake test:misplaced` plays every folder
but `test/all/` on the runs that do not load it and names each test that passed there while
playing a game: a test that could come back to `test/all/` (narrow it with `ONLY=` and `RUNS=`).

**Skips are for the machine, not the console.** A test that cannot run on the machine playing the
suite says so with `skip_on_this_machine "why"` — "this test is for macOS only", a tool that is not installed, a game's data it cannot ship. A test of
something one console cannot do is never a skip: it is in the wrong place, and moves to the folders
of the consoles that can (`test/console/<console>/`), its game and tests kept once in a module the
files include (`test/clock_tests.rb`). The one lowering skip there is: **a part the run's build does
not make yet** (the player raises that itself, naming the part, or `skip_on_gbc "why"` and its
siblings), and only while the work to make it is tracked; the skip names the part, never the
tracker. A run playing as a console refuses a game that console's build refuses before it plays
(`Testing::BuildChecks`: the checks a build runs, from `IR::ProgramChecks`, so the console's limits
and its answers; the interpreter's run asks only that the tree is one a build can be made from), with
the build's `Guardrails::ValidationError`, so a test in `test/all/` of what one console cannot do
fails on that console's runs rather than passing unseen. A test of the refusal itself asserts it
there: its class and a key phrase. A test that shows what a refused game would do plays it on the
interpreter by name (`Reference.new.run`), since no run's player plays it. Any other skip fails the run (`Testing::SkipsByReason`). Reading
the Advance's cartridge (`require_emulator!`, `assert_emulator_loads_rom`) outside the gba run
fails too, saying it belongs in `test/lowering/gba/`. A step budget (`max_steps:`) is fine
anywhere: every run plays it as the frames it covers.

Inside each folder the tree mirrors lib's directories (not its files): a test of
`lib/vblank/audio/score.rb` is in `test/all/vblank/audio/`, of `cli.rb` in `test/all/vblank/`, of
an example in `test/all/examples/`, of a tool in `test/all/tools/`. A new directory needs one under
`lib/` first. The exceptions are the lowerings' `examples/` folders, which mirror `examples/`.

A test belongs to the file a person opens first when it fails:

- A DSL program checked for what it does → the builder file that defines the verb,
  `test/all/vblank/builder/` (`grep -n "def <verb>" lib/vblank/builder/*.rb`). A method on a
  handle (`sprite.face_angle`, `list.shift`) → the dsl file defining it, `test/all/vblank/dsl/`.
- Hand-built IR checked on one backend → that backend's folder.
- One guardrail's friendly error → `test/all/vblank/ir/guardrails/`.
- A number about the build or the run (bytes, frames, dropped sounds) → the file that makes the
  number, usually a backend or `test/lowering/gba/vblank/diagnostics/`.
- A command → the file that does its work. `vblank run` with a tape or script, and `compare`, are done by
  `lib/vblank/playthroughs/command_line.rb`, so their tests are in `test/lowering/gba/vblank/playthroughs/`.

The folder is chosen by which runs a test is about (above); inside it, the file by what it tests.
A behaviour checked through `game_player` and again on the Advance's cartridge is two tests: one
in `test/all/`, one in `test/lowering/gba/` (`test_tint_cartridge.rb` beside `test_tint.rb`).

**One file, one `Minitest::Test` subclass.** **Only tests are public**: every helper in a test
class is `private def`, except one a game block calls back through (`test = self`, then
`test.tileset(self)`) or a class method called as `TestThing.helper`. Helpers two files share go
in a module: defined at the top of the shared test file and included by both classes, the other
file loading it by its path under `test/` (`require "all/vblank/builder/test_tint"`), or, used
by many files, in a shared helper at `test/`.

The shared helpers stay at `test/` — `test_helper.rb`, `differential.rb`, `emulator_blend.rb`,
`mixed_sound.rb`, `conformance_fixture.rb`, `int32_cases.rb` (the calculations a runtime written
again in another language is held to), `runtime_sounds.rb` (the sound such a runtime is held
to, sample for sample against the native one's), `midpoint_circle.rb` (the answer key for a light's
rows), `many_rooms_game.rb` (a scene of many rooms with sprite pictures grouped by room),
`status_bar_games.rb` (small games with a status bar, for the verb's and its handle's tests),
`sprite_box_fields.rb` (a sea with a moving hollow box sprite and a cell of rock, built for any console, for each console's test of a comparison's `ignoring_sprites:`),
`ractor_workers.rb` (for a test that starts Ractor workers by hand: quiet about Ractors being experimental, and a worker's error raised as it was; and `while_swapped`, a library method stood in for by a test on the main Ractor while workers may call it),
`compared_without_advance_emulator.rb` (two cartridges of a console that does not play in the Advance's emulator, compared in a child process where that emulator cannot load, for the Genesis's and the Super Nintendo's tests),
`ps1_pass_work.rb` (a PlayStation game whose pass is a loop of work, and the turns of it, measured in the emulator as the test runs, that end every pass a given range of lines past the blank, for the profile's, the pad's and the checked run's tests of passes longer than a frame),
`slow_pass_games.rb` (a box that steps a pixel a pass, and a build of it whose every fourth pass counts itself and moves the box a frame later, its busy loop's turns measured in the console's emulator as the test runs, built for any console, for each console's test of a comparison's `passes_compared_at: :end` and of where it starts after lead-ins that leave the two builds passes apart and what the one behind presses as it catches up),
`made_up_original.rb` (the made-up Game Boy Advance original and a game reading it through a data pack, for the data pack, copy reader, packing and shell tests),
`pieced_original.rb` (that original's songs rendered by a part in pieces, a song a piece in rooms of uneven size, for the tests of pieces on the build and on the Ruby and web shells' workers),
`folder_original.rb` (a made-up computer original that is a folder of files, `test/fixtures/folder_original/`, and a port reading it, for the copy, copy reader and shell tests),
`shell_screen_tests.rb` (the made-up port with a shell's first screen of its own, `shell_screen`, and the same screen drawn by a plain game, which is the answer key each runtime's test holds it to),
`made_up_original_layouts.rb` (made-up originals in each console's layout, and a game reading them through a data pack, for the layout tests and the pack-at-start runs),
`made_up_vblank_layout_originals.rb` (made-up PlayStation, computer and arcade originals whose unpacking writes colours, tiles and numbers in VBlank's own layout, a game showing them as a background and a sprite, and the same screen drawn by the game, its answer key; for the layout test and the registry),
`pack_games.rb` (THE REGISTRY of small games that read a data pack, each registered once with how long to play it, in a kit for each made-up original; a new verb that takes a pack handle adds its game here, see "A game that reads a data pack" in `.claude/testing/lowerings.md`),
`pack_parity_tests.rb` (the one test of every registered game: built with its pack left out it plays as its all-in-one build on every pass, or is refused in plain words, and written out it holds none of the pack's numbers; a game that names frames is handed the file its pack's unpacking writes from the copy, held byte for byte to the all-in-one one; played by the interpreter and the game as C, JavaScript and Ruby),
`pack_site_coverage.rb` (the lines of the builder that take a pack handle, read from its source, and which registered game reaches each, for the test that fails when a verb has no game),
`pack_background_tests.rb` (made-up originals whose screen is a background of their own tiles, map and colours, in the Advance's, the Super Nintendo's and the Genesis's layouts, for the verb's tests and the registry; and what the same games hold written out with the pack left out, played by the interpreter and the game as C, JavaScript and Ruby),
`pack_cells_in_front_tests.rb` (a made-up Genesis original whose map marks some cells in front of the sprites, by its own priority bit or as map cells, a sprite under them, and a cell written in front, played by each console whose build draws it, the Genesis, with the refusal each other console's build gives; the games are in the registry too),
`pack_turning_background_games.rb` (a made-up original whose screen is a layer that turns, a map of one byte a cell over tiles of a byte a pixel in a table of 256 colours, a game showing it through a data pack, and the same background drawn by the game, which is its answer key),
`pack_table_tile_background_games.rb` (a made-up Advance original whose screen is a layer of 256 colours that scrolls, more than 256 tiles under map cells or the Advance's own two-byte cells, some turned, a game showing it through a data pack, and the same background drawn by the game, which is its answer key),
`pack_slot_view_games.rb` (a made-up original that keeps one stretch of video memory, sixteen-colour tiles then a turning layer's byte map and its tiles of 256 colours, a game reading it as one slot through views, and the same game with a slot for each part, which is its answer key; for the views' tests and the registry),
`pack_slot_view_pixel_tests.rb` (pixels and tables read through views of that slot, held to the game holding them itself, played by each console that shows a tile of five colours in one 8x8 square: not the Color),
`pack_pose_of_shapes_games.rb` (a made-up Advance original whose frame has a piece of every shape and size the console's sprites come in, and a game showing it as a pose; for the Advance's test against the same pieces painted by hand, and the registry),
`pack_pose_read_by_the_game_games.rb` (a made-up original whose piece names a block of sprite memory counted from the object's own, read by a reader the game writes and given each pose's block, and a game showing one frame for two blocks; for the test against the same pieces painted by hand, the unpacking's records, and the registry),
`pack_background_set_cell_at_start_tests.rb` (a cell of a background from the data pack written with `set_cell` with the pack left out, played by the interpreter and the game as C, JavaScript and Ruby, the games being `test/all/vblank/dsl/test_pack_background_set_cell.rb`'s),
`pack_cell_written_now_tests.rb` (a cell of a background from the data pack written with `set_cell ..., now: true`, held to the same cell written without it, played by each console that writes a cell while it draws: the Advance and the Color),
`pack_backdrop_at_start_tests.rb` (a screen's backdrop taken from a data pack slot with the pack left out, played by the interpreter and the game as C, JavaScript and Ruby, the games being `test/all/vblank/builder/test_pack_backdrops.rb`'s),
`pack_color_list_at_start_tests.rb` (a list of colours declared from a data pack slot with the pack left out, recoloured with, walked and drawn in, played by the interpreter and the game as C, JavaScript and Ruby, the games being `test/all/vblank/builder/test_pack_color_lists.rb`'s),
`pack_pose_at_start_tests.rb` (a pose that is one of the original's frames with the pack left out, played by the interpreter and the game as C, JavaScript and Ruby, the games being `test/all/vblank/builder/test_pack_poses.rb`'s and `test_pack_poses_of_words.rb`'s),
`pack_tile_pose_at_start_tests.rb` (a pose of a set of sprite tiles whose pieces are one of the original's frames, with the pack left out: refused without `size:`, and a frame of the file the set cannot draw all of drawing what it can, played by the interpreter and the game as C, JavaScript and Ruby, the games being `test/all/vblank/builder/test_pack_tile_poses.rb`'s),
`pack_pose_bank_colors_at_start_tests.rb` (a pose in the bank its frame names with the pack left out: a frame of two banks, one sprite facing frames of two banks following each one's list, on the Genesis and on the Color and the Super Nintendo, and a pool following its frames' list told another, played by the interpreter and the game as C, JavaScript and Ruby, the games being `test/all/vblank/builder/test_pack_pose_bank_colors.rb`'s),
`pack_stand_in_size_tests.rb` (what a pose or a background's tiles read as the game starts cost the game written out with the pack left out, which holds none of their pixels however many sprites, sets of colours or cells draw them, measured by the native, JavaScript and Ruby runs, the games being `test/all/vblank/builder/test_pack_pose_bank_colors.rb`'s and `test_pack_tile_pictures.rb`'s),
`pack_pose_of_split_tiles_at_start_tests.rb` (a pose whose frame keeps a tile's number in two places, a layout only `Original::FrameLayout` knows, with the pack left out and with the pack made by its unpacking, played by the interpreter and the game as C, JavaScript and Ruby, the game being `test/all/vblank/builder/test_pack_poses_of_split_tiles.rb`'s),
`frame_record_unpacking_tests.rb` (the frames a game names, each written by its pack's unpacking as a record of VBlank's own, held byte for byte to the pack file the all-in-one build made, played by the interpreter and the game as C, JavaScript and Ruby, which are where an unpacking runs),
`pose_color_list_tests.rb` (one sprite whose poses are drawn from different lists of colours, each pose in its own list's, following those lists, and drawing them all with one other list, a pool's things each on its own, played by each console whose build makes it, with the refusal each other console's build gives; the Advance's keeps one list for a sprite, so not in `test/all/`),
`pack_sound_tests.rb` (recordings that take their samples, and their rate, hold point and envelope, from a data pack slot, all-in-one and with the pack left out, played by the interpreter and the game as C, JavaScript and Ruby, which are where a pack is left out; no cartridge is handed a file, so not in `test/all/`),
`full_depth_sound_tests.rb` (recordings of sixteen bits heard at all sixteen, `full_depth_sound`, played by the interpreter and the game as C, JavaScript and Ruby; no cartridge mixes at sixteen bits, so not in `test/all/`),
`pack_hold_tests.rb` (a recording's hold read from a data pack built all-in-one, a hold of every bit set being none, played by each console that plays an instrument: not the Color),
`pack_scores_at_start_tests.rb` (songs and sound effects whose parts read their notes from a data pack slot with the pack left out, held to the same song written by hand, played by the interpreter and the game as C, JavaScript and Ruby),
`copy_reader_tests.rb`, `packing_gba_tests.rb` and `packing_genesis_tests.rb` (a port's unpacking routine, a format of a port's own, and each platform's packed formats in it, played on the interpreter and the native, JavaScript and Ruby runs, which are where an unpacking runs; no console runs one),
`pair_runs_format.rb` and `back_copies_format.rb` (formats of a port's own written in normal Ruby, game files those tests bring in; `back_copies_format.rb` holds a Ruby answer key and the same format written with `block.variable`),
`genesis_packing_answers.rb` (the answer key for the Genesis's packed formats, decoders written from the 68000 routines and writers of made-up blocks),
`m4a_answers.rb` (the answer key for the Advance's common sound driver, MusicPlayer2000: a made-up song of VBlank's own using each command the reader reads, and a player written from the driver's source),
`settings_root_cases.rb` (where a player's settings folders are, the table the Ruby and C rules are both held to),
`console_bios_cases.rb` (where a player's Game Boy Advance BIOS is found and whether it is used, the same for the Ruby and C rules, with made-up files and a made-up checksum, so no BIOS is needed),
`repaint_games.rb` (a tiled game that holds its scroll still and one that scrolls every frame, for how often each runtime builds the whole view),
`border_frame_tests.rb` (a game laid out for the Color, built for the Advance in a border, as the C, JavaScript and Ruby runs' windows show it: the whole screen, the border round the game's),
`color_screen_tests.rb` (games laid out for the Color with a status bar and `hide_sprites`, played by each console they are for: the Advance in its border, and the Color),
`state_image_tests.rb` (a game's whole state written at a frame and read into a fresh run, which plays on as the unbroken run did, played by the C, JavaScript and Ruby runs, each reading a state across from another),
`runtime_feature_games.rb` (small games that do or do not use a runtime feature, for the native, JavaScript and Ruby runs' tests that a game takes in only the features it uses),
`save_list_move_tests.rb` (a whole list moved to or from save memory as a block, held to the interpreter, played by each console whose lowering moves the block itself: the Color and the Super Nintendo),
`clock_tests.rb` (the clock's tests, played by each console that has one),
`main_volume_tests.rb` (the main volume of all a game's sound, `enable_sound main_volume:`, logged as the sound switches on, played by each console whose chip has one: not the Genesis),
`players_connected_tests.rb` (how many players are connected, played by each console whose build reads one controller: the Advance and the Color),
`two_players_tests.rb` (two people at one console, each on a controller of their own, either's buttons and how many are connected, played by each console whose build reads two: the Super Nintendo, the Genesis and the PlayStation),
`many_players_tests.rb` (games and tests for four and for sixteen players, played by the interpreter and the game as C, JavaScript and Ruby, which read sixteen; no cartridge does, so not in `test/all/`; four on the Super Nintendo's Multitap are `test_snes_multitap.rb`, on the Genesis's Team Player `test_genesis_team_player.rb`, and on the PlayStation's Multitap `test_ps1_multitap.rb`),
`wanderers_tests.rb` (`examples/wanderers.rb` with four players, as a computer builds it, played by the same runs, and as the Super Nintendo, the Genesis and the PlayStation build it, through a Multitap, a Team Player and a Multitap, by `test_wanderers_on_snes.rb`, `test_wanderers_on_genesis.rb` and `test_wanderers_on_ps1.rb`),
`multitap_file_tests.rb` (`examples/wanderers.rb` written to a file and opened with `multitap: true`, four players walking from one tape and, where a comparison plays the console, the file compared with itself, played by `test_multitap_file_on_the_super_nintendo.rb`, `test_multitap_file_on_the_genesis.rb` and `test_multitap_file_on_the_playstation.rb`),
`list_reading_tests.rb` (a game's lists and pools read off a running cartridge, played by each console that has a cartridge),
`list_made_first_tests.rb` (a full list read or written before it is made, played on a cartridge console's own build alone, which must stop the game as the interpreter does: the Super Nintendo, the Genesis, the Color and the PlayStation),
`long_list_tests.rb` (a list of more than 65,535 slots, played by each console with the memory for one: the Advance, of bytes, and the PlayStation, of words),
`probe_by_name_tests.rb` (a probe reading a built cartridge's variables, lists and pools by name, played by the Advance and the Color),
`snapshot_start_tests.rb` (two builds of a walking box compared from late in a tape, `starting_after:`, from snapshots of each console kept on disk, held to the comparison from power-on, played by the Advance and the Super Nintendo),
`probe_snapshot_tests.rb` (a probe opened late in a tape, `starting_after:`, from a snapshot of the console kept on disk, held to a probe stepped there from power-on and counting the frames each stepped, played by the Advance, the Color, the Super Nintendo, the Genesis and the PlayStation; its walking box and tape, `SnapshotWalker`, are `tape_snapshot_tests.rb`'s too),
`tape_snapshot_tests.rb` (`tape.play` and a film's cartridge side started late in a tape from a kept snapshot, held to the same playing from power-on and counting the frames each stepped, played by the same five),
`probe_write_tests.rb` (a probe writing a value into a running cartridge's memory, in its processor's byte order, and saving and restoring the console, played by the Advance, the Super Nintendo, the Genesis and the PlayStation),
`heard_alike_tests.rb` (two builds of one small tune held alike by what each cartridge puts out of its speakers, and a probe reading a frame's samples, played by every console; its `HeardVoiceTests`, chosen voices on each side, by each console whose emulator plays a voice alone: not the PlayStation),
`build_once_tests.rb` (what a cartridge build does once, its plan and its routines, held on each console that builds a cartridge),
`song_instrument_tests.rb` (a song part playing a recorded instrument, played by each console that mixes them),
`gliding_note_tests.rb` (a recorded note bent while it sounds, `glides: true`, played by each console whose build glides one),
`note_envelope_tests.rb` (recorded notes with a loudness shape falling away on their voices, played by each console that mixes them),
`snes_envelope_tests.rb` (an instrument given the Super Nintendo sound chip's own envelope bytes, by hand or from a data pack, played by each console that shapes a recording),
`brr_recordings.rb` (made-up recordings in the Super Nintendo sound chip's own format, BRR, a made-up original holding one, and the answer key they are decoded by, fullsnes's decoder, for the decoder's test, the games every run plays and the Super Nintendo's test against what bsnes plays),
`equal_recording_games.rb` (recordings declared under several names with the same samples, for the test every run plays and each lowering's test that its build keeps them once),
`sound_effect_recording_tests.rb` (sound effects whose parts play a recording, sharing the voices by rank, played by each console that mixes them),
`screen_backdrop_games.rb` (small tiled games for `screen ... backdrop:`),
`draw_order_cost_games.rb` (a game of seven things in a `draw_in_order` and the same without, for each console's cost test),
`sprite_count_cost_games.rb` (many sprites declared and four showing, and a pool of many places holding four, each against the same game of four, for each console's cost test of a sprite not showing),
`list_read_cost_games.rb` (four full lists read at a variable, a mask or a loop's count, and the same game reading none, for each console's cost test of a list read),
`loop_cost_games.rb` (a `repeat` and a counted `while`, setting a variable or reading a list at the count, 64 turns against 32, for each console's cost test of a loop's turn),
`number_width_cost_games.rb` (tests of numbers the build proves small: how far apart two byte slots are, a variable against a number, a half slot shifted down, a table of bytes against a variable, four a pass against the same game with none, for each console's cost test of a narrow comparison),
`narrow_variable_cost_games.rb` (a loop working three variables the build proves stay in 16 bits, 64 turns against 32, for each console's cost test of keeping them in two bytes),
`unsigned_place_cost_games.rb` (a pool whose places, in 256ths of a pixel, stay from 0 to 65535 with `& 0xFFFF`, stepped once a pass, eight things against four, for each console's cost test of keeping them in two bytes read with no sign),
`place_games.rb` (small games of places made of flat faces, played by each console that draws a place),
`pack_place_games.rb` (a made-up computer original keeping a lit room as data, a game drawing it as a place, shading and viewer start from its data pack, and the same room written in Ruby, its answer key; for the registry and the interpreter's test),
`called_routine_area_tests.rb` (a routine called inside an area, played by each console that keeps the area as it runs),
`interrupted_walks.rb` (small games where a timer's handler or a bend calls a routine the game is part way through, and the check that the Advance cartridge finishes them as the interpreter does, for the timer's and the bend's cartridge tests),
`palette_walk_tests.rb` (a fade or tint walked and repeated, played by each console that walks its colours itself),
`see_through_scenery_tests.rb` (a background layer half see-through under a fade or a tint and in a scene of its own, played by each console that mixes it with what is behind: the Advance and the PlayStation),
`layer_over_sprites_tests.rb` (a see-through background over sprites behind it and in front of it, played by the same two),
`pixelate_backgrounds_tests.rb` (the backgrounds in blocks and the sprites as drawn, `pixelate ..., sprites: false`, played by each console whose display shows it: the Advance and the Super Nintendo),
`ruby_answers.rb` (plain Ruby game code run as plain Ruby and as the game, its names compared, for
`test_plain_ruby_answers.rb`) and `ruby_answers_parts.rb` (that suite's Structs and parts, a game file),
`first_pass_presses.rb` (presses counted from a game's first pass, for a game that sets up save
records first),
`power_on_frame_games.rb` (a screen held to a reading of `frames_since_power_on`, built with and without
a long setting up, and what each console's cartridge is held to as its emulator counts frames from
power-on, for the Advance's, the Super Nintendo's, the Genesis's and the PlayStation's tests),
`power_on_profile_tests.rb` (a profile with no frames settled first, and a tape's profile from its first frame, counting the passes the interpreter plays and none below nought, included by the Color's, the Super Nintendo's, the Genesis's and the PlayStation's profile tests),
`no_frames_games.rb` (a small room played for no frames, which ends before the runtime turns the screen
on, for the Super Nintendo's, the Genesis's and the PlayStation's tests of the picture such a run reports),
`speakers.rb` (which speaker a cartridge's voice is heard from),
`film_start_tests.rb` (a film's cartridge side and interpreter side of a moving game, painted, tiled, and tiled with more to set up, held to the same picture from the first pass, played by each console whose cartridge shows the interpreter's pictures pass for pass: the Advance, the Color, the Super Nintendo and the PlayStation),
`heard_film.rb` (a film's sound read back by ffmpeg, each speaker's loudness a film frame at a time, and a game that starts a tone on a known pass, for the film's, the film tasks' and the film shell's tests),
`many_tiles.rb` (backgrounds of many different tiles, for what a console does when they are too many to
hold at once), `scene_sprite_pictures.rb` (scenes whose sprite pictures together are more than a console
holds at once), `scene_color_lists.rb` (lists of fifteen colours, for a Super Nintendo screen's own
eight sets), `scene_color_games.rb` (two scenes whose backgrounds from a data pack and sprites need
more than a Genesis's four palettes together, beside a list every scene uses, the second scene coming
in under a fade to black), and the
helpers a test file shares with its `_on_the_advance.rb` twin (`fade_watch.rb`,
`tinted_handover.rb`) — and are loaded by bare name (`require "differential"`), never
`require_relative`.

## How a test file starts

```ruby
# frozen_string_literal: true

require "test_helper"

class TestThing < Minitest::Test
  def test_it_does_the_thing   # played on every lowering
    ...
  end
end
```

`test_helper` gives every test `Reference`, `SaveImage` (save memory for `Reference.new(save:)`
and the Verifier), `GBA`, `Builder`, `Color`, `ROM`, and `EmulatorSupport`
(`assert_emulator_loads_rom`, `assemble_rom`, `require_emulator!`). Do not re-declare them; a
constant declared in the file wins where it needs the name for something else. Narrower helpers
are opt-in: `include Differential`, `include CostArith`, `include VBlank::IR::Build`.

Commands and which run a change needs are in `runs.md`. One whole run holds the machine at a
time; in a worktree set `VBLANK_SUITE_LOCK=checkout`.

## Ractors — fix what the runner reports

The GBA run, and each run whose record says so (`Testing::Lowering::Run#ractors`), plays the suite
through minitest-ractor, a Ractor per test, and reports every test
that reached state the whole process shares. Those are order-dependent bugs, not noise; make the
code Ractor-friendly rather than silencing the report.

- read from a global or class variable while the test runs → read it once at load, into a constant
- a module's registry, or a lazy `@thing ||= …` → one per Ractor: `Ractor.current[:key] ||= …` or
  `Ractor.store_if_absent(:key) { … }`
- a fixture in a constant → nothing to do; `test_helper.rb` deep-freezes every constant a file
  under `test/` declares, in a test class, a shared helper's module or at the top level
  (`InRactors.share_constants_declared_in`). A game kept in a constant whose block holds game code
  cannot be shared that way: return it from a method instead
- a test made in a loop (`define_method`) → nothing to do; on a run in Ractors a test class, and a
  module of tests a file under `test/` declares, makes it from a shareable copy of its block
  (`InRactors::ShareableMethods`), and every other run keeps the block as written. A game's block
  inside such a test cannot read the loop's variables as game code on that run, so write those
  tests out over one private helper. A module made any other way (`Module.new` in a method, a
  class that is not a test) keeps plain blocks
- an example's constants → require it with `ShareableConstants.require_file(VBlank.root.join("examples/<name>").to_s)`
  (`test/support/shareable_constants.rb`), which freezes what the file defined, so `examples/` stays
  plain Ruby with no `Ractor.make_shareable`

A test that changes the whole process on purpose (registering a font or guardrail, stubbing a
library method, declaring a class, asserting the process's output) says `runs_on_the_main_ractor!`
at the top, with a line saying why. It is not somewhere to park a test nobody has looked at.

Starting a child process is not a reason. A test in a Ractor can start one (zig, node, a program a
build makes, many at once), since `vblank/testing` makes standard output unbuffered. What fails is
reading something only the main Ractor may, such as `RbConfig.ruby`; read it once at load, into a
constant. Older files say a child process "hangs inside a Ractor": that is stale, and such a file
moves into the pool when it is next worked on.

## Which frame's numbers the picture was drawn from

A pixel and a variable read at the same moment are not always the same frame, on every backend
and on real hardware:

- **What the program draws** (`pixel`, `fill_rect`, `draw_rect_at`, `blit`, bitmap `draw_text`)
  is in the picture for the pass that drew it. Picture and variable agree.
- **What the framework draws for you** (a sprite, a tiled text glyph, a background's scroll) is
  painted in the gap before the next frame, from the variables then. So on the Advance the
  picture shows the pass before: `v.var(:n)` is 5 while the sprite stands where 4 put it. The
  Color and the Super Nintendo send them from a copy as the gap ends, so each pass places them before its wait and the
  picture shows the pass just ended (`Console::Description#sprites_placed_before_wait`). A test
  that plays on both says how far behind with `framework_drawing_lag` (one, or none).
- **A picture painted from a list and said `changed now: true`** is the exception: it is
  copied where the game said so, during the pass, and its pixels are in that pass's picture
  (the sprite showing it still stands where the pass before put it).

On the Advance a position decided while a frame is being drawn cannot appear in that frame, so
this is not something to design away. In a test, run `framework_drawing_lag` frames further
before reading the picture, or read the variable that many frames earlier. `test/all/vblank/ir/test_frame_pairing.rb` pins both halves. It only
bites a test that pairs a picture with a variable.

## Building the program under test

- **IR directly**, when the lowering is under test: `include VBlank::IR::Build`, then
  `program(screen(:bitmap), clear_screen(:white), bitmap(:s, width:, height:, pixels:, transparent:), blit(:s, x, y), halt)`.
- **DSL**, when the surface is: `b = VBlank::Builder.new; b.instance_eval { … }; b.finalize_program; b.program`,
  or `VBlank.build("NAME", console: :gba) { … }` for a ROM (pass `out:`/`err:` a `StringIO` to assert
  warnings). A build always names its console. A Builder or a hand-built `program(...)` names none, and each
  run plays it as that run's console.
  Don't write a `code:`: made-up codes collide with real cartridges, which is a build error.

## Choosing test values

Make colours and positions diagnostic: a 4-pixel strip of red, green, blue and white catches a
wrong copy offset or count where a solid fill only proves something drew. For edge clipping,
assert the wrap target (e.g. `(239, y-1)`) is background, since the bug is a row wrapping onto
its neighbour.

## Guardrail tests

Assert the friendly error a misuse raises: its class and a key phrase, never the exact wording.

## A speed check counts work, never seconds

A test that can fail because the machine is busy is a bad test: the suite shares the cores with
itself and with other work. So a check that something is quick enough counts work that load cannot
change, with a budget set from a measured baseline and the reason written beside it:

- on a console, the emulator's cycles, scanlines or frames (`costs.md`);
- in a runtime on the computer, the objects a pass makes (`GC.stat(:total_allocated_objects)`), calls
  into its routines (`LiveGame#count_calls`, which wraps them on that game alone, so a real game pays
  nothing), pixels written, or the shape of what the build prints (`test_ruby_unpacking_pace.rb`);
- in the desktop window's pacing, `--counted-clock`, a clock moved only by the waits it asks for.

Work that must be slow is slow by construction: a pass that waits, or a busy loop whose turns are
measured in the emulator as the test runs (`ps1_pass_work.rb`, `slow_pass_games.rb`), never a turn
count written down, which the next speed-up of the lowering breaks.

A clock may stay only where load cannot fail the test: a bound from below (a run cannot be quicker
than the frames it waits out), or a generous hang guard that a passing run never reaches, with a
comment saying it only catches a hang. Whether Ruby keeps up with the console in real time is a
measurement for a person, outside the suite: `rake speed:ruby`.

## Gotchas

- Read a running game by the names it gave (`var`, `sprite`, `background`, `list`, `pool`,
  `music_volume`, `music_playing`), never by a variable the framework made for itself (`__obj1_x`):
  `test/all/vblank/test_hidden_reads.rb` fails on one, naming the file; a test of the framework's
  own storage goes in its `ALLOWED`, saying why.

- Don't name a helper `run`: it shadows `Minitest::Test#run`.
- `rake test:all` needs zig 0.17 on the path (`mise use zig@0.17.0`) and node 18+, or it stops at
  the start, and SDL3 (`brew install sdl3`): the tests that open a window fail without it.
- Emulator tests fail loudly without the emulator rather than skipping. They live in
  `test/lowering/gba/`, which no other run loads.
