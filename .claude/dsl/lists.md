# DSL reference: Lists (what an Array of numbers builds as)

The map of every page is `.claude/rules/dsl-reference.md`. A game does not write a list. It writes
a Ruby Array of numbers, as PLAIN_RUBY.md ("Arrays") and `plain-ruby.md` ("Arrays") teach, and an
Array that game code changes builds as a list. This page is for the reader of the build: what that
list costs, the settings `Array.new` takes for it, and what the build does with it. Every example
here is plain Ruby, and each builds and plays as written (`test_dsl_page_examples.rb`).

## What plain Ruby builds

An Array written out (`[...]` or `Array.new(...)`), given to a local, that game code changes with
an Array verb builds as `list` (`Builder#list`, through `PlainRuby::Arrays`), a `DSL::List`, named
after the local. The `list` verb takes the same settings and stays for the lowering's own tests and
for a reader following a build; a game never needs it.

| Ruby | What the build makes |
|---|---|
| `trail = Array.new(capacity: 4)` | `list :trail, capacity: 4`, empty |
| `ripple = Array.new(8, 0.0)` | `list :ripple, capacity: 8, full_of: 0.0`, full, holding fractions |
| `marks = [3, 1, 4]` | `list :marks, capacity: 3`, then a push of each item |
| `queue = Array.new(4, 0, capacity: 8)` | `list :queue, capacity: 8`, then four pushes of 0 |
| `board = Array.new(64, 0, width: :byte)` | `list :board, capacity: 64, width: :byte, full_of: 0` |

- **The name is the local's**: `trail`, `trail_2` for a second local of that name in one block or
  file, and the file's name first in a file loaded with `VBlank.require_game_file` (`walker_trail`
  in `walker.rb`). A profile, a save and a test read it by that name. A `list` line given a name an
  Array's list has (or the other way round) is a friendly error naming both lines.
- **Settings `Array.new` takes**: `capacity:` (the most items, needed where game code adds items),
  `width:` and `fast:`, each told below. `list`'s `holds:` and `full_of:` have no Array form, since
  the Array says both itself: a start that fills every slot with one number is `full_of:`, and
  whether it holds fractions is read from what goes in.
- **The methods**: Ruby's `<<`/`push`/`append`, `pop`, `shift`, `[]`, `[]=`, `+=` on an item,
  `first`, `last`, `length`/`size`, `empty?`, `each`, `each_with_index`, `sum`, `min`, `max`,
  `include?`, `fill`, `sort!`, `sort_by!` and `reverse!`, and `copy_from`, which is VBlank's. A Ruby
  Array method a list has no meaning for (`unshift`, `insert`, `concat`, `rotate!`, `map`) is a
  friendly error naming the methods a list has.
- **An Array that stays Ruby's** builds nothing: one only game code reads, one changed only while
  the game is built, and one of sprites, `var` handles or anything but numbers. `plain-ruby.md`
  ("Arrays") says which Arrays become lists.

```ruby
# A trail of the last four places, oldest first
screen :bitmap
hero_x = 0
trail = Array.new(capacity: 4)
game_loop do
  hero_x += 1
  trail.shift if trail.size == 4
  trail << hero_x
  clear_screen :black
  trail.each { |x| draw_rect_at x, 50, 2, 2, :red }
end
```

## What a list costs, and what the build does

- **A row of slots or a ring, and the build picks.** A list only pushed onto and read by its place
  is a plain row of slots: `capacity: 145` takes 145 slots, and a read goes straight to the one it
  names. A list that game code `shift`s (drops from the front, which moves where the oldest item
  lives) is a ring, and a ring's slots are rounded up to the next power of two so the wrap is a
  single step: `capacity: 145` then takes 256, and the 111 slots between are room paid for that can
  never be filled. So a queue that is shifted wants a power-of-two capacity. A plain row is also the
  faster to read, having no head to look up first. Neither changes what the list holds or does.
- **A push onto a full list stops the game**, naming the list, where Ruby would grow the Array (the
  Advance cartridge drops the item for now). `trail.shift if trail.size == 4` makes room first, and
  `scores << s if scores.size < 8` skips the new item.
- **Answers about every item:** `sum`, `min`, `max` and `include?` walk the items the list holds as
  the game plays, a loop over them each time, and keep the answer in a hidden variable. `min` and
  `max` of an empty list are 0. A list of fractions sums to a fraction. `item = trail.shift` keeps
  the dropped item in a hidden variable too, a word of memory; `trail.shift` alone keeps nothing.
- **An item is a number.** `answers[i] = pass == 1 ? 1 : 0` keeps the number the test picks on each
  pass, as `x = test ? a : b` does, and so do an `if` with an `else` and a `case` (`plain-ruby.md`).
  nil, `true`, `false` and a test's answer alone (`answers[i] = pass == 1`), written into a slot,
  pushed or filled, are friendly errors at the line: a slot has no mark beside it that says "this
  was nil" or "this was true", as a game variable has, so the item would read back as a number Ruby
  never gave. A test's answer is kept as `test ? 1 : 0`, and read by comparing the item with 1.
- **Whether it holds fractions** is read from what goes in: the start, and every value game code
  puts in with `<<`, `push`, `[]=`, `+=` on an item or `fill`. A Float, a name given one, or `.to_f`
  makes the list hold fractions (`holds: 0.0` on the `list` it builds); every value read out then
  carries the fraction and every value put in is checked against it. `length` stays a plain count
  whatever the items are. A whole number the game works out put into a list of fractions, or a
  fraction into a list of whole numbers, is a friendly error naming the line that decided.

```ruby
# A fraction going in makes a list of fractions
screen :bitmap
speeds = Array.new(capacity: 8)
vx = 0.5
game_loop do
  vx += 0.25
  speeds << vx if speeds.size < 8
end
```

### Sorting in place

`sort!` (the smallest first), `sort! { |a, b| b <=> a }`, `sort_by! { |n| -n }` or `sort!.reverse!`
(the biggest first) sort as Ruby's do; level items keep their order. Each line that sorts is a
routine of its own, an insertion sort done in place (each item moved back past the bigger ones
before it), so it needs no room and costs little for a list nearly in order; `rom.profile` names the
line ("sorting `scores` at line 21") and what it costs. A comparing block of any other shape,
`reverse!` anywhere but right after a sort, and `sort`/`sort_by` (a new Array) are friendly errors.
On the Advance a sort of sixteen items, one new each pass, is about 1,140 instructions, more than a
hand-written one; `test_sort_cartridge.rb` pins it.

```ruby
# Keep the last five scores, biggest first
screen :bitmap
scores = Array.new(5, 0)
t = 0
game_loop do
  t += 1
  scores[t % 5] = (t * 37) % 100
  scores.sort! { |a, b| b <=> a }
  scores.each_with_index { |score, at| draw_rect_at at * 10, 100 - score, 8, score, :green }
end
```

### Starting full

`Array.new(3328, 0, width: :byte)` builds a list that starts holding all 3,328 items, every one 0,
so each is there to read and write by its place from the first frame: a box the game letters text
into, a row of flags, a board. Each time the line runs the list is made full again, the way an
empty list is emptied again. The build makes this a fill only where the start fills every slot
with one number; any other start (`[3, 1, 4]`, or fewer items than the capacity) is a push for each.

What it is for is speed. The loop it replaces, a push of 0 for each slot, finds the place for each
item and stores the length again for each, about twenty instructions an item on the console, where
a fill sets the length once and fills the whole words of the list with the console's copying
engine. In setup that loop is work the first pass pays before the game shows anything: the 3,328
bytes above were most of a large game's first frame. A number too big for a narrow slot keeps the
low bits, as a push of it would. The build warns about the loop it replaces: a `repeat` whose count
is a list's capacity and whose body is one push of a number gets a warning naming the list and the
line. On the Game Boy Color, which has no copying engine for its work memory, a list is filled with
a store for each byte and a count for each item, at every width, so a few hundred bytes cost a small
part of a frame. The framework's own collections start full this way too (a pool's slots, a
canvas's bytes, a save record's buffer), so a pool one slot bigger costs one push at power-on, not
one for every field.

### Setting a run of items at once: `fill`

`box.fill 0x77` sets every item the list holds now, and `box.fill 0xFF, from: f, count: n` a run of
them (VBlank's keywords, where Ruby's `fill` takes a start and a length): clearing the area a
dialogue box letters into, a row of a board. The value, `from:` and `count:` may each be worked out
as the game runs. What it is for is speed: the loop it replaces, `box[i] = v` for each item, works
out an address and stores one item at a time, where a fill hands the whole words of the run to the
console's copying engine and sets only the bytes at its ends one at a time. Measured on a
3,328-byte clear a frame, that is about a fiftieth of the frame against more than two thirds.

A run must stay inside the items the list holds now: the interpreter stops with an error past them,
where the console only holds the run to the capacity. A list the game also `shift`s cannot be
filled, since its items wrap round its memory. A run written past the list's capacity or from
before its first item, a fill on a table (stored in the cartridge, so read-only), and a value of
the wrong kind for the list (a fraction into whole numbers, or the other way round) are friendly
errors.

```ruby
# A board of byte cells, a row cleared at a time
screen :bitmap
board = Array.new(64, 0, width: :byte)
at = 0
game_loop do
  board[at] = 1
  at = (at + 1) % 64
  board.fill 0, from: at, count: 8 if at % 8 == 0
  clear_screen :black
  board.each_with_index { |cell, i| draw_rect_at (i % 8) * 4, (i / 8) * 4, 3, 3, :green if cell == 1 }
end
```

### Copying a run of a table in at once: `copy_from`

`name.copy_from letters, at: which * 64, count: 64` is VBlank's, not Ruby's: the list then holds
exactly `count` entries of the table, from entry `at` on: the picture of a letter a name is painted
with, a frame of an animation, a row of a level. `at` may be worked out as the game runs and is
held inside the table, so the run never reads past either end; `count` is a number written out.
What it is for is speed: the loop it replaces, `name[i] = letters[start + i]` for each entry, reads
and writes one entry at a time, where this hands the whole run to the console's copying engine.
Measured on eighteen 64-byte runs a frame, that is a fiftieth of the frame against about a fifth,
and the gap is far wider for a game whose code runs from the cartridge. It is widest when the start
and the length are whole words (`which * 64` always is), and a run that is neither words nor halves
is still copied, a byte at a time. The table and the list must keep entries the same width and the
same kind of number (both whole, or both with a fraction), since a copy moves them as they are; a
count over the list's capacity or the table's length is a friendly error too.

```ruby
# A name painted from one of two letters kept in the cartridge
screen :bitmap
letters = table :letters, [1, 0, 1, 1, 1, 1, 0, 1]
shown = Array.new(4, 0, width: :half)   # a table keeps entries in halves
which = 0
game_loop do
  which = 1 - which
  shown.copy_from letters, at: which * 4, count: 4
  clear_screen :black
  shown.each_with_index { |dot, i| draw_rect_at i * 4, 20, 3, 3, :white if dot == 1 }
end
```

### How big one slot is: `width:`

`Array.new(capacity: 64, width: :byte)`: a slot holds a whole 32-bit number unless the line says
otherwise, and hardly anything a game keeps in one needs that much. A direction, a state number, a
countdown, how many hit points are left, a yes-or-no: every one of those is a **byte**, at a
quarter of the memory, and `:half` is a half. That memory is the console's 32K of quick memory,
which is the same 32K the framework keeps hot code in, so on a big collection this is the
difference between the game's frame running fast and running from the cartridge. Reading and
writing a narrow slot costs exactly what a wide one costs; only the room differs.

A narrow slot always goes below nothing (`:byte` holds -128..127), and there is deliberately no way
to ask for 0..255 instead. The case that decides it is a countdown, where `wait -= 7` followed by
`wait <= 0` really does hold -4 while that test runs, and a slot that could not go below nothing
would read -4 back as 252 and the test would never fire. Nothing at build time can see that coming,
because the value is worked out as the game runs, which is also why a table can be asked and a list
cannot: a table's values are all known while the cartridge is built. A number that has to reach
past 127 asks for `:half`.

One slot reads without a sign: `:unsigned_half`, two bytes holding 0 to 65535, for a place kept in
256ths of a pixel (`x = (x + speed) & 0xFFFF`), which passes 32767 on a wide screen and never goes
below nothing; it is never a countdown. A number outside 0..65535 put into it keeps its low sixteen
bits, so -1 reads back as 65535, and a load from save memory keeps the low sixteen bits of each item
too. A table cannot be copied into one (`copy_from` is a friendly error), and a list of fractions
cannot be one (a friendly error). The Super Nintendo and the Color keep it in two bytes and work it
sixteen bits at a time; the other consoles keep it in a word. A list the build can see stays in
0..65535 (a place written with `& 0xFFFF`) is kept that way without being asked.

**A number too big for its slot keeps the low bits, with no error**, exactly as the console does,
and every backend drops the same bits (200 in a `:byte` reads back as -56 on each). A byte is the
smallest there is: the console can load 8, 16 or 32 bits and nothing narrower, so a flag costs a
byte, and packing eight of them into one would cost several instructions on every read.

### Where it lives: `fast:`

Which memory a list is kept in is almost never worth saying. The console has two work memories, a
small quick one and a large one that makes it wait about six times as long for a whole number.
Everything a program declares used to come out of the small one, so a game with a lot of state did
not build. Now what a frame touches goes in the quick one and the rest falls into the roomy one.
Which is which is read off the program rather than guessed: a collection named anywhere in the
per-frame path (the game loop, the scenes it runs, the routines those call, a timer's handler) is
one a frame touches.

`Array.new(capacity: 64, fast: false)` says a collection is cold (a world state read when a menu
opens) and moves it whatever the room, which hands the quick memory back to the things walked every
frame; `fast: true` insists on one the framework did not pick. It is the same word `func` takes for
the same question about code, and it changes nothing the program does, only how long a read takes.
It is worth a thought because the quick memory is also where the hot code is kept, and a routine
left out of it runs from the cartridge at about two and a third times slower.

```ruby
# A cold list, changed at the end of a race and read only when a menu opens
screen :bitmap
best_times = Array.new(16, 0, fast: false)
time = 0
shown = 0
game_loop do
  time += 1
  best_times[0] = time if pressed(:a)
  shown = best_times[0] if pressed(:start)
end
```

**The build weighs collections and code by one rule**: what the author insisted on goes first (a
`func`, `scene` or `save_data` that says `fast: true`, and a collection that does), then the
collections a frame touches, then the routines the build picks, then the collections no frame
touches. So a routine the author insisted on moves a collection nobody said anything about to the
roomy memory rather than stop the build, and a collection no frame touches gives its room to the
game loop. A pool moves whole, all its columns together.

**A build that measures the game** (`build_rom`, which does by default) counts how many times a
frame reads or writes each collection, and weighs that against the routines by what each saves a
frame: one read of a whole number kept in the quick memory saves about what four instructions of a
routine do, and one of a half or a byte about one and a half. So a list a frame touches once gives
its room to a routine a frame runs thousands of instructions of, and the build report says how
often a frame touched each collection it moved. A build that does not measure keeps a collection a
frame touches ahead of its own routines, since nothing then says how much a frame reads it.
`rom.profile` says what went where.

**What does not fit.** A pool over 16K is too big to share the quick memory, which is 32K and holds
the hot code as well, so it is kept in the roomy one without being told: a thousand things of four
fields is 25K, and builds. Saying `fast: true` about such a pool is a friendly error, since the game
has asked for a place the pool cannot have. A pool bigger than the roomy memory itself, 256K, fits
nowhere and is a friendly error at its own line; and a game whose collections do not fit the two
memories together is refused by the check that adds up everything it declares, which names the
biggest of them. The collections kept out of the quick memory (`fast: false`, and pools over 16K)
can only be in the roomy one, so that check also holds them to the roomy memory alone, less what
the build keeps there for itself (the sound mixer's buffers, the sound effects table, the save
memory's working space and a held background's cell changes), and names the biggest of them. What
the sprite drawing keeps there in a game with more sprites than the console draws, or pools whose
pictures are sent as they show, is not counted, since only laying out the sprites says how big it
is. **On the Game Boy Color there is one work memory**, 8K with about 6.5K of it free once the
framework has its part, and nothing roomier beside it: the same check counts every variable, list
and pool against that one, and says so in the Color's numbers.

**A collection's own numbers go with it**: a list keeps how many items it holds (and, one that is
shifted, where its oldest is), and a pool keeps a dozen or more of its own (how many are live, the
first and last of its order, where each walk of it has got to). Wherever the collection went, by
`fast: false` or because the build moved it, those go too, so a cold pool leaves nothing of itself
in the quick memory. Reaching one there costs what reaching the collection's items already costs.
A **variable** the game keeps cannot move and never will: it is reached by its distance from the
start of the quick memory, which is what makes reading one two instructions instead of four, so a
program with more variables than fit is a friendly error saying exactly that, and suggesting an
Array.

### A list sized for the worst moment

A collection sized for the worst moment of a game and walked item by item every frame is fine for
the whole of development and falls over in the one session that fills it: a snake's body is sized
for the whole board and holds four cells for most of a game. **The build watches for that, and
measures it rather than working it out**: a build that measures its game (`build_rom`, `ruby
game.rb`, the `vblank` command) runs each scene a second time with every list and pool the game
keeps held at its capacity, and a scene that keeps up as it stands and falls behind full is a
friendly warning giving the frame rate it measured and naming up to three collections, the ones
that run read and wrote most more often than the scene does as it stands. That count is what was
used, not what it cost, so a short walk of dear items can go unnamed beside a long walk of cheap
ones: the names are where to start, and `rom.profile` says where the time went. Only the length is
held: the items past the ones the game put there are whatever is in memory, usually nothing, so a
walk whose work depends on an item's value (skipping an item that is nought, using an item as a
loop count) is measured at what those values cost, which can be more or less than a real full
list. It costs build time and nothing in the cartridge: one more run of each scene, however many
collections the game has.
