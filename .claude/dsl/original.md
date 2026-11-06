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

  A game has one `data_pack`.
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

**Every build is all-in-one today.** The pack is made from the copy as the game is built, written as its
file and read back, and each verb given a handle takes what the slot holds as if the game had written
it. So the game plays as one holding the data on every backend, and a cartridge keeps it that way for
good: a console's cartridge holds its data. A machine with no copy stops at `data_pack` with
`Original::NotSet`, saying what to set; a slot that runs past the end of the copy is `Original::WrongCopy`
naming the slot.

**The pack file** (`Original::Pack`): `"VBLANKPK"`, the format version (2 bytes), the copy's SHA-1 (20
bytes), the build version (a length byte and the text), the slot count (2 bytes), each slot's name (a
length byte and the text) and size (4 bytes), then each slot's bytes. A file that is not a pack, is cut
short or is in another format is refused with `Original::WrongPack`.
