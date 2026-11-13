# frozen_string_literal: true

require "test_helper"

# A TINTED PICTURE, READ BY THE RUBY RUNTIME. A tint (or a fade) is over the whole picture on every
# pass of a game that keeps one in force, as a Super Nintendo game keeps its screen's brightness, and
# the runtime turns each pixel of the picture through the tint's table as it hands the picture over.
# The table is a Hash, and the runtime used to look each pixel up in it one at a time, a call
# into Ruby's C each: as many calls a pass as the screen has pixels. A row with no mixed cell is
# now turned through the table as one. The count is the Hash lookups and the blocks called in one
# more pass, which is exact where a time is not; the picture is held to the interpreter by the
# tint and fade tests this run plays.
class TestRubyTintedPictureCost < Minitest::Test
  SCREEN_PIXELS = 240 * 160

  private def calls_playing(program, frames)
    game = VBlank::IR::Backends::Ruby.new.live_game(program)
    player = VBlank::Original::Unpacking::FrameLimitedPlayer.new(frames)
    calls = 0
    counting = TracePoint.new(:c_call, :b_call) do |call|
      calls += 1 if call.event == :b_call || (call.method_id == :[] && call.defined_class == Hash)
    end
    counting.enable { game.play(player) }
    calls
  end

  # The lookups and blocks one more pass makes, with what starting the game makes taken away.
  private def calls_a_pass(program)
    (calls_playing(program, 12) - calls_playing(program, 2)) / 10
  end

  # A field that scrolls every pass, so the picture is new every pass, under a tint held still.
  private def tinted_field
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gba))
    b.instance_eval do
      screen :tiled
      image(:field_art, "#" => :green, "." => :blue, "o" => :white) { (["#.o.#.o."] * 8).join("\n") }
      tiles :field_tiles, "a" => :field_art
      field = background :field, tiles: :field_tiles, map: Array.new(32) { "a" * 32 }
      across = var :across, 0
      tint :red, 30
      game_loop do
        across += 1
        field.scroll_to across, 0
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_tinted_picture_looks_up_fewer_colors_a_pass_than_it_has_pixels
    assert_operator calls_a_pass(tinted_field), :<, SCREEN_PIXELS / 4
  end
end
