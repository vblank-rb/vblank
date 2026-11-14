# DSL reference: Data from the original (the data pack)

The whole story of `data_pack`, listed on `tables.md`. The map of every page is `.claude/rules/dsl-reference.md`.

A port of a retail game may not ship that game's data. It names the original (`VBlank::Original::Game`,
which finds the player's copy and checks its SHA-1; given `probe:` as well as `releases:`, a copy it refuses
is named by what the probe reads from it, "the EU release, but changed or damaged") and reads what it needs from a **data pack** made
from that copy. The game's code says each piece's shape and size; it never depends on the bytes.

- `data_pack from: ORIGINAL, version: "1.0" do |slots| … end` → a `DSL::DataPack`. `from:` is an
  `Original::Game` (its `copy` is asked for) or an `Original::Copy`. `version:` is required: it names this
  build of the game in the pack's header, so a player's pack is made again when the game's data changes.
  Inside the block, each line is a slot:
  - `slots.colors :palette, at: 0x1000, count: 16` — colours, two bytes each.
  - `slots.tiles :walls, at: 0x1020, count: 40` — 8x8 tiles; `colors: 4` or `colors: 16` where the
    console keeps both (the Super Nintendo). **`colors: 256` is a tile kept a byte a pixel**, 64 bytes row
    by row, each byte a place in a table of 256 colours, in any layout: the pictures of a layer a console
    turns and resizes (the Advance's turning layer, the Super Nintendo's Mode 7), for a `background` from
    the pack (`backgrounds.md`).
  - `slots.numbers :speeds, at: 0x2000, count: 8, width: :byte, signed: false` — numbers one, two or four bytes wide; `signed:` must be said.
    `pack[:video_bytes].numbers(first, count)` is `count` of them from number `first` on, for a
    background's `map:` kept among other things in a bigger slot, as a console keeps a map in a block of
    its video memory; any other verb takes the whole slot. Where the bigger slot has another shape
    (tiles), take the map as a view of it: `pack[:video].as_numbers(at:, count:, width: :byte, signed:
    false)` ("A view", below).
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
    `test/pack_sound_tests.rb`. **A recording kept in the Super Nintendo sound chip's own format** (BRR)
    takes the slot as `brr:`, and its loop point can be a number of the pack: `sample :horn, brr:
    pack[:horn], brr_loop: pack[:loops].number(3), rate: 16_000` (`sound.md`), so the unpacking routine
    copies the original's bytes and converts nothing. Built all-in-one, the build decodes it. With the pack
    left out, the program holds zeros of the most samples it can decode to and the runtime decodes it at
    power-on (`IR::StartFile::BRR`, `rg_mix_fill_brr`), so it works in a shell. **Nothing the pack holds
    stops the game**, built either way: the blocks after one that ends the recording are not played, a
    recording no block ends plays once to its last block, and a loop point inside a block or past the last
    block is that block's start or the last block's. A slot that is not whole blocks, and a loop point the
    game writes that is not a block's start, are friendly errors both ways; bytes the game writes with
    `brr_loop:` from the pack are refused with the pack left out. Worked examples:
    `test/all/vblank/builder/test_brr_recordings.rb`, `test/pack_sound_tests.rb`.
  - `slots.notes :title_0, count: 200` — **notes of music, twelve bytes each in a record of VBlank's own**
    (`Original::PackNote`, whose `LAYOUT` and `bytes_of` a port's tests can use): the tick it starts on and
    how many it lasts (two bytes each, low byte first, 0 for until the next note), a MIDI key (255 a rest),
    which of the part's instruments (255 the part's own), and a volume 0 to 15 (255 the part's own), then
    **the speaker** (0 both, 1 the left, 2 the right, 255 the part's own), then **a loudness in 512ths** (two
    bytes, 65535 for none), then **a noise clock** (the divider 0 to 7 in the low three bits and the
    halvings 0 to 13 in the high four, as the Advance's noise register keeps them; 255 for the key's
    pitch), then a byte of 0. On a part that plays a recording a loudness is played in place of the
    volume, as `volume: 15 * loudness / 512r` (`sound.md`), which is the scale a cartridge's own sound
    engine mixes at; elsewhere it means nothing. One past 512 is refused all-in-one and is all of the
    recording from the player's file. A speaker is a note's `pan:` on any part but one that plays a
    recording, where it means nothing; a noise clock is a note's `noise_clock:` in place of its key on a
    part on the noise voice that is not transposed, and means nothing elsewhere. Where they mean
    something, one that is neither a speaker nor 255 is refused all-in-one and is the part's own from the
    player's file, and a clock with halvings past 13 is refused all-in-one and plays the key from it.
    A note starting on tick 65535 ends the part, so the slot holds the most notes a part can have. A retail game keeps its music in its
    own sound driver's commands, so the unpacking routine runs those forward and writes the notes they
    play. A Score's part takes the slot as its notes: `Score::Part.new(plays: :horn, notes:
    pack[:title_0].notes(instruments: %i[horn bass]))` (`sound.md`). **The song's length and the tick it
    comes round to can be numbers of the pack too**, which the driver's commands say (where its track
    ends, where it jumps back to): `Score.new(..., length: pack[:song].number(0), loop_from:
    pack[:song].number(1), longest: 2000)`, `longest:` being the most ticks the song can last, which a
    build that reads its pack as the game starts makes room for. **A driver that runs once a frame**
    writes its notes a tick a frame, and its Score says `tempo: 3600, ticks_per_beat: 1`, which puts
    each tick on its own frame. That is the whole of what VBlank asks of a port's sound driver: a port
    with a driver of its own writes these in its unpacking routine and needs nothing more (worked
    example: `test_a_port_with_a_sound_driver_of_its_own_plays_its_song_through_the_pack` in
    `test/pack_scores_at_start_tests.rb`).
  - `slots.voiced_notes :title_0, count: 200` — **notes with their voice's settings, thirty-two bytes
    each**: the twelve above, then what a `Score::Note` can say of its voice, each the note's only where
    the names (bytes 20 and 21, a bit each, `Original::PackNote::NAMES`) name it: **a pitch number**
    0 to 2047 in place of the key (bytes 12-13, `pitch_number:`, the Color's period; the key byte must
    still be 127 or less), **a fade** (byte 14, the envelope register's four bits, 8 for a swell:
    `decay:`/`swell:`), **a duty** (byte 15, two bits a frame for four frames: `duty:`), **vibrato**
    (bytes 16-17, depth, speed less one and wait as `Audio::Vibrato#bits`; depth 0 is `:none`; the
    names' CARRIES bit is `carries: true`), **a slide** (byte 18, the sweep register: `slide_up:` or
    `slide_down:`, 0 for `:none`), and **a shade between the speakers** (byte 19, a signed byte in 64ths
    from the middle, -64 the left alone to 64 the right: `pan: shade / 64r`, so `pan: -0.6875` is -44),
    which is the note's in place of the speaker byte on any part, a recorded part too; and **a pitch
    between keys** (bytes 22-24, in 16ths of a hertz: `hz: n / 16r`, on a part that plays a recording or
    the noise voice, as a driver's chip pitch word sets it) and **a glide** (the names' GLIDES bit:
    `glides: true`, on a recorded part, its instrument, volume and loudness left as the part's own,
    where the console glides at all: the Super Nintendo and the PlayStation), and **a rattle** (byte 25,
    1 for a hit that rattles and 0 for one that does not, on the noise voice: `metallic:`) and **a wave**
    (byte 26, which of the part's waves, counting from 0, on the wave voice: `wave:`). A part names its
    waves as it names instruments, `pack[:pad].notes(waves: [pack[:waves].wave(0), :sine])`, each a
    shape, 32 steps or a wave of the pack, and a wave number past them is the part's own from the
    player's file and refused all-in-one (worked examples:
    `test_a_drum_that_rattles_and_a_wave_part_that_changes_wave_from_the_pack_play_as_written_by_hand` in
    `test/all/vblank/builder/test_pack_scores.rb`, and its twin read as the game starts in
    `test/pack_scores_at_start_tests.rb`). A setting the
    part's voice lacks (a duty off the squares, a fade on the wave, a slide off the song's first square,
    a pitch number off the squares and the wave), or one past its range, is refused all-in-one as a note
    written by hand is, and from the player's file is the part's own; a note whose slide and vibrato
    would both move holds its vibrato still (`vibrato: :none`) from the file. `PackNote.bytes_of(notes,
    count:, voiced: true)` writes them for a test, each note's ninth a Hash of its settings by name
    (worked examples: `test_notes_with_their_voices_settings_from_the_pack_play_as_written_by_hand` in
    `test/all/vblank/builder/test_pack_scores.rb`, and its twin read as the game starts in
    `test/pack_scores_at_start_tests.rb`).
  - `pack[:waves].wave(1)` — **a wave of the wave voice**: sixteen bytes of a slot of bytes from wave 1 on,
    two steps a byte, the earlier in the high four bits (as the Game Boy's wave memory keeps them), for a
    Score part's `plays:` in place of its 32 steps. Read where the game is built; a build that reads its
    pack as the game starts reads the wave then, the part playing silence until it does. A PlayStation
    build for a computer refuses that, since it makes each wave's sound memory as it is built. An instrument's numbers can come
    from slots too: `rate: pack[:tuning].number(3)`, `holds_from: pack[:loops].number(3)`, and
    `envelope: pack[:shapes].envelope(3)`, four bytes of a slot of bytes in an `Audio::Envelope`'s order.
    **An envelope kept as a Super Nintendo's sound chip keeps it** is `envelope:
    pack[:adsr].snes_envelope(3)`: three bytes of a slot of bytes, ADSR1, ADSR2 and GAIN, envelope 0 from
    byte 0, read as a `VBlank::Audio::SNESEnvelope` (`sound.md`), so the unpacking routine copies the
    original's bytes and converts nothing. An envelope past the end of its slot is a friendly error.
    Built all-in-one these are read as the game is built. A build that leaves its pack out reads a
    part's notes and an instrument's `rate:`, `holds_from:` and four-byte `envelope:` as the game starts
    (below), and refuses a chip envelope from the pack for now. Worked examples:
    `test/all/vblank/builder/test_pack_scores.rb`, `test/pack_scores_at_start_tests.rb`,
    `test/pack_sound_tests.rb` and `test/snes_envelope_tests.rb`.

  - `slots.map_cells :title_map, count: 1024` — **cells of a background's map, four bytes each in a record
    of VBlank's own** (`Original::MapCell`, `lib/vblank/original/map_cell.rb`, whose `bytes_of` a port's
    tests can use): the tile in two bytes, low byte first, counted from the first tile of the background's
    `tiles:` (0 to 65535; a second bank of video memory is more tiles of the same slot); the bank of
    colours in one (0 to 255; `write_cell` refuses a number past either written in the routine, and one
    worked out as it runs keeps its low bits, as a write of a byte does); and
    the turns in one, 1 mirrored and 2 upside down, the other bits 0. Read as one number, low byte first,
    the record is `tile | bank << 16 | turns << 24` (`Original::MapCell.number(tile:, bank:, mirrored:,
    upside_down:)`, or `MapCell::Cell.new(...).number`), which fits a game's number: it is how
    `set_cells:` and `set_cell` take a cell of such a map (`backgrounds.md`). No
    bit a console keeps for itself (a priority) is in it: a background's layer says where it is drawn. A
    cell is one tile of 8x8. The record is the same whatever console the original ran on, so the unpacking
    routine writes the original's maps into it (`write_cell`, below), and `background ..., map:
    pack[:title_map]` reads it on every console and build that draws a tiled background
    (`backgrounds.md`). A map of numbers in the
    Advance's, the Super Nintendo's or the Genesis's own layout can still be read as it is.

  Any slot may name `cost: 4`: how many times the work of a plain copy one byte of it takes to unpack
  (a whole number, 1 or more; 1 when not named). It changes only the shell's progress bar (below):
  a slot's share of the bar is its bytes times its cost, so a slot the routine renders slowly moves the
  bar as slowly as the routine works. A slot the routine fills moves the bar only by what
  `copy.count_written ..., into:` counts for it. A pack where every slot costs 1 shows the bar by
  bytes, as before.

  Each is in the layout of the original's platform (below) unless the line names another, `layout: :gba`
  (or `layout: :vblank`, VBlank's own). A platform whose layout VBlank does not read (`:ps1`, `:pc`, any
  other name) is in VBlank's own layout, which its unpacking writes. A computer game's numbers
  (`platform: :pc`) are low byte first, as DOS and Windows games keep them, unless the line names its
  byte order: `byte_order: :high_first` (or `:low_first`). A line naming both a layout and a byte order is
  refused, since the layout already says it. A slot of numbers one byte wide has no byte order, so any
  console's name is taken as its layout.

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
  pixels are filled from the file as the game starts. Its colours are held in the program where the game
  gives them, and read from the file then where `colors:` is a slot, all 256 of it taken whole: the build
  holds a marker for each (`colors` from the pack, below), so a port whose original keeps every colour in
  its data ships none. On a console it
  is a picture of that many colours, so what the console does with one given `data:` it does with this.
  Worked examples: `test/all/vblank/builder/test_data_packs.rb` and `test/pack_at_start_tests.rb`.

- `colors :logo_cycle_3, pack[:logo_colors].bank(3, size: 11)` — **a list of colours from a slot of
  colours**, for a sprite the original repaints by writing other colours over its palette. The second
  argument is one bank of the slot (`bank(n, size: k)`: `k` colours from colour `n * k`, 16 when `size:`
  is left out) or the whole slot, 2 to 16 colours either way. It is the list those colours written in
  the game would be, in the slot's order, so every verb that takes a list's name takes it: a picture's
  or a sprite's `colors: :logo_cycle_3`, `draw_with`, `recolor :screen_colors, NAMES, showing: step`,
  `color_walk`, and `screen :tiled, backdrop:` (`sprites.md`, `screen.md`). **Place 0 is kept as the
  slot has it**: see-through to a picture, as in any list, and the colour shown to a backdrop that
  follows the list. A game that writes the same colours by hand builds the same bytes. Built
  all-in-one, the build reads the slot. **A build that reads its pack as the game starts shows the
  same picture**: it reads the colours then, and makes the steps of a `color_walk` of the list then
  ("With the pack left out" below). Friendly errors at the line: a slot or bank of more than 16 colours
  (take one bank), a slot that does not hold colours, a slot of another game's pack. Worked example:
  `test/all/vblank/builder/test_pack_color_lists.rb`, where a sprite is recoloured through three banks.

- `screen :tiled, backdrop: pack[:logo_colors]` — **a screen's backdrop from a slot of colours**: the
  colour the slot holds first, which the original's own screen shows wherever none of its tiles draws.
  `pack[:logo_colors].bank(2)` is that bank's first colour, and `backdrop_place:` picks another place.
  It goes on the game's own `screen` line or a scene's, as a colour written in the game does, and
  builds the same bytes as that colour written out (`screen.md`). Built all-in-one, the build reads
  the slot. A build that reads its pack as the game starts reads the colour then, and shows the same
  screen. Worked examples: `test/all/vblank/builder/test_pack_backdrops.rb`, and with the pack left
  out `test/pack_backdrop_at_start_tests.rb`.

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
- **The unpacking routine**: `slots.fill_from_copy do |copy, pack| … end`, one per pack, or given in named
  parts, `slots.fill_from_copy :floors do … end` then `slots.fill_from_copy :music do … end`, which run in
  that order as one routine would (each part named, no name twice; the cache below keeps them apart). It is **game
  code**, a program of its own (`Original::Unpacking`), so the same routine fills the pack as the game is
  built (played to its `halt` the fastest way the machine has, below) and on the player's machine (see
  "With the pack left out" below). The
  slots with `at:` are copied first, then the routine runs. Inside it, normal Ruby works as in a game block
  (`while` on a number read from the copy is a loop in the routine), and:
  - `copy.byte(at)` (0 to 255), `copy.half(at)`, `copy.word(at)`: low byte first; `big_endian: true` for
    high byte first. `at` may be worked out as the routine runs.
  - `copy.copy_bytes at:, count:, into: pack[:walls], start: 0` — bytes as they are.
  - `copy.unpack_<format> at:, into:, start: 0` — a block in a packed format. The copy offers the formats
    of the platform its original is for, and any the port names in `data_pack ..., formats: [MyFormat]`;
    asking for another is refused, naming the ones it offers. An Advance original's are
    `copy.unpack_lz77` and `copy.unpack_rle`, the BIOS's LZ77 and RLE (4-byte header: the scheme in the
    first byte's top half, 1 or 3, then the unpacked size; `BiosCompress` is the answer key), and **the
    songs of MusicPlayer2000**, the sound driver most Advance games keep their music in (`m4a`,
    `Original::Packing::M4A`, whose comment says every command and what is not kept):
    `copy.unpack_m4a_track at: SONG, into: pack[:title_0], track: 0` writes a track's notes as pack notes
    (`kind: 4` keeps only its notes on the noise voice, `0` on recordings, `1` to `3` the squares and the
    wave), a tick a frame as the driver's tempo lands them; `copy.unpack_m4a_length at: SONG, into:` writes
    the song's length in frames and the frame it comes round to (65535 for a song that ends), two numbers
    of two bytes; `copy.unpack_m4a_recording at: VOICE, into:` a recording voice's samples; and
    `copy.unpack_m4a_voice at: VOICE, into:` its rate, the sample it loops back to (every bit set for a voice
    that does not loop, which `holds_from:` takes as none), its length and its
    envelope's four bytes, four numbers of four bytes (`mix_rate:` names the rate a voice played at a
    fixed rate has); on the wave voice's VOICE it writes the voice's wave pattern instead, sixteen bytes,
    which a Score part plays with `plays: pack[:pattern].wave(0)`. **The console voices' own settings**:
    `copy.unpack_m4a_voiced_track` takes what `unpack_m4a_track` does and writes into a slot of
    `voiced_notes`, each note with its voice's duty (the squares), sweep (the first square, as a slide) and
    envelope (the squares and the noise: an attack swells from silence, a decay fades from the note's
    volume past the driver's sustain level, and with neither the note holds at the sustain level),
    as the driver sets the voice up for the note. SONG is where a song's header is in the copy and VOICE a voice's twelve bytes (a
    drum kit's voice for key k is 12 × k past where its voices are, the second word of the kit's entry
    in the group, and a key split's entry e is 12 × e past its own). **A recorded part's instrument numbers** are the voices' numbers in the song's
    voice group (0 to 127); a drum kit's voice for key k is `kit_from:` + k, and a key split's entry e is
    `split_from:` + e, both 128 unless the track's line sets them. So a track that changes between plain
    voices and one kit (or one split) cannot give two voices one number. A track that plays a kit and a
    split, or two kits, sets one of them apart. The part's `instruments:` list names an instrument for
    every number up to the highest it plays, with no gaps, so set them low to keep it short: a track of
    the group's voices 0 and 7 and a kit's keys 0 and 1 is `copy.unpack_m4a_track at: SONG, into:
    pack[:drums], track: 2, kind: 0, kit_from: 1` with `notes(instruments: %i[piano kick snare piano
    piano piano piano bell])`. A track that plays only a kit can set `kit_from: 0` and name its
    instruments by key. A number past 254 or under 0 is written 255, the part's own instrument.
    Its Score plays a tick a frame: `Score.new(parts:, tempo: 3600, ticks_per_beat: 1,
    length: pack[:timing].number(0), loop_from: pack[:timing].number(1), longest: 2000)`. Worked
    example: the `MusicPlayer2000Songs` kit in `test/pack_games.rb`; the answer key is
    `test/m4a_answers.rb`, written from the driver's source. A Genesis
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
  - `pack[:title_map].write_cell(at, tile:, bank: 0, mirrored: false, upside_down: false)` writes cell `at`
    of a slot of map cells as its record. Each part may be a number or worked out as the routine runs, as
    `at` may; `mirrored:` and `upside_down:` are true or false, or a number whose lowest bit is read, so a
    Game Boy Color port writes `tile: number + (((attributes >> 3) & 1) * 384), bank: attributes & 7,
    mirrored: attributes >> 5, upside_down: attributes >> 6`, with `attributes = copy.byte(attribute_map +
    at)` and `number` the cell's tile counted from $8000: `copy.byte(map + at)` on a screen that counts
    from $8000, and `((copy.byte(map + at) + 128) & 255) + 128` on one that counts from $8800 (LCDC bit 4
    clear, where byte 0 is the tile at $9000). A cell past the slot is refused or stops the build as a
    number's is, `write_cell` on a slot that is not map cells is refused, and so is a tile past 65535 or a
    bank past 255 written as a number, since the record would keep only its low bits. Worked example:
    `color_cells_game_and_file` in `test/pack_background_tests.rb`.
  - `pack[:palette].write_color(at, red:, green:, blue:, bits: 8)` writes colour `at` of a slot of colours
    in the slot's layout, from three channels `bits:` deep as the original keeps them (1 to 8: 8 for a byte
    a channel, 6 for a computer's video card, 5 for the PlayStation's). A channel deeper than the layout's
    keeps its top bits; one shallower is widened, its bits repeated, so its brightest is the brightest.
    Each part may be a number or worked out as the routine runs, as `at` may; one worked out keeps its low
    `bits:` bits. A channel past `bits:` written as a number is refused, and so is `write_color` on a slot
    that is not colours. Worked example: `vblank_layout_game_and_file` in
    `test/made_up_vblank_layout_originals.rb`.
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

  **How an all-in-one build runs the routine**: the fastest way the machine has
  (`Original::Unpacking#write_pack_fastest`): built as C and optimised where zig 0.17 is installed,
  else built as Ruby, else on the interpreter. A byte-at-a-time copy of 300 MB takes seconds as C
  and minutes as Ruby. As C the routine writes the pack file itself, so the build holds the pack
  once, and a list of bytes costs a byte an item. The compiled routine is kept by its C, so a build
  whose routine has not changed does not compile it again. Every way writes the same pack, byte for
  byte. A game's test that makes the pack file as a build does calls
  `unpacking.write_pack_fastest(path, sha1:, build_version:)`; one that reads the routine's lists
  and variables calls `unpacking.run_fastest` (or `run_as_c`, `run_as_ruby` for one way).

  **Keep what the unpacking wrote between builds** with `data_pack from: ..., version: ..., cache:
  ".cache/packs"`, a folder git ignores. With `cache:` a later build with the same copy, the same
  routine, the same slots, the same version and the same VBlank reads the pack file back instead
  (`Original::PackCache`). "The same VBlank" means the part of VBlank a pack is built and played
  with (`Original::PackLibrary`): every file under its `lib` except the folders no unpacking uses,
  such as each console's cartridge lowering, the cartridge and emulator tools, the network and the
  window. So a VBlank commit to the Game Boy Color's lowering leaves the kept pack hitting, and a
  commit to the interpreter or the C build plays the routine again. A test holds that list to what
  a build really runs and reads. The key also holds the routine's defaults (the `DEFAULTS` of the
  records it uses), so a changed default plays it again. A pack kept by an older VBlank misses
  once, and the build keeps it again under the new key.
  The key is the whole routine, so a change to any of it runs all of it again, unless the routine is
  in named parts. Then each part is kept apart, and a change to one part plays that part again and takes
  the rest from the cache (`Original::UnpackingParts`). Two parts are played together when one reads a
  slot the other writes, or both name one variable, list or routine. Hand nothing from one part to
  another in Ruby (an instance variable, a local both blocks share) or through `copy.bytes_done`:
  the cache cannot see it, so pass it through a slot. The pack is the whole routine's,
  byte for byte. A part that cannot be built alone (it calls a routine another part defines) keeps the
  whole routine as one entry. `pack.unpacking_parts` gives the parts to a game's own test. A test that
  wants the slots, not a pack file, keeps them the same way with
  `Original::PackCache.new(folder).slot_bytes(pack.unpacking, parts: pack.unpacking_parts) { |playing, parts| playing.slot_bytes_in(playing.run_fastest) }`:
  the block plays the unpacking it is handed (`playing`, which holds only the parts named), not the
  whole one. Without `parts:` it caches the whole routine as one entry. Leave `cache:` out and
  every build runs the routine. A build that leaves the pack out never runs the routine, so it keeps
  nothing.

  **A format of the port's own** is a module that does `extend VBlank::Original::Packing::Format`,
  `unpacks :name` (with any settings and their defaults: `unpacks :enigma, base: 0`), and defines
  `self.routine(block)`: game code, written into the unpacking once. `block` is the `Packing::BlockKit`
  every format is written with, the library's too: `block.from`, `block.setting(:base)`,
  `block.byte(at)`, `block.variable(:name)`, `block.list(:name, capacity:, width:)`, `block.repeat`,
  `block.expect_size(n)`, `block.write(value)`, `block.written_byte(back)`, `block.written` and
  `block.rewrite(at, value)` (a byte the block wrote, written again once what it holds is known: a
  length, a count), `block.finished`,
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
- **A view: some of a slot's bytes, read in another shape.** A slot has one shape, and a console keeps
  several things in one block: its video memory holds tiles of sixteen colours, tiles of a byte a pixel
  and maps, side by side. A port that keeps the block as one slot reads each part through a view, so its
  unpacking writes the bytes once:
  - `pack[:video].as_tiles(at: 0x8000, count: 256, colors: 256)`
  - `pack[:video].as_numbers(at: 0xC000, count: 1024, width: :byte, signed: false)`
  - `pack[:video].as_colors(at: 0x40, count: 16)`, `.as_pixels(at:, count:)`, `.as_samples(at:, count:)`

  `at:` is a byte of the slot, 0 first, whatever the slot's own shape, and `count:` how many tiles,
  numbers, colours, pixels or samples the view holds; **`count:` left out reads to the slot's end**. Each
  takes what the `slots.` line of its shape takes (`colors:`, `width:` and `signed:`, `layout:`,
  `byte_order:`) and is read in the original's layout unless it names one. What comes back is a handle
  like any other: every verb takes it as it takes a slot of that shape, all-in-one and with the pack
  left out, and it narrows as one does (`.tile(4)`, `.tiles(...)`, `.numbers(first, count)`, `.bank(n)`,
  `.pixels(...)`, `.number(i)`, `.envelope(i)`). A view of a view counts its `at:` from the first view's
  start. The pack holds the slot and nothing for a view, and nothing in a runtime knows of one: to a
  build that reads its pack as the game starts a view is a place in the file, as a slot is. The banks of
  a view of colours are the lists `:<slot>_at_<byte>_<bank>` (`:video_at_64_0`).
  **Friendly errors at the line**: a view that ends after its slot ends; an `at:` that is no byte of the
  slot; bytes to the slot's end that are no whole number of items when `count:` is left out; a view
  asked of tiles, a bank or a run of a slot (ask the slot itself); `.frame` on a view (a frame is read
  from a slot the pack names); and a view given to a verb that reads another shape, as for a slot.
  Not offered: a view as notes, which are records the unpacking writes into a slot of their own.
  Worked examples: `test/pack_slot_view_games.rb` (one slot of video read by a background as
  sixteen-colour tiles and by a turning one as a byte map over tiles of 256 colours),
  `test/console/gba/vblank/builder/test_pack_slot_views_on_the_advance.rb`,
  `test/all/vblank/dsl/test_pack_slot_views.rb`.
- **`number`, `envelope`, `snes_envelope` and `frame` count from the slot's first number**, so each is
  refused on a run (`pack[:bytes].numbers(8, 16).number(0)`): ask the slot itself, or a view of it.

```ruby
# One slot for a stretch of the original's video memory, read three ways.
pack = data_pack from: ORIGINAL, version: "1.0" do |slots|
  slots.tiles   :video,        count: 2048, colors: 16     # 64 KB, filled by the unpacking
  slots.numbers :city_map,     count: 1024, width: :half, signed: false
  slots.colors  :title_colors, count: 256
  slots.fill_from_copy { |copy, pack| … }
end
video = pack[:video]
background :city, tiles: video, map: pack[:city_map], colors: pack[:title_colors], across: 32
sword = background :sword, tiles: video.as_tiles(at: 0x8000, count: 256, colors: 256),
                           map: video.as_numbers(at: 0xC000, count: 1024, width: :byte, signed: false),
                           colors: pack[:title_colors], across: 32
sword.turns_around(120, 72, map_point: [128, 128]).scale(2.0)
```

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

**A slot is kept in the layout of the console the original is for**, where VBlank reads that console's
layout, and the pack holds the bytes as the original has them (unpacked, where the original packs them).
**Every other platform's slots are in VBlank's own layout**, which the port's unpacking writes from however
its original keeps them, as it writes map cells and notes. The original names its platform:
`Original::Game.new(..., platform: :gbc)`, `:gba` (the default), `:gbc`, `:snes`, `:genesis`, `:ps1`, `:pc`
for a computer game, or any other name of lowercase letters, digits and underscores (`:arcade`, `:nes`).
A name a letter or two from one of those six, or the same but for case or punctuation (`:gbcc`, `"GBA"`), is
refused as a typo, naming the one it looks like, since its slots would be read in VBlank's own layout and show
a wrong picture with no error; a new platform with such a name (`:ps2`) adds `new_platform: true` to the line. VBlank reads each layout
itself, for every build and every console the port is built for:

| platform | tiles | colours | numbers |
|---|---|---|---|
| `:gba` | 16 colours, 32 bytes, the left pixel in a byte's low half | 2 bytes, 5 bits each, red lowest, low byte first | low byte first |
| `:gbc` | 4 colours, 16 bytes: each row's bit 0 plane, then its bit 1 plane, the left pixel in bit 7 | as the Advance's | low byte first |
| `:snes` | `colors: 4` as the Color's; `colors: 16`, 32 bytes: planes 0 and 1 for all eight rows, then planes 2 and 3 | as the Advance's | low byte first |
| `:genesis` | 16 colours, 32 bytes, the left pixel in a byte's HIGH half | 2 bytes high byte first, `0000 BBB0 GGG0 RRR0`, each 3 bits widened to 5 as the Genesis shows them | high byte first |
| `:ps1`, `:pc`, any other: VBlank's own (`Console::VBLANK_FORMATS`, `layout: :vblank`) | `colors: 4` or `colors: 16`, 64 bytes, a byte a pixel row by row, each a place in the tile's bank (its low 2 or 4 bits read), so a map cell's bank still picks the colours | as the Advance's; `write_color` narrows the original's | low byte first, unless the slot names `byte_order:` |

A console's layout is a shortcut a port of any platform can still name (`layout: :gba`), where its
unpacking writes that console's bytes. Naming the PlayStation's layout is refused, since VBlank reads no
data in it: leave `layout:` out. Worked example of VBlank's own: `test/made_up_vblank_layout_originals.rb`,
a PlayStation, a computer and an arcade original, each held to the same screen drawn by the game.

Two layouts are no one console's, since a byte is a byte in every layout: a tile of 256 colours, a byte a
pixel (`Console::BYTE_A_PIXEL_TILES`, `slots.tiles ..., colors: 256`), and a map of one byte a cell, each
the number of a tile with no turn and no bank (`Console::BYTE_MAP_CELLS`, a background's `map:` given a
slot of numbers `width: :byte`). Together they are how a console keeps the layer it turns and resizes.

Each console's layout is numbers in its hardware file (`Console::GBCHardware::ORIGINAL_FORMATS` and the
rest), named by its kit (`Console::Kit#original_formats`); one reader reads any of them
(`IR::FormatReading`, and `rg_start_file_fill_picture` in the C, JavaScript and Ruby runtimes, which reads
a slot of pixels, one byte each in any layout, the same way). On the Color, a tile drawn by
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
- `sample`/`instrument` with `rate: pack[:tuning].number(3)`, `holds_from: pack[:loops].number(3)` or `envelope:
  pack[:shapes].envelope(3)` — the recording's settings. The build works a play and a note out from them (how fast a
  voice reads the recording, how far back a held note reads, the shape's four numbers), so the program holds a
  stand-in for each number worked out and the runtime writes it again from the file at power-on
  (`IR::StartFile::RecordingSettings`, the mix feature's `rg_mix_fill_steps`, `_holds` and `_shapes`). It sounds as the
  all-in-one build does, played by the game, a song or a sound effect. **Nothing the pack holds stops the game**,
  built either way: a rate below 1 plays as 1, so the recording all but stands still, and a hold outside the
  recording is its first sample or its last. Built all-in-one the numbers are held by the same rules
  (`IR::StartFile.rate_held`, `.hold_held`), so the two builds sound alike. The same numbers written in the game
  are a friendly error. **A hold with every bit set is none**
  (255 in a byte, 65535 in two, 4294967295 in four, -1 where the slot goes below zero; `IR::StartFile.no_hold?`):
  the recording does not loop, and sounds as one written without `holds_from:`, built all-in-one too, so one slot
  of holds can say which recordings loop and which play once. **`length: pack[:lengths].number(3)`**
  is how many of the slot's samples the recording plays: the slot holds the most a recording can be, and a
  recording that reads back to an earlier sample does so from its own end, not through the rest of the slot.
  The build holds the whole slot's room and the runtime writes the length at power-on (`rg_mix_fill_length`,
  `rg_mix_fill_backs`); one below 1 is 1 and one past the slot is all of it. Built all-in-one, the length is
  held the same way (`IR::StartFile.length_held`), so a recording the player's copy does not have, written as
  nought, builds both ways and plays one sample; a hold the game wrote past that length is the last sample. A
  length the game writes itself outside the recording is a friendly error. **`rate:` from the pack on the Advance
  needs the game to name the rate its sound is mixed at**, `enable_sound mix_rate: 13379` (`sound.md`): there the
  sound is mixed at the rate most recordings have unless the game names one, and a build that does not know the
  rates cannot work that out, so without `mix_rate:` it is refused naming the recording. A console whose
  recordings play at one rate (the Super Nintendo, the PlayStation) needs nothing. `holds_from:` and `envelope:`
  work everywhere. `envelope: pack[:adsr].snes_envelope(3)`, three bytes as the Super Nintendo's sound chip keeps
  them, is worked into the nearest ordinary envelope at power-on (`Audio::SNESEnvelope#closest_envelope`, written
  again in each runtime's `rg_mix_fill_shapes`), and `brr: pack[:horn]` is decoded at power-on (above). Worked
  example: `test/pack_sound_tests.rb`.
- `Score::Part.new(notes: pack[:title_0].notes(instruments: %i[horn bass]), ...)` in `songs` and `sound_effects` — a
  part's notes. **The Score must give `length:`**, in ticks, since where the last note ends is in the pack; one
  without it is refused at the line. **A `length:` (and a `loop_from:`) that is a number of the pack** comes with
  `longest:`, the most ticks the song can last: the program holds that as the song's length and the runtime
  writes the song's own over it at power-on (`IR::StartFile::SongLength`, `rg_music_fill_song_length`), before
  its parts' notes are made. Then every part of the Score reads its notes from the pack, since a part written in
  the game is worked out as it is built; each is refused at the line otherwise. A length past `longest:` in the
  player's file plays as `longest:`, and a loop tick on or past the end comes round to the start. The build knows how many notes the slot holds and none of them, so the
  program holds room for the most events they can make (two for each note, a note and the rest it ends in) and
  the runtime makes the part's events from the file at power-on (`IR::StartFile::Notes`,
  the music feature's `rg_music_fill_notes`), by the rule a Score's notes become events by: in the order of their ticks, a rest
  where a note's length runs out before the next begins, the later of two on one frame, none past the song's
  end, and each part put right where the song comes round. The build hands the runtime the frame of every tick
  and what every key, instrument and volume comes to on the part's voice, so a part can be on any voice and be
  transposed. It sounds as the all-in-one build does. **Nothing the file holds stops the game**, where the
  all-in-one build refuses the same records: a key past 127 is a rest, and an instrument the part does not name
  or a volume past 15 is the part's own. A part that moves its pitch so far that some key from 0 to 127 is past
  its voice is refused at the line, since any key may be in the pack. Worked example:
  `test/pack_scores_at_start_tests.rb`.
- `background :city, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: 32` — a background of the
  original's own tiles, map and colours (`backgrounds.md`). The program holds a tile for each cell of the map,
  see-through until the runtime reads the map at power-on and fills each from the cell's tile, turn and bank
  (`IR::StartFile::Background`, `rg_start_file_fill_background`). Each bank of the slot is a list named
  `:<slot>_<bank>`, as built all-in-one, which `draw_with` takes to give that bank a list of the game's own.
  The build does not know a bank's colours, so a bank's list holds a marker for each, as a list declared from
  the pack does (below): `color_walk` of a bank, `recolor` with one, a picture drawn in one and a bank drawn
  with another all show what the all-in-one build shows. One list given alone (`city.draw_with walk, showing:
  step`) draws every bank, since the build cannot tell which bank the map uses. **A background that follows more
  than one bank the game recolours** (`city.draw_with({ title_0: :title_0, title_3: :title_3 })`, then `recolor` of
  each, which is how a title's palette lines are faded apart) **works as built all-in-one**: when a list is told what
  to hold, only the tiles of its own bank change, and which cells are of which bank is in the file, so the runtime
  works that out at power-on from each cell's bank (`rg_start_file_fill_followed_tiles`) for the copy a list's
  write makes (`rg_background_follow`).
  **The cells it is told it may be written later (`set_cells:`) work as built all-in-one**, on a map of map
  cells as on one in a console's layout: a told number (or map cell) names its tile, turn and bank, so the build knows everything of a told tile but its pixels. Each is a picture of the
  background's own, read from the file at power-on as any picture of a tile from the pack is
  (`rg_start_file_fill_picture`) and drawn in its bank's list, and `set_cell` writes it. A told tile that draws
  nothing is a picture that is see-through all over. The program's tiles for such a background are a stand-in
  for each bank, then the told tiles, then the map's. Plain `set_tile` on it stays a friendly error, since which
  tiles the map draws is in the file. **Cells told by a slot of map cells (`set_cells: pack[:changes]`)**, which
  the unpacking fills with every cell the screen changes to, are known only once the file is read: the program
  holds a stand-in tile for each place of the slot, and the runtime paints each from its cell at power-on as it
  paints a cell of the map (`IR::StartFile::Background#told_at`, `rg_start_file_fill_background`), in every set
  of colours and following its bank's list (`rg_start_file_fill_followed_tiles`); `set_cell` names a place.
  Nothing the file holds stops the game: a cell naming a tile past the slot draws nothing.
  Worked examples: `test/pack_background_tests.rb`, and `test/pack_background_set_cell_at_start_tests.rb` for the
  cells written later.
- `screen :tiled, backdrop: pack[:palette]` (also `.bank(n)` and `backdrop_place:`) — the screen's backdrop,
  on the game's own `screen` line or a scene's. The program holds no colour for it: the screen keeps where
  the colour is in the file (`IR::StartFile::Color`), and the runtime reads it at power-on into an array of
  the game's own, which each `screen` and each scene arriving reads (`rg_start_file_fill_colors`). A `fade`
  or `tint` moves it with the picture, as built all-in-one. A place the slot does not have is refused at
  the line, since the slot's size is the game's own word. Worked examples:
  `test/pack_backdrop_at_start_tests.rb`, and for each scene's own under a tint,
  `test/console/gba/vblank/builder/test_pack_backdrops_at_start_on_the_advance.rb`.
- `colors :logo_cycle_3, pack[:logo_colors].bank(3, size: 11)` (or the whole slot) — a list of colours. The
  program holds none of them: the list holds a MARKER for each, a number where a colour would be that names
  where the colour is in the file (`IR::StartFile`, "MARKERS"), so the list goes wherever a list goes: a picture's
  or a sprite's `colors: :logo_cycle_3`, `draw_with`, `recolor`, `screen :tiled, backdrop: :logo_cycle_3`. The
  runtime reads the colours at power-on into the same array a backdrop's colour is in
  (`rg_start_file_fill_colors`) and puts each where a marker is (`rg_start_file_fill_marked_pixels`).
  **A marker names a recipe for one colour** (an entry of `IR::StartFile#colors`): a colour at a place of the file
  (`Color`), a step of a walk of one (`WalkedColor`, or `CountedWalkColor` for a walk that waits for a falling count), or a colour of a list that a number in the file picks
  (`ChosenColor`). So whatever of a picture's colours is the player's data rides on markers, and no verb is taught it:
  the 256 colours of a picture of pixels, and the bank a pose's frame names, are these too.
  **`color_walk` of such a list makes its steps at power-on**, each colour from the file's by the sum the build
  uses (`Graphics::Color.walked_toward`, `rg_start_file_walk_colors`; for `step:` and `count:`,
  `Graphics::Color.counted_walk`, `rg_start_file_count_walk_colors`). Place 0 keeps the slot's colour, as
  built all-in-one. **What the game paints from a list as it runs** (`image ..., from: list`, `tiles ..., from:
  list`, `canvas`, `sprite_tiles`) **takes such a list too**: a build for a computer draws those through tables of
  the colour each place shows, which it writes with their markers and fills at power-on
  (`rg_start_file_fill_marked_numbers`), and a canvas in such a list `blit`s a picture drawn in it. **A picture given as colours** (`data:`, `from:`, art in characters, the
  last with `colors: pack[:palette]` on its line too) **is drawn as it is**, since its pixels are the game's own
  colours; the build cannot hold them to a list it does not hold, so a pixel in a colour the list lacks is not
  told there. The build cannot compare two colours it does not hold, so one thing is refused at the line: such a
  picture drawn with another list (`draw_with`, `recolor` of its list, a background told other colours), which
  swaps by each pixel's place in its own list; give it `places:`. A picture given as colours in a list of the
  game's own that holds one colour at two places, drawn with such a list, is swapped by the first of them, as
  all-in-one where the file holds one colour at both. A game may read 32766 such colours,
  the steps of its walks among them. Worked example: `test/pack_color_list_at_start_tests.rb`.
- `image :balloon_0, tiles: pack[:sprites], frame: pack[:frames].frame(at, layout: FRAME), origin: [32, 48], colors: :balloon,
  size: [64, 64]` — a pose that is one of the original's own frames (`sprites.md`). How many pieces the frame has and what
  each is is in the pack, so the game gives `size:`, the picture's size, and a pose with none is refused at the line. The
  program holds zeros of that size and where the frame's record and its tiles are in the file (`IR::StartFile::Pose`), and the
  runtime paints each piece into the picture at power-on (`rg_start_file_fill_pose`), the earlier in front where two
  overlap. `colors:` is the game's own list, or a slot or bank of the pack's colours. **A pose that takes its colours from the bank
  its frame names** (a layout with `bank_bit:` and `colors:` a whole slot, `sprites.md`) **is drawn in that bank's colours**: which
  bank is a number in the file, so the pose's list holds a marker for each place of "the bank this frame names"
  (`IR::StartFile::ChosenColor`, picked by an `IR::StartFile::FrameBank`), which the runtime fills at power-on from the bank the
  frame's front piece keeps in its record (`rg_start_file_choose_colors`); the pose is then filled as any pose that holds its
  colours. The build cannot NAME that list, so `colors_name_of` of such a pose is a name standing for it
  (`IR::StartFile::Pose#bank_lists` keeps the bank lists' names): once the file is read the pose is a picture of the list
  `:<slot>_<bank>` its frame picks, and a sprite told `draw_with` that name, or to follow its poses' lists (`draw_with` given a
  hash), follows that list, the runtime writing which one as it starts (`rg_start_file_frame_bank`). `bank:` paints only the
  pieces whose record names that bank, drawn from that bank's list. A frame of two banks in the player's file, which the
  all-in-one build refuses, is drawn whole in its front piece's bank and follows that bank's list. On a
  console whose build keeps one list for a whole sprite (the Advance), one sprite may show two such poses of one slot, as
  all-in-one where their frames name one bank; where the player's file names two, which the all-in-one build refuses, each
  pose is drawn in its own frame's bank. Nothing the file holds stops the
  game: pieces are read while they end inside the slot, a piece outside the picture is not painted, and a tile past the
  slot paints nothing. The build sees a whole box, as for a picture. Worked example: `test/pack_pose_at_start_tests.rb`.
  **The layout is read once, by the pack's unpacking.** A frame's slot holds the original's bytes, and the game's
  `Original::FrameLayout` says how the original keeps a frame. Once every slot is filled, copied as it is or by
  `slots.fill_from_copy`, the unpacking reads each frame the game names and writes it after the pack's last slot as a
  record of VBlank's own, one layout whatever the original (`Original::FrameRecord`, whose file says the layout;
  `Original::FrameRewrite` writes it, as game code). A piece of a record names its tiles and its bank of colours and
  holds no pixel. The build that holds the pack, the interpreter and each runtime read that record and know no
  layout, so a way of keeping a frame that no layout says yet is added to `FrameLayout#piece_from` alone, in Ruby
  (`tile_high_bit:` was, and `test/pack_pose_of_split_tiles_at_start_tests.rb` plays it on every build). A port need
  not wait for that: `FrameLayout.new(..., piece: READER)` reads a piece with a few lines of its own Ruby, given the
  values its pose names (`frame(at, layout:, with: { block: 5 })`), and the unpacking runs those lines as game code
  (`Original::FrameReader`, `sprites.md`). A frame's values are a row of the unpacking's table of frames, so one
  frame given two sets is two records. The game's
  source does not change: the
  slot is still a slot of bytes and the frame still `frame(at, layout:)`. Worked example:
  `test/frame_record_unpacking_tests.rb`.
- `image :spin0, tiles_from: :ball_tiles, frame: pack[:frames].frame(at, layout: FRAME), first_tile: 0x40, origin: [8,
  16], size: [16, 16]` — **a pose of a set of sprite tiles whose pieces are one of the original's frames**
  (`sprites.md`, `sprite_tiles`): a retail game whose sprite memory holds a few tiles it rewrites, and whose frames name
  them. `first_tile:` is the number the frames give the set's first tile, so a frame's tile 0x42 is the set's tile 2;
  each tile of each piece is a piece of the pose, its top left from `origin:` as a pack pose places them. The pose draws
  no pixel of the pack: its pieces say which of the set's tiles go where, and the tiles are what the game loads with
  `copy_from`. Built all-in-one the frame is read as the game is built and the pose is the pose of pieces a port would
  write by hand, so every console that draws a set's poses draws it; a frame the set cannot draw is refused at the line
  (a piece naming a tile outside the set, a piece turned, off the 8-pixel grid, or left of or above the picture). With
  the pack left out the game gives `size:`, the program holds a stand-in piece for each place of the pose's grid and
  where the frame's record is (`IR::StartFile::TilePose`), and the runtime writes the frame's pieces over them at power-on
  (`rg_start_file_fill_tile_pose`). Nothing the file holds stops the game: a tile the all-in-one build refuses draws
  nothing, and of two tiles at one place the earlier is drawn. Worked example:
  `test/all/vblank/builder/test_pack_tile_poses.rb`, and `test/pack_tile_pose_at_start_tests.rb` with the pack left out.

- `place :mine, points: pack[:points], faces: pack[:faces], faces_used: pack[:sizes].number(0), pictures: [...]`,
  `shading :fade, colors: pack[:palette], levels: pack[:fades]` and `viewer :eye, at: ..., facing: ...` given
  numbers of the pack — a 3D level, its light and where the viewer starts (`places.md`). The place's points
  and faces are records of VBlank's own the unpacking writes, read as tables (each written as its size alone
  and filled at power-on); `faces_used:` is a table of one number, and a drawing draws that many faces, held to
  0 and the slot's count. The shading holds zeros of its colours and levels and where they are in the file
  (`IR::StartFile::Shading`), which the interpreter reads as it starts and each runtime writes into the array
  a lit fill reads (`rg_start_file_fill_colors`, `rg_start_file_fill_places`). The viewer's spot and arrows are
  set from tables of three and nine numbers where it is declared. **Nothing the file holds stops the game**:
  a point or picture number a face names past the place's is held to the last, and a shading's place past
  its colours is place 0. Built all-in-one the same tables are drawn, so both builds draw alike. Worked
  example: `test/pack_place_games.rb`, held to the same room written in Ruby by
  `test/interpreter/vblank/builder/test_pack_places_interpreter.rb`.

  Any other verb that reads a slot's bytes is refused at the line. So is a verb that works out its data from a
  picture's pixels as the game is built, where the picture's places are in the pack: `sprite_tiles ... copy_from
  :picture` is refused there, since the build holds none of the picture's tiles; copy from a `table` of the
  tiles' bytes, or build all-in-one.

  **One test holds every one of these to its all-in-one build.** Each verb above has a small game in
  `test/pack_games.rb`, built both ways on the interpreter and the C, JavaScript and Ruby builds and held to the
  same picture and sound on every pass, or to its refusal (`test/pack_parity_tests.rb`; `.claude/testing/lowerings.md`,
  "A game that reads a data pack"). A game's own suite does the same with `VBlank::Testing::PackParity`.
- `pack.unpacking(release: RELEASE)` — the unpacking program for a copy of that release (an
  `Original::Release`, with its name and size), built with no copy; it is handed the copy as its start file, and
  `pack_file_in(run, sha1:, build_version:)` after its halt is the pack file: `slot_bytes_in(run)`, each slot's bytes,
  and `frame_records_in(run)`, the record of each frame of a sprite the game names. Ask for it once the game is
  declared, since it writes a record for each frame named by then.
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
showing its bar however long the routine works between writes; closing the window then keeps no pack.
The desktop program does the same with a thread of its own (`play_part_on_thread`, `rg_sdl.c`), and
the web page with a worker (`rg_shell_unpack_in_worker`, `rg_shell.js`).
**A pack an older build kept is routine, and is never told as a failure.** A port grows a part at a
time and each part changes its pack (`version:`, or a slot more), so a player who takes a new build
starts it over the old build's pack. That pack fails the check, and the shell then starts at its menu as
on a first start, with one sentence under the menu's lines: "This version must read the game's data
again. Load your copy of TITLE." (`Original::Shell.read_again_sentence`), where TITLE is the
**original's** title (`Original::Game`'s `title:`), what the player owns, never the port's own name.
LOAD ROM writes the new pack over the old one. No box, no path and no byte counts are shown; why the
pack was not read goes where a program's complaints go (the error stream, the terminal, the browser's
console) for whoever made the build, and to `Live::Shell#play`'s `kept_pack_refused:`, which the
shell check listens to. The menu learns it from its start file's second byte.
**Nothing a shell tells the player stops the program.** A file refused, or an unpacking that
stopped, is told in words the player can close and the menu plays on under them: the desktop program
draws its own box over the picture (`rg_window_tell`; a button pressed closes it too), where a box
of the system's, put up as the program started, could not be answered on a Mac. SETTINGS opens the
window's menu.
**The line chosen shows as chosen**, in yellow for a few frames (`Original::Shell::CHOSEN_FRAMES`),
before the file chooser opens or the settings do, and stays up behind them. **It is one window (one
device, one canvas) from the menu to the game**: the chooser is that window's own, the unpacking's
bar is drawn in it, and a chooser closed with nothing picked, or a file refused, shows the menu
again with its cursor on the line it was left on (the menu's `shell_line`, handed back to it as the
first byte of its start file). The menu sets `shell_choice` to 1 for LOAD ROM and 2 for SETTINGS as it halts.
The web page (`--format web --shell`) and the desktop program (`--format native --shell`, a folder) do
the same, each made from `Original::ShellFacts`, every sentence they refuse a file in among them. Every
release reads one slot list. Worked example: `test/lowering/ruby/vblank/live/test_shell.rb`.

**The first screen** — `shell_screen do |first| … end` makes the screen a shell opens on the game's
own. With none, VBlank writes it: the game's title in capitals (letters the built-in font lacks left
out), LOAD YOUR COPY OF THE GAME, and the lines LOAD ROM and SETTINGS, gray, white under the cursor
and yellow once chosen, on black.

```ruby
VBlank.game "AEON PORT", consoles: %i[gba] do
  pack = data_pack(from: ORIGINAL, version: "1.0") { |slots| … }
  shell_screen do |first|
    font :runes, glyphs: RUNES                      # declared here, for this screen
    image :sky, width: 240, height: 160, data: SKY
    first.font :runes
    first.title "ÆON"                               # letters the built-in font lacks
    first.needs "LOAD YOUR COPY OF ÆON"
    first.colors title: :yellow, line: :gray, cursor: :white, chosen: :cyan, ground: :blue
    first.picture :sky
    first.line "CREDITS", shows: :credits
    scene(:credits) { draw_text "A PORT BY US", :center, 40, :white, font: :runes }
  end
  …
end
```

- **The words.** The *screen* is this first screen. A *line* is a row the player can put the cursor on
  and choose; LOAD ROM and SETTINGS are lines, and are always there. The *title* and what the game
  *needs* are words above the lines. A line is plain, under the *cursor*, or *chosen*. The *ground* is the
  colour behind everything, and the *picture* is drawn over it, under the words.
- **The block is a program of its own.** This screen plays before the game can: the game's program
  does not start without its data pack. So the block is not run as the game is built. A shell build
  runs it as game code on the program that is the first screen, the way the unpacking routine has a
  program of its own. A font, a picture or a scene the screen uses is declared **inside the block**,
  with the verbs a game declares them with (`font`, `image`, `scene`, `func`, `var`); one declared
  outside it is the game's and is not there. Share art between the two with a Ruby constant or method.
- **Nothing here may come from the data pack.** The screen shows before the player's copy is read, so
  the pack holds nothing yet: no font, picture, colour or sound of the original's. A slot given to
  `first.` anything, or to a verb in the block, is a friendly error saying so.
- `first.font :runes` — the font every word of the screen is written in, a font of glyphs (a block of
  `glyph`s or `glyphs:`). It is how a title in letters the built-in font lacks shows at all. A font of
  pictures is refused, since a line changes colour. Every word the screen writes must be in the font,
  LOAD ROM and SETTINGS too, or the error names the letters.
- `first.title "ÆON"`, `first.needs "…"` — the title's words and the words of the line under it. A
  game's own title is written as given, never folded to capitals. `""` leaves either out.
- `first.labels load_rom: "CARGAR ROM", settings: "AJUSTES"` — the words of the two lines VBlank
  keeps, for a font without their letters or a game in another language. The lines stay and do what
  they do.
- `first.colors title:, needs:, line:, cursor:, chosen:, ground:` — any of the six; the rest keep
  VBlank's.
- `first.picture :sky, at: [0, 0]` — one picture behind the words, over the ground.
- `first.line "CREDITS", shows: :credits` — **a line of the game's own**, under LOAD ROM, or under
  SETTINGS with `under: :settings`. **What a line may do is a short list, since the shell is not the
  game: it shows a scene written in the block and comes back.** Chosen, it shows as chosen as LOAD
  ROM does, then the scene is called every pass over the ground's colour until the player presses A,
  B or Start, and the menu is back with the cursor on that line. Credits, how to get the game, the
  controls. It cannot ask for the copy, start the game or end the shell. Not made yet: a line that
  opens a web address, and a line that sets something the game then reads.
- **Where the words go**, in a font H rows tall: the lines from the screen's middle down, H + 5 rows
  from one to the next; the needs line two such steps above the middle; the title H + 9 rows above
  that. With the built-in font that is the screen as VBlank writes it.
- **Friendly errors**, told when the game is built as a shell and naming the block's line: a slot of the
  data pack; a line with no `shows:`, or one naming a scene the block does not have; more lines than
  fit the screen in the font; a font too tall for the title; words wider than the screen; a letter the
  font lacks; a picture the block does not declare; a colour for a part the screen does not have; a
  second `shell_screen`.
- **What stays VBlank's**: LOAD ROM is choice 1 and SETTINGS choice 2 to every runtime wherever they
  stand; the words a file is refused in; the sentence about reading the data again, written in the
  screen's font where the font has its letters and in the built-in font where it does not; the
  chosen line shown for a moment; the cursor kept; the desktop program's one window.
- **A cartridge holds nothing of it**: only a shell build runs the block, so a mistake in it is not
  told by a cartridge build. Worked examples: `test/shell_screen_tests.rb` (the game, and the same
  screen drawn by a plain game, which every runtime's test holds it to pixel for pixel) and
  `test/all/vblank/builder/test_shell_screens.rb` (what is refused).

**A port's shell check** — `rake shell:check`, from `Original::ShellCheckTasks` in the port's Rakefile
(`t.game_file`, and `t.console` and `t.tape` if wanted), or `Live::ShellCheck.new(game, tape:).run` — does
what a player does with nobody at the controls: builds the shell with no copy in reach, starts it with
the copy this machine names, holds the pack it keeps to the all-in-one build's byte for byte, starts it
again with that copy out of reach, and plays the tape (300 passes with nothing pressed without one) on
both starts and the all-in-one build, holding every picture and sound to that build's. A machine that
names no copy fails with `NotSet`'s words. Worked example: `test/lowering/ruby/vblank/live/test_shell_check.rb`.

**The pack file** (`Original::Pack`): `"VBLANKPK"`, the format version (2 bytes), the copy's SHA-1 (20
bytes), the build version (a length byte and the text), the slot count (2 bytes), each slot's name (a
length byte and the text) and size (4 bytes), then each slot's bytes, then to the end of the file the
record of each frame of a sprite the game names (`Original::FrameRecord::Section`: a directory of four
bytes a frame, then each frame as four bytes and sixteen a piece; nothing for a game that names no
frame). A file that is not a pack, is cut short or is in another format is refused with
`Original::WrongPack`. **The format is 2.** A pack kept by a build before the frame records is format 1,
so a shell's check refuses it and the player's copy is read again, as the menu says.
