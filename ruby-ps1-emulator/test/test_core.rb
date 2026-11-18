# frozen_string_literal: true

require "test_helper"
require "weakref"

# A program made by hand runs in Beetle PSX under OpenBIOS, and what it did is read back: a word it
# stored in RAM, the screen it set up and the colour it filled the screen with.
class TestCore < Minitest::Test
  include HandMadeProgram

  RED = 0x001F # 15 bits: red in the low five
  MARKER = 0x1234_5678
  MARKER_AT = 0x8010_0000
  VRAM_WIDTH = RubyPS1Emulator::Core::VRAM_WIDTH

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

  # A state saved puts back the RAM it was saved with, over whatever was written after.
  def test_a_saved_state_puts_ram_back
    played(red_screen, 120) do |core|
      core.ram_write32(0x0010_0000, 0x1234_5678)
      state = core.serialize
      core.ram_write32(0x0010_0000, 0x0BAD_F00D)
      core.unserialize(state)

      assert_equal 0x1234_5678, core.ram_read32(0x0010_0000)
      assert_raises(ArgumentError) { core.unserialize("not a state".b) }
    end
  end

  def test_the_screen_is_the_red_the_program_filled_it_with
    played(red_screen, 120) do |core|
      assert_equal [320, 240], [core.width, core.height]
      assert_equal [RED], core.colors.uniq
    end
  end

  # A part of video RAM read in place: the red the program filled, and what lies past it, which a
  # read running past the right edge finds at the left.
  def test_a_part_of_video_ram_is_read_where_it_is
    played(red_screen, 120) do |core|
      assert_equal [RED] * 6, core.colors_at(318, 0, 2, 3)
      assert_equal [0] * 4, core.colors_at(320, 0, 4, 1), "nothing was drawn past the picture"
      assert_equal [0, 0, RED, RED], core.colors_at(VRAM_WIDTH - 2, 0, 4, 1), "a row goes round to the left"
    end
  end

  def test_the_processor_is_looping_in_the_program
    played(red_screen, 120) do |core|
      assert_includes LOAD_AT...(LOAD_AT + (red_screen.size * 4)), core.registers.fetch(:pc)
    end
  end

  # The loader copies a program in before it starts, a longer one for longer: a short program begins
  # in the first frame, before any blank, and one padded to 64K after the screen's first blanks.
  def test_the_blanks_before_a_program_begins_grow_with_its_length
    blanks = [red_screen, red_screen + ([0] * 0x4000)].map do |words|
      Dir.mktmpdir do |dir|
        core = RubyPS1Emulator::Core.new(write(dir, words))
        core.watch_program_start!
        12.times { core.run_frame }
        core.blanks_before_program
      ensure
        core&.destroy
      end
    end

    assert_equal 0, blanks.first
    assert_operator blanks.last, :>, 1
  end

  def test_the_start_is_watched_from_power_on_or_not_at_all
    played(red_screen, 1) { |core| assert_raises(ArgumentError) { core.watch_program_start! } }
  end

  # A halfword to the sound chip's register at +distance+ from 1F800000h (SH t1, distance(t0)).
  private def sound_register(distance, value) = number(value) + [0xA509_0000 | distance]

  # Voice 5's pitch set, and a halfword written into sound memory at 1000h through the chip's queue.
  private def sound_writes
    words = ports + sound_register(0x1C54, 0x1234) + sound_register(0x1DA6, 0x1000 / 8) + sound_register(0x1DA8, 0xBEEF)
    words + forever(LOAD_AT + (words.size * 4))
  end

  def test_the_sound_chips_registers_are_read_as_the_program_wrote_them
    played(sound_writes, 2) { |core| assert_equal 0x1234, core.spu_registers.fetch(0x54) }
  end

  def test_sound_memory_holds_what_the_program_wrote_into_it
    played(sound_writes, 2) { |core| assert_equal [0xBEEF].pack("v"), core.sound_ram[0x1000, 2] }
  end

  def test_the_sound_made_is_handed_over_once
    played(red_screen, 3) do |core|
      assert_equal core.sound_frames * 2, core.take_audio.size
      assert_empty core.take_audio
    end
  end

  def test_a_bios_file_that_is_not_there_is_refused
    Dir.mktmpdir do |dir|
      error = assert_raises(ArgumentError) { RubyPS1Emulator::Core.new(write(dir, red_screen), bios: File.join(dir, "none.bin")) }

      assert_match(/no BIOS file/, error.message)
    end
  end

  def test_a_button_the_pad_does_not_have_is_refused
    played(red_screen, 0) do |core|
      assert_raises(ArgumentError) { core.set_buttons(%i[a]) }
    end
  end

  def test_the_memory_card_holds_what_was_written_to_it
    played(red_screen, 0) do |core|
      core.memory_card = "\x5A".b * 16
      core.run_frame
      assert_equal "\x5A".b * 16, core.memory_card.byteslice(0, 16)
      assert_equal 128 * 1024, core.memory_card.bytesize
    end
  end

  # A console nobody destroyed is collected by Ruby in the end, and its copy of the core is handed to
  # the next console made in this process. The next console must start with a memory card of its own,
  # never the one the dropped console had.
  def test_a_console_left_without_destroy_hands_its_memory_card_to_nobody
    dropped = Thread.new { drop_console { |core| core.memory_card = "\x5A".b * 16 } }.value
    collect_dropped_consoles
    refute dropped.weakref_alive?, "the dropped console was collected, so its copy is free for the next"

    played(forever(LOAD_AT), 1) do |core|
      refute_equal "\x5A".b * 16, core.memory_card.byteslice(0, 16), "the new console has the dropped console's card"
    end
  end

  # The copy of the core a dropped console gives back holds no program: Ruby shuts the console as
  # #destroy does. A copy left with the program in it is a library never shut, which keeps the old
  # console's memory for as long as the process runs.
  def test_a_console_left_without_destroy_leaves_no_program_in_its_copy
    dropped = Thread.new { drop_console { nil } }.value
    collect_dropped_consoles
    refute dropped.weakref_alive?, "the dropped console was collected, so its copy is free for the next"

    refute_equal [MARKER].pack("V"), ram_in_next_copy(MARKER_AT, 4), "the copy still holds the dropped console's RAM"
  end

  # Made and played on a thread of its own and let go of there: Ruby looks for what is still held on
  # every stack, and a word left on the test's own could keep the console from being collected. Hands
  # back a weak reference, which says whether the console is still alive without keeping it so.
  private def drop_console
    core = RubyPS1Emulator::Core.new(write(Dir.mktmpdir, red_screen))
    yield core
    3.times { core.run_frame }
    WeakRef.new(core)
  end

  private def collect_dropped_consoles = 3.times { GC.start(full_mark: true, immediate_sweep: true) }

  # +count+ bytes of main RAM from +address+ in the copy of the core the next console would take, opened
  # as that console opens it, before any program goes in. A copy that holds no program has no RAM to
  # show, and answers nil.
  private def ram_in_next_copy(address, count)
    copy = RubyPS1Emulator::KeptCopy.take
    dir = Dir.mktmpdir
    frontend = RubyPS1Emulator::Frontend.new(copy.path, dir, dir, RubyPS1Emulator::Core::SETTINGS,
                                             RubyPS1Emulator::Core::ANY_PIXEL_FORMAT)
    frontend.memory(RubyPS1Emulator::Core::SYSTEM_RAM).byteslice(address & (RubyPS1Emulator::Core::RAM_SIZE - 1), count)
  ensure
    frontend&.close
    copy&.give_back
    FileUtils.rm_rf(dir) if dir
  end
end
