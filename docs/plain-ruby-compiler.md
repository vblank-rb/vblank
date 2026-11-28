# The plain Ruby compiler

This page says what each line of plain Ruby game code means when a game is built by VBlank's
compiler from plain Ruby to the IR, and why each rule is the rule. It is the design the compiler is
built to. Where today's front end (the source rewrite in `lib/vblank/dsl/plain_ruby*.rb`) does
something else, the page says so.

The short version: **setup code runs as Ruby; per-frame code is compiled from its tree, with the
real objects setup made in hand; a place per-frame code writes lives on the console, and anything
else stays Ruby.** No answer comes from how a line is spelled.

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
they are what the compiler emits into. The lowerings do not change.

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

**Setup code** runs as real Ruby, once, while the game is built. It is:

- the `VBlank.game` block outside every game block (below);
- class and module bodies, and every method that setup code calls;
- the block of `once { }`, and the right side of a make-once `||=` (see "Making parts once");
- every file loaded with plain `require`, and every gem.

**Per-frame code** is compiled. It is:

- the blocks of the game verbs: `game_loop`, `scene`, `func`, `once_a_frame`, `every`, `after`,
  `repeat`, `each_pass`, a timer's `on_tick`, a menu's `item`, a data pack's `fill_from_copy`;
- every method of a game file that per-frame code calls, however many calls down, and every block
  or lambda written in a game file that per-frame code calls, whether per-frame code or setup
  made it.

A game file is one loaded with `VBlank.require_game_file`, or the file holding `VBlank.game`. A
method is per-frame code because of where it is reached from, not because of what its lines say:
`FadedScreen#step` called from `initialize` runs as Ruby, and called from a scene is compiled.
Decision: the split follows the call, because the same method is often both (a part's `restart`
is called while setting up and by a scene), and Ruby gives it one meaning wherever it is called.

Setup code sees every game number at its start. A game number never changes while the game is
built, because nothing plays while it is built.

## Known and played values

The compiler walks per-frame code with an abstract interpreter. Every expression gives one of two
things:

- **known**: a real Ruby object, the same one Ruby would have at that line on every pass. A
  constant, a literal, a part setup made, a sum of knowns, a known method's answer.
- **played**: a value that lives on the console, given as an IR expression of a kind (below).
  Reading a played place, or a verb that answers the console's state (`pressed(:a)`, `rand`), gives
  one, and so does any working-out that uses one.

What is known is worked out while building and costs the console nothing: `size = 8 * 2` in a
game loop is 16 in the cartridge. A test on a known value is decided while building, and only the
branch Ruby takes is compiled, so `if console == :gbc` costs nothing and may hold code the other
console cannot build.

A per-frame local (first written in per-frame code) is followed as the walk goes: after `x = 3` it
is known, after `x = hp` it is played. Where two paths meet with different values for it (after an
`if` on a played test, round a loop the game runs) it becomes a console variable that holds
whichever the game took. Its start is fresh on each pass, as Ruby's block locals are.

## Which places are played

**A place is played when per-frame code writes it.** A place is a setup local (a local of the
`VBlank.game` block, or of a scope outside it, that per-frame code can see), an instance variable of
a real object, a field of a real Struct, an item of a real Array, or a value of a real Hash at a
key. Anything else setup made stays Ruby, and per-frame code reads it as known.

Places are keyed by the real object, never by a name in the source: `@frames` of one
`FadedScreen` is a different place from `@frames` of another, and a writer `dial.level += 3`
makes `level` played on that dial alone. The compiler finds the played places by walking the
per-frame code from every game block, writing nothing, and noting every place written; then it
walks again with those places played, since a test that was known may now be played and reach more
code. It stops when a round finds no new place. The set only grows and the places are finite, so it
always stops, and in practice the second round finds nothing new.

A throwaway prototype of the walk, run on Pokemon Pinball's copyright screen copied out of the
game, with a stub builder, found exactly the instance variables the game names with
`game_variables`, plus the two `var` handles, in two rounds, with no `game_variables` line read. It
also left out one the game names, `@first_frame`, because for the copyright screen's object the
branch that writes it is decided known and never taken. That is the gain of keying by object: a
place is played on the parts whose code writes it.

A played place starts at power-on from the value it holds when the build reaches the game: its
setup value. That value is read from the real object and never written back, so the object a game
made stays as setup left it. Two builds of one game (one per console) start from the same objects.

A place setup gives a `var` handle (`showing = var :showing, 0`, `@phase = builder.var(...)`) is
that variable: per-frame writes go into it, and it keeps the name, width and save setting the
`var` line gave. Ruby's `var` answers its start, so a place holding a number that per-frame code
changes is what Ruby sees too.

### What the rewrite guessed, and the rule that replaces it

| Today (rewrite) | What it guesses from the text | The compiler's rule |
|---|---|---|
| `Builder::Session` (`recording?`) | Whether a line runs as game code is a flag set while a game verb's block runs, so a method behaves differently depending on who is recording | Per-frame code is what game blocks reach by calls; the walk knows, and no flag exists while real Ruby runs |
| `LocalNames` (`game_array?`, `GAME_VERBS`, `RUBY_ITERATORS`) | Which local names are game state, from the verbs written near them; whether a `.each` is Ruby's or the game's from whether the receiver is spelt as a literal | A setup local is played when per-frame code writes it (Prism resolves which scope a local is in); a walk over a known collection is unrolled and one over a played one is a loop, by the value |
| `InstanceVariables` (`mark_changing`, `game_variables`) | Which instance variables are game state, from spellings such as `@x = 1 - @x`, or the author's own marks | Played when per-frame code writes it, on that object; `game_variables` is still read for a chosen name and `saved: false`, and asks for nothing else |
| `Writes.write` | Whether a write replaces a value or goes into the variable a name holds, and what to do under a game test, from the place's spelling | Ruby's write, always: a played place takes the value; a known place written under a played test is played, since per-frame code writes it |
| `Steps` (`game_test?`, `equal_test`) | At run of the rewritten code, whether a value is the game's, and fixes for Ruby asking the wrong side (`3 == hp`) | Known or played is decided by the walk before any IR is made; an operator on a played value is compiled whichever side it is on |
| `Promotion` | When a plain value must become a game variable, from tests open around a line | A per-frame local becomes a console variable where paths with different values meet; a setup place by the written rule |
| `CallChanges`, `ItemQuestions`, `KnownRounds` | Which calls change their receiver, which loops are counted while building | The receiver's real class (a game method is walked, a core method is in the prelude's table) and known or played bounds |

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
the scene as it does today. Every pass after gets the same object back. In plain Ruby, `once` is
`@once[site] ||= yield`, so it means what Ruby means, nil kept as well.

Decision: a verb, not a new kind of block, because the parts must be locals of the scene body
(Ruby blocks do not leak locals out, so a `setup do ... end` inside a scene would force instance
variables again) and because a verb is plain Ruby to read: it is a call with a block.

`@x ||= rhs` in per-frame code is the same thing when `@x` is nil or false as the build reaches it,
nothing else in per-frame code writes `@x`, and `rhs` reads no played value: the right side runs
once, as setup code, and the line costs nothing. Where `rhs` reads a played value
(`@ship ||= Ship.new(hero_x, 0)`), the part is made the first time the line runs, as the game
plays: its fields are set from the played values on that pass, and a flag remembers it is made.

A `once` block or a make-once right side that reads a played value of the scope around it is
refused, naming the value, since setup sees only starts. A played value read deeper down, in a
method the right side calls, reads its start: written down as the one place this design differs
from Ruby's timing.

### Parts made as the game plays

`Thing.new(...)` with a game class, reached in per-frame code with any played argument, is a
**making site**. Each site has one place for its object; making it again sets that place up again
from `initialize`, compiled. That is Ruby's answer whenever only one object from the site is in use
at a time, which is what a part made in a loop and used in that pass is. An object from a site put
into an Array with room is one of that Array's things (a pool). A second object from one site kept
alive beside the first (`old = @x; @x = Thing.new`, then both read) is refused as a memory limit:
the console keeps no heap.

### Several known objects in one place

A played place that holds one of several known objects (a Struct made under an `if`, two parts
kept in one name, `pick = big ? sprite_a : sprite_b`) is a **choice**: a small number saying which.
A call on it is a `case` over the objects, each arm compiled with that object known. nil is one of
the choices, so `@point` read before the routine that sets it gives Ruby's `NoMethodError`, said
in plain words, on the pass it happens.

## The kinds of value

| Kind | On the console | Notes |
|---|---|---|
| Integer | 32-bit signed (`IR::Int32`) | Past 2**31 it wraps, on every lowering alike; Ruby makes a Bignum. The interpreter can be told to stop on a wrap, for a test that wants to know |
| Float | a fraction, fixed point | Precision is the fraction's, not a double's: the one other named difference from Ruby |
| true, false | a flag | |
| nil | a flag or a choice member | |
| Symbol | a state: a number per name | Compared with `==`, called with `call`; `:"level#{n}"` is a state worked out from a number, matched against the routines declared |
| Mixed (a place given values of two kinds) | a **tagged value**: a number and a byte saying its kind | `alive = hp` after `alive = true`; `[0, 1.5]`; `Array.new(8)` of nils. Every operation checks the tag, as Ruby does; warned as a cost |
| Part, Struct, Data | known object; its played fields are console variables | Methods walked; `<=>` and `Comparable` compiled |
| Choice | a number over known objects | See above |
| Array of numbers | a list with room | Room from `capacity:`, or the most items the compiler can see; see "Costs" |
| Array of Arrays | a list of lists | Rows of one known size are one block of memory |
| Array of Structs | a pool | As today, with Ruby's order of a walk while it changes |
| Hash | keyed slots, with room for keys added | Known keys are slots; a played key is looked up |
| String | known text, or played text: known pieces and played numbers, with a most length | Drawn, compared, padded, logged; see below |
| Range | known, or two played ends | |
| Proc, lambda, Method | known; its body walked where it is called | |
| Enumerator | a known collection and a played position | `steps.next` in a loop the game runs |
| table | as today | |

Played text has a most length known while building (a 32-bit number is at most 11 characters),
so it needs no heap. It answers `size`, `+`, `*` by a known count, `==`, `center`, `ljust`,
`rjust`, `to_s`, `to_i`, and drawing and logging. A String method with no meaning on the console's
text (`encode`, `unpack1`, a Regexp) on played text is refused.

## What each line means

**Calls.** A call in per-frame code goes one of four ways, chosen by the receiver's real class and
whether anything given is played:

1. A method of a game file: walked. Its body is per-frame code with `self` the real receiver.
2. A verb or a handle's method (Builder, `DSL::Value`, a sprite, a list): called for real while
   building, handed played values as the IR handles the verbs already take. This is how IR is made.
3. A core method (Integer, Float, Array, Hash, String, Range, Comparable, Enumerable, Kernel) on a
   played value, or with played arguments: compiled from the **prelude**, below.
4. Anything else with every input known: called for real, and its answer is known. This is how
   `JSON.parse(LEVELS)` or `Facts.of(...)` in a scene costs nothing. With a played input it is
   refused as a library the console cannot run.

**Tests and loops** mean what Ruby says, with Ruby's truth (only nil and false are false). A test
on a known value compiles one branch; on a played value both, as the game's branch. `while`,
`until`, `loop`, `times`, `upto`, `step`, `each`, `for` over played bounds or a played collection
are loops the game runs; over known ones the build chooses to unroll or count, and the profile says
which (`rom.profile`). `break`, `break value`, `next`, `redo`, `return` from a method or a routine,
and `next` and `break` in `game_loop` mean Ruby's jumps. `begin`, `rescue`, `ensure` and `retry`
are compiled for the errors the game itself raises; a rescue of an error only Ruby's runtime raises
(`NoMethodError` on a played nil) catches it as Ruby does.

**`raise`** in per-frame code is Ruby's: the game stops where the line runs, with the message, on
every lowering. A `raise` under a known test is decided while building, so it stops the build.
Games written for the rewrite sometimes test a value's class to check their own wiring (a Pokemon
Pinball part raises unless a block gave back a Condition); under the compiler that line means
Ruby's raise, so each game's move removes such checks.

**Pattern matching**, multiple assignment, splats, keyword arguments, `defined?`, `__method__`,
`instance_variable_get` and `send` with a known name mean what Ruby says. Reflection with a played
name is refused.

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

- Copies of a played collection (`sort`, `map`, `select`, `dup`, `first(2)`, `+`, `uniq`, `tally`,
  `h.merge`, `h.values` kept). Each has a scratch place sized by the most items the source can
  hold, so no heap is needed; its cost is the copy.
- A played Array or Hash with no `capacity:` that grows (`trail = []`, then `trail << x`;
  `Array.new(n, 0)` with a played `n`; a Hash given a key it did not start with). It gets a room the
  warning names, and a push past that room stops the game in plain words.
- A tagged value, a choice of more than a few objects, a played key looked up in a Hash, a dispatch
  over routine names worked out from a number, Arrays inside Arrays.
- A line that works out a number and drops it (`hp + 1` alone).
- What PLAIN_RUBY.md lists under "What costs more" today: a running total kept by hand, a sort on
  every pass, a copy far from its read.

**Division.** `/` and `%` are Ruby's, rounding down, on negative numbers too. By a power of two
that is a shift and a mask, cheaper than rounding toward zero; by anything else it is the console's
divide and a two-instruction correction. `remainder` is Ruby's own truncating remainder, and costs
nothing extra. `VBlank.game ..., division: :toward_zero` makes every `/` and `%` round toward zero,
as C does: faster on a divisor the compiler cannot see, and not Ruby, so the setting says so in its
name. Where the compiler can see both sides are never negative, the correction is left out.

## The one compiler error

What a console cannot do stops the build with one message shape, written with the simple-english
skill:

```
game.rb:42: `eval` cannot run on the console.
The game runs on the console, and the console has no Ruby to read text as code.
To fix this, do this work above the game block, or write the code out.
```

Line one: the file and line, the construct in backticks, and "cannot run on the console". Line
two: why, in one sentence about the console. Line three: what to do, starting "To fix this". The
same shape covers every refusal: `eval` and its relatives, `system`, backticks, `exec`, `fork`,
`spawn`, `require` and `load` in per-frame code, a library called with a played value, `IO`,
`File`, `Dir`, `STDIN`, threads, Ractors, fibers, `ObjectSpace`, `method_missing` and
`respond_to_missing?` reached with a played name, `define_method`, `class_eval`, `alias` and
`undef` in per-frame code, `BEGIN` and `END`, a global variable written in per-frame code,
reflection with a played name, flip-flops, and a second live object from one making site. The class
is `RubyCompiler::Refused`, a `BuildError`.

Ruby's own errors that the build can see (sort on Structs with no `<=>`, a write to a frozen
Struct, a method no class has) are said as Ruby says them, at build time, in the same shape.

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
out. The log is a new IR kind (`log`), so it goes in the conformance fixture and every lowering
learns it.

## Every Prism node is decided

The compiler keeps a table with one row for each node class of the Prism that VBlank loads
(`Prism::Node`'s subclasses, read at load; Prism 1.9.0's `config.yml` lists 151 and Ruby 4.0's
loaded Prism has 152), each marked compiled, setup only, or refused with the one error. A test
fails on a node class with no row, so a new Prism with a new kind fails until somebody decides.
Decision: the loaded classes, not a path into the gem's install, since they are what parses the
game. The refused rows are: `XStringNode`, `InterpolatedXStringNode`, `PreExecutionNode`,
`PostExecutionNode`, `FlipFlopNode`, `MatchLastLineNode`, `InterpolatedMatchLastLineNode`,
`BackReferenceReadNode`, `NumberedReferenceReadNode`, the global variable write kinds, `UndefNode`,
`AliasGlobalVariableNode`, and in per-frame code `AliasMethodNode`, `ClassNode`, `ModuleNode`,
`SingletonClassNode` and `DefNode` (a method defined while the game plays). `ImaginaryNode` and
`RationalNode` are setup only.

## Where it sits

`lib/vblank/ruby_compiler/`, module `VBlank::RubyCompiler`, with its front door
`ruby_compiler.rb`. It is a module of its own, not more files in `dsl/`, because what it is (a
compiler from Ruby to the IR) is not a thing a game names, and the old files there go when it is
done. Its interface is one method, `RubyCompiler.game_block(block, settings)`, the same shape as
`DSL::PlainRuby.game_block`; everything else is inside: the walk (`Walk`), the fixed point over
written places (`Places`), the kinds (`Kinds`), the node table (`NodeTable`), the prelude, the
refusal and the cost warnings. It emits through the builder's own verbs and containers, so it adds
nothing to the IR but the `log` kind.

## How fast it builds

Measured on this design's branch (the numbers are on the bead): on the largest examples, the
rewrite with its Prism parse is a small part of a build, the game's reading (setup run and
recording) a few times more, the IR checks about half the reading, and the console's lowering most
of the build. Prism's parse is already in C and is a small part of the rewrite. On a scratch copy
of Pokemon Pinball (which builds only part way on this commit) Prism parsed all of the game's files
in a sliver of the time spent loading and rewriting them, and the first build on a cold machine
spent far longer compiling the game's own unpacking as C than in any Ruby phase.

So Prism is not where a build spends its time, and neither is the front end on the examples. The
compiler stays in Ruby, as the framework is. Budget: on every example and every VBlank game, the compiler's reading (its rounds
of the walk and its compiling walk) takes no longer than the rewrite's reading of the same game.
The walk interprets only per-frame code, and setup, the heavy part, runs as Ruby at Ruby's speed;
`once` keeps data work (unpacking art) out of the walk. The prototype walked the copyright screen's
per-frame code, both rounds, in a few milliseconds. If a game misses the budget, the first fixes
are in Ruby: cache each method's walk by its known inputs, and walk a round only from what the last
round changed. C is on the table only with a measurement showing the compiler is the slow part
after those.

## The order of the work, and each part's answer key

1. **Opt in, refuse, and the node table** (the epic's second task). A minimal game builds on
   `plain_ruby: :compiled`; the one error; the node-table test. Answer key: Ruby through
   `test/ruby_answers.rb`, and this page.
2. **The core** (third task): numbers, fractions, flags, states, tests, loops, jumps, methods, parts,
   Structs, Data, `once`, making sites, choices, tagged values, the written-place fixed point.
   `RubyAnswers` gains a way to play each case on both front ends; the `refused` cases this page
   sorts as building become `agrees` cases on the compiler. Answer key: Ruby, then the rewrite
   where it agrees with Ruby; a difference is named as the compiler's bug or the rewrite's.
3. **Collections and costs** (fourth task): Arrays, Arrays of Arrays, pools, Hashes, text, the
   prelude's collection methods, the cost warnings. Every example builds on the compiler and plays
   the same over a fixed tape. Answer key: Ruby; every example on both front ends, screen and sound
   compared; `rake emitted:check`, with growth reported.
4. **The debug log** (fifth task), after the core: the `log` kind on every lowering.
5. **Each game** (the remaining tasks), by that game's own session, in its own repository: turn the
   setting on, remove the rewrite's workarounds (`x = (@x ||= ...)` becomes `x = once { ... }`;
   `game_variables` lines kept only for names and saves; checks that test a value's class removed),
   and play the game's tapes on both. Answer key: the game's tests and tapes, and the original.

## Appendix: PLAIN_RUBY.md's 94 cases on the compiler

Each "Don't" on PLAIN_RUBY.md (as of this branch), sorted four ways:

- **Ruby**: builds and plays as Ruby says; the case goes away. (A case where Ruby itself raises
  is here too: the build says Ruby's error.)
- **Warns**: builds as Ruby says, with a cost warning and a profile line.
- **Limit**: refused, or stopped as the game plays, as a console limit, in the one error's words.
- **Stays**: Ruby's own answer is a frozen game, which stays a teaching error; or the case is
  about a VBlank verb or setting, not about Ruby.

| Count | Ruby | Warns | Limit | Stays |
|---|---|---|---|---|
| All 94 | 57 | 29 | 3 | 5 |
| The 71 refused today | 44 | 22 | 2 | 3 |
| The 15 that surprise | 12 | 0 | 1 | 2 |
| The 8 that cost more | 1 | 7 | 0 | 0 |

The guess that about three quarters go away or become warnings holds: 86 of 94 do, and 66 of the
71 refusals. The count rests on four pieces of this design: tagged values, choices, scratch places
sized from their source, and the prelude. A case whose piece falls through moves to Warns or Limit,
and the task that builds the piece says so.

| Case (PLAIN_RUBY.md's summary) | On the compiler | Why |
|---|---|---|
| `while left` on a bare number | Stays | Ruby's loop never stops; a frozen game stays a teaching error |
| A loop on plain numbers that never ends | Stays | Setup code; Ruby's own endless loop |
| `hp + 1` on its own line | Warns | Ruby does nothing with it; warned, not refused |
| `lives.nonzero? \|\| 1` | Ruby | `nonzero?` gives the number or nil, a tagged answer |
| `alive = hp` when `alive` started as `true` | Warns | A tagged value |
| `x = if ... end` with no `else` | Warns | nil in a tagged value |
| `case hp in Integer => n` | Ruby | A played value's kind is known, so a class pattern is decided |
| `hp.fdiv(2)` | Ruby | Prelude |
| `2**level` with a game number as the power | Ruby | Prelude: a loop by squaring |
| `speed.round(1)` | Ruby | Prelude, at the fraction's precision |
| Other Integer methods, such as `hp.gcd(4)` | Ruby | Prelude |
| `"HP #{hp}".center(12)` | Ruby | Played text |
| `call :"level#{level}"` | Warns | A dispatch over the routines declared with that name |
| Change a String under a game test | Ruby | A choice of known Strings |
| `next` out of `game_loop` under a game test | Ruby | Compiled jump |
| `break` on a game test in `3.times` | Ruby | Compiled jump |
| `for m in marks` on an Array the game keeps | Ruby | A loop over a list |
| `0.step(10, by)` with a game number as the step | Ruby | A loop with a played step |
| `(0...n).map` with a game number `n` | Warns | A new Array with no known room |
| `steps.next` in a `loop do` the game runs | Ruby | An Enumerator: known items, played position |
| `break 5` in a loop the game runs | Ruby | The loop's value |
| `trail = []`, then `trail << x` | Warns | Room named in the warning |
| `Array.new(8)` | Warns | Items of nil: tagged |
| `Array.new(n, 0)` with a game number | Warns | Room named in the warning |
| `rotate!`, `map`, `unshift` and the like | Warns | Prelude; `map` is a copy, `unshift` moves every item |
| `marks.sort` or `sort_by` | Warns | A copy |
| `a == b` on two Arrays the game keeps | Ruby | Prelude |
| `answers[0] = hp == 1` | Warns | A list of tagged items |
| Whole game numbers and fractions in one Array | Warns | A list of tagged items |
| `grid[0][1] += 1` on Arrays inside an Array | Warns | A list of lists |
| `Array.new(capacity: 4, holds: :fraction)` | Stays | A VBlank setting, unneeded; refused as an unknown keyword |
| `[a, b].find { ... }` with game numbers | Ruby | Prelude over a known Array of played items |
| `max_by`, `sort` or `clamp` on game numbers | Ruby | Prelude |
| `uniq`, `tally`, `-` and the like on game numbers | Warns | Copies, an item against every item |
| Index a `game_variables` Array through its reader | Ruby | Places keyed by object |
| Give one Array to two parts that both change it | Ruby | One object, one place |
| Give a game Hash a key it does not have | Warns | Room for added keys |
| `h.delete(:b)`, `merge!`, `clear` on a game Hash | Warns | Room for added keys |
| `h.dup`, `merge`, `select` of a game Hash | Warns | A copy |
| Keep `v = h.values` of a game Hash | Warns | A copy |
| `h[at]` with a key the game works out | Warns | A lookup |
| Change a part's Array of names in game code | Ruby | A list of states |
| An Array of `Data` objects that game code changes | Ruby | A pool whose things are replaced whole |
| `min_by` and other methods a pool does not have | Ruby | Prelude |
| Sort an Array of Structs inside a walk of it | Ruby | Ruby's walk by index, compiled |
| `sparks.min(2)` | Warns | A copy |
| `s.clamp(low, high)` with things of no Array | Ruby | Compiled `<=>` |
| A `<=>` that adds fields | Ruby | `<=>` walked like any method |
| `sort!` on Structs with no `<=>` | Ruby | Ruby's own error, said at build time |
| `shift`, then `<<`, in one walk | Ruby | Ruby's walk by index, compiled |
| `flock.dots << Dot.new(...)` from outside the class | Ruby | Places keyed by object |
| Fill a part's Array from a reopened class | Ruby | Places keyed by object |
| Make a part above `VBlank.game` and change its Array | Ruby | Objects are never changed by a build |
| Set `@open` in a method and test it elsewhere | Ruby | The written-place rule finds it |
| Read `@point` that only a `func` sets | Ruby | A choice with nil; Ruby's error where Ruby has one |
| Make a Struct under an `if` and use it after | Ruby | A choice |
| Sum in a lambda passed with `&` | Ruby | Lambdas are walked |
| Read a part's Array, then change it by its reader | Ruby | Places keyed by object |
| `@counts.first(2)` or `@counts[0..]` of named numbers | Warns | A copy |
| Copy named numbers, as in `@counts.dup` | Warns | A copy |
| `Counter.new` in the game loop | Ruby | A making site |
| Keep two different things in one name with `\|\|=` | Ruby | A choice |
| Give `@point` a new Struct after game code read it | Ruby | A choice |
| Freeze a Struct that holds game numbers | Ruby | Objects are never changed; a write is Ruby's FrozenError |
| Read a Data object as `it` or `_1` | Ruby | Walked like a named parameter |
| Set `score` above `VBlank.game` and change it inside | Ruby | A setup local, played |
| `counts[0] &&= value` on a number | Ruby | Ruby's `&&=` |
| `flags[:open] \|\|= true` on `false` | Ruby | Ruby's `\|\|=` |
| `eval`, `system` and the like in game code | Limit | The one error |
| A library such as `JSON` in game code | Limit | With known inputs it now runs while building; with played ones, the one error |
| `instance_variable_get(:@hp)` | Ruby | Reflection with a known name |
| `if hp` to test for 0 | Ruby | Ruby's truth |
| `x / 2` on a negative game number | Ruby | Ruby's division by default |
| `puts hp` to see a number | Ruby | The debug log |
| Push onto a full Array | Limit | The console's room; the game stops in plain words |
| `draw_number` each frame on a tiled screen | Stays | The verb's meaning |
| Read a local that you gave to a part | Ruby | One object, one place |
| Expect one writer name to change one class | Ruby | Places keyed by object |
| Set a lasting count inside `game_loop` | Ruby | Ruby's block locals |
| Change a method's argument to change the caller's number | Ruby | Ruby's own meaning |
| Expect `"HP #{hp}"` to fit the number | Ruby | Played text is Ruby's text |
| Expect every instance variable to be the game's | Ruby | The written-place rule |
| Put 200 in a `width: :byte` list | Stays | The setting's meaning |
| `<<` in a walk where a called routine took a place | Ruby | Ruby's walk by index |
| Keep a part in a part that is made every pass | Ruby | Making sites, as Ruby |
| Expect a kept part's `initialize` to run each pass | Ruby | Ruby's own meaning |
| Give a handed number another to change its owner | Warns | A place of its own, counted |
| `item = trail.shift` when you can avoid it | Warns | A copy |
| `sum` or `max` of a long list on every pass | Warns | Profile line |
| `sort!` a list on every pass that rarely changes | Warns | Profile line |
| Expect a counting loop to be a loop | Warns | Profile line |
| Copy a game number into a field far from where you read it | Warns | Profile line |
| Fill an Array in a kept part's `initialize` | Ruby | `once` runs it while building, as Ruby runs it once |
| A big list in full words if its numbers are small | Warns | Profile line |
