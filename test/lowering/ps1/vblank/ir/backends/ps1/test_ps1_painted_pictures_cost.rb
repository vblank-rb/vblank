# frozen_string_literal: true

require "test_helper"
require "stringio"

# What many small pictures a pass cost the PlayStation's processor, read from where Beetle PSX says the
# time went. Each picture is a draw mode and a textured rectangle, put in the list of drawing commands
# the DMA hands to the graphics chip (Runtime::DrawList), so the chip draws them while the processor
# works out the next. Fed to the chip's port by the processor, a command at a time, the processor waited
# for room in the chip's queue for every picture after the first few.
class TestPS1PaintedPicturesCost < Minitest::Test
  PICTURES = 300
  CHIP_WAIT = /\Art_(draw_list_\w+_wait|gp0_port_word_wait)\z/

  MANY_PICTURES = VBlank.game("PICTURE COST", consoles: %i[ps1]) do
    screen :bitmap, tear_free: true
    image(:dot, "#" => :white, "." => :red) { Array.new(8) { "#.#.#.#." }.join("\n") }
    game_loop do
      clear_screen :black
      repeat(PICTURES) { |i| blit :dot, (i * 7) % 300, (i * 3) % 220 }
    end
  end

  def test_three_hundred_pictures_leave_the_processor_most_of_each_frame
    rom = MANY_PICTURES.build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: 20)
    wait = result.runtime.select { |spent| spent.routine.to_s.match?(CHIP_WAIT) }.sum(&:share)

    assert_equal({ 1 => 20 }, result.passes_by_frames)
    assert_operator wait, :<, 0.01, "the processor waited on the graphics chip for #{wait.round(4)} of each frame"
    assert_operator result.idle_share, :>, 0.8, "the processor was left #{result.idle_share.round(4)} of each frame"
  end
end
