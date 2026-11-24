# DSL reference: Game code is plain Ruby

How a game's code is written. The map of every page is `.claude/rules/dsl-reference.md`.
Worked examples: `test/all/vblank/dsl/test_plain_ruby.rb` (what works) and
`test/all/vblank/dsl/test_plain_ruby_refusals.rb` (what is refused, and what to write instead).

**`PLAIN_RUBY.md` at the repository's root is the published account of this page**, for game
authors, shown on the docs site. Any change to how plain Ruby works in a game, in this page or in
the code, updates `PLAIN_RUBY.md` in the same commit, so the two never disagree.
`test/all/vblank/test_plain_ruby_guide.rb` builds every example in it and checks each refusal's
quoted words.

**Every plain-Ruby form is held to Ruby's own answer** by
`test/all/vblank/dsl/test_plain_ruby_answers.rb` (runner `test/ruby_answers.rb`): each case runs as
plain Ruby and as the game on every lowering, and fails naming the case where the two differ.
**New plain-Ruby work adds a case there for each form it adds, and each wrong answer a review finds
becomes one**: `agrees` (the names must read the same), `refused` (a friendly refusal, with a key
phrase), `stops` (the game stops as it plays) or `known_gap` (wrong today, naming the open work by
its title; it fails once the game agrees, to be turned into `agrees`).

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
  each pass. State that lasts is set up above the game loop. That holds for one set from a working-out
  too: `back = made - 3`, then `back += 1` in a `repeat` below it, moves on every round.
- **A method's own names are set each time the method runs**, as in Ruby: `count = 0` on a method's
  first line, or at the top of a loop's body in it, sets `count` again on every call and every round,
  whether the method is called from a game loop, from an unpacking routine or twice while setting up,
  and whatever number the line works out each time. `count, other = 0, 0` does the same for both
  names, and `target = nil` sets the name to nil, which reads as 0.
- **An instance variable is a game variable where game code changes it, or a class names it** (next
  section).

## Instance variables

A part of a game is a plain class (`Splitting a game into files`), and it keeps what it knows in
instance variables.

- **An instance variable game code may change is the game's, with no line naming it.** The rewrite
  marks, from the source, each instance variable a class's code (or the game block's) changes from
  what it holds, wherever the line is (`@ticks += 1`, `@lit = 1 - @lit`, `@open = !@open`,
  `@counts[at] += 1`, `@counts[at] = @counts[at] * 2`), and each one a line gives a value inside a
  game verb's block (`func(:open) { @open = true }`, `game_loop { @mode = 1 }`)
  (`LocalNames#changing_instance_variables`, `InstanceVariables.mark_changing`, written at the end of
  the class's body as the list mark is). An attribute changed through a writer counts for every
  object with that writer (`dial.level += 3`, `dial.level = dial.level + 3`, or any `lamp.lit = 1`
  in a game verb's block, marks `@level` and `@lit`). A marked one stays plain Ruby while setting up
  (a counter bumped as parts are made, `@size += 1` in a method setting up calls), and becomes a
  game variable at the first line of game code that reads or changes it, starting from the number
  Ruby holds there (`Uses#followed?`). Since the mark is there before any game code runs, a read
  recorded before the line that changes it (a draw routine recorded before the one that switches
  the lamp) is the game's too. Not one holding nil, which has no number to start from, nor one a
  line of game code gave a number outright first (`@named = 0`, then `@named += 1` used in a
  name): Ruby knows that number where it is read, and the rules for plain ones below keep it to
  that. The answers suite (`test/all/vblank/dsl/test_plain_ruby_answers.rb`) holds each case to Ruby.
- **Ruby can still use such a number while building** where it needs a plain whole number
  (`Array.new(ticker.size)`): until something changes the variable, that is the number it holds
  (`Value#to_int`, `#ruby_start_while_unchanged`). A line that changes it after Ruby used it is
  refused, naming both lines.
- **`game_variables :busy, :seed` names them ahead**, which a build needs for a name of the game's
  own or `saved: false` (below), and for one the source cannot show game code changes (`@busy = 1`
  in a method a routine calls, tested elsewhere). Write it in the class's body, under `class`. A
  second line, or the class reopened, names more. In a method (`def self.setup` too) it is
  refused, and in a file loaded with `require_relative` it stops the build naming
  `VBlank.require_game_file`.
- **A part made outside the game's block** (in a constant of a game file) outlives the build that
  made its variables. The next build of the game (for another console, say) starts each from the
  number Ruby gave it (`InstanceVariables.ruby_number_of_stale`). A program built as part of a
  game (a data pack's unpacking, `Builder::Session.building(..., part_of:)`) is no game of its own:
  a variable it made, reached from another part, stays a variable, and the data pack refuses it.
- **Whether a game is being built is one question** (`Builder::Session`, a thread's build): its
  builder, whether game code is recorded now, and whether parts run as plain Ruby on purpose
  (`Session.running_as_plain_ruby`, the comparison suite's Ruby half). A build opens one and always
  closes it, putting back what was current before; a builder made by hand is current until the
  next (`Session.make_current`). A part's Array of numbers or of Structs made while no game is
  being built (above `VBlank.game`, after a build with no hand-made builder before it) is refused,
  saying to make the part inside the game's block.
- **A variable an unpacking program made** (`part_of:`) stays a variable while the game it is
  part of is being built, so another program of that game reading it is refused by the data pack.
  Once that game's build has ended too (`Session#game_ended?` asks the game's session), a later
  separate build takes it for Ruby's number, as it does a part kept outside the game's block
  (`ruby_number_of_stale`).
- **A part's local summed over a walk** (`sum = 0`, then `@points.each { |p| sum += p.x }`, in a
  method game code calls) is the game's where its first line reads what the block walks and finds
  a list, a pool or an Array of Structs (`Rewriter#walked_option_text`): an instance variable, a
  constant, a literal, a local set by then, or the part's own plain reader (read as its instance
  variable, `InstanceVariables.plain_reader?`). Recording alone does not decide: Ruby planning in
  a part's method runs while game code is recorded too. A block the line cannot read ahead (a
  lambda handed with `&`, a helper that yields) changing the local by a game number is refused
  (`Writes.refuse_unfollowed_walk!`), as a game walk there would keep one item's number.
- **A game instance variable is a game variable from its first number on**, as if `var` had made
  it: `@busy = 0` in `initialize` makes it, starting at 0 at power-on. Every read and change after
  that is the game's, wherever it is: in another routine, in a block another part calls later,
  through `attr_reader`, or in a part it was handed to as that part was made (`Ball.new(selection:
  menu.selection)` hands the variable). `if @busy == 1` above the line that changes it asks the
  number the pass before left, and `(@seed << 5) + @seed` reads the game's seed.
- **A part with changing numbers made by code that runs every frame is refused**
  (`InstanceVariables.making_part`, `refuse_part_made_every_pass!`): a `game_loop`, a scene's body, a
  `func`. Ruby makes a new one there on every pass, starting again from `initialize`, where the game
  would keep one. Changing means its class names some (`game_variables`), has some marked
  (`mark_changing`), has a writer game code changes by name (`Uses#changing_part?`), or its
  `initialize` makes an Array that is a list or pool (`Builder#note_made_in_part`). A part whose
  numbers never change is allowed anywhere, and so is anything VBlank's own library makes (a pool's
  things). The fix the message names: make it above the game loop, or keep it with `||=`.
- **`@part ||= Part.new(...)` keeps a part made in game code** (`Rewriter#kept_part_text`,
  `InstanceVariables.keeping_part`, `Builder#keeping_part`): made the first time the line runs, in
  Ruby and in the game, and the same part after, its scene's re-entries included, which is how
  `examples/dive.rb` and `examples/shmup.rb` make their scene's parts so what they show belongs to
  the scene. Every part its `initialize` makes is kept with it. A local of the game's own block,
  given nothing in another block, keeps one the same way (`c = nil` above the loop, `c ||=
  Counter.new` in it; `Rewriter#kept_local?`). A `||=` on a part that is itself made every pass
  (`Uses#made_every_pass?`) keeps nothing, since Ruby's is new on every pass with it: a changing
  part kept so is refused naming the holder (`Builder#keeping_in_part_made_every_pass`). One name
  kept on two lines of game code that make different things is refused, since Ruby keeps whichever
  line runs first (`Uses#refuse_kept_as_another!`). A line of its `initialize` gives the
  start, as `var` does: `@screen ||= FadedScreen.new(...)` in `scene :copyright do`, with `@phase =
  WAITING` in `initialize`, starts the phase at WAITING and does not set it back on every pass. A
  first number given anywhere else in game code, a method `initialize` calls included, is set there
  on every pass, as Ruby would. What `initialize` puts into an Array it makes there, itself or
  through a method it calls (`hatch`), goes in on the part's first pass alone, behind a hidden
  number `rom.profile` names and a save keeping the Array keeps (`Builder#making_part`,
  `#once_for_part`).
  A push into an Array it was handed, a push from a method called on every pass (`update`), what a
  routine, loop or timer `initialize` opens, and its drawing and pictures all run every time.
- Setting-up code that works with a game one works with the game variable, so `@busy.times` while
  setting up is refused as any game number is: keep a number only the build uses out of game code.
- **Each object keeps its own.** A profile and a test read the variable of `@busy` in a `Tilt` as
  `tilt_busy` (the class's name in small letters, `_` before each capital that follows a small
  letter or a digit, then `_` and the instance variable's: `RedFieldCAVELights` gives
  `red_field_cavelights_held`), and a second Tilt's as `tilt_busy_2`. For one no line names, the
  number follows the order the objects were made in, whichever game code reaches first
  (`Uses#made_name`), so a save made before finds each under the name it had.
- `rom.profile` lists each instance variable the game keeps, with its name and whose it is
  (`Diagnostics::InstanceVariableNumbers`).
- **`game_variables busy: :tilt_wait` gives the variable a name of the game's own**, read as
  `tilt_wait` (a second Tilt's as `tilt_wait_2`, and a second one's Hash slot as
  `cave_light_state_0_2`). Names with and without one mix on one line: `game_variables :seed,
  states: :cave_light_state`. A subclass can give its parent's instance variable another name.
  Refused: two instance variables of one class given one name, one given two names in one class,
  a name another variable of the game has already, and a `var` line after the part, naming the
  variable the part made (in either order the two would be one variable).
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
  in game code and while setting up, and never make it share the other's. In game code the same
  holds for any instance variable holding a number or nothing (`@a = @b`, then `@b += 1`): it is
  made the game's there, with a variable of its own. So a rotation through a
  held value (`@held = @states[0]; @states[0] = @states[1]; @states[1] = @held`) and a swap (`@a,
  @b = @b, @a`) work as in Ruby.
- **An instance variable nobody named that takes a slot's variable only holds it**: `@held =
  @states[0]`, then `@held = 5` or `@held += 1` in game code, is refused at that line, naming
  `game_variables :held`, since Ruby's line would leave `@states[0]` as it was and the game's would
  change it. A variable a part is handed whole is that part's to change (`@selection = selection`
  in `initialize`, or one read through another part's `attr_reader`), as is one a method makes for
  the instance variable that first holds it (`@count = make.call(:count, 0)`).
- A subclass has its parent's names and can name more; a module the class includes can name its own.
  `attr_reader`, `attr_writer` and `attr_accessor`, with names written out or from a list
  (`attr_accessor(*LEVELS)`), reach the same variable, so another part can test `tilt.busy` and write
  `tilt.busy = 1` in its game code.
- **The game block's own work the same way**: `@score = 0` above the game loop and `@score += 1` in it
  make the variable `score` (the block marks its own on the builder before its first line,
  `PlainRuby.callable_source`); `game_variables` in the block names them ahead.
- **A named Hash or Array of numbers is a game variable for each key**: `game_variables
  :tilt_counters`, `@tilt_counters = SIDES.to_h { |side| [side, 0] }` in `initialize`, then
  `@tilt_counters[side] += 1` and `if @tilt_counters[side] > 2` in game code, inside `SIDES.each do
  |side|`. A profile reads `tilt_tilt_counters_left` for a `Tilt`: the variable's name, `_`, then
  the key, so `game_variables states: :cave_light_state` with keys 0 to 3 (a Hash's or an Array's)
  reads `cave_light_state_0` to `cave_light_state_3`. That holds where every key is known while
  building: a number, a symbol, a String or a constant written out, or the name a Ruby loop over
  something written out gives (`SIDES.each do |side|`, `3.times do |i|`).
- **A local Hash written out that game code changes at a key is a game variable for each key**:
  `h = { a: 1, b: 2 }`, then `h[:a] += 3` or `m = (h[:a] += 3)` in game code (`LocalNames#game_hash?`,
  `Writes.game_hash`), named `h_a` and `h_b`. A slot holding a place the game named (`{ x:
  var(:x, 1) }`) stays that place. A Hash verb that adds, drops or changes many keys at once
  (`KeyedHash::CHANGING_VERBS`: `store`, `merge!`, `delete` ...) is refused. A Hash of names alone, written out
  and put in as Symbols (`screens = { 0 => :title }`, `screens[2] = :over`), stays Ruby's own Hash
  (`Local#names_only?`): it is a table a verb such as `call` reads while building.
- **A named Array of numbers read at an index the game may work out is a list** (`lists.md`):
  `@counts = [0, 0]` in `initialize`, then `@counts[which] += 1` in game code, with any other index
  than those above, written in the class, in the class reopened or in a class made from it, in any
  file (`VBlank.require_game_file`): the class that reads it marks it, and the Array becomes the
  game's at the first line of game code that reads it, after every file has run.
- **Through a reader, the line decides from the real Array** (`keeper.counts[which] += 1` in another
  part or the game block, `counts[which]` in the class): the rewrite hands the Array the reader call
  answers to `InstanceVariables.indexed` (`LocalNames#reader_index_sites`), and the build's record
  (`Uses#note_array_handed`, by identity, per build) knows which object's instance variable handed
  it out. In game code an index the game works out makes that one Array a list (made at power-on,
  `Builder#recording_at_boot`), a slot written at a known index a variable per slot; the instance
  variable holds it from then on and is followed (`Uses#note_changing_object`). No reader name is
  kept, so another class's reader of the same name, or a game built later in the process, is never
  changed. Refused instead (`Uses#refuse_array_handed_before!`): the Array was read before that
  line, by game code or at all while setting up (a local may keep Ruby's Array); and a named Array
  (a variable per slot from its first number) read through a reader at a worked-out index
  (`KeyedArray#worked_out_key_message`). Both name the fix: a method of its class
  (`def bump(at) = @counts[at] += 1`). A part made by code that runs every frame (the game loop, a
  `func`, or under a game test) and not kept is refused there too (`refuse_part_made_every_pass!`):
  Ruby's Array starts again each pass, the list would not. A part made above `VBlank.game` works for
  one game; a second game using it stops with a raw FrozenError, as on main. A method answering a copy (`@counts.dup`) is left alone, and
  an index the game works out into a copy stops with words saying the game does not keep that
  Array. Part of a named Array (`counts[0..]`, `counts[1, 2]`, `first(2)`, `last(2)`, `take`,
  `drop`) and a copy of one (`dup`, `clone`, `reverse`, `rotate`, `values_at`, `+`) are refused
  (`KeyedArray#part_taken_message`, `#copy_taken_message`), even where only read: either would hold
  the same variables, and a write through an item reaches the variable itself (`Writes.change`).
  The methods in `KeyedArray::ITEMS_ANSWERED` (`map`, `select`, `sort_by`, `entries`, ...) are
  refused only where the answer holds one of the Array's own variables (`map(&:itself)`), and
  `map { |c| c + 1 }` builds. Called with no block they answer an Enumerator, which is refused
  (`KeyedArray#no_block_message`); one answering the Array itself (`each_slice` with its block) is a
  read. `[*counts]` (rewritten through `Rewriter#splat_array_text`) and
  `Array.new(counts)` are refused by `InstanceVariables.refuse_keyed_array_copied!`, since Ruby
  copies an Array there without calling it. `to_a` is not refused: Ruby's answers the Array itself,
  so a change through it changes the Array in Ruby too. One Ruby Array two instance variables hold (handed to two parts) is refused where the
  second is made a list, or hands it out after the first was (`Uses#refuse_array_kept_twice!`):
  each list is its own, where Ruby shares. Such a list holds
  its items and room for no more, holds fractions where a start is a Float, and a profile reads it
  by the name its variables would have had, `counts_by_number_part_counts`. A named Hash at a key
  the game works out is still refused: a Hash has no list to be.
- **A Struct's fields are named the same way**, in the block of `Struct.new` (`Box = Struct.new(:count,
  :step) { game_variables :count }`) or in the body of a class made from one. Then `box.count += 1` in
  game code changes a game variable, `box_count` in a profile. A field game code changes through
  its writer (`point.x += 1`) is the game's too with no name, on a Struct made while setting up or
  kept with `@point ||= Point.new` (`InstanceVariables.followed_field?`). A Struct made by game code
  that runs again keeps its fields Ruby's, since Ruby makes it new on those passes; a field of one
  read or written outside the test or routine that made it is refused
  (`refuse_field_outside_making!`), a `func` the loop making it calls included. Any other field is
  plain Ruby. `point[:x]`, `point[0]`, `point[:x] = 1`, `to_a`, `values`, `values_at`, `dig`,
  `to_h`, `each`, `each_pair`, `select`, and pattern matching (`deconstruct`,
  `deconstruct_keys`) come through the same reader and writer, and so every Enumerable method
  through `each`. `point.x, point.y = point.y, point.x` reads every field before it gives any,
  as Ruby does (`Rewriter#reads_target?`), and marks each attribute it gives as changing.
- **A field keeps a copy of a game number, as in Ruby**: `Point.new(score, 0)` or `point.x =
  score` holds the number `score` had on that line, while setting up or in game code, followed
  or not. A field given a game number that is not a place of its own (a name's or an instance
  variable's variable, a working-out; not a `var` handle or a sprite's `x`) gets a variable of its
  own at its first read through the Struct, set where the field was given the number
  (`InstanceVariables.copy_field_number!`, `Builder#record_at`): a hidden one (`rom.profile` names it)
  for a Ruby field, the field's named one for a followed field. Nothing is kept where nothing
  was recorded between the two, so `sparks << Spark.new(x, y, 1)` costs nothing. Once the whole
  game is recorded, a hidden copy is left out again (`Builder#drop_unneeded_field_copies`,
  `IR::UnneededCopies`) where every read is in the lines after the copy in the same block, before
  any line not proven to leave its number alone (`IR::Unchanging.left_alone_by?`: the lines only
  draw, test, or change other variables), the number reads only variables, and no timer's handler
  or bend, nor a routine either calls, names those variables. A call, a wait, a loop, a list or a
  button between, or a read in another block (a later pass, a routine), keeps the copy. A field changed
  under a test the game makes is given its variable at the test (`Writes.promote_attribute`).
  A `Data.define` class in a game file or block keeps the same copy for each field, beside the
  object, since it cannot change (`copy_data_field_number!`): its readers, `to_h` and
  `deconstruct_keys` hand it, under the same proof.
- **A name given a new Struct or Data object in game code, where game code read the one it held,
  is refused** (`Writes.refuse_object_replaced!`): the build records the line once, so the read
  found the old one, where Ruby's finds the one an earlier pass made. Keep one Struct and change
  its fields. A `Data.define` class in a game file notes its reads for this (`followed_struct`),
  so `point = point.with(x: point.x + 1)` is refused naming a Struct as the fix.
- Two Structs of one class are numbered in the order they were made (`start_fields` counts
  each), as parts are, so a save made before finds each under its name.
- **A game block's instance variable that a `func` or scene sets, read in game code while it holds
  nil with a method nil does not answer called on it** (`@point.x`), is refused naming where to give
  it a first value (`Rewriter#nil_failing_reads`, `InstanceVariables.refuse_nil_set_in_routine!`):
  each `func` and scene is built after the game loop, so the build reads nil where Ruby has the
  value an earlier call set. A test on such a flag is refused by the flag rules instead.
- **Any other instance variable is plain Ruby.** One game code only reads, or one set only by a
  method that is not marked (`@count = count + 1` in `lay_out`, used as `repeat(@count)` or
  `@count.times`), stays Ruby's. So does one that a routine gives a number outright before that
  routine reads it (`@rows = 2`, then `@rows.times`), one only put into a String, a number read while
  it holds nil, and a line of `initialize`, wherever the object is made. One that game code changes
  and also reads back, where the source does not show it (`@busy = 1` in a method a routine calls,
  read by another), is refused at the line that changes it, naming `game_variables :busy`.
- **A plain `true` or `false` (or nil) not marked is refused when it is a game flag**: a test on it
  (`if @open`, `unless @open`, `if !@open`) has game code on a side, and game code changes it and
  leaves it changed. Ruby would decide that test once, while building. The build watches the side
  Ruby runs. A side Ruby skips counts as game code unless the build ran that same side somewhere else
  and it recorded nothing, or it holds nothing but a `return`, `break`, `next` or `raise`. So `seen
  += 1 if @open` with `@open = true` in a method game code calls is refused, naming both lines and
  `game_variables :open` (and `@open = false` where it starts, for one left nil). A test whose answer
  comes from the flag through a reader (`if door.open?`) is watched the same way: the rewrite notes
  each plain flag read while its test runs (`InstanceVariables.flag_read_mark`,
  `Steps::BuildTest#watch_flag_reads`). A test written for its value (`@open ? 1 : 0`, `door.open? ?
  1 : 0`) picks what the game reads, so it counts as deciding the game whatever its sides hold. A
  once-guard asked through a reader (`plan unless planned?`) is still left alone. Marked, a flag is
  the game's (above), tested any way.
  Not the game's: a
  once-guard, whose test guards building work and no game code (`plan unless @planned`, with `plan`
  setting `@planned = true` and declaring routines; `return if @laid_out` above `@laid_out = true`;
  `raise "..." if @written`), and a switch a routine sets and puts back (`@white = true`, `yield`, then
  `@white = false` in an `ensure`), which is the same on every pass.

## Arrays

An Array that game code changes is a list the game keeps (`lists.md`), named after its local. Ruby's
own Array verbs work on it as Ruby says: `<<`, `push`, `append`, `shift`, `pop`, `[]`, `[]=`, `+=` on
an item, `size`, `length`, `empty?`, `first`, `last`, `each`, `each_with_index`, `sum`, `min`, `max`,
`include?`, and `==`, `!=` and `eql?` with a Ruby Array, and `copy_from`, which is VBlank's (`lists.md`) and makes an Array a list as Ruby's
changing verbs do. `sum`, `min`, `max` and `include?` walk the items as the game plays and keep the
answer in a hidden variable; `min` and `max` of an empty list are 0, as Ruby's nil reads.
`trail == [1, 2]` is Ruby's Array#== as a test (`List#items_equal_test`, a hidden variable too):
the length first, then each pair, so no item past the end is read. A named Array of game variables
(`game_variables :counts`) and an Array literal holding a game number compare the same way, with
the sizes decided while building (`Steps.items_equal_test`). Two Arrays the game keeps as lists
compared with each other are refused.

```ruby
trail = Array.new(capacity: 4)   # empty, with room for 4
ripple = Array.new(8, 0.0)       # 8 items, each 0.0: a Float makes them fractions
marks = [3, 1, 4]                # 3 items, and room for no more
game_loop do
  trail.shift if trail.size == 4
  trail << hero_x
  trail.each { |x| draw_rect_at x, 50, 1, 1, :red }
end
```

- **VBlank adds `capacity:` to `Array.new`, and two settings you can leave out.** A console sets a
  list's memory aside before the game starts, so a list cannot grow as a Ruby Array does: an Array
  that game code adds to needs `capacity:`, the most items it can hold. `Array.new(4, 0,
  capacity: 8)` starts with 4 items and has room for 8. Each setting is told in full in
  `lists.md`, with what the Array builds as:
  - `width: :byte` or `width: :half` keeps each item in less memory. A number too big for the slot
    keeps its low bits, with no error: 200 in a `:byte` reads back as -56.
  - `fast: true` or `fast: false` sets which memory the list is kept in, the quick one or the roomy
    one. It changes only how long a read takes; the build picks well without it.
- **Whether it holds fractions is read from what goes in.** The build looks at the start and at every
  value game code puts into the Array (`<<`, `push`, `[]=`, `+=` on an item and the like). A Float
  (`0.5`), a name given one, `.to_f` or a sum with one of those makes it an Array of fractions; a
  whole number written out (`0`, `3`) fits either kind and decides nothing. An Array nothing puts a
  fraction into holds whole numbers. A whole number the game works out put into an Array of
  fractions is refused, naming the line that put the fraction in and the line of the whole number:
  use `.to_f` on the whole number. A fraction from somewhere the build cannot see (a method's answer)
  put into an Array of whole numbers is refused too: write `.to_f` after it.
- **Which Arrays these are:** an Array written out (`[...]` or `Array.new(...)`) and given to a local,
  on every line that gives that local a value, where game code changes it with an Array verb. An
  Array only game code reads, or one changed only while setting up, stays Ruby's and costs nothing:
  `steps = [1, 2]; steps << 3` above the game loop is a Ruby Array of three. A change a Ruby loop
  makes in game code with numbers known while building is setting up too: `xs = []`, then
  `3.times { |n| xs << n * 8 }` in the game loop, is a Ruby Array laid out on every pass. So is an Array
  made only of `var` handles, sprites or anything but numbers (`pair = [var(:a, 1), var(:b, 1)]`),
  whose items are changed where they stand.
- **An item is a copy of the local it came from**, as in Ruby: `a = 1; pair = [a, b]`, then
  `pair[0] += 1` in game code changes `pair[0]` and leaves `a` alone, though game code changes `a`
  too. The list starts from the numbers the locals hold at the line that makes it.
- `item = queue.shift` and `item = queue.pop` hand back the item dropped, as Ruby's do, and so does
  one that is the answer of a branch (`queue.empty? ? 0 : queue.shift`) or a method. That keeps the
  item in a hidden variable, a word of memory (`rom.profile` lists the line); `queue.shift` alone keeps
  nothing.
- **Ruby's questions about items holding game numbers** (`[a, b].max`, `min`, `minmax`, `count`,
  `any?`, `all?`, `none?`, `include?`, on an Array, Range or Hash of Ruby's that holds a game number
  or whose block makes a game test) are worked out as the game plays (PlainRuby::ItemQuestions: a
  compare and pick per item, or a hidden count). Those that pick items by a game test (`find`,
  `select`, `reject`, `partition`, `max_by`...) are refused, and `<=>` on a game number is refused
  where Ruby asks it (`sort`, `max_by`, `clamp`, a gem), except Range.new: a Range of game numbers
  still builds, written as `Range.new` by the rewrite where an end is not a number written out.
  The questions Ruby answers by comparing items with `eql?` and `hash` or `==` (`ItemQuestions::EQUALITY`:
  `uniq`, `tally`, `group_by`, `chunk`, `index`/`find_index`/`rindex` of a value, `-`, `&`, `|`,
  `difference`, `intersection`, `union`, `intersect?`, `delete`) are refused where an item, an
  argument or a key block's answer is or holds a game number (a Struct or Data by its fields, an
  Array or Hash by its contents, `values_compared`): a Value's `eql?` and `hash` are the object's,
  and its `==` a test, so Ruby's answer would be wrong. `-` reaches ItemQuestions on every receiver
  (`a - 3` is Ruby's own sum there); `&` and `|` come from `Steps.bits` for an Array.
  **`a <=> b` written in game code is a game number**, -1, 0 or 1 (`Steps.compare`,
  `Value#sign_against`: `(a > b) - (a < b)`, two compares, no divide), and `[a, b] <=> [c, d]` the
  sign of the pairs' signs weighed 2 and 1, so the first decides and the next breaks ties.
- **An Array the game keeps is an Array to `is_a?`, `kind_of?`, `instance_of?`, `case ... when
  Array`, `Array === trail` and `trail.class`** (`Steps.kind_question`, `Steps.when_test`,
  `Steps.case_equality`, `Steps.class_of`), though the build holds it as a List, Pool or
  StructArray: the rewrite asks those by name in game code.
- **The list's name** is its local's (`trail`, `trail_2` for a second local of that name in one block
  or file), and in a file loaded with `VBlank.require_game_file`, the file's name first
  (`walker_trail` in `walker.rb`). A profile, a save and a test read it by that name. A `list` line
  and an Array that would have one name are refused, naming both lines, whichever runs first.
- A list holds numbers, so `[[0, 0], [0, 0]]`, an Array of Hashes and an item of nil are refused.
- `sort!`, `sort! { |a, b| b <=> a }`, `sort_by! { |n| -n }` and `sort!.reverse!` sort an Array the
  game changes in place (`lists.md`); an Array of Structs takes `sort_by!` by one field or minus it, or an Array of those for ties (`[s.y, -s.x]`),
  which changes its walk order (refused inside a walk of it, or in a routine a walk may call).
  `sort` and `sort_by` are refused. **A Struct that defines `<=>`** (`include Comparable`,
  `def <=>(other) = y <=> other.y`) says its own order: its `<=>` is read once while building on
  two stand-in things into a `SortOrder::Key` (`StructArray#own_order`, from the pairs
  `Value#sign_against` keeps), and `things.sort!` sorts by it at `sort_by!`'s cost. Each pair must
  be one field against the other thing's same field (reversed for the biggest first), alone or in
  an Array for ties; any other `<=>` is refused rather than called per comparison. `min`, `max`
  and `minmax` walk once by the same key (`StructArray#precedes`, field by field), keeping the
  first thing nothing later comes before, started at the first thing; they hand back a kept thing.
  Two things of one Array answer `<`, `>`, `<=`, `>=`, `between?` (game tests by the same key),
  in `Thing`, ahead of Comparable's, whose own would take the sign as a Ruby answer; a thing of
  another Array is refused. `clamp` takes one thing as both ends only (Ruby stops with an error
  where min comes after max, unknown while building). `==` follows Ruby's lookup
  (`StructArray#equality`): Comparable with a `<=>` of its own, level on the order's fields;
  Comparable alone, the same thing only; otherwise every field. `eql?` is always every field.
  A comparing block to `sort!`, `min`, `max` or `minmax` is read by the same rule as `<=>`, and
  a block or `<=>` that records anything (a change) is refused, since it runs once while
  building. `min(2)` is refused. The thing `min` or `max` hands back is, as a test, whether the
  Array held any thing (`Thing#found`, read by `Steps.game_test?`), as Ruby's nil is falsy;
  `min`/`max` in a routine a walk may call is refused, as a sort there is.
- Ruby's other Array methods (`unshift`, `insert`, `concat`, `rotate!`, `map`, `uniq`) are refused by
  name, listing those that work. They put nothing in as far as the fraction rule goes.
- **A named instance variable's Array** (`game_variables :counts`) is a game variable for each index
  where every index is known while building, and a list where the game may work one out
  ("Instance variables" above).
- **An Array of Structs is a pool** (`pools.md`, DSL::StructArray): where game code puts
  `Spark.new(...)` (or `Spark[...]`) into an Array it changes, the Array is a pool named as a list
  would be, its fields the Struct's members, each starting at 0, or 0.0 where a put shows a
  fraction (`Spark.new(x, 0.0, 1.5)`). `<<`/`push`/`append` spawn, `shift` takes out the oldest,
  `clear` all, `delete_if`/`reject!` those the block holds for; `each` (oldest first),
  `reverse_each`, `each_with_index` (the place in the walk); `size`/`length`/`count` (with a block,
  how many it holds for), `empty?`, `any?`. A walk hands an object of the game's own Struct, so its
  methods run, and each field holds the pool's number for that thing: `s.y += s.vy` changes it. It
  answers `face`, `draw_with`, `move`, `can_move?`, `clamp_to_screen`, `overlaps?`, the edges and
  the screen-edge tests, and `index`. The Array answers `blocked_by` and `put_in_layer`, VBlank's
  words, as the pool's handle does (`collision.md`, `layers.md`). `==`/`eql?` compare every field (a test), `equal?` the slot.
  A thing given a name (`pick = s if s.x == 10`) keeps its slot in a hidden variable, so the name
  stays on it after the walk. `Array.new` takes `capacity:` (needed) and `fast:`; one that game code
  never changes stays Ruby's, its `capacity:` dropped. A thing put in may come from a local
  (`s = Spark.new(...)`) or another Array's walk. In the Struct's block (Struct and Data classes
  only), `drawn_as :spark` (or `facing:`/`frames:`/`rate:`, and `layer:` for the layer it stands in)
  draws each as a sprite (refused without `x` and `y`); a `facing:` missing left or down takes the
  opposite's picture mirrored or turned upside down. `narrow :x, y: :byte` sets widths. A field holds
  fractions where a put or a walk's write shows one (`s.vy = 0.5`); a fraction the build cannot see
  is refused advising `.to_f`. The Struct's methods are read as game code wherever its file is (a
  method not made with `def` is refused). A `Spark = Struct.new` in a game block is a local of the
  block, so each build has its own class. A part's instance variable works the same
  (`@enemies = Array.new(capacity: 8)`, `@enemies << Enemy.new(...)` in the same class and file),
  named as its variable would be, `enemies_part_enemies`. Refused: no capacity, a size or a start
  on `Array.new`, a `Data` class, two kinds in one Array, a member left nil, any other Array method.
  `shift` takes the oldest live thing, during a walk too. A push onto a full Array stops the game
  naming it (`on_full: :stop`), in the words a full Array of numbers stops with; the Advance
  cartridge drops it for now, as it drops a push onto a full list.

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
- Numbers have `abs`, `clamp`, `approach` and `abs!`, `clamp!`, `approach!`, as in Ruby: a method
  ending in `!` changes what it is called on, and one without gives a new value; `variables.md` has the arithmetic, division and fractions.

## Tests

- `if`, `elsif`, `else`, `unless`, the trailing forms and the ternary work as in Ruby.
- **Truthiness is Ruby's**: only `nil` and `false` are false. Keep a yes or no as `true`/`false`, and
  compare a number: `if hp > 0`, never `if hp`.
- **A number alone in an `if`, `unless`, `!` or ternary keeps Ruby's answer**, a game number too:
  true, 0 included, decided while building. That is a presence check (`if floor` on an option that
  is nil when left out), and it builds. To test the number's value, compare it: `left != 0`.
- `&&`, `||`, `!`, `and`, `or` and `not` join tests, and the right side is skipped as in Ruby. `&`,
  `|` and `^` between tests evaluate both sides.
- `== != < <= > >=`, and `zero?`, `positive?` and `negative?`, ask about a number. Either side can be
  the game's number: `3 == hp` is the test `hp == 3` is.
- `x = test ? a : b`, `x = if … else … end` and `x = case … else … end` pick a value on every pass, and
  so does the same written into a list's slot (`answers[i] = test ? 1 : 0`) or a field (`box.count = …`).
- `case` on a game number takes `when` with a number, a symbol, a range (`4..` and `..2` too), a comma list, a variable, or
  `true`/`false`. A `case` with no subject asks each `when` in turn. `case … in` takes the same
  values, with `a | b` between them; any other pattern (a binding, an array, a guard) is Ruby's, on
  a plain value only.
- **A `case` that picks a scene**: `case state`, `when 0 then call :title`, `when 1 then call :playing`.
  On a game variable, with every `when` a whole number (or a constant holding one) and every arm one
  `call` of a scene, it is the game's scene dispatch, the one `call mode` makes (`scenes.md`). Any
  other `case` that calls a scene is refused, saying what to write. A `case` whose arms call funcs is
  the chain of tests above.
- `nil` is Ruby's: `target = nil`, then `if target`, `target.nil?`, `target == nil`, `target != nil`,
  `target || 7`. Read as a number, nil is 0.

## Loops

- **A loop on a game number alone is refused** at its line: `x while left`, `x until left`, `while
  left … end`. In Ruby every number is true, 0 too, so a `while` would never stop (the build would
  never end) and an `until` would never run. The words show the comparison: `left != 0`, `left > 0`,
  `left == 0`. C's meaning, "is not 0", is not given to it: that is not Ruby's.

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
- **`break` and `next` in a loop the game runs do what Ruby says** (`PlainRuby::Jumps`): a `while`,
  an `until`, a counting loop over a game number, `for`, and `loop do`. A `loop do` is Ruby's, its
  rounds written out while building, until a jump in it sits under a game test: the rounds before
  that one stay written out, and that round and the rounds after it are a loop in the game
  (`Counts.endless`). A jump is one branch (`IR::LoopJumps`: `break` past the loop's end, `next` to
  where its count steps on), and costs nothing on the rounds it is not taken. A `next` keeps a
  `while i < n` ending `i += 1` from being counted (`LoopForm#counted_while`), as its `i += 1` is
  left out of a round. `found && break` and `found || next` are sides of a test, as
  `break if found` is. In a loop Ruby runs while building they are Ruby's own, unless a game test
  stands between the jump and the loop, which is refused.
- **A loop on plain numbers inside a loop of the game's is written out on every round**: `column = 0`,
  then `while column < 2` with `column += 1`, in the body of `while row < rows`.
- **A loop Ruby runs while building that goes round a million times is refused** at its line, as one
  that never stops (`n -= 1 while n` on a plain number), so a build never hangs with no words.
- **`repeat(n) { |i| … }` is the loop counted as the game plays** (`control-flow.md`).
- **A block verb called on a builder held in a name means what it means bare**: `@build.repeat(n) { … }`
  or `build.every(2) { … }` in a method of a part is `repeat` or `every` in a game block.
- **Ruby's counting loops go round as often as Ruby says** (`PlainRuby::Counts`): `n.times`,
  `a.upto(b)`, `a.downto(b)`, `a.step(b, by)`, `(a...b).each`, `(a..b).step(by)` and `for i in a...b`.
  With a count or an end that is a game number, the loop is one the game runs (`repeat` underneath),
  reading its start and count once as it begins, as Ruby does. With every number known while
  building, Ruby runs the rounds while building and the build chooses by size
  (`PlainRuby::Counts::KnownRounds`): rounds whose IR nodes total at most 64 (`WRITTEN_OUT_MOST`)
  are written out, `3.times { x += 1 }` adding 3 on every pass; larger rounds that differ only in
  whole numbers stepping evenly from round to round are one loop the game runs, those numbers
  worked out from its count with a multiply and an add each round (a running number in memory
  measured dearer on the Advance, whose loop count is in a register); rounds that differ in anything else (a colour or picture picked by
  `i`, a Ruby Array read at `i`, a test on `i`) are written out however large. A loop with a
  `break` or `next` is written out. `rom.profile` lists each such line with its size and choice
  (`Diagnostics::CountedLoops`). A step
  the game works out is refused (write it as a number), and so is any method but `each` and `step` on
  a range that ends at a game number (`(0...n).map`).
- `.each`, `.map` and the rest on something written in the source (a literal, a constant, a range of
  plain numbers) run while building, written out once for each item.
- `.each` on a name is taken as game code, since it may be a pool's.
- `for x in 1..3` runs while building, as `(1..3).each` does; `for i in 0...n` with `n` a game number
  is the game's loop. A `for` over a list or a pool is refused (write `.each`).

## Splitting a game into files

A file of game code is loaded with `VBlank.require_game_file "walker"`, never `require_relative`. It
is read as game code as a whole: its locals stay its own, and its constants and methods are shared.
Its methods and blocks are checked as a game block is (no `system`, no constant from outside the
game); its other lines run once as it loads, as the lines above a game block do. A constant read
through an object (`self::BOX`, `kind.class::LIFTED`) is that object's own and is not checked: what
the object is cannot be known from the source. A path that starts from a name (`File::SEPARATOR`,
`::File`) is checked by that name.

A Struct or Data class can be in a file loaded with plain `require`, which is not read as game
code. Its objects are followed one at a time, when game code first gives one a name: a local, an
instance variable, a method's argument or a block's named parameter, alone or in an Array, a Hash or a field
(`InstanceVariables.follow_objects_in`). Each field then keeps the number it held on that line,
as in Ruby. A Struct object gets the accessors a game file's Struct has, on that object only, and
a Data object is replaced by a copy whose fields hold copies of those numbers. The class does not
change. A frozen object that holds a number the game works out is refused, and so is a Data object needing a copy that a block reads as `it` or `_1` (name the parameter). A class from Ruby, a
gem or VBlank is left alone.

## What is refused, and what to write instead

Each is a friendly error naming the line.

| written | write instead |
|---|---|
| `return`, `break` or `next` leaving a game block (not a loop in it), or `return` under a game test | put the test in an `if` or `while` around the code |
| `break` or `next` under a game test in a loop Ruby runs while building (`3.times { break if hp > 2 }`) | a loop the game runs: `while`, or a count the game keeps |
| `break 5` (a value) in a loop the game runs | set a variable before the `break` |
| `break` or `next` under a game test in a `begin … end while` body | `loop do … break unless i < n end` |
| a `loop do` made the game's whose body reads a plain value that changes each round (`steps.next`) | an Array the game keeps, read at a number the game counts |
| a local set outside the game block and changed inside it | move the line that sets it into the block |
| an object (a String, an Array) changed under a game test | keep a number, symbol or `true`/`false`, and pick with it |
| a plain number the build could not follow to a game test (a slot at a key worked out on the line, `counts[i + 1] += 1`) changed under that test | a game variable where it is first set: `var :counts, 0` |
| a new Hash key given a number under a game test | give it a number before the test |
| a misspelt key of a Hash of game variables | one of the keys it has |
| `counts[0] &&= value` on a number or true in game code, or `||=` on false or a game's true or false (`Writes.refuse_logic_slot_write!`; `||=` on a number is left alone, as Ruby does) | `counts[0] = value`, under an `if` where needed |
| `store`, `merge!`, `delete` or another verb that changes many keys of a Hash of game variables at once | one key at a time, `h[:a] = 5` |
| a copy of a Hash of game variables, `dup`, `merge`, `select`, `slice` and the others answering a new Hash holding its variables (`KeyedHash::HASH_ANSWERED`) | the values one at a time, `left = h[:left]` |
| an Array of a Hash of game variables' values kept in game code, `v = h.values`, `h.to_a` (`KeyedHash::VALUES_HANDED`, checked by `InstanceVariables.refuse_hash_values_handed!`; a call that only reads it at once, `h.values.sum`, is left alone: `Rewriter#note_values_read_at_once`) | read it where it is made, `h.values.sum` |
| an instance variable that game code changes and reads back, where the source does not show the change (`@busy = 1` in a method a routine calls) | `game_variables :busy` in the class's body (or the game block) |
| an instance variable not marked, set outright by a method under a test the game makes (`r.reset if k == 2`), or worked out from a number another routine gave it, then read | `game_variables :n` in the class's body |
| a part whose numbers or Arrays change, made in a `game_loop`, a scene or a `func` (`c = Counter.new` there) | make it above the game loop, or keep it: `@counter ||= Counter.new` |
| `@lives -= 1` in game code while `@lives` holds nil (a routine recorded later gives it its number) | a number where it is first set, `@lives = 0` in `initialize` |
| a line that changes an instance variable's game number after Ruby used that number while building (`Array.new(part.size)`, then `@size += 1` in game code) | keep the number Ruby uses in another instance variable |
| `fdiv` on a game number, `**` or `pow` with a power the game works out or past 32, `floor`, `ceil`, `round` or `truncate` with a number of digits, `succ` or `pred` on a fraction, `divmod` on a fraction, or any other Integer or Float method (`Value#method_missing`) | `to_i` for the whole part of a fraction (it rounds down); a power written in the game |
| an instance variable named by `game_variables` that holds `nil` or an object (a String, a sprite) when game code reads it | start it with a number, `true` or `false`; keep the object in another instance variable |
| an instance variable nobody named that holds a slot's game variable (`@held = @states[0]`), given a number or changed in game code (`@held = 5`, `@held += 1`) | `game_variables :held` in the class's body: then the line copies the number |
| a `var` line naming a variable a part already made for an instance variable (`game_variables held: :x` in a part made first, then `var :x, 0`) | a name of its own for the `var` |
| two instance variables given one variable name (`game_variables a: :x, b: :x`), one given two, or a name another variable has | a name of its own for each |
| `game_variables :busy, saved: :x` (`saved:` given something but `true` or `false`) | `saved: false`, or `game_variables({ saved: :x })` to name `@saved` |
| `game_variables :flash, saved: false` after `@flash` has its first number | the mark above that line |
| `game_variables saved: false` with no names | the names on the same line, `game_variables :busy, saved: false` |
| `game_variables` in a method (`def self.setup` too) | a `game_variables` line in the class's body |
| `game_variables` in a file loaded with `require` or `require_relative` | `VBlank.require_game_file` |
| a named Hash of numbers at a key the game works out | a key known while building, or an Array: `@counts = [0, 0]` or `counts = Array.new(4, 0)` |
| an Array game code pushes to with no `capacity:` (`trail = []`, `Array.new(4, 0)` then `trail << x`) | `Array.new(capacity: 8)`, or `Array.new(4, 0, capacity: 8)` |
| `Array.new(capacity: n)` or `Array.new(n, 0)` with `n` a number the game works out | a number or a constant known while building |
| `Array.new(8)` with no start, on an Array the game changes | `Array.new(8, 0)`, or `Array.new(capacity: 8)` for an empty one |
| an Array the game changes holding Arrays or Hashes (`[[0, 0], [0, 0]]`) | an Array for each row, or an Array of Structs |
| `Array.new` given a word other than `capacity:`, `width:` or `fast:` (`holds:` too: what goes in decides) | one of those |
| an Array method a list has no meaning for (`rotate!`, `map`, `uniq`) on an Array the game changes | the verbs in "Arrays" above |
| a part's Array its class does not change, added to or turned as a whole through a reader in game code (`flock.dots << dot`, `part.counts.rotate!`; `InstanceVariables.refuse_changed_from_outside!`, the rewrite's `whole_array_change?`) | a method of its class, `def add(dot) = @dots << dot` |
| a part's Array nothing was put into before the game began, changed in game code by a method its class body does not hold, such as the class reopened (`InstanceVariables.refuse_unkept_change!`, the rewrite's `own_array_change?`) | the first item put in before the game loop, or the method in the class body that makes the Array |
| a whole number the game works out put into an Array that another line puts a fraction into | `.to_f` on the whole number |
| a `true`/`false` name given a number | a comparison: `ok = count > 0` |
| a number name given `nil` later | start it with `n = nil` |
| `nil`, `true`, `false` or a test's answer put into a list (`answers[i] = pass == 1`) | a number: `answers[i] = pass == 1 ? 1 : 0` |
| a loop on a game number alone (`x while left`, `until left`) | a comparison: `left != 0`, `(flags & 4) != 0` |
| a loop Ruby runs while building that goes round a million times | a test that can fail: `n != 0` |
| `x = if …` with no `else`; a pick of something other than a number or `true`/`false` (a symbol picks only into a variable that already holds names) | an `else`; a number to pick with |
| `case` asking about a game test, or `when String` of a number | `if` |
| `case … in` on a game number with a pattern other than values and ranges | values, ranges and `\|`; or `case` with no subject and `when hp > 3` |
| `step` by a game number (`0.step(10, by)`) | a step written as a number: `0.step(n, 2)` |
| a method but `each` or `step` on a range that ends at a game number (`(0...n).map`) | `(0...n).each do \|i\|`, the work done in the loop |
| `for` over a list or a pool | `things.each do \|thing\|` |
| a game number put into a Symbol (`:"slot#{n}"`) or a heredoc, or words holding one used as a String (`"HP #{hp}".center(9)`) | draw it: `draw_text "HP #{hp}", x, y, :white` (`text.md`) |
| `nonzero?` used as a number (`lives.nonzero? \|\| 1`, `shown = lives.nonzero?`); `finite?`, `infinite?`, `integer?` on a game number | the test in full: `lives != 0 ? lives : 1` |
| `.then` on a test | `if` |
| a number worked out and not kept (`hp + 1` alone, `hp.abs` alone) | `hp += 1`; `hp.abs!` |
| a constant from outside the game, or `system`, `eval`, `require`, `send` and the like | work it out above the block into a constant; `allow:` a library that is safe |
| `instance_variable_get`, `instance_variable_set`, `method(:name)` | call the method by its name |
| game code in a file loaded with `require_relative` | `VBlank.require_game_file` |

## What builds without a word and means something else

- `if hp` or `seen += 1 if flags & 4`: always true, since 0 is truthy. Compare: `!= 0`. (A loop on
  a game number alone is refused instead.)
- `x = 0` inside `game_loop`, a `func` or a method the game loop calls: set again every pass. State
  that lasts goes above the loop.
- Changing a method's argument: the caller's variable is left as it was (a warning, not an error).
- `/` on a negative game number truncates toward zero (`-7 / 2` is -3), where the same sum on a plain
  number while building is Ruby's -4. `%` follows Ruby in both (`variables.md`).
- `puts` and any other harmless Ruby in a game block run once, while building.
- An instance variable that is not named and that game code only changes stays the number Ruby gave
  it: the change happens once, while building. Name it if anything reads it as the game plays.
- An instance variable of a class itself (`@cache` in `def self.table`) is always plain Ruby.
- An instance variable holding `true` or `false` that is not named is a flag of the build's: `if
  @open` is decided while building. Name it if the game sets and tests it as it plays.
- `dup`, `clone` or `first(2)` of an Array of named numbers holds the same variables, so a change
  to the copy changes the Array.
- An Array handed to a part from a local or a Struct field (`src = [0, 0, 0]; t = Holder.new(src)`)
  and read through `src[1]` after `t.xs[at] += 1` answers Ruby's number from while building: the
  part's instance variable holds the list, the local still the Ruby Array. A constant handed in
  works.
- A part's Array of Structs filled from outside its class while setting up stays a Ruby Array of
  Structs whose fields are followed, which answers alike: the same-class scan
  (`LocalNames#instance_variable_things_made`) is the only thing that makes it a pool.
- A field changed through a writer elsewhere (`dial.level += 3`) is followed by the writer's
  name (`changing_attributes_in_files`, process-wide): any object with that writer keeps the field
  as a game number. Cost and save layout, not answers.

## When plain Ruby is not enough

`var :name, start` declares a variable directly. A game needs it only to keep a variable narrow:
`width: :byte` or `width: :half`, for a variable that only ever holds a small number
(`var :flag, 0, width: :byte`).

Anything else that seems to need `var`, a lower-level verb or VBlank's own classes is a gap in VBlank.
Report it with the line that did the wrong thing; do not write around it.
