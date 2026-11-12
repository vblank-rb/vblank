# frozen_string_literal: true

# Parts of a game as plain classes holding a builder, brought in by `VBlank.require_game_file` for
# test/all/vblank/dsl/test_plain_ruby_parts.rb. None of them has a `var` of its own.
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
