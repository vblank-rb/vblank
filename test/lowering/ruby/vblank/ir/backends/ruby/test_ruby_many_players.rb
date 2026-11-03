# frozen_string_literal: true

require "test_helper"

# MORE PLAYERS THAN EIGHT, played as Ruby and checked against the interpreter on every frame
# (Ruby::CheckedRun). The Ruby runtime keeps a list of buttons, one entry per connected player,
# rather than one number for everybody, so a game for a crowd plays the same as on the
# interpreter. The players' buttons change from frame to frame, so a mix-up between two players'
# entries shows as a frame the two runs disagree on.
class TestRubyManyPlayers < Minitest::Test
  CheckedRun = VBlank::IR::Backends::Ruby::CheckedRun
  PLAYERS = 12

  private def crowd
    b = Builder.new
    b.instance_eval do
      places = (1..PLAYERS).map { |player| var(:"x#{player}", 0) }
      anyone = var(:anyone, 0)
      taps = var(:taps, 0)
      connected = var(:connected, 0)
      game_loop do
        places.each.with_index(1) { |x, player| x.increase!(player) if held(:right, player: player) }
        anyone.increase!(1) if held(:left, player: :any)
        taps.increase!(1) if pressed(:a, player: :any)
        connected.store!(players_connected)
      end
    end
    b.finalize_program
    b.program
  end

  # Player n holds right on the frames n divides, the last player taps A every third frame, and
  # player nine holds left from frame 6.
  private def buttons_on(frame)
    rights = (1..PLAYERS).select { |player| (frame % player).zero? }.map { |player| player == 1 ? :right : :"p#{player}_right" }
    rights << :"p#{PLAYERS}_a" if (frame % 3).zero?
    rights << :p9_left if frame >= 6
    rights
  end

  def test_twelve_players_play_the_same_as_on_the_interpreter
    run = CheckedRun.new.input_each_frame { |frame| buttons_on(frame) }.run(crowd, frames: 24)

    assert_equal 2 * 12, run[:x12], "player twelve moved on frames 12 and 24"
    assert_equal PLAYERS, run[:connected]
    assert_operator run[:taps], :>, 0
  end

  def test_one_player_holding_reads_one_player_connected
    run = CheckedRun.new.hold(:right).run(crowd, frames: 4)

    assert_equal 1, run[:connected]
    assert_equal 4, run[:x1]
  end
end
