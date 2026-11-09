# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_input"

# THE BUTTONS ON THE ADVANCE'S CARTRIDGE: the branches a button test is built of, and the presses
# the cartridge counts in the emulator. The buttons as every run plays them are in
# test/all/vblank/builder/test_input.rb.
class TestInputCartridge < Minitest::Test
  include InputGames
  include VBlank::Console::Hardware

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
  # held
  # ========================================================================

  def test_held_builds_without_error
    rom = build do
      screen :bitmap
      player_y = 80
      game_loop do
        player_y -= 2 if held(:up)
      end
    end

    assert_operator rom.size, :>, 0
  end

  def test_held_all_buttons
    # Every button should be accepted without error
    %i[a b select start right left up down r l].each do |btn|
      rom = build do
        x = var :x, 0
        x = 1 if held(btn)
        halt
      end
      assert_operator rom.size, :>, 0, "button #{btn} should work"
    end
  end

  def test_held_emits_conditional_branch
    rom = build do
      y = var :y, 0
      y = 1 if held(:up)
      halt
    end

    insts = instructions(rom)
    # Should contain a BNE (cond=0x1) that skips over the block
    has_bne = insts.any? { |i| branch?(i) && cond(i) == 0x1 }
    assert has_bne, "expected BNE (skip block if button not pressed)"
  end

  def test_held_branch_skips_correct_distance
    rom = build do
      x = var :x, 0
      x = 42 if held(:a)
      halt
    end

    insts = instructions(rom)
    # Find the BNE instruction
    bne_idx = insts.index { |i| branch?(i) && cond(i) == 0x1 }
    refute_nil bne_idx, "should have a BNE"

    # Decode the branch target
    offset = signed_branch_offset(insts[bne_idx])
    target_idx = bne_idx + 2 + offset  # PC is 2 ahead

    # The halt (loop_forever) should be at or after target_idx
    halt_idx = insts.index(0xEAFFFFFE)
    assert_operator target_idx, :<=, halt_idx + 1,
      "BNE should skip to the instruction after the set block"
  end

  # ========================================================================
  # pressed (edge detection)
  # ========================================================================

  def test_pressed_builds_without_error
    rom = build do
      state = 0
      screen :bitmap
      game_loop do
        state = 1 if pressed(:start)
      end
    end

    assert_operator rom.size, :>, 0
  end

  def test_pressed_emits_beq
    rom = build do
      state = var :state, 0
      state = 1 if pressed(:start)
      halt
    end

    insts = instructions(rom)
    # A press test uses BEQ to skip (Z=1 means not newly pressed)
    has_beq = insts.any? { |i| branch?(i) && cond(i) == 0x0 }
    assert has_beq, "expected BEQ (skip block if button not newly pressed)"
  end

  # A button held from power on is one press on the cartridge too (InputGames#counting_presses).
  def test_a_button_held_from_power_on_is_one_press_on_the_cartridge
    rom = assemble_rom(counting_presses, name: "HELDPOWER")
    v = assert_emulator_loads_rom(rom, frames: 7, keys: KEY_START, vars: rom.var_addresses)
    assert_equal [1, 0], [v.var(:presses), v.var(:before_the_loop)]
  end

  KEY_BITS = { left: KEY_LEFT, a: KEY_A, b: KEY_B }.freeze

  # Any button held and pressed on the cartridge (InputGames#counting_any_button), the presses
  # played four frames later for the frames the cartridge spends setting up.
  def test_any_button_is_held_and_pressed_on_the_cartridge
    rom = assemble_rom(counting_any_button, name: "ANYBUTTON")
    keys = ->(frame) { ANY_BUTTON_FRAMES.fetch(frame - 4, []).sum { |button| KEY_BITS.fetch(button) } }
    v = assert_emulator_loads_rom(rom, frames: 20, keys: keys, vars: rom.var_addresses)
    assert_equal [6, 3], [v.var(:held_frames), v.var(:presses)]
  end

  # A press is never lost to a slow game (InputGames#slow_game_counting_presses).
  def test_a_slow_game_counts_every_tap_once_on_the_console
    rom = assemble_rom(slow_game_counting_presses, name: "SLOWTAPS")
    TAPPED.each do |what, down|
      keys = ->(frame) { down.include?(frame) ? KEY_A : 0 }
      v = assert_emulator_loads_rom(rom, frames: 40, keys: keys, vars: rom.var_addresses)

      assert_equal 1, v.var(:presses), "A held #{what}"
    end
  end

  # A TAP WHILE THE GAME SETS UP IS NOT A PRESS. The screen is off until the game loop's first
  # frame, so nothing a player does then has anything to answer — and the console reads no
  # buttons for the game before it either, the way a retail game reads none before its main
  # loop. A button still down when the loop starts is one press, like one held from power-on.
  #
  # Console only: the interpreter's setting up takes no frames, so a tap cannot land in it.
  # Twenty whole-screen clears above the loop are several frames of setting up.
  private def slow_setup_counting_presses
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      presses = 0
      repeat(20) { clear_screen :blue }
      game_loop { presses += 1 if pressed(:a) }
    end
    builder.finalize_program
    builder.program
  end

  def test_a_tap_while_the_game_sets_up_is_not_a_press
    rom = assemble_rom(slow_setup_counting_presses, name: "SETUPTAP")
    tap = ->(frame) { frame == 1 ? KEY_A : 0 }
    still_down = ->(frame) { frame >= 1 ? KEY_A : 0 }

    assert_equal 0, assert_emulator_loads_rom(rom, frames: 20, keys: tap, vars: rom.var_addresses).var(:presses),
                 "a tap made and let go while the game set up"
    assert_equal 1, assert_emulator_loads_rom(rom, frames: 20, keys: still_down, vars: rom.var_addresses).var(:presses),
                 "a button pressed while the game set up and still down when the loop starts"
  end

  # ========================================================================
  # Integration: runs in mGBA
  # ========================================================================

  def test_input_rom_runs_in_mgba
    rom = build do
      screen :bitmap
      player_y = 80
      game_loop do
        player_y -= 2 if held(:up)
        player_y += 2 if held(:down)
        player_y = 80 if pressed(:start)
      end
    end

    assert_emulator_loads_rom(rom, frames: 10)
  end

  private

  def branch?(inst)
    (inst & 0x0E000000) == 0x0A000000
  end

  def cond(inst)
    (inst >> 28) & 0xF
  end

  def signed_branch_offset(inst)
    offset = inst & 0x00FFFFFF
    (offset & 0x800000) != 0 ? offset - 0x1000000 : offset
  end
end
