# frozen_string_literal: true

require "test_helper"
require "made_up_original_layouts"

# A GAME READING EACH CONSOLE'S LAYOUT THROUGH ITS PACK plays as one holding the data (MadeUpOriginalLayouts).
# A platform with no layout of its own is read in VBlank's (test_data_pack_vblank_layout.rb).
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

  def test_a_slot_of_tiles_in_vblanks_layout_must_say_how_many_colors
    refused = refusal_of_slots(:pc) { |slots| slots.tiles :walls, at: TILES_AT, count: 2 }

    assert_match "colors: 4", refused.message
    assert_match "colors: 16", refused.message
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

  def test_an_original_names_any_platform
    assert_equal :arcade, original_for(:arcade).platform
    assert_equal :amiga, original_for("amiga").platform
  end

  def test_a_platform_that_is_no_name_is_refused
    refused = assert_raises(ArgumentError) { original_for(3) }

    assert_match "platform: 3", refused.message
  end

  # A name a letter or two from a console's, or the same but for case or punctuation, is taken
  # for a typo: read in VBlank's own layout, it would show a wrong picture with no error.
  def test_a_platform_close_to_a_consoles_name_is_refused_naming_the_console
    { gbcc: ":gbc", snse: ":snes", genisis: ":genesis", ps2: ":ps1", "GBA" => ":gba", "p_c" => ":pc" }.each do |typo, meant|
      refused = assert_raises(ArgumentError) { original_for(typo) }

      assert_match "Did you mean #{meant}?", refused.message
      assert_match "new_platform: true", refused.message
    end
  end

  def test_a_new_platform_close_to_a_consoles_name_is_taken_when_the_line_says_so
    assert_equal :ps2, original_for(:ps2, new_platform: true).platform
  end

  private def original_for(platform, **more)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: {}, platform: platform, settings_file: "made_up.yml",
                               releases: { "Test" => { "sha1" => "0" * 40 } }, **more)
  end

  # A number of one byte has no byte order, so no layout refuses it.
  def test_a_slot_of_bytes_is_read_in_a_layout_vblank_does_not_read
    layout = LAYOUTS.first
    Dir.mktmpdir do |folder|
      pack = Builder.new.data_pack(from: layout_original(folder, layout), version: "1") do |slots|
        slots.numbers :bytes, at: SPEEDS_AT, count: 4, width: :byte, signed: false, layout: :ps1
      end

      assert_equal 4, pack[:bytes].layout.byte_size
    end
  end

  def test_a_slot_naming_no_layout_vblank_reads_is_refused
    refused = refusal_of_slots(:gbc) { |slots| slots.colors :palette, at: PALETTE_AT, count: 16, layout: :gbaa }

    assert_match ":gbaa", refused.message
    assert_match ":vblank", refused.message
  end
end
