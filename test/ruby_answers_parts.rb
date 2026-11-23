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
