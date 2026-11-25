# frozen_string_literal: true

# A Struct in a file brought in with `require`, which VBlank does not read as game code, for
# test/all/vblank/dsl/test_struct_array.rb: its method changes a field all the same.

# A drop falling by a method of its own, two pixels a pass.
PlainDrop = Struct.new(:x, :y) do
  def fall
    self.y += 2
  end
end

# A mover whose step asks a test the game makes, with Ruby's own `?:`: a pixel a pass up to x 5,
# then three.
PlainMover = Struct.new(:x) do
  def step = self.x += speed

  def speed = x > 5 ? 3 : 1
end

# A number with a fraction, from a method's answer, which the build cannot see is one.
module PlainSpeeds
  def self.half(builder) = builder.var(:half, 0.5)
end

# A method made with `define_method`, whose block cannot be read as a method of game code.
PlainBlockMover = Struct.new(:x) do
  define_method(:step) { self.x += 1 }
end
