# frozen_string_literal: true

require "test_helper"
require "made_up_vblank_layout_originals"

# A PLAYSTATION, COMPUTER OR ARCADE ORIGINAL'S UNPACKING WRITES ITS COLOURS, TILES AND NUMBERS IN
# VBLANK'S OWN LAYOUT, with no layout: line, and the game shows them as the same screen drawn by the
# game (MadeUpVBlankLayoutOriginals).
class TestDataPackVBlankLayout < Minitest::Test
  include MadeUpVBlankLayoutOriginals

  # The frames after which the two games are compared.
  FRAMES = [1, 4, 9].freeze

  def test_an_original_of_a_platform_with_no_layout_shows_its_unpackings_data_as_drawn_by_hand
    by_hand = vblank_layout_drawn_by_hand
    ORIGINALS.each do |made_up|
      Dir.mktmpdir do |folder|
        program, = vblank_layout_game_and_file(vblank_layout_original(folder, made_up), made_up)

        FRAMES.each do |frames|
          assert_equal game_player.run(by_hand, frames: frames).screen.to_a, game_player.run(program, frames: frames).screen.to_a,
                       "the #{made_up.platform} original after #{frames} frames"
        end
      end
    end
  end

  # VBlank's own layout: fifteen bits a colour, low byte first; a byte a pixel; low byte first.
  def test_the_pack_holds_the_unpackings_data_in_vblanks_own_layout
    made_up = ORIGINALS.last
    Dir.mktmpdir do |folder|
      _, file = vblank_layout_game_and_file(vblank_layout_original(folder, made_up), made_up)
      pack = VBlank::Original::Pack.from_bytes(file)

      assert_equal PALETTE.pack("v*"), pack.bytes_of(:palette)
      assert_equal PLACES.flatten.pack("C*"), pack.bytes_of(:video)
      assert_equal ACROSSES.pack("v*"), pack.bytes_of(:acrosses)
    end
  end

  # A tile of four colours is a byte a pixel too, and only a byte's two low bits pick its colour:
  # the unpacking writes each place with a higher bit set, and the picture is the places alone.
  def test_a_four_color_tile_reads_the_low_two_bits_of_each_byte
    places = PLACES.fetch(1)
    made_up = ORIGINALS.first
    Dir.mktmpdir do |folder|
      from = vblank_layout_original(folder, made_up)
      packed = picture_game do
        pack = data_pack(from: from, version: "1") do |slots|
          slots.tiles :quarter, count: 1, colors: 4
          slots.fill_from_copy do |_copy, filled|
            places.each_with_index { |place, at| filled[:quarter][at] = place | 0x24 }
          end
        end
        image :tile, width: 8, height: 8, colors: BANKS.first.first(4), places: pack[:quarter].tile(0)
      end
      by_hand = picture_game { image :tile, width: 8, height: 8, colors: BANKS.first.first(4), places: places }

      assert_equal game_player.run(by_hand, frames: 2).screen.to_a, game_player.run(packed, frames: 2).screen.to_a
    end
  end

  # A colour written at the original's depth is narrowed to five bits a channel, or widened from
  # fewer, its bits repeated.
  def test_write_color_narrows_and_widens_a_channel
    file = palette_file do |filled|
      filled[:palette].write_color(0, red: 255, green: 8, blue: 0x7F)
      filled[:palette].write_color(1, red: 7, green: 0, blue: 5, bits: 3)
      filled[:palette].write_color(2, red: 31, green: 1, blue: 16, bits: 5)
    end

    assert_equal [31 | (1 << 5) | (15 << 10), 31 | (22 << 10), 31 | (1 << 5) | (16 << 10)], file.unpack("v*")
  end

  # A console's layout is a shortcut: the Genesis keeps three bits a channel, high byte first.
  def test_write_color_writes_a_console_layouts_color
    file = palette_file(layout: :genesis) { |filled| filled[:palette].write_color(0, red: 255, green: 0x40, blue: 0x9F) }

    assert_equal [(7 << 1) | (2 << 5) | (4 << 9)], file.byteslice(0, 2).unpack("n*")
  end

  def test_write_color_past_its_bits_is_refused
    refused = assert_raises(ArgumentError) { palette_file { |filled| filled[:palette].write_color(0, red: 64, green: 0, blue: 0, bits: 6) } }

    assert_match "red", refused.message
    assert_match "63", refused.message
  end

  def test_write_color_on_a_slot_of_another_shape_is_refused
    refused = assert_raises(ArgumentError) { palette_file { |filled| filled[:acrosses].write_color(0, red: 1, green: 0, blue: 0) } }

    assert_match "write_color", refused.message
    assert_match "slots.colors", refused.message
  end

  # A game whose block declares the picture :tile, shown as a sprite.
  private def picture_game(&declares)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      instance_exec(&declares)
      sprite :tile, at: [20, 30]
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # The bytes the unpacking writes into a slot of three colours of the computer original's pack,
  # in +layout+ (VBlank's own where none is named). The block is handed the pack's slots.
  private def palette_file(layout: nil)
    made_up = ORIGINALS.find { |each| each.platform == :pc }
    Dir.mktmpdir do |folder|
      from = vblank_layout_original(folder, made_up)
      b = Builder.new
      b.instance_eval do
        data_pack(from: from, version: "1") do |slots|
          slots.colors :palette, count: 3, **(layout ? { layout: layout } : {})
          slots.numbers :acrosses, count: 1, width: :half, signed: false
          slots.fill_from_copy { |_copy, filled| yield filled }
        end
      end
      VBlank::Original::Pack.from_bytes(b.made_data_pack_file).bytes_of(:palette)
    end
  end
end
