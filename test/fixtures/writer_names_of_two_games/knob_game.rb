# frozen_string_literal: true

VBlank.require_game_file "knob"

# The other game, for test/all/vblank/dsl/test_plain_ruby_writer_names.rb: its knob has a `level`
# writer too, and nothing in this game changes it.
module WriterNamesKnobGame
  def self.game
    VBlank.game("KNOB", consoles: %i[gba gbc snes genesis ps1]) do
      knob = WriterNamesKnob.new
      seen = 0
      game_loop { seen = knob.level }
    end
  end
end
