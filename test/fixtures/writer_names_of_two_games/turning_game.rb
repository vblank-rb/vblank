# frozen_string_literal: true

VBlank.require_game_file "turner"

# One game of two, for test/all/vblank/dsl/test_plain_ruby_writer_names.rb: its part turns a dial
# up through the dial's writer, and game code reads the level before the line that turns it.
module WriterNamesTurningGame
  def self.game
    VBlank.game("TURNING", consoles: %i[gba gbc snes genesis ps1]) do
      dial = WriterNamesDial.new
      turner = WriterNamesTurner.new
      seen = 0
      game_loop do
        seen = dial.level
        turner.nudge(dial)
      end
    end
  end
end

