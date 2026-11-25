# frozen_string_literal: true

# A part of a game that steps a count kept in a slot of halves in place, and copies it to another
# slot each round, as an unpacking routine counts the numbers it has written.
class SteppedCountPart
  def initialize(written, seen)
    @written = written
    @seen = seen
  end

  def count_up(rounds)
    @written[0] = 0
    n = 0
    while n < rounds
      @seen[n] = @written[0]
      @written[0] = @written[0] + 1
      n += 1
    end
  end
end
