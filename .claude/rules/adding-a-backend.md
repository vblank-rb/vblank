---
paths:
  - "lib/vblank/ir/backends/**"
  - "test/all/vblank/ir/backends/**"
---

# Adding a backend

How to add the next lowering (a terminal one is the likely one): what every backend has to do,
where it plugs in, what it is checked against, and the traps. C-only decisions are in the comment atop
`Backends::Native`, JavaScript-only ones atop `Backends::JS`, not here.

## What a backend is

A backend takes an IR tree (`IR::Node`, built by the DSL and checked by `IR::Verifier` and the
guardrails) and either runs it or writes it out as something else that runs. It knows nothing the
IR does not say: the IR is target-neutral, and a backend never reaches back into the DSL or the
builder.

The backends:

- `Backends::Reference` runs the tree in Ruby. **It is the answer key**: what a program means is
  what Reference does with it. It is named for that role, not for its language, and it is never
  made faster at the cost of being plainly correct: a game played fast in Ruby is
  `Backends::Ruby`'s job.
- `Backends::GBA` lowers the tree to ARM and a cartridge.
- `Backends::Native` writes the tree out as C, built by zig into a desktop program.
- `Backends::JS` writes the tree out as JavaScript, for a web page, and for node in the tests.
- `Backends::Ruby` writes the tree out as Ruby, played by a runtime written in Ruby.
- `Backends::GBC` lowers the tree to SM83 code and a Game Boy Color cartridge (MBC5).
- `Backends::SNES` lowers the tree to 65816 code and a Super Nintendo cartridge (LoROM), played in bsnes
  (ruby-snes-emulator) to check it.
- `Backends::Genesis` lowers the tree to 68000 code and a Sega Genesis cartridge, played in Genesis Plus GX
  (ruby-genesis-emulator) to check it.
- `Backends::PS1` lowers the tree to R3000 (MIPS) code and a PlayStation program (a PS-X EXE), played in
  Beetle PSX (ruby-ps1-emulator) to check it.

## A second console

A console of its own needs, beyond a lowering:

- **A description** (`Console::Description`, `Console.described(:gbc)`): its screen size, what it
  can blend, how long a frame is, the rates its mix of recordings can run at
  (`Console::SampleClock`), the most one pool can take, and the rest a game or the interpreter
  asks of a console. A game says which consoles it is for (`consoles: %i[gba gbc]`) and reads
  `screen_width` and `screen_height` rather than writing 240 and 160. The builder and the
  interpreter read these from the program's console and never from one console's hardware
  file (`Console::Hardware` is the GBA lowering's), so the answer key and the cartridge agree
  about what the console cannot do (a fade the Color does not blend is walked colour by colour,
  `IR::Fading`). What every backend must count alike, a fade's steps and a pixelate's biggest
  block (`Backends::FadeSteps`, `Backends::Blocks`), is written there once, and a console's
  lowering is checked against it.
- **An answer for every verb** (`Console::ColorAnswers`; every console has one, the Advance's
  `Console::AdvanceAnswers` included, and `Console::Answers` says what an answer is): it works, or
  it is refused in plain words naming the hardware the console lacks. Nothing is shown differently.
  The guardrail check (`Checks::ConsoleAnswers`) gives those answers at build time for whichever
  console the build is for, working out which part of a verb a line asks for from the console's
  description (its buttons, whether it blends, turns a background or turns a sprite). Each
  console's page under `.claude/dsl/` is generated from its table (`tools/console_answers.rb`),
  so the docs cannot drift from it. The checks that count something the console has — layers,
  sprites, sprites on a row — read the number from its description.
- **Its own cartridge and profiler** (`Cartridge::GBCROM`, `Diagnostics::GBCProfiler`): the
  Advance's never learn about it.
- **Its questions for the one reader** (`Diagnostics::ColorReading`). `Diagnostics::Verifier` plays
  every console's cartridge back and reads the picture, memory, variables, save memory and sound
  the same way for each; what a console keeps its own way (whose each sprite is, how it counts its
  passes, how its colours are laid out, where its save memory ends in the emulator's file) is a
  module the reader takes on when it is made over that console's cartridge. A question a console's
  cartridges cannot answer is not in its module, so a reader over one of them does not have it: a
  Color reader has no `registers` at all. No reader subclasses another's.
- **A kit naming all of it** (`Console::Kit`, `Console.for(:gbc)`, in `console/kit.rb`): its
  description, its answers, the build that makes its cartridge (`Cartridge::LoweredBuild`, the one
  every console but the Advance shares, handed a `Cartridge::BuildRequest`), the cartridge kind,
  its lowering and checked run (`Console::CheckedKit`), its part of the reader (`reading`), and whether its
  builds are measured. The build, the reader, the cartridge-file reader and the command line ask the kit, so a
  console is added by describing it and giving it a kit. Nothing outside a console's own code
  compares console names (`test/all/vblank/console/test_kit.rb` fails the build if something does).
- **The desktop, web and Ruby builds are made as any console.** The C, JavaScript and Ruby runtimes
  read what they need of the console from numbers written ahead of them when the game is built
  (`Computer::ConsoleNumbers`, `JS#console_text`, `Ruby::Lowering#console_text`): its screen size, its
  frame's length, whether it blends, whether its cartridge has a motor and whether its clock keeps
  the date. The rest the lowering decides from the program's console, as the interpreter does (the
  game loop's order, `IR::Frames.loop_in_console_order`). Those runs play the suite once for each
  console (`Lowering::Run#plays_any_console?`), which is how a gap between a runtime and the
  interpreter on that console is found; `CONSOLE=gbc` keeps only the runs playing as one.
- **No console by default.** A game names its consoles, a build (`VBlank.build(..., console:)`)
  and a Rakefile (`t.consoles`) name theirs, and a name is held as its Symbol however it was
  written (`Console.named`). Only an unbound program, a tree built for a test (a Builder told
  none, a hand-built `program(...)`), names none, and each run plays it as that run's console.
  Outside a test such a program stops with plain words when something lays it out; inside one the
  test kit lays it out for the Advance's screen (`Testing::LaidOutForTheAdvance`).

`GBC::Lowering` is a peer of the GBA lowering, not of the native one: it walks the IR and emits
SM83 machine code itself (its picture and sound in `GBC::Lowering::Picture` and
`GBC::Lowering::Sound`), through the Ruby assembler (`GBC::SM83`), calling a runtime written in
SM83 the same way. The comment atop `Backends::GBC` says the rest.

**What the cartridge lowerings share, and what they do not.** The Color's and the Super Nintendo's
lowerings each write machine code for a processor of their own, and that code, the runtime it
calls and where the console keeps things are each lowering's alone. Everything they decide before
writing an instruction is shared, because two copies of a decision drift apart:

- `Backends::LoweringPlan` — what a run reaches, the numbers timers and scenes are known by, how
  each table is kept, constant folding, the game loop in the console's order, and the refusals
  every console makes alike (a step only the Advance has, what the console's answers refuse, a
  routine that calls itself).
- `Backends::ControlFlow` — the loops, tests and choices between scenes (`if`, `loop`, `repeat`,
  `every`, `after`, `case`): where each label goes and which way each jump points. It is mixed into
  the lowering and calls a dozen things of it written in that processor's instructions (a fresh
  label, a jump, a jump unless a condition holds, a load, a store), which the comment atop the module
  lists. `test/all/vblank/ir/backends/test_control_flow.rb` walks it over a chip that only writes
  down what it was asked for.
- `Backends::BuildCache` — what a build works out from the program alone, once for all its tries:
  the plan, the handover, the stacking, each picture's pixels, and the lowering's own memos (its
  `BuildFacts`). A console's build makes one per build (`BuildCache.for`) and hands it to each try.
- `Backends::RoutineCuts` — making each routine once and cutting one too big for a bank into parts;
  the lowering says how big its bank is (`MOST_ROUTINE_BYTES`, `RETURN_BYTES`), measures its own
  code, and says what it holds (`LOWERING_STATE`, a `Backends::LoweringState`) so a routine found
  too big can be taken back.
- `Backends::Sections` — what an assembler's section is, first-fit placing of sections in banks,
  and the words for a cartridge too full for the game. Each linker keeps its bank geometry and how
  it fills in a hole.
- `Backends::SpritePieces` — a sprite picture cut into 8×8 squares, blank ones left out, or
  covered by rectangles of them for a console whose sprite entry draws one (the Genesis's, up to 4×4).
- `Backends::SongTable` — a game's songs and effects as the table a player reads, for the Super
  Nintendo and the Genesis. Each subclass says its chip writes and its limits; each player stays its
  own. The Color's table is another shape and is not one of them.
- `IR::Tunes.ranks_in_order`, `Backends::FadeSteps` — the order sound ranks are kept in, and a
  fade's steps.
- `Backends::PaletteWalk` — a fade or tint that walks the colours: what the runtime is handed
  (toward what, the colour, the steps held to their range) and the rules its runtime keeps (said
  the same, it does nothing; worked out as the pass ends, sent in the blank).

A third console that sees its cartridge a bank at a time starts from these. A decision found
written in two lowerings goes here rather than being fixed in each.

Reading such a cartridge back as it plays is shared the same way. `Backends::CartridgeHeadlessRun`
is what both consoles' headless runs are: the interpreter's calls, the pass-by-pass loop, the
buttons decided a frame at a time, the lists read back, and the words for a fault, whose number is
one table for every console (`Backends::CartridgeFaults`). A console's run says only how its memory
is read, how its runtime keeps its state and its fault, its picture, and what else it can answer
(the sound, the clock). `test/all/vblank/ir/backends/test_cartridge_headless_run.rb` holds each to
every public method of the interpreter. Where a runtime keeps a list's header stays its own.

**Adding a console, what is still written by hand.** A console is one kit and one lowering; the
build, the test run's player (`Testing::CartridgeCheckedPlayer`, made from the kit), the
`skip_on_<name>` helper, the run's own test folder, the Rakefile's console list, the players the
suite test holds to the interpreter's words, and the command line's console choices, its
`--<name>` flag, `compare` and `inspect` all read the kits and the run records. What is left:

- its description (`console/description.rb`), its hardware file, and its answers table;
- its kit, a `Console::CheckedKit` subclass in `console/kit.rb`, and its entry in `KITS`;
- its lowering, with a `CheckedRun` and a `HeadlessRun` on `CartridgeHeadlessRun`;
- its cartridge class (`Cartridge::GBCROM`), its part of the reader (`Diagnostics::ColorReading`),
  its emulator's opening (`Kit#open_core`), and its profiler;
- its run's record in `Testing::Lowering::RUNS` (with `player: nil`), and in the Rakefile a task
  that builds its emulator core if it plays in an emulator of its own;
- `Testing::Pictures::LINE_UPS`, once the one cartridge reader plays its cartridges;
- the CI workflow's shell, and its page under `.claude/dsl/` (generated from the answers).

## Start from the computer builds' statements

`Computer::Lowering` does not write text: it builds a small tree of statements (`Computer::Statements`) —
globals, routines, constant tables, and calls into a runtime — and a printer turns that into the
build's language (`Native::Printer` for C). There is no operator anywhere in it (every number goes through a runtime function
that does what `IR::Int32` does), so nothing in it is C's alone. The JavaScript lowering is that
same tree printed by `JS::Printer`, and a runtime (`js/runtime/*.js`) that is the native one's C
written again, function for function: `JS::Lowering < Computer::Lowering`, as
`Native::Lowering` is. Everything that decides
what a program says — which art is worked out in Ruby, which kinds are not lowered yet — is then
said once, and the two lowerings can only differ in how a runtime does a thing, which the checked
run finds.

A new lowering for a computer that can run a runtime of that shape should start there too, and
only write a lowering of its own when the tree cannot say what its machine needs.

**A drawing feature only some games use is a runtime feature, not more of `rg_screen`.** It is a
folder under `lib/vblank/ir/backends/runtime_features/<name>/` with its C, JavaScript and Ruby side
by side and a `feature.rb` naming the kinds of step that need it and the hooks it takes
(`RuntimeFeatures`, whose comment says how each language takes it in). The screen calls only the
hooks and names no feature; a game whose steps never need it builds without it. A feature needing a
hook the screen does not have adds the hook: a line in `RuntimeFeatures::HOOKS` and its C
signature, the call in each screen file (with its prototype atop `rg_screen.c`), and its C default
(`rg_screen_hook_defaults.h`). Pixelation is the worked example.

**A new console's lowering is written fresh, its own code generator in Ruby.** This is the
operator's standing rule. Never retarget the native C lowering at a console through a cross-compiler, and never bend
one lowering to serve two consoles: a build for a console needs nothing outside Ruby, and every
routine it emits is ours to profile and change. Code two lowerings share is found and factored out
afterwards, from lowerings that exist, the way `LoweringPlan`, `BuildCache` and `RoutineCuts` were.
A design pass for a console does not offer the C route as an option.

**A console's lowering draws the way that console's hardware draws, and is not bent toward the
other consoles' picture.** The operator's standing rule. What a game does — its numbers, where things are, which face is in front,
`screen_spot` — stays exact against the interpreter. The picture is checked exactly against a model
of that console's own drawing (for the PlayStation, `PS1::PolygonFill`, Beetle's fill in Ruby), and
where drawing the console's way puts a pixel somewhere other than the interpreter's picture, that
is the console's picture, not a mismatch: it is neither worked off at a cost in speed nor brought to
the operator as a choice. Pick the way the console's own games drew, and make it fast.

**A lowering replaces a shared piece only with a measured reason, written down where the
override is, and every override is listed in one place a test checks.** The operator's standing
rule. Work shared in the IR or a shared module is the
default for every lowering. A lowering that does the same job its own way says so beside its code,
with the measurement that makes its way cheaper on its console, and names itself in the list, so
"which consoles do this their own way, and why" is answered in one place. An override changes only
how a console reaches the answer, never the answer: the checked runs hold every lowering to the
interpreter (and the picture to the console's own model), so a wrong override fails its run. When a
shared piece is improved, the list shows which consoles do not get the improvement and must be
measured again. The same job written more than once with no entry in the list is drift, and is
filed as a bug.

A new backend is named for the platform it targets (`JS`, not `Canvas` or `V8`), lives in
`lib/vblank/ir/backends/<name>.rb` beside a folder of the same name, and is required from
`lib/vblank/ir/backends.rb`.

## Checked by running, never by output

A backend is right when a game played on it does what the same game does on Reference: the same
variables, lists, pool fields, picture, sprites, sound log and mixed sound, on every frame.
Native is held to that by `Native::CheckedRun` (with `Computer::Check`): it plays the game as C, plays the same buttons on
Reference, and fails at the first frame the two differ. Nothing compares generated code against
code somebody wrote down; a test of a backend's own output (the ARM it emits, the C it writes)
is the exception, and lives in that backend's own test folder.

What a new lowering needs for this, following Native:

- a **headless run** that takes the interpreter's calls (`hold`, `input_each_frame`,
  `each_vblank`, `run(program, frames:)`, `[]`, `vars`, `screen.pixel`, `sprites`, `list`,
  `pool`, `audio` and the rest a test reaches for), so a test written against Reference plays
  the game on it unchanged (a subclass of `Computer::HeadlessRun`, as `Native::HeadlessRun` is);
- a **checked run** that plays it and then Reference on the same buttons and compares every
  frame (`Computer::Check`, with the comparisons in `Computer::Differences`, and a `CheckedRun` of its own, as `Native::CheckedRun` is);
- what it cannot answer yet raises by name (`HeadlessRun::CannotAnswer`), never guesses.

## The contracts every backend honours

- **`IR::Int32` is the arithmetic.** Signed 32-bit two's complement, wrapping. Every value
  operation a backend does maps onto one of its functions, and nothing else does arithmetic on a
  game's numbers. Native writes them as C functions in `runtime/rg_int32.h` and never uses a C
  operator on a game's number; a JavaScript backend, whose numbers are 64-bit floats, needs the
  same discipline (`| 0`, `Math.imul`, explicit wrapping), or it agrees with the others until the
  first number wraps.
- **Console-only kinds are refused up front.** `IR::Portability` tags each kind `:portable` or
  `:hardware_only` (`raw` and `read_scanline` today). A backend that cannot run one refuses a
  program that can REACH one, before writing anything, with a plain message
  (`Computer::Lowering#refuse_unlowered_kinds!`). A hardware-only step in a routine nothing calls
  is not refused: it never runs, and Reference does the same.
- **Dispatch is one method per kind, called by name in a `case`.** Reference lists its kinds in
  `STATEMENT_KINDS` and `VALUE_KINDS` and calls each kind's method in a written-out `case`
  (`#exec_by_kind`, `#value_by_kind`); every lowering does the same, a part file (Picture, Sound)
  keeping its own kinds and its own `case`, so a missing kind is one line to find and a call is
  found by its name. Never `send` a method name read from a table. A kind it cannot do yet goes on a list
  of its own (Native has `NOT_LOWERED_YET`, empty now), held by a coverage test
  (`test/lowering/native/vblank/ir/backends/native/test_native_kind_coverage.rb`) so every kind is either done
  or listed. `test/all/vblank/ir/test_kind_coverage.rb` holds Reference and the GBA lowering to
  every kind the same way.
- **The conformance fixture.** `test/conformance_fixture.rb` is one program that touches every
  kind and every operator. `test/console/gba/vblank/ir/test_cross_backend_conformance_on_the_advance.rb`
  plays it on the lowering under test (`test_the_lowering_under_test_plays_the_whole_fixture`) on
  every run that plays games as the Advance, since its song sounds a recording, which the Color
  refuses; a new lowering joins that test rather than getting a copy of it.
- **`Node#source`** is the DSL line that made a node (`"file.rb:12"`), where the builder knew it.
  Keep it in what you write out, so an error in generated code points at the game.

## Semantics a backend gets wrong without noticing

Each of these is what Reference does; check the line before relying on it.

- **`and` and `or` evaluate both sides.** No short-circuit, unlike `&&` in C and JavaScript.
  Reference evaluates both operands before `eval_binop` combines them; Native calls
  `rg_both`/`rg_either` on two evaluated values.
- **`case` reads its variable once**, before the first clause, and runs every clause whose value
  matches (`Reference#exec_case`). A scene that sets the variable to the next scene must not
  start that scene in the same pass.
- **`repeat` evaluates its count once** and checks `stop_when` BEFORE the body, so a loop already
  finished on its first pass runs nothing (`Reference#exec_repeat`).
- **Dividing by zero gives 1, or -1 for a negative numerator**, and `%` by zero gives the number
  back (`Int32.div`, `Int32.quotient_by_zero`). The game does not stop. `/` truncates toward zero
  and `%` takes Ruby's meaning (the sign of the divisor), so the two do not decompose on negatives.
- **Shifts by 32 or more empty the number**, and a negative count does too, rather than turning
  round (`Int32.shift_left`, `Int32.shift_right`).
- **A list index out of range stops the game with an error** on Reference
  (`IR::ProgramError`); Native ends with `RG_GAME_WENT_WRONG` and the same words. **A table index
  never does**: a power-of-two length wraps it, any other clamps it to the ends.
- **A narrow list slot keeps the low bits and reads back sign-extended**: 200 in a `:byte` slot
  reads -56 (`Reference::ListValue#wrap_to_width`).
- **A frame can end anywhere.** `wait_vblank` may sit deep inside a routine, in a loop, in a
  scene called from a scene: the runtime has to take a frame from the middle of a call and come
  back to it (Reference's `advance_frame` runs synchronously inside `exec_wait_vblank`). The C,
  JavaScript and Ruby lowerings make every routine that can reach a wait resumable
  (`Computer::Resumable`): cut into numbered steps, its step and locals in globals of its own, a wait
  giving back 1 up the chain to a driver that calls `rg_game_main` once a frame. So between frames
  the place the game has reached is in its globals, which a save state writes; a routine that never
  waits stays as it was.
- **`halt` never returns.**

## Joining the test runs

`rake test:all` plays the suite once for each lowering; a new one is a ninth run.
`VBlank::Testing` (lib/vblank/testing/) is where that is decided, and it is the same code a
game's own suite uses:

- **Each lowering's run is one record**, `Testing::Lowering::Run` in `Testing::Lowering::RUNS`:
  its name (what `VBLANK_LOWERING` picks), its title, the console it plays a game as, whether it
  is checked, what `rake -T` says it does, the program it needs, and its player. A new lowering
  is a record there.
- `VBlank::Testing#game_player` hands a test the record's player: Reference on the GBA run,
  the checked player on the native, JavaScript, Ruby and Game Boy Color ones. A checked player raises
  `IR::Backends::RunComparison::Disagreement` when it disagrees with the interpreter, which the
  testing kit turns into a failed test.
- `Testing::TestTask` says how a run is started (every checked one in several processes, never in Ractors, since they start programs); `Testing::RakeTasks` makes `rake test:all` and a
  `test:lowering:<name>` task for each.
- `TestSuites::LOWERING_FOLDERS` (test/support/suites.rb) names the folders only one lowering's
  run loads: put the new backend's own tests in `test/lowering/<name>/`. `TestSuites::CONSOLE_FOLDERS`
  names each console's, loaded by every run that plays games as it.
- **What a checked run does differently** is asked as `Testing.checked?`, which a new lowering
  joins through its record's `checked`: `require_emulator!` in `test/test_helper.rb` (a test of the
  cartridge skips on every run but the GBA one), `Testing::Pictures` and `test/mixed_sound.rb`
  (on a checked run they compare the lowered game instead of the cartridge), and the process
  runner `Testing::TestTask` starts such a run with. A test skips on one run with
  `skip_on_lowering(:name, why)` (`skip_on_native`, `skip_on_js`, `skip_on_ruby`, `skip_on_gbc`
  `skip_on_snes`, `skip_on_genesis` and `skip_on_ps1`
  are its seven), and the lowering's test folder goes in `TestSuites::LOWERING_FOLDERS`.
- **`Testing::Pictures` plays the cartridge of the program's console**, which that console's
  kit builds (`builder.cartridge_for`) and the one reader reads back, so a new console's programs
  are compared pixel for pixel once its kit names them.
- **Reuse the computer builds' checked run.** `Computer::HeadlessRun` reads a program that prints
  runtime/rg_headless.c's lines, and `Computer::Check` compares it with the interpreter; a
  windowless program of the new lowering that prints the same lines is read and checked by
  them, through a subclass that says how its program is built and run (`Native::HeadlessRun` and
  `Native::CheckedRun`, `JS::HeadlessRun` and `JS::CheckedRun`, `Ruby::HeadlessRun` and `Ruby::CheckedRun`;
  `Computer::ProgramRun.run` runs the program).

## What done means

A backend is done when every test plays on it and `rake test:all` passes: there is no lowering that
trails. On the way there, a test it cannot play yet skips itself with a reason
(`skip_on_native` is native's version), and the run counts its skips by reason at the end so
they cannot pile up. A hardware feature is not done until it works on every backend; when one is
on the radar, record each backend's slice as its own piece of work.
