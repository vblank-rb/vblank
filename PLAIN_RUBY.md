# Plain Ruby in a game

**Rule of thumb.** Simple Ruby works: numbers, `if`, `while` and `each` loops, Arrays of numbers, Structs, and small classes with methods. Clever Ruby often does not work: chains of `map` and `select` on an Array the game changes, text that does more than show a number the game changes, Arrays inside Arrays, Hashes that get new keys or are copied, and metaprogramming such as `eval`. When a line cannot work, VBlank stops the build with a message. The message names the line and tells you what to write instead. A few lines build with no message and do something you do not expect. The two lists near the end of this page, [Refused](#refused) and [Builds, but surprises you](#builds-but-surprises-you), give each case.

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

A part kept with `||=` is made once, so what its `initialize` hands another part goes in once, while VBlank builds the game, as in Ruby: a block it adds to another part's Array (`hooks.after { @count += 1 }`), or names (`costume.wear(%i[crouch leap])`). The block then runs wherever the other part runs it, on every pass. The same line run from the game loop itself would add to the Array on every pass in Ruby, so it stops with a message.

A local of the game's own block, set above the game loop, keeps a part the same way: `counter = nil` above it, then `counter ||= Counter.new` in it. A part kept by another part with `||=` is kept only if that other part is kept too: a part made on every pass makes what it keeps on every pass as well. One name kept with `||=` on two lines that make different things (`@enemy ||= Bat.new` in one routine, `@enemy ||= Rat.new` in another) stops with a message, since Ruby keeps whichever runs first.

A part kept so starts from the numbers its `initialize` gives, and what its `initialize` puts into an Array it makes there goes in on the first pass alone. `rom.profile` names the hidden number that keeps it to once, and a save that keeps the Array keeps that number too; to skip it, make the part above the game loop. A part whose numbers never change (a spot that only answers questions) can be made anywhere. A push in `initialize` into an Array the part was handed runs each time the line making the part runs, as in Ruby, and so does everything else `initialize` does in the game, such as drawing or putting up a picture.

The number is named after the class and the instance variable: `lamp_lit` for `@lit` of a `Lamp`, and `score` for the game block's own `@score`. A profile and a test read it by that name. Written in the class's body, `game_variables busy: :lamp_wait` gives the number a name of the game's own, and `game_variables :damage, saved: false` marks numbers a save never keeps.

A Hash or Array of numbers that game code changes is a number for each key, where every key is known while building: a number, a symbol or a constant written out, or the name a Ruby loop over something written out gives.

A part's Hash or Array that holds only symbols stays a Ruby one: names filled while the part is set up, like `@used |= names` in `initialize`. Game code can ask about it (`@used.intersect?(AIMS)`), and Ruby answers while the game is built. A line of game code that changes it stops with a message. To let the game change it, name it with `game_variables :used`.

A Hash written out in the game block, `h = { a: 1, b: 2 }`, works the same way when game code changes it at a key: `h[:a] += 3`, `h[:b] = 0`, or `m = (h[:a] += 3)`, which gives `m` the new number as Ruby does. The numbers are named after the local and the key, `h_a` and `h_b`. The game keeps one number for each key, so a key the Hash does not have stops the build, and so does a method that adds, removes or changes many keys in one step (`store`, `merge!`, `delete`, `transform_values!`, `clear` and the others). Change one key at a time instead. A copy of such a Hash, `dup`, `merge`, `select`, `slice` and the others that answer a new Hash holding its numbers, stops the build too: in Ruby the copy keeps its own numbers, and the game's would change with the Hash. So does an Array of its values kept in game code, `v = h.values` or `h.to_a`; read it where it is made instead, as in `h.values.sum`, `h.values.max` or `h.values.each { ... }`.

A Hash written out in game code that the game only reads, or hands to a verb, stays a Ruby Hash, whatever it holds. So does one whose keys the game sets to values Ruby knows while the game is built: `options = { at: [60, 40], press: :a }`, then `options[:press] = press` and `menu :main, **options`, or `screens = { 0 => :title }`, then `screens[2] = :over if hard` and `call screens, number: state`. Ruby makes it again on each pass, with the same values. A Hash becomes a number for each key when the game works out what goes in a key, as in `h[:a] += 3` or `h[:a] = speed`, or when the Hash is written above the game loop and game code changes a key.

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

A Struct's fields work the same way: `point.x += 1` in game code makes `x` of a Struct made above the game loop a number the game keeps, read any way Ruby reads a Struct (`point.x`, `point[:x]`, `to_a`, `each`, `dig`, a pattern). `point.x, point.y = point.y, point.x` swaps them. A field keeps its own copy of a number, as in Ruby: `Point.new(score, 0)` or `point.x = score` holds the number `score` had on that line, and a later change to `score` leaves the field alone. A `Data` object made from a number keeps it the same way. That copy is a hidden number, which `rom.profile` lists. It costs nothing where the field was given numbers the game keeps (not an Array's item or a button), it is read in the same block as that line, the lines between only draw, test, or change other numbers, and no timer's `on_tick` changes those numbers.

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

Any other Array method is refused, and so is `==` between two Arrays the game keeps: see [Refused](#refused).

A part keeps one in an instance variable the same way. Make it with `capacity:` in `initialize`, and add to it in a method of the same class body:

```ruby
class Scores
  def initialize
    @scores = Array.new(capacity: 8)
  end

  def add(score)
    @scores << score if @scores.size < 8
  end

  def total = @scores.sum
end
```

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

`sort!` puts the items in order, the smallest first, as Ruby's does. `sort! { |a, b| b <=> a }`, `sort_by! { |n| -n }` and `sort!.reverse!` put the biggest first. Items that are level keep their order. A sort moves items back one at a time, so it costs little for a list that is nearly in order and more the more items move. `rom.profile` lists each line that sorts and what it costs. For the smallest item alone, `min` costs less. For a list that rarely changes, sort it when it changes, not on every pass.

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
- `Array.new` needs `capacity:`, and takes `fast:` too. Each field of a thing put in must hold a number. A `Data` class is refused, since its fields cannot change. Other Array methods are refused as they are for an Array of numbers.
- A push onto a full Array stops the game (see [Builds, but surprises you](#builds-but-surprises-you)): `shift` first to make room, as above, or test `size` first. A thing taken out inside a walk gives its place back only when the walk ends, so a `<<` written in a walk after a `shift` written in the same walk stops the build, and a `<<` in a walk that needs a place a routine the walk called took out stops the game saying so: add the new thing after the walk. A `<<` in a walk of an Array with room joins it at once, and only the walk it is in does not visit it.

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

`floor`, `ceil`, `round` and `truncate` give a whole number from a fraction as Ruby's do, and `round` takes a half away from zero (-2.5 becomes -3). `succ` and `pred` add or take away 1 from a whole number. `x**2` works where the power is written in the game, from 0 to 32. `q, r = cell.divmod(30)` gives Ruby's answer on whole numbers, negative ones too.

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

A Struct or Data class can also be in a file loaded with plain `require`. When game code gives a name to an object of it, the object keeps the numbers it was made from, as in Ruby. This is also true for objects in an Array, a Hash or a field. If such an object is frozen and holds a number the game works out, the build stops and tells you. A block that is given such a Data object and reads it as `it` or `_1` can also stop the build. Give the parameter a name, like `{ |point| ... }`.

## Refused

VBlank stops the build at each of these lines, before it builds anything. Each message ends with the file and the line, which this page leaves out. Open a row to see why, the refused code, the message, and the fix.

### Numbers and tests

<details>
<summary>Don't: <code>while left</code> on a bare number. Do: <code>while left &gt; 0</code></summary>

In Ruby every number is true, even 0, so this loop never stops.

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
This loop's test is a number that the game keeps, `left`, with no comparison. In Ruby, every number is true, 0 too. So a `while` on it never stops, and an `until` on it never runs. To fix this, compare the number. For a number that is not 0, write `left != 0` or `left > 0`. For 0, write `left == 0`.
```

Write instead:

```ruby
screen :bitmap
left = 3
game_loop do
  left -= 1 while left > 0
end
```

</details>

<details>
<summary>Don't: a loop on plain numbers that never ends. Do: a test that can fail</summary>

Ruby runs a loop on plain values while it builds the game, and VBlank stops it after a million rounds.

Refused:

```ruby
screen :bitmap
n = 5
n -= 1 while n
game_loop do
  clear_screen :black
end
```

VBlank says:

```
This loop went round a million times while the game was built, and it did not stop. Ruby runs a loop on plain values while it builds the game. If the test is a number alone, the test is always true, because every number is true in Ruby, 0 too. To fix this, compare the number: write `n != 0` or `n > 0`.
```

Write instead:

```ruby
screen :bitmap
n = 5
n -= 1 while n > 0
game_loop do
  clear_screen :black
end
```

</details>

<details>
<summary>Don't: <code>hp + 1</code> on its own line. Do: <code>hp += 1</code></summary>

`hp + 1` makes a new number and does not change `hp`, so the line does nothing.

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
You worked out a number and then did nothing with it. So the program is unchanged and the work is thrown away. `flags | 4` gives you a NEW number and leaves `flags` as it was. To change the variable, write `flags |= 4`, and `hp += 1` for `hp + 1`. If you wrote that already, this line is in code that VBlank does not read as a game. To fix this, move the line into your `VBlank.game` block. If the line is in a file of its own, load that file with `VBlank.require_game_file`, not `require_relative`.
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

</details>

<details>
<summary>Don't: <code>lives.nonzero? || 1</code>. Do: <code>lives != 0 ? lives : 1</code></summary>

Ruby's `nonzero?` gives the number or nil, and a number the game keeps is never nil. So VBlank lets `nonzero?` be a test only.

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
This line uses `nonzero?` as a number. In Ruby, `nonzero?` gives the number or nil. A number the game keeps is never nil, so here `nonzero?` is only a test. To fix this, write the test in full: `lives != 0 ? lives : 1`.
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

</details>

<details>
<summary>Don't: <code>alive = hp</code> when <code>alive</code> started as <code>true</code>. Do: <code>alive = hp &gt; 0</code></summary>

A number the game keeps holds one kind of value. A name that starts as `true` or `false` stays a yes or no.

Refused:

```ruby
screen :bitmap
alive = true
hp = 3
game_loop do
  hp -= 1 if pressed(:a)
  alive = hp
end
```

VBlank says:

```
`alive` started as `true` or `false`, and this line gives it a number. A game variable keeps one kind unless the line says so. To fix this, compare the number, like `alive = count > 0`, or start it with a number.
```

Write instead:

```ruby
screen :bitmap
alive = true
hp = 3
game_loop do
  hp -= 1 if pressed(:a)
  alive = hp > 0
end
```

</details>

<details>
<summary>Don't: <code>x = if ... end</code> with no <code>else</code>. Do: add an <code>else</code></summary>

When the test fails, Ruby gives nil, and a game has no nil.

Refused:

```ruby
screen :bitmap
hp = 3
shown = 0
game_loop do
  hp -= 1 if pressed(:a)
  shown = if hp > 1 then 5 end
end
```

VBlank says:

```
`x = if ...` needs an `else`. Without one, x has no number when the test fails, and a game has no nil. To fix this, add an `else`.
```

Write instead:

```ruby
screen :bitmap
hp = 3
shown = 0
game_loop do
  hp -= 1 if pressed(:a)
  shown = if hp > 1 then 5 else 0 end
end
```

</details>

<details>
<summary>Don't: <code>case hp in Integer =&gt; n</code>. Do: <code>in</code> with numbers or ranges</summary>

The game can match a number it keeps only against numbers, ranges, symbols and constants.

Refused:

```ruby
screen :bitmap
hp = 3
shown = 0
game_loop do
  hp -= 1 if pressed(:a)
  case hp
  in Integer => n if n > 2 then shown = 1
  else shown = 2
  end
end
```

VBlank says:

```
This `case ... in` asks about a number the game keeps. The game can match that number only against numbers, ranges, symbols and constants, with `|` between them. To fix this, write one of those after `in`. Or write tests with `case ... when`: `case` with no subject, then `when hp > 3 then`.
```

Write instead:

```ruby
screen :bitmap
hp = 3
shown = 0
game_loop do
  hp -= 1 if pressed(:a)
  case hp
  in 3.. then shown = 1
  else shown = 2
  end
end
```

</details>

<details>
<summary>Don't: <code>hp.fdiv(2)</code>. Do: <code>hp.to_f / 2</code></summary>

A number the game keeps does not have `fdiv`.

Refused:

```ruby
screen :bitmap
hp = 3
ratio = 0.0
game_loop do
  hp -= 1 if pressed(:a)
  ratio = hp.fdiv(2)
end
```

VBlank says:

```
A game's number does not answer `fdiv` yet. To keep the whole part of a fraction, use `to_i`. It rounds down.
```

Write instead:

```ruby
screen :bitmap
hp = 3
ratio = 0.0
game_loop do
  hp -= 1 if pressed(:a)
  ratio = hp.to_f / 2
end
```

</details>

<details>
<summary>Don't: <code>2**level</code> with a game number as the power. Do: multiply in a loop</summary>

The game can raise a number only to a power written in the code, from 0 to 32.

Refused:

```ruby
screen :bitmap
level = 1
points = 0
game_loop do
  level += 1 if pressed(:a)
  points = 2**level
end
```

VBlank says:

```
This line raises a number to a power that the game works out as it plays. VBlank can only use a power written in the game, from 0 to 32, like `x**2`. To fix this, multiply in a loop.
```

Write instead:

```ruby
screen :bitmap
level = 1
points = 0
game_loop do
  level += 1 if pressed(:a)
  points = 1
  level.times { points *= 2 }
end
```

</details>

<details>
<summary>Don't: <code>speed.round(1)</code>. Do: <code>speed.round</code></summary>

A number the game keeps rounds only to a whole number.

Refused:

```ruby
screen :bitmap
speed = 0.5
shown = 0.0
game_loop do
  speed += 0.25
  shown = speed.round(1)
end
```

VBlank says:

```
`round` with a number of digits is not something a game's number does. It rounds to a whole number only. To fix this, write `round` with no number.
```

Write instead:

```ruby
screen :bitmap
speed = 0.5
shown = 0
game_loop do
  speed += 0.25
  shown = speed.round
end
```

</details>

<details>
<summary>Don't: other Integer methods, such as <code>hp.gcd(4)</code>. Do: write the sum out</summary>

A number the game keeps has only the methods that the message names.

Refused:

```ruby
screen :bitmap
hp = 3
g = 0
game_loop do
  hp += 1
  g = hp.gcd(4)
end
```

VBlank says:

```
A game's number does not answer `gcd`. It answers `+`, `-`, `*`, `/`, `%`, `**`, `abs`, `clamp`, `floor`, `ceil`, `round`, `truncate`, `to_i`, `to_f`, `succ`, `pred`, `divmod`, the bit operations and the comparisons.
```

Write instead:

```ruby
screen :bitmap
hp = 3
g = 0
game_loop do
  hp += 1
  a = hp
  b = 4
  while b != 0
    a, b = b, a % b
  end
  g = a
end
```

</details>

### Text and symbols

<details>
<summary>Don't: <code>"HP #{hp}".center(12)</code>. Do: <code>draw_text "HP #{hp}", :center, ...</code></summary>

The game works out `hp` as it plays, so the letters of the text are not known while VBlank builds the game. The game can only draw such text.

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
This text holds a number the game works out as it plays, so its letters are not known while the game is built, and it does not answer `center`. A game can only draw it: `draw_text "HP \#{...}", 8, 8, :white`.
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

</details>

<details>
<summary>Don't: <code>call :"level#{level}"</code>. Do: a <code>case</code> that calls each name</summary>

Ruby makes the name once, while it builds the game, so it cannot follow a number that changes.

Refused:

```ruby
screen :bitmap
level = 1
func(:level1) { clear_screen :blue }
func(:level2) { clear_screen :green }
game_loop do
  level = 3 - level if pressed(:a)
  call :"level#{level}"
end
```

VBlank says:

```
This text puts a game number into a String with `#{...}`. Ruby makes the String once, while it builds the game. The number changes as the game plays, so the String cannot show it. To fix this, draw the words and the number apart: `draw_text "HP", 8, 8, :white`, then `draw_number hp, 32, 8, :white`. If the text is a name made in a loop, count with Ruby's `3.times { |i| ... }`, not `repeat`.
```

Write instead:

```ruby
screen :bitmap
level = 1
func(:level1) { clear_screen :blue }
func(:level2) { clear_screen :green }
game_loop do
  level = 3 - level if pressed(:a)
  case level
  when 1 then call :level1
  else call :level2
  end
end
```

</details>

<details>
<summary>Don't: change a String under a game test. Do: keep a flag and pick with it</summary>

A game keeps only numbers, symbols, `true` and `false`. A String changed under a game test changes one time, while VBlank builds the game.

Refused:

```ruby
screen :bitmap
hp = 3
label = "OK"
game_loop do
  hp -= 1 if pressed(:a)
  label = "LOW" if hp < 2
end
```

VBlank says:

```
`label` holds "OK", and this line changes it under a test the game makes as it plays. A game can keep only numbers, symbols, `true` and `false`. To fix this, keep a number and pick with it.
```

Write instead:

```ruby
screen :bitmap
hp = 3
low = false
game_loop do
  hp -= 1 if pressed(:a)
  low = true if hp < 2
  clear_screen :black
  draw_text "LOW", 10, 10, :white if low
  draw_text "OK", 10, 10, :white unless low
end
```

</details>

### Loops and leaving a block

<details>
<summary>Don't: <code>next</code> out of <code>game_loop</code> under a game test. Do: an <code>if</code></summary>

The game block only records what the game does. While VBlank builds it, there is nothing to leave yet. `return` and `break` are refused the same way.

Refused:

```ruby
screen :bitmap
hp = 3
game_loop do
  hp -= 1 if pressed(:a)
  next if hp > 2
  clear_screen :black
end
```

VBlank says:

```
`next` cannot leave code the game runs as it plays. This block only records what the game will do, so there is nothing to next from yet. To fix this, put the test in the `if` or `while` around this code.
```

Write instead:

```ruby
screen :bitmap
hp = 3
game_loop do
  hp -= 1 if pressed(:a)
  clear_screen :black if hp <= 2
end
```

</details>

<details>
<summary>Don't: <code>break</code> on a game test in <code>3.times</code>. Do: a <code>while</code> loop</summary>

Ruby runs `3.times` while it builds the game, so a test the game makes as it plays cannot stop it.

Refused:

```ruby
screen :bitmap
hp = 3
total = 0
game_loop do
  hp -= 1 if pressed(:a)
  3.times do |i|
    break if hp > i
    total += 1
  end
end
```

VBlank says:

```
`break` cannot leave code the game runs as it plays. This block only records what the game will do, so there is nothing to break from yet. To fix this, put the test in the `if` or `while` around this code.
```

Write instead:

```ruby
screen :bitmap
hp = 3
total = 0
game_loop do
  hp -= 1 if pressed(:a)
  i = 0
  while i < 3
    break if hp > i
    total += 1
    i += 1
  end
end
```

</details>

<details>
<summary>Don't: <code>for m in marks</code> on an Array the game keeps. Do: <code>marks.each</code></summary>

Ruby runs a `for` loop while it builds the game, and only the game holds the items.

Refused:

```ruby
screen :bitmap
marks = Array.new(capacity: 4)
game_loop do
  marks << 1 if marks.size < 4
  for m in marks
    draw_rect_at m, 0, 2, 2, :red
  end
end
```

VBlank says:

```
A `for` loop cannot go over a list or a pool. Ruby runs a `for` loop while it builds the game, and the game holds the items. To fix this, use `.each`: write `things.each do |thing|`.
```

Write instead:

```ruby
screen :bitmap
marks = Array.new(capacity: 4)
game_loop do
  marks << 1 if marks.size < 4
  marks.each do |m|
    draw_rect_at m, 0, 2, 2, :red
  end
end
```

</details>

### Arrays

<details>
<summary>Don't: <code>trail = []</code>, then <code>trail &lt;&lt; x</code>. Do: <code>Array.new(capacity: 8)</code></summary>

A console sets the memory of a list aside before the game starts, so a list cannot grow.

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
`trail` is an Array that game code changes, so the game keeps it as a list. A console keeps a fixed number of items in a list, and this Array has no room set aside to add items to. To fix this, give the most items it can hold: `trail = Array.new(capacity: 8)`, or `trail = Array.new(4, 0, capacity: 8)` to start with 4 items of 0.
```

Write instead:

```ruby
screen :bitmap
trail = Array.new(capacity: 8)
game_loop do
  trail << 1 if trail.size < 8
end
```

</details>

<details>
<summary>Don't: <code>Array.new(8)</code>. Do: <code>Array.new(8, 0)</code> or <code>Array.new(capacity: 8)</code></summary>

In Ruby the items of `Array.new(8)` are nil, and a list item cannot be nil.

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
`Array.new(8)` gives items of nil in Ruby, and a list item cannot be nil. To fix this, give the number each item starts as: `Array.new(8, 0)`. For an empty list with room for 8, write `Array.new(capacity: 8)`.
```

Write instead:

```ruby
screen :bitmap
slots = Array.new(8, 0)
game_loop do
  slots[0] = 1
end
```

</details>

<details>
<summary>Don't: <code>Array.new(n, 0)</code> with a game number. Do: a number or a constant</summary>

The build must know how many items a list starts with.

Refused:

```ruby
screen :bitmap
n = 4
game_loop do
  n += 1 if pressed(:a)
  row = Array.new(n, 0)
  row[0] += 1
end
```

VBlank says:

```
`row` gets its size from a number the game works out as it plays. The build must know how many items the list starts with. To fix this, give a whole number or a constant, for example `Array.new(8, 0)`.
```

Write instead:

```ruby
screen :bitmap
n = 4
game_loop do
  n += 1 if pressed(:a)
  row = Array.new(8, 0)
  row[0] += 1
end
```

</details>

<details>
<summary>Don't: <code>rotate!</code>, <code>map</code>, <code>unshift</code> and the like. Do: the methods above</summary>

A list the game keeps has only the methods in the table under "Arrays". This includes `map`, `select`, `reject`, `unshift`, `insert` and `concat`.

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
`rotate!` is a method of a Ruby Array, and a list the game keeps does not have it. A list has `<<`, `push`, `append`, `shift`, `pop`, `[]`, `[]=`, `size`, `length`, `empty?`, `first`, `last`, `each`, `each_with_index`, `sum`, `min`, `max`, `include?`, `==` with an Array, `sort!`, `sort_by!`, `fill` and `copy_from`.
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

</details>

<details>
<summary>Don't: <code>marks.sort</code> or <code>sort_by</code>. Do: <code>marks.sort!</code> or <code>sort_by!</code></summary>

`sort` makes a new Array, and a console keeps no room for one.

Refused:

```ruby
screen :bitmap
marks = [3, 1, 4]
game_loop do
  marks[0] += 1
  draw_rect_at marks.sort[0], 10, 2, 2, :white
end
```

VBlank says:

```
`sort` makes a new Array, and a console keeps no room for one. To fix this, sort `marks` in place with `sort!`.
```

Write instead:

```ruby
screen :bitmap
marks = [3, 1, 4]
game_loop do
  marks[0] += 1
  marks.sort!
  draw_rect_at marks[0], 10, 2, 2, :white
end
```

</details>

<details>
<summary>Don't: <code>a == b</code> on two Arrays the game keeps. Do: compare item by item</summary>

VBlank cannot compare two Arrays that the game keeps in one step.

Refused:

```ruby
screen :bitmap
a = [1, 2]
b = [1, 2]
same = 0
game_loop do
  a[0] += 1 if pressed(:a)
  b[1] += 1 if pressed(:b)
  same = 1 if a == b
end
```

VBlank says:

```
This line compares two Arrays the game keeps with `==` or `eql?`. VBlank cannot compare two of them. To fix this, compare the items one at a time, like `(a[0] == b[0]) & (a[1] == b[1])`.
```

Write instead:

```ruby
screen :bitmap
a = [1, 2]
b = [1, 2]
same = 0
game_loop do
  a[0] += 1 if pressed(:a)
  b[1] += 1 if pressed(:b)
  same = 1 if (a[0] == b[0]) & (a[1] == b[1])
end
```

</details>

<details>
<summary>Don't: <code>answers[0] = hp == 1</code>. Do: <code>answers[0] = hp == 1 ? 1 : 0</code></summary>

A list item holds a number, never `true` or `false`.

Refused:

```ruby
screen :bitmap
answers = [0, 0]
hp = 3
game_loop do
  hp -= 1 if pressed(:a)
  answers[0] = hp == 1
end
```

VBlank says:

```
The Array `answers` keeps numbers. This item is the answer to a test, true or false, and a list item cannot be true or false. To keep the answer, write `test ? 1 : 0`. When you read the item, compare it with 1.
```

Write instead:

```ruby
screen :bitmap
answers = [0, 0]
hp = 3
game_loop do
  hp -= 1 if pressed(:a)
  answers[0] = hp == 1 ? 1 : 0
end
```

</details>

<details>
<summary>Don't: whole game numbers and fractions in one Array. Do: <code>.to_f</code></summary>

An Array holds whole numbers or fractions, not both. A whole number that the game works out does not say which.

Refused:

```rb
screen :bitmap
hp = 3
speeds = Array.new(capacity: 4)
game_loop do
  hp -= 1 if pressed(:a)
  speeds << hp if speeds.size < 4
  speeds << 0.5 if speeds.size < 4
end
```

VBlank says:

```
`speeds` holds numbers with a fraction, since the line at game.rb:7 puts one into it. This line puts in a whole number the game works out, and there is no way to tell what it counts. To fix this, use `.to_f` on the whole number, or `.to_i` on the fraction at game.rb:7.
```

Write instead:

```ruby
screen :bitmap
hp = 3
speeds = Array.new(capacity: 4)
game_loop do
  hp -= 1 if pressed(:a)
  speeds << hp.to_f if speeds.size < 4
  speeds << 0.5 if speeds.size < 4
end
```

</details>

<details>
<summary>Don't: <code>grid[0][1] += 1</code> on Arrays inside an Array. Do: one Array a row</summary>

A list holds numbers, not other Arrays. Ruby changes the inner Array one time, while VBlank builds the game.

Refused:

```ruby
screen :bitmap
grid = [[0, 0], [0, 0]]
game_loop do
  grid[0][1] += 1 if pressed(:a)
end
```

VBlank says:

```
`grid[0][1]` holds `0`, which Ruby set while it built the game. This line changes it under a test the game makes as it plays. Ruby would make the change one time, and the game would not see it. To fix this, make a game variable where `grid[0][1]` is first set: `grid[0][1] = var :grid, 0`.
```

Write instead:

```ruby
screen :bitmap
row0 = [0, 0]
row1 = [0, 0]
game_loop do
  row0[1] += 1 if pressed(:a)
end
```

</details>

<details>
<summary>Don't: <code>Array.new(capacity: 4, holds: :fraction)</code>. Do: drop <code>holds:</code> (rare)</summary>

In game code, `Array.new` takes only `capacity:`, `width:` and `fast:`. What goes into the Array decides if it holds fractions.

Refused:

```ruby
screen :bitmap
speeds = Array.new(capacity: 4, holds: :fraction)
game_loop do
  speeds << 1 if speeds.size < 4
end
```

VBlank says:

```
In game code, `Array.new` does not take `holds:`. It takes a size, the number each item starts as, and `capacity:`, `width:` and `fast:`.
```

Write instead:

```ruby
screen :bitmap
speeds = Array.new(capacity: 4)
game_loop do
  speeds << 1.0 if speeds.size < 4
end
```

</details>

### Parts and instance variables

<details>
<summary>Don't: <code>flock.dots &lt;&lt; Dot.new(...)</code> from outside the class. Do: a method</summary>

The game keeps a part's Array only where code in its own class changes it. Otherwise the Array changes one time, while VBlank builds the game.

Refused:

```ruby
Dot = Struct.new(:x, :y)

class Flock
  attr_reader :dots

  def initialize
    @dots = Array.new(capacity: 8)
  end
end
screen :bitmap
flock = Flock.new
game_loop do
  flock.dots << Dot.new(1, 0) if pressed(:a)
end
```

VBlank says:

```
This line changes `@dots` of a `Flock` with `<<`, from outside its class. VBlank makes the game keep a part's Array only where code in its class changes it. Here it is still a plain Ruby Array, so this line changes it one time, while VBlank builds the game. To fix this, make `@dots` with `Array.new(capacity: 8)`, and add to it in a method of its class, in the same class body, like `def add(number) = @dots << number`. For a Struct, make each thing in that method, like `@dots << Point.new(x, y)`. Then call that method here.
```

Write instead:

```ruby
Dot = Struct.new(:x, :y)

class Flock
  def initialize
    @dots = Array.new(capacity: 8)
  end

  def add(x)
    @dots << Dot.new(x, 0) if @dots.size < 8
  end
end
screen :bitmap
flock = Flock.new
game_loop do
  flock.add(1) if pressed(:a)
end
```

</details>

<details>
<summary>Don't: fill a part's Array from a reopened class. Do: the first body (rare)</summary>

VBlank reads the class body that makes the Array to know what the Array holds. A method in the reopened class does not count.

Refused:

```ruby
Dot = Struct.new(:x, :y)

class Flock
  def initialize
    @dots = []
  end
end

class Flock
  def add(x) = @dots << Dot.new(x, 0)
end
```

VBlank says:

```
This line changes `@dots` with `<<` while the game plays, and `@dots` is still a plain Ruby Array. So it changes one time, while VBlank builds the game. The game keeps the Array when the class body that makes it also adds to it. To fix this, make `@dots` with `Array.new(capacity: 8)`, and add to it in a method of its class, in the same class body, like `def add(number) = @dots << number`. For a Struct, make each thing in that method, like `@dots << Point.new(x, y)`.
```

Write instead:

```ruby
Dot = Struct.new(:x, :y)

class Flock
  def initialize
    @dots = Array.new(capacity: 8)
  end

  def add(x) = @dots << Dot.new(x, 0)
end
```

</details>

<details>
<summary>Don't: make a part above <code>VBlank.game</code> and change its Array. Do: make it inside</summary>

The game keeps a part's Array or Hash only when the part is made inside the game block. A part made above it is made one time, before VBlank builds the game, and a game built for two consoles cannot share it. A part whose numbers alone change works anywhere. So does an Array of Structs made above it, such as `dots = [Dot.new(3, 0)]`: game code can walk it and change each Struct's numbers, and the Array stays a Ruby Array of the same size.

With this class in `tallies.rb`:

```rb
class Tallies
  def initialize
    @counts = [0, 0, 0]
  end

  def bump(at) = @counts[at] += 1
end
```

Refused:

```rb
VBlank.require_game_file "tallies"

tallies = Tallies.new

VBlank.game "TALLY", consoles: %i[gba] do
  screen :bitmap
  at = 0
  game_loop do
    at = (at + 1) % 3
    tallies.bump(at)
  end
end
```

VBlank says:

```
This line needs the game to keep `@counts` of a `Tallies`. Your code made this `Tallies` outside the `VBlank.game` block, so the game cannot keep `@counts`. To fix this, make the `Tallies` inside the `VBlank.game` block.
```

Write instead:

```rb
VBlank.require_game_file "tallies"

VBlank.game "TALLY", consoles: %i[gba] do
  screen :bitmap
  tallies = Tallies.new
  at = 0
  game_loop do
    at = (at + 1) % 3
    tallies.bump(at)
  end
end
```

</details>

<details>
<summary>Don't: set <code>@open</code> in a method and test it elsewhere. Do: <code>game_variables :open</code></summary>

VBlank cannot see in the source that the game changes `@open`. So Ruby decides the test once, while it builds the game.

Refused:

```ruby
class Door
  def initialize(build)
    @open = false
    build.func(:open_door) { open! }
    build.func(:draw_door) { build.draw_rect_at 0, 0, 4, 4, :green if @open }
  end

  def open! = @open = true
end
```

VBlank says:

```
`@open` is changed while the game plays (at door.rb:8), and a test on it decides what the game does (at door.rb:5). `@open` is a plain Ruby value, so the game does not see the change. Ruby decided the test once, while it built the game, from the value (`true` or `false`) it held then. To fix this, add `game_variables :open` to Door.
```

Write instead:

```ruby
class Door
  game_variables :open

  def initialize(build)
    @open = false
    build.func(:open_door) { open! }
    build.func(:draw_door) { build.draw_rect_at 0, 0, 4, 4, :green if @open }
  end

  def open! = @open = true
end
```

</details>

<details>
<summary>Don't: read <code>@point</code> that only a <code>func</code> sets. Do: set it above the game loop</summary>

VBlank builds each `func` and scene after the game loop. So while VBlank builds the loop, `@point` holds nothing yet.

Refused:

```ruby
Point = Struct.new(:x, :y)
screen :bitmap
func(:place) { @point = Point.new(5, 5) }
game_loop do
  call :place
  draw_rect_at @point.x, @point.y, 2, 2, :white
end
```

VBlank says:

```
This line reads `@point`, which a `func` or a scene gives a value. VBlank builds each `func` and scene after the game loop, so `@point` holds nothing yet while VBlank builds this line. To fix this, give `@point` its first value above the game loop.
```

Write instead:

```ruby
Point = Struct.new(:x, :y)
screen :bitmap
@point = Point.new(0, 0)
func(:place) { @point.x = 5 }
game_loop do
  call :place
  draw_rect_at @point.x, @point.y, 2, 2, :white
end
```

</details>

<details>
<summary>Don't: make a Struct under an <code>if</code> and use it after. Do: make it above the loop</summary>

In Ruby, the line after the `if` can use the Struct that an earlier pass made. VBlank cannot follow which one.

Refused:

```rb
Point = Struct.new(:x, :y)
screen :bitmap
hp = 3
game_loop do
  hp -= 1 if pressed(:a)
  if hp > 1
    point = Point.new(5, 5)
  end
  draw_rect_at point.x, 5, 2, 2, :white
end
```

VBlank says:

```
This line uses `x` of an object of `Point` that game code makes again on each pass. The code that makes it is in another place than this line: under an `if` that ends before this line, or in the game loop, another `func` or a scene. So in Ruby this line can use the object from an earlier pass, and VBlank cannot follow which one. To fix this, make the `Point` above the game loop, or keep it in an instance variable, like `@point ||= Point.new(...)`.
```

Write instead:

```ruby
Point = Struct.new(:x, :y)
screen :bitmap
hp = 3
point = Point.new(0, 5)
game_loop do
  hp -= 1 if pressed(:a)
  point.x = 5 if hp > 1
  draw_rect_at point.x, 5, 2, 2, :white
end
```

</details>

<details>
<summary>Don't: sum in a lambda passed with <code>&amp;</code>. Do: <code>@counts.each { ... }</code> (rare)</summary>

VBlank cannot tell what a lambda or a helper walks before it runs. So a local that the block changes cannot be a game number.

Refused:

```ruby
class Tally
  def initialize(build)
    @counts = [0, 0, 0]
    build.func(:count_up) { @counts[1] += 1 }
    build.func(:add_up) { build.draw_rect_at total, 0, 2, 2, :white }
  end

  def total
    sum = 0
    add = ->(c) { sum += c }
    @counts.each(&add)
    sum
  end
end
```

VBlank says:

```
This line changes `sum` in a block, by a number the game works out as it plays. VBlank cannot tell what the block walks before it runs, so `sum` cannot be a game number. The game would keep only the last change. To fix this, walk the Array by its instance variable in this method, like `@things.each`.
```

Write instead:

```ruby
class Tally
  def initialize(build)
    @counts = [0, 0, 0]
    build.func(:count_up) { @counts[1] += 1 }
    build.func(:add_up) { build.draw_rect_at total, 0, 2, 2, :white }
  end

  def total
    sum = 0
    @counts.each { |c| sum += c }
    sum
  end
end
```

</details>

<details>
<summary>Don't: read a part's Array, then change it by its reader. Do: a method (rare)</summary>

Code that reads the Array before the change gets a plain Ruby Array. That Array does not see the change.

Refused:

```ruby
class Tally
  attr_reader :counts

  def initialize
    @counts = [0, 0, 0]
  end
end
screen :bitmap
tally = Tally.new
at = 0
game_loop do
  draw_rect_at tally.counts[0], 0, 2, 2, :white
  at = (at + 1) % 3
  tally.counts[at] += 1
end
```

VBlank says:

```
This line changes `@counts` of a `Tally` as the game plays, or reads it at an index the game works out. Game code reads it before this line (at tally.rb:2), and there it is a plain Ruby Array: it keeps the numbers Ruby gave it, so it does not see this change. To fix this, change the Array in a method of its class, like `def bump(at) = @counts[at] += 1`, and call that method here.
```

Write instead:

```ruby
class Tally
  attr_reader :counts

  def initialize
    @counts = [0, 0, 0]
  end

  def bump(at) = @counts[at] += 1
end
screen :bitmap
tally = Tally.new
at = 0
game_loop do
  draw_rect_at tally.counts[0], 0, 2, 2, :white
  at = (at + 1) % 3
  tally.bump(at)
end
```

</details>

<details>
<summary>Don't: <code>@counts.first(2)</code> or <code>@counts[0..]</code> of named numbers. Do: one item (rare)</summary>

In Ruby the part is a copy. Here it holds the same game numbers, so a change to it changes the Array too.

Refused:

```ruby
class Tally
  game_variables :counts

  def initialize(build)
    @counts = [0, 0, 0]
    build.func(:count_up) { @counts[1] += 1 }
    build.func(:show) { build.draw_rect_at @counts.first(2).sum, 0, 2, 2, :red }
  end
end
```

VBlank says:

```
This Array holds game variables, and this line takes a part of it, like `counts[0..]` or `counts.first(2)`. In Ruby the part is a copy, but here it would hold the same variables, so a change to it would change the Array too. To fix this, read the items one at a time, like `counts[0]`.
```

Write instead:

```ruby
class Tally
  game_variables :counts

  def initialize(build)
    @counts = [0, 0, 0]
    build.func(:count_up) { @counts[1] += 1 }
    build.func(:show) { build.draw_rect_at @counts[0] + @counts[1], 0, 2, 2, :red }
  end
end
```

</details>

<details>
<summary>Don't: copy named numbers, as in <code>@counts.dup</code>. Do: read one item (rare)</summary>

In Ruby the copy is its own Array. Here it holds the same game numbers. This includes `clone`, `rotate`, `values_at`, `+`, `[*counts]` and `Array.new(counts)`.

Refused:

```ruby
class Tally
  game_variables :counts

  def initialize(build)
    @counts = [0, 0, 0]
    build.func(:count_up) { @counts[1] += 1 }
    build.func(:show) { build.draw_rect_at @counts.dup[1], 0, 2, 2, :red }
  end
end
```

VBlank says:

```
This Array holds game variables, and this line takes a copy of it, like `counts.dup` or `counts.reverse`. In Ruby the copy is its own. Here the copy would hold the same variables, so a change to it would change the Array too. To fix this, read the items one at a time, like `first = counts[0]`.
```

Write instead:

```ruby
class Tally
  game_variables :counts

  def initialize(build)
    @counts = [0, 0, 0]
    build.func(:count_up) { @counts[1] += 1 }
    build.func(:show) { build.draw_rect_at @counts[1], 0, 2, 2, :red }
  end
end
```

</details>

### Setting values

<details>
<summary>Don't: set <code>score</code> above <code>VBlank.game</code> and change it inside. Do: set it inside</summary>

A number set outside the game block changes one time, while VBlank builds the game. The game never sees the change.

Refused:

```rb
score = 0

VBlank.game "SCORE", consoles: %i[gba] do
  screen :bitmap
  game_loop do
    score += 1 if pressed(:a)
  end
end
```

VBlank says:

```
`score` is set outside the game block, so the game cannot change it. To fix this, move the line that sets `score` into the block.
```

Write instead:

```rb
VBlank.game "SCORE", consoles: %i[gba] do
  screen :bitmap
  score = 0
  game_loop do
    score += 1 if pressed(:a)
  end
end
```

</details>

<details>
<summary>Don't: <code>counts[0] &amp;&amp;= value</code> on a number. Do: <code>counts[0] = value</code></summary>

VBlank cannot do `&&=` on a number or on `true` or `false`. In Ruby a number is always true, so `&&=` on a number always sets it.

Refused:

```ruby
screen :bitmap
counts = [0, 0]
game_loop do
  counts[1] += 1
  counts[0] &&= counts[1]
end
```

VBlank says:

```
This line changes `counts[0]` with `&&=` as the game plays. VBlank cannot do this for a number or a true or false value. To fix this, write `counts[0] = value`. To change it only some of the time, put that line under an `if`.
```

Write instead:

```ruby
screen :bitmap
counts = [0, 0]
game_loop do
  counts[1] += 1
  counts[0] = counts[1]
end
```

</details>

<details>
<summary>Don't: <code>flags[:open] ||= true</code> on <code>false</code>. Do: <code>flags[:open] = true</code></summary>

VBlank cannot do `||=` on `true` or `false`.

Refused:

```ruby
screen :bitmap
flags = { open: false }
game_loop do
  flags[:open] ||= true if pressed(:a)
end
```

VBlank says:

```
This line changes `flags[:open]` with `||=` as the game plays. VBlank cannot do this for a number or a true or false value. To fix this, write `flags[:open] = value`. To change it only some of the time, put that line under an `if`.
```

Write instead:

```ruby
screen :bitmap
flags = { open: false }
game_loop do
  flags[:open] = true if pressed(:a)
end
```

</details>

### Reaching outside the game

<details>
<summary>Don't: <code>eval</code>, <code>system</code> and the like in game code. Do: plain code</summary>

These reach outside the game, and a console cannot run them.

Refused:

```ruby
screen :bitmap
hp = 3
game_loop do
  hp -= 1
  eval("1")
end
```

VBlank says:

```
`eval` reaches outside the game, so this block cannot use it. If you need it while building, use it above the block and keep the result in a constant.
```

Write instead:

```ruby
screen :bitmap
hp = 3
game_loop do
  hp -= 1
end
```

</details>

<details>
<summary>Don't: a library such as <code>JSON</code> in game code. Do: use it above the block</summary>

The game block tells what the game does as it plays, and a library outside the game cannot run there.

Refused:

```ruby
screen :bitmap
hp = 3
game_loop do
  hp -= 1
  hp = JSON.parse("[1]").first
end
```

VBlank says:

```
`JSON` is not part of your game, so this block cannot use it. This block describes what the game does as it plays. If you need `JSON` while building, use it above the block and keep the result in a constant. If this library is safe here, add it with `allow:`.
```

Write instead:

```ruby
screen :bitmap
hp = 3
game_loop do
  hp -= 1
  hp = 1
end
```

</details>

<details>
<summary>Don't: <code>instance_variable_get(:@hp)</code>. Do: <code>@hp</code></summary>

Game code calls a method by its name, and reads an instance variable by its name.

Refused:

```ruby
screen :bitmap
@hp = 3
shown = 0
game_loop do
  @hp -= 1 if pressed(:a)
  shown = instance_variable_get(:@hp)
end
```

VBlank says:

```
`instance_variable_get` reads inside an object, so this block cannot use it. To fix this, call the method by its name.
```

Write instead:

```ruby
screen :bitmap
@hp = 3
shown = 0
game_loop do
  @hp -= 1 if pressed(:a)
  shown = @hp
end
```

</details>

## Builds, but surprises you

These lines build with no message. They do something that a Ruby reader does not expect.

<details>
<summary>Don't: <code>if hp</code> to test for 0. Do: <code>if hp != 0</code></summary>

In Ruby every number is true, even 0. So the test is always true, as Ruby says.

```ruby
screen :bitmap
hp = 0
seen = 0
game_loop do
  seen += 1 if hp            # always true
end
```

```ruby
screen :bitmap
hp = 0
seen = 0
game_loop do
  seen += 1 if hp != 0
end
```

</details>

<details>
<summary>Don't: <code>x / 2</code> on a negative game number. Do: <code>x.divmod(2)</code></summary>

`/` on a game number rounds toward zero: `-7 / 2` is -3. Ruby rounds down and gives -4. `divmod` gives Ruby's answer.

```ruby
screen :bitmap
x = -7
half = 0
game_loop do
  x -= 1 if pressed(:a)
  half, _ = x.divmod(2)      # -4 for -7, as in Ruby
end
```

</details>

<details>
<summary>Don't: <code>puts hp</code> to see a number. Do: <code>draw_number</code></summary>

`puts` and other harmless Ruby in a game block run once, while VBlank builds the game. They do not run as the game plays.

```ruby
screen :bitmap
hp = 3
game_loop do
  hp -= 1 if pressed(:a)
  clear_screen :black
  draw_number hp, 10, 10, :white
end
```

</details>

<details>
<summary>Don't: push onto a full Array. Do: test <code>size</code> first</summary>

A push onto a full Array stops the game with an error that names the Array. Ruby makes the Array bigger. This is true for an Array of numbers and an Array of Structs.

```ruby
screen :bitmap
trail = Array.new(capacity: 8)
game_loop do
  trail << 1 if trail.size < 8
end
```

</details>

<details>
<summary>Don't: <code>draw_number</code> each frame on a tiled screen. Do: write it once</summary>

On a tiled screen, `draw_number` draws its number again each frame. Ruby draws it once. Write the line once, above the game loop or in a scene. For an item, as in `shown[at]`, the game reads `at` again each frame too.

```ruby
screen :tiled
score = 0
draw_number score, 8, 8, :white, digits: 3
game_loop do
  score += 1 if pressed(:a)
end
```

</details>

<details>
<summary>Don't: read a local that you gave to a part. Do: read it through the part (rare)</summary>

The part holds the list that the game keeps. The local `src` still holds the Ruby Array, with the numbers from the time of the build.

```ruby
class Tally
  attr_reader :counts

  def initialize(counts)
    @counts = counts
  end
end
src = [0, 0, 0]
tally = Tally.new(src)
# tally.counts[at] += 1 in game code, then:
# src[1]           Ruby's number, from the build
# tally.counts[1]  the game's number
```

</details>

<details>
<summary>Don't: expect one writer name to change one class. Do: nothing (rare)</summary>

Game code such as `dial.level += 3` makes `level` a game number in every part that has a writer `level=`, in every game file that the game loads. This changes the cost and the layout of a save. It does not change the answers.

```ruby
class Dial
  attr_accessor :level

  def initialize
    @level = 0
  end
end
```

</details>

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
