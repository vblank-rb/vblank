# DSL reference: Pools (what an Array of Structs builds as)

The map of every page is `.claude/rules/dsl-reference.md`. A game does not write a pool. It writes
a Ruby Array of Structs, as PLAIN_RUBY.md ("An Array of Structs") and `plain-ruby.md` ("Arrays")
teach, and an Array that game code puts Structs into and changes builds as a pool. This page is for
the reader of the build: what that pool costs, the settings it takes and where they are written,
and what the build does with it. Every example here is plain Ruby, and each builds and plays as
written (`test_dsl_page_examples.rb`).

## What plain Ruby builds

`sparks = Array.new(capacity: 32)`, with game code putting `Spark.new(...)` into it, builds
`pool :sparks, x: 0, y: 0, vy: 0, capacity: 32, on_full: :stop` (`Composition#declare_pool` with
`struct_fields: true`, through `DSL::StructArray`): one field for each member of the Struct, each
starting at 0, or 0.0 where a line puts a fraction in. The `pool` verb takes the same settings and
stays for the lowering's own tests and for a reader following a build; a game never needs it.

| Ruby | What the build does with the pool |
|---|---|
| `sparks << Spark.new(x, 0, 1.5)` (or `push`, `append`) | spawns a thing with those fields |
| `sparks.each { \|s\| ... }`, `each_with_index` | walks the live things, oldest first |
| `sparks.reverse_each { \|s\| ... }` | walks them newest first (`each(newest_first: true)`) |
| `sparks.delete_if { \|s\| ... }`, `reject!` | walks them, and removes those the test holds for |
| `sparks.shift` | removes the oldest live thing |
| `sparks.clear` | removes every thing |
| `sparks.size`, `length`, `count`, `empty?`, `any?` | counts the live things |
| `sparks.sort_by! { \|s\| s.y }`, `sort!` | puts the walk order in order of fields |
| `sparks.min`, `max`, `minmax` | one walk each, by the Struct's own order |
| `sparks.blocked_by(room)`, `sparks.put_in_layer :walking` | VBlank's words: the pool's own, told on `collision.md` and `layers.md` |

**Where each setting is written:**

- `capacity:` and `fast:` on `Array.new`. `capacity:` is needed; `fast:` is told on `lists.md`
  ("Where it lives"), and a pool moves all its columns together.
- `drawn_as` in the Struct's block takes what `pool` takes for its pictures: `drawn_as :spark` is
  `image: :spark`, and `drawn_as facing: {...}, frames: [...], rate: 8` is `facing:`, `frames:` and
  `rate:`. `drawn_as :spark, layer: :swimmers` makes the pool inside that `layer`.
- `narrow` in the Struct's block is `widths:`: `narrow :x, :y` keeps those fields in a half each,
  and `narrow kind: :byte` in a byte.
- `on_full:` has no setting: an Array of Structs is always `:stop`. The other two are written in
  Ruby: `sparks.shift if sparks.size == 32` before `<<` is `:recycle_oldest`, and
  `sparks << s if sparks.size < 32` is `:drop`.
- `layout:` has no setting: the build chooses, and today every console keeps a pool as `:lists`.
- `pool.func` (a routine for one thing) has no Ruby form yet: a Struct's method runs as game code
  where it is called, and is written again at each place that calls it.

```ruby
# A shower of sparks, each falling at its own speed
Spark = Struct.new(:x, :y, :vy) do
  def fall
    self.y += vy
  end
end
screen :bitmap
sparks = Array.new(capacity: 32)
frame = 0
game_loop do
  frame += 1
  sparks.shift if sparks.size == 32
  sparks << Spark.new(frame % 240, 0.0, 1.5)
  sparks.each(&:fall)
  sparks.delete_if { |s| s.y > 150 }
  clear_screen :black
  sparks.each { |s| draw_rect_at s.x, s.y, 2, 2, :yellow }
end
```

Worked examples in the repository: `examples/sparks.rb` (a bitmap screen, the walk drawing each
spark), and `examples/shmup/enemies.rb` (a Struct `drawn_as facing: ..., rate: 8` whose enemies flap
and turn to face the ship they dive at).

## What a pool is

A pool is many of a thing that has named fields and behaves (bullets, enemies, particles), kept as
one list for each field, a column saying which slots are live, and a walk over the live ones, so the
fields can never fall out of step with each other and the cost model prices it per pool. A thing a
walk hands the block is an object of the game's own Struct whose fields read and write the pool's
lists for that slot (`s.y += s.vy`), and it answers what one thing of a pool answers
(`Pool::Instance`): `face`, `draw_with`, `move`, `can_move?`, `clamp_to_screen`, `overlaps?`, the
edges, the screen-edge tests and `index`, its slot. A thing kept in a name after its walk (`pick = s
if s.x == 10`) keeps its slot in a hidden variable, so the name stays on it after the walk.

## The walk order

**A walk goes in the order things were added**, oldest first, whatever slot each landed in: a thing
removed leaves the order, and a new one always goes last, even in a slot an older one gave back.
That is the order a player can see. Things that each roll `rand` in the walk roll one after
another, so the same seed gives each thing the same numbers however the slots were shuffled by what
came and went before; and things that act on each other or on something shared act first come,
first served. It is how a console game keeps the things in a room.

**During a walk**, a thing removed before its turn is passed over and every other thing is visited
once, and a thing added during the walk is first visited by the next walk, so a thing that splits in
two does not split again in the same pass. A thing removed during a walk keeps its slot until the
walk ends, so a `<<` in the same walk takes a different slot, and a pool that had no room still has
none: a `<<` written in a walk after a `shift` written in the same walk stops the build, and a `<<`
in the walk that needs a place a routine the walk called took out stops the game saying so. The new
thing goes in after the walk. The walk goes through the live things only, so it costs what is live rather than
the capacity. Each walk written in the game keeps three variables of its own, so a walk inside
another walk of the same Array keeps its place.

**`reverse_each` walks the other way**, newest first, for a game where the last thing added has to
act first (which of two things in reach is struck, when the newest should win). It is the exact
reverse of the plain walk, and every rule above holds the same way round. It costs the same as the
plain walk. It changes only the order that one walk visits things in: which thing is drawn in front
stays as below.

**`sort_by!` and `sort!` change the walk order, and so the drawing order**: the live slots are
gathered, sorted by the field's list (the `list_sort` step a list's sort uses) and the order linked
again, one routine per line, named in `rom.profile`. A key of several fields (`{ |s| [s.y, -s.x] }`,
a `SortOrder::Key`) is one `list_sort` for each field, the last first, since `list_sort` keeps level
slots in order. A sort inside a walk of the same Array, or in a routine a walk may call, is refused:
sort after the walk.

## Drawing order, and what it costs

Where two things of one pool overlap, the one added first is in front, whatever slots they landed
in. A thing added into a slot an older one gave back is still behind everything older than it, and
a thing a full Array takes the place of with `shift` then `<<` goes behind the rest, as the newest.
So a game that needs one of a pair in front adds that one first (a bed's cover, then its pillow
end), and the answer does not change as other things come and go.

**What it costs** is one walk of the live things a frame. Each of the console's sprite rows has a
fixed place in front of or behind the others, so before each frame is drawn the framework copies
where each live thing is, which picture it shows and which colours it draws with into the order
they are drawn in. That is one small routine per pool however many slots it has (`rom.profile` lists
it as "putting the sprites of pool :name oldest in front"), a few bytes of memory a slot, and time
for each live thing rather than each slot: measured on `examples/dive`, with its six fish and up to
twelve bubbles, the frame went from 3473 instructions to 4189, which is under half a hundredth of a
frame. A pool keeps a sprite place for every slot, and a game can keep 512 places though the console
draws 128 at once: what has to fit in 128 is what shows on one frame (see "the console's 128 places
for sprites" in `scenes.md`). **Against a plain sprite, a pool takes the place it was made in**, by
the rule two sprites follow: a sprite declared after the Array is made is in front of all its
things, and one declared before is behind them. A game that needs one in front puts it in a sprite
or an Array of its own, in a `layer`.

## A full Array

A `<<` onto a full Array of Structs stops the game naming it (`on_full: :stop`), in the words a full
Array of numbers stops with, where Ruby would grow it; the Advance cartridge drops the thing for
now. The pool's other two policies are written in Ruby:

- **`:recycle_oldest`**: `sparks.shift if sparks.size == 32`, then `sparks << ...`, so a new thing
  always appears (the usual choice for particles and effects). The oldest is the first in the walk
  order, so finding it costs one read whatever the capacity.
- **`:drop`**: `sparks << s if sparks.size < 32` skips the new thing.

The `pool` verb's `:recycle_oldest` has one exception the Ruby form does not: a thing added to a
full pool from inside that pool's own walk is dropped, since moving the walk's first thing to the
end would cut the walk short (or, newest first, carry it past where it ends).

## Things drawn as sprites

**`drawn_as :spark`** (with `screen :tiled`, and `x` and `y` members) draws each live thing as a
hardware sprite at its x and y: `<<` shows one, a removal hides it, and the console composites them.
Each thing then also has a collision box (its x and y plus the picture's size), so
`s.overlaps?(other)`, the screen-edge tests (`s.off_screen?`, `s.below_bottom?` and the rest) and
`s.clamp_to_screen` work for each. `drawn_as` on a Struct with no `x` or `y` is refused. An Array
made inside a `scene` belongs to the scene: its sprites show only while that scene is active.

```ruby
# Drops drawn as sprites, each falling by its own method
Drop = Struct.new(:x, :y) do
  drawn_as :drop
  def fall
    self.y += 2
  end
end
screen :tiled
image(:drop, "#" => :green) { "########\n" * 8 }
drops = Array.new(capacity: 4)
started = 0
game_loop do
  if started == 0
    drops << Drop.new(20, 0)
    drops << Drop.new(60, 0)
    started = 1
  end
  drops.each(&:fall)
end
```

**The code that draws a pool's sprites is written once, however many the pool holds**: every one of
them is drawn the same way from the same lists, so the build writes the drawing one time and goes
round it. That code is what the build tries to keep in the console's 32K of quick memory, so a pool
of forty-five asks that memory for what a pool of four does (a few hundred bytes, where a copy for
each was most of 20K) and costs a frame a handful of instructions more for each thing. **A slot
with nothing in it costs a frame next to nothing**: the places past the last live thing are marked
hidden, a store for each of a place's rows, before the live ones are written, so a pool sized for a
game's busiest room costs a quiet room what its live things cost, and a few instructions for each
empty slot. A pool whose things are kept out of a `fade … under:`, or that keeps one frame of its
pictures in memory at a time, still gets a copy for each, and so does every sprite declared by
hand; `rom.profile` shows the size either way. On a bitmap screen there is no `drawn_as`: the walk
draws each thing itself.

**Things face and animate, each on its own.** `drawn_as facing: {...}` or `frames: [...]` (with
`rate:`) in place of a picture's name: the same words a `sprite` takes, meaning the same thing,
`drawn_as rate: 6, facing: { left: [:walk_l1, :walk_l2], right: [:walk_r1, :walk_r2] }`. Name only
the picture facing right, and facing left is that picture mirrored; a `facing:` missing down takes
up's turned upside down. Inside a walk, `g.face :left` is the same verb a sprite has. **What is per
thing is the point:** the direction and the place in the cycle belong to each slot, so one test
written once leaves ten guards leaning ten ways in the same frame, and one added just now starts its
walk where it starts rather than in step with the rest. That is the pool's own bookkeeping, a hidden
slot beside the fields, never a member the Struct declares, and a slot reused by a later `<<`
starts fresh. **What it costs** is one counter for the whole pool deciding when a step happens, so
a frame that is not a step is one compare and a step walks the slots: a `rate: 6` makes that one
walk in six. Naming two picture sources, or a direction the drawing was not given, is a friendly
error.

**One thing drawn with other colours, the others as they are:** `e.draw_with :hurt` inside a walk,
and `e.draw_with :own` to put it back, as a sprite's `draw_with` (`sprites.md`). A pool of several
kinds, each kind's poses drawn from a list of its own, names each list and one list for all of
them: `e.draw_with({ propene: :white, denkyun: :white })`. A thing added into a slot starts in its
own colours.

## Members and their widths

**A member can have any name Ruby allows.** A pool keeps lists of its own beside the fields (which
slots are live, where each thing is in its animation, the order they came in), and none of them can
meet a field. A member named as what a thing answers (`left`, `move`, `index`) means the member in
a walk, as in Ruby. The `pool` verb refuses two kinds of field name, each a friendly error that
never reaches an Array of Structs: a name a pool's thing already answers to (`remove`, `index`,
`move`, `face`, `draw_with`, `left`, `right`, `top`, `bottom`), and one of `pool`'s own words
(`capacity`, `image`, `facing`, `frames`, `rate`, `on_full`, `widths`, `fast`). A pool's own name
cannot end in an underscore or hold two in a row.

**How big each field is: `narrow`.** A pool is one list per field, so a field left at its full
width costs four bytes a slot to keep a direction or a flag, and a pool is sized for the worst
moment of a game rather than a normal one. Naming the narrow ones is the single biggest thing a big
pool can do: measured on a port's guards, ten of thirteen fields narrowed freed about 3.7K of the
console's 32K, which the framework then gave to three more routines of hot code. `narrow` takes the
widths a list takes (`lists.md`, "How big one slot is"), `:unsigned_half` for a place in 256ths of a
pixel among them, with the same rule about going below nothing for the others (so a countdown is
safe), and the same friendly error for a width the framework does not know. A field that holds
fractions cannot be narrowed and says so: a fraction is mostly its own fractional part and needs the
whole word. **The pool's own bookkeeping is narrowed without being asked**, because unlike a field
the framework knows exactly what it holds: the live-or-not column is a byte whatever the pool is,
and the free-slot stack is as wide as the largest slot number needs.

```ruby
# Guards whose direction and hit points each fit in a byte
Guard = Struct.new(:x, :dir, :hp) do
  narrow dir: :byte, hp: :byte
end
screen :bitmap
guards = Array.new(capacity: 16)
guards << Guard.new(10, 1, 3)
game_loop do
  guards.each { |g| g.x += g.dir }
  guards.delete_if { |g| g.x > 200 }
end
```

**How the console keeps it.** How a pool sits in the console's memory is the build's to choose,
per pool, and the `pool` verb's `layout:` names one: `:lists` is a list for each field, the way
every console can keep a pool; `:tables` is the fields side by side, each read with one index;
`:records` is a record for each thing. A console has only the layouts its build makes (today every
console keeps a pool as `:lists`), and naming one it lacks is a friendly error that names the
console and the layouts it has. The layout never changes what the game does or what any field
holds, only how fast the console reaches them; the widths are always the ones `narrow` declared.
