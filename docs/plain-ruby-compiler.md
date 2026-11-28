# The plain Ruby compiler

This page says what each line of plain Ruby game code means when a game is built by VBlank's
compiler from plain Ruby to the IR, and why each rule is the rule. It is the design the compiler is
built to. Where today's front end (the source rewrite in `lib/vblank/dsl/plain_ruby*.rb`) does
something else, the page says so.

The short version: **setup code runs as Ruby; per-frame code is compiled from its tree, with the
real objects setup made in hand; a place per-frame code writes lives on the console, and anything
else stays Ruby.** No answer comes from how a line is spelled or how its file was loaded.

## Why a compiler

Today a game block runs once at build time with its per-frame lines patched as text: `if`, `&&`
and `x = 1` become calls that look at the value they are handed and record IR when it is a game
number. That works for the spelling it was written for. Every hard question (is this a game
number, is this part kept, is this Array a list the game changes) is answered by patterns in the
source, so each new spelling of one idea is a new bug or a new refusal. PLAIN_RUBY.md lists 94
"Don't" cases, and games carry workarounds such as `field = (@field ||= Thing.new(...))` in every
scene.

A compiler answers those questions from what the program does: which places per-frame code writes,
found on the real objects, and what kind of value reaches each one. The verbs stay as they are;
they are what the compiler emits into. The lowerings learn two new IR kinds, `stop` and `log`
(below), and nothing else.

## Turning it on

```ruby
VBlank.game "PINBALL", consoles: %i[gbc], plain_ruby: :compiled do
  ...
end
```

`plain_ruby: :compiled` builds the game on the compiler. `plain_ruby: :rewritten` is today's front
end and the default while both exist. The setting names what is chosen in words a game author
reads (how plain Ruby is read), not "new" and "old", which stop meaning anything the day the old one
goes. When every game and example builds on the compiler, the default flips, then the rewrite and
the setting are removed together.

Both front ends sit behind one seam: `VBlank.build` asks for the game's block, and gets back a
block that records the game on a builder. `DSL::PlainRuby.game_block` is one adapter and
`RubyCompiler.game_block` is the other; `Cartridge::EvaluatedGame`, the checks and every lowering
see the same kind of block and the same IR either way. That is what lets a test play one case on
both and compare.

## Setup and per-frame code

**Per-frame code** is compiled. It is the blocks of the game verbs (`game_loop`, `scene`, `func`,
`once_a_frame`, `every`, `after`, `repeat`, `each_pass`, a timer's `on_tick`, a menu's `item`, a
data pack's `fill_from_copy`), and every method, block and lambda they reach, however many calls
down, in whatever file it is written and however that file was loaded.

**Setup code** runs as real Ruby, once, while the game is built. It is everything else: the
`VBlank.game` block outside the game verbs' blocks, class and module bodies, every method setup
code calls, every `once { }` block and make-once right side (see "Making parts once"), and the
files and gems the game loads.

A method is per-frame code because of where it is reached from, not because of what its lines
say: `FadedScreen#step` called from `initialize` runs as Ruby, and called from a scene is compiled.
Decision: the split follows the call, because the same method is often both (a part's `restart`
is called while setting up and by a scene), and Ruby gives it one meaning wherever it is called.

Decision: how a file was loaded decides nothing, and game files load with plain `require` and
`require_relative`. A file loads as ordinary Ruby. When per-frame code calls a method, the
compiler takes the real `Method` from the receiver's real class, reads its `source_location`,
parses that file with Prism (once per file) and finds the `def` or block at that line. So what is
compiled is what per-frame code reaches, never what a file was loaded as. A gem's Ruby method
reached from per-frame code is compiled like the game's own, inside the subset.
`VBlank.require_game_file` exists only because the rewrite must rewrite a file's text before Ruby
loads it; it stays for the rewrite and goes with it. Under the rewrite, the way a file was loaded
chose whether its lines were read as game code, which gave a silent wrong answer whenever the
author picked the other one.

The limits are those of reading the source back. A method with no Ruby source (made by `eval` or a
string `class_eval`, or written in C, as a gem's native method is) reached from per-frame code is
refused with the one error, naming the method and where it was defined. A file changed on disk after
it loaded no longer matches the methods Ruby holds, so the lines `source_location` gives point at
other code. The compiler refuses such a file rather than reading it again: `VBlank.game` notes the
time the game was declared, and a file whose modified time is later, or whose line holds no `def`
or block of that method's name, stops the build with "`hud.rb` changed after it was loaded. To fix
this, build again." Reading it again cannot help, since the classes in memory are the old code and
the compiled code would not match what setup ran.

Setup code sees every game number at its start, since nothing plays while the game is built. Setup
is the build machine's Ruby: `Time.now` there is the time the game was built, and `rand` there is a
number picked once, while building. Both are fine for what setup does (a build stamp, a level laid
out once) and neither ever reaches the console.

Setup is real Ruby, so a setup loop that never ends hangs the build, as Ruby would. A watchdog says
so: a thread that wakes when setup has run for about ten seconds reads the main thread's backtrace
and prints where it is, `Still building after 10 s, at game.rb:12 (n -= 1 while n)`, again while it
runs. Where that line is a `while` or `until` whose test is a bare local holding a number, it adds
the teaching line: every number is true in Ruby, 0 too, so compare it. It is a notice, never a
stop, since heavy setup (unpacking a game's data) can rightly take longer; it costs nothing while
setup runs, with no TracePoint.

## Known and played values

The compiler walks per-frame code with an abstract interpreter. Every expression gives one of two
things:

- **known**: a real Ruby object, the same one Ruby would have at that line on every pass. A
  literal, an allowed constant (below), a part setup made, or the answer of a pure call (below) on
  known inputs.
- **played**: a value that lives on the console, given as an IR expression of a kind (below).
  Reading a played place gives one, and so does a verb that answers the console's state
  (`pressed(:a)`, `rand`), a call that is not pure, and any working-out that uses one.

What is known is worked out while building and costs the console nothing: `size = 8 * 2` in a
game loop is 16 in the cartridge. A test on a known value is decided while building, and only the
branch Ruby takes is compiled, so `if console == :gbc` costs nothing and may hold code the other
console cannot build.

A per-frame local (first written in per-frame code) is followed as the walk goes: after `x = 3` it
is known, after `x = hp` it is played. Where two paths meet with different values for it (after an
`if` on a played test, round a loop the game runs) it becomes a console variable that holds
whichever the game took. Its start is fresh on each pass, as Ruby's block locals are.

**The walk changes nothing setup made.** It reads real objects and never writes them, never calls
a method that changes one, and never runs code that is not pure (below). A change per-frame code
makes to a setup object is a write of a place, which makes that place played; it is not made to the
Ruby object while building.

## Constants in per-frame code

"Plain Ruby" means Ruby's syntax and its core, not the standard library. The rule for a constant
in per-frame code goes by what per-frame code needs of it, never by where its file sits on disk,
and it is the same in the game's own methods and in a gem's Ruby methods that per-frame code
reaches:

- A constant whose value the subset holds (a number, a symbol, a frozen String, a frozen Array or
  Hash of those, a Struct or Data class) is allowed.
- A constant naming a class or module is allowed when every method per-frame code reaches through
  it has Ruby source the walk can read, or is a primitive, in `CoreEffects` or a stand-in. So a
  shared gem's `Vec`, written in Ruby, builds in a scene and inside the gem's own `Vec#+` alike.
- A constant naming a class or module whose method per-frame code reaches has no Ruby source and is
  none of those (a C method of the standard library or of a gem) is refused at the line that
  names the constant, unless the game names it with `allow:`, which vouches that its methods are
  pure: they are then run for real with known inputs, and refused with played ones.

A value of such a class that setup made and per-frame code calls a method on is refused the same
way. There is no list of what is refused: one rule catches every constant, and a constant nobody
thought of is refused with a reason rather than called for real with a wrong answer.

The message is today's (`BlockChecks.refuse_outside_constant!`), kept as the constant form of the
one compiler error, with its `allow:` way out:

```
`JSON` is not part of your game, so this block cannot use it. This block describes what the game
does as it plays. If you need `JSON` while building, use it above the block and keep the result in
a constant. If this library is safe here, add it with `allow:`. (at game.rb:42)
```

A handful of constants get a message of their own, because a plain hint helps:

| Constant | Its message says |
|---|---|
| `Time`, `Date`, `DateTime`, on a lowering with no clock that gives a date | the console has no clock with a date, and names `clock` (`.claude/dsl/clock.md`) where the console has one |
| `Random` with no seed | per-frame code cannot seed from the machine; give a seed, or use `rand`, `roll` or `chance` |
| `File`, `Dir`, `IO` | the console has no files; read it above the block, or in a `once` block |
| `Thread`, `Ractor`, `Fiber` | a game runs one thing at a time; use `every`, `after` or `each_pass` for work spread over frames |

### Stand-ins

A few standard classes are stood in by VBlank's own where their meaning holds on a console. A
stand-in is reached only from per-frame code; in setup the class is Ruby's own.

| Stand-in | What it answers | What it refuses |
|---|---|---|
| `Random` | `Random.new(seed)` is a generator of the game's own random numbers (the `rand`, `roll` and `chance` verbs, `.claude/dsl/randomness.md`), its state a played place seeded from `seed`; it answers `rand`, `rand(n)`, `rand(range)`, `rand(float)` and `seed`, and is what `Array#sample` and `shuffle` take as `random:` | `Random.new` with no seed in per-frame code (Ruby seeds it from the machine), `bytes`, `Random::DEFAULT`, `Random.urandom` |
| `Time` | `Time.now` reads the console's clock (the `clock` verb, `.claude/dsl/clock.md`); `Time.new(year, month, day, hour, min, sec)` makes a time; a time answers `year`, `month`, `day`, `hour`, `min`, `sec`, `wday`, `yday`, `to_i`, `+` and `-` with whole seconds, `-` of two times, and the comparisons | `zone`, `utc_offset`, `utc`, `localtime`, `usec`, `nsec`, `strftime`, `to_f`, `round` and every method not in the list |
| `Date`, `DateTime` | `Date.today`, `Date.new(year, month, day)`, and a date's `year`, `month`, `day`, `wday`, `yday`, `+` and `-` with whole days, `-` of two dates, `leap?`, the comparisons; `DateTime` as `Time` | `strftime`, `parse`, calendar reforms, and every method not in the list |

The clock's stand-ins build only on a lowering whose `clock` gives a date: the Advance's
cartridge, and the C, JavaScript and Ruby builds. On the Color, the Super Nintendo, the Genesis and
the PlayStation the build refuses them in plain words, naming `clock` where the console has one. On
a cartridge whose clock is not there or was never set as the game plays, `Time.now` stops the game
in plain words saying so, since Ruby's `Time.now` always has an answer and a time of zeros is not
it; a game that may run with no clock asks `clock.present?` first.

The numbers a stood-in `Random` draws are the game's own sequence, not Ruby's Mersenne Twister, so
a seed gives the same numbers on every lowering but not the ones Ruby gives. What Ruby promises
of them holds: their range, their kind, and the same sequence for the same seed. A RubyAnswers case
that draws compares those, never the numbers.

The rule for adding a stand-in: only where it gives Ruby's answer for every method it accepts, and
refuses every other method by name. A method whose answer the console cannot give (a time zone, a
nanosecond from a clock that counts seconds) is refused, never answered with something near.

## Calls

A call in per-frame code goes one of five ways, chosen by the receiver's real class and the method
it reaches, never by the file it is in:

1. **A method with Ruby source** (a `def`, a `define_method` block, a lambda, a block): walked.
   Its body is per-frame code with `self` the real receiver. The tree comes from the method's
   `source_location` parsed by Prism, cached per file. `attr_reader`, `attr_writer`,
   `attr_accessor`, Struct and Data members, `Forwardable`'s `def_delegator(s)`, `Comparable`'s
   operators and `Struct#==` have no Ruby source and are primitives the compiler knows. A method made
   by `eval` of a string, or by `class_eval` with a string, has no source to read and is refused in
   per-frame code with the one error; `define_method` with a block, in setup, is fine.
2. **A verb or a handle's method** (Builder, `DSL::Value`, a sprite, a list): called for real while
   building, handed played values as the IR handles the verbs already take. This is how IR is made.
3. **A pure core method on known inputs**: called for real while building, and its answer is
   known. `RubyCompiler::CoreEffects` is the table that says which core methods are pure (`+`,
   `Integer#abs`, `Array#size`, `Array#map` with a pure block, `Hash#fetch`, `String#upcase`,
   `Comparable#clamp`, `Math.sqrt` ...). A block handed to one must be pure too, which the walk
   checks.
4. **Any other core method**: compiled, from the prelude (below). This covers a pure method with a
   played input, a method that changes its receiver (`push`, `<<`, `[]=`, `sort!`, `clear`,
   `delete`, `String#<<`, `upcase!`), which is a write of the receiver's place whatever its
   arguments, and a method that draws a random number (`Array#sample`, `shuffle`, `Kernel#rand`, a stood-in
   `Random#rand`), which draws from the game's own random numbers, as `rand` does,
   on every pass.
5. **A method with no Ruby source outside the core** (a gem's C extension): refused with the one
   error, which says to do that work in setup or in a `once` block.

`CoreEffects` takes the place of today's `CallChanges` and `ItemQuestions`: one table, keyed by
class and method, of pure, changes-its-receiver, or draws-a-random-number.

**Tests and loops** mean what Ruby says, with Ruby's truth (only nil and false are false). A test
on a known value compiles one branch; on a played value both, as the game's branch. `while`,
`until`, `loop`, `times`, `upto`, `step`, `each`, `for` over played bounds or a played collection
are loops the game runs; over known ones the build chooses to unroll or count, and the profile says
which (`rom.profile`). `break`, `break value`, `next`, `redo`, `return` from a method or a routine,
and `next` and `break` in `game_loop` mean Ruby's jumps. `begin`, `rescue`, `ensure` and `retry`
are compiled for the errors the game raises and for the errors Ruby raises as the game plays (below).

**Errors.** Ruby raises an error as a line runs, and so does the game. A `raise`, and an error
Ruby itself would raise (a method on nil, `sort!` on Structs with no `<=>`, a write to a frozen
Struct, a `Rational` from a negative power), is compiled as a **stop**: on the pass the line runs,
the game stops with the error's message and line, on every lowering. The build stops instead only
when the error is on every path from power-on (it is in setup, or it runs on the first pass under
no test the game makes), since then no play of the game avoids it. An error on a path that may run
is a build warning naming the line, so it is not first met on a console.

`stop` is a new IR kind: a message number, which the build keeps the text for, the way a `log`
line's is kept. Each lowering ends the game there and makes the message readable (the
interpreter raises `IR::ProgramError` with it; the C, JavaScript and Ruby builds print it; each
console halts with the number where its reader finds it). It is added by the epic's third task, on
every lowering, and goes in the conformance fixture. The existing `stop_full` (a full list) becomes
one use of it.

**Pattern matching**, multiple assignment, splats, keyword arguments, `defined?`, `__method__`,
`instance_variable_get` and `send` with a known name mean what Ruby says. Reflection with a played
name is refused.

## Which places are played

**A place is played when per-frame code writes it.** The places are:

- a setup local per-frame code can see: a local of the `VBlank.game` block or of a scope outside it;
- a local a lambda or block made in setup captured, keyed by the real binding it closed over, so
  two calls of `def counter = (n = 0; -> { n += 1 })` give two places;
- an instance variable of a real object, a class's instance variable, and a class variable
  (`@@count`), keyed by the class that holds it;
- a field of a real Struct, an item of a real Array, a value of a real Hash at a key, and the
  characters of a real String (`label << "!"`, `upcase!`);
- a global variable the game defines (`$level`): one fixed place. Ruby's own globals (`$stdout`,
  `$0`, `$~`, `$;`) are refused.

Anything else setup made stays Ruby, and per-frame code reads it as known.

Places are keyed by the real object, never by a name in the source: `@frames` of one
`FadedScreen` is a different place from `@frames` of another, and a writer `dial.level += 3`
makes `level` played on that dial alone. The compiler finds the played places by walking the
per-frame code from every game block, writing nothing, and noting every place written; then it
walks again with those places played, since a test that was known may now be played and reach more
code. It stops when a round finds no new place. The set only grows and the places are finite, so it
always stops.

A place also has a **path**: how setup reaches it from the game block's locals, such as
`copyright.@screen.@frames`. The path names the place's game variable (`player[:name]` in a test,
the profile, a save's layout) as today's names do, and it stays the same when the build runs again,
which "Making parts once" needs.

A throwaway prototype of the walk, run on Pokemon Pinball's copyright screen copied out of the
game, with a stub builder, found exactly the instance variables the game names with
`game_variables`, plus the two `var` handles, in two rounds, with no `game_variables` line read. It
also left out one the game names, `@first_frame`, because for the copyright screen's object the
branch that writes it is decided known and never taken. That is the gain of keying by object: a
place is played on the parts whose code writes it.

A played place starts at power-on from the value it holds when the build reaches the game: its
setup value. Two builds of one game (one per console) start from the same objects, since the build
never changes them.

A place setup gives a `var` handle (`showing = var :showing, 0`, `@phase = builder.var(...)`) is
that variable: per-frame writes go into it, and it keeps the name, width and save setting the
`var` line gave. Ruby's `var` answers its start, so a place holding a number that per-frame code
changes is what Ruby sees too.

### What the rewrite guessed, and the rule that replaces it

| Today (rewrite) | What it guesses from the text | The compiler's rule |
|---|---|---|
| `Builder::Session` (`recording?`) | Whether a line runs as game code is a flag set while a game verb's block runs | Per-frame code is what game blocks reach by calls; the walk knows, and no flag exists while real Ruby runs |
| `LocalNames` (`game_array?`, `GAME_VERBS`, `RUBY_ITERATORS`) | Which local names are game state, from the verbs written near them; whether an `.each` is Ruby's or the game's from the receiver's spelling | A local is played when per-frame code writes it, keyed by its binding; a walk over a known collection is unrolled and one over a played one is a loop, by the value |
| `InstanceVariables` (`mark_changing`, `game_variables`), `library_file?` | Which instance variables are game state, from spellings such as `@x = 1 - @x`, the author's marks, or the file's way of loading | Played when per-frame code writes it, on that object, whatever the file; `game_variables` is read only for a chosen name and `saved: false` |
| `Writes.write` | Whether a write replaces a value or goes into the variable a name holds, from the place's spelling | Ruby's write, always: a played place takes the value; a known place written under a played test is played, since per-frame code writes it |
| `Steps` (`game_test?`, `equal_test`) | At run of the rewritten code, whether a value is the game's, and fixes for Ruby asking the wrong side (`3 == hp`) | Known or played is decided by the walk before any IR is made; an operator on a played value is compiled whichever side it is on |
| `Promotion` | When a plain value must become a game variable, from tests open around a line | A per-frame local becomes a console variable where paths with different values meet; a setup place by the written rule |
| `CallChanges`, `ItemQuestions`, `KnownRounds` | Which calls change their receiver, which loops are counted while building | `CoreEffects`, and known or played bounds |

## Making parts once

A scene's body runs every frame, so a line there that makes a part makes a new one each pass, as
in Ruby. Ruby's way to keep one is `||=` on a place that outlives the pass, and games today write
`field = (@field ||= Field.new(...))` to keep it and still have a short local name.

The compiler gives the scene a place to make parts once, and keeps `||=` as its short form:

```ruby
scene :red_field do
  art   = once { ScreenUnpacking.art(pack, :red_field_bottom) }
  field = once { RedFieldBottom.sprites(self, art, scroll, saver.x) }
  screen = once { FadedScreen.new(self, :red_field, art, white_frames: RED_FIELD_WHITE_FRAMES) }
  screen.step
end
```

`once { ... }` is a verb: its block is setup code, run as real Ruby the first time the build reaches
that line, inside the scene, so what the block declares (a screen, sprites, routines) belongs to
the scene as it does today. Every pass after gets the same object back. A `once` is keyed by its
line and by `self`: in a method that two parts run, each part has its own. In plain Ruby, `once` is
`@once[site] ||= yield` on `self`, so it means what Ruby means, nil kept as well.

Decision: a verb, not a new kind of block, because the parts must be locals of the scene body
(Ruby blocks do not leak locals out, so a `setup do ... end` inside a scene would force instance
variables again) and because a verb is plain Ruby to read: it is a call with a block.

`@x ||= rhs` in per-frame code is the same thing when `@x` is nil or false as the build reaches it
and nothing else in per-frame code writes `@x`: the right side runs once, as setup code.

### A played value read inside a `once`

Ruby runs a `once` block on the pass it is first reached, and setup runs it while building. The
two give the same answer unless the block reads a played value, at any depth. So the block is run
with a **probe** in every place the build knows is played: an object that stands for "a value the
game has not worked out yet", and that signals the build the moment anything asks it a question.
A probe answers nothing. Asked anything (`probe > 3`, `probe.to_i`, a method on it), it raises a
signal of the build's own, an `Exception` outside `StandardError`, so no `rescue` in the game
catches it. An error raised by a C method that was handed a probe (`Integer#+` given one raises
`TypeError`) counts as a read too. So does a probe left inside what the block made.

If the block read a played value, that `once` is **made as the game plays**, and the build runs
again from the start with that `once`, by its key, marked so. Starting again is what undoes the
half-run block: the sprites, screens and routines it declared before the signal, and anything it
changed on setup's objects, are gone with the build they were made in, so no verb needs a way to
take a declaration back. In the build that follows, the block is not run while building. The first
pass that reaches the line runs the block as written as per-frame code, whatever it holds, and a
flag remembers it ran. Its verbs keep their meaning there as anywhere in per-frame code: a declaring
verb (`sprite`, `screen`) declares while building, and a verb the game may not call in per-frame
code is refused, naming the verb. The build warns, naming the line and the value read.

Places are found as the walk goes, so a `once` may run before a place it reads is known to be
played. When the walk ends with played places that a `once` run earlier had no probe for, the
build runs again from the start, with the played places carried in by their paths, until no new
place appears. Setup is plain Ruby and runs the same way each time. Today's rewrite already builds a
game again when game code read an instance variable before changing it, so this is no new cost in
kind. The start of a played value is never read silently.

### Parts made as the game plays: making sites

Every `new` of a class with instance variables or fields, and every `dup`, `clone` and `Data#with`,
reached in per-frame code is a **making site**, whatever its arguments, except inside `once` and a
make-once `||=`. Ruby makes a new object each time the line runs, and so does the game.

Each site has a **room**: a fixed number of objects of its class, set aside before the game
starts. A reference to one is its slot in the room. An object no place outlives the pass with (a
`Vec` made by `pos + vel + wind` and dropped once the sum is kept) gives its slot back when the
pass ends. An object kept in a place that outlives the pass keeps its slot until no place holds it,
which the game counts for that site's objects only. The room is the most the build can see live at
once: the objects one pass makes where every loop is known; otherwise the site's setting,
`VBlank.game ..., rooms: { Vec => 16 }`, or a default of 8. A site with no room the build could see
warns, naming the room and what it costs in memory. Making an object in a full room stops the game
in plain words, naming the class and the room, as a full Array does.

An object whose fields only `initialize` sets, and that nothing asks `equal?` or `object_id` of (a
frozen Struct, a Data, most value classes such as `Vec`), is kept by value instead: its fields
travel with it, and it needs no room and no counting.

So `spots << Spot.new(1, 2)` eight times holds eight Spots, `@point = Point.new(1, 1)` sets a new
point, and `pos = pos + vel + wind` builds, as Ruby says.

### Several known objects in one place

A played place that holds one of several objects (a Struct made under an `if`, two parts kept in
one name, `pick = big ? sprite_a : sprite_b`) is a **choice**: a small number saying which. A call
on it is a `case` over the objects, each arm compiled with that object known. nil is one of the
choices, so `@point` read before the routine that sets it gives Ruby's `NoMethodError` as a stop,
on the pass it happens. A choice among the things of one Array (`@target = enemies[i]`) is an index
into that Array, one arm whatever the count, since the things share a class.

## The kinds of value

| Kind | On the console | Notes |
|---|---|---|
| Integer | 32-bit signed (`IR::Int32`) | Past 2**31 it wraps, on every lowering alike; Ruby makes a Bignum. The interpreter can be told to stop on a wrap, for a test that wants to know |
| Float | a fraction, fixed point | Precision is the fraction's, not a double's: the one other named difference from Ruby |
| true, false | a flag | |
| nil | a flag or a choice member | |
| Symbol | a state: a number per name | Compared with `==`, called with `call`; `:"level#{n}"` is a state worked out from a number, matched against the routines declared |
| Mixed (a place given values of two kinds) | a **tagged value**: a number and a byte saying its kind | `alive = hp` after `alive = true`; `[0, 1.5]`; `Array.new(8)` of nils. Every operation checks the tag, as Ruby does. Kept in a place, it warns as a cost; a tagged answer used at once (`lives.nonzero? \|\| 1`) is a test and costs nothing more |
| Part, Struct, Data | a setup object, or a making site's object; its played fields are console variables | Methods walked; `<=>` and `Comparable` compiled |
| Choice | a number over known objects, or an index into one Array | See above |
| Array of numbers | a list with room | Room below |
| Array of Arrays | a list of lists | Rows of one known size are one block of memory |
| Array of Structs, or of parts | a pool | As today, with Ruby's order of a walk while it changes; an Array of a game class's objects is a pool of their played fields |
| Hash | keyed slots, with room for keys added | Known keys are slots; a played key is looked up |
| String | known text, or played text with a room | Drawn, compared, padded, formatted, logged; see below |
| Range | known, or two played ends | |
| Proc, lambda, Method | known; its body walked where it is called | |
| Enumerator | a known collection and a played position | `steps.next` in a loop the game runs |
| table | as today | |

**Room.** A console sets memory aside before the game starts, so every played collection has a
room. It is, in order: the `capacity:` the game gave; the most items the build can see the
collection hold (its start, and what known loops add); otherwise the `rooms:` setting for that line,
or a default of 16 with a warning naming it. A copy (`sort`, `map`, `select`, `dup`, `first(2)`,
`uniq`, `+`) has a scratch room the size of its source's. Growing past a room stops the game in
plain words. The build has no range analysis, so `Array.new(n, 0)` and `(0...n).map` with a played
`n` take the setting or the default.

**`capacity:`, `width:` and `fast:` in setup.** Setup is real Ruby, and Ruby's `Array.new` refuses
these keywords. While a game builds on the compiler, `Array.new` takes them: VBlank prepends a
method to `Array.new` that, on a thread that is building, takes the three keywords off, makes Ruby's
Array, and keeps the settings in a table keyed by that Array. A call without them is Ruby's own, so
a gem sees no change; a call with them would have raised in Ruby, so nothing that worked changes.

**Played text** is known pieces, played numbers and played characters, with a room (the most
characters the build can see: a 32-bit number is at most 11; otherwise the setting or a default). It
answers `size`, `+`, `<<`, `*` by a known count, `==`, `center`, `ljust`, `rjust`, `upcase`,
`downcase`, `to_s`, `to_i`, `format` and `String#%` with `%d`, `%s`, `%x` and their widths and
padding, and drawing and logging. A String method with no meaning on the console's text
(`encode`, `unpack1`, a Regexp) on played text is refused.

## The prelude: Ruby's core, written in Ruby

Ruby's core methods on played values are written once, as plain Ruby, in
`lib/vblank/ruby_compiler/prelude/` (`Integer#gcd`, `Array#rotate!`, `Enumerable#tally`,
`String#center`), and compiled like game code wherever a game calls them. A few that need the
console's own instructions (`+`, `<<`, `divmod`, a list's `<<`) are primitives the compiler emits
directly. Decision: Ruby, not a table of IR emitters, because "most Ruby works" then grows by
writing Ruby that `test/ruby_answers.rb` checks against Ruby itself, and every lowering gets each
method for nothing. A core method neither in the prelude nor a primitive is refused by name until
someone writes it, which is a line of Ruby, not a change to the compiler.

## Costs

Correct and slow comes before refused. A construct that is costly on a small console builds as
Ruby says, with one build warning per line and a line in `rom.profile`:

```
Warning: game.rb:42 sorts `marks` into a new Array on every pass.
This copies every item each frame: 24 items now, up to 64.
A faster way: sort it in place, with `marks.sort!`.
```

Each warning says the line and the construct, what it costs in the units the profile counts, and a
cheaper way. `warnings: :quiet` on a line's verb or the game turns a named warning off; the profile
line stays. What warns:

- A copy of a played collection, and a tagged value or a choice of more than a few objects kept in
  a place.
- A collection, text or making site whose room the build could not see, and Arrays inside Arrays.
- A played key looked up in a Hash, and a dispatch over routine names worked out from a number.
- A line that works out a number and drops it (`hp + 1` alone).
- A `once` made as the game plays, and an error on a path that may run.

What PLAIN_RUBY.md lists under "What costs more" today (a running total kept by hand, a sort on
every pass, a copy far from its read) is advice about how often a line runs, which the build cannot
judge; on the compiler those are profile lines, not warnings.

**Division.** `/` and `%` are Ruby's, rounding down, on negative numbers too. By a power of two
that is a shift and a mask, cheaper than rounding toward zero; by anything else it is the console's
divide and a two-instruction correction. `remainder` is Ruby's own truncating remainder, and costs
nothing extra. `VBlank.game ..., division: :toward_zero` makes every `/` and `%` round toward zero,
as C does and as today's rewrite does: faster on a divisor the compiler cannot see, and not Ruby,
so the setting says so in its name. Where the compiler can see both sides are never negative, the
correction is left out.

## The one compiler error

What a console cannot do stops the build with one message shape, written with the simple-english
skill:

```
game.rb:42: `eval` cannot run on the console.
The game runs on the console, and the console has no Ruby to read text as code.
To fix this, do this work above the game block, or write the code out.
```

Line one: the file and line, the construct in backticks, and "cannot run on the console". Line
two: why, in one sentence about the console. Line three: what to do, starting "To fix this", naming
a verb where VBlank has one for the job. The same shape covers every refusal but a constant outside the subset, which keeps today's words (above): a
value of a class outside the subset, `eval` and its relatives, `system`, backticks, `exec`, `fork`,
`spawn`, `require` and `load` in per-frame code, a method with no Ruby source outside the core,
a method made by a string `eval`, `method_missing` and `respond_to_missing?` reached with a played
name, `define_method`, `class_eval`, `Struct.new`, `Class.new`, `alias` and `undef` in per-frame
code (making a class while the game plays), `BEGIN` and `END`, Ruby's own globals, reflection with
a played name, flip-flops, and a core method the prelude does not have yet. The class is
`RubyCompiler::Refused`, a `BuildError`.

## The debug log

`puts hp`, `p hp` and `print "x=#{x}"` in per-frame code write a line to the game's debug log,
with the frame it was written on. In setup code they print while building, as Ruby does.

Each line is kept on the console as a number for its line of source and the played numbers in it,
never as text: the text is made on the computer reading the log, by Ruby's own `to_s` and
`inspect`, so it matches Ruby's output exactly and costs the console a few words a line.

| Where it plays | Where the log goes |
|---|---|
| Interpreter | `interpreter.log`, a list of lines with their frames; a test reads it |
| C, JavaScript and Ruby builds | standard error, and the same list for a test; the browser's console on a web page |
| Each console, in its emulator | a ring in the cartridge's memory, read back each frame by the console's reader (the same seam `Verifier` uses); on the Advance, also mGBA's debug port when it is there |
| `vblank run` | below the window, as it plays |

A full ring drops the oldest line and counts what it dropped. `VBlank.game ..., debug_log: false`
leaves every `puts` out of the cartridge, for a shipped build, and the build says how many it left
out. The log is a new IR kind (`log`), added by the epic's fifth task; it goes in the conformance
fixture and every lowering learns it.

## Every Prism node is decided

The compiler keeps a table with one row for each node class of the Prism that VBlank loads
(`Prism::Node`'s subclasses, read at load; Prism 1.9.0's `config.yml` lists 151 and Ruby 4.0's
loaded Prism has 152). Each row has two marks, one for per-frame code and one for setup: compiled,
runs as Ruby, or refused with the one error. A test fails on a node class with no row, so a new
Prism with a new kind fails until somebody decides. Decision: the loaded classes, not a path into
the gem's install, since they are what parses the game.

Setup runs as Ruby, so in setup every row is "runs as Ruby". In per-frame code the refused rows
are: `XStringNode`, `InterpolatedXStringNode`, `PreExecutionNode`, `PostExecutionNode`,
`FlipFlopNode`, `MatchLastLineNode`, `InterpolatedMatchLastLineNode`, `UndefNode`,
`AliasGlobalVariableNode`, `AliasMethodNode`, `ClassNode`, `ModuleNode`, `SingletonClassNode` and
`DefNode` (a class or a method made while the game plays). `ImaginaryNode` and `RationalNode` are
refused there too, since the console has no complex or rational numbers. `BackReferenceReadNode` and
`NumberedReferenceReadNode` go with Regexp, refused on played text and known on known text.

## Where it sits

`lib/vblank/ruby_compiler/`, module `VBlank::RubyCompiler`, with its front door
`ruby_compiler.rb`. It is a module of its own, not more files in `dsl/`, because what it is (a
compiler from Ruby to the IR) is not a thing a game names, and the old files there go when it is
done. Its interface is one method, `RubyCompiler.game_block(block, settings)`, the same shape as
`DSL::PlainRuby.game_block`; everything else is inside: the walk (`Walk`), the fixed point over
written places (`Places`), the kinds (`Kinds`), the constant rule (`Constants`), the effects table
(`CoreEffects`), making sites and rooms (`Sites`), the node table (`NodeTable`), the prelude, the
refusal and the cost warnings. It emits through the builder's own verbs and containers, and adds
the `stop` and `log` kinds to the IR.

## How fast it builds

Measured on this design's branch (the numbers are on the bead): on the largest examples, the
rewrite with its Prism parse is a small part of a build, the game's reading (setup run and
recording) a few times more, the IR checks about half the reading, and the console's lowering most
of the build. Prism's parse is already in C and is a small part of the rewrite. On a scratch copy
of Pokemon Pinball (which builds only part way on this commit) Prism parsed all of the game's files
in a sliver of the time spent loading and rewriting them, and the first build on a cold machine
spent far longer compiling the game's own unpacking as C than in any Ruby phase.

So Prism is not where a build spends its time, and neither is the front end on the examples. The
compiler stays in Ruby, as the framework is. Budget: on every example and every VBlank game, the
compiler's reading (its rounds of the walk, any second run of setup, and its compiling walk) takes
no longer than the rewrite's reading of the same game. The walk interprets only per-frame code, and
setup, the heavy part, runs as Ruby at Ruby's speed; `once` keeps data work (unpacking art) out of
the walk. The prototype walked the copyright screen's per-frame code, both rounds, in a few
milliseconds. If a game misses the budget, the first fixes are in Ruby: cache each method's walk by
its known inputs, and walk a round only from what the last round changed. C is on the table only
with a measurement showing the compiler is the slow part after those.

## The order of the work, and each part's answer key

1. **Opt in, refuse, and the node table** (the epic's second task). A minimal game builds on
   `plain_ruby: :compiled`; the one error; the constant rule and its `allow:`; the node-table test. Answer key: Ruby
   through `test/ruby_answers.rb`, and this page.
2. **The core** (third task): numbers, fractions, flags, states, tests, loops, jumps, errors and
   the `stop` kind on every lowering, methods, parts, Structs, Data, `once` and its probe, making
   sites and rooms, choices, tagged values, `CoreEffects`, the written-place fixed point, the
   prelude's number methods, `division:`. `RubyAnswers` gains a way to play each case on both front
   ends; the `refused` cases the appendix gives to this task become `agrees` cases on the compiler.
   Answer key: Ruby, then the rewrite where it agrees with Ruby; a difference is named as the
   compiler's bug or the rewrite's.
3. **Collections and costs** (fourth task): Arrays, Arrays of Arrays, pools, Hashes, text, rooms
   for collections, the prelude's collection and text methods, the cost warnings. Every example
   builds on the compiler and plays the same over a fixed tape. Answer key: Ruby; every example on
   both front ends, screen and sound compared, with the compiler on `division: :toward_zero` where
   the example divides a number that can be negative; `rake emitted:check`, with growth reported.
4. **The debug log** (fifth task), after the core: the `log` kind on every lowering.
5. **Each game** (the remaining tasks), by that game's own session, in its own repository: turn the
   setting on, remove the rewrite's workarounds (`VBlank.require_game_file` becomes
   `require_relative`; `x = (@x ||= ...)` becomes `x = once { ... }`;
   `game_variables` lines kept only for names and saves; checks that test a value's class removed),
   and play the game's tapes on both. "Plays the same" compares the compiler on
   `division: :toward_zero`, since the rewrite rounds toward zero; a game that then moves to Ruby's
   division lists the differences that follows on its own bead. Answer key: the game's tests and
   tapes, and the original.

## Appendix: PLAIN_RUBY.md's 94 cases on the compiler

Each "Don't" on PLAIN_RUBY.md (as of this branch), sorted four ways:

- **Ruby**: builds and plays as Ruby says, with no warning; the case goes away. A case where Ruby
  itself raises is here too, as a stop where the line runs.
- **Warns**: builds as Ruby says, with a cost warning and a profile line.
- **Limit**: refused, or stopped as the game plays, as a console limit, in the one error's words.
- **Stays**: Ruby's own answer is a frozen or hung game, or the case is about a VBlank verb or
  setting, not about Ruby.

Each row names the task that builds it (2 to 5: the epic's second to fifth tasks) and the pieces of
this design it rests on, none of which exist yet: **F** the written-place fixed point, **E**
`CoreEffects`, **S** making sites and rooms, **C** choices, **T** tagged values, **P** the
prelude, **R** rooms and scratch copies for collections, **X** played text, **O** `once` and its
probe, **K** the `stop` kind, **L** the `log` kind.

| Count | Ruby | Warns | Limit | Stays |
|---|---|---|---|---|
| All 94 | 64 | 22 | 3 | 5 |
| The 71 refused today | 44 | 22 | 2 | 3 |
| The 15 that surprise | 12 | 0 | 1 | 2 |
| The 8 that cost more | 8 | 0 | 0 | 0 |

The guess that about three quarters go away or become warnings holds: 86 of 94 do, and 66 of the 71
refusals. It rests on pieces that are not built. The three riskiest are making sites with rooms,
choices and tagged values: 17 rows rest on one of them. If every one of those 17 ended up refused,
69 of 94 would still build, which is still about three quarters.

| Case (PLAIN_RUBY.md's summary) | On the compiler | Task | Rests on | Why |
|---|---|---|---|---|
| `while left` on a bare number | Stays | 3 | | Ruby's loop never stops; a frozen game stays a teaching error (the guardrail on a loop whose test is always true) |
| A loop on plain numbers that never ends | Stays | 3 | | Setup is real Ruby, so it hangs as Ruby does; the watchdog prints where, with the teaching line, as a notice |
| `hp + 1` on its own line | Warns | 3 | | Ruby does nothing with it; warned, not refused |
| `lives.nonzero? \|\| 1` | Ruby | 3 | T | A tagged answer used at once |
| `alive = hp` when `alive` started as `true` | Warns | 3 | T | A tagged value kept |
| `x = if ... end` with no `else` | Warns | 3 | T | nil in a tagged value kept |
| `case hp in Integer => n` | Ruby | 3 | | A played value's kind is known, so a class pattern is decided |
| `hp.fdiv(2)` | Ruby | 3 | P | |
| `2**level` with a game number as the power | Ruby | 3 | P, K | Within 32 bits; a negative power is a `Rational` in Ruby, a stop on the console |
| `speed.round(1)` | Ruby | 3 | P | At the fraction's precision |
| Other Integer methods, such as `hp.gcd(4)` | Ruby | 3 | P | |
| `"HP #{hp}".center(12)` | Ruby | 4 | X | |
| `call :"level#{level}"` | Warns | 3 | | A dispatch over the routines declared with that name |
| Change a String under a game test | Ruby | 4 | C, X | Given another String: a choice; changed in place: played text |
| `next` out of `game_loop` under a game test | Ruby | 3 | | |
| `break` on a game test in `3.times` | Ruby | 3 | | |
| `for m in marks` on an Array the game keeps | Ruby | 4 | F | |
| `0.step(10, by)` with a game number as the step | Ruby | 3 | | The step's sign is tested as Ruby does |
| `(0...n).map` with a game number `n` | Warns | 4 | R | Room from the setting or the default |
| `steps.next` in a `loop do` the game runs | Ruby | 4 | | An Enumerator |
| `break 5` in a loop the game runs | Ruby | 3 | | |
| `trail = []`, then `trail << x` | Warns | 4 | E, R | Room from the setting or the default |
| `Array.new(8)` | Warns | 4 | T | nil items: tagged, kept |
| `Array.new(n, 0)` with a game number | Warns | 4 | R | |
| `rotate!`, `map`, `unshift` and the like | Warns | 4 | E, P, R | `map` copies; `unshift` moves every item |
| `marks.sort` or `sort_by` | Warns | 4 | R | A copy |
| `a == b` on two Arrays the game keeps | Ruby | 4 | P | |
| `answers[0] = hp == 1` | Warns | 4 | T | Tagged items |
| Whole game numbers and fractions in one Array | Warns | 4 | T | Tagged items |
| `grid[0][1] += 1` on Arrays inside an Array | Warns | 4 | R | A list of lists |
| `Array.new(capacity: 4, holds: :fraction)` | Stays | 2 | | A VBlank keyword; refused as unknown |
| `[a, b].find { ... }` with game numbers | Ruby | 4 | P | |
| `max_by`, `sort` or `clamp` on game numbers | Ruby | 4 | P | On a written-out Array of two or three |
| `uniq`, `tally`, `-` and the like on game numbers | Warns | 4 | P, R | Copies; every item against every item |
| Index a `game_variables` Array through its reader | Ruby | 4 | F | |
| Give one Array to two parts that both change it | Ruby | 4 | F | One object, one place |
| Give a game Hash a key it does not have | Warns | 4 | R | Room for added keys |
| `h.delete(:b)`, `merge!`, `clear` on a game Hash | Warns | 4 | E, R | |
| `h.dup`, `merge`, `select` of a game Hash | Warns | 4 | R | A copy |
| Keep `v = h.values` of a game Hash | Warns | 4 | R | A copy |
| `h[at]` with a key the game works out | Warns | 4 | | A lookup |
| Change a part's Array of names in game code | Ruby | 4 | F | A list of states |
| An Array of `Data` objects that game code changes | Ruby | 4 | S | Kept by value |
| `min_by` and other methods a pool does not have | Ruby | 4 | P | |
| Sort an Array of Structs inside a walk of it | Ruby | 4 | | Ruby's walk by index |
| `sparks.min(2)` | Warns | 4 | R | A copy |
| `s.clamp(low, high)` with things of no Array | Ruby | 4 | P | |
| A `<=>` that adds fields | Ruby | 4 | | `<=>` walked like any method |
| `sort!` on Structs with no `<=>` | Ruby | 4 | K | Ruby's ArgumentError, a stop where it runs |
| `shift`, then `<<`, in one walk | Ruby | 4 | | Ruby's walk by index |
| `flock.dots << Dot.new(...)` from outside the class | Ruby | 4 | F, S | |
| Fill a part's Array from a reopened class | Ruby | 4 | F | |
| Make a part above `VBlank.game` and change its Array | Ruby | 4 | F | Starts read, never written |
| Set `@open` in a method and test it elsewhere | Ruby | 3 | F | |
| Read `@point` that only a `func` sets | Ruby | 3 | C, K | A choice with nil; Ruby's error as a stop |
| Make a Struct under an `if` and use it after | Ruby | 3 | S, C | |
| Sum in a lambda passed with `&` | Ruby | 4 | F | A captured local keyed by its binding |
| Read a part's Array, then change it by its reader | Ruby | 4 | F | |
| `@counts.first(2)` or `@counts[0..]` of named numbers | Warns | 4 | R | A copy |
| Copy named numbers, as in `@counts.dup` | Warns | 4 | R | A copy |
| `Counter.new` in the game loop | Ruby | 3 | S | Made again each pass, its slot given back |
| Keep two different things in one name with `\|\|=` | Ruby | 3 | S, C | |
| Give `@point` a new Struct after game code read it | Ruby | 3 | S, C | |
| Freeze a Struct that holds game numbers | Ruby | 3 | S | Frozen: kept by value; the file's way of loading decides nothing |
| Read a Data object as `it` or `_1` | Ruby | 4 | S | Kept by value |
| Set `score` above `VBlank.game` and change it inside | Ruby | 3 | F | |
| `counts[0] &&= value` on a number | Ruby | 4 | | |
| `flags[:open] \|\|= true` on `false` | Ruby | 4 | | |
| `eval`, `system` and the like in game code | Limit | 2 | | The one error |
| A library such as `JSON` in game code | Limit | 2 | | Today's constant rule and message, `allow:` kept |
| `instance_variable_get(:@hp)` | Ruby | 3 | | Reflection with a known name |
| `if hp` to test for 0 | Ruby | 3 | | Ruby's truth |
| `x / 2` on a negative game number | Ruby | 3 | | Ruby's division by default |
| `puts hp` to see a number | Ruby | 5 | L | |
| Push onto a full Array | Limit | 4 | R, K | The console's room; a stop in plain words |
| `draw_number` each frame on a tiled screen | Stays | | | The verb's meaning |
| Read a local that you gave to a part | Ruby | 4 | F | One object, one place |
| Expect one writer name to change one class | Ruby | 3 | F | |
| Set a lasting count inside `game_loop` | Ruby | 3 | | Ruby's block locals |
| Change a method's argument to change the caller's number | Ruby | 3 | | |
| Expect `"HP #{hp}"` to fit the number | Ruby | 4 | X | Played text is Ruby's text |
| Expect every instance variable to be the game's | Ruby | 3 | F | |
| Put 200 in a `width: :byte` list | Stays | | | The setting's meaning |
| `<<` in a walk where a called routine took a place | Ruby | 4 | | Ruby's walk by index |
| Keep a part in a part that is made every pass | Ruby | 3 | S | |
| Expect a kept part's `initialize` to run each pass | Ruby | 3 | O | |
| Give a handed number another to change its owner | Ruby | 3 | F | A played place of its own, as Ruby's |
| `item = trail.shift` when you can avoid it | Ruby | 4 | | A profile line |
| `sum` or `max` of a long list on every pass | Ruby | 4 | | A profile line |
| `sort!` a list on every pass that rarely changes | Ruby | 4 | | A profile line |
| Expect a counting loop to be a loop | Ruby | 3 | | A profile line |
| Copy a game number into a field far from where you read it | Ruby | 3 | | A profile line |
| Fill an Array in a kept part's `initialize` | Ruby | 3 | O | |
| A big list in full words if its numbers are small | Ruby | 4 | | A profile line |
