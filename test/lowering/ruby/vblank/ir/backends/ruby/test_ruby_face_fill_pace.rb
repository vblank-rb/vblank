# frozen_string_literal: true

require "test_helper"
require "place_games"

# HOW FAST A GAME BUILT AS RUBY FILLS THE FACES OF A PLACE. A 3D place is filled a pixel at a time
# in Ruby, and a floor of a few hundred faces in view fills most of the lower half of the screen on
# every pass. What the runtime asks for each pixel of a face (where it lands, whether a fade or a mix
# or a kept picture changes it, which shade of colour it takes) is the whole cost of a pass, so the
# usual row, with none of those in force, is checked once and its pixels stored straight into the
# picture (rg_face_row). This holds a pass of PlaceGames.big_floor to a time well inside the
# console's frame, measured on this run's Ruby with YJIT, nothing capping the pace. The picture is
# held to the interpreter's by the place tests this run plays; this is only the time.
class TestRubyFaceFillPace < Minitest::Test
  # The longest a pass of the big floor may take. The console shows a picture every sixtieth of a
  # second, and a game drawing a place does much besides. On the machine the suite runs on a pass
  # takes about three quarters of this, and took a quarter more than this before each row was
  # painted plain; the margin is for the other test processes sharing its cores.
  MOST_SECONDS_A_PASS = 0.009

  PASSES = 20
  TRIES = 5
  WARMING_PASSES = 60 # played first, so YJIT has compiled the fill before it is timed

  private def seconds_playing(game, frames)
    player = VBlank::Original::Unpacking::FrameLimitedPlayer.new(frames)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    game.play(player)
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end

  # The time one more pass takes, with what starting the game takes taken away: the quickest of a
  # few tries, so a moment the machine was busy elsewhere does not count.
  private def seconds_a_pass(program)
    game = -> { VBlank::IR::Backends::Ruby.new.live_game(program) }
    seconds_playing(game.call, WARMING_PASSES)
    Array.new(TRIES) do
      (seconds_playing(game.call, PASSES + 2) - seconds_playing(game.call, 2)) / PASSES
    end.min
  end

  def test_a_pass_of_a_big_floor_fills_well_inside_the_consoles_frame
    assert RubyVM::YJIT.enabled?, "The Ruby run plays with YJIT (Testing::Lowering::RUNS), and this one has none"
    assert_operator seconds_a_pass(PlaceGames.big_floor(perspective: :every_16_pixels)), :<, MOST_SECONDS_A_PASS
  end
end
