# frozen_string_literal: true

# The Structs and parts of test/all/vblank/dsl/test_plain_ruby_answers.rb, brought in by
# `VBlank.require_game_file`, so their methods are read as game code. Each is named for the
# answers suite, apart from the other test files' Structs.

# A point: where it is and how fast it falls.
AnswerPoint = Struct.new(:x, :y, :vy)

# A point ordered by its y, the smallest first.
AnswerLow = Struct.new(:x, :y) do
  include Comparable
  def <=>(other) = y <=> other.y
end

# A point ordered by its y, the biggest first, by turning the answer round.
AnswerHigh = Struct.new(:x, :y) do
  include Comparable
  def <=>(other) = -(y <=> other.y)
end

# A point whose order counts how often it was asked.
AnswerCounted = Struct.new(:x, :y, :n) do
  include Comparable

  def <=>(other)
    self.n += 1
    y <=> other.y
  end
end

# A mover whose step asks a method of its own.
AnswerMover = Struct.new(:x, :y) do
  def step = self.x += speed
  def speed = x > 5 ? 3 : 1
end

# A card with a field called index.
AnswerCard = Struct.new(:x, :y, :index)

# A box whose members share their names with what a thing of an Array answers (left), with
# what a walk hands its block (move) and with `pool`'s own words (capacity, rate).
AnswerBox = Struct.new(:left, :move, :capacity, :rate)

# A point that cannot change: a new one is made with `with`.
AnswerFixedPoint = Data.define(:x, :y)

# A lamp game code switches, with no game_variables line.
class AnswerLamp
  def initialize
    @lit = 0
  end

  def switch = @lit = 1 - @lit

  attr_reader :lit
end

# The same lamp switched by a routine it makes, as a part of a game does.
class AnswerRoutineLamp
  def initialize(build)
    @lit = 0
    build.func(:switch_answer_lamp) { @lit = 1 - @lit }
  end

  attr_reader :lit
end

# A count game code reads in one method before another changes it, and a size changed only while
# building.
class AnswerTicker
  def initialize
    @ticks = 0
    @size = 3
  end

  def grow! = @size += 1
  def shown = @ticks * 10
  def tick = @ticks += 1

  attr_reader :size
end

# A flag game code tests before it changes it.
class AnswerDoor
  def initialize
    @open = false
  end

  def seen = @open ? 1 : 0
  def open? = @open
  def toggle = @open = !@open
end

# A flag a routine tests around game code and then toggles.
class AnswerRoutineDoor
  def initialize(build)
    @open = false
    @seen = 0
    build.func(:answer_door_tick) do
      @seen += 1 if @open
      @open = !@open
    end
  end

  attr_reader :seen
end

# A Hash of numbers game code counts up at keys known while building, with no game_variables line.
class AnswerTally
  SIDES = %i[left right].freeze

  def initialize
    @counters = SIDES.to_h { |side| [side, 0] }
  end

  def count = SIDES.each { |side| @counters[side] += 1 }
  def left = @counters[:left]
end

# An Array of numbers game code counts up at an index it works out, with no game_variables line.
class AnswerSlots
  def initialize
    @counts = [0, 0, 0]
  end

  def bump(at) = @counts[at] += 1
  def first = @counts[0]
end

# An Array of numbers the class names and hands out through its reader, which another part
# changes at an index the game works out.
class AnswerNamedTallies
  game_variables :counts
  attr_reader :counts

  def initialize
    @counts = [0, 0, 0]
  end
end

# The same, with no `game_variables` line.
class AnswerTallies
  attr_reader :counts

  def initialize
    @counts = [0, 0, 0]
  end
end

# A part changing another part's Array through its reader.
class AnswerTallyKeeper
  def initialize(tallies)
    @tallies = tallies
  end

  def bump(at) = @tallies.counts[at] += 1
  def first = @tallies.counts[0]
end

# A method named as a reader that hands out a copy: a change to the copy leaves the Array alone.
class AnswerCopiedTallies
  def initialize(start)
    @counts = [start, start, start]
  end

  def counts = @counts.dup
  def first = @counts[0]
end

# An Array handed in, which two parts can share.
class AnswerSharedTallies
  attr_reader :counts

  def initialize(given)
    @counts = given
  end

  def bump(at) = @counts[at] += 1
  def at(index) = @counts[index]
end

# A named Array read through a reader called `counts`, like AnswerTallies's, only at indexes known
# while building: its slots stay a variable each, whatever another class's `counts` is read at.
class AnswerNamedSizes
  game_variables :counts
  attr_reader :counts

  def initialize
    @counts = [3, 4]
  end
end

# An Array of numbers read through its reader only at indexes known while building.
class AnswerMarks
  game_variables :marks
  attr_reader :marks

  def initialize
    @marks = [0, 0]
  end
end

# An Array of numbers with no `game_variables` line, changed through its reader at known indexes.
class AnswerScores
  attr_reader :scores

  def initialize
    @scores = [5, 0]
  end
end

# A number changed from outside, through its writer.
class AnswerDial
  attr_accessor :level

  def initialize
    @level = 2
  end
end

# One number given another's, then the other counted up: each keeps a number of its own.
class AnswerPair
  def initialize
    @a = 0
    @b = 0
  end

  def step
    @a = @b
    @b += 1
  end

  attr_reader :a, :b
end

# A count set back to nothing under a test the game makes, then counted up.
class AnswerReset
  def initialize
    @n = 5
  end

  def step(reset)
    @n = 0 if reset
    @n += 1
  end

  attr_reader :n
end

# A count set back outright by one method, which nothing calls, and counted up by another.
class AnswerSetter
  def initialize
    @n = 5
  end

  def reset = @n = 0
  def step = @n += 1

  attr_reader :n
end

# A number a method of its own sets back outright, which the source does not mark.
class AnswerResetOutright
  def initialize
    @n = 7
  end

  def reset = @n = 0

  attr_reader :n
end

# Lives that start as nothing, given a number by one method and counted down by another.
class AnswerLives
  def initialize
    @lives = nil
  end

  def start = @lives = 3
  def lose = @lives -= 1

  attr_reader :lives
end

# A counter made inside game code: Ruby makes a new one each time that line runs.
class AnswerCounter
  def initialize
    @n = 0
  end

  def bump = @n += 1

  attr_reader :n
end

# An object whose `initialize` makes an Array of points of its own and fills it.
class AnswerFilled
  def initialize
    @points = Array.new(capacity: 4)
    2.times { |i| @points << AnswerPoint.new(i + 1, 0, 0) }
  end

  def count = @points.size

  WEIGHTS = [3, 4].freeze

  # A local summed over a Ruby Array, in a method game code calls: Ruby's own sum, while building.
  def weight
    sum = 0
    WEIGHTS.each { |each_weight| sum += each_weight }
    sum
  end

  # A local summed over a walk, in a method game code calls.
  def total_x
    sum = 0
    @points.each { |point| sum += point.x }
    sum
  end

  attr_reader :points

  # The same sum, walking what the build cannot read before the walk: the Array through its
  # reader, through a local, by a lambda handed with `&`, and through a helper that yields.
  def total_x_by_reader
    sum = 0
    points.each { |point| sum += point.x }
    sum
  end

  def total_x_by_local
    walked = @points
    sum = 0
    walked.each { |point| sum += point.x }
    sum
  end

  def total_x_by_lambda
    sum = 0
    add = ->(point) { sum += point.x }
    @points.each(&add)
    sum
  end

  def total_x_by_helper
    sum = 0
    each_point { |point| sum += point.x }
    sum
  end

  def each_point(&) = @points.each(&)
end

# A spot whose number never changes after it is made.
class AnswerSpot
  def initialize(x)
    @x = x
  end

  def left = @x - 1
end

# A counter that starts at 50, kept in the same instance variable as an AnswerCounter elsewhere.
class AnswerTallCounter
  def initialize
    @n = 50
  end

  def bump = @n += 1
end

# Keeps a counter with `||=` as it is made; nothing of its own changes.
class AnswerKeeper
  def initialize
    @inner ||= AnswerCounter.new
  end

  def bump = @inner.bump
end

# Makes its counter the first time it is asked; nothing of its own changes.
class AnswerLazyKeeper
  def initialize(x)
    @x = x
  end

  def counter = @counter ||= AnswerCounter.new
end

# Makes counters from class methods: one at once, or one a few calls down.
module AnswerCounters
  def self.make = AnswerCounter.new
  def self.make_deep = handed(make)
  def self.handed(counter) = counter
end

# Hands out counters from methods of its own: a new one, the one it was given, or none at all
# after making one it keeps nowhere.
class AnswerCounterShop
  def initialize(shared) = @shared = shared
  def fresh = AnswerCounters.make_deep
  def shared = @shared

  def lost
    AnswerCounters.make
    nil
  end
end

# Numbers queued in a plain Ruby Array, added to by whoever loads it.
class AnswerQueue
  def initialize = @cells = []

  def add(cells)
    @cells.concat(cells)
    cells.size
  end

  def size = @cells.size
end

# Loads an AnswerQueue from class methods: handing back how many went in, or nil.
module AnswerQueueing
  def self.load_two(queue) = queue.add([3, 4])

  def self.load_lost(queue)
    queue.add([5])
    nil
  end
end

# Blocks to run on each pass, kept in a plain Ruby Array.
class AnswerHooks
  def initialize
    @asked = []
  end

  def after(&asked)
    @asked << asked
  end

  def run = @asked.each(&:call)
end

# Hands an AnswerHooks a block that counts, as it is made.
class AnswerHooked
  def initialize(hooks)
    @n = 0
    hooks.after { @n += 1 }
  end

  attr_reader :n
end

# A fraction counted up, and asked for its whole part with a verb a game's number does not answer.
class AnswerFraction
  def initialize
    @x = 0.0
  end

  def step = @x += 0.5
  def whole = @x.floor
end

# Counts the parts made with it, in plain Ruby: a part made once while setting up is counted once.
class AnswerMadeCount
  def initialize
    @made = 0
  end

  def note = @made += 1

  attr_reader :made
end

# A part that counts itself made, and counts its hits as the game plays.
class AnswerNamed
  def initialize(made)
    made.note
    @id = made.made
    @hits = 0
  end

  def hit = @hits += 1

  attr_reader :id, :hits
end

# A door a method of its own opens outright, asked through a reader or for a number.
class AnswerLatch
  def initialize
    @open = false
  end

  def open! = @open = true
  def open? = @open
  def seen = @open ? 1 : 0
end

# A once-guard asked through a reader: the first step declares a routine, and every step calls it.
class AnswerPlanner
  def initialize(build)
    @build = build
    @planned = false
    @steps = 0
  end

  def planned? = @planned

  def step
    plan unless planned?
    @build.call(:answer_planner_count)
  end

  def plan
    @planned = true
    @build.func(:answer_planner_count) { @steps += 1 }
  end

  attr_reader :steps
end

# An object whose initialize pushes into Arrays it is handed, not its own.
class AnswerHanded
  def initialize(notes, points, x)
    notes << x
    points << AnswerPoint.new(x, 0, 0)
  end
end

# A part's Array made with room for things, which its class body puts nothing into: what goes in
# comes from a reopened class, a subclass, a module, or game code outside the class.
class AnswerFlock
  attr_reader :dots

  def initialize
    @dots = Array.new(capacity: 4)
  end

  def total_x = @dots.sum(&:x)
end

# The same class reopened, putting things into the Array.
class AnswerFlock
  def add(x) = @dots << AnswerPoint.new(x, 0, 0)
end

# A subclass putting things into its parent's Array.
class AnswerBigFlock < AnswerFlock
  def add_big(x) = @dots << AnswerPoint.new(x * 10, 0, 0)
end

# A module putting things into the Array of whatever includes it.
module AnswerFlocking
  def add_dot(x) = @dots << AnswerPoint.new(x, 1, 0)
end

# A class whose Array only the module fills.
class AnswerMixedFlock
  include AnswerFlocking
  attr_reader :dots

  def initialize
    @dots = Array.new(capacity: 4)
  end
end

# A part's Array of numbers, made with room and empty, which a method of its own class fills.
class AnswerNumbers
  def initialize
    @numbers = Array.new(capacity: 4)
  end

  def add(number) = @numbers << number
  def count = @numbers.size
  def total = @numbers.sum
end

# The same Array, handed whatever its caller made: the class shows no Struct, so it keeps numbers.
class AnswerHandedItems
  def initialize
    @items = Array.new(capacity: 4)
  end

  def add(item) = @items << item
  def count = @items.size
end

# Names noted while it is set up, never changed as the game plays, and asked about in game code.
class AnswerNoted
  AIMS = %i[move_to].freeze

  def initialize(scripts)
    @n = 0
    @used = []
    scripts.each { |names| @used |= names }
  end

  def reach = @n += (@used.intersect?(AIMS) ? 1 : 10)

  attr_reader :n
end

# Names a game method switches one of on every pass.
class AnswerSwitchedNames
  def initialize
    @n = 0
    @states = %i[shut shut]
  end

  def flip
    if @states[0] == :shut
      @states[0] = :open
    else
      @states[0] = :shut
    end
    @n += 1 if @states[0] == :open
    @n
  end

  attr_reader :n
end

# Names a game method adds to with `|=` on every pass.
class AnswerGrownNames
  def initialize
    @n = 0
    @used = %i[walk]
    @used |= %i[wait]
  end

  def grow
    @used |= %i[run]
    @n += @used.length
  end

  attr_reader :n
end

# The same names named with `game_variables`, so the game keeps them and sees each switch.
class AnswerNamedSwitchedNames
  game_variables :states

  def initialize
    @n = 0
    @states = %i[shut shut]
  end

  def flip
    if @states[0] == :shut
      @states[0] = :open
    else
      @states[0] = :shut
    end
    @n += 1 if @states[0] == :open
    @n
  end

  attr_reader :n
end

# A cursor game code moves on, whose selection other parts are handed. It is named, so it is a
# game variable from its first number and a part is handed the variable itself.
class AnswerCursor
  game_variables :selection

  def initialize = @selection = 3
  def step = @selection += 1

  attr_reader :selection
end

# Handed the cursor's selection as it is made, then given a number of its own in game code. In
# Ruby the holder keeps its own number, and the cursor's selection stays as it was.
class AnswerSelectionHolder
  def initialize(cursor) = @held = cursor.selection
  def keep = @held = 5
  def bump = @held += 10

  attr_reader :held
end

# A local a `var` line makes, handed to two instance variables as it is made; game code gives one
# a number of its own. In Ruby the other still holds the local's number.
class AnswerLocalHolder
  def initialize(build)
    kept = build.var(:answer_kept, 3)
    @held = kept
    @shown = kept
  end

  def keep = @held = 7

  attr_reader :held, :shown
end
