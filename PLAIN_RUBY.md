# Plain Ruby in a game

**Rule of thumb.** Simple Ruby works: numbers, `if`, `while` and `each` loops, Arrays of numbers, Structs, and small classes with methods. Clever Ruby often does not work: chains of `map` and `select` on an Array the game changes, text that does more than show a number the game changes, Arrays inside Arrays, Hashes that get new keys or are copied, and metaprogramming such as `eval`.

When a line cannot work, VBlank stops the build with a message. The message names the line and tells you what to write instead. A few lines build with no message and do something you do not expect.

The three lists at the end of this page give each case: [Refused](#refused), [Builds, but surprises you](#builds-but-surprises-you) and [What costs more](#what-costs-more).

## Built now, or played later

The game file runs once, while VBlank builds the game. The code inside a game block is recorded, and the console plays it every frame. A test, a sum or a loop on a number the game keeps is part of the game, and the same line on a plain Ruby value is worked out once, while building.

```ruby
screen :bitmap
size = 8 * 2               # worked out once, while building
big = true                 # a plain value: its test is decided while building
hp = 3                     # a number the game keeps
game_loop do
  hp -= 1 if pressed(:a)   # tested and changed on every pass
  clear_screen :black
  draw_rect_at 10, 10, size, size, :red if hp > 0
  draw_text "BIG", 10, 40, :white if big
  draw_text "HP #{hp}", 10, 60, :white, digits: 2
end
```

The game blocks are `game_loop`, `scene`, `func`, `once_a_frame`, `every`, `after`, `repeat`, `each_pass`, a timer's `on_tick` and a menu's `item`. `"HP #{hp}"` and `hp.to_s` put a number the game keeps into drawn text, as `draw_number` draws it.

Limits: see [Refused › Text and symbols](#text-and-symbols).

## Game variables

A name that game code changes is a number the game keeps. A name that nothing in game code changes stays plain Ruby and costs nothing. A kept name can start as a whole number, a Float, `true` or `false`, a symbol, `nil`, or a sum of constants.

```ruby
screen :bitmap
speed = 2                  # never changed in game code: plain Ruby
x = 240 / 2                # a sum worked out while building
fall = 0.5
alive = true
mode = :title
game_loop do
  x += speed
  fall += 0.25 if alive
  alive = false if x > 200
  mode = :over unless alive
end
```

A symbol is a game state: compare it with `==`, and `call mode` runs the routine or scene of that name. Each name is its own number, so two names given one number are two numbers, and the same name in two routines is two.

Limits: see [Refused › Numbers and tests](#numbers-and-tests) and [Builds, but surprises you](#builds-but-surprises-you).

## Changing a variable

`=`, `+=`, `-=`, `*=`, `|=` and `&=` change a number the game keeps, and a name holds a value, as in Ruby. `a, b = b, a` swaps two numbers on every pass. `x ||= 2` changes only `false` or `nil`, as in Ruby, so a number, 0 too, is kept.

```ruby
screen :bitmap
hp = 5
best = 0
x = 10
game_loop do
  hp -= 1 if pressed(:a)
  best = hp if hp > best       # best keeps hp's number, not hp itself
  x += 3 if pressed(:b)
  x.clamp!(0, 100)
end
```

Numbers have these methods, as Ruby's do:

- `abs`, `clamp` and `approach`, and `abs!`, `clamp!` and `approach!`, which change the number they are called on.
- `floor`, `ceil`, `round` and `truncate` give a whole number from a fraction. `round` takes a half away from zero: -2.5 becomes -3.
- `succ` and `pred` add or take away 1 from a whole number, and `q, r = cell.divmod(30)` gives Ruby's answer, for negative numbers too.
- `x**2` works where the power is written in the game, from 0 to 32.

Limits: see [Refused › Numbers and tests](#numbers-and-tests).

## Tests

`if`, `elsif`, `else`, `unless`, `case`, the ternary and the trailing forms work as in Ruby. Only `nil` and `false` are false, as in Ruby, and `&&`, `||` and `!` skip the right side as Ruby does. A `case` on a number the game keeps takes numbers, symbols, ranges, comma lists and constants, and a `case` whose arms each `call` a scene is the game's scene dispatch.

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

Compare a number to test it: `if hp > 0`. Limits: see [Builds, but surprises you](#builds-but-surprises-you) and [Refused › Numbers and tests](#numbers-and-tests).

## Loops

`while` and `until` on a test the game makes are loops in the game. `n.times`, `upto`, `downto`, `step`, `(a...b).each` and `for i in a...b` go round as often as Ruby says, and when a count or an end is a number the game keeps, the game counts it as it plays. `break` and `next` work in every loop, as in Ruby.

```ruby
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

A `loop do` runs while building, as Ruby runs it, until its `break` or `next` is under a test the game makes. From that round on, it is a loop the game runs. Limits: see [Refused › Loops and leaving a block](#loops-and-leaving-a-block) and [What costs more](#what-costs-more).

## Instance variables

A part of a game is a plain class. An instance variable that game code changes is a number the game keeps, as a local is. Game code anywhere reads that number: another routine, `attr_reader`, or a writer such as `lamp.lit = 1`.

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

An instance variable handed another place's number (`@held = cursor.selection`, an argument, a slot `@states[0]`, or a local) holds that number, as in Ruby. If game code gives it another number (`@held = 5`, `@held += 1`), it keeps a number of its own, and the other place keeps its number. To change the other place, change it there: `cursor.selection = 5`. An instance variable that game code only reads reads the other place's number as it is at that time. A changing verb on what it holds (`@place.increase!(1)`) changes the other place, as in Ruby.

The number is named after the class and the instance variable: `lamp_lit` for `@lit` of a `Lamp`, and `score` for the game block's own `@score`. In the class body, `game_variables busy: :lamp_wait` gives the number a name of your own, and `game_variables :damage, saved: false` keeps numbers out of a save.

Limits: see [Refused › Parts and instance variables](#parts-and-instance-variables) and [Builds, but surprises you](#builds-but-surprises-you).

## Parts made in game code

A `game_loop`, a scene and a `func` run every frame, so a line there that makes a part makes a new one on every pass. Keep the part with `||=`: it is made the first time the line runs, and the same part is used after, in Ruby and in the game. The right side can be any method that makes the part, however many calls down (`@field ||= Field.sprites(art)`), since Ruby runs it once and keeps what it gives back. What the right side adds to a plain Ruby Array is added once too, as Ruby does. If it gives back `nil`, Ruby runs it again on the next pass, so a part it makes that changes is refused, and so is a change it makes to a plain Ruby Array. A local works too: `counter = nil` above the game loop, then `counter ||= Counter.new` in it.

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

Limits: see [Refused › Parts and instance variables](#parts-and-instance-variables), [Builds, but surprises you](#builds-but-surprises-you) and [What costs more](#what-costs-more).

## Structs

`point.x += 1` in game code makes `x` of a Struct made above the game loop a number the game keeps. Game code reads it any way Ruby reads a Struct: `point.x`, `point[:x]`, `to_a`, `each`, `dig` or a pattern. A field keeps its own copy of a number, as in Ruby, so a later change to `score` leaves `Point.new(score, 0)` alone, and a `Data` object keeps its numbers the same way.

```ruby
# A point made from the score, which keeps the score it was given
Point = Struct.new(:x, :y)
screen :bitmap
score = 0
point = Point.new(score, 50)
game_loop do
  score += 1
  point.x += 2
  point.x, point.y = point.y, point.x if pressed(:a)   # a swap
  clear_screen :black
  draw_rect_at point.x, point.y, 2, 2, :white
end
```

Limits: see [Refused › Parts and instance variables](#parts-and-instance-variables) and [What costs more](#what-costs-more).

## Hashes

A Hash written out with keys known while building, such as `h = { a: 1, b: 2 }`, keeps one number for each key that game code changes. The numbers are named after the local and the key, `h_a` and `h_b`. A key is known while building when it is a number, a symbol or a constant written out, or the name that a Ruby loop over something written out gives, as in `SIDES.each { |side| @counters[side] += 1 }`.

```ruby
screen :bitmap
h = { a: 1, b: 2 }
m = 0
game_loop do
  h[:b] = 0 if pressed(:a)
  m = (h[:a] += 3)           # m gets the new number, as in Ruby
end
```

A Hash that game code only reads, or hands to a verb, stays a Ruby Hash, and so does one whose keys get values known while building (`options[:press] = :a`, then `menu :main, **options`). Ruby makes such a Hash again on each pass, with the same values.

Limits: see [Refused › Hashes](#hashes-1).

## Arrays

An Array that game code changes is a list the game keeps, named after its local: `trail`, or `walker_trail` in a file `walker.rb`. A console sets the memory of a list aside before the game starts, so an Array that game code adds to needs `capacity:`, the most items it can hold. `Array.new(4, 0, capacity: 8)` starts with 4 items and has room for 8, and `[3, 1, 4]` has 3 items and no room for more.

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

Limits: see [Refused › Arrays](#arrays-1), [Builds, but surprises you](#builds-but-surprises-you) and [What costs more](#what-costs-more).

### What an Array the game keeps can do

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

A part keeps one in an instance variable: it makes the Array with `capacity:` in `initialize`, and adds to it in a method of the same class body. A part's Array read at an index the game works out is a list too, in its class (`@counts[at] += 1`) or through its reader (`tally.counts[at] += 1`).

### Sorting

- `sort!` puts the items in order, the smallest first, as Ruby's does. Items that are level keep their order.
- `sort! { |a, b| b <=> a }`, `sort_by! { |n| -n }` and `sort!.reverse!` put the biggest first.
- What a sort costs is under [What costs more](#what-costs-more).

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

### Arrays that stay Ruby

An Array used only while the game is built stays a Ruby Array, and so does an Array of sprites or of anything but numbers. A Ruby loop in a game block runs while building, so an Array it fills with numbers known then is Ruby's, made again on every pass. Such an Array can hold numbers the game works out, and `[a, b].max`, `min`, `minmax`, `count`, `any?`, `all?`, `none?` and `include?` give Ruby's answer as the game plays.

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

A Range of game numbers, `low..high`, builds. `a <=> b` and `[a, b] <=> [c, d]` in game code are numbers the game works out, -1, 0 or 1, as Ruby's are. Limits: see [Refused › Arrays](#arrays-1).

### An Array of Structs

Many things of one kind, each with fields, are an Array of Structs: bullets, enemies, sparks. Where game code puts `Spark.new(...)` into an Array made with `capacity:`, the game keeps it as a pool. Each thing a walk hands the block is a `Spark` whose fields change where they stand.

```ruby
Spark = Struct.new(:x, :y, :vy)
screen :bitmap
sparks = Array.new(capacity: 32)
frame = 0
game_loop do
  frame += 1
  sparks.shift if sparks.size == 32        # full: take out the oldest
  sparks << Spark.new(frame % 240, 0.0, 1.5)
  sparks.each { |s| s.y += s.vy }
  sparks.delete_if { |s| s.y > 150 }
  clear_screen :black
  sparks.each { |s| draw_rect_at s.x, s.y, 2, 2, :yellow }
end
```

- `<<`, `push` and `append` put a thing in. `shift` takes out the oldest, `clear` takes out all, and `delete_if` and `reject!` take out those the block's test holds for.
- `each` walks them oldest first, `reverse_each` newest first, and `each_with_index` gives the place in the walk too. `size`, `length`, `count`, `empty?` and `any?` count them.
- `a == b` when every field is equal, and `a.equal?(b)` when they are the same thing. A thing kept in a name after its walk (`pick = s if s.x == 10`) is still that thing.
- A field holds fractions where a line puts one in. A member can have any name Ruby allows, and a member named as what a thing answers, such as `left` or `move`, means the member.
- A part keeps one the same way: `@enemies = Array.new(capacity: 8)` in `initialize`, and `@enemies << Enemy.new(...)` in a method of the same class. `Array.new` takes `fast:` too.

Limits: see [Refused › Arrays of Structs](#arrays-of-structs) and [Builds, but surprises you](#builds-but-surprises-you).

### Sorting an Array of Structs

- `sort_by! { |s| s.y }` puts them in order by one field, the smallest first. `sort_by! { |s| -s.y }` or `sort_by!(&:y).reverse!` put the biggest first.
- `sort_by! { |s| [s.y, -s.x] }` sorts by `y`, and where two have the same `y`, by `x`, the biggest first. A sort changes the order of the walk, and so the order of drawing.
- A Struct can give its own order, as in Ruby: `include Comparable` and `def <=>(other) = y <=> other.y` in its block. Write `other.y <=> y` for the biggest first, and `[y, x] <=> [other.y, other.x]` for ties.
- With that order, `sort!` sorts, and `min`, `max` and `minmax` give the things it puts first and last. `<`, `>`, `<=`, `>=` and `between?` compare two things, `==` holds where `<=>` gives 0, and `eql?` compares every field.
- A comparing block, `sort! { |a, b| b.y <=> a.y }` or `max { |a, b| a.x <=> b.x }`, orders by itself, by the same rule.
- On an empty Array, `min` and `max` give no thing, and as a test the answer is false, as Ruby's nil: `if (m = things.min)`.

### Showing an Array of Structs as sprites

- On a tiled screen, `drawn_as :spark` in the Struct's block shows each thing as a sprite at its `x` and `y`.
- `drawn_as facing: {...}, frames: [...], rate: 8` takes what a sprite takes. Name only the picture that faces right: the picture that faces left is that picture, mirrored.
- `layer: :swimmers` puts each thing in that layer, and `sparks.put_in_layer :walking` moves every thing to another layer.
- A thing in a walk answers `face`, `draw_with`, `move`, `overlaps?`, its edges and the screen-edge tests, as a sprite does. `sparks.blocked_by(room)` stops each thing at the walls of the background `room` when it moves.

## Splitting a game into files

A file of game code is loaded with `VBlank.require_game_file`, never `require_relative`, and VBlank checks its methods and blocks as it checks a game block. Its locals stay its own, and its constants and methods are shared with the game. A Struct or Data class can also be in a file loaded with plain `require`, and its objects keep the numbers they were made from, as in Ruby.

```ruby
VBlank.require_game_file "lamp"   # lamp.rb, beside this file

VBlank.game "LAMPS", consoles: %i[gba] do
  screen :bitmap
  lamp = Lamp.new(self)
  game_loop { call :switch_lamp if pressed(:a) }
end
```

Limits: see [Refused › Parts and instance variables](#parts-and-instance-variables).

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

<details>
<summary>Don't: <code>0.step(10, by)</code> with a game number as the step. Do: a step in the code</summary>

When the game counts a `step` as it plays, the step must be a whole number written in the code, and not 0.

Refused:

```ruby
screen :bitmap
by = 1
game_loop do
  by += 1 if pressed(:a)
  0.step(10, by) { |i| draw_rect_at i, 0, 1, 1, :red }
end
```

VBlank says:

```
This `step` uses a number that the game keeps, so the game counts as it plays. Then the step must be a whole number in the code, and not 0, as in `0.step(n, 2)`. To fix this, write the step as a number.
```

Write instead:

```ruby
screen :bitmap
by = 1
game_loop do
  by += 1 if pressed(:a)
  0.step(10, 2) { |i| draw_rect_at i, 0, 1, 1, :red }
end
```

</details>

<details>
<summary>Don't: <code>(0...n).map</code> with a game number <code>n</code>. Do: <code>(0...n).each</code></summary>

The game counts through such a range as it plays. The range can go round with `each` or `step`, or in a `for` loop, and nothing else.

Refused:

```ruby
screen :bitmap
n = 3
game_loop do
  n += 1 if pressed(:a)
  (0...n).map { |i| draw_rect_at i, 0, 1, 1, :red }
end
```

VBlank says:

```
This range goes to a number that the game keeps, and it is asked for `map`. The game counts through such a range as it plays, so the range can only go round with `each` or `step`, or in a `for` loop. To fix this, write `(0...n).each do |i|` and do the work in the loop.
```

Write instead:

```ruby
screen :bitmap
n = 3
game_loop do
  n += 1 if pressed(:a)
  (0...n).each { |i| draw_rect_at i, 0, 1, 1, :red }
end
```

</details>

<details>
<summary>Don't: <code>steps.next</code> in a <code>loop do</code> the game runs. Do: count a game number</summary>

A `loop do` with a `break` under a game test is a loop the game runs. The game keeps the value of one round only, so a plain value that changes on each round cannot be read there.

Refused:

```ruby
screen :bitmap
hp = 3
total = 0
steps = [1, 2, 3].each
game_loop do
  hp -= 1 if pressed(:a)
  loop do
    break if hp > 1
    total += steps.next
  end
end
```

VBlank says:

```
This `loop do` is a loop the game runs, since a `break` or `next` in it is under a test the game makes. But its body reads a plain Ruby value that changes on each round, such as `steps.next`. The game keeps one round's value only. To fix this, read the values from an Array the game keeps, at a number the game counts.
```

Write instead:

```ruby
screen :bitmap
hp = 3
total = 0
game_loop do
  hp -= 1 if pressed(:a)
  at = 0
  loop do
    break if hp > 1 || at > 2
    at += 1
    total += at
  end
end
```

</details>

<details>
<summary>Don't: <code>break 5</code> in a loop the game runs. Do: set a variable, then <code>break</code></summary>

The game cannot give a value from a loop.

Refused:

```ruby
screen :bitmap
at = 0
found = 0
game_loop do
  at = 0
  found = while at < 10
    at += 1
    break 5 if at > 3
  end
end
```

VBlank says:

```
`break` gives a value here, in a loop the game runs. The game cannot give a value from a loop. To fix this, set a variable before the `break`, and write `break` alone.
```

Write instead:

```ruby
screen :bitmap
at = 0
found = 0
game_loop do
  at = 0
  while at < 10
    at += 1
    if at > 3
      found = 5
      break
    end
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

An Array holds whole numbers or fractions, not both. VBlank reads which from what goes in: its start, and every value that game code puts in with `<<`, `push`, `[]=` and the like. A Float, a name given one, or `.to_f` makes an Array of fractions, and a whole number written out, such as `0`, fits either kind.

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

<details>
<summary>Don't: <code>[a, b].find { ... }</code> with game numbers. Do: walk with <code>each</code></summary>

Ruby needs the answer of the test while it builds the game, and the game decides the test as it plays. This is also true for `select` and the other methods that pick items by a test.

Refused:

```ruby
screen :bitmap
a = 1
b = 2
pick = 0
game_loop do
  a += 1
  pick = [a, b].find { |n| n > 2 }
end
```

VBlank says:

```
`find` picks items by a test, and this test is decided as the game plays. Ruby needs the answer while the game is built. To fix this, walk the items with `each` and keep what the test finds in a game number.
```

Write instead:

```ruby
screen :bitmap
a = 1
b = 2
pick = 0
game_loop do
  a += 1
  pick = 0
  [a, b].each { |n| pick = n if pick == 0 && n > 2 }
end
```

</details>

<details>
<summary>Don't: <code>max_by</code>, <code>sort</code> or <code>clamp</code> on game numbers. Do: <code>max</code> or <code>min</code></summary>

These ask `<=>` while VBlank builds the game, and the game works out the numbers as it plays. Code of your own outside the game that asks `<=>` is refused too.

Refused:

```ruby
screen :bitmap
a = 1
b = 2
best = 0
game_loop do
  a += 1
  best = [a, b].max_by { |n| n }
end
```

VBlank says:

```
`<=>` compares two numbers while the game is built, and this number is worked out as the game plays. To fix this, compare with `<`, `>` or `==`, or use `max` or `min`.
```

Write instead:

```ruby
screen :bitmap
a = 1
b = 2
best = 0
game_loop do
  a += 1
  best = [a, b].max
end
```

</details>

<details>
<summary>Don't: <code>uniq</code>, <code>tally</code>, <code>-</code> and the like on game numbers. Do: <code>==</code></summary>

Ruby compares the items while it builds the game, and it cannot compare a number that the game works out. This is true for `uniq`, `tally`, `group_by`, `index(7)`, `find_index(7)`, `rindex(7)`, `-`, `&`, `|`, `difference`, `intersection`, `union`, `intersect?` and `delete(7)`. It is true also where an item holds such a number, as a Struct holds it in a field.

Refused:

```ruby
screen :bitmap
a = 1
b = 2
n = 0
game_loop do
  a += 1
  n = [a, b].uniq.size
end
```

VBlank says:

```
`uniq` compares the items, and one of them is a number the game works out as it plays. Ruby must compare them while the game is built, and it cannot compare that number then. To fix this, compare the numbers one at a time with `==`, or walk the items with `each` and keep the answer in a game number.
```

Write instead:

```ruby
screen :bitmap
a = 1
b = 2
n = 0
game_loop do
  a += 1
  n = a == b ? 1 : 2
end
```

</details>

<details>
<summary>Don't: index a <code>game_variables</code> Array through its reader. Do: a method (rare)</summary>

An Array named with `game_variables` has one number for each index, made from its first numbers. So VBlank cannot find the number at an index that the game works out.

Refused:

```ruby
class Tally
  game_variables :counts
  attr_reader :counts

  def initialize
    @counts = [0, 0, 0]
  end
end
screen :bitmap
tally = Tally.new
at = 0
game_loop do
  at = (at + 1) % 3
  tally.counts[at] += 1
end
```

VBlank says:

```
This Array holds game variables, and this line takes one at an index that is worked out as the game plays. VBlank made a variable for each index where the Array got its first numbers, so it cannot find this one. To fix this, read the Array at the index in its class, like `def count_at(at) = @counts[at]`, and call that method here.
```

Write instead:

```ruby
class Tally
  game_variables :counts

  def initialize
    @counts = [0, 0, 0]
  end

  def bump(at) = @counts[at] += 1
end
screen :bitmap
tally = Tally.new
at = 0
game_loop do
  at = (at + 1) % 3
  tally.bump(at)
end
```

</details>

<details>
<summary>Don't: give one Array to two parts that both change it. Do: one Array each (rare)</summary>

In Ruby the two parts share one Array. The game keeps an Array for each part, so they cannot share.

Refused:

```ruby
class Tally
  def initialize(counts)
    @counts = counts
  end

  def bump(at) = @counts[at] += 1
end
screen :bitmap
counts = [0, 0, 0]
left = Tally.new(counts)
right = Tally.new(counts)
at = 0
game_loop do
  at = (at + 1) % 3
  left.bump(at)
  right.bump(at)
end
```

VBlank says:

```
`@counts` of a `Tally` holds the same Array as `@counts` of a `Tally` (at tally.rb:3). In Ruby, the two share one Array, so a change through one shows through the other. The game keeps an Array for each, so they cannot share. To fix this, keep the Array in one part, and read it through that part in the other. Or, if each part must have its own numbers, give each part a copy made with `dup`.
```

Write instead:

```ruby
class Tally
  def initialize(counts)
    @counts = counts
  end

  def bump(at) = @counts[at] += 1
end
screen :bitmap
left = Tally.new([0, 0, 0])
right = Tally.new([0, 0, 0])
at = 0
game_loop do
  at = (at + 1) % 3
  left.bump(at)
  right.bump(at)
end
```

</details>

### Hashes

<details>
<summary>Don't: give a game Hash a key it does not have. Do: write every key at the start</summary>

The game keeps one number for each key that the Hash starts with. So a key that the Hash does not have stops the build, and a misspelt key stops it too.

Refused:

```ruby
screen :bitmap
h = { a: 1 }
game_loop do
  h[:a] += 1
  h[:b] = 2 if pressed(:a)
end
```

VBlank says:

```
This Hash holds game variables and has no key :b, so the game would never see this number. The keys are :a. To fix this, use one of those keys.
```

Write instead:

```ruby
screen :bitmap
h = { a: 1, b: 0 }
game_loop do
  h[:a] += 1
  h[:b] = 2 if pressed(:a)
end
```

</details>

<details>
<summary>Don't: <code>h.delete(:b)</code>, <code>merge!</code>, <code>clear</code> on a game Hash. Do: one key at a time</summary>

The game cannot add a key, remove a key or change many keys in one step. This is true for `store`, `merge!`, `delete`, `transform_values!`, `clear` and the others.

Refused:

```ruby
screen :bitmap
h = { a: 1, b: 2 }
game_loop do
  h[:a] += 1
  h.delete(:b)
end
```

VBlank says:

```
This Hash holds game variables, and this line changes it with `delete`. The game keeps one number for each key, and cannot add a key, remove a key or change many keys in one step. To fix this, change one key at a time, like `hash[:key] = 5` or `hash[:key] += 1`.
```

Write instead:

```ruby
screen :bitmap
h = { a: 1, b: 2 }
game_loop do
  h[:a] += 1
  h[:b] = 0
end
```

</details>

<details>
<summary>Don't: <code>h.dup</code>, <code>merge</code>, <code>select</code> of a game Hash. Do: read one value</summary>

In Ruby the copy keeps its own numbers. Here the copy holds the numbers of the Hash, so it changes when the Hash changes. This is true for `dup`, `merge`, `select`, `slice` and the others that give a new Hash.

Refused:

```ruby
screen :bitmap
h = { a: 1, b: 2 }
c = nil
game_loop do
  h[:a] += 1
  c = h.dup
end
```

VBlank says:

```
This Hash holds game variables, and this line takes a copy of it, like `hash.dup` or `hash.merge(other)`. In Ruby the copy is its own. Here the copy would hold the same variables, so it would change when the Hash changes. To fix this, read the values one at a time, like `left = hash[:left]`, or add them up in place, like `hash.sum { |_key, value| value }`.
```

Write instead:

```ruby
screen :bitmap
h = { a: 1, b: 2 }
a_now = 0
game_loop do
  h[:a] += 1
  a_now = h[:a]
end
```

</details>

<details>
<summary>Don't: keep <code>v = h.values</code> of a game Hash. Do: <code>h.values.sum</code> in place</summary>

An Array of the values kept in a name is a copy, the same as `h.to_a`. Read the values where you make them, as in `h.values.sum`, `h.values.max` or `h.values.each { ... }`.

Refused:

```ruby
screen :bitmap
h = { a: 1, b: 2 }
total = 0
game_loop do
  h[:a] += 1
  v = h.values
  total = v.sum
end
```

VBlank says:

```
This Hash holds game variables, and this line takes a copy of it, like `hash.dup` or `hash.merge(other)`. In Ruby the copy is its own. Here the copy would hold the same variables, so it would change when the Hash changes. To fix this, read the values one at a time, like `left = hash[:left]`, or add them up in place, like `hash.sum { |_key, value| value }`.
```

Write instead:

```ruby
screen :bitmap
h = { a: 1, b: 2 }
total = 0
game_loop do
  h[:a] += 1
  total = h.values.sum
end
```

</details>

<details>
<summary>Don't: <code>h[at]</code> with a key the game works out. Do: an Array</summary>

Ruby finds the number for a key while it builds the game. So the key must be known then. An Array can be read at an index that the game works out.

Refused:

```ruby
screen :bitmap
h = { 0 => 1, 1 => 2 }
at = 0
game_loop do
  at = 1 - at
  h[at] += 1
end
```

VBlank says:

```
This Hash holds game variables, and this line takes one at a key that is worked out as the game plays. Ruby finds a slot while it builds the game, so it cannot find this one. To fix this, use a key known while building, like a symbol from a Ruby loop (`SIDES.each do |side|`), or keep the numbers in an Array: the game can read an Array at an index it works out.
```

Write instead:

```ruby
screen :bitmap
counts = [1, 2]
at = 0
game_loop do
  at = 1 - at
  counts[at] += 1
end
```

</details>

<details>
<summary>Don't: change a part's Array of names in game code. Do: <code>game_variables :used</code> (rare)</summary>

A part's Hash or Array that holds only symbols stays a Ruby one: names filled while the part is set up, as `@used |= names` in `initialize`. Game code can ask about it, as `@used.intersect?(AIMS)`, and Ruby answers while it builds the game.

Refused:

```ruby
class Aim
  def initialize(build)
    @used = []
    @used |= %i[left]
    build.func(:aim_right) { @used[0] = :right }
  end
end
```

VBlank says:

```
This line changes `@used` while the game plays. `@used` holds only names, so it stays a plain Ruby value, and the game does not see the change. To fix this, add `game_variables :used` to `Aim`.
```

Write instead:

```ruby
class Aim
  game_variables :used

  def initialize(build)
    @used = []
    @used |= %i[left]
    build.func(:aim_right) { @used[0] = :right }
  end
end
```

</details>

### Arrays of Structs

<details>
<summary>Don't: an Array of <code>Data</code> objects that game code changes. Do: <code>Struct.new</code></summary>

The fields of a `Data` object cannot change, and an Array that game code changes holds things whose fields change.

Refused:

```rb
Spot = Data.define(:x, :y)
screen :bitmap
spots = Array.new(capacity: 8)
game_loop do
  spots << Spot.new(1, 2) if spots.size < 8
  spots.each { |s| draw_rect_at s.x, s.y, 1, 1, :red }
end
```

VBlank says:

```
`spots` holds things made from Spot, which is not a Struct. An Array of things that game code changes holds Structs. To fix this: A `Data` thing cannot change its fields. Make it with `Struct.new`.
```

Write instead:

```ruby
Spot = Struct.new(:x, :y)
screen :bitmap
spots = Array.new(capacity: 8)
game_loop do
  spots << Spot.new(1, 2) if spots.size < 8
  spots.each { |s| draw_rect_at s.x, s.y, 1, 1, :red }
end
```

</details>

<details>
<summary>Don't: <code>min_by</code> and other methods a pool does not have. Do: the methods above</summary>

An Array of Structs that game code changes has only the methods that the message names.

Refused:

```ruby
Spark = Struct.new(:x, :y)
screen :bitmap
sparks = Array.new(capacity: 8)
game_loop do
  sparks << Spark.new(1, 2) if sparks.size < 8
  low = sparks.min_by { |s| s.y }
end
```

VBlank says:

```
`sparks` is an Array of Spark that game code changes, so the game keeps it in a fixed number of slots. It does not answer `min_by`. It answers `<<`, `push`, `append`, `shift`, `clear`, `each`, `reverse_each`, `each_with_index`, `delete_if`, `reject!`, `sort!`, `sort_by!`, `reverse!`, `min`, `max`, `minmax`, `size`, `length`, `count`, `empty?`, `any?`, `blocked_by`, `put_in_layer`.
```

Write instead:

```ruby
Spark = Struct.new(:x, :y)
screen :bitmap
sparks = Array.new(capacity: 8)
game_loop do
  sparks << Spark.new(1, 2) if sparks.size < 8
  sparks.sort_by! { |s| s.y }
end
```

</details>

<details>
<summary>Don't: sort an Array of Structs inside a walk of it. Do: sort after the walk</summary>

The walk would lose its place.

Refused:

```ruby
Spark = Struct.new(:x, :y)
screen :bitmap
sparks = Array.new(capacity: 8)
game_loop do
  sparks << Spark.new(1, 2) if sparks.size < 8
  sparks.each do |s|
    s.y += 1
    sparks.sort_by! { |t| t.y }
  end
end
```

VBlank says:

```
This line sorts `sparks` while a walk of it is under way, and the walk would lose its place. To fix this, sort `sparks` after the walk ends.
```

Write instead:

```ruby
Spark = Struct.new(:x, :y)
screen :bitmap
sparks = Array.new(capacity: 8)
game_loop do
  sparks << Spark.new(1, 2) if sparks.size < 8
  sparks.each { |s| s.y += 1 }
  sparks.sort_by! { |t| t.y }
end
```

</details>

<details>
<summary>Don't: <code>sparks.min(2)</code>. Do: sort, then walk the first two</summary>

`min(2)` makes a new Array, and the game keeps no room for one.

Refused:

```ruby
Spark = Struct.new(:x, :y) do
  include Comparable
  def <=>(other) = y <=> other.y
end
screen :bitmap
sparks = Array.new(capacity: 8)
game_loop do
  sparks << Spark.new(1, 2) if sparks.size < 8
  low = sparks.min(2)
end
```

VBlank says:

```
`min(2)` gives an Array of things, and the game keeps no room for a new Array. To fix this, sort `sparks` with `sort!` and walk the first 2 with `each_with_index`.
```

Write instead:

```ruby
Spark = Struct.new(:x, :y)
screen :bitmap
sparks = Array.new(capacity: 8)
game_loop do
  sparks << Spark.new(1, 2) if sparks.size < 8
  sparks.sort_by! { |s| s.y }
  sparks.each_with_index { |s, i| draw_rect_at s.x, s.y, 1, 1, :red if i < 2 }
end
```

</details>

<details>
<summary>Don't: <code>s.clamp(low, high)</code> with things of no Array. Do: compare fields</summary>

The game compares things of one Array only. Ruby can stop with an error where `clamp` compares two different things.

Refused:

```ruby
Spark = Struct.new(:x, :y) do
  include Comparable
  def <=>(other) = y <=> other.y
end
screen :bitmap
sparks = Array.new(capacity: 8)
low = Spark.new(0, 0)
high = Spark.new(0, 9)
game_loop do
  sparks << Spark.new(1, 2) if sparks.size < 8
  sparks.each { |s| s.clamp(low, high) }
end
```

VBlank says:

```
This line compares a thing of `sparks` with something that is not one of its things. The game compares things of one Array only. To fix this, compare their fields: `a.y < b.y`.
```

Write instead:

```ruby
Spark = Struct.new(:x, :y)
screen :bitmap
sparks = Array.new(capacity: 8)
game_loop do
  sparks << Spark.new(1, 2) if sparks.size < 8
  sparks.each { |s| s.y = s.y.clamp(0, 9) }
end
```

</details>

<details>
<summary>Don't: a <code>&lt;=&gt;</code> that adds fields. Do: <code>sort_by! { |s| [s.y, s.x] }</code></summary>

The game can sort by a `<=>` only when it compares the fields one by one.

Refused:

```ruby
Spark = Struct.new(:x, :y) do
  include Comparable
  def <=>(other) = (x + y) <=> (other.x + other.y)
end
screen :bitmap
sparks = Array.new(capacity: 8)
game_loop do
  sparks << Spark.new(1, 2) if sparks.size < 8
  sparks.sort!
end
```

VBlank says:

```
The `<=>` of Spark does not compare its fields one by one, so the game cannot sort by it. To fix this, compare one field with the other thing's same field, `y <=> other.y`, or `other.y <=> y` for the biggest first. For ties, compare Arrays of fields: `[y, x] <=> [other.y, other.x]`.
```

Write instead:

```ruby
Spark = Struct.new(:x, :y)
screen :bitmap
sparks = Array.new(capacity: 8)
game_loop do
  sparks << Spark.new(1, 2) if sparks.size < 8
  sparks.sort_by! { |s| [s.y, s.x] }
end
```

</details>

<details>
<summary>Don't: <code>sort!</code> on Structs with no <code>&lt;=&gt;</code>. Do: <code>sort_by! { |s| s.y }</code></summary>

A Struct has no order of its own unless it gives a `<=>`.

Refused:

```ruby
Spark = Struct.new(:x, :y)
screen :bitmap
sparks = Array.new(capacity: 8)
game_loop do
  sparks << Spark.new(1, 2) if sparks.size < 8
  sparks.sort!
end
```

VBlank says:

```
`sparks` holds Spark things, which have no order of their own. To fix this, sort by one of their fields with `sort_by!`: `sparks.sort_by! { |s| s.y }`, or give Spark a `<=>` that compares its fields.
```

Write instead:

```ruby
Spark = Struct.new(:x, :y)
screen :bitmap
sparks = Array.new(capacity: 8)
game_loop do
  sparks << Spark.new(1, 2) if sparks.size < 8
  sparks.sort_by! { |s| s.y }
end
```

</details>

<details>
<summary>Don't: <code>shift</code>, then <code>&lt;&lt;</code>, in one walk. Do: add the new thing after the walk</summary>

A thing taken out inside a walk gives its place back only when the walk ends. So a full Array has no room for the new thing yet.

Refused:

```ruby
Spark = Struct.new(:x, :y)
screen :bitmap
sparks = Array.new(capacity: 8)
game_loop do
  sparks << Spark.new(1, 2) if sparks.size < 8
  sparks.each do |s|
    sparks.shift if s.y > 5
    sparks << Spark.new(0, 0)
  end
end
```

VBlank says:

```
This line adds to `sparks` inside a walk of it, after a `shift` in the same walk. An item taken out inside a walk gives its place back only when the walk ends, so a full `sparks` has no room for this item. To fix this, add the new item after the walk.
```

Write instead:

```ruby
Spark = Struct.new(:x, :y)
screen :bitmap
sparks = Array.new(capacity: 8)
game_loop do
  sparks << Spark.new(1, 2) if sparks.size < 8
  sparks.each { |s| s.y += 1 }
  sparks.shift if sparks.size == 8
  sparks << Spark.new(0, 0)
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

VBlank reads the class body that makes the Array to know what the Array holds. A method in the reopened class does not count. The same message comes for a game loop line that adds to a part's plain Array on every pass, such as `hooks.after { @count += 1 }`.

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

The game keeps a part's Array or Hash only when the part is made inside the game block. A part made above it is made one time, before VBlank builds the game, and a game built for two consoles cannot share it.

A part whose numbers alone change works anywhere. So does an Array of Structs made above it, such as `dots = [Dot.new(3, 0)]`: game code can walk it and change each Struct's numbers, and the Array stays a Ruby Array of the same size.

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

A line that changes a part's Array through its reader makes the Array the game's for that one part, and the first use in game code must be that line. Code that reads the Array before the change gets a plain Ruby Array, which does not see the change.

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

<details>
<summary>Don't: <code>Counter.new</code> in the game loop. Do: <code>@counter ||= Counter.new</code></summary>

The game loop runs every frame, and in Ruby each new part starts again from `initialize`. So a part whose numbers or Arrays change cannot be made there. A part whose numbers never change, such as a spot that only answers questions, can be made anywhere.

Refused:

```ruby
class Counter
  attr_reader :n

  def initialize
    @n = 0
  end

  def bump = @n += 1
end
screen :bitmap
game_loop do
  counter = Counter.new
  counter.bump
  draw_rect_at counter.n, 0, 2, 2, :white
end
```

VBlank says:

```
This line makes a new `Counter` in code that runs every frame. Its numbers change as the game plays, and in Ruby each new one starts again from `initialize`. To fix this, make it above the game loop, or keep it in an instance variable, like `@part ||= Counter.new(...)`, so it is made one time.
```

Write instead:

```ruby
class Counter
  attr_reader :n

  def initialize
    @n = 0
  end

  def bump = @n += 1
end
screen :bitmap
game_loop do
  counter = (@counter ||= Counter.new)
  counter.bump
  draw_rect_at counter.n, 0, 2, 2, :white
end
```

</details>

<details>
<summary>Don't: keep two different things in one name with <code>||=</code>. Do: a name each</summary>

Ruby keeps what the line that runs first makes, and VBlank cannot know which line that is.

Refused:

```rb
Bat = Struct.new(:x)
Rat = Struct.new(:x)
screen :bitmap
game_loop do
  @enemy ||= Bat.new(1) if pressed(:a)
  @enemy ||= Rat.new(2)
  @enemy.x += 1
end
```

VBlank says:

```
`@enemy` keeps `Bat.new(1)` on one line (at game.rb:5), and `Rat.new(2)` on this line. In Ruby, `@enemy` keeps what the line that runs first makes as the game plays, and VBlank cannot know which line that is. To fix this, keep each one in a name of its own, or make `@enemy` above the game loop.
```

Write instead:

```ruby
Bat = Struct.new(:x)
Rat = Struct.new(:x)
screen :bitmap
game_loop do
  @bat ||= Bat.new(1)
  @rat ||= Rat.new(2)
  @rat.x += 1
end
```

</details>

<details>
<summary>Don't: give <code>@point</code> a new Struct after game code read it. Do: change its fields</summary>

In Ruby, the read gets the Struct that an earlier pass gave `@point`, and VBlank cannot follow that.

Refused:

```rb
Point = Struct.new(:x, :y)
screen :bitmap
@point = Point.new(1, 1)
game_loop do
  @point.x += 1
  draw_rect_at @point.x, @point.y, 2, 2, :white
  @point = Point.new(1, 1) if @point.x > 100
end
```

VBlank says:

```
This line gives `@point` a new `Point`, and game code read the `Point` that `@point` held before. In Ruby, that read gets the `Point` an earlier pass gave `@point`. VBlank cannot follow that. To fix this, keep one `Point` and change its fields, like `@point.x = 1`.
```

Write instead:

```ruby
Point = Struct.new(:x, :y)
screen :bitmap
@point = Point.new(1, 1)
game_loop do
  @point.x += 1
  draw_rect_at @point.x, @point.y, 2, 2, :white
  @point.x = 1 if @point.x > 100
end
```

</details>

<details>
<summary>Don't: freeze a Struct that holds game numbers. Do: leave it unfrozen (rare)</summary>

This is for a Struct or Data class from a file loaded with plain `require`. VBlank must change the object to keep the numbers in its fields.

Refused:

```rb
require_relative "point"          # Point = Struct.new(:x, :y)

VBlank.game "FROZEN", consoles: %i[gba] do
  screen :bitmap
  hp = 0
  game_loop do
    hp += 1
    point = Point.new(hp, 0).freeze
    draw_rect_at point.x, point.y, 2, 2, :white
  end
end
```

VBlank says:

```
Game code uses an object of `Point` that is frozen, or is in something frozen (Point). Its fields hold numbers the game works out, and VBlank must change the object to keep them. To fix this, do not freeze it.
```

Write instead:

```rb
require_relative "point"          # Point = Struct.new(:x, :y)

VBlank.game "FROZEN", consoles: %i[gba] do
  screen :bitmap
  hp = 0
  game_loop do
    hp += 1
    point = Point.new(hp, 0)
    draw_rect_at point.x, point.y, 2, 2, :white
  end
end
```

</details>

<details>
<summary>Don't: read a Data object as <code>it</code> or <code>_1</code>. Do: name the parameter (rare)</summary>

This is for a Data class from a file loaded with plain `require`. VBlank must give the block a copy of the object, and it can only do that for a named parameter.

Refused:

```rb
require_relative "spot"           # Spot = Data.define(:x, :y)

VBlank.game "SPOTS", consoles: %i[gba] do
  screen :bitmap
  hp = 0
  game_loop do
    hp += 1
    spots = [Spot.new(hp, 0)]
    spots.each { draw_rect_at it.x, it.y, 2, 2, :white }
  end
end
```

VBlank says:

```
This block reads an object of `Spot` as `it` or `_1`. Its fields hold numbers the game works out. VBlank must give the block a copy of the object to keep them. To fix this, name the block's parameter, like `{ |point| ... }`.
```

Write instead:

```rb
require_relative "spot"           # Spot = Data.define(:x, :y)

VBlank.game "SPOTS", consoles: %i[gba] do
  screen :bitmap
  hp = 0
  game_loop do
    hp += 1
    spots = [Spot.new(hp, 0)]
    spots.each { |spot| draw_rect_at spot.x, spot.y, 2, 2, :white }
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

On a tiled screen, `draw_number` draws its number again each frame. Ruby draws it once.

Write the line once, above the game loop or in a scene. For an item, as in `shown[at]`, the game reads `at` again each frame too.

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

<details>
<summary>Don't: set a lasting count inside <code>game_loop</code>. Do: set it above the loop</summary>

A name first set inside a game block is set again every time the block runs, so it starts again on each pass. The names of a method are set each time the method runs, as in Ruby.

```ruby
screen :bitmap
total = 0                  # lasts: set once, above the loop
game_loop do
  this_pass = 0            # starts at 0 on every pass
  this_pass += 1
  total += this_pass
end
```

</details>

<details>
<summary>Don't: change a method's argument to change the caller's number. Do: return it</summary>

A method's argument is a copy, so a change inside the method leaves the number of the caller as it was. The build warns about such a line.

```ruby
class Medic
  def heal(hp)
    hp += 1                # changes the copy only
    hp
  end
end
# In game code: hp = medic.heal(hp), not medic.heal(hp) alone
```

</details>

<details>
<summary>Don't: expect <code>"HP #{hp}"</code> to fit the number. Do: give <code>digits:</code></summary>

A number in drawn text takes the room that `draw_number` gives it: 4 digits unless `digits:` gives another size. The number is drawn at the right of that room, so a shorter number leaves a gap before it.

```ruby
screen :bitmap
hp = 3
game_loop do
  hp -= 1 if pressed(:a)
  clear_screen :black
  draw_text "HP #{hp}", 10, 10, :white, digits: 1
end
```

</details>

<details>
<summary>Don't: expect every instance variable to be the game's. Do: change it in game code</summary>

VBlank finds the game's instance variables in the source. One is the game's when a line works it out from what it holds (`@lit = 1 - @lit`, `@ticks += 1`, `@counts[at] += 1`), wherever that line is, or when a line sets it inside a game block.

Any other instance variable is plain Ruby. A game one is plain Ruby too until game code first reads or changes it, so a count bumped while building stays a Ruby number there. From then on, game code reads the game's number, even a routine that comes before the one that changes it.

```ruby
screen :bitmap
@ticks = 0
@ticks += 1                # while building: a Ruby number, now 1
game_loop do
  @ticks += 1              # the game's number, which starts at 1
end
```

</details>

<details>
<summary>Don't: put 200 in a <code>width: :byte</code> list. Do: keep numbers that fit</summary>

A number too big for the slot keeps its low bits, with no error. 200 in a `:byte` reads back as -56.

```ruby
screen :bitmap
small = Array.new(4, 0, width: :byte)
game_loop do
  small[0] = 100
end
```

</details>

<details>
<summary>Don't: <code>&lt;&lt;</code> in a walk where a called routine took a place. Do: add after (rare)</summary>

A thing taken out inside a walk gives its place back only when the walk ends. So a `<<` in a walk that needs a place that a routine the walk called took out stops the game, with a message. A `<<` in a walk of an Array with room joins it at once, and only the walk that it is in does not visit it.

```ruby
Spark = Struct.new(:x, :y)
screen :bitmap
sparks = Array.new(capacity: 8)
game_loop do
  sparks.each { |s| s.y += 1 }
  sparks << Spark.new(0, 0) if sparks.size < 8   # after the walk
end
```

</details>

<details>
<summary>Don't: keep a part in a part that is made every pass. Do: keep both (rare)</summary>

A part kept by another part with `||=` is kept only if that other part is kept too. A part made on every pass makes what it keeps on every pass as well.

```ruby
class Keeper
  def counter = (@counter ||= Counter.new)
end
# In the game loop: keeper = (@keeper ||= Keeper.new), not keeper = Keeper.new
```

</details>

<details>
<summary>Don't: expect a kept part's <code>initialize</code> to run each pass. Do: nothing (rare)</summary>

A part kept with `||=` is made once. So what its `initialize` gives another part goes in once, while VBlank builds the game, as in Ruby: a block it adds to the Array of another part (`hooks.after { @count += 1 }`), or names (`costume.wear(%i[crouch leap])`). The block then runs wherever the other part runs it, on every pass.

A push in `initialize` into an Array that the part was given runs each time the line that makes the part runs, as in Ruby. So does all else that `initialize` does in the game, such as drawing or putting up a picture.

```ruby
class Hopper
  def initialize(hooks)
    @count = 0
    hooks.after { @count += 1 }   # added once, run on every pass
  end
end
```

</details>

## What costs more

These lines build and work, and cost the console more memory or more time than you can expect. Some plain Ruby lines need a hidden number that the game keeps for them, and `rom.profile` lists every line that makes one, with what it costs.

<details>
<summary>Don't: give a handed number another in game code to change its owner. Do: change it through its owner</summary>

`@spot = cursor.at`, then `@spot = 0` in game code, keeps a hidden number for `@spot`: one word of quick memory. The cursor keeps its number, as in Ruby. If you mean to move the cursor, write `cursor.at = 0`. If you only read the number, keep it in a plain local, or read `cursor.at` where you use it.

```ruby
# A cursor, and a marker that starts where the cursor is
class Cursor
  game_variables :at
  attr_accessor :at

  def initialize = @at = 3
end

class Marker
  def initialize(cursor) = @spot = cursor.at
  def jump = @spot = 0

  attr_reader :spot
end
screen :bitmap
cursor = Cursor.new
marker = Marker.new(cursor)
game_loop do
  marker.jump if pressed(:a)
  cursor.at += 1 if pressed(:right)
  draw_rect_at marker.spot, cursor.at, 4, 4, :green
end
```

</details>

<details>
<summary>Don't: <code>item = trail.shift</code> when you can avoid it. Do: <code>trail.first</code>, then <code>shift</code></summary>

`item = trail.shift` keeps the dropped item in a hidden number: one word of quick memory, and a copy each time the line runs. `trail.shift` on its own keeps nothing.

```ruby
screen :bitmap
trail = Array.new(4, 0, capacity: 4)
item = 0
game_loop do
  item = trail.first
  trail.shift
  trail << item
end
```

</details>

<details>
<summary>Don't: <code>sum</code> or <code>max</code> of a long list on every pass. Do: keep a running total</summary>

`sum`, `min`, `max`, `include?` and `==` with an Array look at every item, so they cost more the more items the Array holds.

```ruby
# Add up a growing list, and find its best
screen :bitmap
scores = Array.new(capacity: 8)
total = 0
best = 0
game_loop do
  if scores.size < 8
    scores << 3
    total += 3               # a running total costs one addition
  end
  best = scores.max
  scores.each_with_index { |score, at| draw_rect_at at * 10, 100 - score, 8, score, :green }
end
```

</details>

<details>
<summary>Don't: <code>sort!</code> a list on every pass that rarely changes. Do: sort when it changes</summary>

A sort moves items back one at a time. So it costs little for a list that is nearly in order, and more the more items move.

`rom.profile` lists each line that sorts and what it costs. For the smallest item alone, `min` costs less. On an Array of Structs, `sort!` by the `<=>` of the Struct costs the same as `sort_by!`.

```ruby
screen :bitmap
scores = Array.new(5, 0)
t = 0
game_loop do
  t += 1
  if pressed(:a)
    scores[t % 5] = (t * 37) % 100
    scores.sort!             # only when a score changes
  end
end
```

</details>

<details>
<summary>Don't: expect a counting loop to be a loop. Do: read <code>rom.profile</code></summary>

When every number of `n.times`, `upto`, `downto`, `step`, `each` on a range or `for` is known while building, the build chooses how to make it, and the same game always builds the same way:

- Small rounds are written out once for each time round, which is the fastest. Rounds are small while together they have a size of at most 64. One `draw_rect_at` line is a size of 5, so 4 rounds of two such lines are written out.
- Larger rounds are one loop the game runs, which costs the room of one round. The round number `i` is then a number the game counts, and each round costs time: the loop counts, goes back, and works out each number that counts up with `i`.
- Rounds that differ in more than a number that counts up are written out, however large: a colour or a picture picked by `i` while building, a value read from a Ruby Array at `i`, or a test on `i`. Only a round written out knows its `i` while building.

When a count or an end is a number the game keeps, the loop is a loop in the game, and it goes round as many times as the number holds when the loop starts. `rom.profile` lists each counting loop with its line, its size and what the build chose.

```ruby
screen :bitmap
lives = 3
game_loop do
  clear_screen :black
  lives -= 1 if pressed(:a)
  lives.times { |i| draw_rect_at 10 + (i * 20), 10, 8, 8, :blue }   # a loop in the game
  2.times { |i| draw_rect_at 10 + (i * 20), 30, 8, 8, :green }      # written out two times
end
```

</details>

<details>
<summary>Don't: copy a game number into a field far from where you read it. Do: read it near</summary>

A field keeps its own copy of a number, and that copy is a hidden number, which `rom.profile` lists. It costs nothing when all of these are true: the field was given numbers the game keeps (not the item of an Array, and not a button), it is read in the same block as that line, the lines between only draw, test or change other numbers, and no `on_tick` of a timer changes those numbers.

```ruby
Point = Struct.new(:x, :y)
screen :bitmap
score = 0
point = Point.new(score, 50)
game_loop do
  score += 1
  point.x = score
  draw_rect_at point.x, point.y, 2, 2, :white   # read in the same block: no copy kept
end
```

</details>

<details>
<summary>Don't: fill an Array in a kept part's <code>initialize</code>. Do: make the part above</summary>

A part kept with `||=` starts from the numbers that its `initialize` gives. What its `initialize` puts into an Array that it makes there goes in on the first pass only.

A hidden number keeps that to one time, `rom.profile` names it, and a save that keeps the Array keeps that number too. To skip it, make the part above the game loop.

```ruby
class Flock
  def initialize
    @dots = Array.new(capacity: 8)
    @dots << 0                    # goes in on the first pass only
  end
end
# In the game loop: flock = (@flock ||= Flock.new). Above the loop, no hidden number.
```

</details>

<details>
<summary>Don't: a big list in full words if its numbers are small. Do: <code>width:</code>, <code>narrow</code></summary>

Two settings of `Array.new` can be left out, and change only what the list costs:

- `width: :byte` or `width: :half` keeps each item in less memory. A number too big for the slot keeps its low bits (see [Builds, but surprises you](#builds-but-surprises-you)).
- `fast: true` or `fast: false` puts the list in the quick memory or in the roomy one. It changes only how long a read takes.

In the block of a Struct, `narrow :x, :y` keeps each of those fields in half a word, and `narrow kind: :byte` keeps one in a byte, for a big Array of Structs.

```ruby
screen :bitmap
small = Array.new(64, 0, width: :byte, fast: false)
game_loop do
  small[0] += 1
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

Anything else that seems to need a lower-level verb or VBlank's own classes is a gap in VBlank: report it with the line that did the wrong thing.
