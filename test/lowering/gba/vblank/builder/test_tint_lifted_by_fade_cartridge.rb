# frozen_string_literal: true

require "test_helper"
require "differential"
require "screen_backdrop_games"
require "all/vblank/builder/test_pack_backdrops"

# A FADE THAT TAKES A TINT'S PLACE, ON THE ADVANCE'S CARTRIDGE, read in the emulator. A tint on a
# tiled screen walks the table of background colours, and a whole-number fade after it is the
# display's own blend, so the fade first copies the table back as the cartridge holds it
# (GBA::PaletteTint#emit_lift_palette_tint). The cartridge holds the colours each tile was drawn
# in. So every group of colours the game has since written over is written again after that copy:
# a background drawn with another list, one that follows a list `recolor` changes, a backdrop that
# follows a list, and the backdrop a scene's `screen` names. Each game here tints on pass
# +TINT_PASS+ and fades on pass +LIFT_PASS+, and is held to the interpreter on every pass.
class TestTintLiftedByFadeCartridge < Minitest::Test
  include Differential
  include PackBackdropGames

  TINT_PASS = 4
  LIFT_PASS = 7
  # Every pass to three past the fade, and a frame more for the last pass's colours to show.
  EVERY_PASS = (1..(LIFT_PASS + 4))

  # The list the tiles are drawn in, the two sets `recolor` gives it, and a list borrowed for them:
  # no two share a colour.
  SIGN = [:transparent, Color.rgb(0, 28, 4), Color.rgb(28, 0, 24)].freeze
  SIGN_SETS = [[:transparent, Color.rgb(4, 4, 28), Color.rgb(28, 28, 0)],
               [:transparent, Color.rgb(16, 8, 0), Color.rgb(0, 20, 20)]].freeze
  BORROWED = [:transparent, Color.rgb(31, 16, 0), Color.rgb(8, 0, 31)].freeze
  BLUE = Color.rgb(0, 0, 31)

  # An 8x8 picture, its left half the list's first colour after place 0 and its right half the next.
  private def halves(colors) = Array.new(64) { |i| (i % 8) < 4 ? colors[1] : colors[2] }

  # A tiled game with a tile and a sprite drawn in :sign, three of the tile in the set :sign_set
  # under "s", and the list :borrowed. The block declares the rest and the loop.
  private def game(&rest)
    test = self
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      colors :sign, SIGN
      colors :borrowed, BORROWED
      image :sign_tile, width: 8, height: 8, data: test.halves_of(SIGN), colors: :sign
      image :sign_sprite, width: 8, height: 8, data: test.halves_of(SIGN), colors: :sign
      tiles :sign_set, "s" => :sign_tile
      instance_eval(&rest)
    end
    builder.finalize_program
    builder.program
  end

  # Called back from a game block, where `self` is the builder.
  def halves_of(colors) = halves(colors)

  # A BACKGROUND THAT FOLLOWS ONE LIST THE GAME RECOLOURS: three tiles drawn with :sign, which is
  # told to hold another set before the tint and another after the fade.
  private def one_followed_list
    game do
      pass = var :pass, 0
      title = background :title, tiles: :sign_set, map: ["sss"]
      title.draw_with :sign
      sprite(:sign_sprite, at: [40, 40]).draw_with :sign
      sets = SIGN_SETS.each_with_index.map { |set, at| colors :"sign_set#{at}", set }
      game_loop do
        pass += 1
        recolor :sign, sets, showing: 0 if pass == 2
        recolor :sign, sets, showing: 1 if pass == LIFT_PASS + 2
        tint :red, 50 if pass == TINT_PASS
        fade :black, 25 if pass == LIFT_PASS
      end
    end
  end

  def test_a_background_following_one_list_keeps_its_colors
    assert_backends_agree(one_followed_list, frames: EVERY_PASS)
  end

  # A BACKGROUND DRAWN WITH ANOTHER LIST, one nothing recolours, from the second pass.
  private def one_borrowed_list
    game do
      pass = var :pass, 0
      title = background :title, tiles: :sign_set, map: ["sss"]
      game_loop do
        pass += 1
        title.draw_with :borrowed if pass >= 2
        tint :red, 50 if pass == TINT_PASS
        fade :black, 25 if pass == LIFT_PASS
      end
    end
  end

  def test_a_background_drawn_with_another_list_keeps_its_colors
    assert_backends_agree(one_borrowed_list, frames: EVERY_PASS)
  end

  # THE SAME IN A SCENE'S OWN BACKGROUND, whose group is its own only while its scene is up: the
  # title is up through the tint and the fade, and the menu, drawn as drawn, from two passes after.
  private def a_scenes_borrowed_list
    game do
      pass = var :pass, 0
      state = var :state, 0
      scene(:title) { background(:title, tiles: :sign_set, map: ["sss"]).draw_with :borrowed }
      scene(:menu) { background :choices, tiles: :sign_set, map: [" s s"] }
      game_loop do
        pass += 1
        state = 1 if pass == LIFT_PASS + 2
        tint :red, 50 if pass == TINT_PASS
        fade :black, 25 if pass == LIFT_PASS
        case_var(:state) do
          when_val 0, :title
          when_val 1, :menu
        end
      end
    end
  end

  def test_a_scenes_own_background_drawn_with_another_list_keeps_its_colors
    assert_backends_agree(a_scenes_borrowed_list, frames: EVERY_PASS)
  end

  # A BACKDROP THAT FOLLOWS A LIST, declared black and told to hold blue on the second pass, behind
  # the corner tile, whose left half is see-through.
  private def a_backdrop_following_a_list
    builder = Builder.new
    builder.instance_eval do
      colors :screen_colors, %i[black black]
      colors :lit, [BLUE, :white]
      screen :tiled, backdrop: :screen_colors
      ScreenBackdropGames.declare_corner_tile(self)
      background :title, tiles: :corner_set, map: ["c"]
      pass = var :pass, 0
      game_loop do
        pass += 1
        recolor :screen_colors, :lit if pass == 2
        tint :red, 50 if pass == TINT_PASS
        fade :black, 25 if pass == LIFT_PASS
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_a_backdrop_following_a_list_keeps_the_color_the_list_holds
    assert_backends_agree(a_backdrop_following_a_list, frames: EVERY_PASS)
  end

  # A SCENE'S OWN BACKDROP FROM A DATA PACK SLOT, IN A SCENE THAT SENDS NO COLOURS OF ITS OWN: the
  # one background is every scene's, so the table of colours the fade copies back holds the game's
  # backdrop, black, in its first place. The scene says its backdrop is the second bank's first
  # colour.
  private def a_scenes_backdrop_over_the_games_colors(from)
    test = self
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      pack = test.backdrop_pack_of(self, from)
      test.pack_cell_of(self, pack, :world)
      pass = var :pass, 0
      state = var :state, 0
      scene(:title) { screen :tiled, backdrop: pack[:palette].bank(1) }
      game_loop do
        pass += 1
        tint :red, 50 if pass == TINT_PASS
        fade :black, 25 if pass == LIFT_PASS
        case_var(:state) { when_val 0, :title }
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_a_scenes_backdrop_from_the_pack_keeps_its_color_over_the_games_colors
    Dir.mktmpdir do |folder|
      program = a_scenes_backdrop_over_the_games_colors(backdrop_original(folder))

      assert_backends_agree(program, frames: EVERY_PASS, name: "LIFTGAME")
    end
  end

  # THE SAME IN A SCENE THAT SENDS ITS OWN COLOURS, whose table carries the scene's backdrop in its
  # first place, so the copy puts it back by itself. The title's is the second bank's first colour,
  # and the title is up when the fade takes the tint's place.
  private def a_scenes_backdrop_from_the_pack(from)
    scenes_under(from) do |level|
      level.store!(level + 1)
      tint :red, 50 if level == 100 + TITLE_PASS + 1
      fade :black, 25 if level == 100 + TITLE_PASS + 4
    end
  end

  def test_a_scenes_backdrop_from_the_pack_keeps_its_color
    Dir.mktmpdir do |folder|
      program = a_scenes_backdrop_from_the_pack(backdrop_original(folder))

      assert_backends_agree(program, frames: 2..(TITLE_PASS + 7), name: "LIFTDROP")
    end
  end
end
