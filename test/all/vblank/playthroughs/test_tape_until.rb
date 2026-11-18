# frozen_string_literal: true

require "test_helper"
require "stringio"

# GAMES WITH STRETCHES THE COUNT DOES NOT MOVE ON, for a tape of passes and its `until` steps: a title
# that waits for a press of start, a fade to black that keeps to the frame and is longer on one build
# than on the other, a tally that counts down once a frame and is skipped with a press of A, then the
# play, where the game adds to :steps once a pass. Counted in :steps, the presses before the play
# are not on the tape, so only a step that waits on the game can take a tape past them.
module TapeUntilGames
  TITLE = 0
  FADING = 1
  TALLY = 2
  PLAYING = 3
  TALLY_FRAMES = 40

  # The game unbuilt, for the ways that run it themselves.
  private def until_game(fade_step:)
    program = declared_until_game(fade_step).checked_program(err: StringIO.new)
    VBlank::Playthroughs::UnbuiltGame.new(program, title: "UNTIL", source: "until #{fade_step}")
  end

  # The game built into a cartridge, for the emulator.
  private def until_cartridge(fade_step:) = declared_until_game(fade_step).build_rom(out: StringIO.new, err: StringIO.new)

  private def declared_until_game(fade_step)
    VBlank.game("UNTIL", consoles: %i[gba]) do
      screen = var :screen, TITLE
      level = var :level, 0
      tally = var :_tally_showing, 0
      steps = var :steps, 0
      x = var :x, 0
      game_loop do
        if screen == TITLE
          screen = FADING if pressed(:start)
        elsif screen == FADING
          once_a_frame { level += fade_step }
          fade :black, level
          if level >= 100
            fade :black, 0
            tally = TALLY_FRAMES
            screen = TALLY
          end
        elsif screen == TALLY
          once_a_frame do
            tally -= 1 if tally.positive?
            tally = 0 if pressed(:a)
          end
          screen = PLAYING if tally.zero?
        else
          steps += 1
          x += 1 if held(:right)
        end
      end
    end
  end

  private def quick_fade = until_game(fade_step: 25)
  private def slow_fade = until_game(fade_step: 3)

  # Start until the fade begins, nothing pressed until it ends, A until the tally is gone, then five
  # steps of the play walking right.
  private def to_the_play
    VBlank::Playthroughs::Playthrough.new("to the play") do
      repeat_until(:screen, is: FADING) { press :start }
      repeat_until :screen, is: TALLY
      repeat_until(:_tally_showing, is: 0) { press :a }
      hold :right, frames: 5
      moment :walked
      wait frames: 2
    end
  end
end

# A TAPE OF PASSES PAST STRETCHES ITS COUNT DOES NOT MOVE ON: each `until` step goes on the tape as
# itself, so the tape waits for the game on every build, however long its fade.
class TestTapeUntil < Minitest::Test
  # The ways a playthrough runs a game on are a table of procs (LoweredGame::RUNS) that only the main
  # Ractor can read, as for every playthrough played on one.
  runs_on_the_main_ractor!
  include TapeUntilGames

  private def recorded = to_the_play.play(quick_fade, in_passes: :steps, on: "interpreter").tape

  def test_a_tape_of_until_steps_plays_to_the_play_on_a_build_with_a_longer_fade
    played = recorded.play(slow_fade, on: "interpreter")

    assert_equal PLAYING, played.game.var(:screen)
    assert_equal 5, played.game.var(:x)
    assert_equal 7, played.game.var(:steps)
  end

  def test_the_frames_the_same_presses_took_on_the_other_build_do_not_reach_the_play
    in_frames = to_the_play.play(quick_fade, on: "interpreter").tape
    played = in_frames.play(slow_fade, on: "interpreter")

    refute_equal 5, played.game.var(:x)
  end

  def test_a_moment_after_until_steps_names_its_step
    assert_equal({ walked: 5 }, recorded.moments)
  end

  def test_the_tape_writes_each_until_step_as_a_line_and_reads_it_back
    text = recorded.to_s

    assert_includes text, "\nuntil screen is 1: 1 start, 1 -\n"
    assert_includes text, "\nuntil screen is 2\n"
    assert_includes text, "\nuntil _tally_showing is 0: 1 a, 1 -\n"
    assert_equal recorded, VBlank::Playthroughs::Tape.parse(text)
  end

  def test_a_tape_written_by_hand_with_until_lines_plays
    tape = VBlank::Playthroughs::Tape.parse(<<~TAPE)
      vblank tape 1
      recorded on: UNTIL 0x00000000
      starts from: power-on
      counts: variable steps

      until screen is 1 within 600: 2 start, 3 -
      until screen is 3: 1 a, 1 -
      4 right
    TAPE
    played = tape.play(slow_fade, on: "interpreter")

    assert_equal 4, played.game.var(:x)
  end

  def test_a_script_counted_in_frames_puts_the_frames_on_the_tape
    tape = to_the_play.play(quick_fade, on: "interpreter").tape

    refute_includes tape.to_s, "until"
    assert_equal 5, tape.play(quick_fade, on: "interpreter").game.var(:x)
  end

  def test_a_step_that_never_holds_gives_up_saying_the_step_and_what_the_variable_read
    script = VBlank::Playthroughs::Playthrough.new("stuck") { repeat_until(:screen, is: 9, within: 30) { press :start } }
    error = assert_raises(VBlank::Playthroughs::GaveUp) { script.play(quick_fade, in_passes: :steps, on: "interpreter") }

    assert_match(/screen is 9/, error.message)
    assert_includes error.message, "screen still read #{TALLY}" # the quick fade is over by then
    assert_match(/30 frames/, error.message)
    assert_match(/frame 30\b/, error.message)
  end

  def test_a_step_that_holds_already_plays_no_frame
    script = VBlank::Playthroughs::Playthrough.new("at once") do
      wait frames: 1
      repeat_until :screen, is: TITLE
      moment :still_on_the_title
    end

    assert_equal({ still_on_the_title: 1 }, script.play(quick_fade, on: "interpreter").moments)
  end

  def test_an_until_line_on_a_tape_of_frames_is_refused
    error = assert_raises(ArgumentError) { VBlank::Playthroughs::Tape.parse(tape_text("until screen is 1: 1 start, 1 -")) }

    assert_match(/counts passes/, error.message)
  end

  def test_an_until_line_that_cannot_be_read_names_the_line
    error = assert_raises(ArgumentError) do
      VBlank::Playthroughs::Tape.parse(tape_text("until screen 1", counts: "counts: passes\n"))
    end

    assert_match(/line 5/, error.message)
    assert_match(/until screen is 3/, error.message)
  end

  def test_a_pattern_with_a_button_the_console_does_not_have_is_refused
    error = assert_raises(ArgumentError) do
      VBlank::Playthroughs::Tape.parse(tape_text("until screen is 1: 1 jump", counts: "counts: passes\n"))
    end

    assert_match(/jump/, error.message)
  end

  def test_a_script_step_that_is_not_a_press_hold_or_wait_inside_repeat_until_is_refused
    error = assert_raises(ArgumentError) do
      VBlank::Playthroughs::Playthrough.new("odd") do
        repeat_until(:screen, is: 1) do
          press :start
          moment :inside
        end
      end
    end

    assert_match(/repeat_until/, error.message)
  end

  def test_a_value_that_is_not_a_whole_number_is_refused
    error = assert_raises(ArgumentError) { VBlank::Playthroughs::Playthrough.new("odd") { repeat_until :screen, is: :playing } }

    assert_match(/whole number/, error.message)
  end

  def test_a_name_that_is_not_a_symbol_is_refused
    error = assert_raises(ArgumentError) { VBlank::Playthroughs::Playthrough.new("odd") { repeat_until "screen", is: 1 } }

    assert_match(/symbol/, error.message)
  end

  private def tape_text(line, counts: "")
    "vblank tape 1\nrecorded on: UNTIL 0x00000000\nstarts from: power-on\n#{counts}#{line}\n"
  end
end
