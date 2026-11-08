# DSL reference: Game code is plain Ruby

The whole story of how a game's code is written. The one-line index is `.claude/rules/dsl-reference.md`.
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
  two routines is two.
- **A name first set inside a game block is set again every time the block runs**, so it starts afresh
  each pass. State that lasts is set up above the game loop.

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
- `== != < <= > >=`, and `zero?`, `positive?` and `negative?`, ask about a number.
- `x = test ? a : b`, `x = if … else … end` and `x = case … else … end` pick a value on every pass.
- `case` on a game number takes `when` with a number, a symbol, a range, a comma list, a variable, or
  `true`/`false`. A `case` with no subject asks each `when` in turn.
- `nil` is Ruby's: `target = nil`, then `if target`, `target.nil?`, `target || 7`. Read as a number, nil
  is 0.

## Loops

- **`while` and `until` on a game test are loops in the game.** The build warns about one that never
  waits for a frame.
- **`repeat(n) { |i| … }` is the loop counted as the game plays** (`control-flow.md`).
- **`.each`, `.times`, `upto`, `step` and `.map` on something written in the source** (a literal, a
  constant, a range) run while building: the body is written out once for each time round. In a game
  block, `3.times { x += 1 }` adds 3 on every pass. That is right for laying out a row of sprites, and
  wrong for a count the game works out.
- `.each` on a name is taken as game code, since it may be a pool's.

## Splitting a game into files

A file of game code is loaded with `VBlank.require_game_file "walker"`, never `require_relative`. It
is read as game code as a whole: its locals stay its own, and its constants and methods are shared.

## What is refused, and what to write instead

Each is a friendly error naming the line.

| written | write instead |
|---|---|
| `return`, `break` or `next` leaving a game block, or under a game test (`found \|\| next`, `loop do … break if … end`) | put the test in an `if` or `while` around the code |
| a local set outside the game block and changed inside it | move the line that sets it into the block |
| an object (a String, an Array) changed under a game test | keep a number, symbol or `true`/`false`, and pick with it |
| a new Hash key given a number under a game test | give it a number before the test |
| a misspelt key of a Hash of game variables | one of the keys it has |
| a `true`/`false` name given a number | a comparison: `ok = count > 0` |
| a number name given `nil` later | start it with `n = nil` |
| `x = if …` with no `else`; a pick of something other than a number or `true`/`false` (a symbol picks only into a variable that already holds names) | an `else`; a number to pick with |
| `case` asking about a game test, or `when String` of a number | `if` |
| `even?`, `odd?`, `nonzero?`, `between?` on a game number | the comparison: `hp % 2 == 0` |
| `.then` on a test | `if` |
| a number worked out and not kept (`hp + 1` alone, `hp.abs` alone) | `hp += 1`; `hp.abs!` |
| a constant from outside the game, or `system`, `eval`, `require`, `send` and the like | work it out above the block into a constant; `allow:` a library that is safe |
| game code in a file loaded with `require_relative` | `VBlank.require_game_file` |

Some refusals give the wrong reason. Write it another way, and report the message:

| written | the build says | write instead |
|---|---|---|
| `case … in` (pattern matching), `for i in 0...n` | "This line is in code that VBlank does not read as a game" | `case … when`; `repeat` or a Ruby iterator |
| `"HP #{hp}"` in `draw_text` | the font has no `#` | `draw_number` beside the text |
| `t == nil` | "can't use nil as a value" | `t.nil?` |

## What builds without a word and means something else

- `if hp` or `seen += 1 if flags & 4`: always true, since 0 is truthy. Compare: `!= 0`.
- `x = 0` inside `game_loop` or a `func`: set again every pass. State that lasts goes above the loop.
- `3.times { … }` in a game block: written out three times, run every pass.
- Changing a method's argument: the caller's variable is left as it was (a warning, not an error).
- `/` on a negative game number truncates toward zero (`-7 / 2` is -3), where the same sum on a plain
  number while building is Ruby's -4. `%` follows Ruby in both (`variables.md`).
- `puts` and any other harmless Ruby in a game block run once, while building.

## When plain Ruby is not enough

`var :name, start` declares a variable directly. A game needs it only where the build's own error
says to write it, or to keep a variable narrow:

- `width: :byte` or `width: :half`, for a variable that only ever holds a small number
  (`var :flag, 0, width: :byte`).
- The errors that end "start it with `n = var :n, 0`": a number changed inside a Ruby block under a
  game test, in a `begin … end while` loop, or by game code above the game loop (a pool's `each`
  doing `count += 1`), and an `@a = @b` in game code where `@a` was only handed its variable.

Anything else that seems to need `var`, a lower-level verb or VBlank's own classes is a gap in VBlank.
Report it with the line that did the wrong thing; do not write around it.
