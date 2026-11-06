# DSL reference: Data from the original (the data pack)

The whole story of `data_pack`, indexed under Tables in `.claude/rules/dsl-reference.md`.

A port of a retail game may not ship that game's data. It names the original (`VBlank::Original::Game`,
which finds the player's copy and checks its SHA-1) and reads what it needs from a **data pack** made
from that copy. The game's code says each piece's shape and size; it never depends on the bytes.

- `data_pack from: ORIGINAL, version: "1.0" do |slots| … end` → a `DSL::DataPack`. `from:` is an
  `Original::Game` (its `copy` is asked for) or an `Original::Copy`. `version:` is required: it names this
  build of the game in the pack's header, so a player's pack is made again when the game's data changes.
  Inside the block, each line is a slot:
  - `slots.colors :palette, at: 0x1000, count: 16` — the Advance's colours, two bytes each.
  - `slots.tiles :walls, at: 0x1020, count: 40` — the Advance's 8x8 tiles of sixteen colours, 32 bytes each.
  - `slots.numbers :speeds, at: 0x2000, count: 8, width: :byte, signed: false` — numbers one, two or four bytes wide; `signed:` must be said.

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

**A shape names the layout the original keeps that data in**, and the pack holds the bytes as the
original has them (unpacked, where the original packs them). VBlank reads each layout itself, for every
build and every console. Today every shape is the Game Boy Advance's: colours two bytes, 5 bits each,
low byte first; 16-colour tiles 32 bytes, the left pixel in the low half; numbers low byte first. The
other consoles' layouts (the Color's 4-colour tiles, the Super Nintendo's tiles, the Genesis's tiles and
colours) are shapes still to add. A computer game's data is in no console's layout, so its port's
unpacking routine turns it into one of the shapes.

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
checked runs' and headless runs' `hand_file(bytes)`. The web page and the Ruby file have no way to be
handed one yet: that is the shell's Load ROM, still to come. Handed none, a pack of the wrong size, or
one made for another build version or slot list, the game stops at once with an `IR::ProgramError` in
plain words. A Game Boy Advance desktop program, which plays the console's start-up from the cartridge,
cannot be built this way yet. What reads a slot that way:

- `table :speeds, pack[:speeds]` — written as its size alone and filled from the file at power-on; the
  build never looks at its entries. `table :name, DSL::StartFileEntries.new(at:, count:), width:,
  signed:` is the same for any place in the file.
- `image :wall, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)` — both lists
  from the pack, 8x8, and only as a background's tile so far. As a sprite, a blit, a face or a
  recoloured tile the lowering refuses it naming the picture; `mirror`/`upside_down` of it, a picture
  taking only one list from the pack, and any other verb that reads a slot's bytes are refused at the line.
- `pack.unpacking(copy_size: SIZE)` — the unpacking program for a copy of that many bytes (the
  release's size), built with no copy; it is handed the copy as its start file, and `slot_bytes_in(run)`
  after its halt is the pack, which `Original::Pack.holding(..., sha1:, build_version:)` writes.
  Playing it inside the shipped game before the game starts, keeping the pack on the player's machine
  and checking the copy's SHA-1 are the shell's, still to come.

A cartridge build told `pack_at_start:` is refused at `data_pack`, and `vblank build --pack-at-start`
for a cartridge before anything is built; every cartridge lowering refuses a program that reads a start
file (`Backends.refuse_start_file_on_cartridge!`). The unpacking checks only its copy's size; checking
the copy's SHA-1 is the shell's. Worked example: `test/pack_at_start_tests.rb`.

**The pack file** (`Original::Pack`): `"VBLANKPK"`, the format version (2 bytes), the copy's SHA-1 (20
bytes), the build version (a length byte and the text), the slot count (2 bytes), each slot's name (a
length byte and the text) and size (4 bytes), then each slot's bytes. A file that is not a pack, is cut
short or is in another format is refused with `Original::WrongPack`.
