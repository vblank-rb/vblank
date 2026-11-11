# frozen_string_literal: true

require "test_helper"

# A program made by hand runs in DOSBox and what it did is read back: the colour it filled the screen
# with, the card's memory, palette and mode, and a key pressed on the keyboard.
class TestCore < Minitest::Test
  include HandMadeProgram

  MAGENTA_INDEX = 5 # the default palette's colour 5, which a mode 13h program starts with
  MAGENTA_6_BIT = [42, 0, 42].freeze # 2Ah of 3Fh red, none green, 2Ah blue
  MAGENTA = 0xAA00AA # the same colour in 8 bits a channel

  private def played(program, frames)
    written(program) do |path|
      core = RubyDOSEmulator::Core.new(path)
      frames.times { core.run_frame }
      yield core
    ensure
      core&.destroy
    end
  end

  def test_the_screen_is_the_colour_the_program_filled_it_with
    played(fill_screen(MAGENTA_INDEX), 20) do |core|
      picture = core.picture

      assert_equal [320, 200], [picture.width, picture.height]
      assert_equal [MAGENTA], picture.pixels.uniq
    end
  end

  def test_video_memory_holds_an_index_for_each_pixel_and_the_palette_says_its_colour
    played(fill_screen(MAGENTA_INDEX), 20) do |core|
      assert_equal [MAGENTA_INDEX], core.chained_pixels.bytes.uniq
      assert_equal 64_000, core.chained_pixels.bytesize
      assert_equal MAGENTA_6_BIT, core.palette.fetch(MAGENTA_INDEX)
    end
  end

  def test_the_card_says_it_is_drawing_320_by_200
    played(fill_screen(MAGENTA_INDEX), 20) do |core|
      assert_equal [320, 200], [core.vga_state.width, core.vga_state.height]
    end
  end

  def test_a_frame_is_one_picture_of_a_mode_13h_screen
    played(fill_screen(MAGENTA_INDEX), 20) do |core|
      assert_in_delta 70.0, core.fps, 0.5
    end
  end

  def test_a_key_pressed_is_what_the_keyboard_port_says_until_it_is_let_go
    played(copy_keyboard_port, 5) do |core|
      core.press(%i[z])
      5.times { core.run_frame }

      assert_equal 0x2C, core.peek(0x600, 1).getbyte(0), "the scan code of Z being pressed"

      core.press([])
      5.times { core.run_frame }

      assert_equal 0xAC, core.peek(0x600, 1).getbyte(0), "the scan code of Z being let go"
    end
  end

  def test_a_key_a_dos_keyboard_does_not_have_is_refused
    played(fill_screen(0), 0) do |core|
      assert_raises(ArgumentError) { core.press(%i[fire]) }
    end
  end

  def test_a_library_without_the_probe_patch_is_refused_saying_so
    not_a_core = $LOADED_FEATURES.grep(/fiddle\.(bundle|so)\z/).first # a library that loads and has none of the functions
    setting = RubyDOSEmulator::CoreLibrary::SETTING
    kept = ENV.fetch(setting, nil)
    ENV[setting] = not_a_core

    error = written(fill_screen(0)) { |path| assert_raises(LoadError) { RubyDOSEmulator::Core.new(path) } }

    assert_includes error.message, "without this gem's probe patch"
  ensure
    ENV[setting] = kept
  end

  def test_two_machines_in_one_process_do_not_see_each_other
    played(fill_screen(MAGENTA_INDEX), 20) do |first|
      played(fill_screen(1), 20) do |second|
        assert_equal [MAGENTA], first.picture.pixels.uniq
        refute_equal first.picture.pixels.uniq, second.picture.pixels.uniq
      end
    end
  end

  def test_the_sound_made_is_pairs_of_samples
    played(fill_screen(0), 10) do |core|
      sound = core.take_audio

      assert_operator sound.size, :>, 0
      assert_equal 2, sound.first.size
    end
  end
end
