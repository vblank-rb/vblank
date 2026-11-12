# frozen_string_literal: true

# PARTS OF A GAME THAT NAME THEIR VALUES, brought in by `VBlank.require_game_file` for
# test/all/vblank/dsl/test_plain_ruby_parts.rb. Each named shape has a twin keeping the same
# state in `var`, which is its answer key. Further down, plain Ruby a game runs while it builds,
# which stays Ruby's: nothing there is named, so nothing there is followed or refused.

# A NAMED VALUE IS THE GAME'S FROM ITS FIRST NUMBER ON, wherever game code reads it.

# Read in a block handed to another part, which calls it later, and set back by a method the game
# calls under a test. It counts 1, 2, 3, 4 and is set back to 0 at 4; the waiter counts each 2.
class EndWaiter
  def initialize(builder, prefix) = @ended = builder.var(:"#{prefix}_ended", 0)

  def step(&ends)
    @ended += 1 if ends.call
  end
end

module TitleStarting
  def step
    @waiter.step { @starting == 2 }
    if @starting == 0
      @starting = 1
    else
      @starting += 1
    end
    restart if @starting == 4
  end

  def restart
    @starting = 0
  end
end

class StartingTitlePart
  include TitleStarting
  game_variables :starting

  def initialize(builder)
    @starting = 0
    @waiter = EndWaiter.new(builder, :starting_title)
    builder.func(:starting_title_tick) { step }
  end
end

class StartingTitleWithVarPart
  include TitleStarting

  def initialize(builder)
    @starting = builder.var(:var_starting_title_starting, 0)
    @waiter = EndWaiter.new(builder, :var_starting_title)
    builder.func(:var_starting_title_tick) { step }
  end
end

# Read by other parts through `attr_reader`, and handed to another part as it is made.
module CursorMoving
  attr_reader :selection

  def move
    if @selection == 0
      @selection = 1
    else
      @selection = 0
    end
  end
end

class NamedCursor
  include CursorMoving
  game_variables :selection

  def initialize = @selection = 0
end

class VarCursor
  include CursorMoving

  def initialize(builder) = @selection = builder.var(:var_cursor_selection, 0)
end

class CursorBall
  def initialize(builder, prefix, selection:)
    @selection = selection
    @seen = builder.var(:"#{prefix}_ball_seen", 0)
  end

  def tick
    @seen += 1 if @selection == 1
  end
end

class CursorMenuPart
  def initialize(builder, prefix, cursor)
    ball = CursorBall.new(builder, prefix, selection: cursor.selection)
    @others = builder.var(:"#{prefix}_others", 0)
    builder.func(:"#{prefix}_tick") do
      cursor.move
      ball.tick
      @others += 1 if cursor.selection == 0
    end
  end
end

# Read and changed in one method, which a loading method also calls while setting up.
module Blinking
  def step
    @counter += 1
    if @counter == 2
      @counter = 0
      @step_index += 1
    end
    @shown = @step_index
  end

  def load_frames
    @counter = 0
    @step_index = 0
    step
  end

  def restart = load_frames
end

class BlinkPart
  include Blinking
  game_variables :step_index, :counter

  def initialize(builder)
    @shown = builder.var(:blink_shown, 0)
    restart
    builder.func(:blink_tick) { step }
  end
end

class BlinkWithVarPart
  include Blinking

  def initialize(builder)
    @shown = builder.var(:var_blink_shown, 0)
    @counter = builder.var(:var_blink_counter, 0)
    @step_index = builder.var(:var_blink_step_index, 0)
    restart
    builder.func(:var_blink_tick) { step }
  end
end

# A FADE WHOSE PHASE ONLY A HELPER CHANGES. `step` asks the phase in an if/elsif chain, and the one
# line that changes it in play is a private helper handed the new phase. It waits two passes, then
# fades in, counting a pass of fading each pass after. The twin keeps the phase in a `var`.
module PhaseStepping
  WAITING = 0
  FADING_IN = 1

  def step
    @frames += 1
    if @phase == WAITING
      go(FADING_IN) if @frames > 1
    elsif @phase == FADING_IN
      @fading += 1
    end
  end

  private

  def go(phase)
    @phase = phase
    @frames = 0
  end
end

class PhasedFadePart
  include PhaseStepping
  game_variables :phase

  def initialize(builder)
    @phase = WAITING
    @frames = builder.var(:phased_fade_frames, 0)
    @fading = builder.var(:phased_fade_fading, 0)
    builder.func(:phased_fade_tick) { step }
  end
end

class PhasedFadeWithVarPart
  include PhaseStepping

  def initialize(builder)
    @phase = builder.var(:var_phased_fade_phase, WAITING)
    @frames = builder.var(:var_phased_fade_frames, 0)
    @fading = builder.var(:var_phased_fade_fading, 0)
    builder.func(:var_phased_fade_tick) { step }
  end
end

# THE SAME FADE MADE INSIDE A ROUTINE, as a game makes a screen inside its scene, so `initialize`
# runs while game code is recorded. Its `@phase = WAITING` is the phase's start, not a line the
# game runs on every pass. Each screen changes the phase another way. The routine runs on every
# pass and makes its screen once, as it is recorded; the answer key is the same screen made while
# setting up, outside the routine.
module ScreenStepping
  WAITING = 0
  FADING_IN = 1

  def start(builder, prefix)
    @frames = builder.var(:"#{prefix}_frames", 0)
    @fading = builder.var(:"#{prefix}_fading", 0)
  end

  def step
    @frames += 1
    if @phase == WAITING
      fade_in if @frames > 1
    elsif @phase == FADING_IN
      @fading += 1
    end
  end
end

# A private helper with a body, handed the phase.
class HelperScreen
  include ScreenStepping
  game_variables :phase

  def initialize(builder, prefix)
    @phase = WAITING
    start(builder, prefix)
  end

  private

  def fade_in = go(FADING_IN)

  def go(phase)
    @phase = phase
    @frames = 0
  end
end

# An endless helper.
class EndlessHelperScreen
  include ScreenStepping
  game_variables :phase

  def initialize(builder, prefix)
    @phase = WAITING
    start(builder, prefix)
  end

  private

  def fade_in = go(FADING_IN)

  def go(phase) = (@phase = phase; @frames = 0)
end

# Its own attribute writer.
class WriterScreen
  include ScreenStepping
  game_variables :phase
  attr_writer :phase

  def initialize(builder, prefix)
    @phase = WAITING
    start(builder, prefix)
  end

  private

  def fade_in
    self.phase = FADING_IN
    @frames = 0
  end
end

# Another object's setter: a director moves the screen on.
class DirectedScreen
  include ScreenStepping
  game_variables :phase
  attr_accessor :phase, :frames

  def initialize(builder, prefix)
    @phase = WAITING
    start(builder, prefix)
    @director = ScreenDirector.new(self)
  end

  private

  def fade_in = @director.fade_in
end

class ScreenDirector
  def initialize(screen) = @screen = screen

  def fade_in
    @screen.phase = ScreenStepping::FADING_IN
    @screen.frames = 0
  end
end

class ScreenInPlayPart
  def initialize(builder, screen_class, prefix, made_in_play:)
    screen = screen_class.new(builder, prefix) unless made_in_play
    builder.func(:"#{prefix}_tick") do
      (made_in_play ? screen_class.new(builder, prefix) : screen).step
    end
  end
end

# A NAMED HASH OF NUMBERS: a game variable for each key, keyed by a side known while building. The
# left counter counts every pass and the right one once the left passes 1; a pass with a counter
# past 2 counts as over. The twin keeps a `var` for each side, made in a loop.
module TiltCounting
  SIDES = %i[left right].freeze

  def count_tilts
    SIDES.each do |side|
      @tilt_counters[side] += 1 if side == :left || @tilt_counters[:left] > 1
      @over += 1 if @tilt_counters[side] > 2
    end
  end
end

class TiltCountersPart
  include TiltCounting
  game_variables :tilt_counters

  def initialize(builder)
    @tilt_counters = SIDES.to_h { |side| [side, 0] }
    @over = builder.var(:tilt_counters_over, 0)
    builder.func(:tilt_counters_tick) { count_tilts }
  end
end

class TiltCountersWithVarPart
  include TiltCounting

  def initialize(builder)
    @tilt_counters = SIDES.to_h { |side| [side, builder.var(:"var_tilt_counters_#{side}", 0)] }
    @over = builder.var(:var_tilt_counters_over, 0)
    builder.func(:var_tilt_counters_tick) { count_tilts }
  end
end

# A named Array of numbers, at an index the game works out: refused at the line.
class CountsByNumberPart
  game_variables :counts

  def initialize(builder)
    @counts = [0, 0]
    @which = builder.var(:counts_by_number_which, 1)
    builder.func(:counts_by_number_tick) { @counts[@which] += 1 }
  end
end

# FIELDS OF A STRUCT. A box a part keeps, its `count` named in the block of `Struct.new` and its
# `step` left plain, read only. Counted by two until it passes 5, under a test the game makes,
# so 6 after three passes; the twin keeps the same count in a `var`.
CountingBox = Struct.new(:count, :step) do
  game_variables :count
end

PlainCountingBox = Struct.new(:count, :step)

module BoxCounting
  def count_up
    @box.count += @box.step if @box.count < 5
    @seen = @box.count
  end
end

class BoxCountPart
  include BoxCounting

  def initialize(builder)
    @box = CountingBox.new(0, 2)
    @seen = builder.var(:box_count_seen, 0)
    builder.func(:box_count_tick) { count_up }
  end
end

class BoxCountWithVarPart
  include BoxCounting

  def initialize(builder)
    @box = PlainCountingBox.new(builder.var(:box_var_count, 0), 2)
    @seen = builder.var(:box_var_count_seen, 0)
    builder.func(:box_var_count_tick) { count_up }
  end
end

# A subclass of a Struct naming its field in its own body, holding a symbol: a game state.
class ModeBox < Struct.new(:mode)
  game_variables :mode
end

class ModeBoxPart
  def initialize(builder)
    @box = ModeBox.new(:resting)
    @turns = builder.var(:mode_box_turns, 0)
    builder.func(:mode_box_tick) do
      @turns += 1 if @box.mode == :moving
      @box.mode = :moving
    end
  end
end

# A gauge whose attributes are made from a list of names: they reach the named instance variable
# as written-out ones do, so another part counts it as the game plays.
class ListedGauge
  LEVELS = %i[level].freeze
  game_variables :level
  attr_accessor(*LEVELS)

  def initialize = @level = 0
end

class ListedGaugePart
  def initialize(builder)
    gauge = ListedGauge.new
    @seen = builder.var(:listed_gauge_seen, 0)
    builder.func(:listed_gauge_tick) do
      gauge.level += 1
      @seen = gauge.level
    end
  end
end

# A class reopened to name one more: both are followed, each counted on every pass.
class ReopenedCounter
  game_variables :ups

  def initialize(builder)
    @ups = 0
    @downs = 0
    @seen = builder.var(:reopened_counter_seen, 0)
    builder.func(:reopened_counter_tick) do
      @ups += 1
      @downs += 2
      @seen = @ups + @downs
    end
  end
end

class ReopenedCounter
  game_variables :downs
end

# `game_variables` in a method of a module, where it can name nothing.
module NamedInMethod
  def self.name_them = game_variables(:shown)
end

# BUILD-TIME RUBY INSIDE CODE RECORDED AS GAME CODE: a part made inside a routine, whose making
# runs plain Ruby to plan what it builds. None of it is named, so none of it is followed or
# refused, and it plays as Ruby works it out.
#
# A class method counting loads that fit a budget, a local changed in `map` over a list.
module LoadPlanning
  BUDGET_BYTES = 10
  BYTES_PER_LOAD = 2

  def self.plan(loads)
    budget = 0
    loads.map do |_, size|
      fits = budget + size < BUDGET_BYTES
      budget = (fits ? budget : 0) + size + BYTES_PER_LOAD
      fits ? 0 : 1
    end
  end
end

# The same planning, in other shapes: `each` and `to_h` over a list, `times`, a Hash and an Array
# built and filled in, a ternary, a constant list, a lambda the planning makes and calls itself,
# and a Struct's field. Each counts to a number the test knows.
module MorePlanning
  SIZES = [4, 4, 4].freeze
  Plan = Struct.new(:count)

  def self.counted_by_each
    total = 0
    SIZES.each { |size| total += size }
    total
  end

  def self.counted_by_to_h
    seen = 0
    SIZES.each_with_index.to_h { |size, index| seen += 1; [index, size] }.size + seen
  end

  def self.counted_by_times
    rounds = 0
    3.times { rounds += 2 }
    rounds
  end

  def self.filled_in
    table = {}
    list = []
    SIZES.each_with_index do |size, index|
      table[index] = size
      list << (size > 3 ? 1 : 0)
      table[index] += 1
    end
    table[0] + table[1] + table[2] + list[0] + list[1] + list[2]
  end

  def self.counted_in_struct
    plan = Plan.new(0)
    plan.count += 1
    plan.count += plan.count
    plan.count
  end

  def self.by_own_lambda
    count = 0
    bump = -> { count += 1 }
    bump.call
    bump.call
    count
  end
end

# A buffer of cells, rows of a plain 2-D Array, filled in by a method that plans what to draw. It
# is made and filled while a routine is recorded, and nothing the game runs reads it.
class CellBuffer
  BUFFER_COLUMNS = 3

  def initialize = @rows = Array.new(2) { Array.new(BUFFER_COLUMNS, 0) }

  def put(at, cell)
    @rows[at / BUFFER_COLUMNS][at % BUFFER_COLUMNS] = cell
  end

  def total = @rows.sum(&:sum)
end

class PlannedLoadsPart
  LOADS = [[:a, 4].freeze, [:b, 4].freeze, [:c, 4].freeze].freeze

  def initialize(builder, prefix)
    planned = [LoadPlanning.plan(LOADS).sum, MorePlanning.counted_by_each, MorePlanning.counted_by_to_h,
               MorePlanning.counted_by_times, MorePlanning.filled_in, MorePlanning.by_own_lambda,
               MorePlanning.counted_in_struct, own_count, filled_buffer]
    @answers = builder.list(:"#{prefix}_answers", capacity: planned.length, full_of: 0)
    planned.each_with_index { |answer, index| @answers[index] = answer }
  end

  # An unnamed count of its own, changed and read back by a method `initialize` calls.
  def own_count
    @steps = 0
    @steps += 3
    @steps + @steps
  end

  def filled_buffer
    buffer = CellBuffer.new
    6.times { |at| buffer.put(at, at) }
    buffer.total
  end
end

# The buffer filled by a plan that runs once, from the method a routine's body calls, as a game's
# end-of-ball bonus plans its rows: 0 + 1 + ... + 5 in its cells.
class BufferedPlanPart
  def initialize(builder)
    @builder = builder
    @buffer = CellBuffer.new
    @planned = false
    builder.func(:buffered_plan_tick) { step }
  end

  def step
    plan unless @planned
  end

  def plan
    @planned = true
    6.times { |at| @buffer.put(at, at) }
    @builder.var(:buffered_plan_total, @buffer.total)
  end
end

class PlanInPlayPart
  def initialize(builder, prefix)
    builder.func(:"#{prefix}_tick") { PlannedLoadsPart.new(builder, prefix) }
  end
end
