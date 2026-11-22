# frozen_string_literal: true

require "test_helper"

# `clear_screen` and `fill_rect` on the Advance's cartridge: the copy engine's registers the
# ARM writes, how small that keeps the cartridge, and the picture it draws in the emulator. Every
# test here reads the cartridge itself, so the whole file is the gba run's.
class TestDMA < Minitest::Test
  include VBlank::Console::Hardware

  private def build(validate: false, &block)
    VBlank.build("DMATEST", console: :gba, code: "BDMA", maker: "01", validate: validate, out: nil, err: nil, &block)
  end

  # ========================================================================
  # clear_screen
  # ========================================================================

  def test_clear_screen_builds
    rom = build do
      screen :bitmap
      clear_screen :black
      halt
    end

    assert_operator rom.size, :>, 0
  end

  def test_clear_screen_emits_dma_registers
    rom = build do
      screen :bitmap
      clear_screen :red
      halt
    end

    # Should write to DMA3SAD, DMA3DAD, DMA3CNT
    # Look for stores to these I/O addresses in the instruction stream
    addresses_stored = find_store_targets(rom)

    assert_includes addresses_stored, REG_DMA3SAD, "should write DMA3 source address"
    assert_includes addresses_stored, REG_DMA3DAD, "should write DMA3 destination address"
    assert_includes addresses_stored, REG_DMA3CNT, "should write DMA3 control"
  end

  def test_clear_screen_much_smaller_than_fill_rect
    rom_dma = build do
      screen :bitmap
      clear_screen :red
      halt
    end

    rom_pixel = build do
      screen :bitmap
      fill_rect 0, 0, 240, 160, :red
      halt
    end

    # DMA clear should be way smaller than pixel-by-pixel fill
    assert_operator rom_dma.size, :<, rom_pixel.size / 10,
      "DMA clear should be dramatically smaller than pixel fill"
  end

  # ========================================================================
  # fill_rect: the copy engine a row at a time, where that is cheaper
  # ========================================================================

  def test_a_wide_fill_rect_fills_each_row_with_one_transfer
    rom = build do
      screen :bitmap
      fill_rect 10, 10, 40, 3, :green
      halt
    end

    # 3 rows = 3 DMA transfers, each writing to DMA3CNT
    assert_equal 3, find_store_targets(rom).count(REG_DMA3CNT), "3-row fill should emit 3 DMA3CNT writes"
  end

  def test_an_odd_edge_or_width_still_fills_each_row_with_one_transfer
    rom = build do
      screen :bitmap
      fill_rect 11, 10, 41, 3, :green
      halt
    end

    assert_equal 3, find_store_targets(rom).count(REG_DMA3CNT)
  end

  # A row is one start of the copy engine: its address built once, then three stores
  # (GBATEK, "DMA Transfers"), with the row's own destination built between them. So a
  # row costs a dozen instructions however wide it is, where a store per pixel costs four
  # instructions a pixel.
  def test_a_big_fill_rect_costs_a_dozen_instructions_a_row
    shorter = code_bytes(VBlank::IR::Build.fill_rect(10, 10, 40, 29, :blue))
    taller = code_bytes(VBlank::IR::Build.fill_rect(10, 10, 40, 30, :blue))

    assert_operator taller - shorter, :<=, 12 * 4
  end

  # Below four pixels across, a row of stores is no dearer than a start of the copy engine
  # (four instructions a pixel against eleven a row), and has no set-up, so it stays stores.
  def test_a_narrow_fill_rect_stays_stores
    rom = build do
      screen :bitmap
      fill_rect 10, 10, 3, 3, :green
      halt
    end

    assert_equal 0, find_store_targets(rom).count(REG_DMA3CNT)
  end

  # ========================================================================
  # Integration: DMA clear looks correct in mGBA
  # ========================================================================

  def test_clear_screen_renders_in_mgba
    rom = build do
      screen :bitmap
      clear_screen :red
      halt
    end

    verifier = assert_emulator_loads_rom(rom, frames: 5)
    # Center pixel should be red
    assert verifier.red?(120, 80), "center should be red after clear_screen :red"
    # Corners too
    assert verifier.red?(0, 0), "top-left should be red"
    assert verifier.red?(239, 159), "bottom-right should be red"
  end

  def test_fill_rect_renders_in_mgba
    rom = build do
      screen :bitmap
      clear_screen :black
      fill_rect 100, 60, 40, 40, :green
      halt
    end

    verifier = assert_emulator_loads_rom(rom, frames: 5)
    # Inside the rect should be green
    assert verifier.green?(120, 80), "center of rect should be green"
    # Outside should be black
    assert verifier.black?(10, 10), "outside rect should be black"
  end

  # A two-pixel transfer lands only on an even column, so an odd edge goes a pixel at a time.
  # Each edge pixel is in, and the one beside it, which a shifted fill would cover, is not.
  def test_an_odd_edged_fill_rect_lands_where_it_was_asked
    rom = build do
      screen :bitmap
      clear_screen :black
      fill_rect 11, 10, 41, 3, :green
      halt
    end

    verifier = assert_emulator_loads_rom(rom, frames: 5)
    assert verifier.green?(11, 10)
    assert verifier.green?(51, 12)
    assert verifier.black?(10, 10)
    assert verifier.black?(52, 12)
    assert verifier.black?(11, 13)
  end

  def test_game_loop_with_clear_screen_runs
    rom = build do
      screen :bitmap
      game_loop do
        clear_screen :black
        fill_rect 100, 60, 40, 40, :white
      end
    end

    assert_emulator_loads_rom(rom, frames: 10)
  end

  private

  # The bytes of ARM a program of +statement+ lowers to, before the cartridge is padded out.
  def code_bytes(statement)
    b = VBlank::IR::Build
    VBlank::IR::Backends::GBA.new.lower(b.program(b.screen(:bitmap), statement, b.halt, console: :gba)).bytesize
  end

  # Scan the instruction stream for load_immediate sequences that put an address in r1,
  # then look for the stores made through it.
  # Returns an array of target addresses that were stored to.
  def find_store_targets(rom)
    targets = []
    start = VBlank::Cartridge::ROM::ENTRY_OFFSET
    offset = start

    while offset + 4 <= rom.buffer.bytesize
      word = rom.buffer[offset, 4].unpack1("V")
      break if word == 0

      # Look for load_immediate sequences targeting r1 (address register)
      # followed by STR r0, [r1]
      # Simplified: just decode load_immediate values going into r1
      opcode = (word >> 21) & 0xF
      rd = (word >> 12) & 0xF
      i_bit = (word >> 25) & 1

      if rd == 1 && i_bit == 1 && (opcode == 0xD || opcode == 0xC)
        # This is loading a value into r1 — track the accumulated value
        imm8 = word & 0xFF
        rot = ((word >> 8) & 0xF) * 2
        rotated = rot == 0 ? imm8 : (((imm8 >> rot) | (imm8 << (32 - rot))) & 0xFFFFFFFF)

        if opcode == 0xD  # MOV
          @_tracking_r1 = rotated
        elsif opcode == 0xC  # ORR
          @_tracking_r1 = (@_tracking_r1 || 0) | rotated
        end
      elsif (word & 0x0FFF0000) == 0x05810000  # STR rd, [r1, #step]
        # The step matters: the engine's three registers sit side by side, so only the first
        # address is built and the other two are stored a step along from it.
        targets << (@_tracking_r1 + (word & 0xFFF)) if @_tracking_r1
      end

      offset += 4
    end

    targets
  end
end
