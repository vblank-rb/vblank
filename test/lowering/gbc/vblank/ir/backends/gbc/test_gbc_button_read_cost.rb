# frozen_string_literal: true

require "test_helper"
require "stringio"

# A BUTTON NAMED IN THE PROGRAM, asked whether it is held or was pressed, is a byte read and a bit
# tested where the game asks, as the console's own games test their joypad byte (Pan Docs, "Joypad
# Input": the buttons are read once a frame into a byte, a bit each). The frame's one read of the
# buttons stays where it is; what is measured is each test of a button after it.
class TestGBCButtonReadCost < Minitest::Test
  # A frame of the Color at double speed in the profiler's units, a quarter of an instruction cycle:
  # 154 lines of 228 instruction cycles.
  UNITS_A_FRAME = 154 * 228 * 4

  # Thirty-six tests a pass, as many as a busy game makes (each of the eight buttons in turn).
  TESTS = 36

  # A load of the byte, a test of its bit and the jump past the branch: four, two and three
  # instruction cycles, four units each. The budget is those nine, 36 units, with room for a jump
  # the branch may add.
  MOST_UNITS_A_TEST = 48

  NOTHING_PRESSED = VBlank::Playthroughs::Tape.parse(<<~TAPE)
    vblank tape 1
    recorded on: HELD 0x00000000
    starts from: power-on
  TAPE

  def test_a_held_button_is_a_bit_tested_where_it_is_asked
    units = units_a_test(:held)
    assert_operator units, :<=, MOST_UNITS_A_TEST, "a held test cost #{units.round(1)} units"
  end

  def test_a_pressed_button_is_a_bit_tested_where_it_is_asked
    units = units_a_test(:pressed)
    assert_operator units, :<=, MOST_UNITS_A_TEST, "a pressed test cost #{units.round(1)} units"
  end

  # What one test of a button costs a pass, against the same game with none.
  private def units_a_test(read)
    (awake_units_a_pass(buttons_game(read, TESTS)) - awake_units_a_pass(buttons_game(read, 0))) / TESTS.to_f
  end

  private def awake_units_a_pass(program)
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(program, title: "HELD")
    result = rom.profile(out: StringIO.new, tape: NOTHING_PRESSED, frames: 10..39)
    units = result.readings.sum { |reading| reading.awake_share * UNITS_A_FRAME }
    units / result.readings.sum { |reading| reading.passes_ended.to_i }
  end

  # +tests+ tests a pass of +read+ (:held or :pressed), each button in turn, each counting.
  private def buttons_game(read, tests)
    buttons = %i[a b select start right left up down] # the Color's eight
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      count = var :count, 0
      game_loop do
        tests.times do |i|
          button = buttons[i % buttons.length]
          count += 1 if read == :held ? held(button) : pressed(button)
        end
      end
    end
    b.finalize_program
    b.program
  end
end
