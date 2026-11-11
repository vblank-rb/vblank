# frozen_string_literal: true

require "test_helper"
require "stringio"

# What reading the pad costs a PlayStation game, read from where Beetle PSX says the time went. The pad
# is asked on every frame, a conversation of five bytes the port takes about a thousand cycles each to
# send. Sent from the frame's interrupt with a loop waiting on each, that held the game for a hundredth
# of every frame; the pad's own interrupt now carries the conversation on (Runtime::Pads), and the game
# works meanwhile. A game whose pass takes several frames is where that is felt, so one is measured.
class TestPS1PadCost < Minitest::Test
  PAD_ROUTINES = /\Art_(pad_|buttons_now)/

  # Work for more than a frame and under two, so every pass has a frame in its middle.
  TWO_FRAMES = VBlank.game("TWO FRAMES", consoles: %i[ps1]) do
    total = 0
    func(:too_much) { repeat(45_000) { total += 3 } }
    game_loop { call :too_much }
  end

  def test_reading_the_pad_takes_under_a_five_hundredth_of_a_frame
    rom = TWO_FRAMES.build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: 10)
    share = result.runtime.select { |spent| spent.routine.to_s.match?(PAD_ROUTINES) }.sum(&:share)

    assert_equal({ 2 => 10 }, result.passes_by_frames)
    assert_operator share, :<, 0.002, "the pad's routines took #{share.round(4)} of each frame; waiting on each byte took 0.010"
  end
end
