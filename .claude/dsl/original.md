# DSL reference: Data from the original (the data pack)

The whole story of `data_pack`, indexed under Tables in `.claude/rules/dsl-reference.md`.

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

  Each is in the layout of the original's platform (below) unless the line names another, `layout: :gba`.

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
  - `copy.unpack_lz77 at:, into:, start: 0` and `copy.unpack_rle at:, into:, start: 0` — a block packed in
    the Game Boy Advance BIOS's LZ77 or RLE format (4-byte header: the scheme in the first byte's top half,
    1 or 3, then the unpacked size), the formats retail cartridges and the GBA lowering use
    (`BiosCompress` is the answer key).
  - `pack[:walls][i] = value` writes one byte (the low 8 bits); `pack[:walls][i]` reads one back;
    `pack[:walls].byte_size`.

  **Nothing goes past its place.** A write outside its slot is not made, and a read outside the copy reads
  nothing that matters; either, or a block of another scheme, stops the build, naming the first that
  happened: `Original::WrongCopy` with the place in the copy, or an `ArgumentError` with the slot and the
  byte. A place or count written as a number is refused at once. A routine that never ends is stopped
  after as many frames as the copy and the pack have bytes.

  Each building block adds what it writes to the routine's count of bytes done as it goes, and waits for
  the next frame every 256 bytes and after it ends, so a shell can show progress:
  `pack.unpacking.bytes_done_in(run)` of `byte_size`.
  `pack.unpacking.program` is the program, and `slot_bytes_in(run)` each slot's bytes from a run of it on
  any backend; every lowering plays it like any game, checked against the interpreter. Genesis
  decompressors are not here yet. Worked example: `test/all/vblank/builder/test_data_packs.rb`.
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
(`IR::FormatReading`, and `rg_start_file_fill_picture` in the C, JavaScript and Ruby runtimes). A
`:pc` original keeps its data in no console's layout, so each of its slots names the layout its
unpacking routine writes (`layout: :gba`); a slot without one is refused. On the Color, a tile drawn by
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
plain words. A Game Boy Advance desktop program, which plays the console's start-up from the cartridge,
cannot be built this way yet. What reads a slot that way:

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
  wants a tighter box says `hitbox:`. Any other verb that reads a slot's bytes is refused at the line.
- `pack.unpacking(copy_size: SIZE)` — the unpacking program for a copy of that many bytes (the
  release's size), built with no copy; it is handed the copy as its start file, and `slot_bytes_in(run)`
  after its halt is the pack, which `Original::Pack.holding(..., sha1:, build_version:)` writes.
  Built so, it draws a progress bar as it goes (game code, so every runtime shows it).
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
release's unpacking, writes the pack — byte for byte the all-in-one build's — and plays the game. A
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
