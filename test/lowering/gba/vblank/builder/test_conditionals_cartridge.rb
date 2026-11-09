# frozen_string_literal: true

require "test_helper"

# A game's comparisons (`if state == 0`, `if score > 3` and the rest) on the Advance's own
# cartridge: that each builds, that each skips its block with the opposite branch, and that a game
# of them runs in the emulator. Every test here asks the cartridge, so the whole file is the GBA
# lowering's.
class TestConditionalsCartridge < Minitest::Test
  include VBlank::Console::Hardware

  private def build(validate: false, &block)
    VBlank.build("CONDTEST", console: :gba, code: "BCND", maker: "01", validate: validate, out: nil, err: nil, &block)
  end

  private def instructions(rom)
    start = VBlank::Cartridge::ROM::ENTRY_OFFSET
    result = []
    offset = start
    while offset + 4 <= rom.buffer.bytesize
      word = rom.buffer[offset, 4].unpack1("V")
      break if word == 0
      result << word
      offset += 4
    end
    result
  end

  # ========================================================================
  # == and != — variable against a number
  # ========================================================================

  def test_equal_builds
    rom = build do
      x = var :x, 0
      state = var :state, 0
      x = 1 if state == 0
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_not_equal_builds
    rom = build do
      x = var :x, 0
      state = var :state, 1
      x = 1 if state != 0
      halt
    end
    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # > < >= <= — variable against a number
  # ========================================================================

  def test_greater_builds
    rom = build do
      winner = var :winner, 0
      score = var :score, 5
      winner = 1 if score > 3
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_less_builds
    rom = build do
      y = var :y, 0
      y = 10 if y < 10
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_at_least_builds
    rom = build do
      state = var :state, 0
      score = var :score, 5
      state = 2 if score >= 5
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_at_most_builds
    rom = build do
      dy = var :dy, 0
      y = var :y, 0
      dy = 1 if y <= 0
      halt
    end
    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # Variable against variable
  # ========================================================================

  def test_greater_variable_against_variable
    rom = build do
      cpu_y = var :cpu_y, 0
      ball_y = var :ball_y, 100
      cpu_center = var :cpu_center, 80
      cpu_y += 1 if ball_y > cpu_center
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_less_variable_against_variable
    rom = build do
      cpu_y = var :cpu_y, 0
      ball_y = var :ball_y, 50
      cpu_center = var :cpu_center, 80
      cpu_y -= 1 if ball_y < cpu_center
      halt
    end
    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # A comparison skips its block with the opposite branch
  # ========================================================================

  def test_equal_emits_bne_to_skip
    rom = build do
      x = var :x, 0
      state = var :state, 0
      x = 1 if state == 0
      halt
    end

    insts = instructions(rom)
    has_bne = insts.any? { |i| branch?(i) && cond(i) == 0x1 }
    assert has_bne, "`if state == 0` should emit BNE to skip its block"
  end

  def test_greater_emits_ble_to_skip
    rom = build do
      winner = var :winner, 0
      score = var :score, 5
      winner = 1 if score > 3
      halt
    end

    insts = instructions(rom)
    has_ble = insts.any? { |i| branch?(i) && cond(i) == 0xD }
    assert has_ble, "`if score > 3` should emit BLE to skip its block"
  end

  def test_less_emits_bge_to_skip
    rom = build do
      y = var :y, 0
      y = 10 if y < 10
      halt
    end

    insts = instructions(rom)
    has_bge = insts.any? { |i| branch?(i) && cond(i) == 0xA }
    assert has_bge, "`if y < 10` should emit BGE to skip its block"
  end

  # ========================================================================
  # Large immediate (can't encode as rotated 8-bit)
  # ========================================================================

  def test_at_least_a_large_immediate
    rom = build do
      ball_dy = var :ball_dy, 0
      ball_y = var :ball_y, 156
      ball_dy = 0 if ball_y >= 156
      halt
    end
    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # Nested conditionals
  # ========================================================================

  def test_nested_conditionals
    rom = build do
      score = var :score, 5
      state = var :state, 1
      if score >= 5
        state = 2 if state == 1
      end
      halt
    end
    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # Integration: runs in mGBA
  # ========================================================================

  def test_conditionals_run_in_mgba
    rom = build do
      screen :bitmap
      ball_x = var :ball_x, 120
      ball_y = var :ball_y, 80
      game_loop do
        clear_screen :black
        ball_x += 1
        ball_x = 0 if ball_x >= 240
        ball_y = 0 if ball_y <= 0
      end
    end

    assert_emulator_loads_rom(rom, frames: 60)
  end

  private

  def branch?(inst)
    (inst & 0x0E000000) == 0x0A000000
  end

  def cond(inst)
    (inst >> 28) & 0xF
  end
end
