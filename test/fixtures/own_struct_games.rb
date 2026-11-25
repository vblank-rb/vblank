# frozen_string_literal: true

# Games whose block gives a constant a value, for test/all/vblank/dsl/test_struct_array.rb. Only a
# block written in a module's body can: Ruby refuses a constant given a value inside a method.
module OwnStructGames
  CONSOLES = %i[gba gbc snes genesis ps1 dos].freeze

  # A spark made from a Struct the block makes itself, falling a pixel a pass.
  FALLING = VBlank.game("OWN STRUCT", consoles: CONSOLES) do
    Spark = Struct.new(:x, :y)
    sparks = Array.new(capacity: 4)
    started = 0
    game_loop do
      if started == 0
        sparks << Spark.new(5, 0)
        started = 1
      end
      sparks.each { |s| s.y += 1 }
    end
  end
end
