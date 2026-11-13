# frozen_string_literal: true

require "test_helper"
require "weakref"

# The one reader over a running cartridge plays a Super Nintendo cartridge in bsnes and answers
# the questions it answers for the other consoles.
class TestSNESVerifier < Minitest::Test
  Verifier = VBlank::Diagnostics::Verifier

  private def rom
    VBlank.build("READER", console: :snes, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:dot, "#" => :red) { (["########"] * 8).join("\n") }
      hero = sprite :dot, at: [30, 40]
      steps = var :steps, 7
      background_color = var :seen, 0
      game_loop do
        wait_vblank
        background_color += 1
        if held(:right)
          steps += 1
          hero.x = 50
        end
      end
    end
  end

  # A game that keeps a number in save memory and counts it up each pass.
  private def saving_rom
    VBlank.build("SAVER", console: :snes, out: StringIO.new, err: StringIO.new) do
      best = save_var :best, 5
      game_loop { best += 3 }
    end
  end

  # What a reader left open saved, and a weak reference that says whether Ruby has collected it.
  LeftOpen = Data.define(:save, :reader)

  # A reader nobody closed is collected by Ruby in the end, and the cartridge read next in this
  # process starts with its save memory as the console leaves it: the one cartridge's save is
  # never the other's. Most tests never close a reader, so this is the usual case.
  #
  # Readers earlier tests left open are collected first, so the copy of the core the open reader
  # takes is the one the next reader takes after it.
  def test_a_reader_left_open_hands_its_save_to_no_other_cartridge
    collect_readers_left_open
    left_open = Thread.new { play_reader_left_open }.value
    collect_readers_left_open
    refute left_open.reader.weakref_alive?, "the reader left open was collected"

    fresh = Verifier.new(saving_rom, frames: 0)
    fresh_save = fresh.save_bytes
    fresh.close

    refute_nil fresh_save
    # The first bytes are the save's own mark and the saved number.
    refute_equal left_open.save.byteslice(0, 16), fresh_save.byteslice(0, 16),
                 "the cartridge read next started from the open reader's save"
  end

  # Played on a thread of its own and let go of there: Ruby looks for what is still held on
  # every stack, and a word left on the test's own could keep the reader from being collected.
  private def play_reader_left_open
    reader = Verifier.new(saving_rom, frames: 10)
    LeftOpen.new(save: reader.save_bytes, reader: WeakRef.new(reader))
  end

  private def collect_readers_left_open = 3.times { GC.start(full_mark: true, immediate_sweep: true) }

  def test_it_reads_the_picture_at_the_consoles_size
    reader = Verifier.new(rom, frames: 8)

    assert_equal 256, reader.screen_width
    assert_equal 224, reader.screen_height
    assert reader.pixel_is?(33, 43, :red), "the sprite is where the game put it"
    refute reader.pixel_is?(120, 120, :red), "and nowhere else"
  end

  def test_it_reads_a_variable_and_the_sprites_by_name
    built = rom
    reader = Verifier.new(built, frames: 8, vars: built.var_addresses)
    hero = reader.sprites.first

    assert_equal 7, reader.var(:steps)
    assert_equal [30, 40], [hero.x, hero.y]
  end

  def test_a_step_holds_buttons_as_the_other_consoles_do
    built = rom
    reader = Verifier.new(built, frames: 8, vars: built.var_addresses)
    reader.step(4, keys: VBlank::IR::Buttons.mask(:right))

    assert_operator reader.var(:steps), :>, 7
    assert_equal 50, reader.sprites.first.x
  end

  def test_a_step_holds_the_second_controllers_buttons
    built = VBlank.build("JOINS", console: :snes, out: StringIO.new, err: StringIO.new) do
      joins = var :joins, 0
      game_loop { joins += 1 if pressed(:start, player: 2) }
    end
    reader = Verifier.new(built, frames: 8, vars: built.var_addresses)
    reader.step(4, keys: VBlank::IR::Buttons.mask(:start))

    assert_equal 0, reader.var(:joins)

    reader.step(4, keys: VBlank::IR::Buttons.mask(:p2_start))

    assert_equal 1, reader.var(:joins)
  end

  def test_it_counts_the_passes_the_console_finished
    shorter = Verifier.new(rom, frames: 8).passes
    longer = Verifier.new(rom, frames: 18).passes

    assert_equal 10, longer - shorter
  end

  def test_two_runs_of_one_cartridge_are_one_picture
    built = rom

    assert Verifier.new(built, frames: 8).same_picture_as?(Verifier.new(built, frames: 8))
  end

  def test_the_colour_table_has_the_consoles_shape
    reader = Verifier.new(rom, frames: 8)

    assert_equal 256, reader.palette.size
    assert_equal 128, reader.palette(:sprites).size
    assert_equal 16, reader.palette(:sprites, 0).size
  end

  def test_a_game_that_makes_no_sound_is_silent
    assert Verifier.new(rom, frames: 20).silent?
  end

  # The console takes some frames to reach the game's first pass, so a frame's sound in the wrong
  # frame shows here: the first frames are quiet and the last are not.
  def test_it_records_each_frames_sound_when_the_game_makes_it
    reader = Verifier.new(beeper, frames: 40)
    energy = reader.audio_energy_by_frame

    assert reader.sound?
    assert_equal 40, energy.size
    assert_equal 0, energy.first
    assert_operator energy.last, :>, 0
    assert_equal 0, reader.audio_samples.size % 2, "left and right by turns"
  end

  # Its sound is 48000 samples a second, more than the other consoles' emulator hands over, so a
  # recording read at their rate is too many frames long.
  def test_a_recording_of_its_cartridge_is_as_long_as_the_frames_played
    heard = VBlank::Diagnostics::SoundRecording.of(beeper.source_program, on: :cartridge, frames: 40)

    assert_equal 48_000, heard.rate
    assert_in_delta 40, heard.frames.size, 1
    assert_operator heard.frames.last.loudest, :>, 0
  end

  # The eight voices are not the other consoles' four, so one voice alone is refused in plain
  # words rather than heard as the wrong thing.
  def test_hearing_one_voice_alone_says_it_cannot
    error = assert_raises(ArgumentError) { Verifier.new(beeper, frames: 2).hearing(only: :noise) }

    assert_match(/one voice alone/, error.message)
  end

  private def beeper
    VBlank.build("BEEPER", console: :snes, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      enable_sound
      define_sound :ping, frequency: 880, decay: :none
      n = var :n, 0
      game_loop do
        beep :ping if n == 3
        n += 1
      end
    end
  end
end
