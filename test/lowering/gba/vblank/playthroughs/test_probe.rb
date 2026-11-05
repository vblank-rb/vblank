# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "comparison_games"

# A PORT DRIVES ITS ORIGINAL with a Probe: any cartridge file, played a frame at a time until the
# game says it has got somewhere, and read by the labels its decompilation gave its memory. The
# cartridge here is the walker, built in the test and written to a file, its labels taken from what
# the build recorded: a white box that walks two pixels a frame from column 20 while RIGHT is down.
class TestProbe < Minitest::Test
  include ComparisonGames

  private def with_walker_file
    Dir.mktmpdir("cartridges") do |folder|
      built = walker
      path = File.join(folder, "walker.gba").tap { |file| built.write(file) }
      yield path, { "box_x" => built.var_addresses.fetch(:x) }, folder
    end
  end

  def test_step_until_stops_on_the_frame_the_game_gets_there
    with_walker_file do |path, labels|
      VBlank::Playthroughs::Probe.open(path, labels: labels) do |probe|
        probe.step(10)
        probe.step_until("the box at column 60", within: 100, holding: :right) { probe.read("box_x", as: :s32) >= 60 }

        assert_equal 30, probe.frame
        assert_equal 60, probe.read(labels.fetch("box_x"), as: :u32)
        assert probe.reader.white?(60, 60)
      end
    end
  end

  def test_a_wait_that_never_ends_says_what_and_where
    with_walker_file do |path, labels|
      VBlank::Playthroughs::Probe.open(path, labels: labels) do |probe|
        error = assert_raises(VBlank::Playthroughs::Probe::NeverHappened) do
          probe.step_until("the box at column 60", within: 5, watch: %w[box_x]) { probe.read("box_x") >= 60 }
        end

        assert_match "the box at column 60", error.message
        assert_match "box_x is 20", error.message
      end
    end
  end

  def test_press_until_stops_part_way_through_a_press
    with_walker_file do |path, labels|
      VBlank::Playthroughs::Probe.open(path, labels: labels) do |probe|
        probe.press_until(:right, "the box moved", within: 3) { probe.read("box_x") > 20 }

        assert_equal 2, probe.frame
      end
    end
  end

  def test_a_value_written_moves_the_box_and_leaves_its_neighbours
    with_walker_file do |path, labels|
      VBlank::Playthroughs::Probe.open(path, labels: labels) do |probe|
        probe.step(2)
        after = probe.read(labels.fetch("box_x") + 4, as: :u32)
        probe.write("box_x", 100, as: :u8)
        probe.step(2)

        assert_equal 100, probe.read("box_x", as: :u32)
        assert_equal after, probe.read(labels.fetch("box_x") + 4, as: :u32)
        assert probe.reader.white?(100, 60)
      end
    end
  end

  def test_a_label_says_how_it_is_read_and_a_misaligned_read_is_refused
    with_walker_file do |path, labels|
      VBlank::Playthroughs::Probe.open(path, labels: { "box_x" => [labels.fetch("box_x"), :u32] }) do |probe|
        probe.step(2)
        probe.write("box_x", 300)

        assert_equal 300, probe.read("box_x")
        assert_equal [probe.read("box_x")].pack("V"), probe.read_bytes("box_x", 4)
        assert_match "even address", assert_raises(ArgumentError) { probe.read(labels.fetch("box_x") + 1, as: :u16) }.message
        assert_match "multiple of 4", assert_raises(ArgumentError) { probe.read(labels.fetch("box_x") + 2, as: :u32) }.message
        assert_match "not 3", assert_raises(ArgumentError) { probe.read("box_x", as: :u24) }.message
      end
    end
  end

  def test_a_block_can_choose_what_to_hold_each_frame
    with_walker_file do |path, labels|
      VBlank::Playthroughs::Probe.open(path, labels: labels) do |probe|
        probe.step(10)
        before = probe.read("box_x")
        probe.step(10, holding: ->(running) { :right if running.frame.even? })

        assert_equal before + 10, probe.read("box_x")
      end
    end
  end

  def test_an_unknown_label_is_refused_by_name
    with_walker_file do |path, labels|
      VBlank::Playthroughs::Probe.open(path, labels: labels) do |probe|
        assert_match "box_y", assert_raises(ArgumentError) { probe.read("box_y") }.message
      end
    end
  end

  def test_the_save_memory_is_kept_in_a_folder_of_its_own_and_none_is_left_beside_the_cartridge
    with_walker_file do |path, labels, folder|
      VBlank::Playthroughs::Probe.open(path, labels: labels) { |probe| probe.step(5) }

      assert_equal ["walker.gba"], Dir.children(folder)
    end
  end

  def test_a_saved_state_puts_the_game_back
    with_walker_file do |path, labels, folder|
      VBlank::Playthroughs::Probe.open(path, labels: labels) do |probe|
        probe.step(10, holding: :right)
        walked = probe.read("box_x")
        state = File.join(folder, "walked.state")
        probe.save_state(state)
        probe.step(10, holding: :right)
        probe.load_state(state, frame: 10)

        refute_equal 20, walked
        assert_equal walked, probe.read("box_x")
        assert_equal 10, probe.frame
      end
    end
  end
end
