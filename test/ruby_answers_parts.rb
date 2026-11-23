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

# An object whose initialize pushes into Arrays it is handed, not its own.
class AnswerHanded
  def initialize(notes, points, x)
    notes << x
    points << AnswerPoint.new(x, 0, 0)
  end
end
