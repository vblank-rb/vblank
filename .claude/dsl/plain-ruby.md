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
- **An instance variable is a game variable only where it is named** (next section).

## Instance variables

A part of a game is a plain class (`Splitting a game into files`), and it keeps what it knows in
instance variables.

- **`game_variables :busy, :seed` names the instance variables that are the game's.** Write it in the
  class's body, under `class`. A second line, or the class reopened, names more. In a method
  (`def self.setup` too) it is refused, and in a file loaded with `require_relative` it stops the
  build naming `VBlank.require_game_file`.
- **A named instance variable is a game variable from its first number on**, as if `var` had made
  it: `@busy = 0` in `initialize` makes it, starting at 0 at power-on. Every read and change after
  that is the game's, wherever it is: in another routine, in a block another part calls later,
  through `attr_reader`, or in a part it was handed to as that part was made (`Ball.new(selection:
  menu.selection)` hands the variable). `if @busy == 1` above the line that changes it asks the
  number the pass before left, and `(@seed << 5) + @seed` reads the game's seed.
- **A part made inside a scene or a routine starts once.** A line of its `initialize` gives the
  start, as `var` does: `screen = FadedScreen.new(...)` in `scene :copyright do`, with `@phase =
  WAITING` in `initialize`, starts the phase at WAITING and does not set it back on every pass. A
  first number given anywhere else in game code, a method `initialize` calls included, is set there
  on every pass, as Ruby would.
- Setting-up code that works with a named one works with the game variable, so `@busy.times` while
  setting up is refused as any game number is: keep a number only the build uses unnamed.
- **Each object keeps its own.** A profile and a test read the variable of `@busy` in a `Tilt` as
  `tilt_busy` (the class's name in small letters, `_` before each capital that follows a small
  letter or a digit, then `_` and the instance variable's: `RedFieldCAVELights` gives
  `red_field_cavelights_held`), and a second Tilt's as `tilt_busy_2`.
- **`game_variables busy: :tilt_wait` gives the variable a name of the game's own**, read as
  `tilt_wait` (a second Tilt's as `tilt_wait_2`, and a second one's Hash slot as
  `cave_light_state_0_2`). Names with and without one mix on one line: `game_variables :seed,
  states: :cave_light_state`. A subclass can give its parent's instance variable another name.
  Refused: two instance variables of one class given one name, one given two names in one class,
  and a name another variable of the game has already.
- **`game_variables :damage, :bonus, saved: false` marks them working room a save never keeps**:
  `saves_keep_everything` passes them over, as it does a `var` whose name starts with `_`
  (`variables.md`), and a `save_data` record that keeps one is refused. Their names do not change
  (`screen_flash_damage`), and they play exactly as unmarked ones do. The mark covers every name on
  its line, those given a name of their own too (`game_variables :damage, bonus: :flash_bonus,
  saved: false`); a name marked on any line, in the class or a parent, stays marked. The mark counts
  for a variable made after the line runs, so it goes in the class's body (or, in the game block,
  above the first `@flash = 0`), as `game_variables` always does. A mark written after the variable
  has its first number (a second line, or the class reopened) is refused, naming both lines, and so
  is `game_variables saved: false` with no names. It works in the game block too. `saved:` takes only `true` or `false`; to name an instance variable `@saved`, write
  `game_variables({ saved: :its_name })`. Worked example:
  `test/all/vblank/builder/test_saves_keep_everything.rb`.
- **A named value given another game value copies its number**: `@held = @states[0]`, `@best =
  @score`, `@phase = start_phase` and `@level = other.level` set the named value's own variable,
  in game code and while setting up, and never make it share the other's. So a rotation through a
  held value (`@held = @states[0]; @states[0] = @states[1]; @states[1] = @held`) and a swap (`@a,
  @b = @b, @a`) work as in Ruby.
- A subclass has its parent's names and can name more; a module the class includes can name its own.
  `attr_reader`, `attr_writer` and `attr_accessor`, with names written out or from a list
  (`attr_accessor(*LEVELS)`), reach the same variable, so another part can test `tilt.busy` and write
  `tilt.busy = 1` in its game code.
- **The game block names its own the same way**: `game_variables :score` in the block, then `@score =
  0` above the game loop and `@score += 1` in it. Its variable is `score`.
- **A named Hash or Array of numbers is a game variable for each key**: `game_variables
  :tilt_counters`, `@tilt_counters = SIDES.to_h { |side| [side, 0] }` in `initialize`, then
  `@tilt_counters[side] += 1` and `if @tilt_counters[side] > 2` in game code, inside `SIDES.each do
  |side|`. A profile reads `tilt_tilt_counters_left` for a `Tilt`: the variable's name, `_`, then
  the key, so `game_variables states: :cave_light_state` with keys 0 to 3 (a Hash's or an Array's)
  reads `cave_light_state_0` to `cave_light_state_3`. The key must be known while
  building; a key the game works out (`@counts[which]`, `which` a game number) is refused: keep
  those numbers in a game's own list (`lists.md`).
- **A Struct's fields are named the same way**, in the block of `Struct.new` (`Box = Struct.new(:count,
  :step) { game_variables :count }`) or in the body of a class made from one. Then `box.count += 1` in
  game code changes a game variable, `box_count` in a profile. A field nobody names is plain Ruby.
- **Any other instance variable is plain Ruby.** One that game code changes and also reads back is
  refused at the line that changes it, since the game would never see the change: name it. One changed
  only while setting up (a counter that makes names, a count a setting-up method works out and game
  code uses as `repeat(@count)` or `@count.times`) is not refused. Nor is one that a routine gives a
  number outright before that routine reads it (`@rows = 2`, then `@rows.times`), one only put into a
  String, or one read while it holds nil (`return if @laid_out`). Nor is a line of `initialize`,
  wherever the object is made, or one holding `true` or `false`: that is a flag the build keeps for
  itself (`plan unless @planned`, set true by `plan`). A number one routine gives and another reads is
  refused: the game can run them in either order.

## Changing a variable

- `x = 5`, `x += n`, `x -= n`, `x *= 2`, `flags |= 4`, `flags &= ~4` all change it. `x ||= 2` changes
  only `false` or `nil`: a number is truthy, so `x ||= 2` leaves `x = 0` alone, as in Ruby.
- `a, b = b, a` and splats work, on every pass.
- **A name holds a value, as in Ruby.** A name given a game number keeps the number of its line,
  however the code around it calls, branches or hands things on: `old = hp` keeps hp's number,
  `d = hp + 1` its line's answer, `flags = packed[at]` the item it read, `noise = advance` the
  draw it took, and `x = @hero_x` the number @hero_x had then, in a game block, a game file, a
  method and a routine's block alike. Giving one name a new number never changes another: `bend =
  out; bend = 0` leaves `out` alone.
- **What stays the thing itself, as in Ruby: an object the game holds.** A list, a pool, a part, and
  a game variable a verb or a `var` line hands back (`floors = routine_var(:floors)`, `frame =
  frames_since_power_on`) are objects, so a name given one is that object: `floors.increase!(1)`
  counts it up, and `frame` reads the count live. So is a game variable a name set up hands on,
  whole, to the parts it builds (`setting = @sound_setting`, then `Menus.new(sound_setting:
  setting)`), as `Ball.new(selection: menu.selection)` hands the variable itself.
- **What a name's number costs.** Where the game can change the number before the name is read (a
  line that writes it, a call of game code that can, a later pass), the name keeps it in a hidden
  variable of its own, a word of memory. Where nothing can change it, the name costs nothing. The
  build counts a call as changing what its code can write: the instance variables a method writes
  and what it is handed, the names a `func`'s block writes, the object a method of another file is
  called on, what it is handed and what any object was handed as it was made; code the build cannot
  see changes everything. `rom.profile` lists each line that keeps a copy and what it costs, and a
  game that runs out of memory is told the same lines. To need no copy, read the name before the
  line that changes the number, or read the number again after the call that changes it.
- **A method's argument and a value taken from a Hash are copies.** `def hurt(hp) = hp -= 1` does not
  change the caller's `hp`, and `hp = ball[:hp]; hp = 0` leaves `ball[:hp]` alone. Write
  `ball[:hp] = 0`, pass the Hash, or return the number. The build warns about each such line.
- `@x = 2`, `h[:x] = 2` and `sprite.x = 2` follow game tests like any other write (`@x` once it is
  named, see "Instance variables").
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
- `case` on a game number takes `when` with a number, a symbol, a range (`4..` and `..2` too), a comma list, a variable, or
  `true`/`false`. A `case` with no subject asks each `when` in turn. `case … in` takes the same
  values, with `a | b` between them; any other pattern (a binding, an array, a guard) is Ruby's, on
  a plain value only.
- `nil` is Ruby's: `target = nil`, then `if target`, `target.nil?`, `target == nil`, `target != nil`,
  `target || 7`. Read as a number, nil is 0.

## Loops

- **`while` and `until` on a game test are loops in the game.** The build warns about one that never
  waits for a frame and whose test reads nothing the loop changes (a button, or a number nothing in
  it or the routines it calls writes), since only a frame could end it. A loop that changes what its
  test reads (`i += 1` under `while i < n`, a retry that clears its flag) is work inside the pass and
  gets no warning (`test/all/vblank/ir/guardrails/test_ir_guardrail_loop_never_waits.rb`). The whole test is asked again on every round, as Ruby asks it: `while count < 5
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
| an instance variable that game code changes and reads back, not named | `game_variables :busy` in the class's body (or the game block) |
| an instance variable named by `game_variables` that holds `nil` or an object (a String, a sprite) when game code reads it | start it with a number, `true` or `false`; keep the object in another instance variable |
| an instance variable nobody named that holds another part's game variable, given another game variable in game code | `game_variables :held` in the class's body: then the line copies the number |
| two instance variables given one variable name (`game_variables a: :x, b: :x`), one given two, or a name another variable has | a name of its own for each |
| `game_variables :busy, saved: :x` (`saved:` given something but `true` or `false`) | `saved: false`, or `game_variables({ saved: :x })` to name `@saved` |
| `game_variables :flash, saved: false` after `@flash` has its first number | the mark above that line |
| `game_variables saved: false` with no names | the names on the same line, `game_variables :busy, saved: false` |
| `game_variables` in a method (`def self.setup` too) | a `game_variables` line in the class's body |
| `game_variables` in a file loaded with `require` or `require_relative` | `VBlank.require_game_file` |
| a named Hash or Array of numbers at a key the game works out | a key known while building, or a game's own list |
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
- An instance variable that is not named and that game code only changes stays the number Ruby gave
  it: the change happens once, while building. Name it if anything reads it as the game plays.
- An instance variable of a class itself (`@cache` in `def self.table`) is always plain Ruby.
- An instance variable holding `true` or `false` that is not named is a flag of the build's: `if
  @open` is decided while building. Name it if the game sets and tests it as it plays.

## When plain Ruby is not enough

`var :name, start` declares a variable directly. A game needs it only to keep a variable narrow:
`width: :byte` or `width: :half`, for a variable that only ever holds a small number
(`var :flag, 0, width: :byte`).

Anything else that seems to need `var`, a lower-level verb or VBlank's own classes is a gap in VBlank.
Report it with the line that did the wrong thing; do not write around it.
