# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

# A game that names the PlayStation is built as a PS-X EXE by `vblank build`, and boots in Beetle PSX
# under OpenBIOS: the runtime takes the console over (its own interrupt handler at the exception vector,
# the picture on at the end of the first pass, black), and counts one frame for every frame the console
# draws, each as long as the console's description says.
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

  private def played(exe_path, frames)
    core = VBlank::Diagnostics::Emulator.open_ps1(exe_path)
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
