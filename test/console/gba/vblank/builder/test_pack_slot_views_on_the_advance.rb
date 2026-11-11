# frozen_string_literal: true

require "test_helper"
require "pack_slot_view_games"

# ONE SLOT OF VIDEO MEMORY READ IN THREE SHAPES (PackSlotViewGames): sixteen-colour tiles by a
# ground, and through views a map of bytes over tiles of a byte a pixel by a layer that turns
# behind it. The answer key is the same game with a slot of its own for each part, built
# all-in-one. A build that reads its pack as the game starts is held to it too: only a build for
# a computer leaves its pack out, so that is played by the interpreter and by the game as C,
# JavaScript and Ruby built for the Advance.
#
# A Game Boy Color cannot turn a background, so these play on the Advance's runs alone.
class TestPackSlotViewsOnTheAdvance < Minitest::Test
  include PackSlotViewGames

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)
  FRAMES = [2, 4, 7].freeze

  # What each game does with the layer, as a block run in the game. Made anew for each game, and
  # not kept in a constant: test_helper.rb makes a test class's constants shareable between
  # Ractors, and the turning block kept so did not turn the layer.
  private def still = ->(_layer) { game_loop { wait_vblank } }

  private def turning
    lambda do |layer|
      layer.turns_around(*PIVOT, map_point: MIDDLE).scale(2.0)
      spin = var :spin, 0
      game_loop do
        spin += 11
        layer.rotate spin
      end
    end
  end

  # What the game with a slot for each part shows after each of FRAMES.
  private def pictures_from_slots_of_their_own(from, &more)
    separate, = two_shapes_game_and_file(from, views: false, &more)
    FRAMES.to_h { |count| [count, game_player.run(separate, frames: count).screen.to_a] }
  end

  private def assert_views_show_as_slots_of_their_own(what, &more)
    Dir.mktmpdir do |folder|
      from = slot_view_original(folder)
      wanted = pictures_from_slots_of_their_own(from, &more)
      viewed, = two_shapes_game_and_file(from, views: true, &more)

      assert_operator wanted.fetch(FRAMES.last).flatten.uniq.length, :>, 8, "#{what}: both backgrounds show"
      FRAMES.each do |count|
        assert_equal wanted.fetch(count), game_player.run(viewed, frames: count).screen.to_a,
                     "#{what}: after #{count} frames the views show what slots of their own show"
      end
      wanted
    end
  end

  private def assert_views_read_at_start_show_as_slots_of_their_own(what, &more)
    Dir.mktmpdir do |folder|
      from = slot_view_original(folder)
      wanted = pictures_from_slots_of_their_own(from, &more)
      _whole, file = two_shapes_game_and_file(from, views: true, &more)
      left_out, = two_shapes_game_and_file(from, views: true, options: LEFT_OUT, &more)

      FRAMES.each do |count|
        assert_equal wanted.fetch(count), game_player.hand_file(file).run(left_out, frames: count).screen.to_a,
                     "#{what}: after #{count} frames the views read as the game starts show what slots of their own show"
      end
    end
  end

  def test_still_the_views_show_as_slots_of_their_own
    assert_views_show_as_slots_of_their_own("still", &still)
  end

  def test_turning_the_views_show_as_slots_of_their_own
    pictures = assert_views_show_as_slots_of_their_own("turning", &turning)

    assert_equal FRAMES.length, pictures.values.uniq.length, "the layer turns from frame to frame"
  end

  def test_read_at_start_still_the_views_show_as_slots_of_their_own
    assert_views_read_at_start_show_as_slots_of_their_own("still", &still)
  end

  def test_read_at_start_turning_the_views_show_as_slots_of_their_own
    assert_views_read_at_start_show_as_slots_of_their_own("turning", &turning)
  end

  # The pack a game of views makes holds the stretch once: its one slot, and no slot for a view.
  def test_the_pack_holds_the_video_once
    Dir.mktmpdir do |folder|
      from = slot_view_original(folder)
      _program, viewed_file = two_shapes_game_and_file(from, views: true, &still)
      _other, separate_file = two_shapes_game_and_file(from, views: false, &still)

      viewed = VBlank::Original::Pack.from_bytes(viewed_file)
      separate = VBlank::Original::Pack.from_bytes(separate_file)
      assert_equal %i[video ground_map table], viewed.slots.keys
      assert_equal VIDEO_BYTES, viewed.bytes_of(:video).bytesize
      assert_equal separate.slots.values_at(:ground_tiles, :cells, :pictures).join, viewed.bytes_of(:video)
    end
  end
end
