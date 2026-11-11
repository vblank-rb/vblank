# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "pack_place_games"

# A lit place, its shading and its viewer's start read from a data pack draw what the same game
# written in Ruby draws, built all-in-one and with the pack left out. The interpreter is the answer
# key; PackParityTests holds every run's build of the pack game to it.
class TestPackPlacesInterpreter < Minitest::Test
  ALL_IN_ONE = VBlank::Cartridge::Options.new
  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  def test_place_from_pack_built_all_in_one_draws_what_ruby_room_draws
    Dir.mktmpdir do |folder|
      program, = PackPlaceGames.pack_room_game(folder, ALL_IN_ONE)
      assert_draws_ruby_room(played(Reference.new, program))
    end
  end

  def test_place_from_pack_left_out_draws_what_ruby_room_draws
    Dir.mktmpdir do |folder|
      _, file = PackPlaceGames.pack_room_game(folder, ALL_IN_ONE)
      program, = PackPlaceGames.pack_room_game(folder, LEFT_OUT)
      assert_draws_ruby_room(played(Reference.new.hand_file(file), program))
    end
  end

  def test_ruby_room_shows_lit_room_without_unused_face
    pictures = played(Reference.new, PackPlaceGames.ruby_room_game).pictures
    colors = pictures.last.flatten.uniq
    assert_operator colors.length, :>=, 3, "the room shows its two pictures lit at more than one level"
    assert_includes colors, 0x0000, "the room leaves black where it has no face, so the unused wall is not drawn"
  end

  private def played(player, program) = VBlank::Testing::PackParity.played(player, program, PackPlaceGames::PASSES, {})

  private def assert_draws_ruby_room(handed)
    wanted = played(Reference.new, PackPlaceGames.ruby_room_game)
    assert_nil VBlank::Testing::PackParity.difference(wanted, handed)
  end
end
