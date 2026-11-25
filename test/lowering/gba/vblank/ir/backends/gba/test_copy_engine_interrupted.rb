# frozen_string_literal: true

require "test_helper"
require "differential"

# The copying engine (DMA3) is set up by three writes, and an interrupt can come between any two
# of them. A timer's handler that fills with the same engine must not corrupt a fill the game was
# setting up when the tick came: no row painted the handler's colour, none left unpainted, none
# sent to the handler's square. The game paints a band red and green on alternate passes, so a
# row its fill missed keeps last pass's colour and shows, while a fast timer paints a small blue
# square below it on every tick.
class TestCopyEngineInterrupted < Minitest::Test
  include Differential

  def test_a_fill_interrupted_by_a_handler_that_fills_is_painted_as_the_interpreter_paints_it
    assert_backends_agree(alternating_band_program, frames: [9, 17, 26, 34])
  end

  # A bend in a game with no frame is worked out a line at a time, from the interrupt that comes
  # after every line the display draws, so a bend whose block fills lands in the game's fills as a
  # timer's handler does. The screen is tiled, which draws nothing from the painted memory, so the
  # game's band is read back from video memory: every halfword of it the game's red.
  def test_a_fill_interrupted_by_a_bend_that_fills_keeps_its_colour
    backend = GBA.new
    rom = ROM.assemble(backend.lower(bend_filling_program), title: "BENDFILL", maker: "01")
    memory = assert_emulator_loads_rom(rom, frames: 10).video_ram
    band = memory.byteslice(BAND_TOP * BAND_ROW_BYTES, BAND_ROWS * BAND_ROW_BYTES).unpack("v*")

    assert_equal [RED], band.uniq.map { |color| color & 0x7FFF }, "the game's band holds only its own colour"
  end

  # A handler that only counts uses neither the copying engine nor the fill's colour word, so the
  # game's copies are not held for it: none of its cartridge reaches the interrupt switch from the
  # engine's address, as a held setup does (Primitives#with_copy_setup_held). One that fills is.
  def test_copies_are_held_only_where_a_handler_copies
    held = ASM.ldr_offset(GBA::ADDR, GBA::TMP, GBA::Primitives::IME_STEP)

    refute cartridge_code(ticking_program(fills: false)).include?(held), "a handler that counts holds no copy"
    assert cartridge_code(ticking_program(fills: true)).include?(held), "a handler that fills holds the game's copies"
  end

  BAND_TOP = 40
  BAND_ROWS = 20
  BAND_ROW_BYTES = 240 * 2
  RED = VBlank::Graphics::Color.resolve(:red)
  ASM = VBlank::IR::Backends::GBA::ASM

  private def cartridge_code(program) = GBA.new.lower(program)

  # A bitmap game that fills every pass, with a fast timer whose handler counts, or fills.
  private def ticking_program(fills:)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      hits = var :hits, 0
      timer(:beat, per_second: 8000).on_tick do
        if fills
          fill_rect 0, 140, 16, 16, :blue
        else
          hits += 1
        end
      end
      game_loop do
        fill_rect 0, 0, 240, 120, :red
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  # A tiled game with no frame: it fills a band red over and over, and its one background bends,
  # its block filling a small square blue on every line.
  private def bend_filling_program
    top = BAND_TOP
    rows = BAND_ROWS
    b = Builder.new(options: VBlank::Cartridge::Options.new(frame_sync: :manual))
    b.instance_eval do
      screen :tiled
      image(:t, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :ts, "#" => :t
      background(:bg, tiles: :ts, map: Array.new(4, "#" * 30)).scroll_each_row do |row|
        fill_rect 0, 150, 8, 2, :blue
        row % 8
      end
      game_loop { fill_rect 0, top, 240, rows, :red }
    end
    b.finalize_program
    b.program
  end

  private def alternating_band_program
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      passes = var :passes, 0
      timer(:beat, per_second: 16_000).on_tick { fill_rect 0, 140, 16, 16, :blue }
      game_loop do
        if passes.even?
          fill_rect 0, 0, 240, 120, :red
        else
          fill_rect 0, 0, 240, 120, :green
        end
        passes += 1
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end
end
