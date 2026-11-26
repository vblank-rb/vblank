# frozen_string_literal: true

require "test_helper"

# Saving on a Genesis cartridge. Its battery-backed RAM holds the same bytes the interpreter's
# IR::SaveImage holds, so a save made by either starts the game on the other, and a save survives the
# console going off: two runs handed the same image are a power cycle.
class TestGenesisSaves < Minitest::Test
  Genesis = VBlank::IR::Backends::Genesis
  GenesisReading = VBlank::Diagnostics::GenesisReading

  COUNTING_UP = VBlank.game("COUNT", consoles: %i[gba genesis]) do
    best = save_var :best, 5
    game_loop { best += 2 }
  end

  # A saved number only read, so what it holds after a pass is what it started with.
  # A record in save memory, written, read back and summed by the game itself.
  RECORDS = VBlank.game("RECORDS", consoles: %i[gba genesis]) do
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

  READING = VBlank.game("READING", consoles: %i[gba genesis]) do
    best = save_var :best, 5
    seen = 0
    game_loop { seen = best }
  end

  private def counting_up = COUNTING_UP.program(console: :genesis)

  def test_a_game_started_with_empty_save_memory_reads_the_defaults
    run = Genesis::CheckedRun.new(save: SaveImage.new).run(READING.program(console: :genesis), frames: 1)

    assert_equal 5, run[:seen]
  end

  def test_a_save_var_comes_back_after_the_power_goes_off
    store = SaveImage.new
    Genesis::CheckedRun.new(save: store).run(counting_up, frames: 3)

    again = Genesis::CheckedRun.new(save: store).run(counting_up, frames: 2)

    assert_equal 15, again[:best], "three frames took it to 11, and two more from there"
  end

  def test_the_save_memory_a_run_leaves_is_the_interpreters_byte_for_byte
    interpreters = SaveImage.new
    Reference.new(save: interpreters).run(counting_up, frames: 3)

    cartridges = SaveImage.new
    Genesis::HeadlessRun.new(save: cartridges).run(counting_up, frames: 3)

    assert_equal 11, cartridges.word(VBlank::IR::SaveLayout.save_var_at(0))
    assert_equal interpreters.to_sav, cartridges.to_sav
  end

  def test_a_save_the_interpreter_made_starts_the_cartridge
    store = SaveImage.new
    Reference.new(save: store).run(counting_up, frames: 3)

    assert_equal 13, Genesis::HeadlessRun.new(save: store).run(counting_up, frames: 1)[:best]
  end

  def test_a_save_record_is_written_and_read_back_as_the_interpreter_does
    run = Genesis::CheckedRun.new(save: SaveImage.new).run(RECORDS.program(console: :genesis), frames: 8)

    assert_equal 9, run[:loaded]
  end

  def test_a_sum_of_save_memory_is_the_interpreters_checksum
    build = VBlank::IR::Build
    sums = build.program(build.save_write(build.int(0x7FFC), build.int(0x0102_03FF)),
                         build.set(:whole, build.save_sum(build.int(0x7FFC), build.int(4))),
                         # An odd count, and the last byte alone.
                         build.set(:odd, build.save_sum(build.int(0x7FFC), build.int(3))),
                         build.set(:last, build.save_sum(build.int(0x7FFF), build.int(1))),
                         build.set(:empty, build.save_sum(build.int(0x7FFC), build.int(0))),
                         build.set(:none, build.save_sum(build.int(0x7FFC), build.int(-5))),
                         # From far past the 32K, back to its end: no bytes, so nothing to stop for.
                         build.set(:from_far, build.save_sum(build.int(0x10000), build.int(-0x8000))), build.halt)

    run = Genesis::CheckedRun.new.run(sums, frames: 1)

    assert_equal VBlank::IR::SaveLayout.checksum([0xFF, 0x03, 0x02, 0x01]), run[:whole]
    assert_equal VBlank::IR::SaveLayout.checksum([0xFF, 0x03, 0x02]), run[:odd]
    assert_equal VBlank::IR::SaveLayout.checksum([0x01]), run[:last]
    assert_equal 0, run[:empty]
    assert_equal 0, run[:none]
    assert_equal 0, run[:from_far]
  end

  def test_the_header_names_32k_of_battery_backed_ram_on_odd_bytes
    rom = Genesis.new.build(counting_up)

    assert_equal "RA\xF8\x20".b + [0x200001, 0x20FFFF].pack("N2"), rom.bytes.byteslice(0x1B0, 12)
  end

  def test_a_game_that_never_saves_names_no_memory_in_its_header
    rom = Genesis.new.build(VBlank.game("NOSAVE", consoles: %i[gba genesis]) { game_loop { nil } }.program(console: :genesis))

    assert_equal " " * 12, rom.bytes.byteslice(0x1B0, 12)
  end

  # What Genesis Plus GX does with that header: the save memory is on the odd bytes of the 64K file the
  # emulator's gem writes as it shuts the core. Six frames take the number from 5 to 11.
  def test_genesis_plus_gx_keeps_the_save_on_odd_bytes
    rom = Genesis.new.build(counting_up)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "game.gen")
      rom.write(path)
      core = VBlank::Diagnostics::Emulator.open_genesis(path, save_dir: dir)
      6.times { core.run_frame } # the first passes come after a few frames of booting
      core.destroy
      file = File.binread(File.join(dir, "game.srm"))

      assert_equal 0x10000, file.bytesize
      assert_equal 11, file.getbyte((2 * VBlank::IR::SaveLayout.save_var_at(0)) + 1)
    end
  end

  def test_a_game_that_saves_and_is_bigger_than_2mb_is_refused
    build = VBlank::IR::Build
    big = build.table(:big, Array.new(0x200000, 1), width: :byte, signed: false)
    program = build.program(big, build.save_write(build.int(0), build.table_get(:big, build.int(0))), build.halt,
                            console: :genesis)

    error = assert_raises(VBlank::BuildError) { Genesis.new.build(program) }
    assert_includes error.message, "fit in 2 MB"
  end

  # A length so long the place and it pass the largest number is past the save too.
  def test_a_sum_whose_end_passes_the_largest_number_stops_as_the_interpreter_does
    build = VBlank::IR::Build
    program = build.program(build.set(:sum, build.save_sum(build.int(0x7FFF), build.int(0x7FFFFFFF))), build.halt)
    expected = assert_raises(VBlank::IR::ProgramError) { Reference.new.run(program, frames: 1) }
    error = assert_raises(VBlank::IR::ProgramError) { Genesis::HeadlessRun.new.run(program, frames: 1) }

    assert_equal expected.message, error.message
  end

  def test_an_odd_byte_save_file_holds_the_save_memory_on_its_odd_bytes
    layout = GenesisReading::SAVE_FILE

    assert_equal "\xFF\x01\xFF\x02".b, layout.file_of("\x01\x02".b)
    assert_equal "\x01\x02".b, layout.memory_in(layout.file_of("\x01\x02".b))
  end

  # The last word of the 32K is inside, a word one byte later is not, and neither is a place below
  # nought: the cartridge stops where the interpreter stops, in its words.
  def test_a_place_outside_the_32k_stops_the_game_as_the_interpreter_does
    build = VBlank::IR::Build
    inside = build.program(build.save_write(build.int(0x7FFC), build.int(7)),
                           build.set(:read, build.save_read(build.int(0x7FFC))), build.halt)
    assert_equal 7, Genesis::CheckedRun.new.run(inside, frames: 1)[:read]

    [build.save_write(build.int(0x7FFD), build.int(7)), build.set(:read, build.save_read(build.int(-1)))].each do |step|
      outside = build.program(step, build.halt)
      expected = assert_raises(VBlank::IR::ProgramError) { Reference.new.run(outside, frames: 1) }
      error = assert_raises(VBlank::IR::ProgramError) { Genesis::HeadlessRun.new.run(outside, frames: 1) }

      assert_equal expected.message, error.message
    end
  end
end
