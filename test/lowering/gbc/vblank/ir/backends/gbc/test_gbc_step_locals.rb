# frozen_string_literal: true

require "test_helper"

# A number the color's code keeps only while one line runs, such as which routine of a list a line
# calls or which digit or picture it draws, is kept in work memory, four bytes. Every line of a
# routine that keeps such a number shares the place (GBC::Lowering#keep_step_local), so a routine
# of a few hundred such lines takes four bytes for them, not a few hundred times four.
class TestGBCStepLocals < Minitest::Test
  LINES = 200

  # Lists that leave a little more work memory than a few numbers need, and less than a number
  # for each of lines lines.
  ROOM_BYTES = 4000
  MORE_BYTES = 1900

  # A game whose loop calls one of two routines lines times, each by a number it works out.
  private def many_calls_program
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      room = list :room, capacity: ROOM_BYTES, width: :byte, full_of: 0
      more = list :more, capacity: MORE_BYTES, width: :byte, full_of: 0
      n = var :n, 0
      calls = var :calls, 0
      func(:one) { calls += 1 }
      func(:two) { calls += 2 }
      game_loop do
        room[n & 7] = n
        more[n & 7] = calls
        n += 1
        LINES.times { |at| call %i[one two], number: (n + at) & 1 }
      end
    end
    b.finalize_program
    b.program
  end

  def test_many_lines_calling_a_worked_out_routine_fit_work_memory
    player = game_player.run(many_calls_program, frames: 4)

    assert_operator player[:calls], :>, LINES
  end

  # Digits and pictures picked by a number, many to a routine, each drawn as its own line says.
  private def painted_program
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :bitmap
      image(:dot, "#" => :red) { "##\n##" }
      image(:box, "#" => :blue, "." => :transparent) { "##\n#." }
      n = var :n, 0
      game_loop do
        n += 1
        12.times do |at|
          draw_number n + at, 8 * (at % 6), 8 * (at / 6), :white
          blit %i[dot box], 4 * at, 40, showing: (n + at) & 1
        end
      end
    end
    b.finalize_program
    b.program
  end

  # The run's player holds the cartridge's picture to the interpreter's after every pass.
  def test_digits_and_pictures_picked_line_by_line_draw_as_each_line_says
    player = game_player.run(painted_program, frames: 4)

    assert_operator player[:n], :>=, 3
  end
end
