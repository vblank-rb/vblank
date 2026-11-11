# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "pack_place_games"

# What `place`, `shading` and `viewer` refuse when given slots of the data pack. What they draw
# is held to the same room written in Ruby (test/interpreter/vblank/builder/
# test_pack_places_interpreter.rb) and on every run that reads a pack as it starts (PackGames).
class TestPackPlaces < Minitest::Test
  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  def test_place_with_points_from_pack_and_faces_in_ruby_is_refused
    error = assert_raises(ArgumentError) do
      build_with_pack { |pack| place :room, points: pack[:points], faces: PackPlaceGames::FACES, pictures: %i[rock] }
    end
    assert_match(/both from the data pack/, error.message)
  end

  def test_faces_used_without_pack_place_is_refused
    error = assert_raises(ArgumentError) do
      build_with_pack do |pack|
        place :room, points: PackPlaceGames::POINTS, faces: PackPlaceGames::FACES, pictures: %i[rock moss],
                     faces_used: pack[:sizes].number(0)
      end
    end
    assert_match(/remove faces_used:/, error.message)
  end

  def test_points_slot_not_of_signed_words_is_refused
    error = assert_raises(ArgumentError) do
      build_with_pack { |pack| place :room, points: pack[:fades], faces: pack[:faces], pictures: %i[rock] }
    end
    assert_match(/width: :word, signed: true/, error.message)
  end

  def test_pack_place_without_pictures_is_refused
    error = assert_raises(ArgumentError) do
      build_with_pack { |pack| place :room, points: pack[:points], faces: pack[:faces] }
    end
    assert_match(/lists no pictures/, error.message)
  end

  def test_pack_place_drawn_where_game_puts_it_is_refused
    error = assert_raises(ArgumentError) do
      build_with_pack do |pack|
        place :room, points: pack[:points], faces: pack[:faces], pictures: %i[rock]
        eye = viewer :eye, at: [0.0, 0.0, -2.0]
        draw_place :room, seen_by: eye, at: [1.0, 0.0, 0.0]
      end
    end
    assert_match(/without at: and facing:/, error.message)
  end

  def test_shading_with_colors_from_pack_and_levels_in_ruby_is_refused
    error = assert_raises(ArgumentError) do
      build_with_pack { |pack| shading :fade, colors: pack[:palette], levels: PackPlaceGames::LEVELS }
    end
    assert_match(/both from the data pack/, error.message)
  end

  def test_shading_levels_not_whole_levels_of_bytes_is_refused
    error = assert_raises(ArgumentError) do
      build_with_pack { |pack| shading :fade, colors: pack[:palette], levels: pack[:points] }
    end
    assert_match(/width: :byte, signed: false/, error.message)
  end

  def test_viewer_start_of_wrong_count_is_refused
    error = assert_raises(ArgumentError) do
      build_with_pack { |pack| viewer :eye, at: pack[:start] }
    end
    assert_match(/must be 3 numbers/, error.message)
  end

  def test_picture_numbered_into_shading_read_at_start_is_refused
    error = assert_raises(ArgumentError) do
      build_with_pack(LEFT_OUT) do |pack|
        shading :fade, colors: pack[:palette], levels: pack[:fades]
        image :lit, width: 8, height: 8, shading: :fade, places: PackPlaceGames::ROCK
      end
    end
    assert_match(/build the game all-in-one/, error.message)
  end

  # A game reading the made-up room's pack, built as +options+ say, the block declaring the rest.
  private def build_with_pack(options = VBlank::Cartridge::Options.new, &declares)
    Dir.mktmpdir do |folder|
      from = PackPlaceGames.original(folder)
      builder = VBlank::Builder.new(options: options)
      builder.instance_eval do
        pack = PackPlaceGames.room_pack(self, from)
        screen :bitmap, tear_free: true
        image :rock, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].pixels(0, 64)
        instance_exec(pack, &declares)
      end
      builder.finalize_program
    end
  end
end
