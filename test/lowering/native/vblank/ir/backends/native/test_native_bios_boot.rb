# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/live"

# THE CONSOLE'S OWN START-UP, PLAYED BY runtime/rg_bios_boot.c, the small emulator a desktop build of
# an Advance game runs the player's BIOS in (bios_boot_harness.c drives it).
#
# The processor is held to small programs of its own, assembled here, which need no BIOS. The whole
# start-up is held to mGBA, frame by frame, picture by picture and sample by sample, and that needs
# the player's BIOS: VBLANK_GBA_BIOS names it, and without it those tests skip. Nothing of the BIOS
# is kept: the file is read where it lies, and what is compared is thrown away.
class TestNativeBIOSBoot < Minitest::Test
  HARNESS = Ractor.make_shareable(File.expand_path("bios_boot_harness.c", __dir__))
  Zig = VBlank::IR::Backends::Native::Zig
  ASM = VBlank::IR::Backends::GBA::ASM

  FRAME_BYTES = 240 * 160 * 4
  CARTRIDGE_ENTRY = 0x08000000

  def test_an_addition_that_carries_sets_the_carry_and_zero_flags
    run = run_program(ASM.load_immediate(0, 0xFFFFFFFF) + ASM.load_immediate(1, 1) + ASM.adds_reg(2, 0, 1))

    assert_equal 0, run.fetch("r2")
    assert_equal 0x6, run.fetch("cpsr") >> 28 # Z and C, not N or V
  end

  def test_a_subtraction_past_the_lowest_number_sets_the_overflow_flag
    run = run_program(ASM.load_immediate(0, 0x80000000) + ASM.subs_imm(1, 0, 1))

    assert_equal 0x7FFFFFFF, run.fetch("r1")
    assert_equal 0x3, run.fetch("cpsr") >> 28 # C (no borrow) and V
  end

  def test_a_signed_halfword_load_and_a_push_and_pop_round_trip_through_memory
    code = ASM.load_immediate(0, 0x03000000) + ASM.load_immediate(1, 0x8001) + ASM.str(1, 0) + ASM.ldrsh(3, 0) +
           ASM.push(1, 3) + ASM.load_immediate(1, 0) + ASM.pop(1, 3)
    run = run_program(code, peek: [0x03007EF8, 0x03007EFC])

    assert_equal 0xFFFF8001, run.fetch("r3")
    assert_equal 0x8001, run.fetch("r1")
    assert_equal 0x03007F00, run.fetch("r13")
    assert_equal [0x8001, 0xFFFF8001], [run.fetch(0x03007EF8), run.fetch(0x03007EFC)]
  end

  def test_a_long_multiply_keeps_the_whole_product
    code = ASM.load_immediate(0, 0x10000) + ASM.load_immediate(1, 0xFFFF0000) + ASM.smull(2, 3, 1, 0)
    run = run_program(code)

    assert_equal [0, 0xFFFFFFFF], [run.fetch("r2"), run.fetch("r3")] # -65536 * 65536
  end

  def test_bx_to_an_odd_address_runs_thumb_code
    thumb = [0x2005, # MOV r0, #5
             0x0081, # LSL r1, r0, #2
             0x180A, # ADD r2, r1, r0
             0x4253, # NEG r3, r2
             0xE7FE].pack("v*") # B .
    code = place(ASM.load_immediate(4, 0x41) + ASM.bx(4), 0x40 => thumb)
    run = run_program(code, steps: 6)

    assert_equal [25, 0xFFFFFFE7], [run.fetch("r2"), run.fetch("r3")]
    assert_equal 0x20, run.fetch("cpsr") & 0x20, "the processor is in THUMB"
    assert_equal 0x8, run.fetch("cpsr") >> 28, "NEG of 25 is negative and borrows"
    assert_equal 0x48, run.fetch("pc")
  end

  def test_swi_runs_the_handler_at_eight_and_returns_to_the_next_instruction
    handler = ASM.load_immediate(5, 0x55) + [0xE1B0F00E].pack("V") # MOVS pc, lr
    main = ASM.load_immediate(6, 1) + ASM.swi(0) + ASM.load_immediate(7, 2)
    code = place(ASM.branch(0x40 / 4), 0x08 => handler, 0x40 => main)
    run = run_program(code, steps: 6)

    assert_equal [0x55, 1, 2], [run.fetch("r5"), run.fetch("r6"), run.fetch("r7")]
    assert_equal 0x1F, run.fetch("cpsr") & 0x1F, "back in system mode"
  end

  def test_a_timer_interrupt_reaches_the_handler_at_0x18
    handler = ASM.load_immediate(7, 0x77) + ASM.loop_forever
    main = ASM.load_immediate(0, 0x04000200) + ASM.load_immediate(1, 8) + ASM.store_halfword(1, 0) + # IE: timer 0
           ASM.load_immediate(1, 1) + ASM.store_halfword_offset(1, 0, 8) + # IME
           ASM.load_immediate(2, 0x04000100) + ASM.load_immediate(1, 0xFFF0) + ASM.store_halfword(1, 2) + # reload
           ASM.load_immediate(1, 0xC0) + ASM.store_halfword_offset(1, 2, 2) + # on, with its interrupt
           ASM.loop_forever
    code = place(ASM.branch(0x40 / 4), 0x18 => handler, 0x40 => main)
    run = run_program(code, steps: 200)

    assert_equal 0x77, run.fetch("r7")
    assert_equal 0x12, run.fetch("cpsr") & 0x1F, "in interrupt mode"
    assert_equal 0x80, run.fetch("cpsr") & 0x80, "with interrupts held off"
  end

  # The console's timing: an instruction fetched from the BIOS takes one cycle, a 32-bit load from
  # the 256K work memory six more for its two 16-bit halves and one to finish, and a store one less.
  def test_a_load_from_the_work_memory_takes_eight_cycles_and_a_store_seven
    load = run_program(ASM.load_immediate(0, 0x02000000) + ASM.ldr(1, 0), steps: 2)
    store = run_program(ASM.load_immediate(0, 0x02000000) + ASM.str(1, 0), steps: 2)

    assert_equal [1 + 8, 1 + 7], [load.fetch("cycles"), store.fetch("cycles")]
  end

  def test_a_tiled_background_is_said_to_be_not_handled
    code = ASM.load_immediate(0, 0x04000000) + ASM.load_immediate(1, 0x0100) + ASM.store_halfword(1, 0) + ASM.loop_forever
    run = run_program(code, steps: 2000)

    assert_includes run.fetch("unhandled"), "a tiled background"
  end

  # THE ANSWER KEY: mGBA plays the same BIOS with the same cartridge, and every frame of the
  # start-up is the same picture, pixel for pixel, and the same sound, sample for sample: the
  # console's own mix at its own rate, before anything changes the rate for a speaker. The start-up
  # ends where mGBA's does, part way through the next frame, at the cartridge's first instruction.
  def test_the_start_up_matches_mgba_frame_by_frame
    bios = player_bios
    core = nil
    Dir.mktmpdir("vblank-bios-boot") do |dir|
      rom = File.join(dir, "game.gba")
      VBlank.build("BOOT CHECK", console: :gba, out: nil, err: nil) do
        screen :bitmap
        clear_screen :blue
        game_loop { pixel 1, 1, :white }
      end.write(rom)
      pictures, sound = File.join(dir, "pictures"), File.join(dir, "sound")
      said = Zig.run_program(harness, args: ["boot", bios, rom, 400, pictures, sound], seconds: 120)
      frames = said[/^frames (\d+)/, 1].to_i

      assert_includes said, "reached_game 1"
      assert_includes said, "unhandled \n"
      assert_operator frames, :>, 200, "the start-up plays for about four and a half seconds"

      core = VBlank::Diagnostics::Emulator.open(rom, bios_path: bios)
      heard = 0
      File.open(pictures, "rb") do |mine_pictures|
        File.open(sound, "rb") do |mine_sound|
          frames.times do |frame|
            core.mixed_sound_start
            core.run_frame
            their_sound = core.mixed_sound_finish
            my_sound = mine_sound.read(mine_sound.read(4).unpack1("V") * 4)
            heard += 1 if my_sound.unpack("s<*").any?(&:nonzero?)

            assert_equal core.video_buffer, mine_pictures.read(FRAME_BYTES), "the picture of frame #{frame}"
            assert_equal their_sound, my_sound, "the sound of frame #{frame}"
          end
        end
      end

      assert_operator heard, :>, 150, "the chime sounds for most of the start-up"
      assert core.run_until(CARTRIDGE_ENTRY, 1_000_000), "mGBA reaches the cartridge too"
      assert_operator core.global_cycles, :<, 197_120 + (frames * 280_896), "...before the end of its next frame"
    ensure
      core&.destroy
    end
  end

  private def player_bios
    found = VBlank::Live::ConsoleBIOS.find(environment: ENV.fetch("VBLANK_GBA_BIOS", nil), setting: nil, shared_folder: nil)
    unless found.is_a?(VBlank::Live::ConsoleBIOS::Found)
      skip_on_this_machine "the console's start-up is checked against the player's Game Boy Advance BIOS, and " \
                           "VBLANK_GBA_BIOS does not name one here"
    end
    found.path
  end

  private def harness = Zig.compile_without_sdl([HARNESS, File.join(Zig::RUNTIME_DIR, "rg_bios_boot.c")], mode: :checked)

  # +code+ with the other pieces of code put at the addresses given, the gaps filled with nothing.
  private def place(code, pieces)
    pieces.reduce(code) { |image, (at, piece)| image.ljust(at, "\0".b) + piece }
  end

  # Runs +code+ from address 0 for +steps+ instructions (one for each of its words, unless told), and
  # gives back what the harness printed, by name: the registers, "cycles", "unhandled", and the word
  # at each address in +peek+.
  private def run_program(code, steps: code.bytesize / 4, peek: [])
    Dir.mktmpdir("vblank-bios-boot") do |dir|
      image = File.join(dir, "program.bin")
      File.binwrite(image, code)
      said = Zig.run_program(harness, args: ["program", image, steps, *peek.map { |address| format("0x%08X", address) }])
      said.lines.each_with_object({}) do |line, run|
        name, value = line.chomp.split(" ", 2)
        case name
        when "unhandled" then run[name] = value.to_s
        when "mem"
          address, word = value.split
          run[Integer(address)] = Integer(word)
        else run[name] = Integer(value)
        end
      end
    end
  end
end
