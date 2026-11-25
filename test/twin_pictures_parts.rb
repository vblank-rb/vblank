# frozen_string_literal: true

# The Struct of test/lowering/gba/vblank/diagnostics/test_sprite_pictures.rb, brought in by
# `VBlank.require_game_file`, so its block is read as game code.

# A thing that faces :near or :far, two pictures of one block a tile apart on their canvas.
TwinThing = Struct.new(:x, :y) do
  drawn_as facing: { near: :near, far: :far }
end
