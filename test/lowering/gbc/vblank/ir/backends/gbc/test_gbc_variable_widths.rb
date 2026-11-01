# frozen_string_literal: true

require "test_helper"

# WHAT A KEPT WIDTH SAVES on the Color, whose processor works a byte at a time: the same game with
# and without `width:`, compared by the size of what it was made into.
class TestGBCVariableWidths < Minitest::Test
  GBC = VBlank::IR::Backends::GBC

  private def code_size(**kept)
    rom = VBlank.build("WIDTHS", console: :gbc) do
      flag = var :flag, 0, **kept
      speed = var :speed, 3, **kept
      turns = var :turns, 0, **kept
      game_loop do
        turns += 1 if flag == 2
        speed = speed + turns
        flag = 1 if speed > 40
        flag = 0
        wait_vblank
      end
    end
    rom.bytes.each_byte.count { |byte| !byte.zero? && byte != 0xFF } # what is not the cartridge's padding
  end

  def test_a_byte_is_read_written_and_compared_in_far_less_code
    assert_operator code_size(width: :byte), :<, code_size - 40
  end

  def test_a_game_that_says_nothing_keeps_its_bytes
    assert_equal code_size, code_size(width: :word)
  end
end
