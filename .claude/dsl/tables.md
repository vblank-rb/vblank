# DSL reference: Tables (build-time ROM lookup)

The map of every page is `.claude/rules/dsl-reference.md`. **On this page** has a line for each
verb here; the entries after it tell each one in full.

## On this page

- `table :name, array` → `Table`, ROM data read by index; `data_pack`, from a copy

## In full

- `table :name, ruby_array, width: :half, signed: nil` → a `Table`: a build-time Ruby array shipped as read-only ROM data, read at run time by a Value index. `t[i]` → a `Value` (like `list` indexing, but const/ROM); `length` is a build-time Integer. `width:` is the element size (`:byte`/`:half`/`:word`); `signed:` is inferred from the values (any negative → signed) unless you set it. An out-of-range index is made safe: a power-of-two table wraps it (what an angle wants), any other size clamps to the ends — and **the length you pick decides what a read costs**, because wrapping is one step and clamping is a test against each end, about twice the work. A length like 256 or 512 is the cheap one; round a sine table up to it and the reads get cheaper for nothing. Precompute what the console can't do cheaply each frame — a sine or reciprocal/distance table (see `examples/raycaster.rb`). A value that doesn't fit the width is a friendly build error. **A read is not free** — reaching an element costs about three plain steps, so a table read in a hot loop is real work rather than the single load it looks like. **On the Game Boy Color a game can keep as many tables as the cartridge holds.** Only 16K of the cartridge is always in view, so a table of a kilobyte or more is kept in the cartridge's banks, and in a game whose tables still do not fit, shorter ones go there too, the longest first. Reading a banked table puts its bank in view and puts the old one back, which costs a few dozen more instructions a read. A table a list is copied from with `copy_from` stays in view.
- `data_pack from: ORIGINAL, version: "1.0" do |slots| … end` → a `DataPack`: slots of colours, tiles and numbers from the player's copy of a retail original, made into a data pack as the game is built. `table :speeds, pack[:speeds]` and `image ..., colors: pack[:palette], places: pack[:walls].tile(0)` read a slot; the game holds only handles. The whole story is `.claude/dsl/original.md`.
