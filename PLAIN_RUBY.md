# Plain Ruby in a game

A VBlank game is ordinary Ruby, and it follows one rule: the game file runs once, while the game is built, and the code inside a game block such as `game_loop` is recorded and played on the console every frame. A test, a sum or a loop on a number the game keeps becomes part of the game; the same line on a plain Ruby value is worked out once, while building, and costs the console nothing.

## Built now, or played later

Code inside a game block is played as the game runs; everything around it runs once, while the game is built.

```ruby
screen :bitmap
size = 8 * 2               # worked out once, while building
x = 0                      # the game keeps this number
game_loop do
  x += 1 if held(:right)   # tested and changed on every pass
  clear_screen :black
  draw_rect_at x, 40, size, size, :yellow
end
```

The game blocks are `game_loop`, `scene`, `func`, `once_a_frame`, `every`, `after`, `repeat`, `each_pass`, a timer's `on_tick` and a menu's `item`.

The same `if` can be either kind. A test on a number the game keeps, a button or a sprite's place is a branch in the game, taken or not on each pass. A test on a plain value is decided while building: one side is in the game and the other is not.

```ruby
screen :bitmap
big = true                 # a plain value: decided while building
hp = 3                     # a number the game keeps
game_loop do
  hp -= 1 if pressed(:a)
  clear_screen :black
  draw_rect_at 10, 10, 16, 16, :red if hp > 0
  draw_text "BIG", 10, 40, :white if big
end
```

A number the game keeps can go in drawn text, as Ruby puts one in a String: `"HP #{hp}"` or `hp.to_s`. `draw_text` draws the words, and each number as `draw_number` draws it, where the words before it end. A number takes the room `draw_number` gives it, 4 digits unless `digits:` says otherwise, and is drawn to the right of that room, so a shorter number leaves a gap before it.

```ruby
screen :bitmap
hp = 3
game_loop do
  hp -= 1 if pressed(:a)
  clear_screen :black
  draw_text "HP #{hp}", 10, 10, :white, digits: 2
end
```

## Game variables

A name that game code changes is a number the game keeps; a name nothing in game code changes stays plain Ruby and costs nothing.

```ruby
screen :bitmap
speed = 2                  # never changed in game code: plain Ruby
hp = 10                    # changed below: the game keeps it
game_loop do
  hp -= speed if pressed(:b)
end
```

A kept name can start as a whole number, a Float (a number with a fraction), `true` or `false`, a symbol, `nil`, or a sum of constants.

```ruby
screen :bitmap
x = 240 / 2                # a sum worked out while building
speed = 0.5
alive = true
mode = :title
game_loop do
  x += 1
  speed += 0.25 if alive
  alive = false if x > 200
  mode = :over unless alive
end
```

A symbol is a game state: compare it with `==`, and `call mode` runs the routine or scene of that name.

Each name is its own number. Two names given one number are two numbers, and the same name in two routines is two.

A name first set inside a game block is set again every time the block runs, so it starts afresh on each pass. A number that must last from pass to pass is set above the game loop.

```ruby
screen :bitmap
total = 0                  # lasts: set once, above the loop
game_loop do
  this_pass = 0            # starts at 0 on every pass
  this_pass += 1
  total += this_pass
end
```

A method's own names are set each time the method runs, as in Ruby.

## Instance variables

A part of a game is a plain class. An instance variable that game code may change is a number the game keeps, as a local is. VBlank finds these in the source: a line that works one out from what it holds (`@lit = 1 - @lit`, `@ticks += 1`, `@counts[at] += 1`), wherever it is, and a line that sets one inside a `func`, `game_loop` or other game block. Any other instance variable is plain Ruby, and so is one of these until game code first reads or changes it: a count bumped while the game is built stays a Ruby number there.

```ruby
# A lamp whose on-or-off number the game keeps
class Lamp
  def initialize(build)
    @lit = 0
    build.func(:switch_lamp) { @lit = 1 - @lit }
  end

  attr_reader :lit
end
```

Such an instance variable is the game's from the first line of game code that reads or changes it, starting from the number Ruby gave it, wherever it is read: in another routine, through `attr_reader`, or in another part it was handed to. A routine that draws the lamp reads the game's number even where it comes before the routine that switches it. A change from outside the class through a writer counts too: `dial.level += 3`, or `lamp.lit = 1` in a game block. Where game code sets an instance variable outright in a method of its own (`def open! = @open = true`) and another routine reads it, VBlank cannot see the change in the source, and stops with a message: write `game_variables :open` in the class's body. A `game_loop`, a scene and a `func` run every frame, so a line there that makes a part makes a new one on every pass in Ruby. A part whose numbers or Arrays change cannot be made that way: VBlank stops with a message. Make it above the game loop, or keep it with `||=`, which makes it the first time the line runs and keeps the same part after, in Ruby and in the game:

```ruby
# A ship kept with ||=: made the first time the line runs, and the same ship after
Ship = Struct.new(:x, :y)
screen :bitmap
game_loop do
  ship = (@ship ||= Ship.new(120, 80)) # made inside the loop, as a scene makes what is its own
  ship.x += 1
  clear_screen :black
  draw_rect_at ship.x, ship.y, 4, 4, :white
end
```

A local of the game's own block, set above the game loop, keeps a part the same way: `counter = nil` above it, then `counter ||= Counter.new` in it. A part kept by another part with `||=` is kept only if that other part is kept too: a part made on every pass makes what it keeps on every pass as well. One name kept with `||=` on two lines that make different things (`@enemy ||= Bat.new` in one routine, `@enemy ||= Rat.new` in another) stops with a message, since Ruby keeps whichever runs first.

A part kept so starts from the numbers its `initialize` gives, and what its `initialize` puts into an Array it makes there goes in on the first pass alone. `rom.profile` names the hidden number that keeps it to once, and a save that keeps the Array keeps that number too; to skip it, make the part above the game loop. A part whose numbers never change (a spot that only answers questions) can be made anywhere. A push in `initialize` into an Array the part was handed runs each time the line making the part runs, as in Ruby, and so does everything else `initialize` does in the game, such as drawing or putting up a picture.

The number is named after the class and the instance variable: `lamp_lit` for `@lit` of a `Lamp`, and `score` for the game block's own `@score`. A profile and a test read it by that name. Written in the class's body, `game_variables busy: :lamp_wait` gives the number a name of the game's own, and `game_variables :damage, saved: false` marks numbers a save never keeps.

A Hash or Array of numbers that game code changes is a number for each key, where every key is known while building: a number, a symbol or a constant written out, or the name a Ruby loop over something written out gives.

```ruby
# One count for each side, kept by the game
class Tilt
  SIDES = %i[left right].freeze

  def initialize(build)
    @counters = SIDES.to_h { |side| [side, 0] }
    build.func(:count_tilts) do
      SIDES.each do |side|
        @counters[side] += 1 if build.held(side)
      end
    end
  end
end
```

Such an Array read at an index the game works out is a list the game keeps, as the next section tells: in its own class (`@counts[at] += 1`), or in another part or the game block through its reader (`tally.counts[at] += 1`, with `attr_reader :counts`). Through a reader, the line itself decides, for that one part: another class with a reader of the same name is not changed. That line must be the first to use the Array in game code, and nothing may read the Array while setting up: a line before it that read the Array kept Ruby's numbers, so the build stops naming that line. An Array named with `game_variables` has a number for each index from its first number, so reading it through a reader at an index the game works out stops the build too. In both cases, change or read the Array at the worked-out index in a method of its class (`def bump(at) = @counts[at] += 1`), and call that method. Such a Hash at a key the game works out is refused. One Array handed to two parts that both keep it stops the build with a message: the game keeps an Array for each part, where Ruby shares one.

A Struct's fields work the same way: `point.x += 1` in game code makes `x` of a Struct made above the game loop a number the game keeps, read any way Ruby reads a Struct (`point.x`, `point[:x]`, `to_a`, `each`, `dig`, a pattern). `point.x, point.y = point.y, point.x` swaps them. A field keeps its own copy of a number, as in Ruby: `Point.new(score, 0)` or `point.x = score` holds the number `score` had on that line, and a later change to `score` leaves the field alone. A `Data` object made from a number keeps it the same way.

```ruby
# A point made from the score, which keeps the score it was given
Point = Struct.new(:x, :y)
screen :bitmap
score = 0
point = Point.new(score, 50)
game_loop do
  score += 1
  point.x += 2
  clear_screen :black
  draw_rect_at point.x, point.y, 2, 2, :white
end
```

A line in game code that gives a name a new Struct, after game code read the one the name held, stops with a message: in Ruby, that read gets the one an earlier pass made. Keep one Struct and change its fields. A `Data` object cannot change, so the same line with `point.with(x: point.x + 1)` stops too: use a Struct.

## Arrays

An Array that game code changes is a list the game keeps, named after its local, and Ruby's Array verbs work on it as Ruby says.

```ruby
screen :bitmap
hero_x = 0
trail = Array.new(capacity: 4)   # empty, with room for 4
game_loop do
  hero_x += 1 if held(:right)
  trail.shift if trail.size == 4
  trail << hero_x
  clear_screen :black
  trail.each { |x| draw_rect_at x, 50, 2, 2, :red }
end
```

What an Array the game keeps can do:

| Method | What it does |
|---|---|
| `<<`, `push`, `append` | Adds to the end; stops the game if it is full |
| `shift` | Drops the first item and hands it back |
| `pop` | Drops the last item and hands it back |
| `[]`, `[]=`, `+=` on an item | Reads or changes one item |
| `first`, `last` | Reads the first or the last item |
| `size`, `length`, `empty?` | Tells how many items it holds |
| `fill` | Sets every item to one number |
| `copy_from` | VBlank's, not Ruby's: copies a run of a `table` in at once |
| `each`, `each_with_index` | A loop over the items, run as the game plays |
| `sum`, `min`, `max`, `include?` | Looks at every item; `min` and `max` of none are 0 |
| `==`, `!=`, `eql?` with an Array | Compares every item, as Ruby does: equal only when the sizes match and each pair of items is equal |
| `sort!`, `sort_by!`, `reverse!` | Puts the items in order (see below) |

What it refuses, and what to write instead:

| Method | Write instead |
|---|---|
| `unshift`, `insert` | `<<` at the end |
| `concat`, `rotate!` | `<<` each item |
| `sort`, `sort_by` | `sort!`, `sort_by!` |
| `map`, `select`, `reject` | `each`, writing into a second Array |
| `a == b`, both Arrays the game keeps | Compare the items one at a time: `(a[0] == b[0]) & (a[1] == b[1])` |
| `Array.new(8)` | `Array.new(8, 0)`, or `Array.new(capacity: 8)` |

What these cost:

- `item = trail.shift` keeps the dropped item in a hidden number: one word of quick memory, and a copy each time the line runs. `trail.shift` on its own keeps nothing. To skip the cost, read `trail.first`, then `trail.shift`.
- `sum`, `min`, `max`, `include?` and `==` with an Array cost more the more items the Array holds.
- `rom.profile` lists every line that makes a hidden number.

```ruby
# Add up a growing list, and find its best
screen :bitmap
scores = Array.new(capacity: 8)
total = 0
best = 0
game_loop do
  scores << 3 if scores.size < 8
  total = scores.sum
  best = scores.max
  scores.each_with_index { |score, at| draw_rect_at at * 10, 100 - score, 8, score, :green }
end
```

`sort!` puts the items in order, the smallest first, as Ruby's does. `sort! { |a, b| b <=> a }`, `sort_by! { |n| -n }` and `sort!.reverse!` put the biggest first. Items that are level keep their order. A sort moves items back one at a time, so it costs little for a list that is nearly in order and more the more items move. `rom.profile` lists each line that sorts and what it costs. For the smallest item alone, `min` costs less. For a list that rarely changes, sort it when it changes, not on every pass. `sort` and `sort_by`, which make a new Array, are refused: write `sort!`.

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

```ruby
# Change one item at a time, in place
screen :bitmap
ripple = Array.new(8, 0.0)       # 8 items, each 0.0: numbers with a fraction
marks = [3, 1, 4]                # 3 items, and room for no more
at = 0
game_loop do
  ripple[at] += 1.5
  marks[1] += 1
  at = (at + 1) % 8
end
```

VBlank adds `capacity:` to `Array.new`, because a console sets a list's memory aside before the game starts, so a list cannot grow as a Ruby Array does. An Array that game code adds to needs `capacity:`, the most items it can hold. `Array.new(4, 0, capacity: 8)` starts with 4 items and has room for 8.

Two more settings can be left out, and change only what the list costs:

- `width: :byte` or `width: :half` keeps each item in less memory. A number too big for the slot keeps its low bits, with no error: 200 in a `:byte` reads back as -56.
- `fast: true` or `fast: false` sets which memory the list is kept in, the quick memory or the roomy one. It changes only how long a read takes.

Whether an Array holds fractions is read from what goes into it: its start, and every value game code puts in with `<<`, `push`, `[]=` and the like. A Float, a name given one, or `.to_f` makes it an Array of fractions. A whole number written out, such as `0`, fits either kind.

```ruby
# A fraction going in makes an Array of fractions
screen :bitmap
speeds = Array.new(capacity: 8)
vx = 0.5
game_loop do
  vx += 0.25
  speeds << vx if speeds.size < 8
end
```

An Array used only while the game is built stays Ruby's, and so does an Array of sprites or anything but numbers. A Ruby loop in a game block runs while building too, so an Array it fills with numbers known then is Ruby's, laid out again on every pass.

Such an Array can hold numbers the game works out, as in `[a, b].max`. The game then works out `max`, `min`, `minmax`, `count`, `any?`, `all?`, `none?` and `include?` as it plays, and gives Ruby's answer. A question that needs a test's answer while building is refused, naming the line: `find`, `select` and the others that pick items by a test the game decides, and `<=>` on a number the game works out where Ruby asks it: `sort`, `max_by`, `clamp` or code of your own outside the game. So is a question that compares the items while building, where an item, a value given or a block's answer is a number the game works out, or holds one (a Struct by its fields, an Array or Hash by what it holds): `uniq`, `tally`, `group_by`, `index(7)`, `find_index(7)`, `rindex(7)`, `-`, `&`, `|`, `difference`, `intersection`, `union`, `intersect?` and `delete(7)`. Compare the numbers one at a time with `==` instead. A Range of such numbers, `low..high`, still builds. `a <=> b` written in game code is a number the game works out, -1, 0 or 1, as Ruby's, and so is `[a, b] <=> [c, d]`.

```ruby
# Arrays that stay plain Ruby
screen :bitmap
steps = [1, 2]
steps << 3                       # changed while building: a Ruby Array of three
total = 0
game_loop do
  total = steps.sum
  xs = []
  3.times { |n| xs << (n * 8) }  # a Ruby loop: a Ruby Array of 0, 8 and 16
  xs.each { |x| draw_rect_at x, 10, 4, 4, :red }
end
```

A list is named after its local, so a test or a profile reads `trail` by that name. In a file loaded with `VBlank.require_game_file`, the file's name comes first: `walker_trail` in `walker.rb`.

### What an Array cannot do

| Limit | Write instead |
|---|---|
| It cannot grow past its room; game code adding to it needs `capacity:` | `Array.new(capacity: 8)` |
| A push onto a full Array stops the game (the Advance cartridge drops it for now) | `trail << x if trail.size < 8` |
| `Array.new(8)` with no start: its items would be nil | `Array.new(8, 0)`, or `Array.new(capacity: 8)` |
| Its size or capacity worked out as the game plays | A number or a constant |
| A whole number the game works out and a fraction in one Array | `.to_f` on the whole number |
| An Array of Arrays or of Hashes | One Array for each row, or an Array of Structs |
| A Ruby method an Array the game keeps does not have | The methods in the table above, or a `while` loop |
| A setting on `Array.new` other than `capacity:`, `width:`, `fast:` | One of those three |
| An instance variable's Array read through another object, `part.counts[which]`, after a line that read it first, or one named with `game_variables` | Read it in a method of that class, and call the method |
| A part of an Array of named numbers, `counts[0..]`, `counts[1, 2]`, `counts.first(2)`, `take` or `drop` | Read the items one at a time, `counts[0]` |
| A copy of an Array of named numbers, or a new Array holding its own items: `dup`, `clone`, `reverse`, `rotate`, `values_at`, `+`, `[*counts]`, `Array.new(counts)`, `entries`, or `map`, `select`, `sort_by` and the like where the block hands an item back (`map { |c| c + 1 }` works), or with no block (`counts.map.with_index`) | Read the items one at a time, `first = counts[0]` |
| A part whose Array the game keeps, made while no game is being built: above `VBlank.game`, or after a build. One whose own class indexes the Array is refused; one indexed through its reader works for one game, but a second game using the same part stops with a raw Ruby error | Make the part inside the `VBlank.game` block |

Each refused limit is refused before the game is built, naming the line. Several are shown with their messages under "What is refused, and what to write instead".

### An Array of Structs

Many things of one kind, each with fields (bullets, enemies, sparks), are an Array of Structs. Where game code puts `Spark.new(...)` into an Array and changes it, the game keeps it as a pool, and each thing a walk hands the block is a `Spark` whose fields change where they stand.

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
  sparks.shift if sparks.size == 32        # full: take out the oldest
  sparks << Spark.new(frame % 240, 0.0, 1.5)
  sparks.each(&:fall)
  sparks.delete_if { |s| s.y > 150 }
  clear_screen :black
  sparks.each { |s| draw_rect_at s.x, s.y, 2, 2, :yellow }
end
```

- `<<`, `push` and `append` put a thing in; `shift` takes out the oldest and `clear` all of them; `delete_if` and `reject!` take out those the block's test holds for.
- `each` walks them oldest first, `reverse_each` newest first, and `each_with_index` hands the place in the walk too. `size`, `length`, `count`, `empty?` and `any?` count them.
- On a tiled screen, `drawn_as :spark` in the Struct's block shows each thing as a sprite at its `x` and `y`, and `drawn_as facing: {...}, frames: [...], rate: 8` takes what a sprite takes. Name only the picture facing right, and facing left is that picture mirrored. `layer: :swimmers` stands each thing in that layer. A thing in a walk answers `face`, `draw_with`, `move`, `overlaps?`, its edges and the screen-edge tests, as a sprite does. Two more are VBlank's, not Ruby's: `sparks.blocked_by(room)` stops each thing at the walls of the background `room` when it moves, and `sparks.put_in_layer :walking` moves every thing to another layer.
- `sort_by! { |s| s.y }` puts them in order by one field, the smallest first, and `sort_by! { |s| -s.y }` or `sort_by!(&:y).reverse!` the biggest first. `sort_by! { |s| [s.y, -s.x] }` sorts by `y`, and where two have the same `y`, by `x` the biggest first. It changes the order they are walked in, and so drawn in. A sort inside a walk of the same Array is refused: sort after the walk. A Struct can say its own order, as in Ruby: `include Comparable` and `def <=>(other) = y <=> other.y` in its block (`other.y <=> y` for the biggest first, `[y, x] <=> [other.y, other.x]` for ties). Then `sort!` sorts by that order, at the cost of `sort_by!`, and `min`, `max` and `minmax` hand back the things it puts first and last, in one walk each. Two things compare by it with `<`, `>`, `<=`, `>=` and `between?`, and with Comparable, `==` holds where `<=>` gives 0, as in Ruby; `eql?` compares every field. A comparing block, `sort! { |a, b| b.y <=> a.y }` or `max { |a, b| a.x <=> b.x }`, orders by itself, by the same rule. On an empty Array, `min` and `max` hand back no thing, and as a test the answer is false, as Ruby's nil: `if (m = things.min)`. `min(2)` is refused, since it makes a new Array, and so is `clamp` between two different things, where Ruby can stop with an error. A `<=>` that does not compare fields one by one is refused, and so is `sort!` on a Struct with no `<=>`.
- Two things compare as Structs do: `a == b` when every field is equal, `a.equal?(b)` when they are the same thing. A thing kept in a name after its walk (`pick = s if s.x == 10`) is still that thing.
- `narrow :x, :y` in the Struct's block keeps each of those fields in half a word, and `narrow kind: :byte` in a byte, for a big Array.
- A field holds fractions where a line puts one in: `Spark.new(x, 0.0, 1.5)`, or `s.vy = 0.5` in a walk.
- A member can have any name Ruby allows. A member named as what a thing answers, such as `left` or `move`, means the member, as in Ruby.
- A part keeps one in an instance variable the same way: `@enemies = Array.new(capacity: 8)` in `initialize`, and `@enemies << Enemy.new(...)` in a method of the same class.
- `Array.new` needs `capacity:`, and takes `fast:` too. Each field of a thing put in must hold a number. A `Data` class is refused, since its fields cannot change, and so are Ruby's Array methods it has no meaning for (`rotate!`, `map`), by name.
- A push onto a full Array stops the game, as it does for an Array of numbers: `shift` first to make room, as above, or test `size` first to skip the new thing. A thing taken out inside a walk gives its place back only when the walk ends, so a `<<` in the same walk that needs that place stops the game saying so: add the new thing after the walk. A `<<` in a walk of an Array with room joins it at once, and only the walk it is in does not visit it.

## Changing a variable

`=`, `+=`, `-=`, `*=`, `|=` and `&=` change a number the game keeps, and a name holds a value, as in Ruby.

```ruby
screen :bitmap
hp = 5
flags = 0
best = 0
game_loop do
  hp -= 1 if pressed(:a)
  flags |= 4
  flags &= ~1
  best = hp if hp > best       # best keeps hp's number, not hp itself
end
```

`a, b = b, a` swaps two numbers, on every pass. `x ||= 2` changes only `false` or `nil`, as in Ruby: a number, 0 too, is kept.

A method's argument is a copy: changing it inside the method leaves the caller's number as it was, and the build warns about such a line. Return the number instead.

Numbers have `abs`, `clamp` and `approach`, and `abs!`, `clamp!` and `approach!` change the number they are called on.

```ruby
# Keep a number between 0 and 100
screen :bitmap
x = 10
game_loop do
  x += 3 if pressed(:a)
  x.clamp!(0, 100)
end
```

## Tests

`if`, `elsif`, `else`, `unless`, `case`, the ternary and the trailing forms work as in Ruby, and so does Ruby's truthiness: only `nil` and `false` are false.

```ruby
screen :bitmap
hp = 3
shown = 0
game_loop do
  hp -= 1 if pressed(:a)
  shown = hp > 0 ? 1 : 0
  case hp
  when 3 then shown += 10
  when 1..2 then shown += 20
  else shown += 30
  end
end
```

Compare a number to test its value: `if hp > 0`, never `if hp`, which is always true, as in Ruby. `&&`, `||` and `!` join tests, and the right side is skipped as in Ruby.

A `case` on a number the game keeps takes numbers, symbols, ranges, comma lists and constants. A `case` whose arms each `call` a scene is the game's scene dispatch.

## Loops

`while` and `until` on a test the game makes are loops in the game, asked again on every round.

```ruby
screen :bitmap
row = 0
game_loop do
  row = 0
  while row < 4
    draw_rect_at 10, row * 10, 4, 4, :green
    row += 1
  end
end
```

Ruby's counting loops go round as often as Ruby says: `n.times { |i| }`, `a.upto(b) { |i| }`, `a.downto(b) { |i| }`, `a.step(b, 2) { |i| }`, `(a...b).each { |i| }` and `for i in a...b`. When a count or an end is a number the game keeps, the loop is a loop in the game, and it goes round as many times as the number holds when the loop starts. When every number is written in the source or known while building, the build chooses, and the same game always builds the same way:

- Small rounds are written out once for each time round, which is the fastest. Rounds are small while together they have a size of at most 64. One `draw_rect_at` line is a size of 5, so 4 rounds of two such lines are written out.
- Larger rounds are one loop the game runs, which costs the room of one round. The round number `i` is then a number the game counts. Each round then costs time that a round written out does not: the loop counts and goes back, and works out each number that counts up with `i`.
- Rounds that differ in more than a number that counts up are written out, however large: a colour or a picture picked by `i` while building, a value read from a Ruby Array at `i`, or a test on `i`. Only a round written out knows its `i` while building.

`rom.profile` lists each such loop with its line, its size and what the build chose.

```ruby
# One loop counted by a game number, one written out
screen :bitmap
lives = 3
game_loop do
  clear_screen :black
  lives -= 1 if pressed(:a)
  lives.times { |i| draw_rect_at 10 + (i * 20), 10, 8, 8, :blue }   # one box for each life
  2.times { |i| draw_rect_at 10 + (i * 20), 30, 8, 8, :green }      # written out two times
end
```

A step the game works out is refused: write the step as a number. A range that ends at a game number goes round with `each`, `step` or `for`; other methods on it, such as `map`, are refused.

`break` and `next` work in every loop, as in Ruby: `break` leaves the loop, and `next` goes round again. A `loop do` runs while building, as Ruby runs it, until its `break` or `next` is under a test the game makes. From that round on, it is a loop the game runs. Then its body cannot read a plain value that changes on each round, such as `steps.next`: that is refused.

```ruby
# Find the first even number past a mark, skipping and stopping
screen :bitmap
wanted = 3
found = 0
game_loop do
  wanted += 1 if pressed(:a)
  at = 0
  found = 0
  while at < 10
    at += 1
    next if at.odd?          # skip the odd numbers
    if at * at > wanted * 4  # the first even number past the mark
      found = at
      break
    end
  end
end
```

A `break` that gives a value, as in `break 5`, is refused in a loop the game runs. Set a variable before the `break`.

## Splitting a game into files

A file of game code is loaded with `VBlank.require_game_file`, never `require_relative`, and is read as game code as a whole.

```ruby
VBlank.require_game_file "lamp"   # lamp.rb, beside this file

VBlank.game "LAMPS", consoles: %i[gba] do
  screen :bitmap
  lamp = Lamp.new(self)
  game_loop { call :switch_lamp if pressed(:a) }
end
```

Its locals stay its own, and its constants and methods are shared with the game. Its methods and blocks are checked as a game block is.

## What is refused, and what to write instead

Each refusal is a friendly error that names the line, said before anything is built.

Words with a game number in them, `"HP #{hp}"` or `hp.to_s`, are for drawing only: anything else a String does with them is refused, since the number has no digits while the game is built.

Refused:

```ruby
screen :bitmap
hp = 3
game_loop do
  hp -= 1 if pressed(:a)
  draw_text "HP #{hp}".center(12), 10, 10, :white
end
```

VBlank says:

```
This text holds a number the game works out as it plays, so its letters are not known while the game is built, and it does not answer `center`.
```

Write instead:

```ruby
screen :bitmap
hp = 3
game_loop do
  hp -= 1 if pressed(:a)
  draw_text "HP #{hp}", :center, 10, :white
end
```

A loop on a game number alone is refused, since in Ruby every number is true, 0 too.

Refused:

```ruby
screen :bitmap
left = 3
game_loop do
  left -= 1 while left
end
```

VBlank says:

```
This loop's test is a number that the game keeps, `left`, with no comparison. In Ruby, every number is true, 0 too.
```

Write instead:

```ruby
screen :bitmap
left = 3
game_loop do
  left -= 1 while left > 0
end
```

A number worked out and not kept is refused, since it would do nothing.

Refused:

```ruby
screen :bitmap
hp = 3
game_loop do
  hp -= 1 if pressed(:b)
  hp + 1
end
```

VBlank says:

```
You worked out a number and then did nothing with it. So the program is unchanged and the work is thrown away.
```

Write instead:

```ruby
screen :bitmap
hp = 3
game_loop do
  hp -= 1 if pressed(:b)
  hp += 1
end
```

`even?`, `odd?`, `zero?`, `nonzero?`, `positive?`, `negative?` and `between?` are tests on a game number, as in Ruby. `nonzero?` is only a test: Ruby's gives the number or nil, and a game number is never nil, so a line that uses it as a number is refused.

Refused:

```ruby
screen :bitmap
lives = 3
shown = 0
game_loop do
  lives -= 1 if pressed(:b)
  shown = lives.nonzero? || 1
end
```

VBlank says:

```
This line uses `nonzero?` as a number.
```

Write instead:

```ruby
screen :bitmap
lives = 3
shown = 0
game_loop do
  lives -= 1 if pressed(:b)
  shown = lives != 0 ? lives : 1
end
```

An Array that game code adds to with no `capacity:` is refused, since a list cannot grow.

Refused:

```ruby
screen :bitmap
trail = []
game_loop do
  trail << 1
end
```

VBlank says:

```
A console keeps a fixed number of items in a list, and this Array has no room set aside to add items to.
```

Write instead:

```ruby
screen :bitmap
trail = Array.new(capacity: 8)
game_loop do
  trail << 1 if trail.size < 8
end
```

`Array.new(8)` with no start is refused on an Array the game changes, since its items would be nil.

Refused:

```ruby
screen :bitmap
slots = Array.new(8)
game_loop do
  slots[0] = 1
end
```

VBlank says:

```
`Array.new(8)` gives items of nil in Ruby, and a list item cannot be nil.
```

Write instead:

```ruby
screen :bitmap
slots = Array.new(8, 0)
game_loop do
  slots[0] = 1
end
```

A Ruby Array method a list has no meaning for, such as `rotate!` or `map`, is refused by name, with the list of those that work.

Refused:

```ruby
screen :bitmap
marks = [3, 1, 4]
game_loop do
  marks.rotate!
end
```

VBlank says:

```
`rotate!` is a method of a Ruby Array, and a list the game keeps does not have it.
```

Write instead:

```ruby
screen :bitmap
marks = [3, 1, 4]
game_loop do
  front = marks[0]
  marks[0] = marks[1]
  marks[1] = marks[2]
  marks[2] = front
end
```

Other refusals, each with its own message: `return`, `break` or `next` leaving a game block under a game test, rather than a loop inside it; `break` or `next` under a game test in a loop Ruby runs while building; a local set outside the game block and changed inside it; an instance variable a method sets outright in game code and another routine reads, which the source does not show (write `game_variables`); `floor`, `round`, `succ`, `divmod`, `**` and the like on a game number (use `to_i` for the whole part of a fraction); in a part's method, a local changed by a game number in a lambda handed with `&` or a block a helper yields to (walk the Array by its instance variable, `@things.each`); a constant from outside the game, `system`, `eval` and the like.

## What builds and means something else

A few lines build without a word and do something a Ruby reader may not expect.

```ruby
screen :bitmap
hp = 0
seen = 0
game_loop do
  seen += 1 if hp            # always true: 0 is true in Ruby; write hp != 0
end
```

- `/` on a negative game number rounds toward zero (`-7 / 2` is -3), where Ruby while building gives -4.
- `puts` and other harmless Ruby in a game block run once, while building.
- VBlank builds each `func` and scene after the game loop. An instance variable that only a `func` or a scene gives a value, used in the loop as `@point.x`, stops with a message: give it its first value above the game loop.
- A Struct made in a `game_loop`, a scene or a `func` under an `if`, and used after that `if` or in another routine (a `func` the loop calls, too), stops with a message, since Ruby can keep the one an earlier pass made. Make it above the game loop, or keep it with `@point ||= Point.new(...)`.
- An Array the game pushes to when it is full, of numbers or of Structs, stops the game with an error naming it, where Ruby would grow it. Test `size` first, as the examples above do.
- `h[key] += n` on a Hash of game numbers answers the number before the change where it is used as a value (`m = (h[:a] += 3)`). Write the change on its own line, then read `h[:a]`.
- An Array a part holds, that game code outside its class puts things into (`flock.dots << Dot.new(...)` in the game loop), stays a Ruby Array: the line puts its thing in once, while building. Put things in with a method of its class that writes `@dots << Dot.new(...)`, or put them in above the game loop.
- An Array handed to a part from a local or a Struct field (`src = [0, 0, 0]`, then `tally = Tally.new(src)`), and read through that local after game code changes it through the part (`tally.counts[at] += 1`, then `src[1]`), answers the number Ruby gave it while building. Read it through the part, `tally.counts[1]`, or hand the part a constant.
- An Array a part holds, that game code adds to or turns as a whole through its reader (`part.counts << 7`, `part.counts.rotate!`), changes once, while building. Do it in a method of its class.
- A number or field another class changes through a writer (`dial.level += 3`) and that game code reads before that line stays the game's because of the writer's name: any part with a writer of that name in any game file loaded keeps that field as a game number. This changes what the game costs and how a save is laid out, not what it answers.

## When plain Ruby is not enough

`var :name, start` makes a game number directly, and a game needs it only to keep a number narrow.

```ruby
screen :bitmap
flag = var :flag, 0, width: :byte
game_loop do
  flag.store!(1) if pressed(:a)
end
```

Some plain Ruby lines need a hidden number the game keeps for them, such as a swap, a name that can hold nil, or the item `shift` drops, and `rom.profile` lists each such line and what it costs.

Anything else that seems to need a lower-level verb or VBlank's own classes is a gap in VBlank: report it with the line that did the wrong thing.
