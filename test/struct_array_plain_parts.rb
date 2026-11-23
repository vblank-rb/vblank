# frozen_string_literal: true

# A Struct in a file brought in with `require`, which VBlank does not read as game code, for
# test/all/vblank/dsl/test_struct_array.rb: its method changes a field all the same.

# A drop falling by a method of its own, two pixels a pass.
PlainDrop = Struct.new(:x, :y) do
  def fall
    self.y += 2
  end
end
