# frozen_string_literal: true

# The Structs of test/all/vblank/dsl/test_struct_array.rb, brought in by
# `VBlank.require_game_file`, so their blocks are read as game code.

# A spark: where it is and how fast it falls.
Spark = Struct.new(:x, :y, :vy)

# A drop that falls by a method of its own, kept narrow, and drawn as a 2x2 white square.
Drop = Struct.new(:x, :y) do
  drawn_as :drop
  narrow :x, y: :half

  def fall
    self.y += 2
  end
end

# A thing made with keywords.
Coin = Struct.new(:x, :worth, keyword_init: true)

# Made with Data, whose fields cannot change.
Stone = Data.define(:x)

# A part keeping its things in an instance variable: three birds put in while it is set up, in a
# method of its own, each falling by its speed on every pass.
class FlockPart
  def initialize(builder)
    @birds = Array.new(capacity: 4)
    hatch
    builder.func(:flock_tick) { @birds.each { |bird| bird.y += bird.vy } }
  end

  def hatch
    3.times { |i| @birds << Spark.new(i * 10, 0, i + 1) }
  end
end

# A part that puts two eggs in while it is set up, and one more each time `lay` is called.
class HatcheryPart
  def initialize(_builder)
    @eggs = Array.new(capacity: 8)
    2.times { |i| @eggs << Spark.new(i, 0, 0) }
  end

  def lay = @eggs << Spark.new(9, 0, 0)
end

# A count that starts at 5 and goes up by one each time `bump` is called.
class KeptTally
  def initialize
    @count = 5
  end

  def bump = @count += 1

  attr_reader :count
end

# An object whose initialize pushes into Arrays it is handed, not its own.
class HandedPush
  def initialize(notes, sparks, x)
    notes << x
    sparks << Spark.new(x, 0, 0)
  end
end

# An arrow drawn facing right. Facing left, it is the same picture mirrored.
Arrow = Struct.new(:x, :y) do
  drawn_as facing: { right: :arrow }
end

# A tile in the layer at the back, and one in the layer at the front.
BackTile = Struct.new(:x, :y) do
  drawn_as :green_tile, layer: :back
end

FrontTile = Struct.new(:x, :y) do
  drawn_as :red_tile, layer: :front
end

# No place to draw at.
Flag = Struct.new(:color)
