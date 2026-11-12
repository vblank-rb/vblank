# frozen_string_literal: true

require "test_helper"
require "differential"

# A room with a cloud over part of it, and the colours it shows, shared with the Advance
# cartridge's own tests of the same pictures
# (test/lowering/gba/vblank/builder/test_layer_over_sprites_cartridge.rb).
#
# A red floor at the back. A white cloud, half see-through, covers the screen left of CLOUD_EDGE.
# Each sprite is one solid colour and stands across that edge, so it has a pixel under the cloud
# and a pixel on bare floor. The sprites behind the cloud come to be there in four ways, and a
# room is built with any of them:
#
#   :plain       a sprite declared in the layer behind the cloud
#   :pool        the things of a pool declared in that layer
#   :moved       a sprite declared in front of the cloud and told `put_in_layer` the layer behind
#   :moved_pool  a pool declared in front and told the same
#
# A yellow sprite in front of the cloud is in every room.
module LayerOverSpritesGames
  include SharedConstants

  RED = VBlank::Graphics::Color.resolve(:red)
  WHITE = VBlank::Graphics::Color.resolve(:white)
  GREEN = VBlank::Graphics::Color.resolve(:green)
  BLUE = VBlank::Graphics::Color.resolve(:blue)
  YELLOW = VBlank::Graphics::Color.resolve(:yellow)

  CLOUD_EDGE = 104 # the cloud covers thirteen columns of tiles
  SPRITE_X = 100
  UNDER_CLOUD_X = 101
  BARE_FLOOR_X = 106

  # Where each sprite stands, and its colour.
  ROWS = { plain: 16, pool: 40, moved: 64, moved_pool: 88, front: 112 }.freeze
  SPRITE_COLORS = { plain: GREEN, pool: BLUE, moved: GREEN, moved_pool: BLUE, front: YELLOW }.freeze
  EVERY_WAY_BEHIND = %i[plain pool moved moved_pool].freeze

  SWITCH_AT = 4 # with scenes, the pass the room takes over from a title on

  # The room. +behind+ lists the ways sprites are behind the cloud. With +scenes+ the room is a
  # scene of its own, taking over from a title that sees through nothing.
  private def clouded_room(behind, scenes: false)
    tile = SOLID_TILE
    rows = ROWS
    switch_at = SWITCH_AT
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:floor, "#" => :red) { tile }
      image(:mist, "#" => :white) { tile }
      image(:hero, "#" => :green) { tile }
      image(:guard, "#" => :blue) { tile }
      image(:badge, "#" => :yellow) { tile }
      tiles :floors, "#" => :floor
      tiles :mists, "#" => :mist
      layers :ground, :under, :clouds, :front
      moved = []
      room = lambda do
        layer(:ground) { background :ground_bg, tiles: :floors, map: Array.new(20) { "#" * 30 } }
        layer(:clouds, transparency: 50) do
          background :cloud_bg, tiles: :mists, map: Array.new(20) { ("#" * 13) + (" " * 17) }
        end
        layer(:under) { sprite :hero, at: [SPRITE_X, rows[:plain]] } if behind.include?(:plain)
        if behind.include?(:pool)
          guards = layer(:under) { pool :guards, x: 0, y: 0, capacity: 2, image: :guard }
          guards.spawn x: SPRITE_X, y: rows[:pool]
        end
        layer(:front) do
          sprite :badge, at: [SPRITE_X, rows[:front]]
          moved << sprite(:walker, image: :hero, at: [SPRITE_X, rows[:moved]]) if behind.include?(:moved)
          moved << pool(:walkers, x: 0, y: 0, capacity: 2, image: :guard) if behind.include?(:moved_pool)
        end
        moved.last.spawn x: SPRITE_X, y: rows[:moved_pool] if behind.include?(:moved_pool)
        # A scene's own sprites are told on the scene's passes.
        moved.each { |thing| thing.put_in_layer :under } if scenes
      end
      if scenes
        where = var :where, 0
        pass = var :pass, 0
        scene(:title) { layer(:ground) { background :title_bg, tiles: :mists, map: Array.new(20) { "#" * 30 } } }
        scene(:room, &room)
        game_loop do
          pass += 1
          where = 1 if pass == switch_at
          case_var(:where) do
            when_val 0, :title
            when_val 1, :room
          end
        end
      else
        instance_exec(&room)
        game_loop { moved.each { |thing| thing.put_in_layer :under } }
      end
    end
    b.finalize_program
    b.program
  end

  # The same room with nothing behind the cloud but the floor.
  private def clouded_room_with_no_sprites_behind = clouded_room([])

  # A layer half see-through over +under+: each channel takes eight sixteenths of each side, and
  # the fraction is dropped from the sum (IR::SeeThrough, at `transparency: 50`).
  private def half_white_over(under)
    (0..2).sum do |channel|
      shift = channel * 5
      (((((WHITE >> shift) & 31) * 8) + (((under >> shift) & 31) * 8)) >> 4) << shift
    end
  end

  private def under_cloud(way) = [UNDER_CLOUD_X, ROWS.fetch(way) + 2]
  private def on_bare_floor(way) = [BARE_FLOOR_X, ROWS.fetch(way) + 2]
end

# A SEE-THROUGH BACKGROUND OVER SPRITES. A cloud's shadow passes over the grass and over whoever
# is walking on it: the layer mixes with the sprites behind it as it mixes with the backgrounds
# behind it, and a sprite in front of it is drawn over it, as it is.
#
# On the Advance the display is told which layers a see-through one mixes with, and the sprites
# are one of them, to be named or not. A sprite is behind the layer when it was declared there,
# and when the game put it there as it runs (`put_in_layer`), which the build cannot see from
# where the sprite was declared.
#
# A Game Boy Color and a Genesis mix no layer with another, so this plays on the Advance's runs.
class TestLayerOverSpritesOnTheAdvance < Minitest::Test
  include Differential
  include LayerOverSpritesGames

  SETTLED = 4

  private def screen_of(program, frames: SETTLED) = game_player.run(program, frames: frames).screen

  # The room with sprites behind the cloud in one +way+ alone, so no other way's sprites can be
  # what had the sprites named.
  private def assert_cloud_mixes_over(way)
    room = clouded_room([way])
    screen = screen_of(room)

    assert_equal half_white_over(SPRITE_COLORS.fetch(way)), screen.pixel(*under_cloud(way)), "under the cloud"
    assert_equal SPRITE_COLORS.fetch(way), screen.pixel(*on_bare_floor(way)), "beside the cloud"
    assert_equal half_white_over(RED), screen.pixel(UNDER_CLOUD_X, 150), "the floor under the cloud"
    assert_backends_agree(room, frames: SETTLED)
  end

  def test_the_cloud_mixes_over_a_sprite_declared_behind_it = assert_cloud_mixes_over(:plain)

  def test_the_cloud_mixes_over_a_pool_declared_behind_it = assert_cloud_mixes_over(:pool)

  def test_the_cloud_mixes_over_a_sprite_put_behind_it_as_the_game_runs = assert_cloud_mixes_over(:moved)

  def test_the_cloud_mixes_over_a_pool_put_behind_it_as_the_game_runs = assert_cloud_mixes_over(:moved_pool)

  # NEAR-MISS: naming the sprites as something the cloud mixes with must not make a sprite in
  # front of the cloud mix with anything.
  def test_a_sprite_in_front_of_the_cloud_is_drawn_over_it_unmixed
    [[], EVERY_WAY_BEHIND].each do |behind|
      screen = screen_of(clouded_room(behind))

      assert_equal YELLOW, screen.pixel(*under_cloud(:front)), "over the cloud, with #{behind.inspect} behind"
      assert_equal YELLOW, screen.pixel(*on_bare_floor(:front)), "over the floor, with #{behind.inspect} behind"
    end
  end

  def test_sprites_behind_and_in_front_of_the_cloud_are_each_drawn_their_own_way
    screen = screen_of(clouded_room(EVERY_WAY_BEHIND))

    EVERY_WAY_BEHIND.each do |way|
      assert_equal half_white_over(SPRITE_COLORS.fetch(way)), screen.pixel(*under_cloud(way)), "#{way}, under the cloud"
      assert_equal SPRITE_COLORS.fetch(way), screen.pixel(*on_bare_floor(way)), "#{way}, beside the cloud"
    end
    assert_backends_agree(clouded_room(EVERY_WAY_BEHIND), frames: SETTLED)
  end

  def test_a_scenes_cloud_mixes_over_the_scenes_sprites_behind_it
    room = clouded_room(EVERY_WAY_BEHIND, scenes: true)
    screen = screen_of(room, frames: SWITCH_AT + SETTLED)

    EVERY_WAY_BEHIND.each do |way|
      assert_equal half_white_over(SPRITE_COLORS.fetch(way)), screen.pixel(*under_cloud(way)), "#{way}, under the cloud"
    end
    assert_equal YELLOW, screen.pixel(*under_cloud(:front))
    [SWITCH_AT - 2, SWITCH_AT + SETTLED].each { |frames| assert_backends_agree(room, frames: frames) }
  end

  def test_both_backends_draw_the_room_with_no_sprites_behind_the_cloud_the_same
    assert_backends_agree(clouded_room_with_no_sprites_behind, frames: SETTLED)
  end
end
