# frozen_string_literal: true

require "test_helper"
require "pack_slot_view_games"

# A VIEW OF A SLOT OF A DATA PACK (DSL::PackSlot#as_tiles and its siblings): some of a slot's bytes
# read in a shape of their own. What a game that reads its one video slot through views shows is
# held to the same game holding the data itself, and what a game is told when a view cannot be
# made. The two backgrounds of the made-up original, one of them turning, are
# test/console/gba/vblank/builder/test_pack_slot_views_on_the_advance.rb's.
class TestPackSlotViews < Minitest::Test
  include PackSlotViewGames

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # The error of a game that does +reading+ (a block handed the pack, run in the game) with the
  # made-up original's pack.
  private def refusal(options: VBlank::Cartridge::Options.new, &reading)
    Dir.mktmpdir do |folder|
      from = slot_view_original(folder)
      assert_raises(ArgumentError) do
        VBlank::Builder.new(options: options).instance_eval do
          screen :bitmap
          pack, = PackSlotViewGames.declare_video(self, from, views: true)
          instance_exec(pack, &reading)
        end
      end
    end
  end

  def test_pixels_and_tables_viewed_in_a_slot_of_tiles_show_as_the_game_holding_them
    Dir.mktmpdir do |folder|
      from = slot_view_original(folder)
      viewed, = table_and_pixels_game_and_file(from, views: true)
      held, = table_and_pixels_game_and_file(from, views: false)

      pictures = [2, 5, 9].map do |frames|
        shown = game_player.run(held, frames: frames).screen
        assert_equal shown.to_a, game_player.run(viewed, frames: frames).screen.to_a, "after #{frames} frames"
        shown.to_a
      end
      assert_equal 3, pictures.uniq.length, "the marks move from pass to pass"
    end
  end

  def test_a_view_that_ends_after_its_slot_is_refused
    error = refusal { |pack| pack[:video].as_tiles(at: PICTURES_IN_VIDEO, count: BYTE_TILES.length + 1, colors: 256) }

    assert_includes error.message, "ends after the slot ends"
  end

  def test_a_view_from_a_byte_the_slot_does_not_have_is_refused
    error = refusal { |pack| pack[:video].as_pixels(at: VIDEO_BYTES, count: 1) }

    assert_includes error.message, "at: must be a byte of the slot"
  end

  def test_a_view_to_the_slots_end_that_is_no_whole_number_of_items_is_refused
    error = refusal { |pack| pack[:video].as_tiles(at: PICTURES_IN_VIDEO + 1, colors: 256) }

    assert_includes error.message, "whole number"
  end

  def test_a_view_of_some_tiles_of_a_slot_is_refused
    error = refusal { |pack| pack[:video].tile(2).as_pixels(at: 0, count: 64) }

    assert_includes error.message, "the slot itself"
  end

  # A view is taken as a slot of its shape is, so a verb that wants another shape names what it got.
  def test_a_view_given_to_a_verb_that_reads_another_shape_is_refused
    error = refusal { |pack| table :cells, pack[:video].as_tiles(at: PICTURES_IN_VIDEO, colors: 256) }

    assert_includes error.message, "holds tiles"
  end

  def test_a_view_of_a_slot_of_another_layout_names_the_layouts_tiles
    error = refusal { |pack| pack[:video].as_tiles(at: 0, count: 1, colors: 4) }

    assert_includes error.message, "colors:"
  end

  def test_a_frame_read_from_a_view_is_refused
    error = refusal do |pack|
      pack[:video].as_numbers(at: 0, count: 64, width: :byte, signed: false).frame(0, layout: nil)
    end

    assert_includes error.message, "view of slot :video"
  end

  # A run of a slot does not start at the slot's first number, which these count from.
  def test_a_number_an_envelope_or_a_frame_of_a_run_of_numbers_is_refused
    bytes = ->(pack) { pack[:video].as_numbers(at: 0, count: 64, width: :byte, signed: false).numbers(8, 16) }

    [->(run) { run.number(0) }, ->(run) { run.envelope(0) }, ->(run) { run.snes_envelope(0) },
     ->(run) { run.frame(0, layout: nil) }].each do |misuse|
      error = refusal { |pack| misuse.call(bytes.call(pack)) }

      assert_includes error.message, "counts from the first number of the slot"
    end
  end

  # A build that reads its pack as the game starts refuses the same views as it is built.
  def test_a_view_that_ends_after_its_slot_is_refused_with_the_pack_left_out
    error = refusal(options: LEFT_OUT) { |pack| pack[:video].as_numbers(at: VIDEO_BYTES - 2, count: 2, width: :half, signed: false) }

    assert_includes error.message, "ends after the slot ends"
  end
end
