# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

# A game that names the PlayStation is built as a PS-X EXE by `vblank build`, and boots in Beetle PSX
# under OpenBIOS: the runtime takes the console over (its own interrupt handler at the exception vector,
# the picture on at the end of the first pass, black), and counts one frame for every frame the console
# draws, each as long as the console's description says. Where this machine names a player's own Sony
# BIOS (VBLANK_PS1_BIOS), it starts under that too, with the console as a BIOS leaves it.
class TestPS1Boot < Minitest::Test
  PS1 = VBlank::IR::Backends::PS1

  RUBY = RbConfig.ruby.freeze
  BIN = VBlank.root.join("bin/vblank").to_s

  EMPTY = <<~RUBY
    require "vblank"

    VBlank.game "EMPTY", consoles: %i[gba ps1] do
      game_loop {}
    end
  RUBY

  HARDWARE = VBlank::Console::PS1Hardware
  EXE = VBlank::Cartridge::PS1EXE

  # The player's own BIOS, where this machine names one (VBLANK_PS1_BIOS). Read as the file loads.
  SONY_BIOS = VBlank::Diagnostics::Emulator.ps1_bios

  # Where Sony's kernel keeps the first instruction of its table of routines (the "A" functions), in
  # the part of RAM below a program. It is nought until a BIOS has set the kernel up.
  KERNEL_A_FUNCTIONS = 0x8000_00A0

  private def played(exe_path, frames, bios: nil)
    core = VBlank::Diagnostics::Emulator.open_ps1(exe_path, bios: bios)
    frames.times { core.run_frame }
    yield core
  ensure
    core&.destroy
  end

  private def built(program)
    exe = PS1.new.build(program, title: "BOOT")
    path = File.join(Dir.mktmpdir("ps1-boot"), "boot.exe")
    exe.write(path)
    [exe, path]
  end

  private def counter_program
    VBlank.game("COUNT", consoles: %i[ps1]) do
      passes = 0
      game_loop { passes += 1 }
    end.program(console: :ps1)
  end

  # A game that shows its buttons: a red square while Right is held, and a count of the presses of Cross.
  private def pad_program
    VBlank.game("PAD", consoles: %i[ps1]) do
      presses = 0
      game_loop do
        presses += 1 if pressed(:a)
        fill_rect 10, 10, 20, 20, :red if held(:right)
      end
    end.program(console: :ps1)
  end

  # The word at +address+, in main RAM or in the scratchpad, where the build keeps the numbers a game
  # reads most.
  private def word_at(core, address)
    scratchpad = HARDWARE::SCRATCHPAD...(HARDWARE::SCRATCHPAD + HARDWARE::SCRATCHPAD_SIZE)
    return core.ram_read32(address) unless scratchpad.cover?(address)

    core.scratchpad_bytes(address - HARDWARE::SCRATCHPAD, 4).unpack1("V")
  end

  private def require_sony_bios!
    return if SONY_BIOS

    skip_on_this_machine "this machine names no PlayStation BIOS: set VBLANK_PS1_BIOS to a BIOS file dumped from your own console"
  end

  # +exe+ with a few instructions in front of it that stand for a console whose processor has ALREADY
  # RUN what stood at the exception vector, as one that has taken an interrupt under its BIOS has: the
  # instruction cache is turned on as the BIOS leaves it, a routine that only returns is written at
  # the vector and called once, so the processor holds its instructions in the cache, and then the
  # program is started as usual.
  private def started_after_the_vector_was_run(exe)
    entry = exe.bytes.byteslice(EXE::ENTRY_AT, 4).unpack1("V")
    load_at = exe.bytes.byteslice(EXE::LOAD_AT, 4).unpack1("V")
    body = exe.bytes.byteslice(EXE::HEADER_SIZE..)
    asm = PS1::R3000.new("the vector run")
    asm.li(:t0, HARDWARE::CACHE_CONTROL_SET_BY_BIOS)
    asm.li(:t1, HARDWARE::CACHE_CONTROL)
    asm.sw(:t0, 0, :t1)
    asm.li(:t1, HARDWARE::EXCEPTION_VECTOR)
    asm.li(:t0, 0x03E0_0008) # JR ra
    asm.sw(:t0, 0, :t1)
    (1..3).each { |word| asm.sw(:zero, word * 4, :t1) }
    asm.jalr(:t1)
    asm.li(:t0, entry)
    asm.jr(:t0)
    EXE.new(body + asm.bytes, title: "BOOT", entry: load_at + body.bytesize, load_at: load_at, built: exe.built)
  end

  def test_vblank_build_makes_an_exe_that_boots_to_a_black_screen
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "empty.rb"), EMPTY)
      out, status = Open3.capture2e(RUBY, BIN, "build", "empty.rb", "--console", "ps1", chdir: dir)
      path = File.join(dir, "empty.exe")

      assert status.success?, out
      assert VBlank::Cartridge::PS1EXE.header?(File.binread(path))
      played(path, 10) do |core|
        assert_equal [320, 240], [core.width, core.height]
        assert_equal 0, core.gpu_state.fetch(:display_off), "the picture is on"
        assert_equal [0], core.colors.uniq, "black"
      end
    end
  end

  # The four words at 80000080h, where the processor goes on an interrupt: LUI k0, hi; ORI k0, k0, lo;
  # JR k0; NOP, with the handler's address in the halves.
  def test_the_runtimes_interrupt_handler_is_at_the_exception_vector
    exe, path = built(counter_program)
    handler = exe.built.code.fetch("rt_interrupt")
    played(path, 2) do |core|
      words = Array.new(4) { |i| core.ram_read32(0x8000_0080 + (i * 4)) }

      assert_equal [0x3C1A_0000 | (handler >> 16), 0x375A_0000 | (handler & 0xFFFF), 0x0340_0008, 0], words
    end
  end

  # THE PROCESSOR RUNS CODE FROM A CACHE INSIDE ITSELF, and a word written to RAM does not change the
  # copy the cache holds. So a handler written over one the processor has already run is not the one
  # an interrupt runs, until the cache is emptied: the old one runs, and here it only returns, so no
  # frame is ever counted. The runtime empties the cache once its handler is in place.
  def test_an_interrupt_runs_the_runtimes_handler_where_the_processor_ran_the_one_before_it
    exe, = built(counter_program)
    path = File.join(Dir.mktmpdir("ps1-boot"), "after.exe")
    started_after_the_vector_was_run(exe).write(path)
    frames_at = exe.built.runtime.fetch(PS1::Runtime::Frame::FRAMES)
    played(path, 30) do |core|
      counted = core.ram_read32(frames_at)
      60.times { core.run_frame }

      assert_equal 60, core.ram_read32(frames_at) - counted
    end
  end

  # UNDER A PLAYER'S OWN SONY BIOS the console is not as power-on leaves it: the BIOS has set its
  # kernel up in the low part of RAM, with a handler of its own at the exception vector, interrupts it
  # has asked for, and the pads' port as it left it. The runtime takes all of that over, and the game
  # runs as it does with no BIOS run at all.
  def test_under_a_sony_bios_the_game_starts_and_counts_each_frame
    require_sony_bios!
    exe, path = built(counter_program)
    handler = exe.built.code.fetch("rt_interrupt")
    frames_at = exe.built.runtime.fetch(PS1::Runtime::Frame::FRAMES)
    played(path, 30, bios: SONY_BIOS) do |core|
      counted = core.ram_read32(frames_at)
      300.times { core.run_frame }

      refute_equal 0, core.ram_read32(KERNEL_A_FUNCTIONS), "the BIOS ran before the program"
      assert_equal [0x3C1A_0000 | (handler >> 16), 0x375A_0000 | (handler & 0xFFFF), 0x0340_0008, 0],
                   Array.new(4) { |i| core.ram_read32(HARDWARE::EXCEPTION_VECTOR + (i * 4)) }
      assert_equal 300, core.ram_read32(frames_at) - counted
      assert_equal [320, 240, 0], [core.width, core.height, core.gpu_state.fetch(:display_off)]
      assert_equal [0], core.colors.uniq, "black"
    end
  end

  # The emulator's library is used again by the next console one process makes, and what it kept of
  # the last comes with it. A console with no BIOS file is started at power-on with no BIOS run, and
  # the one after it, given a BIOS, must not be.
  def test_a_console_under_a_sony_bios_runs_its_bios_after_one_that_had_none
    require_sony_bios!
    _exe, path = built(counter_program)
    played(path, 30) { |core| assert_equal 0, core.ram_read32(KERNEL_A_FUNCTIONS), "no BIOS ran" }
    played(path, 30, bios: SONY_BIOS) { |core| refute_equal 0, core.ram_read32(KERNEL_A_FUNCTIONS), "the BIOS ran" }
  end

  def test_under_a_sony_bios_the_pad_is_read_and_the_picture_drawn
    require_sony_bios!
    exe, path = built(pad_program)
    presses_at = exe.built.variables.fetch(:presses)
    red = 31 # the console keeps red in a colour's low five bits
    played(path, 30, bios: SONY_BIOS) do |core|
      assert_equal [0], core.colors.uniq, "nothing held, nothing drawn"
      core.set_buttons(%i[right cross])
      20.times { core.run_frame }

      assert_equal 1, word_at(core, presses_at), "Cross went down once"
      assert_equal [red], core.colors_at(10, 10, 20, 20).uniq, "the square while Right is held"
    end
  end

  # The sound chip makes a pair of samples every 768 cycles of the processor (44100 a second at
  # 33.8688 MHz), so the samples made over many frames say how long a frame is.
  def test_one_frame_is_counted_for_each_frame_drawn_and_lasts_as_the_description_says
    exe, path = built(counter_program)
    frames_at = exe.built.runtime.fetch(PS1::Runtime::Frame::FRAMES)
    played(path, 30) do |core|
      samples = core.sound_frames
      counted = core.ram_read32(frames_at)
      300.times { core.run_frame }
      cycles = (core.sound_frames - samples) * 768 / 300.0

      assert_equal 300, core.ram_read32(frames_at) - counted
      assert_in_delta VBlank::Console.described(:ps1).cycles_a_frame, cycles, 100
    end
  end
end
