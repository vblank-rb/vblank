# frozen_string_literal: true

require "test_helper"

# SAVING ON A SUPER NINTENDO CARTRIDGE. Its battery-backed RAM holds the same bytes the
# interpreter's IR::SaveImage holds, so a save made by either starts the game on the other, and a
# save survives the console going off: two runs handed the same image are a power cycle.
class TestSNESSaves < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  COUNTING_UP = VBlank.game("COUNT", consoles: %i[gba snes]) do
    best = save_var :best, 5
    game_loop { best += 2 }
  end

  # A record in save memory, written, read back and summed by the game itself.
  RECORDS = VBlank.game("RECORDS", consoles: %i[gba snes]) do
    score = 0
    loaded = 0
    files = save_data(:files) { keep score }
    game_loop do
      score += 3
      files[0].save if score == 9
      if score == 15
        score = 0
        files[0].load
        loaded = score
      end
    end
  end

  # A saved number only read, so what it holds after a pass is what it started with.
  READING = VBlank.game("READING", consoles: %i[gba snes]) do
    best = save_var :best, 5
    seen = 0
    game_loop { seen = best }
  end

  private def counting_up = COUNTING_UP.program(console: :snes)

  def test_a_game_started_with_empty_save_memory_reads_the_defaults
    run = SNES::CheckedRun.new(save: SaveImage.new).run(READING.program(console: :snes), frames: 1)

    assert_equal 5, run[:seen]
  end

  def test_a_save_var_comes_back_after_the_power_goes_off
    store = SaveImage.new
    SNES::CheckedRun.new(save: store).run(counting_up, frames: 3)

    again = SNES::CheckedRun.new(save: store).run(counting_up, frames: 2)

    assert_equal 15, again[:best], "three frames took it to 11, and two more from there"
  end

  def test_the_save_memory_a_run_leaves_is_the_interpreters_byte_for_byte
    interpreters = SaveImage.new
    Reference.new(save: interpreters).run(counting_up, frames: 3)

    cartridges = SaveImage.new
    SNES::HeadlessRun.new(save: cartridges).run(counting_up, frames: 3)

    assert_equal 11, cartridges.word(VBlank::IR::SaveLayout.save_var_at(0))
    assert_equal interpreters.to_sav, cartridges.to_sav
  end

  def test_a_save_the_interpreter_made_starts_the_cartridge
    store = SaveImage.new
    Reference.new(save: store).run(counting_up, frames: 3)

    assert_equal 13, SNES::HeadlessRun.new(save: store).run(counting_up, frames: 1)[:best]
  end

  def test_a_save_record_is_written_and_read_back_as_the_interpreter_does
    run = SNES::CheckedRun.new(save: SaveImage.new).run(RECORDS.program(console: :snes), frames: 8)

    assert_equal 9, run[:loaded]
  end

  def test_the_header_says_32k_of_battery_backed_ram
    rom = SNES.new.build(counting_up)

    assert_equal 0x02, rom.bytes.getbyte(0x7FD6), "ROM, RAM and a battery"
    assert_equal 5, rom.bytes.getbyte(0x7FD8), "2^5 kilobytes"
  end

  # HOW BSNES TAKES THE CARTRIDGE, the ground truth for what the header asks of real hardware: the
  # board its heuristics pick from the header (type $02, RAM size 5: LoROM with RAM, and for a
  # cartridge of 2MB or less the "#A" board, whose RAM fills both halves of its banks), the save RAM
  # it gives the cartridge, and the reader's idea of the save file, all one size, the header's.
  def test_bsnes_takes_a_saving_cartridge_for_a_lorom_board_with_32k_of_ram
    rom = SNES.new.build(counting_up)
    board, save_bytes = with_core(rom) { |core| [core.board, core.save_ram.bytesize] }

    assert_equal "LOROM-RAM#A", board
    assert_equal 0x8000, save_bytes
    assert_equal 1024 << rom.bytes.getbyte(0x7FD8), save_bytes, "the size the header says"
    assert_equal save_bytes, VBlank::Diagnostics::SNESReading::SAVE_FILE.whole
  end

  # WHERE BSNES PUTS THE RAM: banks $70 to $7D, the same 32K in each. A byte the processor stores at
  # $70:7FFF is the save RAM's last, and one stored at $7D:0001 its second. On a cartridge of 2MB or
  # less (LOROM-RAM#A) the banks' upper halves are the same RAM again, so $70:8000 is its first byte;
  # on a bigger one (LOROM-RAM) they are the cartridge's ROM, and a byte stored there goes nowhere.
  # The runtime stores only at $70:0000-$7FFF, which is the save RAM on both.
  def test_bsnes_maps_the_save_ram_at_70_to_7d
    ram, seen = with_core(save_ram_writer) { |core| [core.save_ram, core.wram_read8(SEEN_AT_8000)] }

    assert_equal [0x5A, 0x3C, 0xA5, 0xA5], [ram.getbyte(0x7FFF), ram.getbyte(1), ram.getbyte(0), seen]
  end

  def test_bsnes_keeps_rom_over_the_save_ram_banks_upper_half_on_a_big_cartridge
    board, ram, seen = with_core(save_ram_writer(banks: 128)) { |core| [core.board, core.save_ram, core.wram_read8(SEEN_AT_8000)] }

    assert_equal "LOROM-RAM", board
    assert_equal [0x5A, 0x3C], [ram.getbyte(0x7FFF), ram.getbyte(1)]
    assert_equal 0, ram.count(0xA5.chr), "nothing stored at $70:8000 reaches the save RAM"
    refute_equal 0xA5, seen, "$70:8000 reads the cartridge's ROM back, not what was stored"
  end

  SEEN_AT_8000 = 0x0010 # where the cartridge below keeps what it read back from $70:8000

  # A cartridge with 32K of battery-backed RAM that stores $5A at $70:7FFF, $3C at $7D:0001 and $A5
  # at $70:8000, then reads $70:8000 back into work RAM; +banks+ of 32K of ROM, the rest left blank.
  private def save_ram_writer(banks: nil)
    asm = SNES::W65816.new("boot", home: :first)
    asm.instance_eval do
      label "reset"
      sei
      clc
      xce
      sep 0x20
      lda 0x5A
      sta long(0x707FFF)
      lda 0x3C
      sta long(0x7D0001)
      lda 0xA5
      sta long(0x708000)
      lda long(0x708000)
      sta long(SEEN_AT_8000)
      label "forever"
      bra "forever"
    end
    linked = SNES::Linker.new([asm.section]).link
    filled = banks ? linked.banks + Array.new(banks - linked.banks.length) { "\0".b * 0x8000 } : linked.banks
    VBlank::Cartridge::SNESROM.new(filled, title: "SAVE MAP", vectors: { reset: linked.address_of("reset") & 0xFFFF },
                                           save_bytes: 0x8000)
  end

  # +rom+ played for a few frames in bsnes, and what the block makes of the core.
  private def with_core(rom)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "game.sfc")
      rom.write(path)
      core = VBlank::Diagnostics::Emulator.open_snes(path)
      3.times { core.run_frame }
      yield core
    ensure
      core&.destroy
    end
  end

  # The last word of the 32K is inside, a word one byte later is not, and neither is a place below
  # nought: the cartridge stops where the interpreter stops, in its words.
  def test_a_place_outside_the_32k_stops_the_game_as_the_interpreter_does
    build = VBlank::IR::Build
    inside = build.program(build.save_write(build.int(0x7FFC), build.int(7)),
                           build.set(:read, build.save_read(build.int(0x7FFC))), build.halt)
    assert_equal 7, SNES::CheckedRun.new.run(inside, frames: 1)[:read]

    [build.save_write(build.int(0x7FFD), build.int(7)), build.set(:read, build.save_read(build.int(-1)))].each do |step|
      outside = build.program(step, build.halt)
      expected = assert_raises(VBlank::IR::ProgramError) { Reference.new.run(outside, frames: 1) }
      error = assert_raises(VBlank::IR::ProgramError) { SNES::HeadlessRun.new.run(outside, frames: 1) }

      assert_equal expected.message, error.message
    end
  end

  def test_a_sum_of_save_memory_is_the_interpreters_checksum
    build = VBlank::IR::Build
    sums = build.program(build.save_write(build.int(0x7FFC), build.int(0x0102_03FF)),
                         build.set(:whole, build.save_sum(build.int(0x7FFC), build.int(4))),
                         # An odd count, and the last byte alone: the loop sums two a time round.
                         build.set(:odd, build.save_sum(build.int(0x7FFC), build.int(3))),
                         build.set(:last, build.save_sum(build.int(0x7FFF), build.int(1))),
                         build.set(:empty, build.save_sum(build.int(0x7FFC), build.int(0))),
                         build.set(:none, build.save_sum(build.int(0x7FFC), build.int(-5))),
                         # From far past the 32K, back to its end: no bytes, so nothing to stop for.
                         build.set(:from_far, build.save_sum(build.int(0x10000), build.int(-0x8000))), build.halt)

    run = SNES::CheckedRun.new.run(sums, frames: 1)

    assert_equal VBlank::IR::SaveLayout.checksum([0xFF, 0x03, 0x02, 0x01]), run[:whole]
    assert_equal VBlank::IR::SaveLayout.checksum([0xFF, 0x03, 0x02]), run[:odd]
    assert_equal VBlank::IR::SaveLayout.checksum([0x01]), run[:last]
    assert_equal 0, run[:empty]
    assert_equal 0, run[:none]
    assert_equal 0, run[:from_far]
  end

  # `save_memory: 128` is the Advance's flash. A Super Nintendo cartridge has none, so the game
  # built for it saves in the 32K of battery-backed RAM its records fit in.
  def test_a_game_naming_the_advances_flash_saves_in_the_cartridges_battery_backed_ram
    game = VBlank.game("FLASHY", consoles: %i[gba snes], save_memory: 128) do
      best = save_var :best, 5
      game_loop { best += 1 }
    end
    store = SaveImage.new
    SNES::CheckedRun.new(save: store).run(game.program(console: :snes), frames: 3)

    assert_equal VBlank::IR::SaveLayout::PACKED, store.memory
    assert_equal 8, store.word(VBlank::IR::SaveLayout.save_var_at(0))
  end

  # A program that names save memory the cartridge does not keep is refused in plain words.
  def test_save_memory_the_cartridge_does_not_keep_is_refused_in_plain_words
    build = VBlank::IR::Build
    flash = build.program(build.save_memory(128), build.save_write(build.int(0), build.int(7)), build.halt)

    error = assert_raises(SNES::LoweringError) { SNES.new.build(flash) }

    assert_match(/128K of flash/, error.message)
    assert_match(/32K of battery-backed RAM/, error.message)
  end

  # SAVING ON A SUPER FX CARTRIDGE, while the chip paints the screen every pass: the chip's RAM at
  # $70 holds the painted screen, and the save is in a bank of its own past it
  # (Cartridge::SNESROM::SUPER_FX). A rectangle the chip paints moves with the saved number, so a
  # save landing in the picture, or the picture in the save, shows on the pass it happens.
  FX_COUNTING = VBlank.game("FX COUNT", consoles: %i[gba snes], variants: { snes: :superfx }) do
    screen :bitmap
    best = save_var :best, 5
    game_loop do
      clear_screen :black
      draw_rect_at (best & 63) + 10, 40, 20, 20, :green
      fill_rect 0, 0, 240, 8, :white
      best += 2
    end
  end

  # A record saved, the game started over (`reset`, which leaves save memory alone), and the
  # record loaded back, with the chip painting throughout.
  FX_RECORDS = VBlank.game("FX RECORDS", consoles: %i[gba snes], variants: { snes: :superfx }) do
    screen :bitmap
    score = 1
    after_reset = 0
    loaded = 0
    files = save_data(:files) { keep score }
    game_loop do
      clear_screen :blue
      draw_rect_at score, 30, 12, 12, :yellow
      score += 3
      files[0].save if score == 10
      if score == 16
        files.reset
        after_reset = score
        files[0].load
        loaded = score
      end
    end
  end

  private def fx_counting = FX_COUNTING.program(console: :snes, variant: :superfx)

  def test_a_save_var_comes_back_after_the_power_goes_off_on_a_super_fx_cartridge
    store = SaveImage.new
    SNES::CheckedRun.new(save: store).run(fx_counting, frames: 3)

    again = SNES::CheckedRun.new(save: store).run(fx_counting, frames: 2)

    assert_equal 15, again[:best], "three passes took it to 11, and two more from there"
    assert_equal 15, store.word(VBlank::IR::SaveLayout.save_var_at(0))
  end

  def test_a_save_the_interpreter_made_starts_a_super_fx_cartridge
    store = SaveImage.new
    Reference.new(save: store).run(fx_counting, frames: 3)

    assert_equal 13, SNES::HeadlessRun.new(save: store).run(fx_counting, frames: 1)[:best]
  end

  def test_a_record_reset_and_loaded_on_a_super_fx_cartridge_is_the_interpreters
    run = SNES::CheckedRun.new(save: SaveImage.new).run(FX_RECORDS.program(console: :snes, variant: :superfx), frames: 8)

    assert_equal [1, 10], [run[:after_reset], run[:loaded]]
  end

  # The header asks for 128K of the chip's RAM kept by a battery, and bsnes gives the cartridge
  # that: the GSU board, with a save file of all 128K, the save the second 64K of it and the
  # painted screen still in the first 64K. A Super FX game that does not save keeps its 64K.
  def test_bsnes_keeps_a_super_fx_save_in_the_second_bank_of_the_chips_ram
    rom = SNES.new.build(fx_counting)
    board, ram = with_core(rom) { |core| [core.board, core.save_ram] }

    assert_equal [VBlank::Console::SNESHardware::SUPER_FX_RAM_BATTERY, 7],
                 [rom.bytes.getbyte(0x7FD6), rom.bytes.getbyte(VBlank::Console::SNESHardware::EXPANSION_RAM_AT)]
    assert_equal "GSU-RAM", board
    assert_equal 0x20000, ram.bytesize
    saved = VBlank::Diagnostics::SNESReading.save_file_of(rom.bytes).memory_in(ram)
    assert_equal 0x10000, saved.bytesize
    best = saved.byteslice(VBlank::IR::SaveLayout.save_var_at(0), 4).unpack1("V")
    assert_predicate best, :odd?, "counted up from 5 by twos"
    assert_operator best, :>, 5
    assert ram.byteslice(0, 0x10000).bytes.any?(&:positive?), "the painted screen is in the first 64K"
  end

  # SAVES OF MORE THAN 32K ON A SUPER FX CARTRIDGE. The save is the whole of the chip's second
  # bank, $71, 64K of it: a record of a list of 3600 words is 14424 bytes a half, and its two
  # halves end past 32K. Saved twice, so both halves are written, then emptied and loaded back.
  FX_BIG_RECORDS = VBlank.game("FX BIG SAVES", consoles: %i[gba snes], variants: { snes: :superfx }) do
    marks = list :marks, capacity: 3600
    passes = 0
    loaded = 0
    files = save_data(:files) { keep marks }
    game_loop do
      passes += 1
      if passes == 2
        marks.push 7
        files[0].save
        marks.push 9
        files[0].save
      end
      if passes == 130
        marks.pop
        marks.pop
        files[0].load
        loaded = marks[1]
      end
    end
  end

  private def fx_big_records = FX_BIG_RECORDS.program(console: :snes, variant: :superfx)

  def test_a_super_fx_game_whose_saves_need_more_than_32k_saves_and_loads_them_as_the_interpreter_does
    store = SaveImage.new
    run = SNES::CheckedRun.new(save: store).run(fx_big_records, frames: 132)

    assert_equal 9, run[:loaded], "the second save, loaded back"
    assert_equal 0x10000, store.to_sav.bytesize, "the whole spare bank"
    assert store.written.keys.any? { |at| at >= 0x8000 }, "the record's second half is past 32K"
  end

  def test_a_super_fx_save_past_32k_is_the_interpreters_byte_for_byte
    interpreters = SaveImage.new
    Reference.new(save: interpreters).run(fx_big_records, frames: 132)

    cartridges = SaveImage.new
    SNES::HeadlessRun.new(save: cartridges).run(fx_big_records, frames: 132)

    assert_equal interpreters.to_sav, cartridges.to_sav
  end

  # The last word of the 64K is inside and a word one byte later is not; a sum of the whole bank,
  # a length whose low half is nought, sums every byte of it, as the interpreter does.
  def test_a_super_fx_save_ends_at_its_64k_as_the_interpreters_does
    build = VBlank::IR::Build
    fx = lambda do |*steps|
      build.program(build.save_memory(64, chip: :battery), *steps, build.halt, console: :snes, variant: :superfx)
    end
    inside = fx.call(build.save_write(build.int(0xFFFC), build.int(0x0102_0304)),
                     build.set(:read, build.save_read(build.int(0xFFFC))),
                     build.set(:whole, build.save_sum(build.int(0), build.int(0x10000))))
    run = SNES::CheckedRun.new.run(inside, frames: 1)

    assert_equal 0x0102_0304, run[:read]
    assert_equal VBlank::IR::SaveLayout.checksum(([0xFF] * 0xFFFC) + [4, 3, 2, 1]), run[:whole]

    outside = fx.call(build.save_write(build.int(0xFFFD), build.int(7)))
    expected = assert_raises(VBlank::IR::ProgramError) { Reference.new.run(outside, frames: 1) }
    error = assert_raises(VBlank::IR::ProgramError) { SNES::HeadlessRun.new.run(outside, frames: 1) }
    assert_equal expected.message, error.message
  end

  # A plain cartridge keeps 32K: the same game is refused, naming the bytes it needs, the bytes
  # the cartridge keeps, and what to change.
  def test_a_plain_cartridge_refuses_saves_of_more_than_32k_naming_the_bytes
    error = assert_raises(ArgumentError) { FX_BIG_RECORDS.program(console: :snes, variant: VBlank::Console::NO_VARIANT) }

    assert_match(/need 33528 bytes/, error.message, "the table's 4680, and two halves of 20 + 4 + 14400")
    assert_match(/32768 bytes/, error.message)
    assert_match(/fewer copies/, error.message)
    assert_match(/:superfx/, error.message)
  end

  def test_a_super_fx_game_that_does_not_save_keeps_64k_of_the_chips_ram
    game = VBlank.game("FX NO SAVE", consoles: %i[gba snes], variants: { snes: :superfx }) do
      screen :bitmap
      game_loop { clear_screen :black }
    end
    rom = SNES.new.build(game.program(console: :snes, variant: :superfx))

    assert_equal [VBlank::Console::SNESHardware::SUPER_FX_RAM, 6],
                 [rom.bytes.getbyte(0x7FD6), rom.bytes.getbyte(VBlank::Console::SNESHardware::EXPANSION_RAM_AT)]
    assert_same VBlank::Diagnostics::SNESReading::SAVE_FILE, VBlank::Diagnostics::SNESReading.save_file_of(rom.bytes)
  end
end
