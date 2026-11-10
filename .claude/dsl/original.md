# DSL reference: Data from the original (the data pack)

The whole story of `data_pack`, listed on `tables.md`. The map of every page is `.claude/rules/dsl-reference.md`.

A port of a retail game may not ship that game's data. It names the original (`VBlank::Original::Game`,
which finds the player's copy and checks its SHA-1) and reads what it needs from a **data pack** made
from that copy. The game's code says each piece's shape and size; it never depends on the bytes.

- `data_pack from: ORIGINAL, version: "1.0" do |slots| … end` → a `DSL::DataPack`. `from:` is an
  `Original::Game` (its `copy` is asked for) or an `Original::Copy`. `version:` is required: it names this
  build of the game in the pack's header, so a player's pack is made again when the game's data changes.
  Inside the block, each line is a slot:
  - `slots.colors :palette, at: 0x1000, count: 16` — colours, two bytes each.
  - `slots.tiles :walls, at: 0x1020, count: 40` — 8x8 tiles; `colors: 4` or `colors: 16` where the
    console keeps both (the Super Nintendo).
  - `slots.numbers :speeds, at: 0x2000, count: 8, width: :byte, signed: false` — numbers one, two or four bytes wide; `signed:` must be said.
  - `slots.pixels :walls, count: 64 * 64 * 106` — **pixels, one byte each**: pictures of up to 256
    colours, row by row, as a computer game keeps its art. A byte is a byte in every layout, so the line
    names none. How the original lays its art out (column by column, in posts, in pages) is the game's
    to undo in its unpacking routine, which writes the slot row by row (`pack[:walls][i] = place`);
    VBlank reads no one original's format.
  - `slots.samples :sounds, count: 4096` — **recorded sound, one byte each, 8-bit signed**, for a recording's
    `pcm:` (`instrument :pistol, pcm: pack[:sounds].samples(first, count), rate: 7000`, or `sample :bang,
    pcm: pack[:bang], rate: 7000` for a whole slot). `rate:` is required, since a sound's speed is not in its
    bytes. With the pack left out the build holds zeros of the recording's length and the runtime fills them
    at power-on from the start file, so every verb a recording plays in (`play`, songs, sound effects)
    works in a shell. A recording given as `pcm:` bytes beside it stays as it was. Worked example:
    `test/pack_sound_tests.rb`.

  Any slot may name `cost: 4`: how many times the work of a plain copy one byte of it takes to unpack
  (a whole number, 1 or more; 1 when not named). It changes only the shell's progress bar (below):
  a slot's share of the bar is its bytes times its cost, so a slot the routine renders slowly moves the
  bar as slowly as the routine works. A slot the routine fills moves the bar only by what
  `copy.count_written ..., into:` counts for it. A pack where every slot costs 1 shows the bar by
  bytes, as before.

  Each is in the layout of the original's platform (below) unless the line names another, `layout: :gba`.
  A computer game's numbers (`platform: :pc`) are low byte first, as DOS and Windows games keep them,
  unless the line names its byte order: `byte_order: :high_first` (or `:low_first`). A line naming both a
  console's layout and a byte order is refused, since the layout already says it.

- `image :walls, width: 64 * 106, height: 64, colors: WALL_COLOURS, places: pack[:walls], see_through: 255`
  — **a picture of up to 256 colours from a slot of pixels.** `places:` is the whole slot, or
  `pack[:walls].pixels(first, count)` for one picture of several kept in it; `width:` times `height:` must
  be its count. `colors:` is a list of 1 to 256 colours, place 0 first, which the game gives (the
  original's colours often live in its program, not its data), or a slot of colours of the pack.
  **Place 0 is a colour like any other**; `see_through:` names the one place that is not drawn, or is
  left out so every place is drawn. It draws as a picture given `data:` does, by every verb: `blit`, a
  sprite, `draw_column_at` (stretched columns), `mirror`, `upside_down`. Friendly errors at the line: a
  pixel of a place past the colours (unless it is the see-through place), a size that is not the slot's
  count, a `see_through:` that is not 0 to 255, and any other option. With the pack left out (below) its
  pixels are filled from the file as the game starts, its colours held in the program. On a console it
  is a picture of that many colours, so what the console does with one given `data:` it does with this.
  Worked examples: `test/all/vblank/builder/test_data_packs.rb` and `test/pack_at_start_tests.rb`.

  **Releases that keep the data at different places**: a slot's `at:` may be a Hash by release name,
  `slots.colors :palette, at: { "US" => 0x10, "EU" => 0x30 }, count: 16`. The keys are the release names
  as the original lists them, Strings. Name every release the game reads. Do not name a release that
  the original does not list. If you do, the build stops (`BuildError`) and names the problem. The slots'
  shapes, sizes and order stay one list for every release; only where each comes from differs. The
  unpacking routine's block may take a third argument, `do |copy, pack, release|`: the release's name as a
  plain String when the game is built, so Ruby picks places per release (`shift = release == "EU" ? 0x40 : 0`).
  Each readable release gets an unpacking program of its own in a shell (`DSL::DataPack#unpacking(release:)`).
  The shell picks it by the picked file's SHA-1. An all-in-one build uses the release of the copy it was given. A port with one release and plain numbers builds as before.

  A game has one `data_pack`. A slot with no `at:` is filled by the unpacking routine (below); a slot with
  no `at:` and no routine is refused.
- **The unpacking routine**: `slots.fill_from_copy do |copy, pack| … end`, one per pack. It is **game
  code**, a program of its own (`Original::Unpacking`), so the same routine fills the pack as the game is
  built (played to its `halt` on the interpreter) and on the player's machine (see "With the pack left
  out" below). The
  slots with `at:` are copied first, then the routine runs. Inside it, normal Ruby works as in a game block
  (`while` on a number read from the copy is a loop in the routine), and:
  - `copy.byte(at)` (0 to 255), `copy.half(at)`, `copy.word(at)`: low byte first; `big_endian: true` for
    high byte first. `at` may be worked out as the routine runs.
  - `copy.copy_bytes at:, count:, into: pack[:walls], start: 0` — bytes as they are.
  - `copy.unpack_<format> at:, into:, start: 0` — a block in a packed format. The copy offers the formats
    of the platform its original is for, and any the port names in `data_pack ..., formats: [MyFormat]`;
    asking for another is refused, naming the ones it offers. An Advance original's are
    `copy.unpack_lz77` and `copy.unpack_rle`, the BIOS's LZ77 and RLE (4-byte header: the scheme in the
    first byte's top half, 1 or 3, then the unpacked size; `BiosCompress` is the answer key). A Genesis
    original's are `copy.unpack_nemesis` (tiles, 32 bytes each in the Genesis's layout; the block's first
    word says XOR mode and the tile count) and `copy.unpack_enigma ..., base: 0` (a plane map, each cell a
    word high byte first with `base:` added, ending at its own end mark; NOT the usual reading: a spelt
    cell carries only the two flip bits, as the 68000 `EniDec` of retail games reads it). Their answer key
    is `test/genesis_packing_answers.rb`, written from the 68000 routines. A computer original (`:pc`) has
    none built in.
  - `pack[:walls][i] = value` writes one byte (the low 8 bits); `pack[:walls][i]` reads one back;
    `pack[:walls].byte_size`. **On a slot of numbers `width: :half` or `:word`, `i` is a number, not a
    byte**: `pack[:homes][wall] = cell` writes number `wall` over its two or four bytes, in the slot's
    layout's byte order (low byte first on `:gba`, high byte first on `:genesis`), and `pack[:homes][wall]`
    reads it back, below zero where a slot of halves is `signed: true`. A word is a whole game number,
    so one above 2147483647 reads below zero even in a slot `signed: false`. A number past the slot's
    count, at a place written in the routine, is refused at the line, for a read or a write; a write at a
    place worked out as the routine runs stops the build, and a read there is not checked. A copy's formats
    (`copy_bytes`, `unpack_*`, `start:`) still write bytes. `copy.count_written n` counts what a loop of the
    routine's own wrote, in bytes (a half is 2), so the progress bar moves and the routine waits for a
    frame every 256 bytes, as a format does. A slot write does not count itself. Where a slot of the
    pack names its `cost:`, the count must name the slot it went to,
    `copy.count_written 256, into: pack[:music]`; a count with no `into:` is then refused. Worked example:
    `test/all/vblank/builder/test_data_packs.rb` (`numbers_written`).
  - `copy.file("MAPHEAD.#{release}")` — one file of a copy that is several files (below), with the same
    verbs, each place counted from that file's start. A fixed place outside the file is refused.

  **An original that is several files** (a computer game's folder: Wolfenstein 3D's VSWAP.WL6,
  GAMEMAPS.WL6 and the rest) lists each release's files instead of a SHA-1 and a size:
  `releases: { "WL6" => { "files" => { "VSWAP.WL6" => { "sha1" => "…", "size" => 1_544_376 }, … } } }`.
  The copy is the folder; each named file is found in it without regard to case and checked by its size
  and SHA-1, and nothing else in it is read (a settings file the original rewrites, saves). The copy the
  routine reads is the files joined in the order listed, and the pack's header holds the SHA-1 of the
  list. A shell's LOAD ROM asks for the folder. Worked example: `test/folder_original.rb`, whose
  folder is `test/fixtures/folder_original/`.

  **Heavy conversion belongs in the unpacking**, as game code of the port's own (a sound chip
  rendered to samples, a game's own packers as formats of the port's): it runs once, at LOAD ROM or
  as the all-in-one build is made, and the pack keeps the result. Never redo it each time the game
  plays. VBlank takes a format in only when many games use it.

  **Keep what the unpacking wrote between builds** with `data_pack from: ..., version: ..., cache:
  ".cache/packs"`, a folder git ignores. An all-in-one build runs the routine on the interpreter,
  which for a big port takes most of a minute; with `cache:` a later build with the same copy, the
  same routine, the same slots and the same VBlank reads the bytes back instead
  (`Original::PackCache`). Leave it out and every build runs the routine. A build that leaves the
  pack out never runs the routine, so it keeps nothing.

  **A format of the port's own** is a module that does `extend VBlank::Original::Packing::Format`,
  `unpacks :name` (with any settings and their defaults: `unpacks :enigma, base: 0`), and defines
  `self.routine(block)`: game code, written into the unpacking once. `block` is the `Packing::BlockKit`
  every format is written with, the library's too: `block.from`, `block.setting(:base)`,
  `block.byte(at)`, `block.variable(:name)`, `block.list(:name, capacity:, width:)`, `block.repeat`,
  `block.expect_size(n)`, `block.write(value)`, `block.written_byte(back)`, `block.finished`,
  `block.finish!` and `block.emit_wrong_format_fault`. Each write is checked against the slot and
  counted toward the progress bar. Put the module in a file the game loads with
  `VBlank.require_game_file`, so an `if` in it is a branch of the routine. Worked example: `PairRuns`
  in `test/copy_reader_tests.rb`; the library's are `lib/vblank/original/packing/<platform>.rb`.

  **Nothing goes past its place.** A write outside its slot is not made, and a read outside the copy reads
  nothing that matters; either, or a block not in the format asked for, stops the build, naming the first that
  happened: `Original::WrongCopy` with the place in the copy, or an `ArgumentError` with the slot and the
  byte. A place or count written as a number is refused at once. A routine that never ends is stopped
  after as many frames as the copy and the pack have bytes.

  Each building block adds what it writes to the routine's count of bytes done as it goes, and waits for
  the next frame every 256 bytes and after it ends, so a shell can show progress:
  `pack.unpacking.bytes_done_in(run)` of `byte_size`.
  `pack.unpacking.program` is the program, and `slot_bytes_in(run)` each slot's bytes from a run of it on
  the interpreter and on each computer runtime, checked against the interpreter. No console runs it, so
  its tests play on those runs only (`test/copy_reader_tests.rb` and `test/packing_<console>_tests.rb`,
  included under `vblank/original/` in `test/interpreter/` and `test/lowering/{native,js,ruby}/`).
  Where it lives: `copy` is `Original::CopyReader` (`lib/vblank/original/copy_reader.rb`), a format's shape
  and kit are `lib/vblank/original/packing/format.rb`, and each platform's formats are
  `lib/vblank/original/packing/<platform>.rb`, listed by platform in `lib/vblank/original/packing.rb`.
  Worked examples: `test/copy_reader_tests.rb` for the routine, and
  `test/all/vblank/builder/test_data_packs.rb` for a game reading its pack.
- **The game holds handles, never bytes.** `pack[:palette]` is a `DSL::PackSlot`: its `shape`, `count`
  and `layout` (name, place and `byte_size`), nothing it holds. The verbs read the slot themselves:
  `image ..., colors: pack[:palette], places: pack[:walls].tile(3)` and `table :speeds, pack[:speeds]`.
  A table takes the slot's width and sign; a `width:` or `signed:` on the line that differs is refused.
  `pack.rom_sha1` and `pack.build_version` are the pack's header.

```ruby
ORIGINAL = VBlank::Original::Game.new(title: "Space Pinball", setting: "SPACE_PINBALL_ROM",
                                      settings_file: "space_pinball.yml",
                                      releases: { "US" => { "sha1" => "9402…", "size" => 1_048_576 } })
VBlank.game "PINBALL PORT", consoles: %i[gba] do
  pack = data_pack from: ORIGINAL, version: "1.0" do |slots|
    slots.colors :palette, at: 0x1000, count: 16
    slots.tiles :walls, at: 0x1020, count: 2
    slots.numbers :speeds, at: 0x2000, count: 8, width: :byte, signed: false
  end
  image :wall, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)
  speeds = table :speeds, pack[:speeds]
end
```

**A slot is kept in the layout of the console the original is for**, and the pack holds the bytes as
the original has them (unpacked, where the original packs them). The original names its platform:
`Original::Game.new(..., platform: :gbc)`, one of `:gba` (the default), `:gbc`, `:snes`, `:genesis`, or
`:pc` for a computer game. VBlank reads each layout itself, for every build and every console the port is
built for:

| platform | tiles | colours | numbers |
|---|---|---|---|
| `:gba` | 16 colours, 32 bytes, the left pixel in a byte's low half | 2 bytes, 5 bits each, red lowest, low byte first | low byte first |
| `:gbc` | 4 colours, 16 bytes: each row's bit 0 plane, then its bit 1 plane, the left pixel in bit 7 | as the Advance's | low byte first |
| `:snes` | `colors: 4` as the Color's; `colors: 16`, 32 bytes: planes 0 and 1 for all eight rows, then planes 2 and 3 | as the Advance's | low byte first |
| `:genesis` | 16 colours, 32 bytes, the left pixel in a byte's HIGH half | 2 bytes high byte first, `0000 BBB0 GGG0 RRR0`, each 3 bits widened to 5 as the Genesis shows them | high byte first |

Each console's layout is numbers in its hardware file (`Console::GBCHardware::ORIGINAL_FORMATS` and the
rest), named by its kit (`Console::Kit#original_formats`); one reader reads any of them
(`IR::FormatReading`, and `rg_start_file_fill_picture` in the C, JavaScript and Ruby runtimes, which reads
a slot of pixels, one byte each in any layout, the same way). A
`:pc` original keeps its data in no console's layout: its numbers are low byte first unless a slot names
its `byte_order:`, its pictures are slots of pixels, and a slot of colours or tiles names the console layout
its unpacking routine writes (`layout: :gba`); one without is refused. On the Color, a tile drawn by
place from a list of four colours or fewer goes into the cartridge place for place, so a Color
original's tiles are its own bytes there. Worked example: `test/all/vblank/builder/test_data_pack_layouts.rb`.

**All-in-one, unless told otherwise.** The pack is made from the copy as the game is built (by the routine on
the interpreter, where there is one), written as its
file and read back, and each verb given a handle takes what the slot holds as if the game had written
it. So the game plays as one holding the data on every backend, and a cartridge is always built this
way: a console's cartridge holds its data. A machine with no copy stops at `data_pack` with
`Original::NotSet`, saying what to set; a slot that runs past the end of the copy is `Original::WrongCopy`
naming the slot.

**With the pack left out** — `vblank build game.rb --format native|web|ruby --pack-at-start`, or
`pack_at_start: true` on `VBlank.build` and `Cartridge::Options` — a build for a computer (C, JavaScript,
Ruby) reads no copy, builds on a machine with none, and holds none of the original's bytes. The program
reads its pack from a file it is handed as it starts (`IR::StartFile`): the desktop program's
`--data-pack PATH`, `--start-file FILE` on the headless programs, and in a test the interpreter's,
checked runs' and headless runs' `hand_file(bytes)`. The web page has no way to be handed one yet; the
Ruby file gets its pack as a shell (below). Handed none, a pack of the wrong size, or
one made for another build version or slot list, the game stops at once with an `IR::ProgramError` in
plain words. A desktop program built with `--bios`, which plays the console's start-up from the
cartridge, cannot be built this way yet; without `--bios` it can. What reads a slot that way:

- `table :speeds, pack[:speeds]` — written as its size alone and filled from the file at power-on; the
  build never looks at its entries. `table :name, DSL::StartFileEntries.new(at:, count:), width:,
  signed:` is the same for any place in the file.
- `image :wall, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)` — a picture
  from the pack, drawn however a picture is: a background's tile, a sprite, `blit`, a face of a place,
  drawn in other colours (`draw_with`, a background's recolours), `mirror`/`upside_down`. `pack[:sprites]
  .tiles(0, across: 2, down: 2)` takes the places of tiles side by side, for a picture 8 pixels wider
  and taller for each; `pack[:palette].bank(1)` takes the second bank of 16 colours of a slot of colours, as
  a console's palette keeps them. A picture can take only one list from the pack, the other being `colors: [...]`
  or `places: [...]` in the game. The program holds zeros of the picture's size, and the runtime fills
  them at power-on. **The build sees a whole box**: a default hitbox, a cut into blocks or the pieces a
  console draws it in follow the box of its size, not the see-through pixels in it, so a game that
  wants a tighter box says `hitbox:`.
- `sample`/`instrument` with `pcm: pack[:sounds]` — the recording's samples, filled from the file at power-on.
  Any other verb that reads a slot's bytes is refused at the line.
- `pack.unpacking(release: RELEASE)` — the unpacking program for a copy of that release (an
  `Original::Release`, with its name and size), built with no copy; it is handed the copy as its start file, and `slot_bytes_in(run)`
  after its halt is the pack, which `Original::Pack.holding(..., sha1:, build_version:)` writes.
  Built so, it draws a progress bar as it goes (game code, so every runtime shows it), by bytes, or by
  work where a slot names its `cost:`. Worked example: `test/pack_at_start_tests.rb` (`bar_widths`).
- `game.data_pack_file` (a `Cartridge::Game`, `settings:`, `console:`) — the pack file the all-in-one
  build makes from the copy, its bytes: what a build with its pack left out is handed, and what a
  shell must make, byte for byte.

A cartridge build told `pack_at_start:` is refused at `data_pack`, and `vblank build --pack-at-start`
for a cartridge before anything is built; every cartridge lowering refuses a program that reads a start
file (`Backends.refuse_start_file_on_cartridge!`). The unpacking checks only its copy's size; checking
the copy's SHA-1 is the shell's. Worked example: `test/pack_at_start_tests.rb`.

**A whole port, end to end** — `test/fixtures/pacman_port/`: `pacman.gba` (the cartridge `examples/pacman.rb` builds,
checked in with its SHA-1 as a stand-in original; `ruby tools/make_pacman_fixture.rb` makes it again and refuses a
cartridge that packs nothing or with one scheme only), `pacman_facts.yml` (where each asset is, from
`BuildRecord#data_assets`), and `pacman_port.rb`, whose routine unpacks all thirteen packed assets, LZ77 and
RLE (`test/all/vblank/original/test_pacman_fixture.rb` packs each again and gets the cartridge's bytes). Its
shell tests, one for each runtime, are `test_pacman_port_shell.rb`, `test_js_pacman_port_shell.rb` and
`test_native_pacman_port_shell.rb`.

**The shell** — `vblank run game.rb --shell` (`--pack-folder DIR`), `vblank build game.rb --format ruby
--shell`, `Original::Shell.build(game)` — is the port as a player gets it: no copy is read (every
`Original::Game` answers `NotSet` while it builds, so a game whose code reads the copy stops naming the
line), and it holds the game with its pack left out, a menu (the title, LOAD ROM, SETTINGS; a small
game of the library's own), and the unpacking built for each release `from:` reads, which must each
have a `sha1` and a `size`. Played (`Live::Shell`), it plays the game from `data.pack` in its folder
(the desktop build's folder for the game, named from the title and the releases' SHA-1s) when that file
passes the game's start-file check. Otherwise LOAD ROM asks for a file, refuses one that is no release
the game reads (`Original::Releases`, the words a build machine uses too), unpacks it with its
release's unpacking, writes the pack — byte for byte the all-in-one build's — and plays the game. Played
as Ruby, the unpacking runs in a Ractor of its own (`Live::BackgroundUnpacking`), so the window keeps
showing its bar however long the routine works between writes; closing the window then keeps no pack. A
pack for another `version:` fails the check, so the menu asks again. SETTINGS opens the window's menu.
The web page (`--format web --shell`) and the desktop program (`--format native --shell`, a folder) do
the same, each made from `Original::ShellFacts`, every sentence they refuse a file in among them. Every
release reads one slot list. Worked example: `test/lowering/ruby/vblank/live/test_shell.rb`.

**A port's shell check** — `rake shell:check`, from `Original::ShellCheckTasks` in the port's Rakefile
(`t.game_file`, and `t.console` and `t.tape` if wanted), or `Live::ShellCheck.new(game, tape:).run` — does
what a player does with nobody at the controls: builds the shell with no copy in reach, starts it with
the copy this machine names, holds the pack it keeps to the all-in-one build's byte for byte, starts it
again with that copy out of reach, and plays the tape (300 passes with nothing pressed without one) on
both starts and the all-in-one build, holding every picture and sound to that build's. A machine that
names no copy fails with `NotSet`'s words. Worked example: `test/lowering/ruby/vblank/live/test_shell_check.rb`.

**The pack file** (`Original::Pack`): `"VBLANKPK"`, the format version (2 bytes), the copy's SHA-1 (20
bytes), the build version (a length byte and the text), the slot count (2 bytes), each slot's name (a
length byte and the text) and size (4 bytes), then each slot's bytes. A file that is not a pack, is cut
short or is in another format is refused with `Original::WrongPack`.
