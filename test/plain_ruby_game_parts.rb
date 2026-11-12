# frozen_string_literal: true

# Parts of a game as plain classes holding a builder, brought in by `VBlank.require_game_file` for
# test/all/vblank/dsl/test_plain_ruby_parts.rb. The first few have no `var` of their own; further
# down, each part keeping its state in instance variables named by `game_variables` has a twin
# keeping the same state in `var`, which is its answer key.
class CounterPart
  def initialize(builder)
    @builder = builder
    declare
  end

  private

  def declare
    builder = @builder
    count = builder.var(:counter_count, 0)
    builder.func(:counter_tick) { count = count + 1 }
  end
end

class SparklePart
  def initialize(builder)
    @builder = builder
    declare
  end

  private

  def declare
    builder = @builder
    glint = nil
    builder.func(:sparkle_make) do
      glint = builder.var(:sparkle_glint, 0)
      glint = 7
    end
  end
end

class TallyPart
  def initialize(builder)
    @builder = builder
    declare
  end

  private

  def declare
    builder = @builder
    tally = 3
    builder.func(:tally_tick) { tally += 1 }
    builder.func(:tally_show) { builder.var(:tally_seen, 0).store!(tally) }
  end
end

class SeveralOfOnePart
  def initialize(builder, routine)
    ticks = 0
    builder.func(routine) { ticks += 1 }
  end
end

# Methods of the game file's own, called bare from a game block, so their verbs are the builder's.

# A name set to nil on every call and given a number in a block after it is read: each call reads
# nil, which as a number is 0.
def nil_read_before_numbered(numbered, answers, pass)
  held = nil
  answers[pass] = held
  repeat(1) { held = numbered }
end

# A total worked out from what the method is handed, so the line that starts it starts it at a
# different number on each call.
def total_from_double(start)
  total = start * 2
  repeat(2) { total += 1 }
  total
end

# A count of this file's, with a method of another file (steps_taken_by_bare_repeat, in
# test/plain_ruby_loop_parts.rb) called before it is read. That method's local of the same name is
# its own, so this one still holds +rounds+.
def steps_taken_beside_other_files(rounds)
  steps_taken = 0
  repeat(rounds) { steps_taken += 1 }
  steps_taken_by_bare_repeat(2)
  steps_taken
end

# A method's argument, a game variable the caller hands it, read and then changed under a test the
# game makes, in a loop of Ruby's written out twice. As in Ruby, the argument is the method's own
# copy: the caller's variable is left as it was, and the copy counts the rounds whose test held.
def argument_counted_in_ruby_loop(counter, pass, seen)
  round = 0
  while round < 2
    seen.store!(counter)
    counter += 1 if pass == round
    round += 1
  end
  counter
end

class TwoNamesPart
  def initialize(builder)
    @builder = builder
    declare
  end

  private

  def declare
    builder = @builder
    first, second = builder.var(:unpacked_first, 1), builder.var(:unpacked_second, 2)
    builder.func(:unpacked_tick) do
      first += 1
      second = first
    end
  end
end

# A tilt: `@busy` is tested above the lines that change it, so the test
# asks the number the pass before left. It is busy after passes 2 and 4, so it acts on 3 and 5.
module TiltHandling
  def handle
    @acted += 1 if @busy == 1
    @passes += 1
    @busy = 0
    @busy = 1 if @passes == 2 || @passes == 4
  end
end

class TiltPart
  include TiltHandling
  game_variables :busy

  def initialize(builder)
    @busy = 0
    @passes = builder.var(:tilt_passes, 0)
    @acted = builder.var(:tilt_acted, 0)
    builder.func(:tilt_handle) { handle }
  end
end

class TiltWithVarPart
  include TiltHandling

  def initialize(builder)
    @busy = builder.var(:tilt_var_busy, 0)
    @passes = builder.var(:tilt_var_passes, 0)
    @acted = builder.var(:tilt_var_acted, 0)
    builder.func(:tilt_var_handle) { handle }
  end
end

# A random draw: shifts and sums of both seeds, read before they change.
module SeedDrawing
  WORD = 0xFFFF

  def draw
    product = (@seed_low << 5) + (@seed_low << 3) + @seed_low
    @seed_low = (product + 7) & WORD
    @seed_high = (@seed_high + @seed_low) & WORD
    @drawn = @seed_high
  end
end

class SeedPart
  include SeedDrawing
  game_variables :seed_low, :seed_high

  def initialize(build)
    @seed_low = 3
    @seed_high = 5
    @drawn = build.var(:seed_drawn, 0)
    build.func(:seed_draw) { draw }
  end
end

class SeedWithVarPart
  include SeedDrawing

  def initialize(build)
    @seed_low = build.var(:seed_var_low, 3)
    @seed_high = build.var(:seed_var_high, 5)
    @drawn = build.var(:seed_var_drawn, 0)
    build.func(:seed_var_draw) { draw }
  end
end

# Two of one part, each counting in an instance variable of its own.
class TickerPart
  game_variables :ticks

  def initialize(builder, routine)
    @ticks = 0
    builder.func(routine) { @ticks += 1 }
  end
end

# A subclass changing what its parent names, and naming one of its own.
class FastTiltPart < TiltPart
  game_variables :nudges

  def initialize(builder)
    super
    @nudges = 0
    @nudged = builder.var(:fast_tilt_nudged, 0)
    builder.func(:fast_tilt_nudge) { nudge }
  end

  def nudge
    @nudges += 1 if @busy == 1
    @nudged = @nudges
  end
end

# A lamp another part turns on and off through its attributes.
class LampPart
  game_variables :lit, :brightness
  attr_accessor :lit
  attr_reader :brightness
  attr_writer :brightness

  def initialize
    @lit = 0
    @brightness = 2
  end
end

class LampSwitchPart
  def initialize(builder, lamp)
    @ons = builder.var(:lamp_ons, 0)
    @glow = builder.var(:lamp_glow, 0)
    builder.func(:lamp_flip) do
      if lamp.lit == 0
        lamp.lit = 1
        lamp.brightness += 1
      else
        lamp.lit = 0
      end
      @ons += 1 if lamp.lit == 1
      @glow = lamp.brightness
    end
  end
end

# The tilt again, with `@busy` named nowhere: the build stops at the line that changes it.
class UnnamedTiltPart
  include TiltHandling

  def initialize(builder)
    @busy = 0
    @passes = builder.var(:unnamed_tilt_passes, 0)
    @acted = builder.var(:unnamed_tilt_acted, 0)
    builder.func(:unnamed_tilt_handle) { handle }
  end
end

# A count changed in game code and read back after it, in a test, with nothing named.
class UnnamedCountPart
  def initialize(builder)
    @frames = 0
    @late = builder.var(:unnamed_count_late, 0)
    builder.func(:unnamed_count_tick) do
      @frames += 1
      @late += 1 if @frames > 2
    end
  end
end

# Instance variables changed only while building, or changed in game code and never read back, or
# given a number outright by game code before it reads them: none of them refused, and each plays
# as Ruby would.
class BuildTimeCountsPart
  def initialize(builder)
    @made = 0
    @hits = builder.var(:build_counts_hits, 0)
    @rows_seen = builder.var(:build_counts_rows, 0)
    3.times { make_spark }
    lay_out(2)
    builder.func(:build_counts_tick) { tick(builder) }
  end

  # A counter that makes names, bumped while setting up.
  def make_spark
    @made += 1
    @spark_name = :"spark_#{@made}"
  end

  # A count a setting-up method works out, used as Ruby's count in game code.
  def lay_out(count)
    @count = count + 1
  end

  def tick(builder)
    builder.repeat(@count) { @hits += 1 }
    @count.times { @hits += 1 }
    @last_tick = 5
    @rows = 2
    @rows.times { @rows_seen += 1 }
    @named = 0
    @named += 1
    builder.var(:"tick_#{@named}", 0)
    lay_out_once
  end

  # A flag that keeps a method's work to its first call, read while it holds nil.
  def lay_out_once
    return if @laid_out

    @laid_out = true
  end
end

# One routine gives `@mode` a number and another tests it, with nothing named: the game can run them
# in either order, so the test would be decided from whichever ran first while building.
class UnnamedAcrossRoutinesPart
  def initialize(builder)
    @mode = 0
    @seen = builder.var(:across_routines_seen, 0)
    builder.func(:across_routines_set) { @mode = 1 }
    builder.func(:across_routines_test) { @seen += 1 if @mode == 1 }
  end
end

# A module naming its own instance variable, and a class taking it in.
module HeldCounting
  game_variables :held

  def hold
    @held += 1
    @held_seen = @held
  end
end

class HolderPart
  include HeldCounting

  def initialize(builder)
    @held = 0
    @held_seen = builder.var(:holder_held, 0)
    builder.func(:holder_hold) { hold }
  end
end

# A named instance variable game code reads before anything gives it a number.
class UnsetNamedPart
  game_variables :aim

  def initialize(builder)
    @hits = builder.var(:unset_named_hits, 0)
    builder.func(:unset_named_tick) { @hits += 1 if @aim == 1 }
  end
end
