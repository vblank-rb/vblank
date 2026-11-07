# frozen_string_literal: true

require "test_helper"
require "made_up_original_layouts"

# A GAME READING EACH CONSOLE'S LAYOUT THROUGH ITS PACK plays as one holding the data (MadeUpOriginalLayouts).
class TestDataPackLayouts < Minitest::Test
  include MadeUpOriginalLayouts

  def test_a_game_reading_each_consoles_layout_through_the_pack_plays_as_one_holding_the_data
    LAYOUTS.each do |layout|
      Dir.mktmpdir do |folder|
        packed, = layout_game(through_layout_pack(layout_original(folder, layout), layout))
        held, = layout_game(layout_held_directly(layout))

        [1, 4, 9].each do |frames|
          shown = game_player.run(held, frames: frames).screen.to_a
          assert_equal shown, game_player.run(packed, frames: frames).screen.to_a,
                       "#{layout.title} layout: after #{frames} frames the two games show the same picture"
        end
      end
    end
  end

  # The pack holds the original's bytes as the original keeps them.
  def test_the_pack_holds_each_layouts_bytes_unchanged
    LAYOUTS.each do |layout|
      Dir.mktmpdir do |folder|
        _, file = layout_game(through_layout_pack(layout_original(folder, layout), layout))
        pack = VBlank::Original::Pack.from_bytes(file)

        assert_equal layout.tile_bytes, pack.bytes_of(:walls), layout.title
        assert_equal layout.copy.byteslice(PALETTE_AT, 32), pack.bytes_of(:palette), layout.title
      end
    end
  end

  private def refusal_of_slots(platform, &slots)
    layout = LAYOUTS.find { |each| each.platform == platform }
    Dir.mktmpdir do |folder|
      assert_raises(ArgumentError) { VBlank::Builder.new.data_pack(from: layout_original(folder, layout), version: "1", &slots) }
    end
  end

  def test_a_slot_of_a_computer_games_original_must_name_its_layout
    refused = refusal_of_slots(:pc) { |slots| slots.tiles :walls, at: TILES_AT, count: 2 }

    assert_match ":walls", refused.message
    assert_match "layout:", refused.message
  end

  def test_a_slot_of_super_nintendo_tiles_must_say_how_many_colors
    refused = refusal_of_slots(:snes) { |slots| slots.tiles :walls, at: TILES_AT, count: 2 }

    assert_match "colors: 4", refused.message
    assert_match "colors: 16", refused.message
  end

  def test_a_slot_in_a_layout_vblank_does_not_read_is_refused
    refused = refusal_of_slots(:gbc) { |slots| slots.tiles :walls, at: TILES_AT, count: 2, layout: :ps1 }

    assert_match ":walls", refused.message
    assert_match "PlayStation", refused.message
  end

  def test_a_tile_of_more_colors_than_the_layout_keeps_is_refused
    refused = refusal_of_slots(:gbc) { |slots| slots.tiles :walls, at: TILES_AT, count: 2, colors: 16 }

    assert_match "colors: 4", refused.message
  end

  def test_an_original_from_no_known_platform_is_refused
    refused = assert_raises(ArgumentError) do
      VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: {}, platform: :amiga, settings_file: "made_up.yml",
                                 releases: { "Test" => { "sha1" => "0" * 40 } })
    end

    assert_match ":amiga", refused.message
    assert_match ":pc", refused.message
    assert_match ":genesis", refused.message
  end
end
