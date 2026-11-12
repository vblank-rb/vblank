# DSL reference: Game code is plain Ruby

How a game's code is written. The map of every page is `.claude/rules/dsl-reference.md`.
Worked examples: `test/all/vblank/dsl/test_plain_ruby.rb` (what works) and
`test/all/vblank/dsl/test_plain_ruby_refusals.rb` (what is refused, and what to write instead).

A game is written in ordinary Ruby: locals, `=` and `+=`, `if` and `case`, `&&` and `||`, methods of
its own. The verbs on the other pages (`sprite`, `draw_text`, `pressed` …) are called from that Ruby.
Nothing else is needed, and **nothing else should be reached for**: where plain Ruby does not do what
it says here, that is a fault in VBlank to report, not a reason to write the game another way.

## The one rule: built now, or played later

A game file runs once, while the game is built. Code inside a **game block** (`game_loop`, `scene`,
`func`, `once_a_frame`, `every`, `after`, `repeat`, `each_pass`, a timer's `on_tick`, a menu `item`)
is not run then: it is recorded, and runs as the game plays, every time its block does.

Each construct looks at what it is given:

- **A test on a game number** (one game code changes, `pressed(:a)`, a sprite's `x`) becomes a branch
  in the game, taken or not on each pass.
- **A test on a plain value** (`if console == :gbc`, `if screen_width > 200`) is decided while
  building: one side is in the game and the other is not.

So the same `if` can be either, and that is the point: build-time choices cost nothing as the game
plays.

## Game variables

- `hp = 10` **makes a game variable** named `hp` when game code changes it later. It can start as a
  whole number, a Float (a fraction, see `variables.md`), `true` or `false`, a symbol, `nil`, or a
  constant or a sum of constants (`x = WIDTH / 2`). Set up outside game blocks, it can also start from
  another name, a method's answer or a list read.
- **A name nothing in game code changes stays plain Ruby** and costs nothing.
- **A symbol is a game state**: `mode = :title`, then `mode = :playing` in game code, `mode ==
  :playing` to test it, and `call mode` runs the routine or scene of that name (`scenes.md`).
- **Each name is its own variable.** Two names given one number are two variables, and the same name in
  two routines is two, as it is in two files of one game.
- **A name first set inside a game block is set again every time the block runs**, so it starts afresh
  each pass. State that lasts is set up above the game loop.
- **A method's own names are set each time the method runs**, as in Ruby: `count = 0` on a method's
  first line, or at the top of a loop's body in it, sets `count` again on every call and every round,
  whether the method is called from a game loop, from an unpacking routine or twice while setting up,
  and whatever number the line works out each time. `count, other = 0, 0` does the same for both
  names, and `target = nil` sets the name to nil, which reads as 0.

## Changing a variable

- `x = 5`, `x += n`, `x -= n`, `x *= 2`, `flags |= 4`, `flags &= ~4` all change it. `x ||= 2` changes
  only `false` or `nil`: a number is truthy, so `x ||= 2` leaves `x = 0` alone, as in Ruby.
- `a, b = b, a` and splats work, on every pass.
- **A name holds a value, as in Ruby.** `old = hp` in game code keeps hp's number from that line;
  `d = hp + 1` keeps its line's answer.
- **A method's argument and a value taken from a Hash are copies.** `def hurt(hp) = hp -= 1` does not
  change the caller's `hp`, and `hp = ball[:hp]; hp = 0` leaves `ball[:hp]` alone. Write
  `ball[:hp] = 0`, pass the Hash, or return the number. The build warns about each such line.
- `@x = 2`, `h[:x] = 2` and `sprite.x = 2` follow game tests like any other write.
- Numbers have `abs`, `clamp`, `approach` (new numbers) and `abs!`, `clamp!`, `approach!` (change
  the variable); `variables.md` has the arithmetic, division and fractions.

## Tests

- `if`, `elsif`, `else`, `unless`, the trailing forms and the ternary work as in Ruby.
- **Truthiness is Ruby's**: only `nil` and `false` are false. Keep a yes or no as `true`/`false`, and
  compare a number: `if hp > 0`, never `if hp`.
- `&&`, `||`, `!`, `and`, `or` and `not` join tests, and the right side is skipped as in Ruby. `&`,
  `|` and `^` between tests evaluate both sides.
- `== != < <= > >=`, and `zero?`, `positive?` and `negative?`, ask about a number. Either side can be
  the game's number: `3 == hp` is the test `hp == 3` is.
- `x = test ? a : b`, `x = if … else … end` and `x = case … else … end` pick a value on every pass.
- `case` on a game number takes `when` with a number, a symbol, a range, a comma list, a variable, or
  `true`/`false`. A `case` with no subject asks each `when` in turn. `case … in` takes the same
  values, with `a | b` between them; any other pattern (a binding, an array, a guard) is Ruby's, on
  a plain value only.
- `nil` is Ruby's: `target = nil`, then `if target`, `target.nil?`, `target == nil`, `target != nil`,
  `target || 7`. Read as a number, nil is 0.

## Loops

- **`while` and `until` on a game test are loops in the game.** The build warns about one that never
  waits for a frame. The whole test is asked again on every round, as Ruby asks it: `while count < 5
  && marks[count] != 9`, and `while copy.byte(at) != 0` in an unpacking routine, whose read is
  checked against the copy's end on each round.
- **A loop can start on plain numbers and become the game's.** `at = 3`, then `while at < size` with a
  body that moves `at` on under a game test (`if found then … else at += 17 end`): the first round is
  Ruby's, written out once, and the rounds after it are a loop in the game.
- **A loop on plain numbers inside a loop of the game's is written out on every round**: `column = 0`,
  then `while column < 2` with `column += 1`, in the body of `while row < rows`.
- **`repeat(n) { |i| … }` is the loop counted as the game plays** (`control-flow.md`).
- **A block verb called on a builder held in a name means what it means bare**: `@build.repeat(n) { … }`
  or `build.every(2) { … }` in a method of a part is `repeat` or `every` in a game block.
- **`.each`, `.times`, `upto`, `step` and `.map` on something written in the source** (a literal, a
  constant, a range) run while building: the body is written out once for each time round. In a game
  block, `3.times { x += 1 }` adds 3 on every pass. That is right for laying out a row of sprites, and
  wrong for a count the game works out.
- `.each` on a name is taken as game code, since it may be a pool's.
- `for x in 1..3` runs while building, as `(1..3).each` does. A `for` from or to a game number is
  refused (write a `while` loop), and so is one over a list or a pool (write `.each`).

## Splitting a game into files

A file of game code is loaded with `VBlank.require_game_file "walker"`, never `require_relative`. It
is read as game code as a whole: its locals stay its own, and its constants and methods are shared.
Its methods and blocks are checked as a game block is (no `system`, no constant from outside the
game); its other lines run once as it loads, as the lines above a game block do. A constant read
through an object (`self::BOX`, `kind.class::LIFTED`) is that object's own and is not checked: what
the object is cannot be known from the source. A path that starts from a name (`File::SEPARATOR`,
`::File`) is checked by that name.

## What is refused, and what to write instead

Each is a friendly error naming the line.

| written | write instead |
|---|---|
| `return`, `break` or `next` leaving a game block, or under a game test (`found \|\| next`, `loop do … break if … end`) | put the test in an `if` or `while` around the code |
| a local set outside the game block and changed inside it | move the line that sets it into the block |
| an object (a String, an Array) changed under a game test | keep a number, symbol or `true`/`false`, and pick with it |
| a plain number the build could not follow to a game test (a slot at a key worked out on the line, `counts[i + 1] += 1`) changed under that test | a game variable where it is first set: `var :counts, 0` |
| a new Hash key given a number under a game test | give it a number before the test |
| a misspelt key of a Hash of game variables | one of the keys it has |
| a `true`/`false` name given a number | a comparison: `ok = count > 0` |
| a number name given `nil` later | start it with `n = nil` |
| `x = if …` with no `else`; a pick of something other than a number or `true`/`false` (a symbol picks only into a variable that already holds names) | an `else`; a number to pick with |
| `case` asking about a game test, or `when String` of a number | `if` |
| `case … in` on a game number with a pattern other than values and ranges | values, ranges and `\|`; or `case` with no subject and `when hp > 3` |
| `for` from or to a game number | `i = 0`, `while i < n`, `i += 1` at the end of its body |
| `for` over a list or a pool | `things.each do \|thing\|` |
| a game number put into a String or Symbol (`"HP #{hp}"`) | `draw_text "HP"` and `draw_number hp` beside it |
| `even?`, `odd?`, `nonzero?`, `between?` on a game number | the comparison: `hp % 2 == 0` |
| `.then` on a test | `if` |
| a number worked out and not kept (`hp + 1` alone, `hp.abs` alone) | `hp += 1`; `hp.abs!` |
| a constant from outside the game, or `system`, `eval`, `require`, `send` and the like | work it out above the block into a constant; `allow:` a library that is safe |
| `instance_variable_get`, `instance_variable_set`, `method(:name)` | call the method by its name |
| game code in a file loaded with `require_relative` | `VBlank.require_game_file` |

## What builds without a word and means something else

- `if hp` or `seen += 1 if flags & 4`: always true, since 0 is truthy. Compare: `!= 0`.
- `x = 0` inside `game_loop`, a `func` or a method the game loop calls: set again every pass. State
  that lasts goes above the loop.
- `3.times { … }` in a game block: written out three times, run every pass.
- Changing a method's argument: the caller's variable is left as it was (a warning, not an error).
- `/` on a negative game number truncates toward zero (`-7 / 2` is -3), where the same sum on a plain
  number while building is Ruby's -4. `%` follows Ruby in both (`variables.md`).
- `puts` and any other harmless Ruby in a game block run once, while building.

## When plain Ruby is not enough

`var :name, start` declares a variable directly. A game needs it only to keep a variable narrow:
`width: :byte` or `width: :half`, for a variable that only ever holds a small number
(`var :flag, 0, width: :byte`).

Anything else that seems to need `var`, a lower-level verb or VBlank's own classes is a gap in VBlank.
Report it with the line that did the wrong thing; do not write around it.
