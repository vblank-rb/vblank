# frozen_string_literal: true

require "test_helper"

# The game these tests play, shared with the Genesis cartridge's own test of the same colours
# (test/lowering/genesis/vblank/ir/backends/genesis/test_genesis_recolor_several_lists.rb).
module RecolorSeveralListsGames
  include SharedConstants

  # Colours whose channels are multiples of four, so a console that keeps three bits of each
  # still tells them apart.
  def self.rgb4(red, green, blue) = VBlank::Graphics::Color.rgb(red * 4, green * 4, blue * 4)

  # A list of that number's own two colours, see-through first: no two numbers share a colour.
  def self.list(number) = [:transparent, rgb4(number, 7 - number, 1), rgb4(7 - number, number, 6)]

  # The lists the game changes, and the three sets each can hold besides its own colours.
  CHANGING = { sign: 0, words: 2, trim: 4 }.freeze
  SETS = 3
  # A list of the same background that nothing changes.
  PLAIN = [:transparent, rgb4(7, 7, 7), rgb4(3, 3, 3)].freeze

  # The colours of +list+ at step +step+, counting its sets from 0; any other step is its own.
  def self.colors_at(list, step)
    own = list(CHANGING.fetch(list))
    return own unless step.between?(0, SETS - 1)

    own.each_with_index.map { |color, place| place.zero? ? color : color ^ (step + 1) << 12 }
  end

  # WHICH SET EACH LIST HOLDS ON EACH PASS, counting passes from 1: 3 is its own colours. The
  # lists change on different passes, all three change on pass 7, and :sign goes back to its
  # own on pass 9 while the others stay.
  STEPS = Ractor.make_shareable({ sign: [3, 3, 0, 0, 1, 1, 1, 2, 2, 3, 3],
                                  words: [3, 3, 3, 0, 0, 0, 1, 2, 2, 2, 2],
                                  trim: [3, 3, 3, 3, 3, 0, 0, 1, 1, 1, 1] })
  LAST_PASS = 10

  # Where each tile of the background stands, and each sprite: a pixel of its left half, then its right.
  TILE_PIXELS = Ractor.make_shareable({ sign: [[1, 1], [5, 1]], words: [[9, 1], [13, 1]], trim: [[17, 1], [21, 1]],
                                        plain: [[25, 1], [29, 1]] })
  SPRITE_PIXELS = Ractor.make_shareable({ sign: [[41, 41], [45, 41]], words: [[61, 41], [65, 41]], trim: [[81, 41], [85, 41]] })

  # ONE BACKGROUND WHOSE TILES ARE DRAWN FROM FOUR LISTS, three of which the game changes, each
  # through its own three sets by its own number, and a sprite drawn with each of the three. Each
  # picture is 8x8, its left half its list's first colour after place 0 and its right half the next.
  # +following+ is what the background is told to draw with, the three lists by default. A block
  # is handed each list's sets and the background, and takes the place of the loop. +builder+ is
  # the build it is declared in, for a test that names its console.
  private def several_lists_game(following: CHANGING.keys.to_h { |list| [list, list] }, builder: Builder.new, &rest)
    games = RecolorSeveralListsGames
    builder.instance_eval do
      screen :tiled
      halves = ->(colors) { Array.new(64) { |i| (i % 8) < 4 ? colors[1] : colors[2] } }
      CHANGING.each_key do |list|
        colors list, games.list(CHANGING.fetch(list))
        image :"#{list}_tile", width: 8, height: 8, data: halves.(games.list(CHANGING.fetch(list))), colors: list
        image :"#{list}_sprite", width: 8, height: 8, data: halves.(games.list(CHANGING.fetch(list))), colors: list
      end
      colors :plain, PLAIN
      image :plain_tile, width: 8, height: 8, data: halves.(PLAIN), colors: :plain
      tiles :title_set, "s" => :sign_tile, "w" => :words_tile, "t" => :trim_tile, "p" => :plain_tile
      title = background :title, tiles: :title_set, map: ["swtp"]
      title.draw_with(following) if following
      CHANGING.each_key.with_index { |list, at| sprite(:"#{list}_sprite", at: [40 + (at * 20), 40]).draw_with list }
      sets = CHANGING.keys.to_h do |list|
        [list, (0...SETS).map { |step| colors :"#{list}_set#{step}", games.colors_at(list, step) }]
      end
      steps = STEPS.to_h { |list, by_pass| [list, table(:"#{list}_steps", by_pass)] }
      next instance_exec(sets, title, &rest) if rest

      pass = var :pass, 0
      game_loop do
        pass += 1
        CHANGING.each_key { |list| recolor list, sets.fetch(list), showing: steps.fetch(list)[pass] }
      end
    end
    builder.finalize_program
    builder.program
  end
end

# A BACKGROUND DRAWN FROM SEVERAL LISTS THE GAME CHANGES follows each of them: a tile shows what
# its own list holds, as a sprite drawn with that list does, so a screen whose lists all walk to
# black fades whole.
class TestRecolorSeveralLists < Minitest::Test
  include RecolorSeveralListsGames

  private def shown_all(colors) = colors.drop(1).map { |color| shown(color) }

  # What each tile and each sprite shows once pass +pass+ is drawn.
  private def shown_on(pass)
    screen = game_player.run(several_lists_game, frames: pass + framework_drawing_lag).screen
    spots = ->(pixels) { pixels.transform_values { |places| places.map { |x, y| screen.pixel(x, y) } } }
    [spots.(TILE_PIXELS), spots.(SPRITE_PIXELS)]
  end

  def test_each_tile_shows_what_its_own_list_holds_on_every_pass
    (1..LAST_PASS).each do |pass|
      lists = CHANGING.keys.to_h { |list| [list, shown_all(RecolorSeveralListsGames.colors_at(list, STEPS.fetch(list)[pass]))] }
      tiles, sprites = shown_on(pass)

      assert_equal lists.merge(plain: shown_all(PLAIN)), tiles, "the background on pass #{pass}"
      assert_equal lists, sprites, "the sprites on pass #{pass}"
    end
  end

  def test_a_program_with_no_game_loop_shows_what_each_list_holds
    unpaced = several_lists_game do |sets|
      recolor :sign, sets.fetch(:sign), showing: 1
      recolor :trim, sets.fetch(:trim), showing: 2
      halt
    end
    screen = game_player.run(unpaced, frames: 3).screen
    tiles = TILE_PIXELS.transform_values { |places| places.map { |x, y| screen.pixel(x, y) } }

    assert_equal({ sign: shown_all(RecolorSeveralListsGames.colors_at(:sign, 1)),
                   words: shown_all(RecolorSeveralListsGames.colors_at(:words, 3)),
                   trim: shown_all(RecolorSeveralListsGames.colors_at(:trim, 2)), plain: shown_all(PLAIN) }, tiles)
  end

  # Told to follow two of the three, its tiles of the third would show that list's power-on
  # colours for good.
  def test_a_changing_list_the_background_was_not_told_says_so
    message = assert_raises(ArgumentError) { several_lists_game(following: { sign: :sign, words: :words }) }.message

    assert_match(/background :title/, message)
    assert_match(/trim: :trim/, message)
  end

  # Following its lists, the background has no other list to take turns with.
  def test_another_list_beside_the_followed_ones_says_so
    message = assert_raises(ArgumentError) do
      several_lists_game(following: { sign: :sign, words: :words, trim: :trim, plain: :words })
    end.message

    assert_match(/background :title/, message)
    assert_match(/for good/, message)
  end
end
