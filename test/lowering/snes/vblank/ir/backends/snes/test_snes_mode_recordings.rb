# frozen_string_literal: true

require "test_helper"

# EACH MODE BRINGS ITS OWN RECORDINGS INTO THE SOUND CHIP. A game that picks its modes by calling
# the routine a variable names (`call mode`) has them take turns as a game's scenes do, so a
# recording only one mode plays is wanted in the Super Nintendo's sound chip only while that mode
# runs. Its recordings together are more than the chip's 64K, and each mode's fit alone: the mode
# called brings its own in as it is first called, over the mode before's. The checked run holds
# every pass to the interpreter; the chip's memory (CheckedRun#apu_ram) says which is in it.
class TestSNESModeRecordings < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  Samples = SNES::Samples

  # Two recordings of 64000 samples, 36000 bytes each in the chip's format: 72000 together, against
  # 64704 the chip has room for. Each a pattern of its own, so the chip's memory says which is there.
  LENGTH = 64_000
  HALL = Array.new(LENGTH) { |i| ((i % 32) - 16) * 4 }.pack("c*")
  CAVE = Array.new(LENGTH) { |i| ((i % 20) < 10 ? 48 : -48) }.pack("c*")
  # One recording both modes play, which stays in the chip throughout.
  CHIME = Array.new(320) { |i| ((i % 16) - 8) * 8 }.pack("c*")

  HALL_STARTS = 3      # The pass the hall plays its echo on
  CAVE_TAKES_OVER = 30
  CAVE_STARTS = 32     # The pass the cave plays its drip on

  private def game(hall: HALL, cave: CAVE, cave_called_by_name: false)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      enable_sound
      echo = sample :hall_echo, pcm: hall, rate: 32_000
      drip = sample :cave_drip, pcm: cave, rate: 32_000
      chime = sample :chime, pcm: CHIME, rate: 32_000
      mode = var :mode, :hall
      step = var :step, 0
      func(:hall) do
        echo.play(loop: true) if step == HALL_STARTS
        chime.play if step == HALL_STARTS + 1
      end
      func(:cave) do
        drip.play(loop: true) if step == CAVE_STARTS
        chime.play if step == CAVE_STARTS + 1
      end
      game_loop do
        step += 1
        mode = :cave if step == CAVE_TAKES_OVER
        call mode
        call :cave if cave_called_by_name && step == 1
      end
    end
    b.finalize_program
    b.program
  end

  private def kept(pcm) = Samples.recording(pcm, LENGTH).first
  private def held?(run, pcm) = run.apu_ram.include?(kept(pcm).pack("C*"))

  def test_the_first_mode_plays_its_own_recording_from_the_chips_memory
    run = SNES::CheckedRun.new.run(game, frames: HALL_STARTS + 3)

    assert_equal %i[hall_echo], run.active_samples
    assert_equal [true, false], [held?(run, HALL), held?(run, CAVE)]
  end

  def test_the_next_mode_brings_its_own_recording_in_over_the_first
    run = SNES::CheckedRun.new.run(game, frames: CAVE_STARTS + 4)

    assert_includes run.active_samples, :cave_drip
    assert_includes run.audio, [:sample, :chime]
    assert_equal [false, true], [held?(run, HALL), held?(run, CAVE)]
  end

  # One mode whose own recordings do not fit is refused, naming it and the sound memory.
  def test_a_mode_whose_recordings_do_not_fit_is_refused_naming_it
    error = assert_raises(VBlank::BuildError) { SNES.new.build(game(cave: CAVE * 2)) }

    assert_match "routine :cave", error.message
    assert_match "sound memory", error.message
  end

  # A mode the game also calls by name could run without its recordings brought in, so it keeps
  # none of its own, and recordings that do not fit at once are refused saying how to make them.
  def test_a_mode_also_called_by_name_keeps_no_recordings_of_its_own
    error = assert_raises(VBlank::BuildError) { SNES.new.build(game(cave_called_by_name: true)) }

    assert_match "sound memory", error.message
    assert_match "call mode", error.message
  end
end
