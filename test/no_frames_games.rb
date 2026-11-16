# frozen_string_literal: true

# A small game for each console's test of a run of no frames, which ends as the first pass does,
# before the runtime turns the screen on: the Super Nintendo's, the Genesis's and the PlayStation's.
module NoFramesGames
  # A tiled room in grey, and a count of the passes played (+n+), built for +console+.
  def self.room_counting_passes(console)
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :tiled
      image(:wall, "#" => :gray) { "########\n" * 8 }
      tiles :set, "#" => :wall
      background :room, tiles: :set, map: ["##", "##"]
      n = 0
      game_loop { n += 1 }
    end
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = console }
  end
end
