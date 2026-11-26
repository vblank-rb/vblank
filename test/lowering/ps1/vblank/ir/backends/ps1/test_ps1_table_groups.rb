# frozen_string_literal: true

require "test_helper"

# A PlayStation game whose data is more than the console's 2 megabytes of RAM, kept in table groups
# (`table_groups`), built as a disc and played from it in Beetle PSX: each level's tables read from the
# disc into one room when the game loads the level, and the game held to the interpreter after every
# pass. The levels together are bigger than RAM; the program and the biggest level fit.
#
# How fast a level loads is the drive's: the console's own games read a level's sectors one after
# another at double speed, each sent to RAM by the DMA, while the game waits (psx-spx, "CDROM Controller
# Command Summary": Setmode bit 7, 150 sectors a second). A load here is held to that rate.
class TestPS1TableGroups < Minitest::Test
  PS1 = VBlank::IR::Backends::PS1

  # Words in each level's map, a level each: about 1300K, 600K and 500K, 2400K in all. The first is loaded
  # on the first pass and takes more than 255 frames to read.
  LEVEL_WORDS = [340_000, 150_000, 125_000].freeze

  # The entry each pass reads of the level loaded: one near each map's end, read from the disc.
  def self.entry(level, at) = (level * 1_000_000) + (at * 7)

  # Each pass loads the next level (0, 1, 2, then 0 again) and reads an entry of its map near the end,
  # a table every level shares, and how many times a 60-a-second timer has ticked: a pass that loads
  # takes many frames, and the timer counts them on both sides.
  private def levels_game
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :ps1))
    words = LEVEL_WORDS
    b.instance_eval do
      maps = words.each_with_index.map do |count, level|
        table :"map#{level}", Array.new(count) { |at| TestPS1TableGroups.entry(level, at) }, width: :word
      end
      names = table :names, [100, 200, 300]
      levels = table_groups :levels, words.each_index.to_h { |level| [level, [:"map#{level}"]] }
      clock = timer :clock, per_second: 60
      level = var :level, 0
      passes = var :passes, 0
      read = var :read, 0
      named = var :named, 0
      ticks = var :ticks, 0
      game_loop do
        levels.load level
        read.store!(maps[0][words[0] - 1]) if level == 0
        read.store!(maps[1][words[1] - 1]) if level == 1
        read.store!(maps[2][words[2] - 1]) if level == 2
        named.store!(names[level])
        ticks.store!(clock.ticks)
        passes.increase!(1)
        level.increase!(1)
        level.store!(0) if level == 3
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_game_bigger_than_memory_is_built_as_a_disc_and_plays_each_level_from_it
    program = levels_game
    run = PS1::CheckedRun.new
    rom = run.build(program)

    assert rom.disc, "a game with tables in groups is built as a disc"
    assert_operator LEVEL_WORDS.sum * 4, :>, VBlank::Console::PS1Hardware::RAM_SIZE, "the levels are more than RAM holds"
    assert_operator rom.disc.sector_count * VBlank::Cartridge::PS1Disc::SECTOR, :>, VBlank::Console::PS1Hardware::RAM_SIZE
    assert_operator rom.bytes.bytesize, :<, 64 * 1024, "the program holds none of the levels"

    run.run(program, frames: 4)

    assert_equal 4, run[:passes]
    assert_equal self.class.entry(0, LEVEL_WORDS[0] - 1), run[:read], "the fourth pass loaded level 0 again"
    assert_equal 100, run[:named]
    # The frames a pass's load took are the ones the next pass answers for, as the interpreter counts them.
    assert_operator run.frames_took(2), :>, 255, "the first level took more frames to read than a byte counts"
  end

  # A level's sectors come in at the drive's double speed, 150 a second, as the console's own games read
  # theirs: the frames a pass that loads takes are its sectors at that rate, and a little for the seek
  # and the commands (Beetle PSX gives a seek a few frames). Each load's frames are the ones the next pass
  # answers for.
  def test_a_level_loads_at_the_drives_double_speed
    program = levels_game
    run = PS1::CheckedRun.new
    run.run(program, frames: 4)
    frames_a_second = 1 / VBlank::Console::PLAYSTATION.frame_seconds

    LEVEL_WORDS.each_with_index do |words, level|
      sectors = VBlank::Cartridge::PS1Disc.sectors_for(words * 4)
      at_drive_speed = sectors * frames_a_second / 150.0

      assert_operator run.frames_took(level + 2), :>=, at_drive_speed.floor, "level #{level} cannot be quicker than the drive"
      assert_operator run.frames_took(level + 2), :<=, at_drive_speed + 15, "level #{level} reads at the drive's speed"
    end
  end
end
