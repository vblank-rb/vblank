# frozen_string_literal: true

require "test_helper"

# A program made by hand runs in Beetle PSX under OpenBIOS, and what it did is read back: a word it
# stored in RAM, the screen it set up and the colour it filled the screen with.
class TestCore < Minitest::Test
  include HandMadeProgram

  RED = 0x001F # 15 bits: red in the low five
  MARKER = 0x1234_5678
  MARKER_AT = 0x8010_0000

  # Resets the graphics chip, shows a 320 × 240 picture from the top left of video RAM, and fills it
  # red with GP0 02h (a fill: colour, top left, size), then stores a word and loops.
  private def red_screen
    words = ports +
            gp1(0x0000_0000) + # reset
            gp1(0x0800_0001) + # display mode: 320 across, 240 down, NTSC, 15-bit colour
            gp1(0x0600_0000 | 0x260 | (0xC60 << 12)) + # the 320 pixels' place on the line
            gp1(0x0700_0000 | 0x10 | (0x100 << 10)) + # the 240 lines
            gp1(0x0500_0000) + # the picture starts at the top left of video RAM
            gp1(0x0300_0000) + # display on
            gp0(0x0200_00F8) + gp0(0) + gp0((240 << 16) | 320) + # fill red, from (0, 0), 320 × 240
            store_at(MARKER_AT, MARKER)
    words + forever(LOAD_AT + (words.size * 4))
  end

  private def played(words, frames)
    Dir.mktmpdir do |dir|
      core = RubyPS1Emulator::Core.new(write(dir, words))
      frames.times { core.run_frame }
      yield core
    ensure
      core&.destroy
    end
  end

  def test_the_program_runs_and_its_word_is_in_ram
    played(red_screen, 120) { |core| assert_equal MARKER, core.ram_read32(MARKER_AT) }
  end

  def test_the_screen_is_the_red_the_program_filled_it_with
    played(red_screen, 120) do |core|
      assert_equal [320, 240], [core.width, core.height]
      assert_equal [RED], core.colors.uniq
    end
  end

  def test_the_processor_is_looping_in_the_program
    played(red_screen, 120) do |core|
      assert_includes LOAD_AT...(LOAD_AT + (red_screen.size * 4)), core.registers.fetch(:pc)
    end
  end

  def test_a_button_the_pad_does_not_have_is_refused
    played(red_screen, 0) do |core|
      assert_raises(ArgumentError) { core.set_buttons(%i[a]) }
    end
  end
end
