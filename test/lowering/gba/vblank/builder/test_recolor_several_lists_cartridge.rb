# frozen_string_literal: true

require "test_helper"
require "differential"
require "all/vblank/builder/test_recolor_several_lists"

# A BACKGROUND DRAWN WITH SEVERAL LISTS THE GAME CHANGES, ON THE ADVANCE'S CARTRIDGE, read in the
# emulator. The console keeps a background's colours and a sprite's in two tables, so a list's
# colours are copied into the group of sixteen the background's tiles read whenever the list is
# told what to hold, and again after anything that sends the background colours afresh. What the
# game does on every run is in test/all/vblank/builder/test_recolor_several_lists.rb.
class TestRecolorSeveralListsCartridge < Minitest::Test
  include RecolorSeveralListsGames
  include Differential

  # Enough frames for every pass of the game, and one more for the last pass's colours to show.
  EVERY_PASS = (1..(LAST_PASS + 1))

  def test_the_cartridge_agrees_with_the_interpreter_on_every_pass
    assert_backends_agree(several_lists_game, frames: EVERY_PASS)
  end

  # The console's own pixels, read off the cartridge and held to the colours written here, so
  # the two cannot agree on showing the declared colours for good.
  def test_the_console_shows_each_tile_in_what_its_own_list_holds
    told_once = several_lists_game do |sets|
      recolor :sign, sets.fetch(:sign), showing: 1
      recolor :trim, sets.fetch(:trim), showing: 2
      game_loop { wait_vblank }
    end
    v = assert_emulator_loads_rom(assemble_rom(told_once, name: "FOLLOWS"), frames: 6)
    tiles = TILE_PIXELS.transform_values { |places| places.map { |x, y| v.pixel_gba(x, y) } }
    held = { sign: 1, words: SETS, trim: 2 }.to_h { |list, step| [list, RecolorSeveralListsGames.colors_at(list, step).drop(1)] }

    assert_equal held.merge(plain: PLAIN.drop(1)), tiles
  end

  # A game of the three lists that also says +effect+ every pass, with the pass and a level
  # that is 0 until the fourth pass, 50 until the eighth, and 0 again after. :sign changes before
  # the effect starts, :trim while it is in force, and :words goes back to its own under it.
  private def game_under(&effect)
    several_lists_game do |sets|
      pass = var :pass, 0
      level = var :level, 0
      game_loop do
        pass += 1
        level = 50 if pass == 4
        level = 0 if pass == 8
        recolor :sign, sets.fetch(:sign), showing: 1 if pass == 2
        recolor :words, sets.fetch(:words), showing: 0 if pass == 3
        recolor :trim, sets.fetch(:trim), showing: 2 if pass == 5
        recolor :words, :words if pass == 6
        recolor :sign, sets.fetch(:sign), showing: 2 if pass == 9
        instance_exec(level, pass, &effect)
      end
    end
  end

  # A tint walks the whole table of background colours from the cartridge, which holds each
  # list's declared colours: the groups are put back from what the lists hold, through the tint.
  def test_the_tiles_follow_their_lists_under_a_tint
    assert_backends_agree(game_under { |level, _pass| tint :red, level }, frames: EVERY_PASS)
  end

  # ...and under one that moves every pass, so every pass walks the table over the groups.
  def test_the_tiles_follow_their_lists_under_a_tint_that_moves_every_pass
    assert_backends_agree(game_under { |_level, pass| tint :blue, pass * 5 }, frames: EVERY_PASS)
  end

  # A whole-number fade on this screen is the display's own, and changes no colour in memory.
  def test_the_tiles_follow_their_lists_under_a_fade
    assert_backends_agree(game_under { |level, _pass| fade :black, level }, frames: EVERY_PASS)
  end

  # A fade whose amount holds a fraction walks the colours, as a tint does.
  def test_the_tiles_follow_their_lists_under_a_fade_that_walks_the_colors
    walked = game_under do |_level, pass|
      fade :black, 37.5 if pass == 4
      fade :black, 0.0 if pass == 8
    end

    assert_backends_agree(walked, frames: EVERY_PASS)
  end

  # A fade over a tint in force puts the tables back as drawn before it darkens them.
  def test_the_tiles_follow_their_lists_when_a_fade_lifts_a_tint
    lifted = game_under do |_level, pass|
      tint :red, 50 if pass == 4
      fade :black, 25 if pass == 7
    end

    assert_backends_agree(lifted, frames: EVERY_PASS)
  end

  # TWO LISTS THE GAME CHANGES, :sign and :words, a tile and a sprite drawn from each, the tiles
  # in the set :title_set under "s" and "w", and two plain lists with a tile each in :plain_set,
  # under "m" and "o". The block declares the backgrounds and the loop, handed each list's sets.
  private def two_lists_game(&rest)
    games = RecolorSeveralListsGames
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      halves = ->(colors) { Array.new(64) { |i| (i % 8) < 4 ? colors[1] : colors[2] } }
      %i[sign words].each do |list|
        colors list, games.list(CHANGING.fetch(list))
        image :"#{list}_tile", width: 8, height: 8, data: halves.(games.list(CHANGING.fetch(list))), colors: list
        image :"#{list}_sprite", width: 8, height: 8, data: halves.(games.list(CHANGING.fetch(list))), colors: list
        sprite(:"#{list}_sprite", at: [40 + (CHANGING.fetch(list) * 10), 40]).draw_with list
      end
      colors :menu_colors, PLAIN
      image :menu_tile, width: 8, height: 8, data: halves.(PLAIN), colors: :menu_colors
      colors :other_colors, games.list(5)
      image :other_tile, width: 8, height: 8, data: halves.(games.list(5)), colors: :other_colors
      tiles :title_set, "s" => :sign_tile, "w" => :words_tile
      tiles :plain_set, "m" => :menu_tile, "o" => :other_tile
      sets = %i[sign words].to_h do |list|
        [list, (0...SETS).map { |step| colors :"#{list}_set#{step}", games.colors_at(list, step) }]
      end
      instance_exec(sets, &rest)
    end
    builder.finalize_program
    builder.program
  end

  # A GROUND THAT WALKS BETWEEN TWO AREAS IN FRONT OF THE BACKGROUND, below its row of tiles.
  # Walking into an area sends that area's whole table of background colours, over the groups the
  # background's lists were written into. With +tinted+ a tint is in force from the third pass.
  private def walking_game(tinted: false)
    two_lists_game do |sets|
      tiles :field_tiles, "g" => :menu_tile
      tiles :house_tiles, "f" => :other_tile
      title = background :title, tiles: :title_set, map: ["sws"]
      title.draw_with({ sign: :sign, words: :words })
      ground = background :ground, tiles: { field: :field_tiles, house: :house_tiles },
                                   map: { field: { meadow: [" " * 30, " " * 30, "g" * 30] },
                                          house: { hall: [" " * 30, " " * 30, "f" * 30] } }
      pass = var :pass, 0
      room = var :room, 0
      game_loop do
        pass += 1
        room = 1 if pass == 4
        room = 0 if pass == 8
        tint :red, 50 if tinted && pass == 3
        recolor :sign, sets.fetch(:sign), showing: 1 if pass == 2
        recolor :words, sets.fetch(:words), showing: 2 if pass == 5
        recolor :sign, :sign if pass == 6
        ground.show_map room
      end
    end
  end

  def test_the_tiles_follow_their_lists_when_another_background_walks_into_an_area
    assert_backends_agree(walking_game, frames: EVERY_PASS)
  end

  def test_the_tiles_follow_their_lists_when_an_area_is_walked_into_under_a_tint
    assert_backends_agree(walking_game(tinted: true), frames: EVERY_PASS)
  end

  # Each area hands its groups of colours out again, so a walking background's tiles have no one
  # group for a list's colours to be copied into. The build says so.
  def test_a_background_that_walks_between_areas_and_follows_several_lists_is_refused
    walking = two_lists_game do |sets|
      tiles :sign_tiles, "s" => :sign_tile, "w" => :words_tile
      tiles :words_tiles, "s" => :sign_tile, "w" => :words_tile, "m" => :menu_tile
      ground = background :ground, tiles: { near: :sign_tiles, far: :words_tiles },
                                   map: { near: { first: ["sw"] }, far: { second: ["wsm"] } }
      ground.draw_with({ sign: :sign, words: :words })
      game_loop { %i[sign words].each { |list| recolor list, sets.fetch(list), showing: 1 } }
    end
    message = assert_raises(GBA::LoweringError) { GBA.new.lower(walking.copy.tap { |copy| copy.console = :gba }) }.message

    assert_match(/background :ground walks between areas/, message)
    assert_match(/does not make that yet/, message)
  end

  # TWO SCENES WITH A BACKGROUND EACH. The title's follows two lists, and the menu's own tiles
  # read the same groups of colours while the menu is up. The lists change while the menu is up,
  # where nothing of the title's may be written; the title then arrives showing what they hold, and
  # arrives again after the menu showing what they were told meanwhile. With +tinted+ a tint is in
  # force from the fourth pass.
  private def scenes_game(tinted: false)
    two_lists_game do |sets|
      scene :menu do
        background :choices, tiles: :plain_set, map: ["mom"]
      end
      scene :title do
        title = background :title, tiles: :title_set, map: ["sws"]
        title.draw_with({ sign: :sign, words: :words })
      end
      state = var :state, 0
      pass = var :pass, 0
      game_loop do
        pass += 1
        state = 1 if pass == 5
        state = 0 if pass == 8
        state = 1 if pass == 11
        tint :red, 50 if tinted && pass == 4
        recolor :sign, sets.fetch(:sign), showing: 1 if pass == 2
        recolor :words, sets.fetch(:words), showing: 2 if pass == 3
        recolor :sign, sets.fetch(:sign), showing: 0 if pass == 6
        recolor :words, :words if pass == 9
        case_var(:state) do
          when_val 0, :menu
          when_val 1, :title
        end
      end
    end
  end

  def test_a_scenes_own_background_arrives_showing_what_its_lists_hold
    assert_backends_agree(scenes_game, frames: 1..13)
  end

  def test_a_scenes_own_background_arrives_under_a_tint_showing_what_its_lists_hold
    assert_backends_agree(scenes_game(tinted: true), frames: 1..13)
  end

  # The menu's tiles, read off the cartridge while the lists change under it: the same groups of
  # colours are the title's when the title is up, and the menu's own colours must stay in them.
  def test_a_list_changed_while_another_scene_is_up_leaves_that_scenes_colors_alone
    v = assert_emulator_loads_rom(assemble_rom(scenes_game, name: "FOLLOWS"), frames: 5)

    assert_equal PLAIN.drop(1), [v.pixel_gba(1, 1), v.pixel_gba(5, 1)], "the menu's first tile"
    assert_equal RecolorSeveralListsGames.list(5).drop(1), [v.pixel_gba(9, 1), v.pixel_gba(13, 1)], "its second"
  end
end
