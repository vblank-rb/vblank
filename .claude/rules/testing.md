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
(`Testing::BuildChecks`: the guardrails a build runs, so the console's limits and its answers), with
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
`made_up_original.rb` (the made-up Game Boy Advance original and a game reading it through a data pack, for the data pack, copy reader, packing and shell tests),
`folder_original.rb` (a made-up computer original that is a folder of files, `test/fixtures/folder_original/`, and a port reading it, for the copy, copy reader and shell tests),
`made_up_original_layouts.rb` (made-up originals in each console's layout, and a game reading them through a data pack, for the layout tests and the pack-at-start runs),
`pack_background_tests.rb` (made-up originals whose screen is a background of their own tiles, map and colours, in the Advance's, the Super Nintendo's and the Genesis's layouts, for the verb's tests; and the same games with the pack left out, played by the interpreter and the game as C, JavaScript and Ruby),
`pack_backdrop_at_start_tests.rb` (a screen's backdrop taken from a data pack slot with the pack left out, played by the interpreter and the game as C, JavaScript and Ruby, the games being `test/all/vblank/builder/test_pack_backdrops.rb`'s),
`pack_color_list_at_start_tests.rb` (a list of colours declared from a data pack slot with the pack left out, recoloured with, walked and drawn in, played by the interpreter and the game as C, JavaScript and Ruby, the games being `test/all/vblank/builder/test_pack_color_lists.rb`'s),
`pack_pose_at_start_tests.rb` (a pose that is one of the original's frames with the pack left out, played by the interpreter and the game as C, JavaScript and Ruby, the games being `test/all/vblank/builder/test_pack_poses.rb`'s and `test_pack_poses_of_words.rb`'s),
`pack_strip_font_at_start_tests.rb` (a font cut from a strip that is a picture from the data pack, its pixels or its colours, with the pack left out, played by the interpreter and the game as C, JavaScript and Ruby),
`pack_sound_tests.rb` (recordings that take their samples, and their rate, hold point and envelope, from a data pack slot, all-in-one and with the pack left out, played by the interpreter and the game as C, JavaScript and Ruby, which are where a pack is left out; no cartridge is handed a file, so not in `test/all/`),
`pack_scores_at_start_tests.rb` (songs and sound effects whose parts read their notes from a data pack slot with the pack left out, held to the same song written by hand, played by the interpreter and the game as C, JavaScript and Ruby),
`copy_reader_tests.rb`, `packing_gba_tests.rb` and `packing_genesis_tests.rb` (a port's unpacking routine, a format of a port's own, and each platform's packed formats in it, played on the interpreter and the native, JavaScript and Ruby runs, which are where an unpacking runs; no console runs one),
`genesis_packing_answers.rb` (the answer key for the Genesis's packed formats, decoders written from the 68000 routines and writers of made-up blocks),
`settings_root_cases.rb` (where a player's settings folders are, the table the Ruby and C rules are both held to),
`console_bios_cases.rb` (where a player's Game Boy Advance BIOS is found and whether it is used, the same for the Ruby and C rules, with made-up files and a made-up checksum, so no BIOS is needed),
`repaint_games.rb` (a tiled game that holds its scroll still and one that scrolls every frame, for how often each runtime builds the whole view),
`state_image_tests.rb` (a game's whole state written at a frame and read into a fresh run, which plays on as the unbroken run did, played by the C, JavaScript and Ruby runs, each reading a state across from another),
`runtime_feature_games.rb` (small games that do or do not use a runtime feature, for the native, JavaScript and Ruby runs' tests that a game takes in only the features it uses),
`save_list_move_tests.rb` (a whole list moved to or from save memory as a block, held to the interpreter, played by each console whose lowering moves the block itself: the Color and the Super Nintendo),
`clock_tests.rb` (the clock's tests, played by each console that has one),
`players_connected_tests.rb` (how many players are connected, played by each console whose build reads one controller: the Advance, the Color and the Genesis),
`many_players_tests.rb` (games and tests for four and for sixteen players, played by the interpreter and the game as C, JavaScript and Ruby, which read sixteen; no cartridge does, so not in `test/all/`),
`wanderers_tests.rb` (`examples/wanderers.rb` with four players, as a computer builds it, played by the same runs for the same reason),
`list_reading_tests.rb` (a game's lists and pools read off a running cartridge, played by each console that has a cartridge),
`probe_by_name_tests.rb` (a probe reading a built cartridge's variables, lists and pools by name, played by the Advance and the Color),
`heard_alike_tests.rb` (two builds of one small tune held alike by what each cartridge puts out of its speakers, and a probe reading a frame's samples, played by each console whose emulator hands its sound over),
`build_once_tests.rb` (what a cartridge build does once, its plan and its routines, held on each console that builds a cartridge),
`song_instrument_tests.rb` (a song part playing a recorded instrument, played by each console that mixes them),
`note_envelope_tests.rb` (recorded notes with a loudness shape falling away on their voices, played by each console that mixes them),
`snes_envelope_tests.rb` (an instrument given the Super Nintendo sound chip's own envelope bytes, by hand or from a data pack, played by each console that shapes a recording),
`equal_recording_games.rb` (recordings declared under several names with the same samples, for the test every run plays and each lowering's test that its build keeps them once),
`sound_effect_recording_tests.rb` (sound effects whose parts play a recording, sharing the voices by rank, played by each console that mixes them),
`screen_backdrop_games.rb` (small tiled games for `screen ... backdrop:`),
`draw_order_cost_games.rb` (a game of seven things in a `draw_in_order` and the same without, for each console's cost test),
`place_games.rb` (small games of places made of flat faces, played by each console that draws a place),
`called_routine_area_tests.rb` (a routine called inside an area, played by each console that keeps the area as it runs),
`palette_walk_tests.rb` (a fade or tint walked and repeated, played by each console that walks its colours itself),
`first_pass_presses.rb` (presses counted from a game's first pass, for a game that sets up save
records first),
`speakers.rb` (which speaker a cartridge's voice is heard from),
`many_tiles.rb` (backgrounds of many different tiles, for what a console does when they are too many to
hold at once), `scene_sprite_pictures.rb` (scenes whose sprite pictures together are more than a console
holds at once), `scene_color_lists.rb` (lists of fifteen colours, for a Super Nintendo screen's own
eight sets), and the
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

The GBA run plays the suite through minitest-ractor, a Ractor per test, and reports every test
that reached state the whole process shares. Those are order-dependent bugs, not noise; make the
code Ractor-friendly rather than silencing the report.

- read from a global or class variable while the test runs → read it once at load, into a constant
- a module's registry, or a lazy `@thing ||= …` → one per Ractor: `Ractor.current[:key] ||= …` or
  `Ractor.store_if_absent(:key) { … }`
- a fixture in a constant → nothing to do; `test_helper.rb` deep-freezes every constant a test
  class declares

A test that changes the whole process on purpose (registering a font or guardrail, stubbing a
library method, declaring a class, asserting the process's output) or starts a child process
(which hangs inside a Ractor) says `runs_on_the_main_ractor!` at the top, with a line saying why.
It is not somewhere to park a test nobody has looked at.

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
